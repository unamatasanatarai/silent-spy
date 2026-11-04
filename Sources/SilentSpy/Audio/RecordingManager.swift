import Foundation
import Combine
import AppKit

/// Thread-safe hand-off point between the capture queues and the recording pipeline.
///
/// Audio samples go straight from the capture queues to the synchronizer — never through the main
/// thread — so UI stalls can't delay or reorder audio. Meter values are accumulated here and picked
/// up by the UI at a fixed rate instead of triggering a SwiftUI update per audio buffer.
private final class CaptureSink: @unchecked Sendable {
    private let lock = NSLock()
    private var synchronizer: AudioStreamSynchronizer?
    private var micRMS: Float = 0
    private var micPeak: Float = 0
    private var systemRMS: Float = 0
    private var systemPeak: Float = 0

    func attach(_ sync: AudioStreamSynchronizer?) {
        lock.lock()
        synchronizer = sync
        micRMS = 0; micPeak = 0; systemRMS = 0; systemPeak = 0
        lock.unlock()
    }

    func push(_ audio: CapturedAudio, from source: AudioStreamSynchronizer.Source) {
        lock.lock()
        let sync = synchronizer
        if sync != nil {
            switch source {
            case .mic:
                micRMS = max(micRMS, audio.rms)
                micPeak = max(micPeak, audio.peak)
            case .system:
                systemRMS = max(systemRMS, audio.rms)
                systemPeak = max(systemPeak, audio.peak)
            }
        }
        lock.unlock()
        sync?.append(audio, from: source)
    }

    /// Returns the loudest levels seen since the previous call and resets them.
    func takeLevels() -> (micRMS: Float, micPeak: Float, systemRMS: Float, systemPeak: Float) {
        lock.lock()
        defer {
            micRMS = 0; micPeak = 0; systemRMS = 0; systemPeak = 0
            lock.unlock()
        }
        return (micRMS, micPeak, systemRMS, systemPeak)
    }
}

@MainActor
public final class RecordingManager: ObservableObject, MicrophoneCaptureDelegate, SystemAudioCaptureDelegate {
    @Published public var isRecording: Bool = false

    // Live Audio Meters (0.0 to 1.0), refreshed at `meterRefreshRate`
    @Published public var micLevel: Float = 0.0
    @Published public var micPeakLevel: Float = 0.0
    @Published public var systemLevel: Float = 0.0
    @Published public var systemPeakLevel: Float = 0.0

    // Statistics
    @Published public var elapsedDuration: TimeInterval = 0.0
    @Published public var bytesWritten: UInt64 = 0
    @Published public var currentRecordingURL: URL?
    @Published public var lastSavedRecordingURL: URL?

    // Storage & Directory
    @Published public var storageDirectoryURL: URL = AudioConfig.storageDirectory

    // Permissions & Status
    @Published public var hasMicPermission: Bool = false
    @Published public var hasScreenPermission: Bool = false
    @Published public var hasStoragePermission: Bool = false
    @Published public var statusMessage: String = "Ready to record"
    @Published public var errorMessage: String? = nil
    @Published public var quitPromptActive: Bool = false

    /// Number of recordings stopped but not yet fully written & finalized on disk.
    @Published public private(set) var pendingFinalizations: Int = 0

    private let micManager = MicrophoneCaptureManager()
    private var systemManager: AnyObject? = nil
    private let sink = CaptureSink()

    private var m4aWriter: StreamingM4AWriter?
    private var synchronizer: AudioStreamSynchronizer?
    private var finalizationWaiters: [() -> Void] = []

    private static let meterRefreshRate: Double = 30
    private var timer: Timer?
    private var timerTicks = 0
    private var startTime: Date?

    public init() {
        micManager.delegate = self
        if #available(macOS 12.3, *) {
            let sysMgr = SystemAudioCaptureManager()
            sysMgr.delegate = self
            self.systemManager = sysMgr
        }
        self.storageDirectoryURL = AudioConfig.storageDirectory
        checkPermissions()

        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkPermissions()
            }
        }
    }

    public func checkPermissions() {
        self.hasMicPermission = MicrophoneCaptureManager.checkPermission()
        if #available(macOS 12.3, *) {
            self.hasScreenPermission = SystemAudioCaptureManager.checkPermission()
        } else {
            self.hasScreenPermission = false
        }
        self.hasStoragePermission = AudioConfig.checkStoragePermission()
        self.storageDirectoryURL = AudioConfig.storageDirectory
        updateCaptureEngines()
    }

    public func restartApp() {
        let bundleURL = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: bundleURL, configuration: config) { _, _ in
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
        }
    }

    /// Capture engines run ONLY while recording. Start/stop is idempotent and serialized inside each
    /// manager, so this can be called any number of times in any order.
    public func updateCaptureEngines() {
        micManager.setActive(isRecording && hasMicPermission)
        if #available(macOS 12.3, *), let sysMgr = systemManager as? SystemAudioCaptureManager {
            sysMgr.setActive(isRecording && hasScreenPermission)
        }
        if !isRecording {
            micLevel = 0; micPeakLevel = 0
            systemLevel = 0; systemPeakLevel = 0
        }
    }

    public func startMonitoringIfPermitted() {
        updateCaptureEngines()
    }

    public func requestMicPermission() {
        MicrophoneCaptureManager.requestPermission { [weak self] granted in
            self?.hasMicPermission = granted
            if granted {
                self?.statusMessage = "Microphone permission granted."
                self?.updateCaptureEngines()
            } else {
                self?.statusMessage = "Microphone permission denied. Enable in System Settings."
            }
        }
    }

    public func requestScreenPermission() {
        if #available(macOS 12.3, *) {
            SystemAudioCaptureManager.requestPermission()
        }
        // Check again after a brief delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.checkPermissions()
        }
    }

    public func requestStoragePermission(window: NSWindow? = nil, completion: ((Bool) -> Void)? = nil) {
        AudioConfig.promptForStorageFolder(window: window) { [weak self] selectedURL in
            guard let self = self else { return }
            if let selectedURL = selectedURL {
                self.storageDirectoryURL = selectedURL
                self.hasStoragePermission = AudioConfig.checkStoragePermission(for: selectedURL)
                self.statusMessage = "Storage folder set to: \(selectedURL.lastPathComponent)"
                completion?(self.hasStoragePermission)
            } else {
                self.checkPermissions()
                completion?(self.hasStoragePermission)
            }
        }
    }

    public func startRecording() {
        guard !isRecording else { return }
        errorMessage = nil

        checkPermissions()

        // Ensure storage folder permission
        guard hasStoragePermission else {
            self.statusMessage = "Please select and authorize a storage folder."
            requestStoragePermission { [weak self] granted in
                if granted {
                    self?.startRecording()
                } else {
                    self?.errorMessage = "Cannot record without a writable storage folder."
                }
            }
            return
        }

        let recordingURL = AudioConfig.generateRecordingURL()

        do {
            let writer = try StreamingM4AWriter(
                fileURL: recordingURL,
                sampleRate: AudioConfig.sampleRate,
                channels: 2
            )
            writer.onWriteError = { [weak self, weak writer] status in
                Task { @MainActor [weak self] in
                    guard let self = self, let writer = writer else { return }
                    self.handleWriteFailure(of: writer, status: status)
                }
            }
            let sync = AudioStreamSynchronizer(writer: writer)

            self.currentRecordingURL = recordingURL
            self.m4aWriter = writer
            self.synchronizer = sync
            self.sink.attach(sync)
            self.isRecording = true
            self.startTime = Date()
            self.elapsedDuration = 0
            self.bytesWritten = 0
            self.statusMessage = "Recording active (M4A Stereo)..."
            self.startTimer()

            updateCaptureEngines()
        } catch {
            self.errorMessage = "Failed to initialize recording file: \(error.localizedDescription)"
            self.statusMessage = "Failed to initialize recording file."
            self.currentRecordingURL = nil
            updateCaptureEngines()
        }
    }

    /// Stops the active recording. `completion` runs on the main thread once the file is fully
    /// written and finalized (or immediately if nothing was recording).
    public func stopRecording(completion: (() -> Void)? = nil) {
        guard isRecording, let sync = synchronizer else {
            completion?()
            return
        }

        stopTimer()
        let savedURL = currentRecordingURL
        let folderName = storageDirectoryURL.lastPathComponent
        statusMessage = "Finalizing M4A file..."

        // Detach this recording's pipeline *now*. Its flush completion below only touches values it
        // captured, so a new recording started before the flush finishes is never affected.
        sink.attach(nil)
        synchronizer = nil
        m4aWriter = nil
        currentRecordingURL = nil
        isRecording = false
        updateCaptureEngines()

        pendingFinalizations += 1
        sync.flushAndFinish { [weak self] status in
            guard let self = self else {
                completion?()
                return
            }
            if let savedURL = savedURL, FileManager.default.fileExists(atPath: savedURL.path) {
                self.lastSavedRecordingURL = savedURL
            }
            if status == noErr {
                if !self.isRecording {
                    self.statusMessage = "Recording saved to \(folderName)!"
                }
            } else {
                self.errorMessage = "Recording \(savedURL?.lastPathComponent ?? "") may be incomplete (OSStatus \(status))."
            }
            self.pendingFinalizations -= 1
            completion?()
            if self.pendingFinalizations == 0 {
                let waiters = self.finalizationWaiters
                self.finalizationWaiters.removeAll()
                waiters.forEach { $0() }
            }
        }
    }

    /// Stops any active recording and calls `completion` once every recording is finalized on disk.
    /// Used to delay app termination so no file is left without its `moov` index.
    public func finalizeAll(completion: @escaping () -> Void) {
        if isRecording {
            stopRecording()
        }
        if pendingFinalizations == 0 {
            completion()
        } else {
            finalizationWaiters.append(completion)
        }
    }

    public var hasUnfinalizedRecordings: Bool {
        isRecording || pendingFinalizations > 0
    }

    private func handleWriteFailure(of writer: StreamingM4AWriter, status: OSStatus) {
        guard writer === m4aWriter, isRecording else { return }
        errorMessage = "Writing to disk failed (OSStatus \(status)) — recording stopped. Check free space and the storage folder."
        stopRecording()
    }

    private func startTimer() {
        stopTimer()
        timerTicks = 0
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / Self.meterRefreshRate, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.timerTick()
            }
        }
    }

    private func timerTick() {
        guard isRecording else { return }
        timerTicks += 1

        let levels = sink.takeLevels()
        micLevel = max(levels.micRMS * 2.5, micLevel * 0.82)
        micPeakLevel = max(levels.micPeak, micPeakLevel * 0.88)
        systemLevel = max(levels.systemRMS * 2.5, systemLevel * 0.82)
        systemPeakLevel = max(levels.systemPeak, systemPeakLevel * 0.88)

        if let start = startTime {
            let elapsed = Date().timeIntervalSince(start)
            // Only republish when the displayed second changes.
            if Int(elapsed) != Int(elapsedDuration) {
                elapsedDuration = elapsed
            }
        }

        // File size: once per second is plenty (it's a stat() syscall).
        if timerTicks % Int(Self.meterRefreshRate) == 0, let writer = m4aWriter {
            bytesWritten = writer.currentBytesWritten
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Capture delegates (called on capture queues)

    public nonisolated func microphoneDidCapture(_ audio: CapturedAudio) {
        sink.push(audio, from: .mic)
    }

    public nonisolated func microphoneCaptureDidFail(with error: Error) {
        Task { @MainActor in
            self.errorMessage = "Microphone: \(error.localizedDescription)"
        }
    }

    public nonisolated func systemAudioDidCapture(_ audio: CapturedAudio) {
        sink.push(audio, from: .system)
    }

    public nonisolated func systemAudioCaptureDidFail(with error: Error) {
        Task { @MainActor in
            self.errorMessage = "System Audio: \(error.localizedDescription)"
        }
    }

    // MARK: - Helpers

    public func openStorageFolder() {
        NSWorkspace.shared.open(storageDirectoryURL)
    }

    /// Opens the storage folder in Finder with the newest recording selected.
    /// Falls back to just opening the folder when no recording exists yet.
    public func revealLatestInFinder() {
        guard let url = newestRecordingURL() else {
            openStorageFolder()
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Resolves the newest recording: the in-progress file while recording,
    /// otherwise the most recently created `.m4a` in the storage folder
    /// (survives app restarts and folder changes, unlike `lastSavedRecordingURL`).
    public func newestRecordingURL() -> URL? {
        let fm = FileManager.default
        if isRecording, let url = currentRecordingURL, fm.fileExists(atPath: url.path) {
            return url
        }

        let keys: [URLResourceKey] = [.creationDateKey, .contentModificationDateKey, .isRegularFileKey]
        let files = (try? fm.contentsOfDirectory(
            at: storageDirectoryURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        )) ?? []

        func date(_ url: URL) -> Date {
            let values = try? url.resourceValues(forKeys: Set(keys))
            return values?.creationDate ?? values?.contentModificationDate ?? .distantPast
        }

        let newest = files
            .filter { $0.pathExtension.lowercased() == "m4a" }
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .max { date($0) < date($1) }

        if let newest = newest {
            return newest
        }
        if let last = lastSavedRecordingURL, fm.fileExists(atPath: last.path) {
            return last
        }
        return nil
    }

    public var formattedDuration: String {
        let totalSeconds = Int(elapsedDuration)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%02d:%02d", minutes, seconds)
        }
    }

    public var formattedFileSize: String {
        let kb = Double(bytesWritten) / 1024.0
        if kb < 1024.0 {
            return String(format: "%.1f KB", kb)
        }
        let mb = kb / 1024.0
        return String(format: "%.2f MB", mb)
    }
}

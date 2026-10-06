import Foundation
import Combine
import AppKit

@MainActor
public final class RecordingManager: ObservableObject, MicrophoneCaptureDelegate, SystemAudioCaptureDelegate {
    @Published public var isRecording: Bool = false
    
    // Live Audio Meters (0.0 to 1.0)
    @Published public var micLevel: Float = 0.0
    @Published public var micPeakLevel: Float = 0.0
    @Published public var systemLevel: Float = 0.0
    @Published public var systemPeakLevel: Float = 0.0
    
    // Statistics
    @Published public var elapsedDuration: TimeInterval = 0.0
    @Published public var bytesWritten: UInt32 = 0
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
    
    private let micManager = MicrophoneCaptureManager()
    private var systemManager: Any? = nil
    private var m4aWriter: StreamingM4AWriter?
    private var synchronizer: AudioStreamSynchronizer?
    
    private var timer: Timer?
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
    
    /// Controls audio capture engines.
    /// The microphone and system audio are engaged ONLY when recording is active.
    /// When idle, both engines are stopped and their levels remain 0.
    public func updateCaptureEngines() {
        if isRecording && hasMicPermission {
            if !micManager.isRunning {
                try? micManager.startCapture()
            }
        } else {
            if micManager.isRunning {
                micManager.stopCapture()
            }
            micLevel = 0.0
            micPeakLevel = 0.0
        }
        
        if #available(macOS 12.3, *) {
            if let sysMgr = systemManager as? SystemAudioCaptureManager {
                if isRecording && hasScreenPermission {
                    if !sysMgr.isRunning {
                        Task {
                            do {
                                try await sysMgr.startCapture()
                            } catch {
                                self.errorMessage = error.localizedDescription
                            }
                        }
                    }
                } else {
                    if sysMgr.isRunning {
                        Task {
                            await sysMgr.stopCapture()
                        }
                    }
                    systemLevel = 0.0
                    systemPeakLevel = 0.0
                }
            }
        } else {
            systemLevel = 0.0
            systemPeakLevel = 0.0
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
        self.currentRecordingURL = recordingURL
        
        do {
            let writer = try StreamingM4AWriter(
                fileURL: recordingURL,
                sampleRate: AudioConfig.sampleRate,
                channels: 2
            )
            self.m4aWriter = writer
            self.synchronizer = AudioStreamSynchronizer(writer: writer)
            self.isRecording = true
            self.startTime = Date()
            self.statusMessage = "Recording active (M4A Stereo)..."
            self.startTimer()
            
            // Activate capture engines (engages microphone now that recording is active)
            updateCaptureEngines()
        } catch {
            self.errorMessage = "Failed to initialize recording file: \(error.localizedDescription)"
            self.statusMessage = "Failed to initialize recording file."
            cleanupAfterFailure()
        }
    }
    
    public func stopRecording() {
        guard isRecording else { return }
        
        stopTimer()
        let savedURL = currentRecordingURL
        let folderName = storageDirectoryURL.lastPathComponent
        statusMessage = "Finalizing M4A file..."
        
        // Immediately disengage microphone when stopping recording
        isRecording = false
        updateCaptureEngines()
        
        synchronizer?.flushAndFinish { [weak self] in
            guard let self = self else { return }
            self.m4aWriter = nil
            self.synchronizer = nil
            self.lastSavedRecordingURL = savedURL
            self.currentRecordingURL = nil
            self.statusMessage = "Recording saved to \(folderName)!"
        }
    }
    
    private func cleanupAfterFailure() {
        stopTimer()
        isRecording = false
        updateCaptureEngines()
        m4aWriter = nil
        synchronizer = nil
    }
    
    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.timerTick()
            }
        }
    }
    
    private func timerTick() {
        guard isRecording else { return }
        
        if let start = startTime {
            elapsedDuration = Date().timeIntervalSince(start)
        }
        
        if let writer = m4aWriter {
            bytesWritten = writer.currentBytesWritten
        }
    }
    
    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
    
    // MARK: - Delegates
    
    public nonisolated func microphoneDidOutputSamples(_ samples: [Float], rmsLevel: Float, peakLevel: Float) {
        Task { @MainActor in
            guard self.isRecording else {
                if self.micLevel > 0 {
                    self.micLevel = 0.0
                    self.micPeakLevel = 0.0
                }
                return
            }
            
            // Update live levels when recording
            self.micLevel = max(rmsLevel * 2.5, self.micLevel * 0.82)
            self.micPeakLevel = max(peakLevel, self.micPeakLevel * 0.88)
            self.synchronizer?.appendMicSamples(samples)
        }
    }
    
    public nonisolated func microphoneCaptureDidFail(with error: Error) {
        Task { @MainActor in
            self.errorMessage = "Microphone error: \(error.localizedDescription)"
        }
    }
    
    public nonisolated func systemAudioDidOutputSamples(_ samples: [Float], rmsLevel: Float, peakLevel: Float) {
        Task { @MainActor in
            guard self.isRecording else {
                if self.systemLevel > 0 {
                    self.systemLevel = 0.0
                    self.systemPeakLevel = 0.0
                }
                return
            }
            
            // Update live levels when recording
            self.systemLevel = max(rmsLevel * 2.5, self.systemLevel * 0.82)
            self.systemPeakLevel = max(peakLevel, self.systemPeakLevel * 0.88)
            self.synchronizer?.appendSystemSamples(samples)
        }
    }
    
    public nonisolated func systemAudioCaptureDidFail(with error: Error) {
        Task { @MainActor in
            self.errorMessage = "System Audio error: \(error.localizedDescription)"
        }
    }
    
    // MARK: - Helpers
    
    public func openStorageFolder() {
        NSWorkspace.shared.open(storageDirectoryURL)
    }
    
    public func revealLatestInFinder() {
        guard let url = lastSavedRecordingURL ?? currentRecordingURL else {
            openStorageFolder()
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
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

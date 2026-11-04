import Foundation
import AppKit
import ScreenCaptureKit
import CoreMedia
import AVFoundation

public protocol SystemAudioCaptureDelegate: AnyObject {
    /// Called on the sample queue (not the main thread).
    func systemAudioDidCapture(_ audio: CapturedAudio)
    /// Called on an arbitrary queue.
    func systemAudioCaptureDidFail(with error: Error)
}

/// System audio capture: ScreenCaptureKit on macOS 13+, virtual loopback device (BlackHole…) on macOS 12.
///
/// Start/stop is driven by a desired state (`setActive`). Every reconcile step is appended to a single
/// serial chain of async operations, so a stop can never overtake an in-flight start and two streams can
/// never exist at once — whatever the click timing. Stream/session state is only touched inside that chain.
@available(macOS 12.3, *)
public final class SystemAudioCaptureManager: NSObject, SCStreamDelegate, SCStreamOutput, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let sampleQueue = DispatchQueue(label: "com.silentspy.systemaudio", qos: .userInteractive)

    // Guarded by `lock`
    private let lock = NSLock()
    private var desiredActive = false
    private var operationChain: Task<Void, Never>?

    // Only touched inside the serial operation chain
    private var stream: SCStream?
    private var fallbackSession: AVCaptureSession?
    private var lastAutoRecovery: Date?

    // sampleQueue-confined
    private let converter = MonoSampleConverter(targetRate: AudioConfig.sampleRate)

    public weak var delegate: SystemAudioCaptureDelegate?

    public static func checkPermission() -> Bool {
        return CGPreflightScreenCaptureAccess()
    }

    public static func requestPermission() {
        CGRequestScreenCaptureAccess()
    }

    /// Requests system-audio capture be running (`true`) or stopped (`false`). Idempotent, non-blocking.
    public func setActive(_ active: Bool) {
        lock.lock()
        desiredActive = active
        lock.unlock()
        enqueue { await $0.reconcile() }
    }

    // MARK: - Serial operation chain

    private func enqueue(_ operation: @escaping (SystemAudioCaptureManager) async -> Void) {
        lock.lock()
        let previous = operationChain
        operationChain = Task { [self] in
            await previous?.value
            await operation(self)
        }
        lock.unlock()
    }

    private var wantsActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return desiredActive
    }

    private func reconcile() async {
        let isRunning = stream != nil || fallbackSession != nil
        if wantsActive && !isRunning {
            do {
                try await start()
            } catch {
                delegate?.systemAudioCaptureDidFail(with: error)
            }
        } else if !wantsActive && isRunning {
            await stop()
        }
    }

    private func start() async throws {
        sampleQueue.sync { converter.reset() }

        if #available(macOS 13.0, *) {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let display = content.displays.first else {
                throw NSError(domain: "SilentSpy.SystemAudio", code: 1, userInfo: [NSLocalizedDescriptionKey: "No active display found for audio capture."])
            }

            let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

            let config = SCStreamConfiguration()
            config.capturesAudio = true
            config.excludesCurrentProcessAudio = true
            config.sampleRate = Int(AudioConfig.sampleRate)
            config.channelCount = 2

            // Minimize video capture overhead
            config.width = 2
            config.height = 2
            config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            config.showsCursor = false

            let newStream = SCStream(filter: filter, configuration: config, delegate: self)
            try newStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
            try await newStream.startCapture()
            stream = newStream
        } else {
            // macOS 12 Fallback: Virtual Audio Loopback Device (BlackHole, Soundflower, Loopback, etc.)
            let discovery = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.builtInMicrophone, .externalUnknown],
                mediaType: .audio,
                position: .unspecified
            )
            let virtualDevice = discovery.devices.first { device in
                let name = device.localizedName.lowercased()
                return name.contains("blackhole") || name.contains("soundflower") || name.contains("loopback") || name.contains("vb-cable")
            }

            guard let device = virtualDevice else {
                throw NSError(
                    domain: "SilentSpy.SystemAudio",
                    code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "System audio requires macOS 13+ or BlackHole 2ch driver."]
                )
            }

            let captureSession = AVCaptureSession()
            let input = try AVCaptureDeviceInput(device: device)
            guard captureSession.canAddInput(input) else {
                throw NSError(domain: "SilentSpy.SystemAudio", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cannot add virtual audio input to capture session."])
            }
            captureSession.addInput(input)

            let output = AVCaptureAudioDataOutput()
            // Loopback devices are often at 44.1 kHz: have Core Audio convert to 48 kHz Float32.
            output.audioSettings = AudioConfig.captureOutputSettings(channels: 2)
            output.setSampleBufferDelegate(self, queue: sampleQueue)
            guard captureSession.canAddOutput(output) else {
                throw NSError(domain: "SilentSpy.SystemAudio", code: 3, userInfo: [NSLocalizedDescriptionKey: "Cannot add virtual audio output to capture session."])
            }
            captureSession.addOutput(output)
            captureSession.startRunning()
            fallbackSession = captureSession
        }
    }

    private func stop() async {
        if let stream = stream {
            if #available(macOS 13.0, *) {
                try? await stream.stopCapture()
            }
            self.stream = nil
        }
        if let session = fallbackSession {
            session.stopRunning()
            fallbackSession = nil
        }
    }

    // MARK: - Sample delivery (sampleQueue)

    // macOS 12 fallback
    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        processAudioBuffer(sampleBuffer)
    }

    // macOS 13+
    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard #available(macOS 13.0, *) else { return }
        guard type == .audio else { return }
        processAudioBuffer(sampleBuffer)
    }

    private func processAudioBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard let audio = converter.convert(sampleBuffer) else { return }
        delegate?.systemAudioDidCapture(audio)
    }

    // MARK: - SCStreamDelegate

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        delegate?.systemAudioCaptureDidFail(with: error)
        // Drop our reference inside the chain (only if it is still the same stream), then try to recover.
        enqueue { manager in
            guard manager.stream === stream else { return }
            manager.stream = nil
            // At most one automatic restart per 10 s, so a persistently failing stream can't spin.
            if let last = manager.lastAutoRecovery, Date().timeIntervalSince(last) < 10 { return }
            manager.lastAutoRecovery = Date()
            await manager.reconcile()
        }
    }
}

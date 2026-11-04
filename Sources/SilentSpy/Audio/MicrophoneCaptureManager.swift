import Foundation
import AppKit
import AVFoundation
import CoreMedia

public protocol MicrophoneCaptureDelegate: AnyObject {
    /// Called on the capture queue (not the main thread).
    func microphoneDidCapture(_ audio: CapturedAudio)
    /// Called on an arbitrary queue.
    func microphoneCaptureDidFail(with error: Error)
}

/// Microphone capture.
///
/// All session work (`startRunning`/`stopRunning` block for tens to hundreds of ms) runs on a private
/// serial `sessionQueue`, never the main thread. Start/stop requests are expressed as a desired state
/// (`setActive`) and reconciled in order on that queue, so rapid toggling can't leave a session orphaned.
public final class MicrophoneCaptureManager: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable { // state confined to sessionQueue / captureQueue
    private let sessionQueue = DispatchQueue(label: "com.silentspy.micsession")
    private let captureQueue = DispatchQueue(label: "com.silentspy.miccapture", qos: .userInteractive)

    // sessionQueue-confined state
    private var captureSession: AVCaptureSession?
    private var currentDevice: AVCaptureDevice?
    private var desiredActive = false
    private var observers: [NSObjectProtocol] = []

    // captureQueue-confined state
    private let converter = MonoSampleConverter(targetRate: AudioConfig.sampleRate)

    public weak var delegate: MicrophoneCaptureDelegate?

    public override init() {
        super.init()
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    public static func checkPermission() -> Bool {
        return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    @MainActor
    public static func requestPermission(completion: @escaping (Bool) -> Void) {
        NSApplication.shared.activate(ignoringOtherApps: true)

        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        case .denied, .restricted:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                NSWorkspace.shared.open(url)
            }
            completion(false)
        @unknown default:
            completion(false)
        }
    }

    /// Requests the capture engine be running (`true`) or stopped (`false`). Idempotent, non-blocking.
    public func setActive(_ active: Bool) {
        sessionQueue.async { [self] in
            desiredActive = active
            reconcile()
        }
    }

    // MARK: - Session lifecycle (sessionQueue only)

    private func reconcile() {
        if desiredActive, captureSession == nil {
            do {
                try startSession()
            } catch {
                delegate?.microphoneCaptureDidFail(with: error)
            }
        } else if !desiredActive, captureSession != nil {
            stopSession()
        }
    }

    private func startSession() throws {
        guard let micDevice = AVCaptureDevice.default(for: .audio) else {
            throw NSError(
                domain: "SilentSpy.Microphone",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "No microphone device found on system."]
            )
        }

        let session = AVCaptureSession()
        let input = try AVCaptureDeviceInput(device: micDevice)

        guard session.canAddInput(input) else {
            throw NSError(
                domain: "SilentSpy.Microphone",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Cannot add microphone input to capture session."]
            )
        }
        session.addInput(input)

        let output = AVCaptureAudioDataOutput()
        // Let Core Audio do format + sample-rate conversion (high quality, stateful, anti-aliased).
        output.audioSettings = AudioConfig.captureOutputSettings(channels: 1)
        output.setSampleBufferDelegate(self, queue: captureQueue)

        guard session.canAddOutput(output) else {
            throw NSError(
                domain: "SilentSpy.Microphone",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Cannot add audio output to capture session."]
            )
        }
        session.addOutput(output)

        captureQueue.sync { converter.reset() }
        observe(session: session, device: micDevice)
        session.startRunning()
        captureSession = session
        currentDevice = micDevice
    }

    private func stopSession() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        captureSession?.stopRunning()
        captureSession = nil
        currentDevice = nil
    }

    private func observe(session: AVCaptureSession, device: AVCaptureDevice) {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .AVCaptureDeviceWasDisconnected, object: device, queue: nil) { [weak self] _ in
            self?.sessionQueue.async { self?.handleDeviceLoss(reason: "Microphone \"\(device.localizedName)\" disconnected") }
        })
        observers.append(center.addObserver(forName: .AVCaptureSessionRuntimeError, object: session, queue: nil) { [weak self] note in
            let err = note.userInfo?[AVCaptureSessionErrorKey] as? Error
            self?.sessionQueue.async {
                self?.handleDeviceLoss(reason: "Microphone error: \(err?.localizedDescription ?? "unknown")")
            }
        })
    }

    /// The input went away mid-recording: tear down, tell the user, and fall back to the new default input.
    private func handleDeviceLoss(reason: String) {
        guard captureSession != nil else { return }
        stopSession()
        guard desiredActive else { return }

        do {
            try startSession()
            let name = currentDevice?.localizedName ?? "default input"
            delegate?.microphoneCaptureDidFail(with: NSError(
                domain: "SilentSpy.Microphone",
                code: 10,
                userInfo: [NSLocalizedDescriptionKey: "\(reason). Switched to \(name)."]
            ))
        } catch {
            delegate?.microphoneCaptureDidFail(with: NSError(
                domain: "SilentSpy.Microphone",
                code: 11,
                userInfo: [NSLocalizedDescriptionKey: "\(reason). No other microphone available — mic channel is silent."]
            ))
        }
    }

    // MARK: - AVCaptureAudioDataOutputSampleBufferDelegate (captureQueue)

    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let audio = converter.convert(sampleBuffer) else { return }
        delegate?.microphoneDidCapture(audio)
    }
}

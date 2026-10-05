import Foundation
import AppKit
import AVFoundation
import CoreMedia

public protocol MicrophoneCaptureDelegate: AnyObject {
    func microphoneDidOutputSamples(_ samples: [Float], rmsLevel: Float, peakLevel: Float)
    func microphoneCaptureDidFail(with error: Error)
}

public final class MicrophoneCaptureManager: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private var captureSession: AVCaptureSession?
    private let captureQueue = DispatchQueue(label: "com.silentspy.miccapture", qos: .userInteractive)
    
    public weak var delegate: MicrophoneCaptureDelegate?
    public private(set) var isRunning: Bool = false
    
    public override init() {
        super.init()
    }
    
    public static func checkPermission() -> Bool {
        return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }
    
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
    
    public func startCapture() throws {
        guard !isRunning else { return }
        
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
        output.setSampleBufferDelegate(self, queue: captureQueue)
        
        guard session.canAddOutput(output) else {
            throw NSError(
                domain: "SilentSpy.Microphone",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Cannot add audio output to capture session."]
            )
        }
        session.addOutput(output)
        
        session.startRunning()
        self.captureSession = session
        self.isRunning = true
    }
    
    public func stopCapture() {
        guard isRunning, let session = captureSession else { return }
        session.stopRunning()
        self.captureSession = nil
        self.isRunning = false
    }
    
    // MARK: - AVCaptureAudioDataOutputSampleBufferDelegate
    
    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard sampleBuffer.isValid else { return }
        
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee else {
            return
        }
        
        var blockBuffer: CMBlockBuffer?
        let channelCount = max(1, Int(asbd.mChannelsPerFrame))
        let bufferListPointer = AudioBufferList.allocate(maximumBuffers: channelCount)
        defer {
            free(UnsafeMutableRawPointer(bufferListPointer.unsafeMutablePointer))
        }
        
        let bufferListSize = MemoryLayout<AudioBufferList>.size + (channelCount - 1) * MemoryLayout<AudioBuffer>.size
        
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: bufferListPointer.unsafeMutablePointer,
            bufferListSize: bufferListSize,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        
        guard status == noErr else { return }
        
        let numFrames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard numFrames > 0 else { return }
        
        var monoSamples = [Float](repeating: 0.0, count: numFrames)
        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isSignedInt = (asbd.mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0
        let isNonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        
        if isFloat {
            if isNonInterleaved {
                let actualChannels = min(bufferListPointer.count, channelCount)
                for c in 0..<actualChannels {
                    if let ptr = bufferListPointer[c].mData?.assumingMemoryBound(to: Float.self) {
                        for i in 0..<numFrames {
                            monoSamples[i] += ptr[i] / Float(max(1, actualChannels))
                        }
                    }
                }
            } else {
                if let ptr = bufferListPointer[0].mData?.assumingMemoryBound(to: Float.self) {
                    for i in 0..<numFrames {
                        var sum: Float = 0.0
                        for c in 0..<channelCount {
                            sum += ptr[i * channelCount + c]
                        }
                        monoSamples[i] = sum / Float(max(1, channelCount))
                    }
                }
            }
        } else if isSignedInt {
            if asbd.mBitsPerChannel == 16 {
                if isNonInterleaved {
                    let actualChannels = min(bufferListPointer.count, channelCount)
                    for c in 0..<actualChannels {
                        if let ptr = bufferListPointer[c].mData?.assumingMemoryBound(to: Int16.self) {
                            for i in 0..<numFrames {
                                monoSamples[i] += (Float(ptr[i]) / 32767.0) / Float(max(1, actualChannels))
                            }
                        }
                    }
                } else {
                    if let ptr = bufferListPointer[0].mData?.assumingMemoryBound(to: Int16.self) {
                        for i in 0..<numFrames {
                            var sum: Float = 0.0
                            for c in 0..<channelCount {
                                sum += Float(ptr[i * channelCount + c]) / 32767.0
                            }
                            monoSamples[i] = sum / Float(max(1, channelCount))
                        }
                    }
                }
            } else if asbd.mBitsPerChannel == 32 {
                if isNonInterleaved {
                    let actualChannels = min(bufferListPointer.count, channelCount)
                    for c in 0..<actualChannels {
                        if let ptr = bufferListPointer[c].mData?.assumingMemoryBound(to: Int32.self) {
                            for i in 0..<numFrames {
                                monoSamples[i] += (Float(ptr[i]) / 2147483647.0) / Float(max(1, actualChannels))
                            }
                        }
                    }
                } else {
                    if let ptr = bufferListPointer[0].mData?.assumingMemoryBound(to: Int32.self) {
                        for i in 0..<numFrames {
                            var sum: Float = 0.0
                            for c in 0..<channelCount {
                                sum += Float(ptr[i * channelCount + c]) / 2147483647.0
                            }
                            monoSamples[i] = sum / Float(max(1, channelCount))
                        }
                    }
                }
            }
        }
        
        // Resample if microphone input sample rate differs from target 48kHz
        var targetSamples = monoSamples
        let inRate = asbd.mSampleRate
        let outRate = AudioConfig.sampleRate
        if inRate > 0 && abs(inRate - outRate) > 1.0 {
            let outFrames = Int(Double(numFrames) * (outRate / inRate))
            if outFrames > 0 {
                targetSamples = [Float](repeating: 0.0, count: outFrames)
                for i in 0..<outFrames {
                    let srcIdx = Double(i) * (inRate / outRate)
                    let srcFloor = Int(srcIdx)
                    let frac = Float(srcIdx - Double(srcFloor))
                    let s0 = monoSamples[min(srcFloor, numFrames - 1)]
                    let s1 = monoSamples[min(srcFloor + 1, numFrames - 1)]
                    targetSamples[i] = s0 + frac * (s1 - s0)
                }
            }
        }
        
        guard !targetSamples.isEmpty else { return }
        
        // Calculate RMS and Peak for level meters
        var sumSquares: Float = 0.0
        var maxPeak: Float = 0.0
        for sample in targetSamples {
            let absVal = abs(sample)
            if absVal > maxPeak { maxPeak = absVal }
            sumSquares += sample * sample
        }
        let rms = sqrt(sumSquares / Float(targetSamples.count))
        
        delegate?.microphoneDidOutputSamples(targetSamples, rmsLevel: rms, peakLevel: maxPeak)
    }
}

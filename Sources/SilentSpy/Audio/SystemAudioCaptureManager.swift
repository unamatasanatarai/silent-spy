import Foundation
import AppKit
import ScreenCaptureKit
import CoreMedia
import AVFoundation

public protocol SystemAudioCaptureDelegate: AnyObject {
    func systemAudioDidOutputSamples(_ samples: [Float], rmsLevel: Float, peakLevel: Float)
    func systemAudioCaptureDidFail(with error: Error)
}

@available(macOS 12.3, *)
public final class SystemAudioCaptureManager: NSObject, SCStreamDelegate, SCStreamOutput, AVCaptureAudioDataOutputSampleBufferDelegate {
    private var stream: SCStream?
    private var fallbackMicSession: AVCaptureSession?
    private let sampleQueue = DispatchQueue(label: "com.silentspy.systemaudio", qos: .userInteractive)
    
    public weak var delegate: SystemAudioCaptureDelegate?
    public private(set) var isRunning: Bool = false
    
    public static func checkPermission() -> Bool {
        return CGPreflightScreenCaptureAccess()
    }
    
    public static func requestPermission() {
        CGRequestScreenCaptureAccess()
    }
    
    public func startCapture() async throws {
        guard !isRunning else { return }
        
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
            self.stream = newStream
            self.isRunning = true
        } else {
            // macOS 12 Fallback: Check for Virtual Audio Loopback Device (BlackHole, Soundflower, Loopback, etc.)
            let session = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.builtInMicrophone, .externalUnknown],
                mediaType: .audio,
                position: .unspecified
            )
            let virtualDevice = session.devices.first { device in
                let name = device.localizedName.lowercased()
                return name.contains("blackhole") || name.contains("soundflower") || name.contains("loopback") || name.contains("vb-cable")
            }
            
            if let device = virtualDevice {
                let captureSession = AVCaptureSession()
                let input = try AVCaptureDeviceInput(device: device)
                guard captureSession.canAddInput(input) else {
                    throw NSError(domain: "SilentSpy.SystemAudio", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cannot add virtual audio input to capture session."])
                }
                captureSession.addInput(input)
                
                let output = AVCaptureAudioDataOutput()
                output.setSampleBufferDelegate(self, queue: sampleQueue)
                guard captureSession.canAddOutput(output) else {
                    throw NSError(domain: "SilentSpy.SystemAudio", code: 3, userInfo: [NSLocalizedDescriptionKey: "Cannot add virtual audio output to capture session."])
                }
                captureSession.addOutput(output)
                captureSession.startRunning()
                
                self.fallbackMicSession = captureSession
                self.isRunning = true
            } else {
                throw NSError(
                    domain: "SilentSpy.SystemAudio",
                    code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "System audio requires macOS 13+ or BlackHole 2ch driver."]
                )
            }
        }
    }
    
    public func stopCapture() async {
        guard isRunning else { return }
        if let stream = self.stream {
            if #available(macOS 13.0, *) {
                try? await stream.stopCapture()
            }
            self.stream = nil
        }
        if let fallback = self.fallbackMicSession {
            fallback.stopRunning()
            self.fallbackMicSession = nil
        }
        self.isRunning = false
    }
    
    // MARK: - AVCaptureAudioDataOutputSampleBufferDelegate (macOS 12 Fallback)
    
    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        processAudioBuffer(sampleBuffer)
    }
    
    // MARK: - SCStreamOutput (macOS 13+)
    
    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard #available(macOS 13.0, *) else { return }
        guard type == .audio else { return }
        processAudioBuffer(sampleBuffer)
    }
    
    // MARK: - Common Audio Buffer Processing
    
    private func processAudioBuffer(_ sampleBuffer: CMSampleBuffer) {
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
        
        // Calculate RMS and Peak
        var sumSquares: Float = 0.0
        var maxPeak: Float = 0.0
        for s in monoSamples {
            let absVal = abs(s)
            if absVal > maxPeak { maxPeak = absVal }
            sumSquares += s * s
        }
        let rms = sqrt(sumSquares / Float(numFrames))
        
        delegate?.systemAudioDidOutputSamples(monoSamples, rmsLevel: rms, peakLevel: maxPeak)
    }
    
    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        self.isRunning = false
        delegate?.systemAudioCaptureDidFail(with: error)
    }
}

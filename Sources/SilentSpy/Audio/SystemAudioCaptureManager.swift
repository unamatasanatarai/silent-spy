import Foundation
import AppKit
import ScreenCaptureKit
import CoreMedia
import AVFoundation

public protocol SystemAudioCaptureDelegate: AnyObject {
    func systemAudioDidOutputSamples(_ samples: [Float], rmsLevel: Float, peakLevel: Float)
    func systemAudioCaptureDidFail(with error: Error)
}

public final class SystemAudioCaptureManager: NSObject, SCStreamDelegate, SCStreamOutput {
    private var stream: SCStream?
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
    }
    
    public func stopCapture() async {
        guard isRunning, let stream = self.stream else { return }
        try? await stream.stopCapture()
        self.stream = nil
        self.isRunning = false
    }
    
    // MARK: - SCStreamOutput
    
    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid else { return }
        
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

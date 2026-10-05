import Foundation
import AudioToolbox
import CoreAudio

/// High-performance streaming AAC (.m4a) audio writer.
/// Encodes dual-channel Linear PCM audio (Left: Mic, Right: System) into an M4A/AAC container
/// in real time with minimal memory footprint.
public final class StreamingM4AWriter {
    public let fileURL: URL
    public let sampleRate: Double
    public let channels: UInt32
    
    private var extAudioFile: ExtAudioFileRef?
    private let writeQueue = DispatchQueue(label: "com.silentspy.m4awriter", qos: .userInitiated)
    private var totalFramesWritten: Int64 = 0
    public private(set) var isWriting: Bool = false
    
    public init(fileURL: URL, sampleRate: Double = 48000.0, channels: UInt32 = 2) throws {
        self.fileURL = fileURL
        self.sampleRate = sampleRate
        self.channels = channels
        
        let directoryURL = fileURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directoryURL.path) {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        }
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try? FileManager.default.removeItem(at: fileURL)
        }
        
        // Output AAC destination format definition
        var dstFormat = AudioStreamBasicDescription()
        dstFormat.mFormatID = kAudioFormatMPEG4AAC
        dstFormat.mSampleRate = sampleRate
        dstFormat.mChannelsPerFrame = channels
        
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        AudioFormatGetProperty(kAudioFormatProperty_FormatInfo, 0, nil, &formatSize, &dstFormat)
        
        var audioFile: ExtAudioFileRef?
        var status = ExtAudioFileCreateWithURL(
            fileURL as CFURL,
            kAudioFileM4AType,
            &dstFormat,
            nil,
            AudioFileFlags.eraseFile.rawValue,
            &audioFile
        )
        
        guard status == noErr, let audioFile = audioFile else {
            throw NSError(
                domain: "SilentSpy.M4AWriter",
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "Failed to create M4A file at \(fileURL.path) (OSStatus: \(status))."]
            )
        }
        
        // Client PCM format (Float32, non-interleaved stereo: Buf[0] = Mic, Buf[1] = System)
        var srcFormat = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: channels,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        
        let clientFormatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        status = ExtAudioFileSetProperty(
            audioFile,
            kExtAudioFileProperty_ClientDataFormat,
            clientFormatSize,
            &srcFormat
        )
        
        guard status == noErr else {
            ExtAudioFileDispose(audioFile)
            throw NSError(
                domain: "SilentSpy.M4AWriter",
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "Failed to set client audio format for M4A writer (OSStatus: \(status))."]
            )
        }
        
        self.extAudioFile = audioFile
        self.isWriting = true
    }
    
    /// Writes dual-channel audio frames (Left = Mic, Right = System Audio) to the M4A encoder.
    public func writeInterleavedSamples(micSamples: [Float], sysSamples: [Float]) {
        guard isWriting else { return }
        
        writeQueue.async { [weak self] in
            guard let self = self, let extAudioFile = self.extAudioFile else { return }
            
            let frameCount = min(micSamples.count, sysSamples.count)
            guard frameCount > 0 else { return }
            
            var micArray = micSamples
            var sysArray = sysSamples
            
            micArray.withUnsafeMutableBufferPointer { micPtr in
                sysArray.withUnsafeMutableBufferPointer { sysPtr in
                    let ablPointer = AudioBufferList.allocate(maximumBuffers: 2)
                    defer {
                        free(UnsafeMutableRawPointer(ablPointer.unsafeMutablePointer))
                    }
                    
                    ablPointer[0] = AudioBuffer(
                        mNumberChannels: 1,
                        mDataByteSize: UInt32(frameCount * MemoryLayout<Float>.size),
                        mData: micPtr.baseAddress
                    )
                    ablPointer[1] = AudioBuffer(
                        mNumberChannels: 1,
                        mDataByteSize: UInt32(frameCount * MemoryLayout<Float>.size),
                        mData: sysPtr.baseAddress
                    )
                    
                    let status = ExtAudioFileWrite(extAudioFile, UInt32(frameCount), ablPointer.unsafePointer)
                    if status == noErr {
                        self.totalFramesWritten += Int64(frameCount)
                    } else {
                        print("SilentSpy: ExtAudioFileWrite error: \(status)")
                    }
                }
            }
        }
    }
    
    public func finish(completion: (() -> Void)? = nil) {
        writeQueue.async { [weak self] in
            guard let self = self else {
                completion?()
                return
            }
            if let extAudioFile = self.extAudioFile {
                ExtAudioFileDispose(extAudioFile)
                self.extAudioFile = nil
            }
            self.isWriting = false
            completion?()
        }
    }
    
    public var currentBytesWritten: UInt32 {
        if let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
           let size = attrs[.size] as? NSNumber {
            return size.uint32Value
        }
        // Approximate compressed stereo AAC size (~192 kbps = ~24 KB/s)
        let seconds = Double(totalFramesWritten) / sampleRate
        return UInt32(seconds * 24_000)
    }
    
    public var durationSeconds: Double {
        return Double(totalFramesWritten) / sampleRate
    }
}

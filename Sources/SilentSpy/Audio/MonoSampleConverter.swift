import Foundation
import AVFoundation
import CoreMedia
import Accelerate

/// One block of captured audio, normalised to mono Float32 at the target sample rate.
public struct CapturedAudio {
    public let samples: [Float]
    /// Presentation timestamp of the first sample (host clock). Invalid if the source provided none.
    public let presentationTime: CMTime
    public let rms: Float
    public let peak: Float
}

/// Converts captured `CMSampleBuffer`s of any linear-PCM layout (float/int, interleaved or not,
/// any channel count, any sample rate) into mono Float32 at `targetRate`.
///
/// Stateful: keep exactly one instance per capture stream. Sample-rate conversion uses a persistent
/// `AVAudioConverter`, so resampler phase and filter history carry across buffers — no per-buffer
/// truncation drift, no boundary discontinuities, and proper anti-aliasing when downsampling.
/// Not thread-safe; call it only from the stream's capture queue.
final class MonoSampleConverter {
    private let targetRate: Double
    private let outputFormat: AVAudioFormat

    private var cachedInputASBD: AudioStreamBasicDescription?
    private var inputFormat: AVAudioFormat?
    private var converter: AVAudioConverter?

    init(targetRate: Double) {
        self.targetRate = targetRate
        self.outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetRate,
            channels: 1,
            interleaved: false
        )!
    }

    /// Clears resampler state (call when a stream restarts, e.g. after a device change).
    func reset() {
        cachedInputASBD = nil
        inputFormat = nil
        converter = nil
    }

    func convert(_ sampleBuffer: CMSampleBuffer) -> CapturedAudio? {
        guard sampleBuffer.isValid,
              let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            return nil
        }
        let numFrames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard numFrames > 0 else { return nil }

        guard let inFormat = format(for: asbdPtr.pointee, description: formatDescription),
              let inBuffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(numFrames)) else {
            return nil
        }
        inBuffer.frameLength = AVAudioFrameCount(numFrames)
        let copyStatus = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(numFrames),
            into: inBuffer.mutableAudioBufferList
        )
        guard copyStatus == noErr else { return nil }

        let samples: [Float]
        if inFormat.commonFormat == .pcmFormatFloat32, abs(inFormat.sampleRate - targetRate) < 1.0 {
            samples = averageChannels(inBuffer)
        } else {
            guard let converted = resample(inBuffer, from: inFormat) else { return nil }
            samples = converted
        }
        guard !samples.isEmpty else { return nil }

        var rms: Float = 0
        var peak: Float = 0
        samples.withUnsafeBufferPointer { ptr in
            vDSP_rmsqv(ptr.baseAddress!, 1, &rms, vDSP_Length(ptr.count))
            vDSP_maxmgv(ptr.baseAddress!, 1, &peak, vDSP_Length(ptr.count))
        }

        return CapturedAudio(
            samples: samples,
            presentationTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
            rms: rms,
            peak: peak
        )
    }

    // MARK: - Private

    private func format(for asbd: AudioStreamBasicDescription, description: CMAudioFormatDescription) -> AVAudioFormat? {
        if let cached = cachedInputASBD, let fmt = inputFormat, Self.sameFormat(cached, asbd) {
            return fmt
        }
        // Input format changed (first buffer or device switch): rebuild the conversion chain.
        let fmt = AVAudioFormat(cmAudioFormatDescription: description)
        cachedInputASBD = asbd
        inputFormat = fmt
        converter = nil
        return fmt
    }

    private static func sameFormat(_ lhs: AudioStreamBasicDescription, _ rhs: AudioStreamBasicDescription) -> Bool {
        lhs.mSampleRate == rhs.mSampleRate
            && lhs.mFormatID == rhs.mFormatID
            && lhs.mFormatFlags == rhs.mFormatFlags
            && lhs.mBytesPerPacket == rhs.mBytesPerPacket
            && lhs.mFramesPerPacket == rhs.mFramesPerPacket
            && lhs.mBytesPerFrame == rhs.mBytesPerFrame
            && lhs.mChannelsPerFrame == rhs.mChannelsPerFrame
            && lhs.mBitsPerChannel == rhs.mBitsPerChannel
    }

    /// Fast path: Float32 already at the target rate — average channels into mono.
    private func averageChannels(_ buffer: AVAudioPCMBuffer) -> [Float] {
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard frames > 0, channels > 0, let data = buffer.floatChannelData else { return [] }

        var mono = [Float](repeating: 0, count: frames)
        mono.withUnsafeMutableBufferPointer { out in
            let outPtr = out.baseAddress!
            if buffer.format.isInterleaved {
                // Single buffer, samples strided by channel count.
                let src = data[0]
                for c in 0..<channels {
                    vDSP_vadd(src + c, vDSP_Stride(channels), outPtr, 1, outPtr, 1, vDSP_Length(frames))
                }
            } else {
                for c in 0..<channels {
                    vDSP_vadd(data[c], 1, outPtr, 1, outPtr, 1, vDSP_Length(frames))
                }
            }
            if channels > 1 {
                var scale = 1.0 / Float(channels)
                vDSP_vsmul(outPtr, 1, &scale, outPtr, 1, vDSP_Length(frames))
            }
        }
        return mono
    }

    /// General path: any PCM layout / rate → mono Float32 @ targetRate via a persistent converter.
    private func resample(_ buffer: AVAudioPCMBuffer, from inFormat: AVAudioFormat) -> [Float]? {
        if converter == nil {
            converter = AVAudioConverter(from: inFormat, to: outputFormat)
            converter?.downmix = true
            converter?.sampleRateConverterQuality = AVAudioQuality.high.rawValue
        }
        guard let converter = converter else { return nil }

        let ratio = targetRate / inFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return nil }

        var supplied = false
        var error: NSError?
        let status = converter.convert(to: outBuffer, error: &error) { _, inputStatus in
            if supplied {
                // `.noDataNow` (not `.endOfStream`) keeps the converter's internal state for the next buffer.
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, let channel = outBuffer.floatChannelData?[0] else { return nil }
        return Array(UnsafeBufferPointer(start: channel, count: Int(outBuffer.frameLength)))
    }
}

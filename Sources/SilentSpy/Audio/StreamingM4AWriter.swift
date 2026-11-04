import Foundation
import AVFoundation
import CoreMedia

/// Streaming AAC (.m4a) writer for dual-channel audio (Left: Mic, Right: System).
///
/// Crash-resilient: the file is written as a *fragmented* MPEG-4 (`movieFragmentInterval`), so if the
/// app crashes, is force-quit, or the Mac loses power, everything up to the last fragment (at most
/// `fragmentInterval` seconds ago) is still playable. A clean `finish` produces a normal, complete file.
///
/// All writer state is confined to `writeQueue`. The first failure (disk full, volume gone…) is
/// reported once via `onWriteError`, and further writes are skipped.
public final class StreamingM4AWriter: @unchecked Sendable { // state confined to writeQueue / statsLock
    public let fileURL: URL
    public let sampleRate: Double
    public let channels: UInt32

    /// Maximum audio lost on a crash.
    public static let fragmentInterval: Double = 3.0

    /// Called once, on the write queue, when encoding/writing fails.
    public var onWriteError: ((OSStatus) -> Void)?

    private let writeQueue = DispatchQueue(label: "com.silentspy.m4awriter", qos: .userInitiated)

    // writeQueue-confined
    private let assetWriter: AVAssetWriter
    private let input: AVAssetWriterInput
    private let pcmFormat: AVAudioFormat
    private var framesAppended: Int64 = 0
    private var hasFailed = false
    private var isFinished = false

    // Read from the main thread for UI, written on writeQueue
    private let statsLock = NSLock()
    private var _totalFramesWritten: Int64 = 0

    public init(fileURL: URL, sampleRate: Double = 48000.0, channels: UInt32 = 2) throws {
        self.fileURL = fileURL
        self.sampleRate = sampleRate
        self.channels = channels

        let directoryURL = fileURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directoryURL.path) {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        }
        // AVAssetWriter refuses to overwrite; callers pass unique URLs, but stay safe.
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }

        guard let pcmFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: AVAudioChannelCount(channels),
            interleaved: false
        ) else {
            throw Self.error(-50, "Unsupported PCM format (\(sampleRate) Hz, \(channels) ch).")
        }
        self.pcmFormat = pcmFormat

        let writer = try AVAssetWriter(outputURL: fileURL, fileType: .m4a)
        writer.movieFragmentInterval = CMTime(seconds: Self.fragmentInterval, preferredTimescale: 600)

        let input = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channels,
                AVEncoderBitRateKey: 192_000,
            ],
            sourceFormatHint: pcmFormat.formatDescription
        )
        input.expectsMediaDataInRealTime = true

        guard writer.canAdd(input) else {
            throw Self.error(-50, "Cannot add AAC audio input to M4A writer.")
        }
        writer.add(input)

        guard writer.startWriting() else {
            throw Self.error(-1, "Failed to start M4A writer at \(fileURL.path): \(writer.error?.localizedDescription ?? "unknown error").")
        }
        writer.startSession(atSourceTime: .zero)

        self.assetWriter = writer
        self.input = input
    }

    /// Queues dual-channel frames (Left = Mic, Right = System Audio) for encoding.
    public func write(micSamples: [Float], systemSamples: [Float]) {
        writeQueue.async { [self] in
            guard !hasFailed, !isFinished else { return }

            let frameCount = min(micSamples.count, systemSamples.count)
            guard frameCount > 0 else { return }

            guard let sampleBuffer = makeSampleBuffer(mic: micSamples, system: systemSamples, frames: frameCount) else {
                fail(-1)
                return
            }

            // Real-time input: wait briefly for the encoder if it's momentarily busy.
            var waited = 0
            while !input.isReadyForMoreMediaData && assetWriter.status == .writing && waited < 2000 {
                usleep(1000)
                waited += 1
            }

            guard assetWriter.status == .writing, input.append(sampleBuffer) else {
                fail(Self.status(of: assetWriter.error))
                return
            }

            framesAppended += Int64(frameCount)
            statsLock.lock()
            _totalFramesWritten = framesAppended
            statsLock.unlock()
        }
    }

    /// Finalizes the file. Completion (on the write queue) receives `noErr` on success.
    public func finish(completion: ((OSStatus) -> Void)? = nil) {
        writeQueue.async { [self] in
            guard !isFinished else {
                completion?(hasFailed ? -1 : noErr)
                return
            }
            isFinished = true

            guard assetWriter.status == .writing else {
                completion?(Self.status(of: assetWriter.error))
                return
            }

            input.markAsFinished()
            // Nothing written at all: still produce a valid (empty) file.
            assetWriter.endSession(atSourceTime: CMTime(value: framesAppended, timescale: CMTimeScale(sampleRate)))

            let done = DispatchSemaphore(value: 0)
            assetWriter.finishWriting { done.signal() }
            done.wait()

            if assetWriter.status == .completed && !hasFailed {
                completion?(noErr)
            } else {
                completion?(hasFailed ? -1 : Self.status(of: assetWriter.error))
            }
        }
    }

    public var totalFramesWritten: Int64 {
        statsLock.lock()
        defer { statsLock.unlock() }
        return _totalFramesWritten
    }

    public var durationSeconds: Double {
        Double(totalFramesWritten) / sampleRate
    }

    public var currentBytesWritten: UInt64 {
        if let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
           let size = attrs[.size] as? NSNumber {
            return size.uint64Value
        }
        return 0
    }

    // MARK: - Private (writeQueue)

    private func fail(_ status: OSStatus) {
        guard !hasFailed else { return }
        hasFailed = true
        onWriteError?(status)
    }

    private func makeSampleBuffer(mic: [Float], system: [Float], frames: Int) -> CMSampleBuffer? {
        guard let pcm = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: AVAudioFrameCount(frames)),
              let channelData = pcm.floatChannelData else { return nil }
        pcm.frameLength = AVAudioFrameCount(frames)
        mic.withUnsafeBufferPointer { channelData[0].update(from: $0.baseAddress!, count: frames) }
        if channels > 1 {
            system.withUnsafeBufferPointer { channelData[1].update(from: $0.baseAddress!, count: frames) }
        }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
            presentationTimeStamp: CMTime(value: framesAppended, timescale: CMTimeScale(sampleRate)),
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        var status = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: nil,
            dataReady: false,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: pcmFormat.formatDescription,
            sampleCount: CMItemCount(frames),
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let buffer = sampleBuffer else { return nil }

        status = CMSampleBufferSetDataBufferFromAudioBufferList(
            buffer,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            bufferList: pcm.audioBufferList
        )
        return status == noErr ? buffer : nil
    }

    private static func status(of error: Error?) -> OSStatus {
        guard let nsError = error as NSError? else { return -1 }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            return OSStatus(truncatingIfNeeded: underlying.code)
        }
        return OSStatus(truncatingIfNeeded: nsError.code)
    }

    private static func error(_ code: OSStatus, _ message: String) -> NSError {
        NSError(domain: "SilentSpy.M4AWriter", code: Int(code), userInfo: [NSLocalizedDescriptionKey: message])
    }
}

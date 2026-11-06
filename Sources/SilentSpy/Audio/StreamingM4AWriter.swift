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
///
/// Back-pressure: when the encoder is momentarily not ready (slow disk, I/O burst, busy CPU), encoded
/// input is held in a bounded backlog and retried — never appended while not ready, and a transient
/// stall never ends the recording. Only a backlog overflow (`maxBacklogSeconds`) is treated as fatal.
public final class StreamingM4AWriter: @unchecked Sendable { // state confined to writeQueue / statsLock
    public let fileURL: URL
    public let sampleRate: Double
    public let channels: UInt32

    /// Maximum audio lost on a crash.
    public static let fragmentInterval: Double = 3.0

    /// Audio held while the encoder is not ready before the stall is treated as a failure.
    public static let maxBacklogSeconds: Double = 30.0

    /// Called once, on the write queue, when encoding/writing fails.
    public var onWriteError: ((OSStatus) -> Void)?

    private let writeQueue = DispatchQueue(label: "com.silentspy.m4awriter", qos: .userInitiated)

    // writeQueue-confined
    private let assetWriter: AVAssetWriter
    private let input: AVAssetWriterInput
    private let pcmFormat: AVAudioFormat
    /// Frames handed to the encoder.
    private var framesAppended: Int64 = 0
    /// Frames turned into sample buffers (appended + backlog); next buffer's timestamp.
    private var framesQueued: Int64 = 0
    private var backlog: [(buffer: CMSampleBuffer, frames: Int64)] = []
    private var backlogFrames: Int64 = 0
    private var retryScheduled = false
    private var failureStatus: OSStatus?
    private var hasFailed: Bool { failureStatus != nil }
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

    /// Queues dual-channel frames (Left = Mic, Right = System Audio) for encoding. Never blocks.
    public func write(micSamples: [Float], systemSamples: [Float]) {
        writeQueue.async { [self] in
            guard !hasFailed, !isFinished else { return }

            let frameCount = min(micSamples.count, systemSamples.count)
            guard frameCount > 0 else { return }

            guard let sampleBuffer = makeSampleBuffer(mic: micSamples, system: systemSamples, frames: frameCount) else {
                fail(-1)
                return
            }
            backlog.append((sampleBuffer, Int64(frameCount)))
            backlogFrames += Int64(frameCount)
            framesQueued += Int64(frameCount)

            drainBacklog()
            guard !hasFailed else { return }
            if Double(backlogFrames) / sampleRate > Self.maxBacklogSeconds {
                fail(Self.encoderStalledStatus)
                return
            }
            scheduleRetryIfNeeded()
        }
    }

    /// Finalizes the file. Completion (on the write queue) receives `noErr` on success.
    public func finish(completion: ((OSStatus) -> Void)? = nil) {
        writeQueue.async { [self] in
            guard !isFinished else {
                completion?(failureStatus ?? noErr)
                return
            }
            isFinished = true

            guard assetWriter.status == .writing else {
                completion?(Self.status(of: assetWriter.error))
                return
            }

            // Drain whatever the encoder hasn't accepted yet (bounded wait: never hang shutdown).
            var waited = 0
            while !backlog.isEmpty && !hasFailed && assetWriter.status == .writing && waited < 10_000 {
                drainBacklog()
                if !backlog.isEmpty {
                    usleep(1000)
                    waited += 1
                }
            }
            let droppedTail = !backlog.isEmpty
            backlog.removeAll()
            backlogFrames = 0

            input.markAsFinished()
            // Nothing written at all: still produce a valid (empty) file.
            assetWriter.endSession(atSourceTime: CMTime(value: framesAppended, timescale: CMTimeScale(sampleRate)))

            let done = DispatchSemaphore(value: 0)
            assetWriter.finishWriting { done.signal() }
            done.wait()

            if let failure = failureStatus {
                completion?(failure)
            } else if assetWriter.status != .completed {
                completion?(Self.status(of: assetWriter.error))
            } else {
                completion?(droppedTail ? Self.encoderStalledStatus : noErr)
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
        failureStatus = status
        backlog.removeAll()
        backlogFrames = 0
        onWriteError?(status)
    }

    /// Appends backlog buffers, in order, while the encoder accepts them.
    private func drainBacklog() {
        while !backlog.isEmpty && !hasFailed {
            guard assetWriter.status == .writing else {
                fail(Self.status(of: assetWriter.error))
                return
            }
            guard input.isReadyForMoreMediaData else { return }
            let (buffer, frames) = backlog.removeFirst()
            backlogFrames -= frames
            guard input.append(buffer) else {
                fail(Self.status(of: assetWriter.error))
                return
            }
            framesAppended += frames
            statsLock.lock()
            _totalFramesWritten = framesAppended
            statsLock.unlock()
        }
    }

    /// While a backlog exists and no new audio arrives to trigger a drain, poll the encoder.
    private func scheduleRetryIfNeeded() {
        guard !backlog.isEmpty, !retryScheduled, !hasFailed, !isFinished else { return }
        retryScheduled = true
        writeQueue.asyncAfter(deadline: .now() + .milliseconds(10)) { [self] in
            retryScheduled = false
            guard !isFinished else { return }
            drainBacklog()
            scheduleRetryIfNeeded()
        }
    }

    private func makeSampleBuffer(mic: [Float], system: [Float], frames: Int) -> CMSampleBuffer? {
        guard let pcm = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: AVAudioFrameCount(frames)),
              let channelData = pcm.floatChannelData else { return nil }
        pcm.frameLength = AVAudioFrameCount(frames)
        mic.withUnsafeBufferPointer { channelData[0].initialize(from: $0.baseAddress!, count: frames) }
        if channels > 1 {
            system.withUnsafeBufferPointer { channelData[1].initialize(from: $0.baseAddress!, count: frames) }
        }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
            presentationTimeStamp: CMTime(value: framesQueued, timescale: CMTimeScale(sampleRate)),
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

    /// Status reported via `onWriteError` when the encoder backlog overflows `maxBacklogSeconds`.
    public static let encoderStalledStatus: OSStatus = 0x53_53_53_54 // 'SSST'

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

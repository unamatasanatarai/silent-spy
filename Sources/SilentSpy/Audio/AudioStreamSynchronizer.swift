import Foundation
import CoreMedia

/// Merges the asynchronous Microphone and System Audio streams into lockstep stereo frames
/// (L = mic, R = system) and feeds them to the M4A writer.
///
/// Alignment is driven by each buffer's presentation timestamp against ONE shared epoch (the host-clock
/// time the recording started), not by arrival order or by each stream's first buffer:
/// - A stream that starts late (capture startup latency, or ScreenCaptureKit delivering nothing until
///   something plays) gets leading silence of exactly the right length, so L and R stay time-aligned.
/// - Late delivery (scheduling jitter) does NOT insert silence — the samples are placed where their
///   timestamp says they belong, so jitter up to `maxLead` is absorbed by buffering.
/// - A genuine gap inside a stream (dropped buffers, device switch) is filled with silence of the
///   right length; an overlap (stream resuming after it was idle-padded) is trimmed.
/// - A stream that stops delivering entirely is padded once the other stream is more than `maxLead`
///   ahead, which also bounds memory.
///
/// All state is confined to `syncQueue`.
public final class AudioStreamSynchronizer: @unchecked Sendable { // state confined to syncQueue
    public enum Source { case mic, system }

    private struct Track {
        /// Pending samples are `storage[head...]`. Consumed samples are dropped lazily (see `compact`)
        /// so draining a chunk doesn't memmove the whole backlog on every callback.
        var storage: [Float] = []
        var head = 0
        /// Timestamp corresponding to frame position 0 of this track.
        var anchor: CMTime?
        /// True once the first real buffer has been placed (anchor validated).
        var hasReceivedAudio = false
        /// Frames placed into this track so far (written + buffered, including padding).
        var framesPlaced: Int64 = 0

        var count: Int { storage.count - head }

        mutating func appendSilence(_ frames: Int) {
            guard frames > 0 else { return }
            storage.append(contentsOf: repeatElement(0, count: frames))
            framesPlaced += Int64(frames)
        }

        mutating func consume(_ frames: Int) {
            head += frames
            // Compact only when the dead prefix is large: amortized O(1) per sample.
            if head >= 16_384 && head * 2 >= storage.count {
                storage.removeFirst(head)
                head = 0
            }
        }

        mutating func takeAll() -> [Float] {
            let out = Array(storage[head...])
            storage.removeAll(keepingCapacity: true)
            head = 0
            return out
        }
    }

    private let writer: StreamingM4AWriter
    private let sampleRate: Double
    private let syncQueue = DispatchQueue(label: "com.silentspy.audiosync", qos: .userInteractive)

    private var mic = Track()
    private var system = Track()

    private let chunkSize = 1024
    /// Timestamp disagreement tolerated before inserting silence / trimming (~21 ms @ 48 kHz).
    private let gapTolerance: Int64 = 1024
    /// How far one stream may run ahead before the other is presumed idle and padded (1 s).
    private let maxLead: Int
    /// A first buffer further than this from the epoch is assumed to use a foreign clock.
    private let maxStartOffset: Int64
    private var isFlushing = false

    /// - Parameter epoch: host-clock time at which the recording starts (frame 0 of both channels).
    ///   Pass `.invalid` to fall back to anchoring each stream at its first buffer.
    public init(writer: StreamingM4AWriter, epoch: CMTime, sampleRate: Double = AudioConfig.sampleRate) {
        self.writer = writer
        self.sampleRate = sampleRate
        self.maxLead = Int(sampleRate)
        self.maxStartOffset = Int64(sampleRate * 10)
        if epoch.isValid && epoch.isNumeric {
            mic.anchor = epoch
            system.anchor = epoch
        }
        mic.storage.reserveCapacity(maxLead * 2)
        system.storage.reserveCapacity(maxLead * 2)
    }

    public func append(_ audio: CapturedAudio, from source: Source) {
        // Strong capture: the synchronizer must outlive every queued block until flushed.
        syncQueue.async { [self] in
            guard !isFlushing else { return }
            switch source {
            case .mic: place(audio, into: &mic)
            case .system: place(audio, into: &system)
            }
            padIdleStream()
            drainCompleteChunks()
        }
    }

    /// Writes everything still buffered, finalizes the file, then calls `completion` on the main queue
    /// with the finalization status (`noErr` on success).
    public func flushAndFinish(completion: @escaping (OSStatus) -> Void) {
        syncQueue.async { [self] in
            isFlushing = true

            let maxCount = max(mic.count, system.count)
            if maxCount > 0 {
                mic.appendSilence(maxCount - mic.count)
                system.appendSilence(maxCount - system.count)
                writer.write(micSamples: mic.takeAll(), systemSamples: system.takeAll())
            }

            writer.finish { status in
                DispatchQueue.main.async { completion(status) }
            }
        }
    }

    // MARK: - Private (syncQueue)

    private func frames(from anchor: CMTime, to pts: CMTime) -> Int64 {
        Int64((CMTimeSubtract(pts, anchor).seconds * sampleRate).rounded())
    }

    private func place(_ audio: CapturedAudio, into track: inout Track) {
        var samples = audio.samples[...]
        let pts = audio.presentationTime

        if pts.isValid && pts.isNumeric {
            if !track.hasReceivedAudio {
                track.hasReceivedAudio = true
                // Shared epoch: the first buffer lands at its true offset from recording start. If the
                // timestamp is implausibly far from the epoch (foreign clock), or there is no epoch,
                // anchor it at the track's current end instead.
                let plausible = track.anchor.map { abs(frames(from: $0, to: pts) - track.framesPlaced) <= maxStartOffset } ?? false
                if !plausible {
                    track.anchor = CMTimeSubtract(pts, CMTime(value: track.framesPlaced, timescale: CMTimeScale(sampleRate)))
                }
            }
            if let anchor = track.anchor {
                let delta = frames(from: anchor, to: pts) - track.framesPlaced
                if delta > gapTolerance {
                    // Real gap (or late start): fill it so this audio stays at the right time.
                    track.appendSilence(Int(min(delta, Int64(maxLead * 10))))
                } else if delta < -gapTolerance {
                    // These samples cover time we already filled (idle padding, or captured before
                    // the epoch): drop the overlap.
                    let overlap = Int(min(-delta, Int64(samples.count)))
                    samples = samples.dropFirst(overlap)
                }
            }
        } else {
            track.hasReceivedAudio = true
        }

        track.storage.append(contentsOf: samples)
        track.framesPlaced += Int64(samples.count)
    }

    private func padIdleStream() {
        let lead = mic.count - system.count
        if lead > maxLead {
            system.appendSilence(lead)
        } else if -lead > maxLead {
            mic.appendSilence(-lead)
        }
    }

    private func drainCompleteChunks() {
        let available = min(mic.count, system.count)
        guard available >= chunkSize else { return }
        let frames = (available / chunkSize) * chunkSize

        writer.write(
            micSamples: Array(mic.storage[mic.head ..< mic.head + frames]),
            systemSamples: Array(system.storage[system.head ..< system.head + frames])
        )
        mic.consume(frames)
        system.consume(frames)
    }
}

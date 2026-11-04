import Foundation
import CoreMedia

/// Merges the asynchronous Microphone and System Audio streams into lockstep stereo frames
/// (L = mic, R = system) and feeds them to the M4A writer.
///
/// Alignment is driven by each buffer's presentation timestamp, not by arrival order:
/// - Late delivery (scheduling jitter) does NOT insert silence — the samples are placed where their
///   timestamp says they belong, so jitter up to `maxLead` is absorbed by buffering.
/// - A genuine gap inside a stream (dropped buffers, device switch) is filled with silence of the
///   right length; an overlap (stream resuming after it was idle-padded) is trimmed.
/// - A stream that stops delivering entirely (e.g. ScreenCaptureKit while nothing plays) is padded
///   once the other stream is more than `maxLead` ahead, which also bounds memory.
///
/// All state is confined to `syncQueue`.
public final class AudioStreamSynchronizer: @unchecked Sendable { // state confined to syncQueue
    public enum Source { case mic, system }

    private struct Track {
        var buffer: [Float] = []
        /// Timestamp corresponding to frame position 0 of this track.
        var anchor: CMTime?
        /// Frames placed into this track so far (written + buffered, including padding).
        var framesPlaced: Int64 = 0
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
    private var isFlushing = false

    public init(writer: StreamingM4AWriter, sampleRate: Double = AudioConfig.sampleRate) {
        self.writer = writer
        self.sampleRate = sampleRate
        self.maxLead = Int(sampleRate)
        mic.buffer.reserveCapacity(maxLead * 2)
        system.buffer.reserveCapacity(maxLead * 2)
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

            let maxCount = max(mic.buffer.count, system.buffer.count)
            if maxCount > 0 {
                mic.buffer.append(contentsOf: repeatElement(0, count: maxCount - mic.buffer.count))
                system.buffer.append(contentsOf: repeatElement(0, count: maxCount - system.buffer.count))
                writer.write(micSamples: mic.buffer, systemSamples: system.buffer)
                mic.buffer.removeAll()
                system.buffer.removeAll()
            }

            writer.finish { status in
                DispatchQueue.main.async { completion(status) }
            }
        }
    }

    // MARK: - Private (syncQueue)

    private func place(_ audio: CapturedAudio, into track: inout Track) {
        var samples = audio.samples[...]
        let pts = audio.presentationTime

        if pts.isValid && pts.isNumeric {
            if track.anchor == nil {
                // First real buffer: it lands at the current end of the track (after any idle padding).
                track.anchor = CMTimeSubtract(pts, CMTime(value: track.framesPlaced, timescale: CMTimeScale(sampleRate)))
            }
            if let anchor = track.anchor {
                let expected = Int64((CMTimeSubtract(pts, anchor).seconds * sampleRate).rounded())
                let delta = expected - track.framesPlaced
                if delta > gapTolerance {
                    // Real gap in this stream: fill it so later audio stays at the right time.
                    let pad = Int(min(delta, Int64(maxLead * 10)))
                    track.buffer.append(contentsOf: repeatElement(0, count: pad))
                    track.framesPlaced += Int64(pad)
                } else if delta < -gapTolerance {
                    // These samples cover time we already filled (idle padding): drop the overlap.
                    let overlap = Int(min(-delta, Int64(samples.count)))
                    samples = samples.dropFirst(overlap)
                }
            }
        }

        track.buffer.append(contentsOf: samples)
        track.framesPlaced += Int64(samples.count)
    }

    private func padIdleStream() {
        let lead = mic.buffer.count - system.buffer.count
        if lead > maxLead {
            system.buffer.append(contentsOf: repeatElement(0, count: lead))
            system.framesPlaced += Int64(lead)
        } else if -lead > maxLead {
            mic.buffer.append(contentsOf: repeatElement(0, count: -lead))
            mic.framesPlaced += Int64(-lead)
        }
    }

    private func drainCompleteChunks() {
        let available = min(mic.buffer.count, system.buffer.count)
        guard available >= chunkSize else { return }
        let frames = (available / chunkSize) * chunkSize

        writer.write(micSamples: Array(mic.buffer[0..<frames]), systemSamples: Array(system.buffer[0..<frames]))
        mic.buffer.removeFirst(frames)
        system.buffer.removeFirst(frames)
    }
}

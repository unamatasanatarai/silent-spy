import Foundation

/// Synchronizes separate asynchronous streams of Microphone and System Audio samples
/// into lockstep interleaved multi-channel audio frames and writes them directly to the M4A writer.
public final class AudioStreamSynchronizer {
    private let writer: StreamingM4AWriter
    private let syncQueue = DispatchQueue(label: "com.silentspy.audiosync", qos: .userInteractive)
    
    private var micBuffer: [Float] = []
    private var systemBuffer: [Float] = []
    
    private let chunkSize: Int = 1024
    private let maxBufferCapacity: Int = 48000 // 1 second safety threshold
    private var isFlushing: Bool = false
    
    public init(writer: StreamingM4AWriter) {
        self.writer = writer
        self.micBuffer.reserveCapacity(4096)
        self.systemBuffer.reserveCapacity(4096)
    }
    
    public func appendMicSamples(_ samples: [Float]) {
        syncQueue.async { [weak self] in
            guard let self = self, !self.isFlushing else { return }
            self.micBuffer.append(contentsOf: samples)
            self.processAvailableFrames()
        }
    }
    
    public func appendSystemSamples(_ samples: [Float]) {
        syncQueue.async { [weak self] in
            guard let self = self, !self.isFlushing else { return }
            self.systemBuffer.append(contentsOf: samples)
            self.processAvailableFrames()
        }
    }
    
    private func processAvailableFrames() {
        // If one buffer is advancing way ahead of the other (for instance, system audio is idle and not emitting buffers),
        // we synthesize silence for the lagging channel to keep both streams perfectly aligned in time.
        
        let diff = abs(micBuffer.count - systemBuffer.count)
        if diff > chunkSize * 2 {
            if micBuffer.count > systemBuffer.count {
                let padCount = micBuffer.count - systemBuffer.count
                systemBuffer.append(contentsOf: [Float](repeating: 0.0, count: padCount))
            } else {
                let padCount = systemBuffer.count - micBuffer.count
                micBuffer.append(contentsOf: [Float](repeating: 0.0, count: padCount))
            }
        }
        
        let availableFrames = min(micBuffer.count, systemBuffer.count)
        guard availableFrames >= chunkSize else { return }
        
        let framesToWrite = (availableFrames / chunkSize) * chunkSize
        
        let micChunk = Array(micBuffer[0..<framesToWrite])
        let sysChunk = Array(systemBuffer[0..<framesToWrite])
        
        micBuffer.removeFirst(framesToWrite)
        systemBuffer.removeFirst(framesToWrite)
        
        writer.writeInterleavedSamples(micSamples: micChunk, sysSamples: sysChunk)
    }
    
    public func flushAndFinish(completion: @escaping () -> Void) {
        syncQueue.async { [weak self] in
            guard let self = self else {
                completion()
                return
            }
            self.isFlushing = true
            
            // Equalize remaining buffers
            let maxCount = max(self.micBuffer.count, self.systemBuffer.count)
            if self.micBuffer.count < maxCount {
                self.micBuffer.append(contentsOf: [Float](repeating: 0.0, count: maxCount - self.micBuffer.count))
            }
            if self.systemBuffer.count < maxCount {
                self.systemBuffer.append(contentsOf: [Float](repeating: 0.0, count: maxCount - self.systemBuffer.count))
            }
            
            if maxCount > 0 {
                self.writer.writeInterleavedSamples(micSamples: self.micBuffer, sysSamples: self.systemBuffer)
                self.micBuffer.removeAll()
                self.systemBuffer.removeAll()
            }
            
            self.writer.finish {
                DispatchQueue.main.async {
                    completion()
                }
            }
        }
    }
}

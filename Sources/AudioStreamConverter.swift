import AVFoundation
import Speech

// AVAudioConverter is accessed only while holding this lock. Each yielded buffer
// is newly allocated and never mutated again after ownership passes to the stream.
final class AudioStreamConverter: @unchecked Sendable {
    private let lock = NSLock()
    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat
    private let sink: AsyncStream<AnalyzerInput>.Continuation
    init?(from input: AVAudioFormat, to output: AVAudioFormat, sink: AsyncStream<AnalyzerInput>.Continuation) {
        guard let converter = AVAudioConverter(from: input, to: output) else { return nil }
        self.converter = converter; self.outputFormat = output; self.sink = sink
    }
    func append(_ input: AVAudioPCMBuffer) throws {
        lock.lock(); defer { lock.unlock() }
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * outputFormat.sampleRate / input.format.sampleRate)) + 256
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }
        let provider = ConversionInput(input)
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, state in
            provider.next(state)
        }
        if let conversionError { throw conversionError }
        if status == .error { throw NSError(domain: "MyWispr.Audio", code: 1, userInfo: [NSLocalizedDescriptionKey: "Conversione audio fallita."]) }
        if output.frameLength > 0 { sink.yield(AnalyzerInput(buffer: output)) }
    }
}

// The synchronous converter may request input repeatedly; protect its one-shot state.
private final class ConversionInput: @unchecked Sendable {
    private let lock = NSLock()
    private let buffer: AVAudioPCMBuffer
    private var supplied = false
    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
    func next(_ state: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioPCMBuffer? {
        lock.lock(); defer { lock.unlock() }
        guard !supplied else { state.pointee = .noDataNow; return nil }
        supplied = true; state.pointee = .haveData; return buffer
    }
}

import AVFoundation
import CoreMedia
import CoreAudio
import Speech

// A device-specific, input-only capture session. Unlike AVAudioEngine, it never
// creates an output audio unit or opens the system's default Bluetooth microphone.
final class MicrophoneCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let control = DispatchQueue(label: "MyWispr.capture.control", qos: .userInitiated)
    private let samples = DispatchQueue(label: "MyWispr.capture.samples", qos: .userInitiated)
    private let outputFormat: AVAudioFormat
    private let sink: AsyncStream<AnalyzerInput>.Continuation
    private let meter: AudioLevelMailbox
    private let failure: @Sendable (String) -> Void
    private var converter: AudioStreamConverter?
    private var sourceFormat: AVAudioFormat?
    init(outputFormat: AVAudioFormat, sink: AsyncStream<AnalyzerInput>.Continuation, meter: AudioLevelMailbox, failure: @escaping @Sendable (String) -> Void) {
        self.outputFormat = outputFormat; self.sink = sink; self.meter = meter; self.failure = failure
    }
    static func selectedDevice(preferBuiltIn: Bool) -> AVCaptureDevice? {
        guard let id = AudioInputRouting.device(preferBuiltIn: preferBuiltIn) else { return nil }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &uid) == noErr, let uid else { return nil }
        return AVCaptureDevice(uniqueID: uid.takeRetainedValue() as String)
    }
    func start(preferBuiltIn: Bool) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            control.async {
                do {
                    guard let device = Self.selectedDevice(preferBuiltIn: preferBuiltIn) else { throw self.error("Microfono selezionato non disponibile.") }
                    let input = try AVCaptureDeviceInput(device: device)
                    self.session.beginConfiguration()
                    guard self.session.canAddInput(input) else { self.session.commitConfiguration(); throw self.error("Impossibile aprire il microfono.") }
                    self.session.addInput(input)
                    let output = AVCaptureAudioDataOutput()
                    output.audioSettings = [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMIsFloatKey: true, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsNonInterleaved: true]
                    output.setSampleBufferDelegate(self, queue: self.samples)
                    guard self.session.canAddOutput(output) else { self.session.commitConfiguration(); throw self.error("Impossibile acquisire l’audio.") }
                    self.session.addOutput(output); self.session.commitConfiguration()
                    self.session.startRunning()
                    guard self.session.isRunning else { throw self.error("Il microfono non è stato avviato.") }
                    continuation.resume()
                } catch { self.session.stopRunning(); continuation.resume(throwing: error) }
            }
        }
    }
    private func tearDown() {
        session.stopRunning()
        samples.sync {}
        disconnect()
    }
    private func disconnect() {
        session.beginConfiguration()
        for output in session.outputs {
            (output as? AVCaptureAudioDataOutput)?.setSampleBufferDelegate(nil, queue: nil)
            session.removeOutput(output)
        }
        for input in session.inputs { session.removeInput(input) }
        session.commitConfiguration()
    }
    func stop() { control.async { self.tearDown() } }
    func finish() async {
        await withCheckedContinuation { continuation in
            control.async {
                self.session.stopRunning()
                self.samples.sync {}
                continuation.resume()
                // Closing device objects must not delay the recognizer end-of-input.
                self.disconnect()
            }
        }
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) { process(sampleBuffer) }
    func process(_ sampleBuffer: CMSampleBuffer) {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        let count = CMSampleBufferGetNumSamples(sampleBuffer)
        guard count > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else { return }
        buffer.frameLength = AVAudioFrameCount(count)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(count), into: buffer.mutableAudioBufferList)
        guard status == noErr else { failure("Impossibile leggere il flusso del microfono."); return }
        do {
            if sourceFormat != format {
                guard let converter = AudioStreamConverter(from: format, to: outputFormat, sink: sink) else { throw error("Formato audio non supportato.") }
                self.converter = converter; self.sourceFormat = format
            }
            try converter?.append(buffer)
            if let channel = buffer.floatChannelData?[0] {
                var sum: Float = 0
                for index in 0..<count { sum += channel[index] * channel[index] }
                let rms = sqrt(sum / Float(count))
                meter.update(min(1, max(0, (Double(20 * log10(max(rms, 0.00001))) + 55) / 45)))
            }
        } catch { failure(error.localizedDescription) }
    }
    private func error(_ message: String) -> NSError { NSError(domain: "MyWispr.Capture", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

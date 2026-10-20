import SwiftUI
import AppKit

@MainActor
final class RecordingMeter: ObservableObject {
    @Published var level: Double = 0
}
struct RecordingWaveform: View {
    @ObservedObject var meter: RecordingMeter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let weights: [Double] = [0.35, 0.65, 0.9, 1, 0.8, 0.55, 0.3]
    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(weights.indices, id: \.self) { index in
                Capsule(style: .continuous).fill(.white)
                    .frame(width: 3, height: reduceMotion ? 10 : 3 + 17 * meter.level * weights[index])
            }
        }.frame(width: 40, height: 22)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.10), value: meter.level)
    }
}

// CoreAudio sound setup/playback can perform synchronous IPC when Bluetooth
// changes mode. Keep all NSSound work off the application's main thread.
final class SoundCue: @unchecked Sendable {
    private let queue = DispatchQueue(label: "MyWispr.sound", qos: .userInitiated)
    private var sound: NSSound?
    init(resource: String) {
        let url = Bundle.main.url(forResource: resource, withExtension: "wav")
        queue.async { if let url { self.sound = NSSound(contentsOf: url, byReference: false) } }
    }
    func play() { queue.async { self.sound?.stop(); self.sound?.volume = 0.7; self.sound?.play() } }
}

@MainActor
final class TranscriptionState: ObservableObject {
    @Published var text = ""
}
@MainActor
final class UIResponsivenessMonitor {
    private var task: Task<Void, Never>?
    private(set) var largestDelay: Double = 0
    func start() {
        task?.cancel(); largestDelay = 0
        let scheduled = ContinuousClock.now
        task = Task { [weak self] in
            var previous = scheduled
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
                guard let self else { return }
                let now = ContinuousClock.now
                let components = previous.duration(to: now).components
                let seconds = Double(components.seconds) + Double(components.attoseconds) / 1e18
                largestDelay = max(largestDelay, max(0, seconds - 0.05))
                previous = now
            }
        }
    }
    func stop() { task?.cancel(); task = nil }
}

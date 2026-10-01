import SwiftUI
import AppKit
import AVFoundation
import Speech
@preconcurrency import ApplicationServices

struct Usage: Codable, Identifiable {
    var id = UUID()
    let date: Date
    let words: Int
    let duration: Double
    let latency: Double
    let inserted: Bool
    var text: String? = nil
}

@MainActor
final class Dictation: ObservableObject {
    enum Phase { case idle, recording, finishing }
    @Published var phase: Phase = .idle
    @Published var message = "Pronto quando lo sei tu."
    @Published var transcript = ""
    @Published var audioLevel: Double = 0
    @Published var showsCopyPreview = false
    @Published var previewCopied = false
    @Published var holdHint: String?
    private var hintTask: Task<Void, Never>?
    private var pressedAt = ContinuousClock.now
    private var heldShortcut = "fn"
    @Published var history: [Usage] = []
    @Published var language = UserDefaults.standard.string(forKey: "language") ?? "it-IT"
    private let engine = AVAudioEngine()
    private let startSound: NSSound? = Bundle.main.url(forResource: "recording-start", withExtension: "wav").flatMap { NSSound(contentsOf: $0, byReference: false) }
    @Published var microphoneAllowed = false
    @Published var accessibilityAllowed = false
    @Published var modelReady = false
    @Published var modelStatus = "Preparazione modello…"
    private var transcriber: SpeechTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var audioFormat: AVAudioFormat?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var setupTask: Task<Void, Never>?
    private var committedText = ""
    private var pendingStart: Task<Void, Never>?
    private var permissionTimer: Timer?
    var permissionsReady: Bool { microphoneAllowed && accessibilityAllowed }
    private var silenceTask: Task<Void, Never>?
    private var lastSound = ContinuousClock.now
    private var deadline: Task<Void, Never>?
    private var session = UUID()
    private var started = Date()
    private var stopped = Date()
    private var target: NSRunningApplication?
    private var focusedField: AXUIElement?
    private var insertionMessage = ""
    private var tapInstalled = false
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var keyDown = false
    @Published private(set) var buttonRecording = false
    @Published var isStarting = false
    var showHUD: (() -> Void)?
    var hideHUD: (() -> Void)?
    var showCopyHUD: (() -> Void)?
    var showHintHUD: (() -> Void)?
    private let storage = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MyWispr/usage.json")

    init() {
        if let data = try? Data(contentsOf: storage), let saved = try? JSONDecoder().decode([Usage].self, from: data) { history = saved }
    }
    func installShortcut() {
        refreshPermissions()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { @Sendable [weak self] _ in
            Task { @MainActor in self?.refreshPermissions() }
        }
        prepareModel()
        guard globalMonitor == nil else { return }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown, .keyUp]) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown, .keyUp]) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return event
        }
    }
    private func handle(_ event: NSEvent) {
        guard !buttonRecording else { return }
        if event.type == .flagsChanged && event.keyCode == 63 {
            let pressed = event.modifierFlags.contains(.function)
            if pressed && !keyDown { keyboardPressed("fn") }
            if !pressed && keyDown { keyboardReleased() }
        } else if event.keyCode == 49 {
            if event.type == .keyDown && event.modifierFlags.contains(.option) && !event.isARepeat && !keyDown { keyboardPressed("⌥Spazio") }
            if event.type == .keyUp && keyDown { keyboardReleased() }
        }
    }
    private func keyboardPressed(_ shortcut: String) {
        keyDown = true; pressedAt = .now; heldShortcut = shortcut
        start()
    }
    private func keyboardReleased() {
        keyDown = false
        if pressedAt.duration(to: .now) < .milliseconds(350), transcript.isEmpty || isStarting || phase == .idle {
            if phase == .recording || pendingStart != nil { abort("Tieni premuto il tasto per registrare.") }
            showHoldHint()
        } else { stop() }
    }
    private func showHoldHint() {
        hintTask?.cancel()
        holdHint = heldShortcut
        showHintHUD?()
        hintTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(2500)) } catch { return }
            guard let self else { return }
            self.holdHint = nil
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            guard self.phase == .idle, !self.showsCopyPreview, self.holdHint == nil else { return }
            self.hideHUD?()
        }
    }
    func refreshPermissions() {
        microphoneAllowed = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        accessibilityAllowed = AXIsProcessTrusted()
    }
    func authorizeMicrophone() {
        refreshPermissions()
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { @Sendable [weak self] _ in
                Task { @MainActor in
                    self?.refreshPermissions()
                    self?.message = self?.microphoneAllowed == true ? "Microfono autorizzato." : "Abilita My Wispr in Privacy e sicurezza → Microfono."
                }
            }
        } else {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
        }
    }
    func authorizeAccessibility() {
        refreshPermissions()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        if !accessibilityAllowed {
            message = "Se My Wispr è già attiva in Accessibilità, rimuovi la vecchia voce con − e aggiungi questa app con +."
        }
    }
    func permissions() {
        refreshPermissions()
        if !microphoneAllowed { authorizeMicrophone() }
        else if !accessibilityAllowed { authorizeAccessibility() }
        else { message = "Microfono e Accessibilità sono autorizzati." }
    }
    func prepareModel() {
        guard phase == .idle else { return }
        setupTask?.cancel()
        modelReady = false; modelStatus = "Preparazione modello…"
        let selectedLanguage = language
        setupTask = Task { [weak self] in
            guard let self else { return }
            do {
                guard SpeechTranscriber.isAvailable,
                      let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: selectedLanguage)) else {
                    throw NSError(domain: "MyWispr", code: 1, userInfo: [NSLocalizedDescriptionKey: "Lingua non supportata dal motore locale."])
                }
                let module = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults, .fastResults], attributeOptions: [])
                try await AssetInventory.reserve(locale: locale)
                if let installation = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                    self.modelStatus = "Download del modello vocale…"
                    try await installation.downloadAndInstall()
                }
                guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
                    throw NSError(domain: "MyWispr", code: 2, userInfo: [NSLocalizedDescriptionKey: "Formato audio non disponibile."])
                }
                let analyzer = SpeechAnalyzer(modules: [module])
                try await analyzer.prepareToAnalyze(in: format)
                try Task.checkCancellation()
                guard self.language == selectedLanguage else { return }
                self.transcriber = module; self.audioFormat = format; self.analyzer = analyzer
                self.modelReady = true; self.modelStatus = "Modello locale pronto"

            } catch {
                guard !Task.isCancelled else { return }
                self.modelStatus = "Modello non pronto: \(error.localizedDescription)"
                self.message = self.modelStatus
            }
        }
    }
    func startFromButton() { start(fromButton: true) }
    func stopFromButton() { stop() }
    func start(fromButton: Bool = false) {
        guard phase == .idle, pendingStart == nil else { return }
        hintTask?.cancel(); holdHint = nil
        refreshPermissions()
        guard microphoneAllowed else { message = "Abilita il microfono nelle Impostazioni di Sistema."; return }
        guard modelReady, let transcriber, let analyzer, let audioFormat else { message = modelStatus; return }
        buttonRecording = fromButton
        isStarting = true
        dismissCopyPreview()
        target = NSWorkspace.shared.frontmostApplication
        focusedField = target.flatMap { editableField(from: focusedElement(in: $0)) }
        transcript = ""; committedText = ""
        let token = UUID(); session = token
        let (stream, sink) = AsyncStream<AnalyzerInput>.makeStream()
        continuation = sink
        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self, self.session == token, self.phase != .idle else { return }
                    let text = String(result.text.characters)
                    if !text.isEmpty && self.phase == .recording { self.lastSound = .now }
                    if result.isFinal {
                        self.committedText += text
                        self.transcript = self.committedText
                    } else { self.transcript = self.committedText + text }
                }
                self?.finish(token: token)
            } catch {
                guard let self, self.session == token, !Task.isCancelled else { return }
                self.abort("Riconoscimento interrotto: \(error.localizedDescription)")
            }
        }
        pendingStart = Task { [weak self] in
            guard let self else { return }
            do {
                try await analyzer.start(inputSequence: stream)
                guard self.session == token, (self.keyDown || self.buttonRecording), !Task.isCancelled else {
                    self.continuation?.finish(); self.pendingStart = nil; self.isStarting = false; self.buttonRecording = false
                    self.resultsTask?.cancel(); await analyzer.cancelAndFinishNow(); self.prepareModel(); return
                }
                let input = self.engine.inputNode
                let format = input.outputFormat(forBus: 0)
                guard format.sampleRate > 0, format.channelCount > 0,
                      let converter = AudioStreamConverter(from: format, to: audioFormat, sink: sink) else {
                    throw NSError(domain: "MyWispr", code: 3, userInfo: [NSLocalizedDescriptionKey: "Microfono o conversione audio non disponibile."])
                }
                input.installTap(onBus: 0, bufferSize: 1024, format: format) { @Sendable [weak self] buffer, _ in
                    do { try converter.append(buffer) }
                    catch {
                        let reason = error.localizedDescription
                        Task { @MainActor in
                            guard let self, self.session == token else { return }
                            self.abort("Errore audio: \(reason)")
                        }
                    }
                    guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
                    var sum: Float = 0
                    for index in 0..<Int(buffer.frameLength) { sum += samples[index] * samples[index] }
                    let rms = sqrt(sum / Float(buffer.frameLength))
                    let level = min(1, max(0, (Double(20 * log10(max(rms, 0.00001))) + 55) / 45))
                    Task { @MainActor in
                        guard let self, self.session == token, self.phase == .recording else { return }
                        self.audioLevel = level
                        if level > 0.22 { self.lastSound = .now }
                    }
                }
                self.tapInstalled = true
                self.engine.prepare(); try self.engine.start()
                self.started = Date(); self.phase = .recording; self.message = "Ti ascolto…"; self.showHUD?()
                self.lastSound = .now
                self.startSilenceWatchdog(token: token)
                self.startSound?.stop()
                self.startSound?.volume = 0.7
                self.startSound?.play()
                self.pendingStart = nil; self.isStarting = false
            } catch {
                guard self.session == token, !Task.isCancelled else { return }
                self.pendingStart = nil; self.isStarting = false
                self.abort("Impossibile avviare: \(error.localizedDescription)")
            }
        }
    }
    func stop() {
        buttonRecording = false
        if let pendingStart { pendingStart.cancel(); return }
        guard phase == .recording, let analyzer else { return }
        stopped = Date(); phase = .finishing; message = "Sto completando…"
        stopAudio(); continuation?.finish(); continuation = nil
        let token = session
        deadline = Task { [weak self] in
            do {
                try await analyzer.finalizeAndFinishThroughEndOfInput()
                await self?.resultsTask?.value
                self?.finish(token: token)
            } catch {
                guard let self, self.session == token, !Task.isCancelled else { return }
                self.abort("Trascrizione non completata: \(error.localizedDescription)")
            }
        }
    }
    private func startSilenceWatchdog(token: UUID) {
        silenceTask?.cancel()
        silenceTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                guard let self, self.session == token, self.phase == .recording else { return }
                if self.lastSound.duration(to: .now) > .seconds(10) {
                    self.stop()
                    self.message = "Registrazione terminata dopo 10 secondi di silenzio."
                    return
                }
            }
        }
    }
    private func stopAudio() {
        silenceTask?.cancel(); silenceTask = nil
        audioLevel = 0
        engine.stop()
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
    }
    private func finish(token: UUID) {
        guard session == token, phase == .finishing else { return }
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let latency = Date().timeIntervalSince(stopped)
        deadline?.cancel(); deadline = nil
        resultsTask?.cancel(); resultsTask = nil; analyzer = nil; transcriber = nil
        phase = .idle; hideHUD?(); prepareModel()
        guard !text.isEmpty else { message = "Nessuna parola riconosciuta. Riprova."; return }
        let inserted = insert(text)
        if !inserted { showsCopyPreview = true; showCopyHUD?() }
        history.insert(Usage(date: Date(), words: text.split(whereSeparator: { $0.isWhitespace }).count, duration: stopped.timeIntervalSince(started), latency: latency, inserted: inserted, text: text), at: 0)
        do {
            try FileManager.default.createDirectory(at: storage.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(history).write(to: storage, options: .atomic)
            message = insertionMessage
        } catch { message = "Testo pronto. Statistiche non salvate: \(error.localizedDescription)" }
    }
    private func abort(_ reason: String) {
        buttonRecording = false; isStarting = false
        session = UUID(); pendingStart?.cancel(); pendingStart = nil; deadline?.cancel(); stopAudio()
        continuation?.finish(); continuation = nil; resultsTask?.cancel(); resultsTask = nil
        if let analyzer { Task { await analyzer.cancelAndFinishNow() } }
        analyzer = nil; transcriber = nil
        phase = .idle; hideHUD?(); prepareModel(); message = reason
    }
    private func focusedElement(in app: NSRunningApplication) -> AXUIElement? {
        let application = AXUIElementCreateApplication(app.processIdentifier)
        // Electron and Chromium lazily expose their editable accessibility tree.
        _ = AXUIElementSetAttributeValue(application, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        _ = AXUIElementSetAttributeValue(application, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(application, kAXFocusedUIElementAttribute as CFString, &value) == .success,
           let value, CFGetTypeID(value) == AXUIElementGetTypeID() {
            return unsafeDowncast(value, to: AXUIElement.self)
        }
        value = nil
        guard AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let element = unsafeDowncast(value, to: AXUIElement.self)
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, pid == app.processIdentifier else { return nil }
        return element
    }
    private func editableField(from element: AXUIElement?) -> AXUIElement? {
        guard let element else { return nil }
        if isEditableField(element) { return element }
        // Some web editors report an inner focus node instead of their text area.
        var current = element
        for _ in 0..<6 {
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parent) == .success,
                  let parent, CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
            current = unsafeDowncast(parent, to: AXUIElement.self)
            if isEditableField(current) { return current }
        }
        return nil
    }
    private func fieldValue(_ field: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(field, kAXValueAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
    private func isEditableField(_ field: AXUIElement) -> Bool {
        var role: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(field, kAXRoleAttribute as CFString, &role)
        var editable: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(field, "AXEditable" as CFString, &editable)
        if let explicitlyEditable = editable as? Bool { return explicitlyEditable }
        // Native and web text inputs can accept paste without exposing writable
        // AXValue/AXSelectedText or a selected range. Their role is sufficient.
        if [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role as? String ?? "") { return true }
        var writable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(field, kAXSelectedTextAttribute as CFString, &writable) == .success, writable.boolValue { return true }
        var selectedRange: CFTypeRef?
        if AXUIElementCopyAttributeValue(field, "AXSelectedTextMarkerRange" as CFString, &selectedRange) == .success { return true }
        return false
    }
    private func insert(_ text: String) -> Bool {
        refreshPermissions()
        guard accessibilityAllowed else {
            insertionMessage = "Trascrizione pronta. Abilita Accessibilità per My Wispr per inserirla nelle altre app."
            return false
        }
        guard let target, target.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            insertionMessage = "Trascrizione pronta. Clicca in un campo di testo di un’altra app prima di dettare."
            return false
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier else {
            insertionMessage = "L’app attiva è cambiata: la trascrizione resta disponibile con Copia."
            return false
        }
        // Use the current caret in the original app; the nonactivating HUD never owns focus.
        var field = editableField(from: focusedElement(in: target))
        if field == nil, let captured = focusedField {
            var focused: CFTypeRef?
            if AXUIElementCopyAttributeValue(captured, kAXFocusedAttribute as CFString, &focused) == .success,
               focused as? Bool == true { field = captured }
        }
        guard let field else {
            insertionMessage = "Nessun campo di testo attivo: la trascrizione è pronta da copiare."
            return false
        }
        do {
            var role: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(field, kAXSubroleAttribute as CFString, &role)
            if role as? String == kAXSecureTextFieldSubrole {
                insertionMessage = "La trascrizione è pronta; questo campo è protetto."
                return false
            }
            var settable = DarwinBoolean(false)
            if AXUIElementIsAttributeSettable(field, kAXSelectedTextAttribute as CFString, &settable) == .success, settable.boolValue {
                let before = fieldValue(field)
                if AXUIElementSetAttributeValue(field, kAXSelectedTextAttribute as CFString, text as CFString) == .success {
                    let after = fieldValue(field)
                    if before == nil || after == nil || before != after {
                        insertionMessage = "Testo inserito in \(target.localizedName ?? "campo attivo")."
                        return true
                    }
                }
            }
        }
        // Standard paste works with browser editors, Electron apps and rich text fields
        // that do not implement writable AXSelectedText or Unicode key events.
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
            insertionMessage = "Impossibile inviare Incolla. La trascrizione è disponibile con Copia."
            return false
        }
        let pasteboard = NSPasteboard.general
        let previous = (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type -> (NSPasteboard.PasteboardType, Data)? in
                guard let data = item.data(forType: type) else { return nil }
                return (type, data)
            }
        }
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            insertionMessage = "Impossibile preparare Incolla. Usa Copia dalla finestra."
            return false
        }
        let changeCount = pasteboard.changeCount
        down.flags = .maskCommand; up.flags = .maskCommand
        down.postToPid(target.processIdentifier); up.postToPid(target.processIdentifier)
        insertionMessage = "Incolla inviato a \(target.localizedName ?? "campo attivo")."
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(800))
            // Do not overwrite anything the user copied in the meantime.
            guard pasteboard.changeCount == changeCount else { return }
            pasteboard.clearContents()
            let items = previous.map { values in
                let item = NSPasteboardItem()
                for (type, data) in values { item.setData(data, forType: type) }
                return item
            }
            if !items.isEmpty { pasteboard.writeObjects(items) }
        }
        return true
    }
    func dismissCopyPreview() { showsCopyPreview = false; previewCopied = false; hideHUD?() }
    func copyPreview() { copy(); previewCopied = true; message = "Trascrizione copiata." }
    func copy() { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(transcript, forType: .string) }
}

struct SpeedArc: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let radius = min((rect.width - 14) / 2, rect.height - 8)
        path.addArc(center: CGPoint(x: rect.midX, y: rect.maxY - 7), radius: radius, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
        return path
    }
}

struct Dashboard: View {
    @ObservedObject var model: Dictation
    private let teal = Color(red: 0.12, green: 0.12, blue: 0.12)
    private let canvas = Color(white: 0.97)
    private let cardColor = Color(white: 0.985)
    private var totalWords: Int { model.history.reduce(0) { $0 + $1.words } }
    private var totalSeconds: Double { model.history.reduce(0) { $0 + $1.duration } }
    private var wpm: Int { totalSeconds > 0 ? Int(Double(totalWords) / totalSeconds * 60) : 0 }
    private var latency: String { model.history.isEmpty ? "—" : String(format: "%.2f s", model.history.reduce(0) { $0 + $1.latency } / Double(model.history.count)) }
    private var dailyWords: [Date: Int] {
        Dictionary(grouping: model.history, by: { Calendar.current.startOfDay(for: $0.date) }).mapValues { $0.reduce(0) { $0 + $1.words } }
    }
    private var streak: Int {
        let calendar = Calendar.current
        var date = calendar.startOfDay(for: Date())
        if dailyWords[date] == nil { date = calendar.date(byAdding: .day, value: -1, to: date)! }
        var count = 0
        while dailyWords[date] != nil { count += 1; date = calendar.date(byAdding: .day, value: -1, to: date)! }
        return count
    }
    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 28) {
                Image(systemName: "waveform").font(.system(size: 25, weight: .bold)).padding(.top, 22)
                Image(systemName: "chart.bar.xaxis").font(.system(size: 20)).frame(width: 42, height: 42)
                    .background(Color.black.opacity(0.045), in: RoundedRectangle(cornerRadius: 10)).help("Il tuo utilizzo")
                Spacer()
                Image(systemName: "mic").foregroundStyle(teal).padding(.bottom, 22)
            }.frame(width: 68)
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    HStack {
                        Text("Insights").font(.system(size: 28, weight: .medium, design: .serif))
                        Spacer()
                        HStack(spacing: 6) { Circle().fill(teal).frame(width: 6, height: 6); Text("Tutto sul tuo Mac").font(.system(size: 12, weight: .medium)) }.foregroundStyle(teal)
                    }
                    VStack(alignment: .leading, spacing: 13) {
                        Text("Il tuo utilizzo").font(.system(size: 14, weight: .semibold))
                        ZStack(alignment: .leading) { Rectangle().fill(.black.opacity(0.07)).frame(height: 1); Rectangle().fill(.primary).frame(width: 100, height: 2) }
                    }
                    HStack(alignment: .top, spacing: 18) {
                        card {
                            Text("\(wpm)").font(.system(size: 31, weight: .medium, design: .serif))
                            caption("PAROLE AL MINUTO")
                            ZStack(alignment: .bottom) {
                                SpeedArc().stroke(teal.opacity(0.12), style: StrokeStyle(lineWidth: 12, lineCap: .round))
                                SpeedArc().trim(from: 0, to: min(1, Double(wpm) / 240)).stroke(teal, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                                VStack(spacing: 4) { Text("La tua velocità").font(.caption).foregroundStyle(.secondary); Text(model.history.isEmpty ? "Inizia a dettare" : "\(totalWords) parole").font(.system(size: 14, weight: .medium)) }.padding(.bottom, 2)
                            }.frame(width: 145, height: 84).padding(.top, 12)
                        }.frame(width: 210)
                        card {
                            Text("\(model.history.count)").font(.system(size: 31, weight: .medium, design: .serif))
                            caption("SESSIONI DI DETTATURA")
                            Divider().padding(.vertical, 12)
                            HStack { Text("Tempo di voce"); Spacer(); Text("\(Int(totalSeconds / 60)) min").fontWeight(.medium) }.font(.system(size: 13))
                            HStack { Text("Latenza media"); Spacer(); Text(latency).fontWeight(.medium) }.font(.system(size: 13)).padding(.top, 5)
                        }.frame(width: 235)
                        card {
                            Text(totalWords.formatted()).font(.system(size: 31, weight: .medium, design: .serif))
                            caption("PAROLE DETTATE IN TOTALE")
                            Divider().padding(.vertical, 12)
                            Text(model.history.isEmpty ? "Le tue idee iniziano con la voce." : "Le tue parole, senza interrompere il flusso.").font(.system(size: 14)).foregroundStyle(.secondary)
                            HStack { Image(systemName: "desktopcomputer"); Text("Desktop"); Spacer(); Text("100%") }.font(.system(size: 12, weight: .medium)).foregroundStyle(.white).padding(8).background(teal, in: RoundedRectangle(cornerRadius: 4)).padding(.top, 12)
                        }.frame(maxWidth: .infinity)
                    }
                    HStack(alignment: .top, spacing: 18) {
                        card {
                            HStack { Text("Attività recente").font(.system(size: 23, weight: .medium, design: .serif)); Spacer(); caption("ULTIME SESSIONI") }
                            if model.history.isEmpty {
                                VStack(spacing: 12) { Image(systemName: "waveform").font(.title).foregroundStyle(teal); Text("Non hai ancora dettato").font(.system(size: 14, weight: .medium)); Text("Tieni premuto fn in un campo di testo.\nLe tue sessioni appariranno qui.").font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center) }.frame(maxWidth: .infinity, minHeight: 190)
                            } else {
                                VStack(spacing: 15) {
                                    ForEach(Array(model.history.prefix(5))) { usage in
                                        HStack(spacing: 12) {
                                            Image(systemName: usage.inserted ? "text.cursor" : "doc.on.clipboard").foregroundStyle(teal).frame(width: 24)
                                            VStack(alignment: .leading, spacing: 3) { Text("\(usage.words) parole").font(.system(size: 14, weight: .medium)); Text(usage.date, format: .dateTime.day().month().hour().minute()).font(.caption).foregroundStyle(.secondary) }
                                            Spacer(); Text(String(format: "%.2f s", usage.latency)).font(.system(size: 13)).foregroundStyle(.secondary)
                                        }
                                    }
                                }.padding(.top, 17).frame(maxWidth: .infinity, minHeight: 190, alignment: .topLeading)
                            }
                        }.frame(maxWidth: .infinity)
                        card {
                            HStack { Text(streak == 1 ? "1 giorno di fila" : "\(streak) giorni di fila").font(.system(size: 23, weight: .medium, design: .serif)); Spacer() }
                            caption("LA TUA ATTIVITÀ · ULTIME 12 SETTIMANE").padding(.top, 3)
                            heatmap.padding(.top, 18)
                            HStack(spacing: 5) { Text("Meno").font(.caption).foregroundStyle(.secondary); ForEach(0..<4) { level in RoundedRectangle(cornerRadius: 3).fill(teal.opacity(level == 0 ? 0.08 : Double(level) / 3)).frame(width: 12, height: 12) }; Text("Più").font(.caption).foregroundStyle(.secondary); Spacer() }.padding(.top, 10)
                        }.frame(maxWidth: .infinity)
                    }
                    VStack(alignment: .leading, spacing: 18) {
                        HStack {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("Pronto a dettare").font(.system(size: 24, weight: .medium, design: .serif))
                                Text("Tieni premuto fn, oppure avvia dal notch. Stop automatico dopo 10 secondi di silenzio.").font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Picker("Lingua", selection: $model.language) { Text("Italiano").tag("it-IT"); Text("English").tag("en-US") }.frame(width: 175).disabled(model.phase != .idle)
                        }
                        HStack(spacing: 14) {
                            permissionCard("Microfono", detail: "Per ascoltare e trascrivere la tua voce.", icon: "mic", granted: model.microphoneAllowed, action: model.authorizeMicrophone)
                            permissionCard("Accessibilità", detail: "Per inserire il testo nel campo attivo.", icon: "text.cursor", granted: model.accessibilityAllowed, action: model.authorizeAccessibility)
                        }
                        HStack(spacing: 8) {
                            Image(systemName: model.modelReady ? "checkmark.circle" : "arrow.triangle.2.circlepath")
                            Text(model.modelStatus).font(.caption)
                            if !model.modelReady { Button("Riprova", action: model.prepareModel).controlSize(.small) }
                        }.foregroundStyle(.secondary)
                        Text(model.message).font(.system(size: 13)).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    VStack(alignment: .leading, spacing: 18) {
                        HStack {
                            Text("Trascrizioni").font(.system(size: 26, weight: .medium, design: .serif))
                            Spacer()
                            Text("\(model.history.count) sessioni").font(.caption).foregroundStyle(.secondary)
                        }
                        if model.history.isEmpty {
                            Text("La tua prima trascrizione apparirà qui.").font(.system(size: 14)).foregroundStyle(.secondary).padding(.vertical, 20)
                        } else {
                            LazyVStack(spacing: 12) {
                                ForEach(model.history) { usage in
                                    TranscriptRow(usage: usage)
                                }
                            }
                        }
                    }
                    Text("Audio non salvato. Trascrizioni e statistiche sono conservate solo sul tuo Mac.").font(.caption).foregroundStyle(.secondary)
                }.padding(36).frame(maxWidth: 1120).frame(maxWidth: .infinity)
            }
            .background(Color.white, in: RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(.black.opacity(0.05), lineWidth: 1))
            .padding(.trailing, 12).padding(.vertical, 12)
        }.background(canvas).foregroundStyle(Color(white: 0.10))
            .frame(minWidth: 960, minHeight: 650)
            .preferredColorScheme(.light)
            .onChange(of: model.language) { _, value in UserDefaults.standard.set(value, forKey: "language"); model.prepareModel() }
    }
    private func permissionCard(_ title: String, detail: String, icon: String, granted: Bool, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: icon).font(.system(size: 17)).frame(width: 32, height: 32).background(Color.black.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                Text(title).font(.system(size: 14, weight: .semibold))
                Spacer()
                Label(granted ? "Autorizzato" : "Da attivare", systemImage: granted ? "checkmark" : "circle")
                    .font(.system(size: 10, weight: .medium)).padding(.horizontal, 9).padding(.vertical, 5)
                    .background(Color.black.opacity(granted ? 0.07 : 0.03), in: Capsule())
            }
            Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
            if !granted {
                Button("Autorizza \(title.lowercased())", action: action).buttonStyle(DashboardButtonStyle())
            } else {
                Text("Tutto pronto").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }.padding(18).frame(maxWidth: .infinity, minHeight: 144, alignment: .topLeading)
        .background(.white, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.black.opacity(0.09)))
    }
    private func caption(_ text: String) -> some View { Text(text).font(.system(size: 10, weight: .medium)).tracking(0.7).foregroundStyle(.secondary) }
    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8, content: content).padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: 200, alignment: .topLeading)
            .background(LinearGradient(colors: [.white, cardColor], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.black.opacity(0.08), lineWidth: 1))
    }
    private var heatmap: some View {
        let calendar = Calendar.current
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: Date())!.start
        let first = calendar.date(byAdding: .day, value: -77, to: weekStart)!
        let maximum = max(1, dailyWords.values.max() ?? 1)
        return HStack(spacing: 5) {
            ForEach(0..<12) { week in
                VStack(spacing: 5) {
                    ForEach(0..<7) { weekday in
                        let date = calendar.date(byAdding: .day, value: week * 7 + weekday, to: first)!
                        let words = dailyWords[date] ?? 0
                        RoundedRectangle(cornerRadius: 3)
                            .fill(teal.opacity(words == 0 ? 0.08 : 0.3 + 0.7 * Double(words) / Double(maximum)))
                            .frame(maxWidth: .infinity).aspectRatio(1, contentMode: .fit)
                            .opacity(date > Date() ? 0.25 : 1)
                            .help("\(date.formatted(date: .abbreviated, time: .omitted)): \(words) parole")
                    }
                }
            }
        }.frame(maxHeight: 164)
    }
}

struct DashboardButtonStyle: ButtonStyle {
    @State private var hovered = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white).padding(.horizontal, 14).padding(.vertical, 8)
            .background(Color.black.opacity(configuration.isPressed ? 0.7 : hovered ? 0.85 : 1), in: RoundedRectangle(cornerRadius: 7))
            .onHover { hovered = $0 }
    }
}

struct TranscriptRow: View {
    let usage: Usage
    @State private var copied = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(usage.date, format: .dateTime.day().month().year().hour().minute()).font(.system(size: 11)).foregroundStyle(.secondary)
                Text("· \(usage.words) parole").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                if let text = usage.text {
                    Button {
                        NSPasteboard.general.clearContents()
                        copied = NSPasteboard.general.setString(text, forType: .string)
                    } label: { Label(copied ? "Copiato" : "Copia", systemImage: copied ? "checkmark" : "doc.on.doc") }
                    .buttonStyle(DashboardButtonStyle())
                }
            }
            Text(usage.text ?? "Testo non disponibile: questa sessione è precedente alla cronologia delle trascrizioni.")
                .font(.system(size: 14)).lineSpacing(4).textSelection(.enabled)
                .foregroundStyle(usage.text == nil ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }.padding(18).background(LinearGradient(colors: [.white, Color(white: 0.99)], startPoint: .top, endPoint: .bottom), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.black.opacity(0.08)))
    }
}

struct NotchButtonStyle: ButtonStyle {
    var lightSurface = false
    var filled = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background((lightSurface ? Color.black : Color.white).opacity(configuration.isPressed ? 0.22 : hovered ? 0.16 : filled ? 0.09 : 0), in: Capsule(style: .continuous))
            .clipShape(Capsule(style: .continuous))
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(.easeOut(duration: 0.15), value: hovered)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: configuration.isPressed)
            .onHover { inside in
                guard hovered != inside else { return }
                hovered = inside
                if inside { NSCursor.pointingHand.push() }
                else { NSCursor.pop() }
            }
            .onDisappear {
                if hovered { NSCursor.pop(); hovered = false }
            }
    }
}

struct RecordingHUD: View {
    @ObservedObject var model: Dictation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let weights: [Double] = [0.35, 0.65, 0.9, 1, 0.8, 0.55, 0.3]
    @State private var hovered = false
    private var listening: Bool { model.phase == .recording }
    private var expanded: Bool { hovered || listening || model.isStarting || model.holdHint != nil }
    private var notchWidth: CGFloat { model.holdHint != nil ? 350 : listening ? (model.buttonRecording ? 106 : 82) : 112 }
    var body: some View {
        ZStack(alignment: .bottom) {
            if model.showsCopyPreview {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Label("Trascrizione pronta", systemImage: "text.bubble.fill").font(.system(size: 13, weight: .semibold))
                        Spacer()
                        Button(action: model.dismissCopyPreview) { Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).frame(width: 24, height: 24) }
                            .buttonStyle(NotchButtonStyle(lightSurface: true)).accessibilityLabel("Chiudi trascrizione").help("Chiudi")
                    }
                    ScrollView {
                        Text(model.transcript).font(.system(size: 15)).lineSpacing(3)
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 100)
                    HStack {
                        Spacer()
                        Button(action: model.copyPreview) {
                            Label(model.previewCopied ? "Copiato" : "Copia", systemImage: model.previewCopied ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 13, weight: .semibold))
                                .frame(width: 104, height: 32).contentShape(Capsule(style: .continuous))
                        }
                        .buttonStyle(NotchButtonStyle(lightSurface: true, filled: true))
                        .accessibilityLabel(model.previewCopied ? "Trascrizione copiata" : "Copia trascrizione")
                    }
                }
                .padding(20).frame(width: 360, height: 200)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 26, style: .continuous))

                .transition(reduceMotion ? .opacity : .scale(scale: 0.92, anchor: .bottom).combined(with: .opacity))
            }
            ZStack(alignment: .bottom) {
            Capsule(style: .continuous).fill(.black.opacity(0.96))
                .frame(width: expanded ? notchWidth : 48, height: model.holdHint != nil ? 48 : expanded ? 32 : 6)
            HStack(spacing: 5) {
                if let shortcut = model.holdHint {
                    HStack(spacing: 5) {
                        Text("Tieni premuto il tasto")
                        Text(shortcut).fontWeight(.semibold)
                        Text("per registrare")
                    }.font(.system(size: 12))
                } else if model.phase == .finishing || model.isStarting {
                    ProgressView().controlSize(.small).tint(.white)
                    Text(model.isStarting ? "Avvio…" : "Trascrivo…").font(.system(size: 13, weight: .medium))
                } else {
                    if listening {
                        Image(systemName: "mic.fill").font(.system(size: 14, weight: .medium)).frame(width: 24, height: 24)
                        HStack(spacing: 2.5) {
                            ForEach(weights.indices, id: \.self) { index in
                                Capsule(style: .continuous).fill(.white)
                                    .frame(width: 3, height: reduceMotion ? 10 : 3 + 17 * model.audioLevel * weights[index])
                            }
                        }.frame(width: 40, height: 22)
                            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: model.audioLevel)
                        if model.buttonRecording {
                        Button(action: model.stopFromButton) {
                            Image(systemName: "stop.fill").font(.system(size: 11, weight: .semibold))
                                .frame(width: 24, height: 24)
                        }.buttonStyle(NotchButtonStyle(filled: true)).accessibilityLabel("Stop registrazione").help("Stop")
                        }
                    } else {
                        Button(action: model.startFromButton) {
                            HStack(spacing: 6) {
                                Image(systemName: "mic.fill").font(.system(size: 14, weight: .medium))
                                Text("Registra").font(.system(size: 12, weight: .medium))
                            }.frame(width: 112, height: 32).contentShape(Capsule(style: .continuous))
                        }.buttonStyle(NotchButtonStyle()).accessibilityLabel("Avvia registrazione").help("Avvia registrazione")
                    }
                }
            }
            .foregroundStyle(.white)
            .opacity(expanded ? 1 : 0)
            .allowsHitTesting(expanded)
            .frame(width: notchWidth, height: model.holdHint != nil ? 48 : 32)
        }
        .frame(width: notchWidth, height: model.holdHint != nil ? 48 : 32)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .opacity(model.showsCopyPreview ? 0 : 1)
            }
        .animation(reduceMotion ? .linear(duration: 0.15) : .timingCurve(0.23, 1, 0.32, 1, duration: 0.2), value: expanded)
        .animation(reduceMotion ? .linear(duration: 0.15) : .spring(response: 0.35, dampingFraction: 1), value: model.showsCopyPreview)
        .animation(reduceMotion ? .linear(duration: 0.15) : .spring(response: 0.35, dampingFraction: 1), value: model.holdHint)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 6)
        .accessibilityLabel(listening ? "Microfono attivo, ascolto in corso" : "Dettatura pronta")
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = Dictation()
    private var panel: NSPanel?
    func applicationDidFinishLaunching(_ notification: Notification) {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 148, height: 48), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.hasShadow = false; panel.hidesOnDeactivate = false; panel.isOpaque = false; panel.backgroundColor = .clear; panel.level = .floating; panel.ignoresMouseEvents = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: RecordingHUD(model: model)); self.panel = panel
        model.showHUD = { [weak panel] in
            if let screen = NSScreen.main { panel?.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - 74, y: screen.visibleFrame.minY + 12)) }
            panel?.orderFrontRegardless()
        }
        model.hideHUD = { [weak panel] in
            guard let panel else { return }
            let center = panel.frame.midX; let bottom = panel.frame.minY
            panel.ignoresMouseEvents = false
            panel.setFrame(NSRect(x: center - 74, y: bottom, width: 148, height: 48), display: true)
            panel.orderFrontRegardless()
        }
        model.showHintHUD = { [weak panel] in
            guard let panel else { return }
            let center = panel.frame.midX; let bottom = panel.frame.minY
            panel.setFrame(NSRect(x: center - 185, y: bottom, width: 370, height: 68), display: true)
            panel.orderFrontRegardless()
        }
        model.showCopyHUD = { [weak panel] in
            guard let panel else { return }
            let center = panel.frame.midX; let bottom = panel.frame.minY
            panel.setFrame(NSRect(x: center - 210, y: bottom, width: 420, height: 240), display: true)
            panel.ignoresMouseEvents = false
            panel.orderFrontRegardless()
        }
        model.showHUD?()
        model.installShortcut()
    }
    func applicationDidBecomeActive(_ notification: Notification) { model.refreshPermissions() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
struct MyWisprApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        WindowGroup("My Wispr") { Dashboard(model: delegate.model) }.defaultSize(width: 1120, height: 850)
            .windowToolbarStyle(.unifiedCompact)
        MenuBarExtra("My Wispr", systemImage: "waveform") {
            Button("Apri statistiche") { NSApp.activate(ignoringOtherApps: true); NSApp.windows.first(where: { !($0 is NSPanel) })?.makeKeyAndOrderFront(nil) }
            Text(delegate.model.message)
            Button("Abilita permessi", action: delegate.model.permissions)
            Divider()
            Button("Esci") { NSApp.terminate(nil) }
        }
    }
}

import SwiftUI
import AppKit
import AVFoundation
import Speech
import ServiceManagement
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

struct ShortcutBinding: Codable {
    var keyCode: UInt16
    var modifiers: UInt
    var label: String
    var isModifier: Bool
    static let fn = ShortcutBinding(keyCode: 63, modifiers: 0, label: "fn", isModifier: true)
}

@MainActor
final class Dictation: ObservableObject {
    @Published var clipboardEnabled = UserDefaults.standard.bool(forKey: "clipboardEnabled") { didSet { UserDefaults.standard.set(clipboardEnabled, forKey: "clipboardEnabled"); if !clipboardEnabled { closeClipboard() } } }
    @Published var clipboardItems: [String] = []
    @Published var clipboardZoomAnchor = UnitPoint.bottom
    var clipboardButtonOffset: CGFloat = 28
    var clipboardButtonHeight: CGFloat = 9
    @Published var showsClipboard = false
    @Published var clipboardSelection = 0
    @Published var clipboardBinding = UserDefaults.standard.data(forKey: "clipboardBinding").flatMap { try? JSONDecoder().decode(ShortcutBinding.self, from: $0) }
    @Published var captureClipboardBinding = false
    private var clipboardTimer: Timer?
    private var clipboardCount = NSPasteboard.general.changeCount
    private var lastShiftTap: TimeInterval = 0
    private var shiftStarted: TimeInterval = 0
    private var shiftChord = false
    private var clipboardTarget: NSRunningApplication?
    var showClipboardHUD: (() -> Void)?
    var closeClipboardHUD: (() -> Void)?
    func pollClipboard() {
        guard clipboardEnabled else { clipboardCount = NSPasteboard.general.changeCount; return }
        let board = NSPasteboard.general
        guard board.changeCount != clipboardCount else { return }
        clipboardCount = board.changeCount
        // Password managers mark confidential clipboard content with these types.
        guard !(board.types ?? []).contains(where: { $0.rawValue == "org.nspasteboard.ConcealedType" || $0.rawValue == "org.nspasteboard.TransientType" }),
              let text = board.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        clipboardItems.removeAll { $0 == text }
        clipboardItems.insert(text, at: 0)
        clipboardItems = Array(clipboardItems.prefix(40))
    }
    func openClipboard() {
        guard clipboardEnabled, phase == .idle, !isStarting, !showsCopyPreview else { return }
        if showsClipboard { closeClipboard(); return }
        pollClipboard()
        clipboardTarget = NSWorkspace.shared.frontmostApplication
        clipboardSelection = 0
        showClipboardHUD?()
        showsClipboard = true
        if soundEnabled { clipboardSound?.stop(); clipboardSound?.volume = 0.7; clipboardSound?.play() }
    }
    func closeClipboard() {
        guard showsClipboard else { return }
        showsClipboard = false
        closeClipboardHUD?()
    }
    func clipboardKey(_ code: UInt16) {
        switch code {
        case 125: clipboardSelection = min(max(0, clipboardItems.count - 1), clipboardSelection + 1)
        case 126: clipboardSelection = max(0, clipboardSelection - 1)
        case 53: closeClipboard()
        case 36: pasteClipboard()
        default: break
        }
    }
    func pasteClipboard() {
        guard clipboardItems.indices.contains(clipboardSelection) else { return }
        let text = clipboardItems[clipboardSelection]
        let destination = clipboardTarget
        let board = NSPasteboard.general
        board.clearContents(); board.setString(text, forType: .string)
        clipboardCount = board.changeCount
        closeClipboard()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            guard !self.showsClipboard, self.phase == .idle else { return }
            self.notchNotice = "Copiato"
            self.hideHUD?()
            try? await Task.sleep(for: .seconds(2.5))
            self.notchNotice = nil
        }
        guard let destination, !destination.isTerminated else { return }
        destination.activate()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == destination.processIdentifier,
                  let source = CGEventSource(stateID: .privateState),
                  let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else { return }
            down.flags = .maskCommand; up.flags = .maskCommand
            down.postToPid(destination.processIdentifier); up.postToPid(destination.processIdentifier)
        }
    }
    enum Phase { case idle, recording, finishing }
    @Published var phase: Phase = .idle
    @Published var message = "Pronto quando lo sei tu."
    let notes = NotesStore()
    @Published var noteRecordingID: UUID?
    private var noteBase = ""
    private var noteTranscriptBase = ""
    var openNotes: (() -> Void)?
    func startNote(_ id: UUID) {
        guard phase == .idle, !isStarting, modelReady, microphoneAllowed, let note = notes.notes.first(where: { $0.id == id }) else { return }
        noteRecordingID = id; noteBase = note.body; noteTranscriptBase = note.transcript
        start(fromButton: true)
        if !isStarting && phase == .idle { noteRecordingID = nil }
    }
    @Published var transcript = "" {
        didSet {
            if let id = noteRecordingID {
                notes.update(id) { note in
                    note.body = noteBase + (noteBase.isEmpty || transcript.isEmpty ? "" : "\n\n") + transcript
                    note.transcript = noteTranscriptBase + (noteTranscriptBase.isEmpty || transcript.isEmpty ? "" : "\n\n") + transcript
                }
            }
        }
    }
    @Published var audioLevel: Double = 0
    @Published var showsCopyPreview = false
    @Published var previewCopied = false
    @Published var notchNotice: String?
    @Published var holdHint: String?
    private var hintTask: Task<Void, Never>?
    private var pressedAt = ContinuousClock.now
    private var heldShortcut = "fn"
    @Published var history: [Usage] = []
    @Published var shortcut = (UserDefaults.standard.data(forKey: "shortcut").flatMap { try? JSONDecoder().decode(ShortcutBinding.self, from: $0) }) ?? .fn {
        didSet { if let data = try? JSONEncoder().encode(shortcut) { UserDefaults.standard.set(data, forKey: "shortcut") } }
    }
    @Published var shortcutEnabled = UserDefaults.standard.object(forKey: "shortcutEnabled") as? Bool ?? true { didSet { UserDefaults.standard.set(shortcutEnabled, forKey: "shortcutEnabled") } }
    @Published var soundEnabled = UserDefaults.standard.object(forKey: "soundEnabled") as? Bool ?? true { didSet { UserDefaults.standard.set(soundEnabled, forKey: "soundEnabled") } }
    @Published var silenceSeconds = UserDefaults.standard.object(forKey: "silenceSeconds") as? Double ?? 10 { didSet { UserDefaults.standard.set(silenceSeconds, forKey: "silenceSeconds") } }
    @Published var capturingShortcut = false
    @Published private(set) var launchAtLogin = false
    @Published private(set) var loginNeedsApproval = false
    @Published private(set) var loginError: String?
    func refreshLoginStatus() {
        let status = SMAppService.mainApp.status
        launchAtLogin = status == .enabled || status == .requiresApproval
        loginNeedsApproval = status == .requiresApproval
    }
    func setLaunchAtLogin(_ enabled: Bool) {
        loginError = nil
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch { loginError = "Impossibile aggiornare l’avvio al login: \(error.localizedDescription)" }
        refreshLoginStatus()
    }
    @Published var language = UserDefaults.standard.string(forKey: "language") ?? "it-IT"
    private let engine = AVAudioEngine()
    private let clipboardSound: NSSound? = Bundle.main.url(forResource: "clipboard-open", withExtension: "wav").flatMap { NSSound(contentsOf: $0, byReference: false) }
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
    private var fnChord = false
    private var mediaTap: CFMachPort?
    private var mediaSource: CFRunLoopSource?
    @Published private(set) var buttonRecording = false
    @Published var isStarting = false
    @Published var notchScreenID = UserDefaults.standard.string(forKey: "notchScreenID") ?? "" {
        didSet { UserDefaults.standard.set(notchScreenID, forKey: "notchScreenID"); resetHUDPosition?() }
    }
    var notchScreen: NSScreen? {
        NSScreen.screens.first { Self.screenID($0) == notchScreenID } ?? NSScreen.main ?? NSScreen.screens.first
    }
    static func screenID(_ screen: NSScreen) -> String { (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.stringValue ?? "" }
    var resetHUDPosition: (() -> Void)?
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
            Task { @MainActor in self?.refreshPermissions(); self?.pollClipboard() }
        }
        clipboardTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { @Sendable [weak self] _ in Task { @MainActor in self?.pollClipboard() } }
        prepareModel()
        installMediaObserver()
        guard globalMonitor == nil else { return }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown, .keyUp]) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown, .keyUp]) { [weak self] event in
            let capturing = MainActor.assumeIsolated {
                let capturing = (self?.capturingShortcut ?? false) || (self?.showsClipboard ?? false)
                self?.handle(event)
                return capturing
            }
            return capturing ? nil : event
        }
    }
    private func installMediaObserver() {
        guard mediaTap == nil else { return }
        // Observe macOS media-key events without consuming or remapping them.
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly, eventsOfInterest: CGEventMask(1) << 14, callback: { _, type, event, context in
            if type.rawValue == 14, let native = NSEvent(cgEvent: event), native.subtype.rawValue == 8,
               ((native.data1 >> 8) & 0xff) == 0x0a, let context {
                let model = Unmanaged<Dictation>.fromOpaque(context).takeUnretainedValue()
                Task { @MainActor in model.cancelFnChord() }
            }
            return Unmanaged.passUnretained(event)
        }, userInfo: context) else { return }
        mediaTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        mediaSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }
    private func cancelFnChord() {
        guard keyDown, shortcut.keyCode == 63, !buttonRecording, !fnChord else { return }
        fnChord = true
        hintTask?.cancel(); holdHint = nil
        if phase == .recording || pendingStart != nil { abort("Combinazione Fn: dettatura annullata.") }
        transcript = ""; hideHUD?()
    }
    private func modifierFlag(for code: UInt16) -> NSEvent.ModifierFlags {
        switch code { case 63: .function; case 61, 58: .option; case 62, 59: .control; case 60, 56: .shift; case 54, 55: .command; default: [] }
    }
    private func handle(_ event: NSEvent) {
        if showsClipboard { if event.type == .keyDown { clipboardKey(event.keyCode) }; return }
        if clipboardEnabled, !capturingShortcut {
            if let binding = clipboardBinding {
                if binding.isModifier, event.type == .flagsChanged, event.keyCode == binding.keyCode, event.modifierFlags.contains(modifierFlag(for: binding.keyCode)) { openClipboard(); return }
                if !binding.isModifier, event.type == .keyDown, !event.isARepeat, event.keyCode == binding.keyCode,
                   event.modifierFlags.intersection([.command, .option, .control, .shift]).rawValue == binding.modifiers { openClipboard(); return }
            } else {
                if event.type == .keyDown { shiftChord = true; lastShiftTap = 0 }
                if event.type == .flagsChanged, [56, 60].contains(event.keyCode) {
                    if event.modifierFlags.contains(.shift) { shiftStarted = event.timestamp; shiftChord = !event.modifierFlags.intersection([.command, .control, .option]).isEmpty }
                    else if !shiftChord, event.timestamp - shiftStarted < 0.3 {
                        if lastShiftTap > 0, event.timestamp - lastShiftTap < 0.45 { lastShiftTap = 0; openClipboard(); return }
                        lastShiftTap = event.timestamp
                    }
                }
            }
        }

        if capturingShortcut {
            let original = shortcut
            defer { if captureClipboardBinding, !capturingShortcut { clipboardBinding = shortcut; shortcut = original; captureClipboardBinding = false; if let data = try? JSONEncoder().encode(clipboardBinding) { UserDefaults.standard.set(data, forKey: "clipboardBinding") } } }
            if event.type == .flagsChanged, [63, 61, 62, 60, 54].contains(event.keyCode), event.modifierFlags.contains(modifierFlag(for: event.keyCode)) {
                let labels: [UInt16: String] = [63: "fn", 61: "⌥ destro", 62: "⌃ destro", 60: "⇧ destro", 54: "⌘ destro"]
                shortcut = ShortcutBinding(keyCode: event.keyCode, modifiers: 0, label: labels[event.keyCode] ?? "fn", isModifier: true)
                capturingShortcut = false
            } else if event.type == .keyDown, !event.isARepeat {
                if event.keyCode == 53 { capturingShortcut = false; return }
                let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
                guard !flags.isEmpty || event.keyCode >= 96 else { return }
                let names: [UInt16: String] = [49: "Spazio", 36: "Invio", 48: "Tab", 122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12"]
                let prefix = (flags.contains(.control) ? "⌃" : "") + (flags.contains(.option) ? "⌥" : "") + (flags.contains(.shift) ? "⇧" : "") + (flags.contains(.command) ? "⌘" : "")
                shortcut = ShortcutBinding(keyCode: event.keyCode, modifiers: flags.rawValue, label: prefix + (names[event.keyCode] ?? event.charactersIgnoringModifiers?.uppercased() ?? "Tasto"), isModifier: false)
                capturingShortcut = false
            }
            return
        }
        guard shortcutEnabled, !buttonRecording else { return }
        if shortcut.isModifier {
            if event.type == .flagsChanged && event.keyCode == shortcut.keyCode {
                let pressed = event.modifierFlags.contains(modifierFlag(for: shortcut.keyCode))
                if pressed && !keyDown {
                    let others = event.modifierFlags.intersection([.command, .option, .control, .shift]).subtracting(modifierFlag(for: shortcut.keyCode))
                    if !others.isEmpty { keyDown = true; heldShortcut = shortcut.label; fnChord = true }
                    else { fnChord = false; keyboardPressed(shortcut.label) }
                }
                if !pressed && keyDown {
                    if fnChord { keyDown = false; fnChord = false }
                    else { keyboardReleased() }
                }
            } else if keyDown && (event.type == .keyDown || event.type == .flagsChanged) { cancelModifierChord() }
        } else if event.keyCode == shortcut.keyCode {
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift]).rawValue
            if event.type == .keyDown, flags == shortcut.modifiers, !event.isARepeat, !keyDown { keyboardPressed(shortcut.label) }
            if event.type == .keyUp, keyDown { keyboardReleased() }
        }
    }
    private func cancelModifierChord() {
        guard keyDown, shortcut.isModifier, !buttonRecording, !fnChord else { return }
        fnChord = true; hintTask?.cancel(); holdHint = nil
        if phase == .recording || pendingStart != nil { abort("Combinazione di tasti: dettatura annullata.") }
        transcript = ""; hideHUD?()
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
        refreshLoginStatus()
        microphoneAllowed = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        accessibilityAllowed = AXIsProcessTrusted()
        if accessibilityAllowed { installMediaObserver() }
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
                if self.soundEnabled { self.startSound?.play() }
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
        if pendingStart != nil, noteRecordingID != nil { abort("Registrazione annullata."); return }
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
                if self.noteRecordingID == nil && self.silenceSeconds > 0 && self.lastSound.duration(to: .now) > .seconds(self.silenceSeconds) {
                    self.stop()
                    self.message = "Registrazione terminata per silenzio."
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
        guard !text.isEmpty else { noteRecordingID = nil; notes.save(); message = "Nessuna parola riconosciuta. Riprova."; return }
        if noteRecordingID != nil { noteRecordingID = nil; notes.save(); message = "Nota salvata."; return }
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
        noteRecordingID = nil; notes.save()
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
    @State private var showingSettings = false
    @State private var clipboardPage = false
    @State private var notesPage = false
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
                Button { clipboardPage = false; notesPage = false } label: { LucideIcon(name: "chart").frame(width: 42, height: 42)
                    .background(Color.black.opacity(clipboardPage || notesPage ? 0 : 0.09), in: RoundedRectangle(cornerRadius: 10)).help("Il tuo utilizzo") }.buttonStyle(.plain)
                Button { clipboardPage = true; notesPage = false } label: { LucideIcon(name: "clipboard").frame(width: 42, height: 42).background(Color.black.opacity(clipboardPage ? 0.09 : 0), in: RoundedRectangle(cornerRadius: 10)) }.buttonStyle(.plain).help("Appunti")
                Button { notesPage = true; clipboardPage = false } label: { LucideIcon(name: "notes").frame(width: 42, height: 42).background(Color.black.opacity(notesPage ? 0.09 : 0), in: RoundedRectangle(cornerRadius: 10)) }.buttonStyle(.plain).help("Note")
                Spacer()
                Button { showingSettings = true } label: { LucideIcon(name: "settings").frame(width: 42, height: 42) }.buttonStyle(.plain).help("Impostazioni").padding(.bottom, 22)
            }.frame(width: 68).frame(maxHeight: .infinity)
            Group {
                if notesPage { NotesView(model: model, store: model.notes, embedded: true) } else {
            ScrollView {
                if clipboardPage { ClipboardPage(model: model) } else {
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
                                Text(model.shortcutEnabled ? "Tieni premuto \(model.shortcut.label), oppure avvia dal notch." : "Avvia la registrazione dal notch.").font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Picker("Lingua", selection: $model.language) { Text("Italiano").tag("it-IT"); Text("English").tag("en-US") }.frame(width: 175).disabled(model.phase != .idle)
                        }
                        HStack(spacing: 14) {
                            permissionCard("Microfono", detail: "Per ascoltare e trascrivere la tua voce.", icon: "mic", granted: model.microphoneAllowed, action: model.authorizeMicrophone)
                            permissionCard("Accessibilità", detail: "Per inserire il testo nel campo attivo.", icon: "text.cursor", granted: model.accessibilityAllowed, action: model.authorizeAccessibility)
                        }
                        if !model.modelReady {
                            HStack { Text(model.modelStatus).font(.caption); Button("Riprova", action: model.prepareModel).controlSize(.small) }.foregroundStyle(.secondary)
                        }
                    }
                    VStack(alignment: .leading, spacing: 18) {
                        HStack {
                            Text("Trascrizioni").font(.system(size: 26, weight: .medium, design: .serif))
                            Spacer()
                            Text("\(model.history.count) sessioni").font(.caption).foregroundStyle(.secondary)
                        }
                        TranscriptDataTable(history: model.history)
                    }
                }.padding(36).frame(maxWidth: 1120).frame(maxWidth: .infinity)
                }
            }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 22))
            .clipShape(RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(.black.opacity(0.05), lineWidth: 1))
            .padding(.trailing, 12).padding(.vertical, 12)
        }.background(canvas).foregroundStyle(Color(white: 0.10))
            .frame(minWidth: 960, minHeight: 650)
            .preferredColorScheme(.light)
            .overlay {
                if showingSettings {
                    Color.black.opacity(0.25).ignoresSafeArea().onTapGesture { showingSettings = false; model.capturingShortcut = false }
                    SettingsDialog(model: model, close: { showingSettings = false; model.capturingShortcut = false })
                        .shadow(color: .black.opacity(0.15), radius: 28, y: 12)
                }
            }
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

struct TranscriptDataTable: View {
    let history: [Usage]
    @State private var page = 0
    private let pageSize = 10
    private var pageCount: Int { max(1, (history.count + pageSize - 1) / pageSize) }
    private var currentPage: Int { min(page, pageCount - 1) }
    private var start: Int { currentPage * pageSize }
    private var rows: [Usage] { Array(history.dropFirst(start).prefix(pageSize)) }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Text("Data").frame(width: 130, alignment: .leading)
                Text("Trascrizione").frame(maxWidth: .infinity, alignment: .leading)
                Text("Parole").frame(width: 54, alignment: .trailing)
                Text("Azioni").frame(width: 90, alignment: .trailing)
            }.font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 16).padding(.vertical, 12).background(Color(white: 0.97))
            Divider()
            if rows.isEmpty {
                Text("La tua prima trascrizione apparirà qui.").font(.system(size: 13)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 30)
            } else {
                ForEach(rows) { usage in
                    TranscriptTableRow(usage: usage)
                    Divider()
                }
            }
            HStack(spacing: 14) {
                Text(history.isEmpty ? "0 trascrizioni" : "\(start + 1)–\(min(start + pageSize, history.count)) di \(history.count)")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Text("Pagina \(currentPage + 1) di \(pageCount)").font(.system(size: 12)).foregroundStyle(.secondary)
                Button { page = max(0, currentPage - 1) } label: { Label("Precedente", systemImage: "chevron.left") }
                    .disabled(currentPage == 0)
                Button { page = min(pageCount - 1, currentPage + 1) } label: { HStack { Text("Successiva"); Image(systemName: "chevron.right") } }
                    .disabled(currentPage >= pageCount - 1)
            }.buttonStyle(.bordered).controlSize(.small).padding(14)
        }
        .background(.white, in: RoundedRectangle(cornerRadius: 10))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.black.opacity(0.09)))
        .onChange(of: history.count) { _, _ in page = 0 }
    }
}

struct TranscriptTableRow: View {
    let usage: Usage
    @State private var copied = false
    @State private var showText = false
    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(usage.date, format: .dateTime.day().month().year())
                Text(usage.date, format: .dateTime.hour().minute()).foregroundStyle(.secondary)
            }.font(.system(size: 11)).frame(width: 130, alignment: .leading)
            if let text = usage.text {
                Button { showText = true } label: {
                    Text(text).font(.system(size: 13)).lineLimit(2).multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain).help("Mostra la trascrizione completa")
                .popover(isPresented: $showText) {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Trascrizione").font(.system(size: 20, design: .serif))
                        ScrollView { Text(text).font(.system(size: 14)).lineSpacing(4).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    }.padding(20).frame(width: 420, height: 240)
                }
            } else {
                Text("Testo non salvato nella versione precedente").font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("\(usage.words)").font(.system(size: 12)).monospacedDigit().frame(width: 54, alignment: .trailing)
            Group {
                if let text = usage.text {
                    Button {
                        NSPasteboard.general.clearContents()
                        copied = NSPasteboard.general.setString(text, forType: .string)
                    } label: { Label(copied ? "Copiato" : "Copia", systemImage: copied ? "checkmark" : "doc.on.doc") }
                        .buttonStyle(.bordered).controlSize(.small)
                } else { Text("—").foregroundStyle(.tertiary) }
            }.frame(width: 90, alignment: .trailing)
        }.padding(.horizontal, 16).frame(height: 64)
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
    private var expanded: Bool { hovered || listening || model.isStarting || model.holdHint != nil || model.notchNotice != nil }
    private var notchWidth: CGFloat { model.holdHint != nil ? 350 : listening ? (model.buttonRecording ? 106 : 82) : 112 }
    var body: some View {
        ZStack(alignment: .bottom) {
            if model.showsClipboard {
                ClipboardPopup(model: model).transition(reduceMotion ? .opacity : .scale(scale: 0.06, anchor: model.clipboardZoomAnchor).combined(with: .opacity))
            }
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
            HStack(alignment: .bottom, spacing: 8) {
            ZStack(alignment: .bottom) {
            Capsule(style: .continuous).fill(.black.opacity(expanded ? 0.96 : 0.45))
                .frame(width: expanded ? notchWidth : 48, height: model.holdHint != nil ? 48 : expanded ? 32 : 6)
            HStack(spacing: 5) {
                if let notice = model.notchNotice {
                    Label(notice, systemImage: "checkmark").font(.system(size: 12, weight: .medium))
                } else if let shortcut = model.holdHint {
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
        .frame(width: expanded ? notchWidth : 48, height: model.holdHint != nil ? 48 : 32)
        if model.clipboardEnabled && hovered && model.holdHint == nil && model.notchNotice == nil {
            Button(action: model.openClipboard) {
                LucideIcon(name: "clipboard", size: 14).foregroundStyle(.white)
                    .opacity(expanded ? 1 : 0)
                    .frame(width: expanded ? 32 : 6, height: expanded ? 32 : 6)
                    .contentShape(Capsule(style: .continuous))
            }.buttonStyle(NotchButtonStyle())
                .background(.black.opacity(0.96), in: Capsule(style: .continuous))
                .transition(.scale(scale: 0.8).combined(with: .opacity))
                .accessibilityLabel("Apri appunti").help("Apri appunti")
        }
        }
        .contentShape(Rectangle())
        .onHover {
            hovered = $0
            model.clipboardButtonOffset = (expanded ? notchWidth : 48) / 2 + 4
            model.clipboardButtonHeight = expanded ? 22 : 9
        }
        .contextMenu {
            Button("Apri Note") { model.openNotes?() }
            Button("Ripristina posizione", systemImage: "arrow.counterclockwise") { model.resetHUDPosition?() }
        }
        .opacity(model.showsCopyPreview || model.showsClipboard ? 0 : 1)
            }
        .animation(reduceMotion ? .linear(duration: 0.15) : .timingCurve(0.23, 1, 0.32, 1, duration: 0.2), value: expanded)
        .animation(reduceMotion ? .linear(duration: 0.15) : .spring(response: 0.35, dampingFraction: 1), value: model.showsCopyPreview)
        .animation(reduceMotion ? .linear(duration: 0.15) : .spring(response: 0.35, dampingFraction: 1), value: model.showsClipboard)
        .animation(reduceMotion ? .linear(duration: 0.15) : .spring(response: 0.35, dampingFraction: 1), value: model.holdHint)
        .animation(reduceMotion ? .linear(duration: 0.15) : .spring(response: 0.35, dampingFraction: 1), value: model.notchNotice)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 6)
        .accessibilityLabel(listening ? "Microfono attivo, ascolto in corso" : "Dettatura pronta")
    }
}

@MainActor
final class MovableNotchPanel: NSPanel {
    var canDrag: (() -> Bool)?
    var acceptsKeyboard: (() -> Bool)?
    var keyboardAction: ((UInt16) -> Void)?
    override func keyDown(with event: NSEvent) {
        if acceptsKeyboard?() == true { keyboardAction?(event.keyCode) }
        // The nonactivating notch has no text responder: never forward to the system beep.
    }
    override func keyUp(with event: NSEvent) {}
    override var canBecomeKey: Bool { acceptsKeyboard?() == true }
    private var pressEvent: NSEvent?
    private var pressPoint = NSPoint.zero
    private var initialOrigin = NSPoint.zero
    private var dragging = false

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown where canDrag?() == true:
            pressEvent = event
            pressPoint = NSEvent.mouseLocation
            initialOrigin = frame.origin
            dragging = false
            return
        case .leftMouseDragged where pressEvent != nil:
            let point = NSEvent.mouseLocation
            let dx = point.x - pressPoint.x, dy = point.y - pressPoint.y
            if hypot(dx, dy) > 5 { dragging = true }
            if dragging { setFrameOrigin(NSPoint(x: initialOrigin.x + dx, y: initialOrigin.y + dy)) }
            return
        case .leftMouseUp where pressEvent != nil:
            let down = pressEvent
            pressEvent = nil
            if dragging {
                UserDefaults.standard.set(frame.midX, forKey: "notchCenterX")
                UserDefaults.standard.set(frame.minY, forKey: "notchBottomY")
                dragging = false
                return
            }
            if let down { super.sendEvent(down) }
            super.sendEvent(event)
            return
        default: super.sendEvent(event)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model = Dictation()
    private var notesWindow: NSWindow?
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let item = NSMenuItem(title: "Notetaker", action: #selector(openNotesFromDock), keyEquivalent: "")
        item.target = self; menu.addItem(item); return menu
    }
    @objc private func openNotesFromDock() { showNotesWindow() }
    func showNotesWindow() {
        if let notesWindow { NSApp.activate(ignoringOtherApps: true); notesWindow.makeKeyAndOrderFront(nil); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1050, height: 720), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.minSize = NSSize(width: 900, height: 650)
        window.title = "My Wispr — Note"; window.isReleasedWhenClosed = false; window.delegate = self
        window.contentView = NSHostingView(rootView: NotesView(model: model, store: model.notes))
        window.center(); notesWindow = window
        NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if model.noteRecordingID != nil { model.stopFromButton() }
        model.notes.save(); return true
    }
    private var panel: NSPanel?
    private var clipboardOrigin: NSPoint?
    func applicationDidFinishLaunching(_ notification: Notification) {
        model.openNotes = { [weak self] in self?.showNotesWindow() }
        let panel = MovableNotchPanel(contentRect: NSRect(x: 0, y: 0, width: 180, height: 48), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "My Wispr — Notch"
        panel.hasShadow = false; panel.hidesOnDeactivate = false; panel.isOpaque = false; panel.backgroundColor = .clear; panel.level = .floating; panel.ignoresMouseEvents = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.canDrag = { [weak self] in self?.model.showsCopyPreview == false && self?.model.showsClipboard == false }
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let hosting = NSHostingView(rootView: RecordingHUD(model: model))
        hosting.sizingOptions = []
        panel.contentView = hosting; self.panel = panel
        panel.isReleasedWhenClosed = false
        model.resetHUDPosition = { [weak self, weak panel] in
            guard let self, let panel, let screen = self.model.notchScreen else { return }
            UserDefaults.standard.removeObject(forKey: "notchCenterX")
            UserDefaults.standard.removeObject(forKey: "notchBottomY")
            panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - panel.frame.width / 2, y: screen.visibleFrame.minY + 12))
        }
        if let screen = model.notchScreen {
            let defaults = UserDefaults.standard
            let x = defaults.object(forKey: "notchCenterX") as? Double ?? screen.visibleFrame.midX
            let y = defaults.object(forKey: "notchBottomY") as? Double ?? screen.visibleFrame.minY + 12
            let savedFrame = NSRect(x: x - 90, y: y, width: 180, height: 48)
            if screen.visibleFrame.contains(savedFrame) {
                panel.setFrameOrigin(savedFrame.origin)
            } else { model.resetHUDPosition?() }
        }
        model.showHUD = { [weak self, weak panel] in
            guard let self, let panel else { return }
            if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(panel.frame) }) { self.model.resetHUDPosition?() }
            panel.orderFrontRegardless()
        }
        model.hideHUD = { [weak panel] in
            guard let panel else { return }
            let center = panel.frame.midX; let bottom = panel.frame.minY
            panel.ignoresMouseEvents = false
            panel.setFrame(NSRect(x: center - 90, y: bottom, width: 180, height: 48), display: true)
            panel.orderFrontRegardless()
        }
        model.showHintHUD = { [weak panel] in
            guard let panel else { return }
            let center = panel.frame.midX; let bottom = panel.frame.minY
            panel.setFrame(NSRect(x: center - 205, y: bottom, width: 410, height: 68), display: true)
            panel.orderFrontRegardless()
        }
        model.showCopyHUD = { [weak panel] in
            guard let panel else { return }
            let center = panel.frame.midX; let bottom = panel.frame.minY
            panel.setFrame(NSRect(x: center - 210, y: bottom, width: 420, height: 240), display: true)
            panel.ignoresMouseEvents = false
            panel.orderFrontRegardless()
        }
        panel.keyboardAction = { [weak self] code in self?.model.clipboardKey(code) }
        panel.acceptsKeyboard = { [weak self] in self?.model.showsClipboard == true }
        model.showClipboardHUD = { [weak self, weak panel] in
            guard let self, let panel else { return }
            self.clipboardOrigin = panel.frame.origin
            let center = panel.frame.midX, bottom = panel.frame.minY
            let screen = panel.screen?.visibleFrame ?? NSScreen.main!.visibleFrame
            let frame = NSRect(x: min(max(center - 190, screen.minX), screen.maxX - 380), y: min(bottom, screen.maxY - 360), width: 380, height: 360)
            let source = NSPoint(x: center + self.model.clipboardButtonOffset, y: bottom + self.model.clipboardButtonHeight)
            self.model.clipboardZoomAnchor = UnitPoint(x: (source.x - frame.minX - 15) / 350, y: 1 - (source.y - frame.minY - 6) / 320)
            panel.setFrame(frame, display: true)
            Task { @MainActor [weak panel] in
                await Task.yield()
                panel?.makeKeyAndOrderFront(nil)
            }
        }
        model.closeClipboardHUD = { [weak self, weak panel] in
            panel?.resignKey()
            Task { @MainActor [weak self, weak panel] in
                try? await Task.sleep(for: .milliseconds(350))
                guard let self, !self.model.showsClipboard else { return }
                self.model.hideHUD?()
                if let origin = self.clipboardOrigin { panel?.setFrameOrigin(origin) }
                self.clipboardOrigin = nil
            }
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
    private func menuLabel(_ title: String, icon: String) -> some View {
        Label {
            Text(title)
        } icon: {
            if let url = Bundle.main.url(forResource: "lucide-" + icon, withExtension: "png"), let image = NSImage(contentsOf: url) {
                let _ = { image.size = NSSize(width: 16, height: 16); image.isTemplate = true }()
                Image(nsImage: image)
            }
        }
    }
    var body: some Scene {
        WindowGroup("My Wispr") { Dashboard(model: delegate.model) }.defaultSize(width: 1120, height: 850)
            .windowToolbarStyle(.unifiedCompact)
        MenuBarExtra("My Wispr", systemImage: "waveform") {
            Button { NSApp.activate(ignoringOtherApps: true); NSApp.windows.first(where: { $0.title == "My Wispr" && !($0 is NSPanel) })?.makeKeyAndOrderFront(nil) } label: { menuLabel("Statistiche", icon: "chart") }
            Button { delegate.showNotesWindow() } label: { menuLabel("Notetaker", icon: "notes") }
            Button(action: delegate.model.openClipboard) { menuLabel("Appunti", icon: "clipboard") }.disabled(!delegate.model.clipboardEnabled)
            Divider()
            Button { delegate.model.resetHUDPosition?(); delegate.model.showHUD?() } label: { Label("Ripristina notch", systemImage: "arrow.counterclockwise") }
            Button(action: delegate.model.permissions) { Label("Permessi", systemImage: "lock.shield") }
            Divider()
            Button { NSApp.terminate(nil) } label: { Label("Esci", systemImage: "rectangle.portrait.and.arrow.right") }
        }
    }
}

struct SettingsDialog: View {
    @ObservedObject var model: Dictation
    let close: () -> Void
    @State private var systemTab = false
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text("IMPOSTAZIONI").font(.system(size: 11, weight: .semibold)).tracking(1).foregroundStyle(.secondary).padding(.bottom, 16)
                tab("Generali", icon: "slider.horizontal.3", selected: !systemTab) { systemTab = false }
                tab("Sistema", icon: "laptopcomputer", selected: systemTab) { systemTab = true }
                Spacer()
                Text("My Wispr").font(.system(size: 12)).foregroundStyle(.secondary)
            }.padding(22).frame(width: 185).background(Color(white: 0.965))
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    Text(systemTab ? "Sistema" : "Generali").font(.system(size: 30, design: .serif))
                    Spacer()
                    Button(action: close) { Image(systemName: "xmark").frame(width: 28, height: 28) }.buttonStyle(.plain).help("Chiudi impostazioni")
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if !systemTab {
                            settingRow("Scorciatoia di registrazione", subtitle: "Tieni premuto il tasto per parlare; rilascia per trascrivere.") {
                                Toggle("Attiva", isOn: $model.shortcutEnabled).toggleStyle(.switch).controlSize(.small)
                            }
                            Divider()
                            settingRow(model.capturingShortcut ? "Premi la nuova scorciatoia…" : "Tasto assegnato: \(model.shortcut.label)", subtitle: model.capturingShortcut ? "Fn, un modificatore destro o una combinazione. Esc per annullare." : "Fn + altri tasti resta disponibile per le funzioni del Mac.") {
                                Button(model.capturingShortcut ? "Annulla" : "Modifica") { model.capturingShortcut.toggle() }.buttonStyle(DashboardButtonStyle())
                            }
                            Divider()
                            settingRow("Scorciatoia appunti", subtitle: model.captureClipboardBinding ? "Premi una combinazione di tasti." : (model.clipboardBinding?.label ?? "Doppio Shift")) {
                                HStack {
                                    Button("Modifica") { model.captureClipboardBinding = true; model.capturingShortcut = true }.buttonStyle(DashboardButtonStyle())
                                    Button("Doppio Shift") { model.clipboardBinding = nil; UserDefaults.standard.removeObject(forKey: "clipboardBinding") }.buttonStyle(DashboardButtonStyle())
                                }
                            }
                            Divider()
                            settingRow("Lingua di dettatura", subtitle: "Il modello vocale viene preparato per la lingua scelta.") {
                                Picker("Lingua", selection: $model.language) { Text("Italiano").tag("it-IT"); Text("English").tag("en-US") }.labelsHidden().frame(width: 135)
                            }
                            Divider()
                            settingRow("Suono di avvio", subtitle: "Riproduci il suono quando il microfono inizia a registrare.") {
                                Toggle("Suono", isOn: $model.soundEnabled).labelsHidden().toggleStyle(.switch).controlSize(.small)
                            }
                            Divider()
                            settingRow("Stop automatico", subtitle: "Termina la registrazione dopo un periodo di silenzio.") {
                                Picker("Silenzio", selection: $model.silenceSeconds) { Text("Disattivato").tag(0.0); Text("5 secondi").tag(5.0); Text("10 secondi").tag(10.0); Text("20 secondi").tag(20.0); Text("30 secondi").tag(30.0) }.labelsHidden().frame(width: 135)
                            }
                        } else {
                            settingRow("Schermo del notch", subtitle: "Scegli dove visualizzare il notch.") {
                                Picker("Schermo", selection: $model.notchScreenID) {
                                    Text("Schermo principale").tag("")
                                    ForEach(NSScreen.screens, id: \.self) { screen in Text(screen.localizedName).tag(Dictation.screenID(screen)) }
                                }.labelsHidden().frame(width: 180)
                            }
                            Divider()
                            Button("Ripristina posizione del notch") { model.resetHUDPosition?(); model.showHUD?() }.buttonStyle(DashboardButtonStyle()).padding(.vertical, 14)
                            Divider()
                            loginSection
                            settingRow("Microfono", subtitle: model.microphoneAllowed ? "Autorizzato" : "Necessario per registrare la tua voce.") {
                                Button("Apri impostazioni", action: model.authorizeMicrophone).buttonStyle(DashboardButtonStyle())
                            }
                            Divider()
                            settingRow("Accessibilità", subtitle: model.accessibilityAllowed ? "Autorizzata" : "Necessaria per inserire il testo nelle altre app.") {
                                Button("Apri impostazioni", action: model.authorizeAccessibility).buttonStyle(DashboardButtonStyle())
                            }
                            Divider()
                            settingRow("Microfono di sistema", subtitle: "My Wispr usa il dispositivo di ingresso selezionato da macOS.") {
                                Button("Modifica") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension")!) }.buttonStyle(DashboardButtonStyle())
                            }
                        }
                    }.padding(.horizontal, 18).background(Color(white: 0.975), in: RoundedRectangle(cornerRadius: 12))
                        .disabled(model.phase != .idle || model.isStarting)
                }
                Spacer(minLength: 0)
            }.padding(30).frame(maxWidth: .infinity)
        }.frame(width: 850, height: 560).background(.white, in: RoundedRectangle(cornerRadius: 18))
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(.black.opacity(0.08)))
            .onExitCommand(perform: close)
    }
    @ViewBuilder private var loginSection: some View {
                            settingRow("Avvia al login", subtitle: "Apri My Wispr automaticamente quando accedi al Mac.") {
                                Toggle("Avvia al login", isOn: Binding(get: { model.launchAtLogin }, set: { enabled in model.setLaunchAtLogin(enabled) })).labelsHidden().toggleStyle(.switch).controlSize(.small)
                            }
                            if model.loginNeedsApproval {
                                HStack {
                                    Text("Completa l’autorizzazione negli elementi di login di macOS.").font(.system(size: 11)).foregroundStyle(.secondary)
                                    Spacer()
                                    Button("Apri") { SMAppService.openSystemSettingsLoginItems() }.buttonStyle(DashboardButtonStyle())
                                }.padding(.bottom, 16)
                            }
                            if let error = model.loginError { Text(error).font(.system(size: 11)).foregroundStyle(.secondary).padding(.bottom, 16) }
                            Divider()
    }
    private func tab(_ title: String, icon: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: icon).font(.system(size: 14, weight: .medium)).frame(maxWidth: .infinity, alignment: .leading).padding(10).background(Color.black.opacity(selected ? 0.055 : 0), in: RoundedRectangle(cornerRadius: 8)) }.buttonStyle(.plain)
    }
    private func settingRow<Content: View>(_ title: String, subtitle: String, @ViewBuilder control: () -> Content) -> some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 6) { Text(title).font(.system(size: 13, weight: .semibold)); Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            Spacer(minLength: 5)
            control()
        }.padding(.vertical, 19)
    }
}

struct ClipboardPage: View {
    @ObservedObject var model: Dictation
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Appunti").font(.system(size: 28, weight: .medium, design: .serif))
            HStack(alignment: .center) {
                Text("Cronologia appunti").font(.headline)
                Spacer()
                Toggle("Abilita", isOn: $model.clipboardEnabled).labelsHidden().toggleStyle(.switch)
            }
            HStack(alignment: .center) { Text("Ultimi appunti").font(.headline); Spacer(); Button("Svuota") { model.clipboardItems = [] }.buttonStyle(DashboardButtonStyle()).disabled(model.clipboardItems.isEmpty) }
            ForEach(Array(model.clipboardItems.enumerated()), id: \.offset) { _, text in
                Text(text).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading).padding(14).background(Color.black.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
            }
        }.padding(36)
    }
}
struct ClipboardPopup: View {
    @ObservedObject var model: Dictation
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Spacer(); Button { model.closeClipboard() } label: { Image(systemName: "xmark").frame(width: 24, height: 24) }.buttonStyle(NotchButtonStyle()).accessibilityLabel("Chiudi appunti") }
            if model.clipboardItems.isEmpty { LucideIcon(name: "clipboard", size: 26).foregroundStyle(.secondary).accessibilityLabel("Nessun appunto").frame(maxWidth: .infinity, maxHeight: .infinity) }
            else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 4) {
                            ForEach(Array(model.clipboardItems.enumerated()), id: \.offset) { index, text in
                                Button { model.clipboardSelection = index; model.pasteClipboard() } label: {
                                    Text(text).font(.system(size: 13)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading).padding(10)
                                        .background(.white.opacity(model.clipboardSelection == index ? 0.14 : 0.035), in: RoundedRectangle(cornerRadius: 10))
                                }.buttonStyle(.plain).id(index)
                            }
                        }
                    }.onChange(of: model.clipboardSelection) { _, index in withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(index) } }
                }
            }
        }.padding(16).frame(width: 350, height: 320).foregroundStyle(.primary)
            .background(ClipboardGlassBackdrop().clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous)))
            .preferredColorScheme(.dark)
    }
}

struct LucideIcon: View {
    let name: String
    var size: CGFloat = 20
    var body: some View {
        if let url = Bundle.main.url(forResource: "lucide-" + name, withExtension: "png"), let image = NSImage(contentsOf: url) {
            Image(nsImage: image).renderingMode(.template).resizable().scaledToFit().frame(width: size, height: size)
        }
    }
}

struct ClipboardGlassBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .darkAqua)
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

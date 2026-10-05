import SwiftUI
import AppKit

struct WisprNote: Identifiable, Codable {
    var id = UUID()
    var title = "Nuova nota"
    var date = Date()
    var body = ""
    var transcript = ""
    var rewritten = ""
}
@MainActor
final class NotesStore: ObservableObject {
    @Published var notes: [WisprNote] = []
    @Published var selected: UUID?
    @Published var rewriting: UUID?
    @Published var error: String?
    private var saveTask: Task<Void, Never>?
    private let file = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MyWispr/notes.json")
    init() {
        if let data = try? Data(contentsOf: file), let values = try? JSONDecoder().decode([WisprNote].self, from: data) { notes = values }
    }
    func create() { let note = WisprNote(); notes.insert(note, at: 0); selected = note.id; save() }
    func update(_ id: UUID, _ action: (inout WisprNote) -> Void) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        action(&notes[index]); saveTask?.cancel()
        saveTask = Task { try? await Task.sleep(for: .milliseconds(400)); guard !Task.isCancelled else { return }; save() }
    }
    func delete(_ id: UUID) {
        guard rewriting != id else { return }
        saveTask?.cancel()
        notes.removeAll { $0.id == id }
        if selected == id { selected = notes.first?.id }
        save()
    }
    func save() {
        do { try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true); try JSONEncoder().encode(notes).write(to: file, options: .atomic) }
        catch { self.error = "Impossibile salvare le note: \(error.localizedDescription)" }
    }
    func rewrite(_ id: UUID) {
        guard rewriting == nil, let note = notes.first(where: { $0.id == id }), !note.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        rewriting = id; error = nil
        Task {
            do {
                let result = try await NoteRewriter.run(note.body)
                update(id) { $0.rewritten = result }; save()
            } catch { self.error = error.localizedDescription }
            rewriting = nil
        }
    }
}
struct NotesView: View {
    @ObservedObject var model: Dictation
    @ObservedObject var store: NotesStore
    var embedded = false
    @State private var tab = 0
    @State private var search = ""
    @State private var deleteCandidate: WisprNote?
    @State private var revealedNote: UUID?
    private var recording: Bool { model.noteRecordingID != nil }
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 20) {
                HStack { Text("Note").font(.system(size: 28, design: .serif)); Spacer(); Button { store.create(); tab = 0 } label: { Image(systemName: "plus") }.buttonStyle(DashboardButtonStyle()).disabled(recording) }
                TextField("Cerca", text: $search).textFieldStyle(.roundedBorder)
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(store.notes.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || $0.body.localizedCaseInsensitiveContains(search) }) { note in
                            SwipeNoteRow(note: note, selected: store.selected == note.id, revealed: $revealedNote,
                                select: { store.selected = note.id; tab = 0 },
                                delete: { deleteCandidate = note })
                                .disabled(recording || store.rewriting == note.id)
                        }
                    }
                }
            }.padding(24).frame(width: embedded ? 240 : 280).background(Color(white: 0.97))
            Divider()
            if let id = store.selected, let note = store.notes.first(where: { $0.id == id }) {
                VStack(alignment: .leading, spacing: 20) {
                    TextField("Nuova nota", text: Binding(get: { store.notes.first(where: { $0.id == id })?.title ?? "" }, set: { value in store.update(id) { $0.title = value } })).textFieldStyle(.plain).font(.system(size: 32, design: .serif))
                    Text(note.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 24) {
                        ForEach(Array(["Nota", "Trascrizione", "Riscritta"].enumerated()), id: \.offset) { index, label in
                            Button { tab = index } label: { Text(label).fontWeight(tab == index ? .semibold : .regular).padding(.bottom, 10).overlay(alignment: .bottom) { if tab == index { Rectangle().frame(height: 2) } } }.buttonStyle(.plain)
                        }
                    }
                    TextEditor(text: Binding(get: {
                        guard let current = store.notes.first(where: { $0.id == id }) else { return "" }
                        return tab == 0 ? current.body : tab == 1 ? current.transcript : current.rewritten
                    }, set: { value in store.update(id) { if tab == 0 { $0.body = value } else if tab == 2 { $0.rewritten = value } } }))
                        .font(.system(size: 16)).scrollContentBackground(.hidden).padding(12).background(Color(white: 0.98), in: RoundedRectangle(cornerRadius: 14)).disabled(recording || tab == 1 || store.rewriting == id)
                    if let error = store.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                    if recording || model.isStarting { Text(model.phase == .finishing ? "Completo la trascrizione…" : "Registrazione in corso").font(.caption).foregroundStyle(.secondary) }
                    HStack {
                        Button { if recording { model.stopFromButton() } else { tab = 0; model.startNote(id) } } label: { Label(recording ? "Stop" : "Registra", systemImage: recording ? "stop.fill" : "mic") }.buttonStyle(DashboardButtonStyle()).disabled(model.phase == .finishing || (!recording && (!model.modelReady || !model.microphoneAllowed || model.phase != .idle)))
                        Spacer()
                        if tab == 2, !note.rewritten.isEmpty { Button("Usa nella nota") { store.update(id) { $0.body = $0.rewritten }; tab = 0 }.buttonStyle(DashboardButtonStyle()).disabled(recording) }
                        Button { tab = 2; store.rewrite(id) } label: { Label(store.rewriting == id ? "Riscrivo…" : "Riscrivi con Claude", systemImage: "sparkles") }.buttonStyle(DashboardButtonStyle()).disabled(recording || model.isStarting || store.rewriting != nil || note.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }.padding(embedded ? 36 : 32).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 20) { Text("Le tue idee, in un posto solo.").font(.system(size: 28, design: .serif)); Button("Nuova nota") { store.create() }.buttonStyle(DashboardButtonStyle()) }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(.white).foregroundStyle(.black).preferredColorScheme(.light)
        .disabled(deleteCandidate != nil)
        .overlay {
            if let note = deleteCandidate {
                ZStack {
                    Color.black.opacity(0.25).ignoresSafeArea().onTapGesture { deleteCandidate = nil }
                    VStack(alignment: .leading, spacing: 18) {
                        Text("Eliminare questa nota?").font(.system(size: 24, weight: .medium, design: .serif))
                        Text("“\(note.title)” verrà eliminata definitivamente, insieme alla trascrizione e alla versione riscritta.").font(.system(size: 14)).foregroundStyle(.secondary)
                        HStack {
                            Spacer()
                            Button("Annulla") { deleteCandidate = nil }.buttonStyle(DashboardButtonStyle())
                            Button("Elimina definitivamente", role: .destructive) {
                                guard !recording, store.rewriting != note.id else { return }
                                store.delete(note.id); revealedNote = nil; deleteCandidate = nil
                            }.buttonStyle(DashboardButtonStyle())
                        }
                    }.padding(26).frame(width: 420).background(.white, in: RoundedRectangle(cornerRadius: 18))
                }.onExitCommand { deleteCandidate = nil }
            }
        }
    }
}

struct SwipeNoteRow: View {
    let note: WisprNote
    let selected: Bool
    @Binding var revealed: UUID?
    let select: () -> Void
    let delete: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drag: CGFloat = 0
    @State private var isDragging = false
    private var offset: CGFloat { min(0, max(-72, (revealed == note.id ? -72 : 0) + drag)) }
    var body: some View {
        Button {
            if revealed == note.id { withAnimation(motion) { revealed = nil } }
            else { select() }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text(note.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Text(note.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                Text(note.body).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                .background(Color(white: selected ? 0.91 : 0.95), in: RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain).offset(x: offset)
            .background(alignment: .trailing) {
                Button(role: .destructive, action: delete) {
                    Image(systemName: "trash").font(.system(size: 18)).foregroundStyle(.white).frame(width: 72).frame(maxHeight: .infinity)
                }.buttonStyle(.plain).accessibilityLabel("Elimina nota")
                    .allowsHitTesting(revealed == note.id && !isDragging)
                    .frame(maxWidth: .infinity, alignment: .trailing).background(Color.red.opacity(offset < 0 ? 1 : 0))
                    .accessibilityHidden(revealed != note.id)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .simultaneousGesture(DragGesture(minimumDistance: 10)
                .onChanged { value in
                    guard abs(value.translation.width) > abs(value.translation.height) else { return }
                    isDragging = true; drag = value.translation.width
                }
                .onEnded { value in
                    guard isDragging else { return }
                    let destination = (revealed == note.id ? -72.0 : 0) + value.predictedEndTranslation.width
                    withAnimation(motion) { revealed = destination < -36 ? note.id : nil; drag = 0; isDragging = false }
                })
            .accessibilityAction(named: Text("Mostra Elimina")) { withAnimation(motion) { revealed = note.id } }
    }
    private var motion: Animation { reduceMotion ? .linear(duration: 0.1) : .spring(response: 0.28, dampingFraction: 0.9) }
}

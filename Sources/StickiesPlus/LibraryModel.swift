import AppKit
import Combine

/// What the library asks the app to do with sticky windows.
@MainActor
protocol LibraryHost: AnyObject {
    /// Pushes a library edit into an open sticky; returns false if the note has no sticky window.
    func libraryEdited(_ note: Note) -> Bool
    func librarySetOnDesktop(_ onDesktop: Bool, note: Note)
    /// Closes the note's sticky window, if it has one.
    func libraryRemovedSticky(noteID: Int64)
}

enum LibrarySection: Hashable {
    case notes
    case recentlyDeleted
    case allTexts
    case category(TextCategory)
}

enum LibrarySelection: Hashable {
    case note(Int64)
    case text(Int64)
}

struct LibraryNote: Identifiable {
    var note: Note
    var plainText: String

    init(_ note: Note) {
        self.note = note
        plainText = note.plainText
    }

    var id: Int64 { note.id }

    private var lines: [String] {
        plainText.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    var title: String { lines.first ?? "New Note" }
    var preview: String { lines.dropFirst().first ?? "No additional text" }
}

/// State for the Notes-style library window.
@MainActor
final class LibraryModel: ObservableObject {
    /// Days a note stays in Recently Deleted before it's removed for good.
    static let trashRetentionDays = 30

    @Published private(set) var notes: [LibraryNote] = []
    @Published private(set) var deletedNotes: [LibraryNote] = []
    @Published private(set) var texts: [TextItem] = []
    @Published var section: LibrarySection? = .notes {
        didSet { if oldValue != section { selection = nil } }
    }
    @Published var selection: LibrarySelection?
    @Published var search = ""

    weak var host: LibraryHost?
    private let store: NoteStore
    /// Where a note goes if it's later shown as a sticky.
    var defaultStickyFrame: () -> NSRect = { NSRect(x: 100, y: 100, width: 250, height: 220) }

    init(store: NoteStore) {
        self.store = store
        reload()
    }

    func reload() {
        let all = store.allNotes()
        notes = all.filter { $0.deletedAt == nil }.map(LibraryNote.init)
            .sorted { $0.note.updatedAt > $1.note.updatedAt }
        deletedNotes = all.filter { $0.deletedAt != nil }.map(LibraryNote.init)
            .sorted { ($0.note.deletedAt ?? .distantPast) > ($1.note.deletedAt ?? .distantPast) }
        reloadTexts()
    }

    var isShowingTrash: Bool { section == .recentlyDeleted }

    func reloadTexts() {
        texts = store.allTexts()
    }

    // MARK: Lists

    private func matchesSearch(_ text: String) -> Bool {
        search.isEmpty || text.localizedCaseInsensitiveContains(search)
    }

    var visibleNotes: [LibraryNote] {
        (isShowingTrash ? deletedNotes : notes).filter { matchesSearch($0.plainText) }
    }

    var visibleTexts: [TextItem] {
        texts.filter { item in
            guard matchesSearch(item.text) else { return false }
            if case .category(let category) = section { return (item.category ?? .note) == category && item.category != nil }
            return true
        }
    }

    func count(_ section: LibrarySection) -> Int {
        switch section {
        case .notes: return notes.count
        case .recentlyDeleted: return deletedNotes.count
        case .allTexts: return texts.count
        case .category(let category):
            return texts.filter { $0.category == category && !($0.category == .todo && $0.isDone) }.count
        }
    }

    func note(_ id: Int64) -> LibraryNote? {
        notes.first { $0.id == id } ?? deletedNotes.first { $0.id == id }
    }

    /// e.g. "29 days left" for a note in Recently Deleted.
    func daysLeft(_ note: Note) -> Int {
        guard let deletedAt = note.deletedAt else { return Self.trashRetentionDays }
        let elapsed = Calendar.current.dateComponents([.day], from: deletedAt, to: Date()).day ?? 0
        return max(Self.trashRetentionDays - elapsed, 0)
    }
    func text(_ id: Int64) -> TextItem? { texts.first { $0.id == id } }

    // MARK: Notes

    func newNote(with text: String? = nil) {
        var note = store.createNote(frame: defaultStickyFrame(), color: .yellow, onDesktop: false)
        if let text {
            note.content = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 15)])
                .rtfd(from: NSRange(location: 0, length: text.utf16.count), documentAttributes: [:]) ?? Data()
            store.save(note)
        }
        reload()
        search = ""
        section = .notes
        selection = .note(note.id)
    }

    func updateContent(noteID: Int64, content: Data) {
        guard var note = note(noteID)?.note else { return }
        note.content = content
        note.updatedAt = Date()
        if host?.libraryEdited(note) != true { store.save(note) }
        replace(note)
    }

    /// A sticky window saved; keep our copy current (it has the latest frame and color).
    func noteSavedOnDesktop(_ note: Note) {
        replace(note)
    }

    private func replace(_ note: Note) {
        if let index = notes.firstIndex(where: { $0.id == note.id }) {
            notes[index] = LibraryNote(note)
            notes.sort { $0.note.updatedAt > $1.note.updatedAt }
        } else {
            reload()
        }
    }

    func setOnDesktop(_ onDesktop: Bool, noteID: Int64) {
        guard let note = note(noteID)?.note else { return }
        host?.librarySetOnDesktop(onDesktop, note: note)
        reload()
    }

    /// Moves a note to Recently Deleted.
    func deleteNote(_ noteID: Int64) {
        host?.libraryRemovedSticky(noteID: noteID)
        store.trashNote(id: noteID)
        if selection == .note(noteID) { selection = nil }
        reload()
    }

    func restoreNote(_ noteID: Int64) {
        store.restoreNote(id: noteID)
        reload()
        section = .notes
        selection = .note(noteID)
    }

    func deletePermanently(_ noteID: Int64) {
        store.deleteNote(id: noteID)
        if selection == .note(noteID) { selection = nil }
        reload()
    }

    func emptyTrash() {
        deletedNotes.forEach { store.deleteNote(id: $0.id) }
        selection = nil
        reload()
    }

    // MARK: Texts

    func setCategory(_ category: TextCategory, textID: Int64) {
        store.setCategory(category, forText: textID)
        reloadTexts()
    }

    func toggleDone(_ textID: Int64) {
        guard let item = text(textID) else { return }
        store.setDone(!item.isDone, forText: textID)
        reloadTexts()
    }

    func deleteText(_ textID: Int64) {
        store.deleteText(id: textID)
        if selection == .text(textID) { selection = nil }
        reloadTexts()
    }

    func makeNote(fromText textID: Int64) {
        guard let item = text(textID) else { return }
        newNote(with: item.text)
    }
}

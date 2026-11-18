import AppKit
import SwiftUI

/// Notes-app-style window: folders | list | white editor.
struct LibraryView: View {
    @ObservedObject var model: LibraryModel

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } content: {
            contentList
                .navigationSplitViewColumnWidth(min: 240, ideal: 290)
        } detail: {
            detail
        }
        .searchable(text: $model.search, placement: .toolbar)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { model.newNote() } label: { Label("New Note", systemImage: "square.and.pencil") }
                    .help("New note")
            }
        }
        .frame(minWidth: 760, minHeight: 440)
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: $model.section) {
            Section("Notes") {
                sidebarRow(.notes, "All Notes", "note.text")
                sidebarRow(.recentlyDeleted, "Recently Deleted", "trash")
            }
            Section("Texts to Self") {
                sidebarRow(.allTexts, "All Texts", "message")
                ForEach(TextCategory.allCases, id: \.self) { category in
                    sidebarRow(.category(category), category.title, category.symbol)
                }
            }
        }
    }

    private func sidebarRow(_ section: LibrarySection, _ title: String, _ symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .badge(model.count(section))
            .tag(section)
    }

    // MARK: Middle list

    @ViewBuilder
    private var contentList: some View {
        if model.section == .notes || model.section == nil {
            notesList
        } else if model.isShowingTrash {
            trashList
        } else {
            textsList
        }
    }

    private var notesList: some View {
        List(model.visibleNotes, selection: $model.selection) { item in
            NoteRow(item: item)
                .tag(LibrarySelection.note(item.id))
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) { model.deleteNote(item.id) } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
                .contextMenu {
                    Button(item.note.isOnDesktop ? "Remove from Desktop" : "Show as Sticky") {
                        model.setOnDesktop(!item.note.isOnDesktop, noteID: item.id)
                    }
                    Divider()
                    Button("Delete", role: .destructive) { model.deleteNote(item.id) }
                }
        }
        .overlay {
            if model.visibleNotes.isEmpty {
                ContentUnavailableView("No Notes", systemImage: "note.text", description: Text("Click ✎ to start one."))
            }
        }
    }

    private var trashList: some View {
        List(model.visibleNotes, selection: $model.selection) { item in
            NoteRow(item: item, daysLeft: model.daysLeft(item.note))
                .tag(LibrarySelection.note(item.id))
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    Button { model.restoreNote(item.id) } label: {
                        Label("Recover", systemImage: "arrow.uturn.backward")
                    }
                    .tint(.blue)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) { model.deletePermanently(item.id) } label: {
                        Label("Delete Forever", systemImage: "trash.slash")
                    }
                }
                .contextMenu {
                    Button("Recover") { model.restoreNote(item.id) }
                    Divider()
                    Button("Delete Permanently", role: .destructive) { model.deletePermanently(item.id) }
                }
        }
        .overlay {
            if model.visibleNotes.isEmpty {
                ContentUnavailableView(
                    "No Recently Deleted Notes", systemImage: "trash",
                    description: Text("Deleted notes stay here for \(LibraryModel.trashRetentionDays) days."))
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !model.deletedNotes.isEmpty {
                Button("Delete All", role: .destructive) { confirmEmptyTrash() }
                    .padding(10)
            }
        }
    }

    private func confirmEmptyTrash() {
        let alert = NSAlert()
        alert.messageText = "Delete all \(model.deletedNotes.count) notes permanently?"
        alert.informativeText = "This can’t be undone."
        alert.addButton(withTitle: "Delete All")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        if alert.runModal() == .alertFirstButtonReturn { model.emptyTrash() }
    }

    private var textsList: some View {
        List(model.visibleTexts, selection: $model.selection) { item in
            TextRow(item: item, showCategory: model.section == .allTexts) { model.toggleDone(item.id) }
                .tag(LibrarySelection.text(item.id))
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) { model.deleteText(item.id) } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
                .contextMenu {
                    Menu("Move to") {
                        ForEach(TextCategory.allCases, id: \.self) { category in
                            Button(category.title) { model.setCategory(category, textID: item.id) }
                        }
                    }
                    Button("Make Note") { model.makeNote(fromText: item.id) }
                    Divider()
                    Button("Delete", role: .destructive) { model.deleteText(item.id) }
                }
        }
        .overlay {
            if model.visibleTexts.isEmpty {
                ContentUnavailableView("No Texts", systemImage: "message",
                                       description: Text("Texts you send yourself show up here, sorted automatically."))
            }
        }
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        switch model.selection {
        case .note(let id):
            if let item = model.note(id), item.note.deletedAt != nil {
                NoteEditor(note: item.note, isEditable: false) { _ in }
                    .id(id)
                    .safeAreaInset(edge: .top) {
                        HStack {
                            Text("This note is in Recently Deleted.").foregroundStyle(.secondary)
                            Button("Recover") { model.restoreNote(id) }
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity)
                        .background(Color(white: 0.96))
                    }
            } else if let item = model.note(id) {
                NoteEditor(note: item.note) { model.updateContent(noteID: id, content: $0) }
                    .id(id)
                    .toolbar {
                        ToolbarItemGroup {
                            Button {
                                model.setOnDesktop(!item.note.isOnDesktop, noteID: id)
                            } label: {
                                Label(item.note.isOnDesktop ? "Remove from Desktop" : "Show as Sticky",
                                      systemImage: item.note.isOnDesktop ? "note" : "rectangle.on.rectangle")
                            }
                            .help(item.note.isOnDesktop ? "Remove from desktop" : "Show as a sticky on the desktop")
                            Button { model.deleteNote(id) } label: { Label("Delete", systemImage: "trash") }
                                .help("Delete note")
                        }
                    }
            }
        case .text(let id):
            if let item = model.text(id) {
                TextDetail(item: item, model: model)
            }
        case nil:
            ContentUnavailableView("Nothing Selected", systemImage: "note.text")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.white)
        }
    }
}

// MARK: Rows

private func shortDate(_ date: Date) -> String {
    Calendar.current.isDateInToday(date)
        ? date.formatted(date: .omitted, time: .shortened)
        : date.formatted(date: .numeric, time: .omitted)
}

private struct NoteRow: View {
    let item: LibraryNote
    /// Shown instead of the preview for notes in Recently Deleted.
    var daysLeft: Int? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(item.title).font(.headline).lineLimit(1)
                Spacer()
                if item.note.isOnDesktop {
                    Circle().fill(Color(nsColor: item.note.color.nsColor))
                        .overlay(Circle().stroke(.black.opacity(0.15)))
                        .frame(width: 9, height: 9)
                        .help("On the desktop as a sticky")
                }
            }
            HStack(spacing: 6) {
                Text(shortDate(item.note.updatedAt))
                if let daysLeft {
                    Text(daysLeft == 1 ? "1 day left" : "\(daysLeft) days left").foregroundStyle(.secondary)
                } else {
                    Text(item.preview).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .font(.subheadline)
        }
        .padding(.vertical, 4)
    }
}

private struct TextRow: View {
    let item: TextItem
    let showCategory: Bool
    let onToggleDone: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if item.category == .todo {
                Button(action: onToggleDone) {
                    Image(systemName: item.isDone ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(item.isDone ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(item.text)
                    .lineLimit(2)
                    .strikethrough(item.isDone)
                    .foregroundStyle(item.isDone ? .secondary : .primary)
                HStack(spacing: 6) {
                    Text(shortDate(item.date))
                    if showCategory {
                        if let category = item.category {
                            Label(category.title, systemImage: category.symbol)
                        } else {
                            Label("Sorting…", systemImage: "sparkles")
                        }
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }
}

private struct TextDetail: View {
    let item: TextItem
    @ObservedObject var model: LibraryModel

    private var url: URL? {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        return detector?.firstMatch(in: item.text, range: NSRange(item.text.startIndex..., in: item.text))?.url
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Texted \(item.date.formatted(date: .complete, time: .shortened))")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(item.text)
                .font(.title3)
                .textSelection(.enabled)
            if let url { Link(url.absoluteString, destination: url) }
            HStack {
                Picker("Category", selection: Binding(
                    get: { item.category ?? .note },
                    set: { model.setCategory($0, textID: item.id) })) {
                    ForEach(TextCategory.allCases, id: \.self) { category in
                        Label(category.title, systemImage: category.symbol).tag(category)
                    }
                }
                .fixedSize()
                if item.category == .todo {
                    Toggle("Done", isOn: Binding(get: { item.isDone }, set: { _ in model.toggleDone(item.id) }))
                }
                Spacer()
                Button("Make Note") { model.makeNote(fromText: item.id) }
                Button("Delete", role: .destructive) { model.deleteText(item.id) }
            }
            Spacer()
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.white)
    }
}

// MARK: Editor

/// White rich-text editor; saves shortly after typing stops.
private struct NoteEditor: NSViewRepresentable {
    let note: Note
    var isEditable = true
    let onChange: (Data) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        let textView = scrollView.documentView as! NSTextView
        textView.isRichText = true
        textView.importsGraphics = true
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.usesFontPanel = true
        textView.isEditable = isEditable
        textView.drawsBackground = true
        textView.backgroundColor = .white
        textView.textContainerInset = NSSize(width: 24, height: 20)
        textView.font = Coordinator.defaultFont
        textView.typingAttributes[.font] = Coordinator.defaultFont
        textView.delegate = context.coordinator
        scrollView.backgroundColor = .white
        context.coordinator.textView = textView
        context.coordinator.onChange = onChange
        context.coordinator.load(note)
        DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onChange = onChange
        // Edited in its sticky window: show the new text unless we're mid-edit here.
        if note.content != coordinator.lastContent && coordinator.pending == nil {
            coordinator.load(note)
        }
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.flush()
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        static let defaultFont = NSFont.systemFont(ofSize: 15)
        private static let saveDelay: TimeInterval = 0.4

        weak var textView: NSTextView?
        var onChange: ((Data) -> Void)?
        var lastContent = Data()
        var pending: DispatchWorkItem?

        func load(_ note: Note) {
            lastContent = note.content
            let text = note.content.isEmpty ? NSAttributedString()
                : (NSAttributedString(rtfd: note.content, documentAttributes: nil) ?? NSAttributedString())
            textView?.textStorage?.setAttributedString(text)
        }

        func textDidChange(_ notification: Notification) {
            pending?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.flush() }
            pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.saveDelay, execute: work)
        }

        func flush() {
            guard let work = pending, let storage = textView?.textStorage else { return }
            work.cancel()
            pending = nil
            let data = storage.rtfd(from: NSRange(location: 0, length: storage.length),
                                    documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd]) ?? Data()
            lastContent = data
            let send = onChange
            // Deferred so we never publish model changes during a SwiftUI view update.
            DispatchQueue.main.async { send?(data) }
        }
    }
}

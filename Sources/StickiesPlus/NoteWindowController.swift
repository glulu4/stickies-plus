import AppKit
import UniformTypeIdentifiers

/// Panel that turns a title-bar double-click into collapse/expand, like Stickies.
final class NotePanel: NSPanel {
    var onTitleBarDoubleClick: (() -> Void)?

    override var canBecomeKey: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, event.clickCount == 2,
           event.locationInWindow.y > contentLayoutRect.maxY {
            onTitleBarDoubleClick?()
            return
        }
        super.sendEvent(event)
    }
}

final class NoteWindowController: NSWindowController, NSWindowDelegate, NSTextViewDelegate, NSMenuItemValidation {
    private static let saveDelay: TimeInterval = 0.5
    private static let translucentAlpha: CGFloat = 0.6
    private static let defaultFont = NSFont.systemFont(ofSize: 14)

    private(set) var note: Note
    private let store: NoteStore
    private let scrollView: NSScrollView
    private let textView: NSTextView
    private var pendingSave: DispatchWorkItem?
    /// Called when this sticky leaves the desktop (deleted, or moved to the library).
    var onRemove: ((NoteWindowController) -> Void)?
    /// Called after every save so the library can refresh.
    var onSaved: ((Note) -> Void)?

    init(note: Note, store: NoteStore) {
        self.note = note
        self.store = store

        let panel = NotePanel(
            contentRect: note.frame,
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered, defer: false)
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.titlebarAppearsTransparent = true
        panel.minSize = NSSize(width: 120, height: 60)
        // Notes are always light, so keep text dark even in Dark Mode.
        panel.appearance = NSAppearance(named: .aqua)

        scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true
        textView = scrollView.documentView as! NSTextView
        textView.drawsBackground = false
        textView.isRichText = true
        textView.importsGraphics = true
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.usesFontPanel = true
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.font = Self.defaultFont
        textView.typingAttributes[.font] = Self.defaultFont
        if !note.content.isEmpty, let text = NSAttributedString(rtfd: note.content, documentAttributes: nil) {
            textView.textStorage?.setAttributedString(text)
        }
        panel.contentView = scrollView

        super.init(window: panel)
        panel.delegate = self
        textView.delegate = self
        panel.onTitleBarDoubleClick = { [weak self] in self?.toggleCollapsed(nil) }

        applyAppearance()
        if note.isCollapsed { applyCollapsed() }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: Text

    var plainText: String { textView.string }

    private var firstLine: String {
        let line = plainText.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return line.trimmingCharacters(in: .whitespaces).isEmpty ? "Note" : line
    }

    func append(_ text: String) {
        guard let storage = textView.textStorage else { return }
        var attributes = textView.typingAttributes
        attributes[.font] = attributes[.font] ?? Self.defaultFont
        let needsNewline = storage.length > 0 && !storage.string.hasSuffix("\n")
        storage.append(NSAttributedString(string: (needsNewline ? "\n" : "") + text, attributes: attributes))
        textChanged()
    }

    /// Replaces the text after an edit made in the library (already saved there).
    func setContent(_ note: Note) {
        pendingSave?.cancel()
        self.note.content = note.content
        self.note.updatedAt = note.updatedAt
        let text = note.content.isEmpty ? NSAttributedString()
            : (NSAttributedString(rtfd: note.content, documentAttributes: nil) ?? NSAttributedString())
        textView.textStorage?.setAttributedString(text)
        if self.note.isCollapsed { window?.title = firstLine }
    }

    func textDidChange(_ notification: Notification) {
        textChanged()
    }

    private func textChanged() {
        if note.isCollapsed { window?.title = firstLine }
        note.updatedAt = Date()
        scheduleSave()
    }

    // MARK: Persistence

    private func scheduleSave() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.saveDelay, execute: work)
    }

    func saveNow() {
        pendingSave?.cancel()
        pendingSave = nil
        if let storage = textView.textStorage {
            note.content = storage.rtfd(
                from: NSRange(location: 0, length: storage.length),
                documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd]) ?? Data()
        }
        store.save(note)
        onSaved?(note)
    }

    func windowDidMove(_ notification: Notification) {
        guard let frame = window?.frame else { return }
        if note.isCollapsed {
            // Keep the expanded frame, pinned to the collapsed bar's top edge.
            note.frame.origin = NSPoint(x: frame.minX, y: frame.maxY - note.frame.height)
        } else {
            note.frame = frame
        }
        scheduleSave()
    }

    func windowDidResize(_ notification: Notification) {
        guard !note.isCollapsed, let frame = window?.frame else { return }
        note.frame = frame
        scheduleSave()
    }

    func move(topLeft: NSPoint) {
        window?.setFrameTopLeftPoint(topLeft)
    }

    // MARK: Closing: empty notes are deleted, others move to the library

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !hasAttachments {
            pendingSave?.cancel()
            store.deleteNote(id: note.id)
            removeFromDesktop()
        } else {
            note.isOnDesktop = false
            saveNow()
            removeFromDesktop()
        }
        return false
    }

    private var hasAttachments: Bool {
        textView.textStorage?.containsAttachments ?? false
    }

    /// Hides the window without saving; the library or AppDelegate owns what happens to the note.
    func removeFromDesktop() {
        pendingSave?.cancel()
        window?.orderOut(nil)
        onRemove?(self)
    }

    // MARK: Note menu actions

    private func applyAppearance() {
        guard let panel = window as? NSPanel else { return }
        panel.backgroundColor = note.color.nsColor
        panel.isFloatingPanel = note.isFloating
        panel.level = note.isFloating ? .floating : .normal
        panel.alphaValue = note.isTranslucent ? Self.translucentAlpha : 1
    }

    @objc func setNoteColor(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let color = NoteColor(rawValue: raw) else { return }
        note.color = color
        applyAppearance()
        saveNow()
    }

    @objc func toggleFloating(_ sender: Any?) {
        note.isFloating.toggle()
        applyAppearance()
        saveNow()
    }

    @objc func toggleTranslucent(_ sender: Any?) {
        note.isTranslucent.toggle()
        applyAppearance()
        saveNow()
    }

    @objc func toggleCollapsed(_ sender: Any?) {
        note.isCollapsed.toggle()
        if note.isCollapsed { applyCollapsed() } else { applyExpanded() }
        saveNow()
    }

    private func applyCollapsed() {
        guard let window else { return }
        let titleBarHeight = window.frame.height - window.contentLayoutRect.height
        let expanded = note.frame
        scrollView.isHidden = true
        window.styleMask.remove(.resizable)
        window.title = firstLine
        window.titleVisibility = .visible
        window.setFrame(NSRect(x: expanded.minX, y: expanded.maxY - titleBarHeight,
                               width: expanded.width, height: titleBarHeight), display: true)
    }

    private func applyExpanded() {
        guard let window else { return }
        let top = window.frame.maxY
        window.styleMask.insert(.resizable)
        window.titleVisibility = .hidden
        window.setFrame(NSRect(x: window.frame.minX, y: top - note.frame.height,
                               width: note.frame.width, height: note.frame.height), display: true)
        scrollView.isHidden = false
    }

    @objc func exportNote(_ sender: Any?) {
        guard let window, let storage = textView.textStorage else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.rtf]
        panel.nameFieldStringValue = firstLine.prefix(40) + ".rtf"
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            let data = storage.rtf(from: NSRange(location: 0, length: storage.length),
                                   documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
            try? data?.write(to: url)
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(setNoteColor(_:)):
            menuItem.state = (menuItem.representedObject as? String) == note.color.rawValue ? .on : .off
        case #selector(toggleFloating(_:)):
            menuItem.state = note.isFloating ? .on : .off
        case #selector(toggleTranslucent(_:)):
            menuItem.state = note.isTranslucent ? .on : .off
        case #selector(toggleCollapsed(_:)):
            menuItem.title = note.isCollapsed ? "Expand" : "Collapse"
        default:
            break
        }
        return true
    }
}

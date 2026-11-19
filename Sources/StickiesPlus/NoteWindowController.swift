import AppKit
import UniformTypeIdentifiers

/// Panel that handles title-bar clicks like Stickies: double-click collapses, right-click shows options.
final class NotePanel: NSPanel {
    var onTitleBarDoubleClick: (() -> Void)?
    var onTitleBarRightClick: ((NSEvent) -> Void)?

    override var canBecomeKey: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        let inTitleBar = event.locationInWindow.y > contentLayoutRect.maxY
        if inTitleBar, event.type == .leftMouseDown, event.clickCount == 2 {
            onTitleBarDoubleClick?()
            return
        }
        if inTitleBar, event.type == .rightMouseDown {
            onTitleBarRightClick?(event)
            return
        }
        super.sendEvent(event)
    }
}

final class NoteWindowController: NSWindowController, NSWindowDelegate, NSTextViewDelegate, NSMenuItemValidation {
    private static let saveDelay: TimeInterval = 0.5
    private static let translucentAlpha: CGFloat = 0.6
    private static let defaultFont = NSFont.systemFont(ofSize: 14)
    static let bullet = "• "
    private static let glowAlpha: CGFloat = 0.35
    private static let glowStepDuration: TimeInterval = 0.18
    private static let glowBlinks = 2

    private(set) var note: Note
    private let store: NoteStore
    private let scrollView: NSScrollView
    private let textView: NSTextView
    private var pendingSave: DispatchWorkItem?
    /// Texts filed while collapsed; shown as "+N" until expanded.
    private var unseenCount = 0
    /// Called when this sticky leaves the desktop (closed or deleted).
    var onRemove: ((NoteWindowController) -> Void)?

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
        panel.onTitleBarRightClick = { [weak self] event in self?.showTitleBarMenu(event) }

        applyAppearance()
        if note.isCollapsed { applyCollapsed() }
        updateTitleBar()
        applyTimestamps(store.routedTexts(noteID: note.id))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: Text

    var plainText: String { textView.string }

    private var firstLine: String {
        let line = plainText.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return line.trimmingCharacters(in: .whitespaces).isEmpty ? "Note" : line
    }

    private var hasTitle: Bool { !(note.title ?? "").isEmpty }

    func append(_ text: String, toolTip: String? = nil) {
        guard let storage = textView.textStorage else { return }
        var attributes = baseTypingAttributes
        if let toolTip { attributes[.toolTip] = toolTip }
        let needsNewline = storage.length > 0 && !storage.string.hasSuffix("\n")
        storage.append(NSAttributedString(string: (needsNewline ? "\n" : "") + text, attributes: attributes))
        textView.typingAttributes = baseTypingAttributes
        textChanged()
    }

    /// Adds a text you sent yourself as a bullet, with its send time on hover.
    func file(_ text: String, sentAt date: Date) {
        append(Self.bullet + text, toolTip: Self.timestampToolTip(date))
        if note.isCollapsed { unseenCount += 1 }
        updateTitleBar()
        glow()
        saveNow()
    }

    private var baseTypingAttributes: [NSAttributedString.Key: Any] {
        var attributes = textView.typingAttributes
        attributes[.font] = attributes[.font] ?? Self.defaultFont
        attributes[.toolTip] = nil
        return attributes
    }

    private static func timestampToolTip(_ date: Date) -> String {
        "Texted \(date.formatted(date: .abbreviated, time: .shortened))"
    }

    /// Tooltips don't survive saving, so re-attach them to filed lines on load.
    private func applyTimestamps(_ entries: [(text: String, date: Date)]) {
        guard let storage = textView.textStorage else { return }
        let string = storage.string as NSString
        for entry in entries {
            let range = string.range(of: Self.bullet + entry.text)
            if range.location != NSNotFound {
                storage.addAttribute(.toolTip, value: Self.timestampToolTip(entry.date), range: range)
            }
        }
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        // Don't let new typing inherit a filed line's tooltip.
        textView.typingAttributes[.toolTip] = nil
    }

    func textDidChange(_ notification: Notification) {
        textChanged()
    }

    private func textChanged() {
        if note.isCollapsed { updateTitleBar() }
        note.updatedAt = Date()
        scheduleSave()
    }

    // MARK: Title

    private func updateTitleBar() {
        guard let window else { return }
        var text = hasTitle ? note.title! : (note.isCollapsed ? firstLine : "")
        if note.isCollapsed && unseenCount > 0 { text += "  +\(unseenCount)" }
        window.title = text
        window.titleVisibility = text.isEmpty ? .hidden : .visible
    }

    @objc func editTitle(_ sender: Any?) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Sticky Title"
        alert.informativeText = "Titled stickies receive matching texts you send yourself. Leave empty for a plain sticky."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = note.title ?? ""
        field.placeholderString = "e.g. 🛒 Groceries"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            let title = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            note.title = title.isEmpty ? nil : title
            updateTitleBar()
            saveNow()
        }
    }

    private func showTitleBarMenu(_ event: NSEvent) {
        let menu = NSMenu()
        menu.addItem(withTitle: hasTitle ? "Rename…" : "Set Title…", action: #selector(editTitle(_:)), keyEquivalent: "")
        menu.addItem(withTitle: note.isCollapsed ? "Expand" : "Collapse", action: #selector(toggleCollapsed(_:)), keyEquivalent: "")
        menu.items.forEach { $0.target = self }
        if let view = window?.contentView?.superview {
            NSMenu.popUpContextMenu(menu, with: event, for: view)
        }
    }

    /// Quick blink so you notice a text landing here.
    private func glow() {
        guard let window else { return }
        let restingAlpha = note.isTranslucent ? Self.translucentAlpha : 1
        var steps: [CGFloat] = []
        for _ in 0..<Self.glowBlinks { steps += [Self.glowAlpha, restingAlpha] }
        func run(_ remaining: ArraySlice<CGFloat>) {
            guard let next = remaining.first else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = Self.glowStepDuration
                window.animator().alphaValue = next
            }, completionHandler: { run(remaining.dropFirst()) })
        }
        run(steps[...])
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

    // MARK: Closing: empty notes are deleted, others go to Window → Recently Closed

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !hasAttachments && !hasTitle {
            pendingSave?.cancel()
            store.deleteNote(id: note.id)
        } else {
            saveNow()
            store.closeNote(id: note.id)
        }
        pendingSave?.cancel()
        window?.orderOut(nil)
        onRemove?(self)
        return false
    }

    private var hasAttachments: Bool {
        textView.textStorage?.containsAttachments ?? false
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
        if note.isCollapsed {
            applyCollapsed()
        } else {
            unseenCount = 0
            applyExpanded()
        }
        updateTitleBar()
        saveNow()
    }

    private func applyCollapsed() {
        guard let window else { return }
        let titleBarHeight = window.frame.height - window.contentLayoutRect.height
        let expanded = note.frame
        scrollView.isHidden = true
        window.styleMask.remove(.resizable)
        window.setFrame(NSRect(x: expanded.minX, y: expanded.maxY - titleBarHeight,
                               width: expanded.width, height: titleBarHeight), display: true)
    }

    private func applyExpanded() {
        guard let window else { return }
        let top = window.frame.maxY
        window.styleMask.insert(.resizable)
        window.setFrame(NSRect(x: window.frame.minX, y: top - note.frame.height,
                               width: note.frame.width, height: note.frame.height), display: true)
        scrollView.isHidden = false
    }

    @objc func exportNote(_ sender: Any?) {
        guard let window, let storage = textView.textStorage else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.rtf]
        panel.nameFieldStringValue = note.displayName.prefix(40) + ".rtf"
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
        case #selector(editTitle(_:)):
            menuItem.title = hasTitle ? "Rename…" : "Set Title…"
        default:
            break
        }
        return true
    }
}

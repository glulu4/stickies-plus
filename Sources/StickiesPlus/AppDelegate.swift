import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation, NSMenuDelegate {
    private static let defaultNoteSize = NSSize(width: 250, height: 220)
    private static let cascadeOffset: CGFloat = 24
    private static let pollInterval: TimeInterval = 5
    /// On first launch, pull in self-texts from this far back.
    private static let firstImportLookback: TimeInterval = 24 * 60 * 60
    private static let inboxTitle = "📥 Inbox"
    /// Closed stickies stay in Window → Recently Closed this long.
    private static let closedRetention: TimeInterval = 30 * 24 * 60 * 60
    /// How many recent lines of each sticky the router sees as examples.
    private static let routingExampleLines = 5
    private static let recentlyClosedNameLength = 40
    private static let fullDiskAccessURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

    private var store: NoteStore!
    private var controllers: [NoteWindowController] = []
    private var pollTimer: Timer?
    private var hasShownAccessAlert = false
    private var textsStatusItem: NSMenuItem!
    private let recentlyClosedMenu = NSMenu(title: "Recently Closed")
    private let servicesProvider = ServicesProvider()
    private var isRouting = false

    private var chatDBPath: String {
        ProcessInfo.processInfo.environment["STICKIESPLUS_CHAT_DB"]
            ?? NSHomeDirectory() + "/Library/Messages/chat.db"
    }

    private var dataDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["STICKIESPLUS_DATA_DIR"] {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StickiesPlus")
    }

    private var isWatchingTexts: Bool {
        store.setting(SettingKey.watchTexts) != "0"
    }

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            store = try NoteStore(directory: dataDirectory)
        } catch {
            NSAlert(error: error).runModal()
            NSApp.terminate(nil)
            return
        }
        NSApp.mainMenu = buildMainMenu()

        servicesProvider.onText = { [weak self] text in self?.newNote(with: text) }
        NSApp.servicesProvider = servicesProvider
        NSUpdateDynamicServices()

        store.purgeClosedNotes(olderThan: Self.closedRetention)
        titleInboxIfNeeded()

        let notes = store.allNotes()
        if notes.isEmpty {
            newNote(with: """
                Welcome to Stickies Plus!

                Right-click a sticky's title bar → Set Title… (e.g. "🛒 Groceries"). \
                Texts you send yourself land on the sticky they fit, or in 📥 Inbox.
                """)
        } else {
            notes.filter { $0.closedAt == nil }.forEach { show($0) }
        }

        importTexts(userInitiated: false)
        routePendingTexts()
        pollTimer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.importTexts(userInitiated: false) }
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        controllers.forEach { $0.saveNow() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if controllers.isEmpty { newNote(nil) }
        return true
    }

    // MARK: Notes

    @discardableResult
    private func show(_ note: Note) -> NoteWindowController {
        var note = note
        if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(note.frame) }) {
            note.frame.origin = defaultOrigin(for: note.frame.size)  // its screen was disconnected
        }
        let controller = NoteWindowController(note: note, store: store)
        controller.onRemove = { [weak self] removed in
            self?.controllers.removeAll { $0 === removed }
        }
        controllers.append(controller)
        controller.showWindow(nil)
        return controller
    }

    private func defaultOrigin(for size: NSSize) -> NSPoint {
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        return NSPoint(x: visible.minX + 40, y: visible.maxY - 40 - size.height)
    }

    @objc func newNote(_ sender: Any?) {
        newNote(with: nil)
    }

    @discardableResult
    private func newNote(with text: String?, color: NoteColor = .yellow, title: String? = nil) -> NoteWindowController {
        var frame = NSRect(origin: defaultOrigin(for: Self.defaultNoteSize), size: Self.defaultNoteSize)
        if let key = NSApp.keyWindow, controllers.contains(where: { $0.window === key }) {
            frame.origin = NSPoint(x: key.frame.minX + Self.cascadeOffset,
                                   y: key.frame.maxY - Self.cascadeOffset - frame.height)
        }
        let controller = show(store.createNote(frame: frame, color: color, title: title))
        if let text { controller.append(text) }
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return controller
    }

    @objc func arrangeByColor(_ sender: Any?) {
        let order = NoteColor.allCases
        arrange(controllers.sorted {
            (order.firstIndex(of: $0.note.color)!, $0.note.id) < (order.firstIndex(of: $1.note.color)!, $1.note.id)
        })
    }

    @objc func arrangeByDate(_ sender: Any?) {
        arrange(controllers.sorted { $0.note.updatedAt > $1.note.updatedAt })
    }

    private func arrange(_ sorted: [NoteWindowController]) {
        let visible = NSScreen.main?.visibleFrame ?? .zero
        for (index, controller) in sorted.enumerated() {
            let offset = CGFloat(index) * Self.cascadeOffset
            controller.move(topLeft: NSPoint(x: visible.minX + 20 + offset, y: visible.maxY - 20 - offset))
            controller.window?.orderFront(nil)
        }
    }

    // MARK: Recently Closed

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === recentlyClosedMenu else { return }
        menu.removeAllItems()
        let closed = store.closedNotes()
        if closed.isEmpty {
            let empty = NSMenuItem(title: "No Recently Closed Stickies", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }
        for note in closed {
            var name = note.displayName
            if name.count > Self.recentlyClosedNameLength {
                name = String(name.prefix(Self.recentlyClosedNameLength)) + "…"
            }
            let entry = item(name, #selector(reopenClosedNote(_:)), "", target: self, tag: Int(note.id))
            entry.toolTip = "Closed \(note.closedAt!.formatted(.relative(presentation: .named)))"
            menu.addItem(entry)
        }
    }

    @objc func reopenClosedNote(_ sender: NSMenuItem) {
        let id = Int64(sender.tag)
        store.reopenNote(id: id)
        guard let note = store.allNotes().first(where: { $0.id == id }) else { return }
        show(note).window?.makeKeyAndOrderFront(nil)
    }

    // MARK: Texts to self

    /// The 📥 sticky used to have a header line instead of a title; give it the title.
    private func titleInboxIfNeeded() {
        guard let id = store.setting(SettingKey.inboxNoteID).flatMap(Int64.init),
              var inbox = store.allNotes().first(where: { $0.id == id }),
              (inbox.title ?? "").isEmpty else { return }
        inbox.title = Self.inboxTitle
        store.save(inbox)
    }

    private var inboxNoteID: Int64? {
        store.setting(SettingKey.inboxNoteID).flatMap(Int64.init)
    }

    /// The 📥 Inbox sticky, reopened or recreated if needed.
    private var inboxController: NoteWindowController {
        if let id = inboxNoteID {
            if let existing = controllers.first(where: { $0.note.id == id }) { return existing }
            if store.allNotes().contains(where: { $0.id == id }) {
                store.reopenNote(id: id)
                if let note = store.allNotes().first(where: { $0.id == id }) { return show(note) }
            }
        }
        let inbox = newNote(with: nil, color: .blue, title: Self.inboxTitle)
        store.setSetting(SettingKey.inboxNoteID, String(inbox.note.id))
        return inbox
    }

    @objc func importTextsNow(_ sender: Any?) {
        importTexts(userInitiated: true)
    }

    private func importTexts(userInitiated: Bool) {
        guard userInitiated || isWatchingTexts else { return }
        let importer = MessagesImporter(
            chatDBPath: chatDBPath,
            extraHandles: (store.setting(SettingKey.selfHandles) ?? "").split(separator: ",").map(String.init))
        do {
            let latest = try importer.latestRowID()
            let lastSeen = store.setting(SettingKey.messagesLastRowID).flatMap(Int64.init)
            let texts = try importer.selfTexts(
                afterRowID: lastSeen ?? 0, upToRowID: latest,
                since: lastSeen == nil ? Date().addingTimeInterval(-Self.firstImportLookback) : nil)
            texts.forEach { store.insertText($0) }
            store.setSetting(SettingKey.messagesLastRowID, String(latest))
            textsStatusItem.title = "Last checked \(Date().formatted(date: .omitted, time: .shortened))"
            routePendingTexts()
        } catch {
            textsStatusItem.title = "⚠︎ Needs Full Disk Access"
            if userInitiated || !hasShownAccessAlert { showAccessAlert(error) }
        }
    }

    /// Files waiting texts one at a time onto the sticky they fit (or the inbox).
    private func routePendingTexts() {
        guard !isRouting else { return }
        let pending = store.pendingTexts()
        guard !pending.isEmpty else { return }
        isRouting = true
        Task { @MainActor in
            for item in pending {
                let inboxID = inboxNoteID
                let candidates = controllers
                    .filter { !($0.note.title ?? "").isEmpty && $0.note.id != inboxID }
                    .map(routeCandidate)
                let inbox = controllers.first { $0.note.id == inboxID }.map(routeCandidate)
                let route = await StickyRouter.route(item.text, candidates: candidates, inbox: inbox)
                // The chosen sticky may have been closed while the model was thinking.
                let target = controllers.first { $0.note.id == route.noteID } ?? inboxController
                target.file(route.text, sentAt: item.date)
                store.markRouted(textID: item.id, noteID: target.note.id, filedText: route.text)
            }
            isRouting = false
            routePendingTexts()  // pick up anything that arrived meanwhile
        }
    }

    private func routeCandidate(_ controller: NoteWindowController) -> RouteCandidate {
        let lines = controller.plainText.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .map { $0.hasPrefix(NoteWindowController.bullet) ? String($0.dropFirst(NoteWindowController.bullet.count)) : $0 }
            .filter { !$0.isEmpty }
        return RouteCandidate(noteID: controller.note.id, title: controller.note.title ?? "",
                              recentLines: Array(lines.suffix(Self.routingExampleLines)))
    }

    private func showAccessAlert(_ error: Error) {
        hasShownAccessAlert = true
        let alert = NSAlert()
        alert.messageText = "Stickies Plus can’t read your Messages yet"
        alert.informativeText = """
            To pull in texts you send yourself, turn on Stickies Plus under \
            System Settings → Privacy & Security → Full Disk Access, then reopen the app.

            (\(error))
            """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Not Now")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(Self.fullDiskAccessURL)
        }
    }

    @objc func toggleWatchingTexts(_ sender: Any?) {
        store.setSetting(SettingKey.watchTexts, isWatchingTexts ? "0" : "1")
    }

    @objc func showInbox(_ sender: Any?) {
        inboxController.window?.makeKeyAndOrderFront(nil)
    }

    @objc func setSelfHandles(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Your phone numbers and emails"
        alert.informativeText = "Usually detected automatically. If texts to yourself aren’t showing up, list the numbers or Apple ID emails you text yourself at, separated by commas."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.stringValue = store.setting(SettingKey.selfHandles) ?? ""
        field.placeholderString = "+1 555 123 4567, me@icloud.com"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let value = field.stringValue.trimmingCharacters(in: .whitespaces)
        store.setSetting(SettingKey.selfHandles, value.isEmpty ? nil : value)
    }

    @objc func openFullDiskAccess(_ sender: Any?) {
        NSWorkspace.shared.open(Self.fullDiskAccessURL)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleWatchingTexts(_:)) {
            menuItem.state = isWatchingTexts ? .on : .off
        }
        return true
    }

    // MARK: Menus

    private func buildMainMenu() -> NSMenu {
        let main = NSMenu()

        let app = NSMenu()
        app.addItem(withTitle: "About Stickies Plus", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        let services = NSMenu()
        app.addItem(withTitle: "Services", action: nil, keyEquivalent: "").submenu = services
        NSApp.servicesMenu = services
        app.addItem(.separator())
        app.addItem(withTitle: "Hide Stickies Plus", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        app.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit Stickies Plus", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu(app, "Stickies Plus"))

        let file = NSMenu(title: "File")
        file.addItem(item("New Note", #selector(newNote(_:)), "n", target: self))
        file.addItem(item("Close", #selector(NSWindow.performClose(_:)), "w"))
        file.addItem(.separator())
        file.addItem(item("Export Note…", #selector(NoteWindowController.exportNote(_:)), "e", [.command, .shift]))
        file.addItem(item("Print…", #selector(NSView.printView(_:)), "p"))
        main.addItem(submenu(file))

        let edit = NSMenu(title: "Edit")
        edit.addItem(item("Undo", Selector(("undo:")), "z"))
        edit.addItem(item("Redo", Selector(("redo:")), "z", [.command, .shift]))
        edit.addItem(.separator())
        edit.addItem(item("Cut", #selector(NSText.cut(_:)), "x"))
        edit.addItem(item("Copy", #selector(NSText.copy(_:)), "c"))
        edit.addItem(item("Paste", #selector(NSText.paste(_:)), "v"))
        edit.addItem(item("Paste and Match Style", #selector(NSTextView.pasteAsPlainText(_:)), "v", [.command, .option, .shift]))
        edit.addItem(item("Select All", #selector(NSText.selectAll(_:)), "a"))
        edit.addItem(.separator())
        let find = NSMenu(title: "Find")
        find.addItem(findItem("Find…", "f", NSTextFinder.Action.showFindInterface))
        find.addItem(findItem("Find Next", "g", NSTextFinder.Action.nextMatch))
        find.addItem(findItem("Find Previous", "G", NSTextFinder.Action.previousMatch))
        find.addItem(findItem("Use Selection for Find", "e", NSTextFinder.Action.setSearchString))
        edit.addItem(submenu(find))
        main.addItem(submenu(edit))

        let format = NSMenu(title: "Format")
        let fonts = NSFontManager.shared
        format.addItem(item("Show Fonts", #selector(NSFontManager.orderFrontFontPanel(_:)), "t", target: fonts))
        format.addItem(item("Bold", #selector(NSFontManager.addFontTrait(_:)), "b", target: fonts, tag: Int(NSFontTraitMask.boldFontMask.rawValue)))
        format.addItem(item("Italic", #selector(NSFontManager.addFontTrait(_:)), "i", target: fonts, tag: Int(NSFontTraitMask.italicFontMask.rawValue)))
        format.addItem(item("Underline", #selector(NSText.underline(_:)), "u"))
        format.addItem(item("Bigger", #selector(NSFontManager.modifyFont(_:)), "+", target: fonts, tag: Int(NSFontAction.sizeUpFontAction.rawValue)))
        format.addItem(item("Smaller", #selector(NSFontManager.modifyFont(_:)), "-", target: fonts, tag: Int(NSFontAction.sizeDownFontAction.rawValue)))
        format.addItem(.separator())
        format.addItem(item("Show Colors", #selector(NSApplication.orderFrontColorPanel(_:)), "C"))
        format.addItem(.separator())
        format.addItem(item("Align Left", #selector(NSText.alignLeft(_:)), "{"))
        format.addItem(item("Center", #selector(NSText.alignCenter(_:)), "|"))
        format.addItem(item("Align Right", #selector(NSText.alignRight(_:)), "}"))
        format.addItem(.separator())
        format.addItem(item("Check Spelling While Typing", #selector(NSTextView.toggleContinuousSpellChecking(_:)), ""))
        main.addItem(submenu(format))

        let note = NSMenu(title: "Note")
        for (index, color) in NoteColor.allCases.enumerated() {
            let colorItem = item(color.title, #selector(NoteWindowController.setNoteColor(_:)), "\(index + 1)")
            colorItem.representedObject = color.rawValue
            note.addItem(colorItem)
        }
        note.addItem(.separator())
        note.addItem(item("Float on Top", #selector(NoteWindowController.toggleFloating(_:)), "f", [.command, .option]))
        note.addItem(item("Translucent", #selector(NoteWindowController.toggleTranslucent(_:)), "t", [.command, .option]))
        note.addItem(item("Collapse", #selector(NoteWindowController.toggleCollapsed(_:)), "c", [.command, .option]))
        note.addItem(.separator())
        note.addItem(item("Set Title…", #selector(NoteWindowController.editTitle(_:)), "T"))
        main.addItem(submenu(note))

        let texts = NSMenu(title: "Texts")
        texts.autoenablesItems = true
        texts.addItem(item("Import Texts to Self Now", #selector(importTextsNow(_:)), "i", [.command, .shift], target: self))
        texts.addItem(item("Watch for New Texts", #selector(toggleWatchingTexts(_:)), "", target: self))
        texts.addItem(item("Show Inbox Note", #selector(showInbox(_:)), "", target: self))
        texts.addItem(.separator())
        texts.addItem(item("My Numbers & Emails…", #selector(setSelfHandles(_:)), "", target: self))
        texts.addItem(item("Open Full Disk Access Settings…", #selector(openFullDiskAccess(_:)), "", target: self))
        texts.addItem(.separator())
        textsStatusItem = NSMenuItem(title: "Not checked yet", action: nil, keyEquivalent: "")
        textsStatusItem.isEnabled = false
        texts.addItem(textsStatusItem)
        main.addItem(submenu(texts))

        let window = NSMenu(title: "Window")
        recentlyClosedMenu.delegate = self
        window.addItem(submenu(recentlyClosedMenu))
        window.addItem(.separator())
        window.addItem(item("Arrange by Color", #selector(arrangeByColor(_:)), "", target: self))
        window.addItem(item("Arrange by Date", #selector(arrangeByDate(_:)), "", target: self))
        window.addItem(.separator())
        window.addItem(item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:)), ""))
        main.addItem(submenu(window))
        NSApp.windowsMenu = window

        return main
    }

    private func item(_ title: String, _ action: Selector, _ key: String,
                      _ modifiers: NSEvent.ModifierFlags = .command,
                      target: AnyObject? = nil, tag: Int = 0) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: key)
        menuItem.keyEquivalentModifierMask = modifiers
        menuItem.target = target
        menuItem.tag = tag
        return menuItem
    }

    private func findItem(_ title: String, _ key: String, _ action: NSTextFinder.Action) -> NSMenuItem {
        item(title, #selector(NSTextView.performFindPanelAction(_:)), key, tag: action.rawValue)
    }

    private func submenu(_ menu: NSMenu, _ title: String? = nil) -> NSMenuItem {
        let holder = NSMenuItem(title: title ?? menu.title, action: nil, keyEquivalent: "")
        holder.submenu = menu
        return holder
    }
}

/// Handles the "Make New Sticky Note" entry in every app's Services menu.
final class ServicesProvider: NSObject {
    var onText: ((String) -> Void)?

    @objc func makeSticky(_ pboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        if let text = pboard.string(forType: .string) { onText?(text) }
    }
}

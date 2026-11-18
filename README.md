# Stickies Plus

A personal, native macOS take on Stickies that also pulls in texts you send yourself.

## Features
- Sticky note windows with rich text, images, fonts, alignment, find, spell check and print
- Six note colors, Float on Top, Translucent, and collapse by double-clicking the title bar
- Arrange notes by color or date; export a note as RTF
- **Make New Sticky Note** in every app's Services menu (right-click selected text)
- **Texts to Self**: messages you text yourself land in a blue 📥 inbox note within about 5 seconds
- **Notes Library** (⌘0): a white, Notes-app-style window with a sidebar, note list and editor.
  Every sticky shows up here too. Close a sticky and it moves to the library; "Show as Sticky" puts it back.
- **Auto-sorted texts**: each self-text is classified as To-Do, Idea, Shopping, Link or Other by Apple's
  on-device model (nothing leaves your Mac). To-dos get checkboxes. Recategorize from the right-click menu.
  Without Apple Intelligence it falls back to simple keyword rules.

Requires macOS 26 or later.

Notes are stored in SQLite at `~/Library/Application Support/StickiesPlus/notes.sqlite`.

## Build & install
```bash
./scripts/build-app.sh --install
```
This installs to `~/Applications/Stickies Plus.app`.

## Reading your texts
The app reads `~/Library/Messages/chat.db` (read-only), so it needs **Full Disk Access**:
System Settings → Privacy & Security → Full Disk Access → turn on Stickies Plus, then reopen it.
Rebuilding changes the ad-hoc signature, so you may need to turn it off and on again after a rebuild.

Your own numbers and emails are detected automatically. If self-texts don't show up, set them in
**Texts → My Numbers & Emails…**. On first launch it imports self-texts from the last 24 hours,
then only new ones.

## Testing against a fake Messages database
```bash
STICKIESPLUS_CHAT_DB=/path/to/fake/chat.db STICKIESPLUS_DATA_DIR=/tmp/stickies-test \
  "build/Stickies Plus.app/Contents/MacOS/StickiesPlus"
```

## Regenerating the icon
```bash
swift scripts/make-icon.swift && iconutil -c icns AppIcon.iconset -o Resources/AppIcon.icns && rm -r AppIcon.iconset
```

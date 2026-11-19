# Stickies Plus

A personal, native macOS take on Stickies that also pulls in texts you send yourself.

## Features
- Sticky note windows with rich text, images, fonts, alignment, find, spell check and print
- Six note colors, Float on Top, Translucent, and collapse by double-clicking the title bar
- Arrange notes by color or date; export a note as RTF
- **Make New Sticky Note** in every app's Services menu (right-click selected text)
- **Texts to Self, filed automatically**: give a sticky a title (right-click its title bar → Set Title…,
  or ⌘⇧T), e.g. "🛒 Groceries". Texts you send yourself land on the titled sticky they fit within about
  5 seconds, or in **📥 Inbox** when nothing fits. Untitled stickies never receive texts.
  - Shortcut: start a text with a title to skip the guessing: `groceries: eggs`, `groc: eggs` or `#groceries eggs`
    (case and emoji ignored, a unique beginning is enough; the prefix is removed).
  - Otherwise Apple's on-device model picks, using each sticky's title and last few lines as examples.
    Nothing leaves your Mac. Without Apple Intelligence, only the shortcut works and the rest goes to the inbox.
  - The receiving sticky blinks; collapsed stickies show "+N". Hover a filed line to see when you sent it.
- **Recently Closed** (Window menu): closing a sticky keeps it for 30 days so you can reopen it.
  Closing an empty, untitled sticky deletes it.

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

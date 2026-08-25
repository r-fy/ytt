import AppKit

// Puts text at the cursor of the frontmost app: pasteboard + synthetic Cmd+V,
// then restores what was on the pasteboard before. Best effort: a clipboard
// manager that rewrites the pasteboard inside the restore window wins.
// Keystroke timings (8 ms between down and up, 20 ms settle) copied from
// OpenWhispr's macos-fast-paste.swift.
enum TextInjector {
    // Later phases read these. Written from Phase 3 on.
    private(set) static var lastInserted: String?
    private(set) static var lastInsertedAt: Date?

    // The pasteboard from before the first of any run of back-to-back
    // inserts. Only replaced once that run's restore has happened, so two
    // quick dictations cannot end up "restoring" our own first paste.
    private static var original: [SavedItem]?
    private static var lastChange = 0
    private static var pendingRestore: DispatchWorkItem?

    // Skips the paste when the user switched apps between releasing the key
    // and the transcript arriving. The text stays on the pasteboard so a
    // manual Cmd+V still gets it.
    static func insert(_ text: String, intendedTarget: pid_t?) {
        guard !text.isEmpty else { return }
        guard AXIsProcessTrusted() else {
            Log.warn("Accessibility not granted, cannot paste")
            return
        }
        let front = NSWorkspace.shared.frontmostApplication
        if let intendedTarget, let front, front.processIdentifier != intendedTarget {
            Log.warn("PASTE_SKIPPED front app changed to \(front.localizedName ?? "?"), text left on the pasteboard")
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            return
        }

        let pb = NSPasteboard.general
        pendingRestore?.cancel()
        if original == nil { original = snapshot(pb) }

        pb.clearContents()
        pb.setString(text, forType: .string)
        lastChange = pb.changeCount

        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: 0x09, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: 0x09, keyDown: false) else {
            Log.warn("cannot build Cmd+V event")
            return
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cgSessionEventTap)
        usleep(8_000)
        keyUp.post(tap: .cgSessionEventTap)
        usleep(20_000)

        lastInserted = text
        lastInsertedAt = Date()
        Log.info("PASTED chars=\(text.count) into=\(front?.localizedName ?? "?")")

        // Give slow apps (Electron, browsers) time to read the pasteboard
        // before it goes back. Skip the restore if something else wrote it.
        let work = DispatchWorkItem {
            pendingRestore = nil
            let saved = original
            original = nil
            guard pb.changeCount == lastChange, let saved else {
                Log.info("pasteboard changed by another app, restore skipped")
                return
            }
            restore(pb, saved)
        }
        pendingRestore = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private struct SavedItem {
        let data: [NSPasteboard.PasteboardType: Data]
    }

    private static func snapshot(_ pb: NSPasteboard) -> [SavedItem] {
        (pb.pasteboardItems ?? []).map { item in
            var d: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { d[type] = data }
            }
            return SavedItem(data: d)
        }
    }

    private static func restore(_ pb: NSPasteboard, _ items: [SavedItem]) {
        pb.clearContents()
        guard !items.isEmpty else { return }
        let restored = items.map { saved -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in saved.data { item.setData(data, forType: type) }
            return item
        }
        pb.writeObjects(restored)
    }
}

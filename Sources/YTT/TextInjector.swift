import AppKit

// Puts text at the cursor of the frontmost app: pasteboard + synthetic Cmd+V,
// then restores what was on the pasteboard before.
// Keystroke timings (8 ms between down and up, 20 ms settle) copied from
// OpenWhispr's macos-fast-paste.swift.
enum TextInjector {
    // Phase 8's correction watcher reads these. Written from Phase 3 on.
    private(set) static var lastInserted: String?
    private(set) static var lastInsertedAt: Date?

    static func insert(_ text: String) {
        guard !text.isEmpty else { return }
        guard AXIsProcessTrusted() else {
            Log.warn("Accessibility not granted, cannot paste")
            return
        }
        let pb = NSPasteboard.general
        let saved = snapshot(pb)

        pb.clearContents()
        pb.setString(text, forType: .string)
        let ourChange = pb.changeCount

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
        Log.info("PASTED chars=\(text.count) into=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")")

        // Give slow apps (Electron, browsers) time to read the pasteboard
        // before it goes back. Skip the restore if something else wrote it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            guard pb.changeCount == ourChange else { return }
            restore(pb, saved)
        }
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

import AppKit

protocol GlobeKeyListenerDelegate: AnyObject {
    func globeKeyDown()
    func globeKeyUp(interrupted: Bool, heldSeconds: Double)
}

// In-process Globe (Fn) key monitor. Phase 0 showed the global monitor
// survives sleep/wake on this Mac, so no helper process or supervision.
final class GlobeKeyListener {
    weak var delegate: GlobeKeyListenerDelegate?

    private var fnIsDown = false
    private var fnInterrupted = false
    private var fnDownAt = Date()
    private var flagsMonitor: Any?
    private var keyMonitor: Any?

    // Returns false when Accessibility is missing (the monitor is created but never fires).
    @discardableResult
    func start() -> Bool {
        guard AXIsProcessTrusted() else {
            Log.warn("Accessibility not granted, Globe key will not be seen")
            return false
        }
        flagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlags(event.modifierFlags.contains(.function))
        }
        // Another key pressed while Fn is held (Fn+Arrow = Home, etc) means a
        // shortcut, not a dictation. Phase 0: macOS on this Mac delivers no key
        // events while Globe is held, so this is a safety net only.
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] _ in
            guard let self, self.fnIsDown, !self.fnInterrupted else { return }
            self.fnInterrupted = true
            Log.info("FN_INTERRUPTED")
        }
        return flagsMonitor != nil
    }

    func stop() {
        if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        flagsMonitor = nil
        keyMonitor = nil
    }

    private func handleFlags(_ containsFn: Bool) {
        if containsFn && !fnIsDown {
            fnIsDown = true
            fnInterrupted = false
            fnDownAt = Date()
            delegate?.globeKeyDown()
        } else if !containsFn && fnIsDown {
            fnIsDown = false
            let held = Date().timeIntervalSince(fnDownAt)
            let interrupted = fnInterrupted
            fnInterrupted = false
            delegate?.globeKeyUp(interrupted: interrupted, heldSeconds: held)
        }
    }
}

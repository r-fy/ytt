// YTT spike: Globe (Fn) key listener, shared by the spike mains.
//
// Derived from OpenWhispr's resources/macos-globe-listener.swift (MIT).
// Stripped: mouse button event tap, right-modifier tracking, MODIFIER_UP
// reporting, and stdin reconfiguration. Added: timestamps, hold duration,
// and onFnDown/onFnUp callbacks.
//
// Build (see README.md):
//   swiftc -O spike/GlobeListener.swift spike/globe/main.swift -o spike/globe-spike
//
// stdout lines: FN_DOWN, FN_UP (with hold ms), FN_INTERRUPTED.

import Cocoa
import Darwin

var fnIsDown = false
var fnInterrupted = false
var fnDownAt: Date?

let startedAt = Date()

func stamp() -> String {
    String(format: "[%8.3fs]", Date().timeIntervalSince(startedAt))
}

func emit(_ message: String) {
    FileHandle.standardOutput.write((stamp() + " " + message + "\n").data(using: .utf8)!)
    fflush(stdout)
}

func emitWarning(_ message: String) {
    FileHandle.standardError.write((stamp() + " " + message + "\n").data(using: .utf8)!)
}

func parseArguments() -> (suppress: Bool, statePath: String?) {
    var suppress = false
    var statePath: String?
    var arguments = CommandLine.arguments.dropFirst().makeIterator()
    while let argument = arguments.next() {
        switch argument {
        case "--suppress-system-globe-action":
            suppress = true
        case "--globe-preference-state":
            statePath = arguments.next()
        default:
            emitWarning("Ignored unknown argument: \(argument)")
        }
    }
    return (suppress, statePath)
}

struct GlobePreferenceState: Codable {
    let version: Int
    let originalValue: Int32
    let keyExisted: Bool
}

// macOS runs the standalone Globe action (emoji viewer, input-source switch,
// dictation) from WindowServer ahead of every event tap, so a listener cannot
// consume the key. The only way to stop it firing alongside our hotkey is to
// hold AppleFnUsageType at "Do Nothing" while we own the key.
// TISUpdateFnUsageType is what System Settings itself calls: it persists the
// preference and broadcasts the change so it applies live. Writing the
// preference directly is ignored until the user's next login.
enum GlobeSystemAction {
    private typealias GetUsageType = @convention(c) () -> Int32
    private typealias UpdateUsageType = @convention(c) (Int32) -> Void

    private static let doNothing: Int32 = 0
    private static let stateVersion = 1
    private static let domain = "com.apple.HIToolbox" as CFString
    private static let key = "AppleFnUsageType" as CFString

    private static let entryPoints: (get: GetUsageType, update: UpdateUsageType)? = {
        guard let carbon = dlopen("/System/Library/Frameworks/Carbon.framework/Carbon", RTLD_LAZY),
              let get = dlsym(carbon, "TISGetFnUsageType"),
              let update = dlsym(carbon, "TISUpdateFnUsageType")
        else { return nil }
        return (unsafeBitCast(get, to: GetUsageType.self), unsafeBitCast(update, to: UpdateUsageType.self))
    }()

    static var statePath: String?
    private static var owned: GlobePreferenceState?

    static func currentValue() -> Int32? { entryPoints?.get() }

    // Adopts a marker left by a crashed run so its recorded original value is
    // used instead of mistaking our own override for the user's preference.
    static func recoverLeftoverState() {
        guard let state = readMarker(), let entryPoints else { return }
        if entryPoints.get() == doNothing {
            emit("RECOVERED_MARKER original=\(state.originalValue)")
            owned = state
        } else {
            // The user picked a new action since we died. Theirs wins.
            removeMarker()
        }
    }

    static func apply() {
        guard owned == nil else { return }
        guard let entryPoints else {
            emitWarning("Cannot suppress the macOS Globe action: TISUpdateFnUsageType unavailable")
            return
        }

        let original = entryPoints.get()
        guard original != doNothing else {
            emit("GLOBE_ACTION already Do Nothing, nothing to suppress")
            return
        }

        let state = GlobePreferenceState(
            version: stateVersion,
            originalValue: original,
            keyExisted: rawValueExists()
        )
        // Record how to get back before changing anything.
        guard writeMarker(state) else { return }

        owned = state
        entryPoints.update(doNothing)
        emit("GLOBE_ACTION suppressed (was \(original), now \(entryPoints.get()))")
    }

    static func restore() {
        guard let state = owned, let entryPoints else { return }
        owned = nil

        // Only put the value back while it is still ours: if the user picked a
        // new action while we were running, that choice wins.
        if entryPoints.get() == doNothing {
            entryPoints.update(state.originalValue)
            // The value was a macOS-computed default before we touched it, so
            // clear the key again to keep it tracking hardware and input sources.
            if !state.keyExisted {
                clearRawValue()
            }
            emit("GLOBE_ACTION restored to \(state.originalValue) (now \(entryPoints.get()))")
        }

        removeMarker()
    }

    // CFPreferencesCopyAppValue caches foreign domains for the life of the
    // process and would miss changes made after launch.
    private static func rawValueExists() -> Bool {
        CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        return CFPreferencesCopyValue(key, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) != nil
    }

    private static func clearRawValue() {
        CFPreferencesSetValue(key, nil, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }

    private static func readMarker() -> GlobePreferenceState? {
        guard let statePath, let data = FileManager.default.contents(atPath: statePath) else { return nil }
        guard let state = try? JSONDecoder().decode(GlobePreferenceState.self, from: data),
              state.version == stateVersion
        else {
            removeMarker()
            return nil
        }
        return state
    }

    private static func writeMarker(_ state: GlobePreferenceState) -> Bool {
        guard let statePath else {
            emitWarning("Cannot suppress the macOS Globe action: no state path provided")
            return false
        }
        do {
            let dir = URL(fileURLWithPath: statePath).deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try JSONEncoder().encode(state).write(to: URL(fileURLWithPath: statePath), options: .atomic)
            return true
        } catch {
            emitWarning("Cannot suppress the macOS Globe action: \(error.localizedDescription)")
            return false
        }
    }

    private static func removeMarker() {
        guard let statePath else { return }
        try? FileManager.default.removeItem(atPath: statePath)
    }
}

// Callbacks a spike main.swift plugs into.
var onFnDown: () -> Void = {}
var onFnUp: (_ interrupted: Bool) -> Void = { _ in }
var onShutdown: () -> Void = {}

var globeMonitor: Any?
var keyMonitor: Any?
var terminationSources: [DispatchSourceSignal] = []

func shutdownListener() -> Never {
    emit("SHUTDOWN")
    onShutdown()
    GlobeSystemAction.restore()
    if let globeMonitor { NSEvent.removeMonitor(globeMonitor) }
    if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    exit(0)
}

func installTerminationSource(for signalNumber: Int32) -> DispatchSourceSignal {
    signal(signalNumber, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
    source.setEventHandler { shutdownListener() }
    source.resume()
    return source
}

// Parses arguments, installs the Fn monitors, suppresses the system Globe
// action if asked, then runs the app loop forever. Set onFnDown/onFnUp first.
func runGlobeListener() -> Never {
    let launchOptions = parseArguments()
    GlobeSystemAction.statePath = launchOptions.statePath
    GlobeSystemAction.recoverLeftoverState()

    emit("STARTED pid=\(getpid()) accessibilityTrusted=\(AXIsProcessTrusted()) globeAction=\(GlobeSystemAction.currentValue().map(String.init) ?? "unknown")")

    guard let monitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: { event in
        let containsFn = event.modifierFlags.contains(.function)

        if containsFn && !fnIsDown {
            fnIsDown = true
            fnInterrupted = false
            fnDownAt = Date()
            emit("FN_DOWN")
            onFnDown()
        } else if !containsFn && fnIsDown {
            fnIsDown = false
            let heldMs = Int((Date().timeIntervalSince(fnDownAt ?? Date())) * 1000)
            emit(fnInterrupted ? "FN_UP held=\(heldMs)ms (after interrupt, would discard)" : "FN_UP held=\(heldMs)ms")
            let wasInterrupted = fnInterrupted
            fnInterrupted = false
            onFnUp(wasInterrupted)
        }
    }) else {
        emitWarning("Failed to create event monitor (Accessibility permission missing?)")
        GlobeSystemAction.restore()
        exit(1)
    }
    globeMonitor = monitor

    // Another key pressed while Fn is held (e.g. Fn+Arrow = Home) means this is
    // a normal keyboard shortcut, not a dictation. Cancel instead of recording noise.
    // Phase 0 note: on this Mac, macOS delivers no key events while Globe is
    // held, so this never fires here. Kept because it is harmless.
    keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
        if fnIsDown && !fnInterrupted {
            fnInterrupted = true
            emit("FN_INTERRUPTED keyCode=\(event.keyCode)")
        }
    }

    // Only take over the system Globe action once the listener is known to work.
    if launchOptions.suppress {
        GlobeSystemAction.apply()
    }

    // Held for the process lifetime: releasing these sources would drop the signal
    // handlers and with them the preference restore on quit.
    terminationSources = [SIGTERM, SIGINT, SIGHUP].map(installTerminationSource(for:))

    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.run()
    exit(0)
}

import Foundation

// macOS runs the standalone Globe action (emoji viewer, input-source switch,
// dictation) from WindowServer ahead of every event tap, so a listener cannot
// consume the key. The only way to stop it firing alongside our hotkey is to
// hold AppleFnUsageType at "Do Nothing" while we own the key.
// TISUpdateFnUsageType is what System Settings itself calls: it persists the
// preference and broadcasts the change so it applies live. Writing the
// preference directly is ignored until the user's next login.
//
// Ported from OpenWhispr's macos-globe-listener.swift (MIT). Verified working
// on macOS 26 in Phase 0.
enum GlobeSystemAction {
    private typealias GetUsageType = @convention(c) () -> Int32
    private typealias UpdateUsageType = @convention(c) (Int32) -> Void

    struct State: Codable {
        let version: Int
        let originalValue: Int32
        let keyExisted: Bool
    }

    private static let doNothing: Int32 = 0
    private static let stateVersion = 1
    private static let domain = "com.apple.HIToolbox" as CFString
    private static let key = "AppleFnUsageType" as CFString

    static let statePath = NSHomeDirectory() + "/Library/Application Support/YTT/globe-preference-state.json"

    private static let entryPoints: (get: GetUsageType, update: UpdateUsageType)? = {
        guard let carbon = dlopen("/System/Library/Frameworks/Carbon.framework/Carbon", RTLD_LAZY),
              let get = dlsym(carbon, "TISGetFnUsageType"),
              let update = dlsym(carbon, "TISUpdateFnUsageType")
        else { return nil }
        return (unsafeBitCast(get, to: GetUsageType.self), unsafeBitCast(update, to: UpdateUsageType.self))
    }()

    private static var owned: State?

    static var available: Bool { entryPoints != nil }
    static func currentValue() -> Int32? { entryPoints?.get() }

    // Adopts a marker left by a crashed run so its recorded original value is
    // used instead of mistaking our own override for the user's preference.
    static func recoverLeftoverState() {
        guard let state = readMarker(), let entryPoints else { return }
        if entryPoints.get() == doNothing {
            Log.info("GLOBE_ACTION recovered marker, original=\(state.originalValue)")
            owned = state
        } else {
            removeMarker()
        }
    }

    static func apply() {
        guard owned == nil else { return }
        guard let entryPoints else {
            Log.warn("Cannot suppress the macOS Globe action: TISUpdateFnUsageType unavailable")
            return
        }
        let original = entryPoints.get()
        guard original != doNothing else { return }

        let state = State(version: stateVersion, originalValue: original, keyExisted: rawValueExists())
        guard writeMarker(state) else { return }
        owned = state
        entryPoints.update(doNothing)
        Log.info("GLOBE_ACTION suppressed (was \(original))")
    }

    static func restore() {
        guard let state = owned, let entryPoints else { return }
        owned = nil
        // Only put the value back while it is still ours: if the user picked a
        // new action while we were running, that choice wins.
        if entryPoints.get() == doNothing {
            entryPoints.update(state.originalValue)
            if !state.keyExisted {
                clearRawValue()
            }
            Log.info("GLOBE_ACTION restored to \(state.originalValue)")
        }
        removeMarker()
    }

    private static func rawValueExists() -> Bool {
        CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        return CFPreferencesCopyValue(key, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) != nil
    }

    private static func clearRawValue() {
        CFPreferencesSetValue(key, nil, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }

    private static func readMarker() -> State? {
        guard let data = FileManager.default.contents(atPath: statePath) else { return nil }
        guard let state = try? JSONDecoder().decode(State.self, from: data), state.version == stateVersion else {
            removeMarker()
            return nil
        }
        return state
    }

    private static func writeMarker(_ state: State) -> Bool {
        do {
            let url = URL(fileURLWithPath: statePath)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(state).write(to: url, options: .atomic)
            return true
        } catch {
            Log.warn("Cannot suppress the macOS Globe action: \(error.localizedDescription)")
            return false
        }
    }

    private static func removeMarker() {
        try? FileManager.default.removeItem(atPath: statePath)
    }
}

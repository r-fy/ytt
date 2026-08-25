import Foundation

// Where rules.json and history.jsonl live. Default is Application Support.
// Point it at a synced folder to share rules across Macs:
//   defaults write local.ytt.menubar dataDir "$HOME/Sync/YTT"
// Relaunch after changing it.
enum DataDir {
    static let url: URL = {
        // Used by tools/check-rules.sh so the check never touches real rules.
        if let override = ProcessInfo.processInfo.environment["YTT_DATA_DIR_OVERRIDE"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        if let custom = UserDefaults.standard.string(forKey: "dataDir"), !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
        }
        return URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/YTT")
    }()
}

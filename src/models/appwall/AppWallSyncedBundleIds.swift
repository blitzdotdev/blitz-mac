import Foundation

/// Persists the set of bundle IDs the user has successfully synced to the App Wall.
/// Used for the "unsynced apps" banner — avoids querying the wall backend on every render.
enum AppWallSyncedBundleIds {
    private static let key = "appWallSyncedBundleIds"

    static func load() -> Set<String> {
        let arr = UserDefaults.standard.stringArray(forKey: key) ?? []
        return Set(arr)
    }

    static func save(_ ids: Set<String>) {
        UserDefaults.standard.set(Array(ids), forKey: key)
    }

    static func add(_ ids: Set<String>) {
        save(load().union(ids))
    }
}

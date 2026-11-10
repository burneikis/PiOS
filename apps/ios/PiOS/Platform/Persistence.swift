import Foundation
import PiOSCore
import Security

/// One file per key under Application Support. Transcript caches and the
/// outbox are too large and too precious for `UserDefaults`.
final class FileStorage: StorageAdapter {
    private let directory: URL

    init(name: String = "pios") {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = base.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Caches are rebuilt from the daemon; the outbox is not, but it is
        // also not worth an iCloud backup of base64 screenshots.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var url = directory
        try? url.setResourceValues(values)
    }

    func read(_ key: String) -> Data? {
        try? Data(contentsOf: path(key))
    }

    func write(_ key: String, _ data: Data) {
        try? data.write(to: path(key), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func remove(_ key: String) {
        try? FileManager.default.removeItem(at: path(key))
    }

    func removeAll() {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func path(_ key: String) -> URL {
        let safe = key.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" ? $0 : "_" }
        return directory.appendingPathComponent(String(safe) + ".json")
    }
}

/// Device tokens live in the Keychain: a token is as good as an SSH key to
/// the machine that issued it.
enum Keychain {
    private static let service = "dev.pios.device-token"

    static func token(for machineId: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: machineId,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func setToken(_ token: String, for machineId: String) {
        removeToken(for: machineId)
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: machineId,
            kSecValueData as String: Data(token.utf8),
            // Readable in the background after first unlock, never synced.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        SecItemAdd(item as CFDictionary, nil)
    }

    static func removeToken(for machineId: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: machineId,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// A paired machine. The token is not stored here but in the Keychain.
struct Machine: Codable, Hashable, Identifiable {
    var id: String
    var label: String
    /// The one route to the machine: its relay, or the daemon in development.
    var url: URL

    var socketURL: URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        components.path = "/ws"
        components.query = nil
        components.fragment = nil
        return components.url
    }
}

struct MachineStore: Codable {
    static let version = 1
    static let key = "pios.machines"

    var machines: [Machine] = []
    var activeId: String?

    var active: Machine? { machines.first { $0.id == activeId } }
}

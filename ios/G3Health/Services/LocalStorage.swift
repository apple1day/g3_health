import Foundation
import Security

struct TokenStore {
    private var service: String { (Bundle.main.bundleIdentifier ?? "com.anxiong.g3health") + ".relay" }
    private let account = "upload-token"

    func read() -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var value: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &value) == errSecSuccess,
              let data = value as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func save(_ token: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account]
        let update: [String: Any] = [kSecValueData as String: Data(token.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            update.forEach { item[$0.key] = $0.value }
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw StorageFailure.keychain }
        } else if status != errSecSuccess { throw StorageFailure.keychain }
    }

    func delete() {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
    }
}

enum StorageFailure: Error { case keychain }

struct SnapshotCache {
    private func fileURL() throws -> URL {
        let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                appropriateFor: nil, create: true)
        var folder = root.appendingPathComponent("HealthSnapshot", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try folder.setResourceValues(values)
        return folder.appendingPathComponent("latest.json")
    }

    func read() -> HealthSnapshot? {
        guard let file = try? fileURL(), let data = try? Data(contentsOf: file),
              let snapshot = try? HealthSnapshot.decoder.decode(HealthSnapshot.self, from: data),
              snapshot.dataMode == .healthkit, snapshot.schemaVersion == 1 else { return nil }
        return snapshot
    }

    func write(_ snapshot: HealthSnapshot) throws {
        guard snapshot.dataMode == .healthkit else { return }
        let file = try fileURL()
        try HealthSnapshot.encoder.encode(snapshot).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func delete() {
        if let file = try? fileURL() { try? FileManager.default.removeItem(at: file) }
    }
}

import Foundation
import Security

/// Upgrade cleanup is scoped to this app's old relay entry. No credentials are used.
enum LegacyRelayCredential {
    static func remove() {
        let service = (Bundle.main.bundleIdentifier ?? "com.anxiong.g3health") + ".relay"
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: "upload-token"]
        SecItemDelete(query as CFDictionary)
    }
}

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

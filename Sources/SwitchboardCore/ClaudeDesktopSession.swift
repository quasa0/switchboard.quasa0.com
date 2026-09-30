import Foundation
import SQLite3
import CommonCrypto
import CryptoKit
import Security
import LocalAuthentication
import Darwin

/// Explicit, read-only import of Claude Desktop's first-party session cookie.
/// Never called by discovery, previews, or automatic usage refresh.
public struct ClaudeDesktopSession {
    public struct Cookie: Sendable {
        public let value: String
        public let domain: String
        public let expiresAt: Date?
    }
    public init() {}
    public static var isInstalled: Bool {
        [URL(fileURLWithPath: "/Applications/Claude.app"),
         FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Claude.app")]
            .contains { FileManager.default.fileExists(atPath: $0.appendingPathComponent("Contents/Info.plist").path) }
    }
    public func read() throws -> Cookie {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Claude")
        for path in ["Network/Cookies", "Cookies"] {
            let database = root.appendingPathComponent(path)
            if FileManager.default.fileExists(atPath: database.path) {
                return try Self.read(database: database, password: Self.password)
            }
        }
        throw Self.unavailable
    }

    private static var unavailable: SwitchboardError {
        .message("No usable Claude Desktop sign-in was found. Sign in to Claude Desktop, then try again.")
    }

    private static func password() throws -> Data {
        let context = LAContext()
        context.localizedReason = "Connect Claude Desktop sign-in to Switchboard billing"
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Safe Storage", kSecAttrAccount as String: "Claude",
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let value = result as? Data, !value.isEmpty else {
            throw SwitchboardError.message("Claude Desktop's encryption key is unavailable. Allow Keychain access or sign in inside Switchboard.")
        }
        return value
    }

    // Internal injection points keep all cookie and Keychain tests synthetic.
    static func read(database: URL, password: () throws -> Data, now: Date = Date()) throws -> Cookie {
        var cursor = database
        while cursor.path != "/" {
            var info = stat()
            guard lstat(cursor.path, &info) == 0,
                  info.st_mode & S_IFMT != S_IFLNK else { throw unavailable }
            if cursor == database || cursor == database.deletingLastPathComponent() {
                guard info.st_uid == getuid() else { throw unavailable }
            }
            if cursor == database {
                guard info.st_mode & S_IFMT == S_IFREG, info.st_size < 67_108_864 else { throw unavailable }
            }
            cursor.deleteLastPathComponent()
            // Shared system parents do not contain the cookie database.
            if cursor.path == "/Users" || cursor.path == "/private" || cursor.path == "/tmp" { break }
        }
        for suffix in ["-wal", "-shm"] {
            var info = stat()
            let path = database.path + suffix
            if lstat(path, &info) == 0 {
                guard info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG else { throw unavailable }
            }
        }
        var db: OpaquePointer?
        guard sqlite3_open_v2(database.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              let db else { if let db { sqlite3_close(db) }; throw unavailable }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 1000)
        guard sqlite3_exec(db, "PRAGMA query_only=ON; BEGIN", nil, nil, nil) == SQLITE_OK else { throw unavailable }
        defer { sqlite3_exec(db, "ROLLBACK", nil, nil, nil) }
        var metadata: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT value FROM meta WHERE key='version'", -1, &metadata, nil) == SQLITE_OK else { throw unavailable }
        defer { sqlite3_finalize(metadata) }
        guard sqlite3_step(metadata) == SQLITE_ROW else { throw unavailable }
        let version = Int(sqlite3_column_int(metadata, 0))
        guard (1...24).contains(version) else { throw unavailable }
        var rows: OpaquePointer?
        let query = "SELECT host_key,value,encrypted_value,expires_utc,has_expires FROM cookies WHERE name='sessionKey' AND host_key IN ('claude.ai','.claude.ai') AND path='/' AND is_secure=1 AND is_httponly=1 AND top_frame_site_key='' ORDER BY expires_utc DESC LIMIT 8"
        guard sqlite3_prepare_v2(db, query, -1, &rows, nil) == SQLITE_OK else { throw unavailable }
        defer { sqlite3_finalize(rows) }
        var key: Data?
        while sqlite3_step(rows) == SQLITE_ROW {
            guard let hostText = sqlite3_column_text(rows, 0), let plainText = sqlite3_column_text(rows, 1) else { continue }
            let host = String(cString: hostText)
            let expiry = sqlite3_column_int(rows, 4) == 1
                ? Date(timeIntervalSince1970: Double(sqlite3_column_int64(rows, 3)) / 1_000_000 - 11_644_473_600) : nil
            if let expiry, expiry <= now { continue }
            let size = Int(sqlite3_column_bytes(rows, 2))
            guard size <= 16_384 else { throw unavailable }
            let value: String
            if size > 0, let bytes = sqlite3_column_blob(rows, 2) {
                if key == nil { key = try deriveKey(password()) }
                value = try decrypt(Data(bytes: bytes, count: size), key: key!, host: host, version: version)
            } else { value = String(cString: plainText) }
            guard !value.isEmpty, value.utf8.count <= 16_000,
                  !value.contains(where: { $0.isWhitespace || $0 == ";" || $0.isNewline }) else { throw unavailable }
            return Cookie(value: value, domain: host, expiresAt: expiry)
        }
        throw unavailable
    }

    static func deriveKey(_ password: Data) throws -> Data {
        guard !password.isEmpty else { throw unavailable }
        var key = Data(count: 16)
        let salt = Array("saltysalt".utf8)
        let result = key.withUnsafeMutableBytes { output in
            password.withUnsafeBytes { input in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), input.baseAddress!.assumingMemoryBound(to: Int8.self),
                    password.count, salt, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003,
                    output.baseAddress!.assumingMemoryBound(to: UInt8.self), 16)
            }
        }
        guard result == kCCSuccess else { throw unavailable }
        return key
    }
    static func decrypt(_ encrypted: Data, key: Data, host: String, version: Int) throws -> String {
        guard encrypted.starts(with: Data("v10".utf8)), key.count == 16, encrypted.count > 3 else { throw unavailable }
        let payload = Data(encrypted.dropFirst(3)), iv = [UInt8](repeating: 32, count: 16)
        var plain = Data(count: payload.count + 16), written = 0
        let capacity = plain.count
        let result = plain.withUnsafeMutableBytes { output in
            key.withUnsafeBytes { keyBytes in
                payload.withUnsafeBytes { input in
                    CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                        keyBytes.baseAddress, key.count, iv, input.baseAddress, payload.count,
                        output.baseAddress, capacity, &written)
                }
            }
        }
        guard result == kCCSuccess else { throw unavailable }
        plain.count = written
        if version >= 24 {
            let hash = Data(SHA256.hash(data: Data(host.utf8)))
            guard plain.starts(with: hash) else { throw unavailable }
            plain.removeFirst(hash.count)
        }
        guard let value = String(data: plain, encoding: .utf8) else { throw unavailable }
        return value
    }
}

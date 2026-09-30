import Foundation
import SQLite3
import Darwin
import XCTest
@testable import SwitchboardCore

final class ClaudeDesktopSessionTests: XCTestCase {
    private let encrypted = "763130777c56ffd2448d31bd5ed3abc0bf162903132905a8e79d2ae48d38b5a44e93a5a2c386ce0e821063c7c39d57441efae76f7c20b8589d0b87d0c02e2c7d6bf693"
    private func bytes(_ hex: String) -> Data {
        Data(stride(from: 0, to: hex.count, by: 2).map { offset in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)!
        })
    }
    func testIndependentOpenSSLVectorAndHostBinding() throws {
        let key = try ClaudeDesktopSession.deriveKey(Data("synthetic-desktop-password".utf8))
        XCTAssertEqual(key, bytes("46c8a5cec105a3ce3e68c665b393936d"))
        XCTAssertEqual(try ClaudeDesktopSession.decrypt(bytes(encrypted), key: key, host: "claude.ai", version: 24), "synthetic-desktop-session")
        XCTAssertThrowsError(try ClaudeDesktopSession.decrypt(bytes(encrypted), key: key, host: ".claude.ai", version: 24))
        XCTAssertThrowsError(try ClaudeDesktopSession.decrypt(Data("v20unsupported".utf8), key: key, host: "claude.ai", version: 24))
        XCTAssertThrowsError(try ClaudeDesktopSession.decrypt(bytes(encrypted), key: Data(repeating: 0, count: 16), host: "claude.ai", version: 24))
    }
    func testReadOnlyWALCookieSelectionAndNoKeychainForPlaintext() throws {
        let root = URL(fileURLWithPath: "/Users/Shared").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Cookies")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(file.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let schema = "PRAGMA journal_mode=WAL; CREATE TABLE meta(key TEXT,value INTEGER); INSERT INTO meta VALUES('version',24); CREATE TABLE cookies(host_key TEXT,name TEXT,value TEXT,encrypted_value BLOB,path TEXT,is_secure INTEGER,is_httponly INTEGER,top_frame_site_key TEXT,expires_utc INTEGER,has_expires INTEGER);"
        XCTAssertEqual(sqlite3_exec(db, schema, nil, nil, nil), SQLITE_OK)
        let unrelated = "INSERT INTO cookies VALUES('other.example','sessionKey','synthetic-wrong',X'','/',1,1,'',0,0); INSERT INTO cookies VALUES('claude.ai','sessionKey','synthetic-insecure',X'','/',0,1,'',0,0);"
        XCTAssertEqual(sqlite3_exec(db, unrelated, nil, nil, nil), SQLITE_OK)
        XCTAssertThrowsError(try ClaudeDesktopSession.read(database: file, password: { XCTFail("Unexpected Keychain read"); return Data() }))
        XCTAssertEqual(sqlite3_exec(db, "INSERT INTO cookies VALUES('claude.ai','sessionKey','',X'\(encrypted)','/',1,1,'',0,0);", nil, nil, nil), SQLITE_OK)
        let before = try Data(contentsOf: file)
        let cookie = try ClaudeDesktopSession.read(database: file, password: { Data("synthetic-desktop-password".utf8) })
        XCTAssertEqual(cookie.value, "synthetic-desktop-session")
        XCTAssertEqual(cookie.domain, "claude.ai")
        XCTAssertNil(cookie.expiresAt)
        XCTAssertEqual(try Data(contentsOf: file), before)
        XCTAssertEqual(sqlite3_exec(db, "DELETE FROM cookies; INSERT INTO cookies VALUES('.claude.ai','sessionKey','synthetic-plain',X'','/',1,1,'',0,0);", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(try ClaudeDesktopSession.read(database: file, password: { XCTFail("Unexpected Keychain read"); return Data() }).value, "synthetic-plain")
        let link = root.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertThrowsError(try ClaudeDesktopSession.read(database: link, password: { Data() }))
        XCTAssertEqual(sqlite3_exec(db, "UPDATE cookies SET expires_utc=1,has_expires=1;", nil, nil, nil), SQLITE_OK)
        XCTAssertThrowsError(try ClaudeDesktopSession.read(database: file, password: { Data() }))
    }
}

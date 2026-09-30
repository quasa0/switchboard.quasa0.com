import Foundation
import XCTest
import Darwin
@testable import SwitchboardCore

final class ClaudeCredentialHelperTests: XCTestCase {
    func testWritePassesOnlyHexCredentialOnStdinWithExactNames() throws {
        let fixture = try Fixture(script: """
        import os, shlex, sys
        from pathlib import Path
        Path(__file__ + '.pid').write_text(str(os.getpid()))
        assert sys.argv[1:] == ['-q', '-i']
        line = sys.stdin.read()
        assert len(line.encode()) < 4096
        arguments = shlex.split(line)
        assert arguments[:2] == ['add-generic-password', '-U']
        assert '-T' not in arguments
        assert arguments[arguments.index('-s') + 1] == 'synthetic-service "quoted"\\\\name'
        assert arguments[arguments.index('-a') + 1] == 'synthetic-user'
        payload = bytes.fromhex(arguments[arguments.index('-X') + 1])
        Path(__file__ + '.data').write_bytes(payload)
        """)
        defer { fixture.remove() }
        let payload = Data("{\"accessToken\":\"SYNTHETIC-ONLY\",\"label\":\"café 🚀\\n\"}".utf8)
        try fixture.helper.write(payload, service: "synthetic-service \"quoted\"\\name", account: "synthetic-user")
        XCTAssertEqual(try Data(contentsOf: fixture.output("data")), payload)
        try fixture.assertChildStopped()
    }

    func testOversizedAndMultilineCommandsFailBeforeStartingHelper() throws {
        let fixture = try Fixture(script: """
        import os
        from pathlib import Path
        Path(__file__ + '.pid').write_text(str(os.getpid()))
        """)
        defer { fixture.remove() }
        XCTAssertThrowsError(try fixture.helper.write(Data(repeating: 65, count: 3000), service: "synthetic", account: "user"))
        XCTAssertThrowsError(try fixture.helper.write(Data("{}".utf8), service: "first\nsecond", account: "user"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.output("pid").path))
    }

    func testMigrationCreationCannotUpdateAnExistingItem() throws {
        let fixture = try Fixture(script: """
        import shlex, sys
        arguments = shlex.split(sys.stdin.read())
        assert arguments[0] == 'add-generic-password'
        assert '-U' not in arguments
        assert '-T' not in arguments
        assert bytes.fromhex(arguments[arguments.index('-X') + 1]) == b'{}'
        sys.exit(45)
        """)
        defer { fixture.remove() }
        XCTAssertThrowsError(try fixture.helper.create(Data("{}".utf8), service: "synthetic", account: "user")) { error in
            XCTAssertTrue(error.localizedDescription.contains("(45)"))
        }
    }

    func testMissingItemsAreNilForReadsAndHarmlessForDeletesButWritesStillFail() throws {
        let fixture = try Fixture(script: """
        import sys
        print('synthetic-sensitive-diagnostic', file=sys.stderr)
        sys.exit(44)
        """)
        defer { fixture.remove() }
        XCTAssertNil(try fixture.helper.read(service: "synthetic", account: "user"))
        XCTAssertNoThrow(try fixture.helper.delete(service: "synthetic", account: "user"))
        XCTAssertThrowsError(try fixture.helper.write(Data("{}".utf8), service: "synthetic", account: "user")) { error in
            XCTAssertFalse(error.localizedDescription.contains("synthetic-sensitive-diagnostic"))
        }
    }

    func testReadDecodesPreviouslyHexEncodedCredentialOutput() throws {
        let fixture = try Fixture(script: """
        import sys
        assert sys.argv[1:] == ['find-generic-password', '-w', '-s', 'synthetic', '-a', 'user']
        print(b'{\\n  "accessToken": "synthetic-token"\\n}'.hex())
        """)
        defer { fixture.remove() }
        let result = try XCTUnwrap(fixture.helper.read(service: "synthetic", account: "user"))
        XCTAssertEqual(try jsonObject(result)["accessToken"] as? String, "synthetic-token")
    }

    func testTimeoutKillsAndReapsHelper() throws {
        let fixture = try Fixture(script: """
        import os, signal, time
        from pathlib import Path
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        Path(__file__ + '.pid').write_text(str(os.getpid()))
        time.sleep(60)
        """, timeout: 2)
        defer { fixture.remove() }
        XCTAssertThrowsError(try fixture.helper.read(service: "synthetic", account: "user")) { error in
            XCTAssertTrue(error.localizedDescription.contains("timed out"))
        }
        try fixture.assertChildStopped()
    }

    func testExcessiveOutputKillsAndReapsHelper() throws {
        let fixture = try Fixture(script: """
        import os, sys, time
        from pathlib import Path
        Path(__file__ + '.pid').write_text(str(os.getpid()))
        sys.stdout.write('x' * 1100000)
        sys.stdout.flush()
        time.sleep(60)
        """)
        defer { fixture.remove() }
        XCTAssertThrowsError(try fixture.helper.read(service: "synthetic", account: "user")) { error in
            XCTAssertTrue(error.localizedDescription.contains("excessive output"))
        }
        try fixture.assertChildStopped()
    }

    private struct Fixture {
        let directory: URL
        let executable: URL
        let timeout: TimeInterval
        var helper: ClaudeCredentialHelper { ClaudeCredentialHelper(executable: executable, timeout: timeout) }

        init(script: String, timeout: TimeInterval = 5) throws {
            self.timeout = timeout
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("switchboard-keychain-helper-test-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            executable = directory.appendingPathComponent("fixture")
            try Data(("#!/usr/bin/env python3\n" + script + "\n").utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        }

        func output(_ suffix: String) -> URL { URL(fileURLWithPath: executable.path + "." + suffix) }

        func assertChildStopped(file: StaticString = #filePath, line: UInt = #line) throws {
            let pid = try XCTUnwrap(Int32(String(contentsOf: output("pid"), encoding: .utf8)), file: file, line: line)
            XCTAssertEqual(kill(pid, 0), -1, file: file, line: line)
            XCTAssertEqual(errno, ESRCH, file: file, line: line)
        }

        func remove() { try? FileManager.default.removeItem(at: directory) }
    }
}

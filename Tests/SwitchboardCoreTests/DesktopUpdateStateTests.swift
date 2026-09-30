import XCTest
@testable import SwitchboardCore

final class DesktopUpdateStateTests: XCTestCase {
    func testLaterChecksCannotDiscardVerifiedOrInstallingUpdate() {
        for status: DesktopUpdateState.Status in [.ready, .installing, .downloading] {
            var state = DesktopUpdateState(status: status)
            state.version = "2.0"; state.progress = 75
            state.found("3.0")
            state.checkFinished(error: true)
            state.checkFinished(error: false)
            XCTAssertEqual(state.status, status)
            XCTAssertEqual(state.version, "2.0")
            XCTAssertEqual(state.progress, 75)
            XCTAssertNil(state.message)
            XCTAssertNotNil(state.checkedAt)
        }
    }

    func testProgressIsBoundedAndOnlyChangesWhileDownloading() {
        var state = DesktopUpdateState(status: .downloading)
        state.received(35); XCTAssertEqual(state.progress, 35)
        state.received(.nan); XCTAssertEqual(state.progress, 35)
        state.received(.infinity); XCTAssertEqual(state.progress, 35)
        state.received(-1); XCTAssertEqual(state.progress, 0)
        state.received(101); XCTAssertEqual(state.progress, 100)
        state.status = .ready; state.received(5); XCTAssertEqual(state.progress, 100)
    }

    func testCheckFailureAndNoUpdateHaveDifferentResults() {
        var state = DesktopUpdateState(status: .checking)
        state.checkFinished(error: true)
        XCTAssertEqual(state.status, .error)
        XCTAssertNotNil(state.message)
        state.found("2.0")
        XCTAssertEqual(state.status, .available)
        XCTAssertNil(state.message)
        state.checkFinished(error: false)
        XCTAssertEqual(state.status, .idle)
        XCTAssertNil(state.version)
    }
}

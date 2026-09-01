import XCTest
import WebKit
@testable import Slate

final class UserScriptsTests: XCTestCase {
    @MainActor func testOverlayBusterLoadsFromBundle() {
        let script = UserScripts.script(named: "overlay-buster", injectionTime: .atDocumentEnd, forMainFrameOnly: false)
        XCTAssertFalse(script.source.isEmpty)
        XCTAssertTrue(script.source.contains("slateOverlayBuster"))
        XCTAssertFalse(script.isForMainFrameOnly)
    }

    @MainActor func testMissingScriptReturnsEmptySource() {
        XCTAssertTrue(UserScripts.source(named: "no-such-script").isEmpty)
    }
}

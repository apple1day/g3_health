import XCTest
@testable import G3Health

final class HealthSourceIdentityTests: XCTestCase {
    func testThirdPartyWatchesDoNotReceiveAppleWatchPriority() {
        for model in ["OnePlus Watch", "OPPO Watch", "Watch", "Watch X2", "Galaxy Watch"] {
            XCTAssertFalse(HealthSourceIdentity.isAppleWatch(productType: "iPhone14,7",
                model: model, manufacturer: "OPPO"), model)
        }
        XCTAssertFalse(HealthSourceIdentity.isAppleWatch(productType: "watchlink", model: nil, manufacturer: nil))
        XCTAssertFalse(HealthSourceIdentity.isAppleWatch(productType: nil, model: "Watch", manufacturer: nil))
        XCTAssertFalse(HealthSourceIdentity.isAppleWatch(productType: nil, model: nil, manufacturer: nil))
    }

    func testAppleWatchMetadataStillRecognized() {
        XCTAssertTrue(HealthSourceIdentity.isAppleWatch(productType: "Watch6,18", model: nil, manufacturer: nil))
        XCTAssertTrue(HealthSourceIdentity.isAppleWatch(productType: nil, model: "Apple Watch Ultra", manufacturer: nil))
        XCTAssertTrue(HealthSourceIdentity.isAppleWatch(productType: nil, model: " Watch ", manufacturer: " Apple Inc. "))
        XCTAssertFalse(HealthSourceIdentity.isAppleWatch(productType: "iPhone14,7", model: "iPhone", manufacturer: "Apple"))
    }
}

import XCTest
@testable import MotionOSAppleCapture

final class ProductSessionSyncReceiptTests: XCTestCase {
    func testSyncReceiptCarriesIPhoneCameraCuePTS() throws {
        let receipt = ProductSessionManifest.SyncReceipt(
            cueID: "sync-start",
            label: "start",
            acknowledgedAtUTC: "2026-10-04T22:00:00Z",
            watchDeviceTimeNS: 12_000_000_000,
            iPhoneCameraPTSNS: 34_500_000_000
        )

        let encoded = try JSONEncoder().encode(receipt)
        let decoded = try JSONDecoder().decode(
            ProductSessionManifest.SyncReceipt.self,
            from: encoded
        )

        XCTAssertEqual(
            decoded.iPhoneCameraPTSNS,
            34_500_000_000
        )
    }

    func testOlderSyncReceiptWithoutCameraPTSStillDecodes() throws {
        let raw = """
        {
          "cueID": "sync-middle",
          "label": "middle",
          "acknowledgedAtUTC": "2026-10-04T22:01:00Z",
          "watchDeviceTimeNS": 85000000000
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(
            ProductSessionManifest.SyncReceipt.self,
            from: raw
        )

        XCTAssertNil(decoded.iPhoneCameraPTSNS)
        XCTAssertEqual(decoded.label, "middle")
    }
}

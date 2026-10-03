import XCTest
@testable import MotionOSAppleCapture

final class IndoBoardEquipmentQualificationRegistryLoaderTests:
    XCTestCase {
    func testLoadsResearchProducedSnakeCaseRegistry() throws {
        let json = """
        {
          "schema_version": "motionos.indo-equipment-model-qualification-registry.v1",
          "qualifications": [
            {
              "schema_version": "motionos.indo-equipment-model-qualification.v1",
              "model_id": "indo-equipment-v1",
              "status": "evaluation_only",
              "evaluation_dataset_id": "indo-heldout-v1",
              "evaluation_report_sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
              "authorization_note": null,
              "metrics": {
                "roller_center_error_p90": 0.03
              },
              "claim_boundary": "beta boundary"
            }
          ],
          "claim_boundary": "registry boundary"
        }
        """

        let registry =
            try IndoBoardEquipmentQualificationRegistryLoader
                .load(from: Data(json.utf8))

        XCTAssertEqual(
            registry.qualifications.count,
            1
        )
        XCTAssertEqual(
            registry.qualifications.first?.modelID,
            "indo-equipment-v1"
        )
    }

    func testUnknownRegistrySchemaFailsClosed() {
        let json = """
        {
          "schema_version": "future-registry",
          "qualifications": [],
          "claim_boundary": "test"
        }
        """

        XCTAssertThrowsError(
            try IndoBoardEquipmentQualificationRegistryLoader
                .load(from: Data(json.utf8))
        ) { error in
            XCTAssertEqual(
                error as?
                    IndoBoardEquipmentQualificationRegistryError,
                .invalidSchema("future-registry")
            )
        }
    }

    func testDuplicateModelIDsFailClosed() {
        let qualification = """
        {
          "schema_version": "motionos.indo-equipment-model-qualification.v1",
          "model_id": "indo-equipment-v1",
          "status": "evaluation_only",
          "evaluation_dataset_id": null,
          "evaluation_report_sha256": null,
          "authorization_note": null,
          "metrics": {},
          "claim_boundary": "beta boundary"
        }
        """
        let json = """
        {
          "schema_version": "motionos.indo-equipment-model-qualification-registry.v1",
          "qualifications": [
            \(qualification),
            \(qualification)
          ],
          "claim_boundary": "registry boundary"
        }
        """

        XCTAssertThrowsError(
            try IndoBoardEquipmentQualificationRegistryLoader
                .load(from: Data(json.utf8))
        ) { error in
            XCTAssertEqual(
                error as?
                    IndoBoardEquipmentQualificationRegistryError,
                .duplicateModelID(
                    "indo-equipment-v1"
                )
            )
        }
    }

    func testMalformedJSONFailsClosed() {
        XCTAssertThrowsError(
            try IndoBoardEquipmentQualificationRegistryLoader
                .load(from: Data("{".utf8))
        ) { error in
            guard let registryError =
                    error as?
                        IndoBoardEquipmentQualificationRegistryError,
                  case .unreadable = registryError
            else {
                XCTFail(
                    "Expected unreadable registry error"
                )
                return
            }
        }
    }
}

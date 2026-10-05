import Foundation
import MotionOSAppleCapture

enum ReplayReviewLedgerStore {
    static let relativePath =
        "review/replay-review-ledger.json"

    static func url(
        for run: ProductRunRecord
    ) -> URL {
        run.directoryURL
            .appendingPathComponent(
                "review",
                isDirectory: true
            )
            .appendingPathComponent(
                "replay-review-ledger.json"
            )
    }

    static func load(
        for run: ProductRunRecord
    ) throws -> ReplayReviewLedgerV1 {
        let url = url(for: run)
        guard FileManager.default
                .fileExists(
                    atPath: url.path
                )
        else {
            return ReplayReviewLedgerV1(
                runID: run.runID
            )
        }

        let value =
            try JSONDecoder()
                .decode(
                    ReplayReviewLedgerV1.self,
                    from:
                        Data(
                            contentsOf: url
                        )
                )
        guard value.runID
                == run.runID
        else {
            throw ReplayReviewLedgerError
                .runMismatch
        }
        return value
    }

    @discardableResult
    static func append(
        _ flag: ReplayReviewFlagV1,
        to run: ProductRunRecord
    ) throws -> ReplayReviewLedgerV1 {
        var ledger =
            try load(for: run)
        ledger =
            try ledger.appending(flag)

        let output = url(for: run)
        try FileManager.default
            .createDirectory(
                at:
                    output
                        .deletingLastPathComponent(),
                withIntermediateDirectories:
                    true
            )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [
            .prettyPrinted,
            .sortedKeys,
        ]
        try encoder.encode(ledger)
            .write(
                to: output,
                options: .atomic
            )
        return ledger
    }

    static func artifactBindings(
        for run: ProductRunRecord,
        alignment:
            VideoAlignmentReceiptV1?
    ) -> [ReplayReviewArtifactBindingV1] {
        var values:
            [ReplayReviewArtifactBindingV1] =
            []

        func add(
            role: String,
            hash: String?,
            url: URL?
        ) {
            guard let hash,
                  !hash.isEmpty
            else {
                return
            }
            values.append(
                ReplayReviewArtifactBindingV1(
                    role: role,
                    sha256: hash,
                    filename:
                        url?
                            .lastPathComponent
                )
            )
        }

        add(
            role: "iphone_video",
            hash:
                run.productManifest?
                    .cameraVideoSHA256,
            url: run.cameraVideoURL
        )
        add(
            role:
                "iphone_camera_journal",
            hash:
                run.productManifest?
                    .cameraJournalSHA256,
            url: run.cameraJournalURL
        )
        add(
            role: "action4_video",
            hash:
                alignment?
                    .sourceVideo
                    .sha256
                    ?? run.productManifest?
                        .externalCameraSHA256,
            url: run.externalVideoURL
        )

        for (
            role,
            url
        ) in [
            (
                "video_alignment",
                run.externalAlignmentURL
            ),
            (
                "action4_pose_track",
                run.externalPoseTrackURL
            ),
            (
                "product_session",
                run.productManifestURL
            ),
        ] {
            guard let url,
                  let digest =
                    try? FileEvidence.digest(
                        url
                    )
            else {
                continue
            }
            add(
                role: role,
                hash: digest.sha256,
                url: url
            )
        }

        return values
    }
}

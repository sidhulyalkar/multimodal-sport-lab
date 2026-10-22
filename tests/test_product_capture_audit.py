import hashlib
import json

import pytest

from motionos.product_capture_audit import (
    build_product_capture_audit,
    write_product_capture_audit,
)


def _write(root, relative, content):
    target = root / relative
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(content)
    return hashlib.sha256(content).hexdigest()


def _fixture(tmp_path, *, watch=True, action4=False):
    docs = tmp_path / "exported-iPhone-Documents"
    name = "run-fixture-123"
    run = docs / "MotionOSRuns" / name
    op_lines = "".join(
        json.dumps({"run_id": name, "sequence": index, "kind": "fixture"}) + "\n"
        for index in range(3)
    ).encode()
    op_hash = _write(docs, f"MotionOSRuns/{name}/operator-events.jsonl", op_lines)
    meta_hash = _write(
        docs, f"MotionOSRuns/{name}/operator-metadata.json",
        json.dumps({"run_id": name, "protocol_kind": "Indo Board"}).encode(),
    )
    camera_id = "camera-123"
    camera_video_hash = _write(
        docs, f"MotionOSCamera/{camera_id}/camera.mov", b"fixture movie bytes"
    )
    camera_frame_hash = _write(
        docs, f"MotionOSCamera/{camera_id}/camera-frames.jsonl",
        b'{"sequence":0,"kind":"frame"}\n',
    )
    camera_meta_hash = _write(
        docs, f"MotionOSCamera/{camera_id}/camera-metadata.json", b"{}"
    )
    watch_id = "watch-123"
    watch_blob = b'{"sequence":0,"kind":"watch"}\n'
    if watch:
        _write(
            docs, f"MotionOSInbox/{watch_id}/watch.jsonl", watch_blob
        )

    external_hash = None
    if action4:
        external_hash = _write(
            docs, f"MotionOSRuns/{name}/external/action4/original-movie.mp4",
            b"fixture Action4 movie",
        )
    manifest = {
        "schemaVersion": "motionos.product-session.v1",
        "runID": name,
        "sport": "indo_board",
        "outcome": "completed",
        "captureMode": "Watch + iPhone",
        "targetDurationSeconds": 120,
        "watchSessionID": watch_id,
        "watchJournalSHA256": hashlib.sha256(watch_blob).hexdigest(),
        "watchJournalByteCount": len(watch_blob),
        "cameraSessionID": camera_id,
        "operatorJournalSHA256": op_hash,
        "operatorMetadataSHA256": meta_hash,
        "cameraVideoSHA256": camera_video_hash,
        "cameraJournalSHA256": camera_frame_hash,
        "cameraMetadataSHA256": camera_meta_hash,
        "operatorEvidenceSealed": True,
        "cameraEvidenceSealed": True,
        "externalCameraExpected": action4,
        "externalCameraImported": action4,
        "externalCameraSHA256": external_hash,
        "syncReceipts": [{"label": label} for label in ("start", "middle", "end")],
    }
    (run / "product-session.json").write_text(json.dumps(manifest))
    return run, docs


def test_complete_export_matches_manifest_and_never_claims_biomechanics(tmp_path):
    run, _ = _fixture(tmp_path)
    receipt = build_product_capture_audit(run)
    assert receipt["status"] == "export_hashes_verified"
    assert receipt["issues"] == []
    assert receipt["warnings"] == []
    assert receipt["physical_capture_qualified"] is False
    assert receipt["biomechanics_validated"] is False
    assert {x["role"] for x in receipt["artifacts"]} == {
        "operator_journal", "operator_metadata", "watch_journal",
        "camera_video", "camera_journal", "camera_metadata",
    }


def test_missing_watch_export_is_pending_not_invented_data_loss(tmp_path):
    run, _ = _fixture(tmp_path, watch=False)
    report = build_product_capture_audit(run)
    assert report["status"] == "incomplete_evidence"
    assert "watch_journal_missing_or_not_exported" in report["warnings"]
    assert report["issues"] == []


def test_original_camera_mutation_produces_integrity_failure(tmp_path):
    run, docs = _fixture(tmp_path)
    (docs / "MotionOSCamera/camera-123/camera.mov").write_bytes(b"modified")
    report = build_product_capture_audit(run)
    assert report["status"] == "integrity_problem"
    assert "camera_video:hash_mismatch" in report["issues"]


def test_wrong_operator_run_identity_and_duplicates_are_detected(tmp_path):
    run, _ = _fixture(tmp_path)
    (run / "operator-metadata.json").write_text('{"run_id":"different"}')
    report = build_product_capture_audit(run)
    assert report["status"] == "integrity_problem"
    assert "operator_metadata_run_id_mismatch" in report["issues"]
    manifest = json.loads((run / "product-session.json").read_text())
    manifest["syncReceipts"].append({"label": "middle"})
    (run / "product-session.json").write_text(json.dumps(manifest))
    report = build_product_capture_audit(run)
    assert "duplicate_sync_labels" in report["issues"]


def test_external_video_bound_only_when_expected_and_imported(tmp_path):
    run, _ = _fixture(tmp_path, action4=True)
    report = build_product_capture_audit(run)
    assert report["status"] == "export_hashes_verified"
    assert next(x for x in report["artifacts"] if x["role"] == "external_video")["hash_matches"]


def test_bad_sibling_directory_does_not_get_misread(tmp_path):
    _, docs = _fixture(tmp_path)
    with pytest.raises(ValueError, match="expected iPhone Documents"):
        build_product_capture_audit(docs)


def test_output_is_not_allowed_inside_original_evidence(tmp_path):
    run, docs = _fixture(tmp_path)
    before = (run / "product-session.json").read_bytes()
    with pytest.raises(ValueError, match="outside"):
        write_product_capture_audit(run, run / "product-session.json")
    with pytest.raises(ValueError, match="outside"):
        write_product_capture_audit(run, docs / "capture-audit.json")
    assert (run / "product-session.json").read_bytes() == before

    report_path = tmp_path / "report.json"
    assert write_product_capture_audit(run, report_path)["status"] == "export_hashes_verified"
    with pytest.raises(FileExistsError, match="refusing to overwrite"):
        write_product_capture_audit(run, report_path)


def test_interleaved_frame_pose_streams_have_independent_sequences(tmp_path):
    run, docs = _fixture(tmp_path)
    frames = (
        b'{"stream":"/camera/frame","sequence":0}\n'
        b'{"stream":"/camera/pose","sequence":0}\n'
        b'{"stream":"/camera/frame","sequence":1}\n'
        b'{"stream":"/camera/pose","sequence":1}\n'
    )
    frame_hash = _write(
        docs, "MotionOSCamera/camera-123/camera-frames.jsonl", frames
    )
    manifest = json.loads((run / "product-session.json").read_text())
    manifest["cameraJournalSHA256"] = frame_hash
    (run / "product-session.json").write_text(json.dumps(manifest))
    assert build_product_capture_audit(run)["status"] == "export_hashes_verified"

    duplicated = frames + b'{"stream":"/camera/pose","sequence":1}\n'
    new_hash = _write(
        docs, "MotionOSCamera/camera-123/camera-frames.jsonl", duplicated
    )
    manifest["cameraJournalSHA256"] = new_hash
    (run / "product-session.json").write_text(json.dumps(manifest))
    report = build_product_capture_audit(run)
    assert report["status"] == "integrity_problem"
    assert "camera_journal_invalid_jsonl" in report["issues"]

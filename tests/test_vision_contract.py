from motionos.vision_contract import CameraSource, VisionSessionManifest


def test_action4_source_is_external_recorded_not_fake_live_sdk():
    source = CameraSource(
        source_id="dji-action4",
        display_name="DJI Osmo Action 4",
        kind="external_recorded",
        clock_domain="action4-video-pts",
        timestamp_basis="container_video_pts",
        supports_live_frames=False,
        supports_remote_control=False,
        capabilities=("4k", "timecode", "wide_fov"),
    )

    assert source.supports_live_frames is False
    assert source.supports_remote_control is False
    assert source.to_dict()["capabilities"] == ["4k", "timecode", "wide_fov"]


def test_vision_manifest_round_trip():
    raw = {
        "schema_version": "motionos.vision-session.v1",
        "session_id": "indo-1",
        "sport": "indo_board",
        "capture_mode": "multiview_calibration",
        "created_at_utc": "2026-09-30T22:00:00Z",
        "camera_sources": [
            {
                "source_id": "iphone-rear",
                "display_name": "iPhone Rear Camera",
                "kind": "built_in",
                "clock_domain": "avcapture-pts",
                "timestamp_basis": "avcapture_presentation_timestamp",
                "supports_live_frames": True,
                "supports_remote_control": True,
                "capabilities": ["vision_pose"],
            }
        ],
        "sync_landmarks": [],
        "claim_boundary": "native clocks preserved",
    }

    manifest = VisionSessionManifest.from_dict(raw)

    assert manifest.session_id == "indo-1"
    assert manifest.camera_sources[0].kind == "built_in"
    assert manifest.to_dict()["camera_sources"][0]["source_id"] == "iphone-rear"

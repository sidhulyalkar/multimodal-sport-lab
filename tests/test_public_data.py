import pytest

from motionos.public_data import index_totalcapture


def test_totalcapture_indexer_preserves_sequence_modalities(tmp_path):
    sequence = tmp_path / "s1" / "acting1"
    sequence.mkdir(parents=True)
    (sequence / "gt_skel_gbl_pos.txt").write_text("0 0 0\n", encoding="utf-8")
    (sequence / "gt_skel_gbl_ori.txt").write_text("1 0 0\n", encoding="utf-8")
    (sequence / "acting1_Xsens_AuxFields.sensors").write_text(
        "fixture\n",
        encoding="utf-8",
    )
    (sequence / "TC_S1_acting1_cam1.mp4").write_bytes(b"camera-1")
    (sequence / "TC_S1_acting1_cam2.mp4").write_bytes(b"camera-2")

    output = tmp_path / "index.json"
    payload = index_totalcapture(tmp_path, output)

    assert payload["dataset"] == "TotalCapture"
    assert len(payload["samples"]) == 1
    sample = payload["samples"][0]
    assert sample["subject_id"] == "s1"
    assert sample["camera_view"] == "multi-view"
    assert len(sample["modalities"]["video"]) == 2
    assert output.is_file()


def test_totalcapture_indexer_fails_when_required_pair_is_absent(tmp_path):
    sequence = tmp_path / "s1" / "acting1"
    sequence.mkdir(parents=True)
    (sequence / "gt_skel_gbl_pos.txt").write_text("0 0 0\n", encoding="utf-8")

    with pytest.raises(ValueError, match="no TotalCapture sequences"):
        index_totalcapture(tmp_path, tmp_path / "index.json")

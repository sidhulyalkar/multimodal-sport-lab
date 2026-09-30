import json
from pathlib import Path

import pytest

import motionos.fiducial_assets as fiducial_assets
from motionos.provenance import sha256_file
from motionos.world_geometry import load_calibration_board


class _FakeBytesList:
    shape = (50, 1, 4)


class _FakeDictionary:
    bytesList = _FakeBytesList()


class _FakeBoard:
    def generateImage(self, size, *, marginSize, borderBits):
        return (
            f"charuco:{size}:{marginSize}:{borderBits}"
        ).encode()


class _FakeAruco:
    DICT_5X5_1000 = 1
    DICT_4X4_50 = 2

    @staticmethod
    def getPredefinedDictionary(_identifier):
        return _FakeDictionary()

    @staticmethod
    def CharucoBoard(
        _size,
        _square_length,
        _marker_length,
        _dictionary,
    ):
        return _FakeBoard()

    @staticmethod
    def generateImageMarker(
        _dictionary,
        marker_id,
        pixels,
        *,
        borderBits,
    ):
        return (
            f"aruco:{marker_id}:{pixels}:{borderBits}"
        ).encode()


class _FakeCV2:
    __version__ = "fake-1.0"
    aruco = _FakeAruco()

    @staticmethod
    def imwrite(path, image):
        Path(path).write_bytes(image)
        return True


@pytest.fixture
def fake_cv2(monkeypatch):
    monkeypatch.setattr(
        fiducial_assets,
        "_cv2",
        lambda: _FakeCV2(),
    )


def test_charuco_asset_build_hashes_printable_into_contract(
    tmp_path,
    fake_cv2,
):
    spec = tmp_path / "charuco-spec.json"
    spec.write_text(
        json.dumps(
            {
                "schema_version":
                    "motionos.charuco-board-build-spec.v1",
                "board_id": "board-v1",
                "squares_x": 7,
                "squares_y": 5,
                "square_length_m": 0.04,
                "marker_length_m": 0.03,
                "dictionary": "DICT_5X5_1000",
                "print_dpi": 600,
                "margin_m": 0.01,
            }
        ),
        encoding="utf-8",
    )

    receipt = fiducial_assets.build_charuco_board_assets(
        spec,
        tmp_path / "out",
    )

    contract_path = tmp_path / "out" / "board-v1.json"
    image_path = tmp_path / "out" / "board-v1.png"
    contract = load_calibration_board(contract_path)

    assert image_path.is_file()
    assert contract.printable_source_sha256 == sha256_file(
        image_path
    )
    assert receipt["printable"]["sha256"] == sha256_file(
        image_path
    )
    assert receipt["printable"]["board_size_m"] == pytest.approx(
        [0.28, 0.20]
    )
    assert receipt["printable"]["print_scale_percent"] == 100
    assert receipt["board_contract"]["sha256"] == sha256_file(
        contract_path
    )


def test_aruco_asset_build_preserves_ids_sizes_and_hashes(
    tmp_path,
    fake_cv2,
):
    spec = tmp_path / "aruco-spec.json"
    spec.write_text(
        json.dumps(
            {
                "schema_version":
                    "motionos.aruco-marker-build-spec.v1",
                "asset_id": "indo-v1",
                "dictionary": "DICT_4X4_50",
                "marker_ids": [21, 22, 23, 24],
                "marker_size_m": 0.05,
                "print_dpi": 600,
                "border_bits": 1,
            }
        ),
        encoding="utf-8",
    )

    receipt = fiducial_assets.build_aruco_marker_assets(
        spec,
        tmp_path / "out",
    )

    assert [
        marker["marker_id"]
        for marker in receipt["markers"]
    ] == [21, 22, 23, 24]
    assert all(
        marker["physical_size_m"] == pytest.approx(0.05)
        for marker in receipt["markers"]
    )
    for marker in receipt["markers"]:
        path = tmp_path / "out" / marker["path"]
        assert path.is_file()
        assert marker["sha256"] == sha256_file(path)


@pytest.mark.parametrize(
    "bad_ids",
    [
        [21, 21, 22],
        [21.5, 22, 23],
        [-1, 22, 23],
        ["not-an-id", 22, 23],
    ],
)
def test_aruco_asset_build_rejects_invalid_marker_ids(
    tmp_path,
    fake_cv2,
    bad_ids,
):
    spec = tmp_path / "aruco-spec.json"
    spec.write_text(
        json.dumps(
            {
                "schema_version":
                    "motionos.aruco-marker-build-spec.v1",
                "asset_id": "indo-v1",
                "dictionary": "DICT_4X4_50",
                "marker_ids": bad_ids,
                "marker_size_m": 0.05,
                "print_dpi": 600,
                "border_bits": 1,
            }
        ),
        encoding="utf-8",
    )

    with pytest.raises(ValueError):
        fiducial_assets.build_aruco_marker_assets(
            spec,
            tmp_path / "out",
        )

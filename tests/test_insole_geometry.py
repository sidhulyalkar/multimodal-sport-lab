from __future__ import annotations

import json

import pytest

from motionos.insole_geometry import (
    CANONICAL_FOOT_FRAME,
    InsoleGeometryProfile,
    PressureSensel,
    load_insole_geometry_profile,
)


def _sensels() -> tuple[PressureSensel, ...]:
    return tuple(
        PressureSensel(
            index=index,
            center_x_m=0.01 * index,
            center_y_m=-0.004 + 0.0005 * index,
            area_m2=0.0002,
        )
        for index in range(1, 17)
    )


def test_geometry_profile_preserves_explicit_frame_and_sensels(tmp_path):
    profile = InsoleGeometryProfile(
        vendor="fixture",
        model="insole",
        size_label="7",
        side="left",
        origin_description="heel-center fixture origin",
        source="fixture calibration v1",
        sensels=_sensels(),
    )

    assert profile.frame_convention == CANONICAL_FOOT_FRAME
    assert len(profile.sensels) == 16
    assert profile.normalized_cop_to_meters(0.1, -0.2) is None

    path = tmp_path / "geometry.json"
    path.write_text(
        json.dumps(profile.to_dict()),
        encoding="utf-8",
    )
    loaded = load_insole_geometry_profile(path)

    assert loaded == profile


def test_metric_cop_requires_explicit_affine_transform():
    profile = InsoleGeometryProfile(
        vendor="fixture",
        model="insole",
        size_label="7",
        side="right",
        origin_description="heel center",
        source="measured fixture",
        sensels=_sensels(),
        cop_normalized_to_meters_affine=(
            (0.20, 0.00, 0.10),
            (0.00, 0.08, -0.02),
        ),
    )

    assert profile.normalized_cop_to_meters(0.5, -0.5) == pytest.approx(
        (0.20, -0.06)
    )


def test_geometry_rejects_duplicate_sensel_indices():
    sensels = list(_sensels())
    sensels[-1] = PressureSensel(
        index=15,
        center_x_m=0.16,
        center_y_m=0.0,
    )

    with pytest.raises(ValueError, match="unique"):
        InsoleGeometryProfile(
            vendor="fixture",
            model="insole",
            size_label="7",
            side="left",
            origin_description="heel center",
            source="fixture",
            sensels=tuple(sensels),
        )


def test_geometry_rejects_noncanonical_frame():
    with pytest.raises(ValueError, match="canonical foot frame"):
        InsoleGeometryProfile(
            vendor="fixture",
            model="insole",
            size_label="7",
            side="left",
            origin_description="heel center",
            source="fixture",
            sensels=_sensels(),
            frame_convention="+X right,+Y forward,+Z up",
        )


def test_geometry_loader_rejects_partial_affine(tmp_path):
    profile = InsoleGeometryProfile(
        vendor="fixture",
        model="insole",
        size_label="7",
        side="left",
        origin_description="heel center",
        source="fixture",
        sensels=_sensels(),
    ).to_dict()
    profile["cop_normalized_to_meters_affine"] = [[1, 0, 0]]

    path = tmp_path / "bad.json"
    path.write_text(json.dumps(profile), encoding="utf-8")

    with pytest.raises(ValueError, match="2x3"):
        load_insole_geometry_profile(path)

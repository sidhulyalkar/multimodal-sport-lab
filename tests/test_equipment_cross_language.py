import json
from pathlib import Path

from motionos.equipment import EquipmentProfile

FIXTURE = (
    Path(__file__).parents[1]
    / "apple"
    / "MotionOSAppleCapture"
    / "Tests"
    / "MotionOSAppleCaptureTests"
    / "Fixtures"
    / "equipment_profile.json"
)


def test_same_equipment_profile_fixture_decodes_in_python():
    data = json.loads(FIXTURE.read_text(encoding="utf-8"))
    profile = EquipmentProfile.from_dict(data)

    assert profile.equipment_id == "longboard-001"
    assert profile.mount_id == "center-deck-v1"
    assert profile.calibration.sensor_to_equipment[0] == (1.0, 0.0, 0.0)
    assert profile.calibration.sensor_to_equipment[2] == (0.0, 0.0, 1.0)
    assert profile.calibration.level_mean_accel == (0.0, 0.0, 9.81)

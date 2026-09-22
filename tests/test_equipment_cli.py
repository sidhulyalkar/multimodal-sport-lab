import json

from motionos.equipment import load_equipment_profile
from motionos.equipment_cli import calibrate_equipment_mount_file


def test_equipment_mount_calibration_file_workflow(tmp_path):
    source = tmp_path / "calibration.json"
    source.write_text(
        json.dumps(
            {
                "equipment_id": "longboard-001",
                "equipment_type": "longboard",
                "mount_id": "center-deck-v1",
                "level_samples": [
                    [0.0, 0.0, 9.81],
                    [0.01, -0.01, 9.80],
                    [-0.01, 0.01, 9.82],
                ],
                "nose_up_samples": [
                    [-4.14, 0.0, 8.90],
                    [-4.16, 0.01, 8.88],
                    [-4.13, -0.01, 8.89],
                ],
            }
        ),
        encoding="utf-8",
    )
    output = tmp_path / "profile.json"

    result = calibrate_equipment_mount_file(source, output)

    assert result == output
    profile = load_equipment_profile(output)
    assert profile.equipment_id == "longboard-001"
    assert profile.mount_id == "center-deck-v1"
    assert profile.calibration.forward_excitation > 0.3
    transformed_up = profile.calibration.transform((0.0, 0.0, 9.81))
    assert transformed_up[2] > 9.7

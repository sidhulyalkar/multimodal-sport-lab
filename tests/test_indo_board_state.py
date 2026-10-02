from motionos.indo_board_state import (
    analyze_board_observations,
    derive_board_state,
    detect_recoveries,
)


def _frame(time_s: float, roller_position: float):
    deck_center = 0.5
    half_length = 0.3
    roller_x = deck_center + roller_position * half_length
    return {
        "time_s": time_s,
        "deck": {
            "left": [0.2, 0.55],
            "right": [0.8, 0.55],
            "confidence": 0.95,
        },
        "roller": {
            "left": [roller_x - 0.03, 0.62],
            "right": [roller_x + 0.03, 0.62],
            "confidence": 0.90,
        },
    }


def test_board_geometry_recovers_normalized_roller_position():
    payload = {
        "frames": [
            _frame(0.0, -0.5),
            _frame(0.1, 0.0),
            _frame(0.2, 0.5),
        ]
    }

    frames = derive_board_state(payload)

    assert len(frames) == 3
    assert abs(frames[0].roller_position + 0.5) < 1e-6
    assert abs(frames[1].roller_position) < 1e-6
    assert abs(frames[2].roller_position - 0.5) < 1e-6
    assert all(abs(frame.deck_angle_deg) < 1e-6 for frame in frames)


def test_recovery_detector_measures_return_and_overshoot():
    positions = [
        0.0,
        0.20,
        0.40,
        0.55,
        0.45,
        0.25,
        0.12,
        -0.10,
        -0.20,
        -0.08,
        0.0,
    ]
    frames = derive_board_state(
        {
            "frames": [
                _frame(index * 0.1, position)
                for index, position in enumerate(positions)
            ]
        }
    )

    events = detect_recoveries(frames)

    assert len(events) == 1
    event = events[0]
    assert event.direction == "right"
    assert 350 <= event.recovery_time_ms <= 500
    assert event.overshoot_ratio > 0.30


def test_board_report_produces_cold_start_balance_metrics():
    positions = [
        0.0,
        0.1,
        0.25,
        0.4,
        0.2,
        0.1,
        0.0,
        -0.2,
        -0.45,
        -0.25,
        -0.1,
        0.0,
    ] * 12

    result = analyze_board_observations(
        {
            "frames": [
                _frame(index * 0.1, position)
                for index, position in enumerate(positions)
            ]
        }
    )

    metrics = result["metrics"]
    assert result["frame_count"] == len(positions)
    assert 0 <= metrics["center_time_fraction"] <= 1
    assert metrics["roller_excursion_p90"] > 0.2
    assert metrics["correction_count"] > 0
    assert "recovery_time_ms" in metrics
    assert all(
        0 <= value <= 1
        for value in result["confidence"].values()
    )

from motionos.indo_profile import (
    blend_population_and_personal_reference,
    cue_utility,
    new_personal_balance_profile,
    profile_metric_estimate,
    record_cue_response,
    update_personal_balance_profile,
)


def test_profile_updates_from_first_session():
    profile = new_personal_balance_profile()
    profile = update_personal_balance_profile(
        profile,
        session_id="s1",
        skill_id="neutral_balance_hold",
        metrics={
            "center_time_fraction": 0.52,
            "correction_rate_hz": 1.8,
        },
        confidence={
            "center_time_fraction": 0.9,
            "correction_rate_hz": 0.8,
        },
    )

    estimate = profile_metric_estimate(
        profile,
        skill_id="neutral_balance_hold",
        metric="center_time_fraction",
    )

    assert estimate is not None
    assert estimate["mean"] == 0.52
    assert estimate["confidence"] > 0


def test_population_prior_yields_to_personal_evidence():
    profile = new_personal_balance_profile()
    for index in range(5):
        profile = update_personal_balance_profile(
            profile,
            session_id=f"s{index}",
            skill_id="neutral_balance_hold",
            metrics={"center_time_fraction": 0.8},
            confidence={"center_time_fraction": 1.0},
        )

    blended = blend_population_and_personal_reference(
        profile,
        skill_id="neutral_balance_hold",
        metric="center_time_fraction",
        population_mean=0.5,
        population_confidence=0.5,
        prior_strength=2.0,
    )

    assert blended["personal_fraction"] > 0.75
    assert blended["mean"] > 0.7


def test_cue_response_tracks_rider_specific_utility():
    profile = new_personal_balance_profile()
    profile = record_cue_response(
        profile,
        cue_id="smaller_second_correction",
        target_metric="overshoot_ratio",
        before=0.55,
        after=0.32,
        improvement_direction="decrease",
        confidence=0.9,
    )
    profile = record_cue_response(
        profile,
        cue_id="smaller_second_correction",
        target_metric="overshoot_ratio",
        before=0.50,
        after=0.30,
        improvement_direction="decrease",
        confidence=0.9,
    )

    utility = cue_utility(
        profile,
        cue_id="smaller_second_correction",
        target_metric="overshoot_ratio",
    )

    assert utility is not None
    assert utility["mean_normalized_response"] > 0
    assert utility["positive_fraction"] == 1.0

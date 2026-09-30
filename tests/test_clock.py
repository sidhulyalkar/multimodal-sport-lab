from motionos.clock import (
    ClockModel,
    ClockObservation,
    compose_clock_models,
    estimate_clock_model,
    invert_clock_model,
)


def test_clock_estimator_recovers_drift_and_rejects_high_rtt_outlier():
    slope = 1.0 + 25e-6
    intercept = 8_000_000
    observations = []
    for i in range(10):
        device = i * 1_000_000_000
        session = int(slope * device + intercept)
        observations.append(ClockObservation(device, session, 500_000 + i * 1_000))
    observations.append(
        ClockObservation(4_000_000_000, 4_250_000_000, 50_000_000)
    )
    model = estimate_clock_model(observations)
    assert abs(model.drift_ppm - 25.0) < 0.5
    expected = int(slope * 7_500_000_000 + intercept)
    assert abs(model.map(7_500_000_000) - expected) < 20_000


def test_clock_model_inversion_and_composition_round_trip():
    device_to_host = ClockModel(
        slope=1.00002,
        intercept_ns=5_000_000,
        residual_rms_ns=2_000_000,
        observations_used=4,
    )
    host_to_device = invert_clock_model(device_to_host)
    identity = compose_clock_models(
        device_to_host,
        host_to_device,
    )

    assert abs(identity.slope - 1.0) < 1e-12
    assert abs(identity.intercept_ns) < 1e-6
    assert identity.residual_rms_ns > 0

    device_to_watch = compose_clock_models(
        device_to_host,
        ClockModel(
            slope=0.99999,
            intercept_ns=-2_000_000,
            residual_rms_ns=1_000_000,
            observations_used=3,
        ),
    )
    expected = round(
        0.99999
        * device_to_host.map(3_000_000_000)
        - 2_000_000
    )
    assert abs(device_to_watch.map(3_000_000_000) - expected) <= 1

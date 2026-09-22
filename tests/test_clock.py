from motionos.clock import ClockObservation, estimate_clock_model


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

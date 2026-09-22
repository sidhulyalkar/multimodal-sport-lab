from motionos.schema import SensorEvent
from motionos.sync import estimate_impulse_lag_ns


def _events(stream, offset):
    result = []
    for i in range(10):
        result.append(
            SensorEvent(
                "s",
                stream,
                f"/{stream}",
                i,
                i * 10_000_000,
                {"ax": 0, "ay": 0, "az": 20 if i == 5 else 1},
                i * 10_000_000 + offset,
                1.0,
            )
        )
    return result


def test_impulse_lag():
    assert (
        estimate_impulse_lag_ns(_events("ref", 0), _events("target", 3_000_000))
        == 3_000_000
    )

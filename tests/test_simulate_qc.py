from motionos.qc import session_qc
from motionos.session import SessionReader
from motionos.simulate import simulate_session
from motionos.validate import validate_m0_session


def test_simulated_calibration_session_passes_m0(tmp_path):
    session = simulate_session(tmp_path, duration_s=2.2, seed=1)
    reader = SessionReader(session)
    report = session_qc(reader)
    assert report["passed"] is True
    assert len(reader.list_streams()) >= 8
    assert validate_m0_session(reader).passed is True

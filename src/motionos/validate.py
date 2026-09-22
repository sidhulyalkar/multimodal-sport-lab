from __future__ import annotations

from dataclasses import dataclass

from .qc import session_qc
from .session import SessionReader

FIELD_REQUIRED = {
    "/body/watch/imu",
    "/body/left_foot/pressure",
    "/body/right_foot/pressure",
    "/equipment/imu",
}
CALIBRATION_EXTRA = {"/camera/pose3d"}


@dataclass(frozen=True)
class ValidationResult:
    passed: bool
    missing_streams: tuple[str, ...]
    qc_passed: bool


def validate_m0_session(reader: SessionReader) -> ValidationResult:
    required = set(FIELD_REQUIRED)
    if reader.manifest.mode == "calibration":
        required.update(CALIBRATION_EXTRA)
    streams = set(reader.list_streams())
    missing = tuple(sorted(required - streams))
    qc = session_qc(reader)
    return ValidationResult(
        passed=not missing and bool(qc["passed"]),
        missing_streams=missing,
        qc_passed=bool(qc["passed"]),
    )

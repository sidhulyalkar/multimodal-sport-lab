from __future__ import annotations

import json
import math
import os
from dataclasses import asdict, dataclass
from pathlib import Path

from .calibration import (
    CalibrationBundle,
    CalibrationSource,
    GapRegion,
    calibration_gap_regions,
    load_calibration_bundle,
)
from .clock import ClockModel
from .clock_sync import (
    ClockSyncReceipt,
    load_clock_sync_receipt,
    validate_clock_sync_receipt,
)
from .pose import BodyModel, load_body_model
from .provenance import sha256_file
from .session import SessionReader

FIRST_RIDE_SCHEMA_VERSION = "motionos.first-ride.v1"
MOVEMENT_LOG_SCHEMA_VERSION = "motionos.first-ride-log.v1"

REQUIRED_ROLES = ("watch", "equipment", "insoles", "camera")
NON_REFERENCE_ROLES = ("equipment", "insoles", "camera")
REQUIRED_PROFILE_KINDS = (
    "equipment_mount",
    "left_insole_geometry",
    "right_insole_geometry",
    "body_model",
)
REQUIRED_MOVEMENT_STAGES = (
    "quiet_stance",
    "pushes",
    "straight_glide",
    "left_carves",
    "right_carves",
    "front_load_shift",
    "rear_load_shift",
    "foot_repositioning",
    "braking",
    "stabilization_perturbations",
    "sync_start",
    "sync_middle",
    "sync_end",
)

RECEIPT_RULES: dict[str, tuple[str, str]] = {
    "watch": ("P0", "passed"),
    "equipment": ("P1", "passed"),
    "insoles": ("P2-capture", "capture_passed"),
    "camera": ("P5A-camera", "passed"),
}


@dataclass(frozen=True)
class RideReceiptStatus:
    role: str
    session_id: str
    protocol: str | None
    expected_protocol: str
    pass_field: str
    passed: bool
    path: str | None
    sha256: str | None
    errors: tuple[str, ...]

    def to_dict(self) -> dict[str, object]:
        return asdict(self)


@dataclass(frozen=True)
class RideClockStatus:
    role: str
    reference_role: str
    receipt_path: str
    receipt_sha256: str
    drift_ppm: float
    residual_rms_ms: float
    mapping_quality: float
    structural_coverage_passed: bool
    observation_count: int
    model_matches_bundle: bool
    max_sync_residual_ms: float | None
    threshold_passed: bool | None

    def to_dict(self) -> dict[str, object]:
        return asdict(self)


@dataclass(frozen=True)
class MovementProtocolStatus:
    path: str
    sha256: str
    ride_id: str | None
    missing_stages: tuple[str, ...]
    incomplete_stages: tuple[str, ...]
    extra_stages: tuple[str, ...]
    duplicate_stages: tuple[str, ...]
    completed: bool

    def to_dict(self) -> dict[str, object]:
        return asdict(self)


@dataclass(frozen=True)
class BodyModelStatus:
    path: str
    sha256: str
    model_id: str
    height_m: float
    segment_count: int
    bound_to_calibration_bundle: bool

    def to_dict(self) -> dict[str, object]:
        return asdict(self)


@dataclass(frozen=True)
class FirstRideReport:
    calibration_bundle_path: str
    calibration_bundle_sha256: str
    reference_role: str
    reference_session_id: str
    required_roles: tuple[str, ...]
    missing_roles: tuple[str, ...]
    receipts: tuple[RideReceiptStatus, ...]
    clocks: tuple[RideClockStatus, ...]
    body_model: BodyModelStatus
    movement_protocol: MovementProtocolStatus
    required_profile_kinds: tuple[str, ...]
    missing_profile_kinds: tuple[str, ...]
    gaps: tuple[GapRegion, ...]
    evidence_complete: bool
    timing_gates_frozen: bool
    timing_passed: bool
    gap_gate_frozen: bool
    gap_passed: bool
    qualified: bool
    max_gap_multiple: float | None
    schema_version: str = FIRST_RIDE_SCHEMA_VERSION

    def to_dict(self) -> dict[str, object]:
        return {
            "schema_version": self.schema_version,
            "calibration_bundle": {
                "path": self.calibration_bundle_path,
                "sha256": self.calibration_bundle_sha256,
                "reference_role": self.reference_role,
                "reference_session_id": self.reference_session_id,
            },
            "required_roles": list(self.required_roles),
            "missing_roles": list(self.missing_roles),
            "receipts": [receipt.to_dict() for receipt in self.receipts],
            "clocks": [clock.to_dict() for clock in self.clocks],
            "body_model": self.body_model.to_dict(),
            "movement_protocol": self.movement_protocol.to_dict(),
            "required_profile_kinds": list(self.required_profile_kinds),
            "missing_profile_kinds": list(self.missing_profile_kinds),
            "gap_gate": {
                "frozen": self.gap_gate_frozen,
                "max_gap_multiple": self.max_gap_multiple,
                "passed": self.gap_passed,
            },
            "gaps": [gap.to_dict() for gap in self.gaps],
            "timing_gate": {
                "frozen": self.timing_gates_frozen,
                "passed": self.timing_passed,
            },
            "evidence_complete": self.evidence_complete,
            "qualified": self.qualified,
            "claim_boundary": (
                "evidence_complete means the required modality receipts, "
                "clock correspondences, profiles, movement protocol, and "
                "hashes are internally consistent. qualified additionally "
                "requires explicitly frozen synchronization-residual and "
                "gap gates. Neither verdict establishes biomechanical or "
                "clinical accuracy."
            ),
        }


def _resolve(raw: str, *, base: Path) -> Path:
    path = Path(raw)
    if path.is_absolute():
        return path
    return (base / path).resolve()


def _load_json_object(path: Path, *, label: str) -> dict[str, object]:
    raw = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(raw, dict):
        raise TypeError(f"{label} must contain a JSON object")
    return dict(raw)


def _artifact_path(
    calibration_path: Path,
    raw: str,
) -> Path:
    return _resolve(raw, base=calibration_path.parent)


def _session_path(
    calibration_path: Path,
    source: CalibrationSource,
) -> Path:
    return _artifact_path(calibration_path, source.session_path)


def _clock_models_match(
    first: ClockModel,
    second: ClockModel,
) -> bool:
    return (
        math.isclose(
            first.slope,
            second.slope,
            rel_tol=1e-12,
            abs_tol=1e-15,
        )
        and math.isclose(
            first.intercept_ns,
            second.intercept_ns,
            rel_tol=1e-12,
            abs_tol=1e-3,
        )
        and math.isclose(
            first.residual_rms_ns,
            second.residual_rms_ns,
            rel_tol=1e-12,
            abs_tol=1e-3,
        )
        and first.observations_used == second.observations_used
    )


def _receipt_status(
    calibration_path: Path,
    source: CalibrationSource,
) -> RideReceiptStatus:
    expected_protocol, pass_field = RECEIPT_RULES[source.role]
    errors: list[str] = []

    if source.receipt is None:
        return RideReceiptStatus(
            role=source.role,
            session_id=source.session_id,
            protocol=None,
            expected_protocol=expected_protocol,
            pass_field=pass_field,
            passed=False,
            path=None,
            sha256=None,
            errors=("qualification receipt is missing",),
        )

    path = _artifact_path(calibration_path, source.receipt.path)
    raw = _load_json_object(
        path,
        label=f"{source.role} qualification receipt",
    )
    protocol = (
        str(raw["protocol"])
        if raw.get("protocol") is not None
        else None
    )
    receipt_session_id = (
        str(raw["session_id"])
        if raw.get("session_id") is not None
        else None
    )

    if protocol != expected_protocol:
        errors.append(
            f"protocol mismatch: expected {expected_protocol}, got {protocol}"
        )
    if receipt_session_id != source.session_id:
        errors.append(
            "receipt session_id does not match calibration source"
        )

    passed_value = raw.get(pass_field)
    if passed_value is not True:
        errors.append(f"{pass_field} is not true")

    return RideReceiptStatus(
        role=source.role,
        session_id=source.session_id,
        protocol=protocol,
        expected_protocol=expected_protocol,
        pass_field=pass_field,
        passed=not errors,
        path=source.receipt.path,
        sha256=source.receipt.sha256,
        errors=tuple(errors),
    )


def _clock_status(
    calibration_path: Path,
    bundle: CalibrationBundle,
    reference_source: CalibrationSource,
    source: CalibrationSource,
    *,
    max_sync_residual_ms: float | None,
) -> RideClockStatus:
    if source.clock_sync is None or source.clock_model is None:
        raise ValueError(
            f"non-reference role {source.role!r} lacks clock evidence"
        )

    sync_path = _artifact_path(
        calibration_path,
        source.clock_sync.path,
    )
    receipt: ClockSyncReceipt = load_clock_sync_receipt(sync_path)

    reference_reader = SessionReader(
        _session_path(calibration_path, reference_source)
    )
    target_reader = SessionReader(
        _session_path(calibration_path, source)
    )
    recomputed = validate_clock_sync_receipt(
        receipt,
        reference_reader,
        target_reader,
    )
    model_matches = _clock_models_match(
        recomputed,
        source.clock_model,
    )
    if not model_matches:
        raise ValueError(
            f"stored calibration clock model changed for role {source.role!r}"
        )

    threshold_passed = (
        recomputed.residual_rms_ns / 1e6 <= max_sync_residual_ms
        if max_sync_residual_ms is not None
        else None
    )

    return RideClockStatus(
        role=source.role,
        reference_role=bundle.reference_role,
        receipt_path=source.clock_sync.path,
        receipt_sha256=source.clock_sync.sha256,
        drift_ppm=recomputed.drift_ppm,
        residual_rms_ms=recomputed.residual_rms_ns / 1e6,
        mapping_quality=recomputed.quality,
        structural_coverage_passed=receipt.coverage.passed,
        observation_count=receipt.coverage.observation_count,
        model_matches_bundle=model_matches,
        max_sync_residual_ms=max_sync_residual_ms,
        threshold_passed=threshold_passed,
    )


def _movement_protocol_status(
    path: Path,
) -> MovementProtocolStatus:
    raw = _load_json_object(path, label="first-ride movement log")
    if raw.get("schema_version") != MOVEMENT_LOG_SCHEMA_VERSION:
        raise ValueError("unsupported first-ride movement log schema")

    stages_raw = raw.get("stages")
    if not isinstance(stages_raw, list):
        raise TypeError("first-ride movement log stages must be a list")

    completed_by_id: dict[str, bool] = {}
    counts: dict[str, int] = {}
    for index, item in enumerate(stages_raw):
        if not isinstance(item, dict):
            raise TypeError(f"movement stage {index} must be an object")
        stage_id = str(item.get("id", "")).strip()
        if not stage_id:
            raise ValueError(f"movement stage {index} requires id")
        counts[stage_id] = counts.get(stage_id, 0) + 1
        completed_by_id[stage_id] = bool(item.get("completed", False))

    required = set(REQUIRED_MOVEMENT_STAGES)
    observed = set(completed_by_id)
    missing = tuple(sorted(required - observed))
    incomplete = tuple(
        sorted(
            stage
            for stage in required & observed
            if not completed_by_id[stage]
        )
    )
    extra = tuple(sorted(observed - required))
    duplicates = tuple(
        sorted(stage for stage, count in counts.items() if count > 1)
    )

    return MovementProtocolStatus(
        path=str(path),
        sha256=sha256_file(path),
        ride_id=(
            str(raw["ride_id"])
            if raw.get("ride_id") is not None
            else None
        ),
        missing_stages=missing,
        incomplete_stages=incomplete,
        extra_stages=extra,
        duplicate_stages=duplicates,
        completed=not missing and not incomplete and not duplicates,
    )


def _body_model_status(
    path: Path,
    bundle: CalibrationBundle,
) -> BodyModelStatus:
    model: BodyModel = load_body_model(path)
    digest = sha256_file(path)
    matching_profiles = [
        profile
        for profile in bundle.profiles
        if profile.kind == "body_model"
    ]
    bound = (
        len(matching_profiles) == 1
        and matching_profiles[0].sha256 == digest
    )
    return BodyModelStatus(
        path=str(path),
        sha256=digest,
        model_id=model.model_id,
        height_m=model.height_m,
        segment_count=len(model.segments_m),
        bound_to_calibration_bundle=bound,
    )


def _timing_thresholds(
    raw: object,
) -> dict[str, float]:
    if raw is None:
        return {}
    if not isinstance(raw, dict):
        raise TypeError("timing_gates must be an object")

    thresholds: dict[str, float] = {}
    for role, value in raw.items():
        if str(role) not in NON_REFERENCE_ROLES:
            raise ValueError(
                f"unsupported timing gate role: {role!r}"
            )
        if not isinstance(value, dict):
            raise TypeError(
                f"timing gate for role {role!r} must be an object"
            )
        threshold = value.get("max_sync_residual_ms")
        if threshold is None:
            continue
        threshold_float = float(threshold)
        if not math.isfinite(threshold_float) or threshold_float <= 0:
            raise ValueError(
                f"max_sync_residual_ms for role {role!r} "
                "must be positive and finite"
            )
        thresholds[str(role)] = threshold_float
    return thresholds


def build_first_ride_report(
    spec_path: str | Path,
    output_path: str | Path,
) -> FirstRideReport:
    spec_file = Path(spec_path).resolve()
    spec_dir = spec_file.parent
    raw = _load_json_object(spec_file, label="first-ride spec")

    calibration_raw = raw.get("calibration_bundle")
    body_model_raw = raw.get("body_model")
    movement_log_raw = raw.get("movement_log")
    if calibration_raw is None:
        raise ValueError("first-ride spec requires calibration_bundle")
    if body_model_raw is None:
        raise ValueError("first-ride spec requires body_model")
    if movement_log_raw is None:
        raise ValueError("first-ride spec requires movement_log")

    calibration_path = _resolve(
        str(calibration_raw),
        base=spec_dir,
    )
    body_model_path = _resolve(
        str(body_model_raw),
        base=spec_dir,
    )
    movement_log_path = _resolve(
        str(movement_log_raw),
        base=spec_dir,
    )

    bundle = load_calibration_bundle(
        calibration_path,
        verify_hashes=True,
    )
    source_by_role = {
        source.role: source
        for source in bundle.sources
    }
    missing_roles = tuple(
        role
        for role in REQUIRED_ROLES
        if role not in source_by_role
    )

    if bundle.reference_role != "watch":
        raise ValueError(
            "first M0 calibration ride requires watch as reference role"
        )
    if "watch" not in source_by_role:
        raise ValueError("calibration bundle is missing Watch reference")

    receipts = tuple(
        _receipt_status(
            calibration_path,
            source_by_role[role],
        )
        for role in REQUIRED_ROLES
        if role in source_by_role
    )

    thresholds = _timing_thresholds(raw.get("timing_gates"))
    reference_source = source_by_role["watch"]
    clocks = tuple(
        _clock_status(
            calibration_path,
            bundle,
            reference_source,
            source_by_role[role],
            max_sync_residual_ms=thresholds.get(role),
        )
        for role in NON_REFERENCE_ROLES
        if role in source_by_role
    )

    body_model = _body_model_status(
        body_model_path,
        bundle,
    )
    movement_protocol = _movement_protocol_status(
        movement_log_path
    )

    profile_kinds = {profile.kind for profile in bundle.profiles}
    missing_profiles = tuple(
        kind
        for kind in REQUIRED_PROFILE_KINDS
        if kind not in profile_kinds
    )

    gaps = calibration_gap_regions(calibration_path)

    max_gap_raw = raw.get("max_gap_multiple")
    max_gap_multiple: float | None
    if max_gap_raw is None:
        max_gap_multiple = None
    else:
        max_gap_multiple = float(max_gap_raw)
        if (
            not math.isfinite(max_gap_multiple)
            or max_gap_multiple <= 1
        ):
            raise ValueError(
                "max_gap_multiple must be finite and greater than 1"
            )

    gap_gate_frozen = max_gap_multiple is not None
    gap_passed = (
        all(gap.gap_multiple <= max_gap_multiple for gap in gaps)
        if max_gap_multiple is not None
        else False
    )

    timing_gates_frozen = (
        set(thresholds) == set(NON_REFERENCE_ROLES)
    )
    timing_passed = (
        timing_gates_frozen
        and len(clocks) == len(NON_REFERENCE_ROLES)
        and all(clock.threshold_passed is True for clock in clocks)
    )

    receipts_pass = (
        len(receipts) == len(REQUIRED_ROLES)
        and all(receipt.passed for receipt in receipts)
    )
    clocks_structurally_valid = (
        len(clocks) == len(NON_REFERENCE_ROLES)
        and all(
            clock.structural_coverage_passed
            and clock.model_matches_bundle
            for clock in clocks
        )
    )
    evidence_complete = (
        not missing_roles
        and receipts_pass
        and clocks_structurally_valid
        and not missing_profiles
        and body_model.bound_to_calibration_bundle
        and movement_protocol.completed
    )
    qualified = (
        evidence_complete
        and timing_gates_frozen
        and timing_passed
        and gap_gate_frozen
        and gap_passed
    )

    output = Path(output_path).resolve()
    output.parent.mkdir(parents=True, exist_ok=True)

    report = FirstRideReport(
        calibration_bundle_path=os.path.relpath(
            calibration_path,
            output.parent,
        ),
        calibration_bundle_sha256=sha256_file(calibration_path),
        reference_role=bundle.reference_role,
        reference_session_id=bundle.reference_session_id,
        required_roles=REQUIRED_ROLES,
        missing_roles=missing_roles,
        receipts=receipts,
        clocks=clocks,
        body_model=body_model,
        movement_protocol=movement_protocol,
        required_profile_kinds=REQUIRED_PROFILE_KINDS,
        missing_profile_kinds=missing_profiles,
        gaps=gaps,
        evidence_complete=evidence_complete,
        timing_gates_frozen=timing_gates_frozen,
        timing_passed=timing_passed,
        gap_gate_frozen=gap_gate_frozen,
        gap_passed=gap_passed,
        qualified=qualified,
        max_gap_multiple=max_gap_multiple,
    )
    output.write_text(
        json.dumps(report.to_dict(), indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return report

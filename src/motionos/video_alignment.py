from __future__ import annotations

import hashlib
import json
import math
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any

from .clock import ClockModel, ClockObservation, estimate_clock_model

VIDEO_ALIGNMENT_SCHEMA_VERSION = "motionos.video-alignment.v1"


@dataclass(frozen=True)
class VideoAlignmentAnchor:
    label: str
    video_pts_ns: int
    reference_time_ns: int
    uncertainty_ns: int = 0
    source: str = "declared_correspondence"

    def to_dict(self) -> dict[str, object]:
        return asdict(self)

    def to_observation(self) -> ClockObservation:
        return ClockObservation(
            device_time_ns=self.video_pts_ns,
            session_time_ns=self.reference_time_ns,
            round_trip_ns=self.uncertainty_ns,
        )


@dataclass(frozen=True)
class VideoAlignmentCoverage:
    passed: bool
    anchor_count: int
    reference_start_ns: int
    reference_end_ns: int
    first_position_fraction: float
    last_position_fraction: float
    has_middle_anchor: bool
    reference_span_fraction: float

    def to_dict(self) -> dict[str, object]:
        return asdict(self)


@dataclass(frozen=True)
class VideoAlignmentReceipt:
    run_id: str
    source_video_filename: str
    source_video_sha256: str
    source_video_byte_count: int
    video_duration_ns: int
    reference_start_ns: int
    reference_end_ns: int
    anchors: tuple[VideoAlignmentAnchor, ...]
    coverage: VideoAlignmentCoverage
    clock_model: ClockModel
    anchor_residuals_ns: tuple[int, ...]
    trim_video_start_ns: int
    trim_video_end_ns: int
    source_metadata: dict[str, object]
    schema_version: str = VIDEO_ALIGNMENT_SCHEMA_VERSION

    def map_video_pts_to_reference(self, video_pts_ns: int) -> int:
        return self.clock_model.map(video_pts_ns)

    def map_reference_to_video_pts(self, reference_time_ns: int) -> int:
        if not math.isfinite(self.clock_model.slope) or self.clock_model.slope <= 0:
            raise ValueError("video-alignment clock slope must be positive")
        value = (
            reference_time_ns - self.clock_model.intercept_ns
        ) / self.clock_model.slope
        return round(value)

    def to_dict(self) -> dict[str, object]:
        return {
            "schema_version": self.schema_version,
            "run_id": self.run_id,
            "source_video": {
                "filename": self.source_video_filename,
                "sha256": self.source_video_sha256,
                "byte_count": self.source_video_byte_count,
                "duration_ns": self.video_duration_ns,
                "metadata": dict(self.source_metadata),
            },
            "reference_window": {
                "start_ns": self.reference_start_ns,
                "end_ns": self.reference_end_ns,
            },
            "anchors": [anchor.to_dict() for anchor in self.anchors],
            "coverage": self.coverage.to_dict(),
            "clock_model": {
                "slope": self.clock_model.slope,
                "intercept_ns": self.clock_model.intercept_ns,
                "drift_ppm": self.clock_model.drift_ppm,
                "residual_rms_ns": self.clock_model.residual_rms_ns,
                "residual_rms_ms": self.clock_model.residual_rms_ns / 1e6,
                "observations_used": self.clock_model.observations_used,
            },
            "anchor_residuals_ns": list(self.anchor_residuals_ns),
            "trim_window": {
                "video_start_ns": self.trim_video_start_ns,
                "video_end_ns": self.trim_video_end_ns,
            },
            "mapping": "source video PTS -> MotionOS reference/session time",
            "claim_boundary": (
                "This receipt binds an imported video to a declared temporal "
                "alignment and derived trim window. It does not prove camera "
                "calibration, 3D geometry, biomechanics accuracy, or event labels."
            ),
        }


def file_sha256(path: str | Path) -> tuple[str, int]:
    source = Path(path)
    hasher = hashlib.sha256()
    byte_count = 0
    with source.open("rb") as handle:
        while chunk := handle.read(1024 * 1024):
            hasher.update(chunk)
            byte_count += len(chunk)
    return hasher.hexdigest(), byte_count


def _validate_anchors(
    anchors: list[VideoAlignmentAnchor],
    *,
    video_duration_ns: int,
    reference_start_ns: int,
    reference_end_ns: int,
) -> list[VideoAlignmentAnchor]:
    if video_duration_ns <= 0:
        raise ValueError("video duration must be positive")
    if reference_end_ns <= reference_start_ns:
        raise ValueError("reference end must be after reference start")
    if len(anchors) < 3:
        raise ValueError("at least three video alignment anchors are required")

    labels = [anchor.label.strip() for anchor in anchors]
    if any(not label for label in labels):
        raise ValueError("video alignment anchor labels cannot be empty")
    if len(set(labels)) != len(labels):
        raise ValueError("video alignment anchor labels must be unique")

    ordered = sorted(anchors, key=lambda item: item.reference_time_ns)
    previous_video: int | None = None
    previous_reference: int | None = None
    for anchor in ordered:
        if anchor.video_pts_ns < 0 or anchor.video_pts_ns > video_duration_ns:
            raise ValueError(
                f"video anchor {anchor.label!r} falls outside source duration"
            )
        if not reference_start_ns <= anchor.reference_time_ns <= reference_end_ns:
            raise ValueError(
                f"reference anchor {anchor.label!r} falls outside session window"
            )
        if anchor.uncertainty_ns < 0:
            raise ValueError("video alignment uncertainty cannot be negative")
        if (
            previous_video is not None
            and anchor.video_pts_ns <= previous_video
        ):
            raise ValueError(
                "video alignment anchors must preserve temporal order"
            )
        if (
            previous_reference is not None
            and anchor.reference_time_ns <= previous_reference
        ):
            raise ValueError(
                "reference alignment anchors must be strictly increasing"
            )
        previous_video = anchor.video_pts_ns
        previous_reference = anchor.reference_time_ns
    return ordered


def alignment_coverage(
    anchors: list[VideoAlignmentAnchor],
    *,
    reference_start_ns: int,
    reference_end_ns: int,
) -> VideoAlignmentCoverage:
    ordered = sorted(anchors, key=lambda item: item.reference_time_ns)
    if len(ordered) < 3:
        raise ValueError("at least three video alignment anchors are required")

    duration = reference_end_ns - reference_start_ns
    if duration <= 0:
        raise ValueError("reference window must span time")

    positions = [
        (anchor.reference_time_ns - reference_start_ns) / duration
        for anchor in ordered
    ]
    first = positions[0]
    last = positions[-1]
    middle = any(0.30 <= value <= 0.70 for value in positions[1:-1])
    span_fraction = (
        ordered[-1].reference_time_ns - ordered[0].reference_time_ns
    ) / duration

    passed = (
        all(0.0 <= value <= 1.0 for value in positions)
        and first <= 0.20
        and middle
        and last >= 0.80
    )
    return VideoAlignmentCoverage(
        passed=passed,
        anchor_count=len(ordered),
        reference_start_ns=reference_start_ns,
        reference_end_ns=reference_end_ns,
        first_position_fraction=first,
        last_position_fraction=last,
        has_middle_anchor=middle,
        reference_span_fraction=span_fraction,
    )


def build_video_alignment(
    video_path: str | Path,
    *,
    run_id: str,
    video_duration_ns: int,
    reference_start_ns: int,
    reference_end_ns: int,
    anchors: list[VideoAlignmentAnchor],
    source_metadata: dict[str, object] | None = None,
) -> VideoAlignmentReceipt:
    if not run_id.strip():
        raise ValueError("run_id cannot be empty")

    source = Path(video_path)
    if not source.is_file():
        raise FileNotFoundError(source)

    ordered = _validate_anchors(
        anchors,
        video_duration_ns=video_duration_ns,
        reference_start_ns=reference_start_ns,
        reference_end_ns=reference_end_ns,
    )
    observations = [anchor.to_observation() for anchor in ordered]
    model = estimate_clock_model(
        observations,
        keep_fraction=1.0,
        prune_residual_outliers=False,
    )
    if not math.isfinite(model.slope) or model.slope <= 0:
        raise ValueError("video alignment produced an invalid clock slope")

    coverage = alignment_coverage(
        ordered,
        reference_start_ns=reference_start_ns,
        reference_end_ns=reference_end_ns,
    )
    residuals = tuple(
        observation.session_time_ns
        - model.map(observation.device_time_ns)
        for observation in observations
    )

    def inverse(reference_ns: int) -> int:
        mapped = round((reference_ns - model.intercept_ns) / model.slope)
        return max(0, min(video_duration_ns, mapped))

    trim_start = inverse(reference_start_ns)
    trim_end = inverse(reference_end_ns)
    if trim_end <= trim_start:
        raise ValueError("derived video trim window is empty")

    digest, byte_count = file_sha256(source)
    return VideoAlignmentReceipt(
        run_id=run_id,
        source_video_filename=source.name,
        source_video_sha256=digest,
        source_video_byte_count=byte_count,
        video_duration_ns=video_duration_ns,
        reference_start_ns=reference_start_ns,
        reference_end_ns=reference_end_ns,
        anchors=tuple(ordered),
        coverage=coverage,
        clock_model=model,
        anchor_residuals_ns=residuals,
        trim_video_start_ns=trim_start,
        trim_video_end_ns=trim_end,
        source_metadata=dict(source_metadata or {}),
    )


def write_video_alignment(
    spec_path: str | Path,
    output_path: str | Path,
) -> VideoAlignmentReceipt:
    raw = json.loads(Path(spec_path).read_text(encoding="utf-8"))
    if not isinstance(raw, dict):
        raise TypeError("video alignment spec must be a JSON object")

    source_video = raw.get("source_video")
    if not isinstance(source_video, str) or not source_video:
        raise TypeError("video alignment spec source_video must be a path string")

    raw_anchors = raw.get("anchors")
    if not isinstance(raw_anchors, list):
        raise TypeError("video alignment spec anchors must be a list")

    anchors: list[VideoAlignmentAnchor] = []
    for index, value in enumerate(raw_anchors):
        if not isinstance(value, dict):
            raise TypeError(f"video alignment anchor {index} must be an object")
        try:
            anchors.append(
                VideoAlignmentAnchor(
                    label=str(value["label"]),
                    video_pts_ns=int(value["video_pts_ns"]),
                    reference_time_ns=int(value["reference_time_ns"]),
                    uncertainty_ns=int(value.get("uncertainty_ns", 0)),
                    source=str(
                        value.get(
                            "source",
                            "declared_correspondence",
                        )
                    ),
                )
            )
        except (KeyError, TypeError, ValueError) as exc:
            raise ValueError(
                f"invalid video alignment anchor at index {index}"
            ) from exc

    metadata = raw.get("source_metadata", {})
    if not isinstance(metadata, dict):
        raise TypeError("source_metadata must be a JSON object")

    receipt = build_video_alignment(
        source_video,
        run_id=str(raw["run_id"]),
        video_duration_ns=int(raw["video_duration_ns"]),
        reference_start_ns=int(raw["reference_start_ns"]),
        reference_end_ns=int(raw["reference_end_ns"]),
        anchors=anchors,
        source_metadata={str(k): v for k, v in metadata.items()},
    )

    output = Path(output_path)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(
        json.dumps(receipt.to_dict(), indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return receipt


def load_video_alignment(
    path: str | Path,
) -> VideoAlignmentReceipt:
    raw = json.loads(Path(path).read_text(encoding="utf-8"))
    if not isinstance(raw, dict):
        raise TypeError("video alignment receipt must be a JSON object")
    if raw.get("schema_version") != VIDEO_ALIGNMENT_SCHEMA_VERSION:
        raise ValueError("unsupported video alignment receipt schema")

    source = raw.get("source_video")
    reference = raw.get("reference_window")
    model_raw = raw.get("clock_model")
    trim = raw.get("trim_window")
    anchors_raw = raw.get("anchors")
    coverage_raw = raw.get("coverage")
    if not all(
        isinstance(value, dict)
        for value in (source, reference, model_raw, trim, coverage_raw)
    ):
        raise TypeError("video alignment receipt has malformed object fields")
    if not isinstance(anchors_raw, list):
        raise TypeError("video alignment receipt anchors must be a list")

    anchors = tuple(
        VideoAlignmentAnchor(
            label=str(value["label"]),
            video_pts_ns=int(value["video_pts_ns"]),
            reference_time_ns=int(value["reference_time_ns"]),
            uncertainty_ns=int(value.get("uncertainty_ns", 0)),
            source=str(value.get("source", "declared_correspondence")),
        )
        for value in anchors_raw
        if isinstance(value, dict)
    )
    if len(anchors) != len(anchors_raw):
        raise TypeError("video alignment receipt contains malformed anchors")

    metadata = source.get("metadata", {})
    if not isinstance(metadata, dict):
        raise TypeError("video alignment source metadata must be an object")

    return VideoAlignmentReceipt(
        run_id=str(raw["run_id"]),
        source_video_filename=str(source["filename"]),
        source_video_sha256=str(source["sha256"]),
        source_video_byte_count=int(source["byte_count"]),
        video_duration_ns=int(source["duration_ns"]),
        reference_start_ns=int(reference["start_ns"]),
        reference_end_ns=int(reference["end_ns"]),
        anchors=anchors,
        coverage=VideoAlignmentCoverage(
            passed=bool(coverage_raw["passed"]),
            anchor_count=int(coverage_raw["anchor_count"]),
            reference_start_ns=int(coverage_raw["reference_start_ns"]),
            reference_end_ns=int(coverage_raw["reference_end_ns"]),
            first_position_fraction=float(
                coverage_raw["first_position_fraction"]
            ),
            last_position_fraction=float(
                coverage_raw["last_position_fraction"]
            ),
            has_middle_anchor=bool(coverage_raw["has_middle_anchor"]),
            reference_span_fraction=float(
                coverage_raw["reference_span_fraction"]
            ),
        ),
        clock_model=ClockModel(
            slope=float(model_raw["slope"]),
            intercept_ns=float(model_raw["intercept_ns"]),
            residual_rms_ns=float(model_raw["residual_rms_ns"]),
            observations_used=int(model_raw["observations_used"]),
        ),
        anchor_residuals_ns=tuple(
            int(value) for value in raw.get("anchor_residuals_ns", [])
        ),
        trim_video_start_ns=int(trim["video_start_ns"]),
        trim_video_end_ns=int(trim["video_end_ns"]),
        source_metadata={str(k): v for k, v in metadata.items()},
    )


def validate_video_alignment(
    receipt: VideoAlignmentReceipt,
    video_path: str | Path,
) -> ClockModel:
    digest, byte_count = file_sha256(video_path)
    if digest != receipt.source_video_sha256:
        raise ValueError("video alignment source hash mismatch")
    if byte_count != receipt.source_video_byte_count:
        raise ValueError("video alignment source byte count mismatch")

    ordered = _validate_anchors(
        list(receipt.anchors),
        video_duration_ns=receipt.video_duration_ns,
        reference_start_ns=receipt.reference_start_ns,
        reference_end_ns=receipt.reference_end_ns,
    )
    coverage = alignment_coverage(
        ordered,
        reference_start_ns=receipt.reference_start_ns,
        reference_end_ns=receipt.reference_end_ns,
    )
    if coverage != receipt.coverage:
        raise ValueError("video alignment coverage does not recompute")

    model = estimate_clock_model(
        [anchor.to_observation() for anchor in ordered],
        keep_fraction=1.0,
        prune_residual_outliers=False,
    )
    stored = receipt.clock_model
    if (
        not math.isclose(model.slope, stored.slope, rel_tol=1e-12, abs_tol=1e-15)
        or not math.isclose(
            model.intercept_ns,
            stored.intercept_ns,
            rel_tol=1e-12,
            abs_tol=1e-3,
        )
        or not math.isclose(
            model.residual_rms_ns,
            stored.residual_rms_ns,
            rel_tol=1e-12,
            abs_tol=1e-3,
        )
        or model.observations_used != stored.observations_used
    ):
        raise ValueError("video alignment affine model does not recompute")

    if receipt.trim_video_start_ns < 0:
        raise ValueError("video alignment trim start is negative")
    if receipt.trim_video_end_ns > receipt.video_duration_ns:
        raise ValueError("video alignment trim end exceeds source duration")
    if receipt.trim_video_end_ns <= receipt.trim_video_start_ns:
        raise ValueError("video alignment trim window is empty")
    return model

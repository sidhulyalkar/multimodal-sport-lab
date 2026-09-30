from __future__ import annotations

from collections.abc import Iterable
from dataclasses import dataclass
from pathlib import Path

from .clock import ClockModel, ClockObservation, estimate_clock_model
from .schema import SensorEvent
from .vision_contract import VisionJointObservation, VisionObservation


@dataclass(frozen=True)
class Pose2DJournal:
    source_id: str
    observations: tuple[VisionObservation, ...]
    clock_model: ClockModel


def fit_embedded_host_clock(
    events: Iterable[SensorEvent],
) -> ClockModel:
    anchors: list[ClockObservation] = []
    for event in events:
        if event.stream != "/camera/frame":
            continue
        raw = event.payload.get("host_monotonic_time_ns")
        if raw is None:
            continue
        host_time_ns = round(float(raw))
        if host_time_ns < 0:
            continue
        anchors.append(
            ClockObservation(
                device_time_ns=event.device_time_ns,
                session_time_ns=host_time_ns,
                round_trip_ns=1,
            )
        )

    if len(anchors) < 3:
        raise ValueError(
            "camera journal requires at least three embedded host-clock anchors"
        )
    return estimate_clock_model(
        anchors,
        keep_fraction=1.0,
        prune_residual_outliers=False,
    )


def load_unmapped_pose2d_journal(
    path: str | Path,
    *,
    source_id: str,
) -> tuple[VisionObservation, ...]:
    return _parse_pose2d_events(
        _load_events(path),
        source_id=source_id,
    )


def load_pose2d_journal(
    path: str | Path,
    *,
    source_id: str,
    clock_model: ClockModel | None = None,
) -> Pose2DJournal:
    events = _load_events(path)
    if clock_model is None:
        clock_model = fit_embedded_host_clock(events)

    raw_observations = _parse_pose2d_events(
        events,
        source_id=source_id,
    )
    observations = tuple(
        VisionObservation(
            source_id=item.source_id,
            frame_sequence=item.frame_sequence,
            frame_source_time_ns=item.frame_source_time_ns,
            mapped_session_time_ns=clock_model.map(
                item.frame_source_time_ns
            ),
            timing_uncertainty_ns=max(
                0,
                round(clock_model.residual_rms_ns),
            ),
            coordinate_frame=item.coordinate_frame,
            model_identifier=item.model_identifier,
            joints=item.joints,
        )
        for item in raw_observations
    )

    return Pose2DJournal(
        source_id=source_id,
        observations=observations,
        clock_model=clock_model,
    )


def _parse_pose2d_events(
    events: Iterable[SensorEvent],
    *,
    source_id: str,
) -> tuple[VisionObservation, ...]:
    observations: list[VisionObservation] = []
    for event in events:
        if event.stream != "/camera/pose2d":
            continue
        if event.device_id != source_id:
            continue

        payload = event.payload
        width = round(float(payload["image_width_px"]))
        height = round(float(payload["image_height_px"]))
        if width <= 0 or height <= 0:
            raise ValueError("pose2d image dimensions must be positive")
        if payload.get("joint_coordinate_frame") != (
            "vision_normalized_lower_left"
        ):
            raise ValueError(
                "pose2d journal requires Vision normalized lower-left joints"
            )

        raw_joints = payload.get("joints_normalized")
        if not isinstance(raw_joints, dict):
            raise TypeError("pose2d joints_normalized must be an object")

        joints: dict[str, VisionJointObservation] = {}
        for name, raw_joint in raw_joints.items():
            if not isinstance(raw_joint, dict):
                raise TypeError(f"joint {name!r} must be an object")
            x = float(raw_joint["x"])
            y = float(raw_joint["y"])
            confidence = float(raw_joint["confidence"])
            if not 0.0 <= x <= 1.0 or not 0.0 <= y <= 1.0:
                raise ValueError(
                    f"joint {name!r} normalized coordinates are out of range"
                )
            joints[str(name)] = VisionJointObservation(
                x=x * width,
                y=(1.0 - y) * height,
                confidence=confidence,
            )

        observations.append(
            VisionObservation(
                source_id=source_id,
                frame_sequence=round(
                    float(payload["source_frame_sequence"])
                ),
                frame_source_time_ns=round(
                    float(payload["source_frame_pts_ns"])
                ),
                mapped_session_time_ns=None,
                timing_uncertainty_ns=None,
                coordinate_frame="image_pixels",
                model_identifier=str(
                    payload.get(
                        "vision_request",
                        "VNDetectHumanBodyPoseRequest",
                    )
                ),
                joints=joints,
            )
        )

    if not observations:
        raise ValueError(f"no /camera/pose2d events found for {source_id}")

    observations.sort(
        key=lambda item: (
            item.frame_source_time_ns,
            item.frame_sequence,
        )
    )
    return tuple(observations)


def pair_pose_observations(
    reference: Iterable[VisionObservation],
    target: Iterable[VisionObservation],
    *,
    maximum_time_delta_ms: float = 10.0,
) -> tuple[tuple[VisionObservation, VisionObservation], ...]:
    reference_items = tuple(reference)
    target_items = tuple(target)
    if not reference_items or not target_items:
        return ()
    if maximum_time_delta_ms <= 0:
        raise ValueError("maximum_time_delta_ms must be positive")
    if any(item.mapped_session_time_ns is None for item in reference_items):
        raise ValueError("reference observations require mapped session time")
    if any(item.mapped_session_time_ns is None for item in target_items):
        raise ValueError("target observations require mapped session time")

    max_delta_ns = round(maximum_time_delta_ms * 1e6)
    pairs: list[tuple[VisionObservation, VisionObservation]] = []
    target_index = 0

    for reference_item in reference_items:
        reference_time = int(reference_item.mapped_session_time_ns or 0)
        while (
            target_index + 1 < len(target_items)
            and abs(
                int(
                    target_items[target_index + 1].mapped_session_time_ns
                    or 0
                )
                - reference_time
            )
            <= abs(
                int(
                    target_items[target_index].mapped_session_time_ns
                    or 0
                )
                - reference_time
            )
        ):
            target_index += 1

        target_item = target_items[target_index]
        delta = abs(
            int(target_item.mapped_session_time_ns or 0)
            - reference_time
        )
        if delta <= max_delta_ns:
            pairs.append((reference_item, target_item))

    return tuple(pairs)


def _load_events(path: str | Path) -> tuple[SensorEvent, ...]:
    events: list[SensorEvent] = []
    for line_number, line in enumerate(
        Path(path).read_text(encoding="utf-8").splitlines(),
        start=1,
    ):
        if not line.strip():
            continue
        try:
            events.append(SensorEvent.from_json(line))
        except Exception as exc:
            raise ValueError(
                f"invalid sensor event at line {line_number}"
            ) from exc
    return tuple(events)

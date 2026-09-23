from __future__ import annotations

import argparse
import json

from .body_authoring import (
    build_body_model_from_spec,
    write_body_registration_report,
)
from .body_model import (
    load_body_model_profile,
    verify_body_model_source_artifact,
)
from .calibration import (
    build_calibration_bundle,
    calibration_gap_regions,
    replay_calibration_frames,
)
from .calibration_run import (
    build_calibration_run,
    write_calibration_report,
    write_replay_lab_payload,
)
from .camera import (
    import_camera_evidence,
    write_camera_capture_receipt,
)
from .clock_sync import write_clock_sync
from .closure import write_m0_closure_receipt
from .equipment_cli import calibrate_equipment_mount_file
from .insole import (
    import_opengo_text_export,
    write_p2_capture_receipt,
    write_p2_physical_receipt,
)
from .mcap_io import export_mcap
from .operator_evidence import write_operator_evidence_receipt
from .p0 import import_watch_journal, write_p0_receipt
from .p1 import (
    import_pod_journal,
    write_impulse_clock_observations,
    write_p1_receipt,
)
from .qc import session_qc
from .replay import replay_frames
from .session import SessionReader
from .simulate import simulate_session
from .validate import validate_m0_session


def _channel_keys(raw: str) -> tuple[str, ...]:
    keys = tuple(
        value.strip()
        for value in raw.split(",")
        if value.strip()
    )
    if not keys:
        raise argparse.ArgumentTypeError(
            "channel key list must contain at least one name"
        )
    return keys


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="motionos",
        description="MotionOS M0 capture toolkit",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    sim = sub.add_parser("simulate", help="write a deterministic multimodal demo session")
    sim.add_argument("--out", default="data")
    sim.add_argument("--sport", default="longboard")
    sim.add_argument("--mode", choices=("calibration", "field"), default="calibration")
    sim.add_argument("--duration", type=float, default=6.0)
    sim.add_argument("--seed", type=int, default=7)

    inspect = sub.add_parser("inspect", help="summarize a session bundle")
    inspect.add_argument("session")

    qc = sub.add_parser("qc", help="compute per-stream capture quality")
    qc.add_argument("session")

    validate = sub.add_parser("validate", help="apply M0 required-stream + QC gates")
    validate.add_argument("session")

    replay = sub.add_parser("replay", help="print compact synchronized replay frames")
    replay.add_argument("session")
    replay.add_argument("--hz", type=float, default=10.0)
    replay.add_argument("--frames", type=int, default=10)

    mcap = sub.add_parser("export-mcap", help="export a session bundle to MCAP")
    mcap.add_argument("session")
    mcap.add_argument("output")

    p0_import = sub.add_parser(
        "import-watch-journal",
        help="import a physical Apple Watch JSONL journal into a MotionOS bundle",
    )
    p0_import.add_argument("journal")
    p0_import.add_argument("--out", default="data")

    p0 = sub.add_parser(
        "validate-p0",
        help="write a single-Watch physical qualification receipt",
    )
    p0.add_argument("session")
    p0.add_argument("--min-duration", type=float, default=60.0)
    p0.add_argument("--receipt", default="p0-receipt.json")

    mount = sub.add_parser(
        "calibrate-equipment-mount",
        help="derive a sensor-to-equipment rotation from level/nose-up samples",
    )
    mount.add_argument("input")
    mount.add_argument("output")

    p1_import = sub.add_parser(
        "import-pod-journal",
        help="import recovered MetaMotionS flash evidence",
    )
    p1_import.add_argument("journal")
    p1_import.add_argument("--out", default="data")
    p1_import.add_argument("--profile")
    p1_import.add_argument("--sport", default="equipment-qualification")

    p1 = sub.add_parser(
        "validate-p1",
        help="write a MetaMotionS physical qualification receipt",
    )
    p1.add_argument("session")
    p1.add_argument("--min-duration", type=float, default=60.0)
    p1.add_argument("--receipt", default="p1-receipt.json")
    p1.add_argument("--capture-only", action="store_true")
    p1.add_argument("--rate-tolerance", type=float)
    p1.add_argument("--max-gap-multiple", type=float)
    p1.add_argument("--sync-observations")
    p1.add_argument("--max-sync-residual-ms", type=float)

    sync = sub.add_parser(
        "derive-p1-sync",
        help="pair deliberate impulse landmarks across Watch and pod clocks",
    )
    sync.add_argument("reference_session")
    sync.add_argument("pod_session")
    sync.add_argument("windows")
    sync.add_argument("output")
    sync.add_argument(
        "--reference-stream",
        default="/body/watch/imu",
    )
    sync.add_argument(
        "--pod-stream",
        default="/equipment/imu/accel",
    )

    generic_sync = sub.add_parser(
        "derive-clock-sync",
        help="derive an affine target→reference clock mapping from explicit landmarks",
    )
    generic_sync.add_argument("reference_session")
    generic_sync.add_argument("target_session")
    generic_sync.add_argument("windows")
    generic_sync.add_argument("output")
    generic_sync.add_argument("--reference-stream", required=True)
    generic_sync.add_argument("--target-stream", required=True)
    generic_sync.add_argument(
        "--reference-keys",
        type=_channel_keys,
        default=("ax", "ay", "az"),
        help="comma-separated payload keys used for reference peak magnitude",
    )
    generic_sync.add_argument(
        "--target-keys",
        type=_channel_keys,
        default=("ax", "ay", "az"),
        help="comma-separated payload keys used for target peak magnitude",
    )

    calibration = sub.add_parser(
        "build-calibration-bundle",
        help="build a hash-verified non-destructive calibration manifest",
    )
    calibration.add_argument("spec")
    calibration.add_argument("output")

    calibration_replay = sub.add_parser(
        "replay-calibration",
        help="replay clock-mapped calibration events without rewriting sources",
    )
    calibration_replay.add_argument("manifest")
    calibration_replay.add_argument("--hz", type=float, default=10.0)
    calibration_replay.add_argument("--frames", type=int, default=10)

    calibration_gaps = sub.add_parser(
        "calibration-gaps",
        help="report explicit timestamp gaps in a calibration bundle",
    )
    calibration_gaps.add_argument("manifest")

    run_build = sub.add_parser(
        "build-calibration-run",
        help="build a hash-verified first-class calibration run manifest",
    )
    run_build.add_argument("spec")
    run_build.add_argument("output")

    run_report = sub.add_parser(
        "report-calibration-run",
        help="write a deterministic evidence/timing/gap report for a run",
    )
    run_report.add_argument("run")
    run_report.add_argument("output")

    run_replay = sub.add_parser(
        "export-replay-lab",
        help="export a generated Replay Lab JSON payload from a calibration run",
    )
    run_replay.add_argument("run")
    run_replay.add_argument("output")
    run_replay.add_argument("--hz", type=float, default=10.0)

    closure = sub.add_parser(
        "validate-m0-closure",
        help=(
            "write a strict final M0 physical-integration closure receipt"
        ),
    )
    closure.add_argument("run")
    closure.add_argument(
        "--receipt",
        default="m0-closure-receipt.json",
    )

    body_build = sub.add_parser(
        "build-body-model",
        help="build a hash-bound personalized body model from measured landmarks",
    )
    body_build.add_argument("spec")
    body_build.add_argument("output")

    body_eval = sub.add_parser(
        "evaluate-body-registration",
        help="evaluate personalized body registration repeatability",
    )
    body_eval.add_argument("profile")
    body_eval.add_argument("camera_session")
    body_eval.add_argument("output")

    body_model = sub.add_parser(
        "validate-body-model",
        help="validate a personalized motionos.body-model.v2 profile",
    )
    body_model.add_argument("profile")
    body_model.add_argument("--source-artifact")

    camera_import = sub.add_parser(
        "import-camera-evidence",
        help="import an iPhone camera MOV/frame-journal evidence bundle",
    )
    camera_import.add_argument("input")
    camera_import.add_argument("--out", default="data")
    camera_import.add_argument("--athlete-id", default="local-athlete")
    camera_import.add_argument("--sport", default="camera-calibration")

    camera_validate = sub.add_parser(
        "validate-camera",
        help="write a camera/video/Vision capture receipt",
    )
    camera_validate.add_argument("session")
    camera_validate.add_argument("--min-duration", type=float, default=60.0)
    camera_validate.add_argument(
        "--receipt",
        default="camera-capture-receipt.json",
    )

    operator_validate = sub.add_parser(
        "validate-operator-evidence",
        help="validate a sealed first-ride operator journal bundle",
    )
    operator_validate.add_argument("directory")
    operator_validate.add_argument(
        "--receipt",
        default="operator-evidence-receipt.json",
    )

    p2_import = sub.add_parser(
        "import-opengo-export",
        help="import a bilateral Moticon OpenGo text export",
    )
    p2_import.add_argument("input")
    p2_import.add_argument("--out", default="data")
    p2_import.add_argument("--session-id")
    p2_import.add_argument("--athlete-id", default="local-athlete")
    p2_import.add_argument("--sport", default="insole-qualification")

    p2 = sub.add_parser(
        "validate-p2",
        help="write a bilateral insole exported-data capture receipt",
    )
    p2.add_argument("session")
    p2.add_argument("--min-duration", type=float, default=60.0)
    p2.add_argument("--receipt", default="p2-capture-receipt.json")

    p2_physical = sub.add_parser(
        "validate-p2-physical",
        help="write a full controlled + field P2 physical qualification receipt",
    )
    p2_physical.add_argument("field_session")
    p2_physical.add_argument("controlled_session")
    p2_physical.add_argument("spec")
    p2_physical.add_argument(
        "--min-controlled-duration",
        type=float,
        default=600.0,
    )
    p2_physical.add_argument(
        "--min-field-duration",
        type=float,
        default=1800.0,
    )
    p2_physical.add_argument(
        "--receipt",
        default="p2-physical-receipt.json",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    if args.command == "simulate":
        path = simulate_session(
            args.out,
            sport=args.sport,
            mode=args.mode,
            duration_s=args.duration,
            seed=args.seed,
        )
        print(path)
        return 0

    if args.command == "inspect":
        reader = SessionReader(args.session)
        print(
            json.dumps(
                {"manifest": reader.manifest.to_dict(), "streams": reader.index["streams"]},
                indent=2,
                sort_keys=True,
            )
        )
        return 0

    if args.command == "qc":
        print(json.dumps(session_qc(SessionReader(args.session)), indent=2, sort_keys=True))
        return 0

    if args.command == "validate":
        result = validate_m0_session(SessionReader(args.session))
        print(
            json.dumps(
                {
                    "passed": result.passed,
                    "missing_streams": result.missing_streams,
                    "qc_passed": result.qc_passed,
                },
                indent=2,
            )
        )
        return 0 if result.passed else 2

    if args.command == "replay":
        reader = SessionReader(args.session)
        for index, frame in enumerate(replay_frames(reader, frame_hz=args.hz)):
            if index >= args.frames:
                break
            print(
                json.dumps(
                    {"time_ns": frame.time_ns, "streams": sorted(frame.latest)},
                    sort_keys=True,
                )
            )
        return 0

    if args.command == "export-mcap":
        print(export_mcap(args.session, args.output))
        return 0

    if args.command == "import-watch-journal":
        print(import_watch_journal(args.journal, args.out))
        return 0

    if args.command == "validate-p0":
        receipt = write_p0_receipt(
            args.session,
            args.receipt,
            min_duration_s=args.min_duration,
        )
        print(json.dumps(receipt.to_dict(), indent=2, sort_keys=True))
        return 0 if receipt.passed else 2

    if args.command == "calibrate-equipment-mount":
        print(calibrate_equipment_mount_file(args.input, args.output))
        return 0

    if args.command == "import-pod-journal":
        print(
            import_pod_journal(
                args.journal,
                args.out,
                equipment_profile_path=args.profile,
                sport=args.sport,
            )
        )
        return 0

    if args.command == "derive-p1-sync":
        observations = write_impulse_clock_observations(
            args.reference_session,
            args.pod_session,
            args.windows,
            args.output,
            reference_stream=args.reference_stream,
            pod_stream=args.pod_stream,
        )
        print(
            json.dumps(
                [
                    {
                        "device_time_ns": item.device_time_ns,
                        "session_time_ns": item.session_time_ns,
                        "round_trip_ns": item.round_trip_ns,
                    }
                    for item in observations
                ],
                indent=2,
                sort_keys=True,
            )
        )
        return 0

    if args.command == "derive-clock-sync":
        receipt = write_clock_sync(
            args.reference_session,
            args.target_session,
            args.windows,
            args.output,
            reference_stream=args.reference_stream,
            target_stream=args.target_stream,
            reference_peak_keys=args.reference_keys,
            target_peak_keys=args.target_keys,
        )
        print(json.dumps(receipt.to_dict(), indent=2, sort_keys=True))
        return 0 if receipt.coverage.passed else 2

    if args.command == "build-calibration-bundle":
        bundle = build_calibration_bundle(args.spec, args.output)
        print(json.dumps(bundle.to_dict(), indent=2, sort_keys=True))
        return 0

    if args.command == "replay-calibration":
        for index, frame in enumerate(
            replay_calibration_frames(
                args.manifest,
                frame_hz=args.hz,
            )
        ):
            if index >= args.frames:
                break
            print(json.dumps(frame.to_dict(), sort_keys=True))
        return 0

    if args.command == "calibration-gaps":
        gaps = calibration_gap_regions(args.manifest)
        print(
            json.dumps(
                [gap.to_dict() for gap in gaps],
                indent=2,
                sort_keys=True,
            )
        )
        return 0

    if args.command == "build-calibration-run":
        run = build_calibration_run(args.spec, args.output)
        print(json.dumps(run.to_dict(), indent=2, sort_keys=True))
        return 0

    if args.command == "report-calibration-run":
        report = write_calibration_report(args.run, args.output)
        print(json.dumps(report, indent=2, sort_keys=True))
        return 0

    if args.command == "export-replay-lab":
        payload = write_replay_lab_payload(
            args.run,
            args.output,
            frame_hz=args.hz,
        )
        print(
            json.dumps(
                {
                    "schema_version": payload["schema_version"],
                    "run_id": payload["run"]["run_id"],
                    "frames": len(payload["frames"]),
                    "output": args.output,
                },
                indent=2,
                sort_keys=True,
            )
        )
        return 0

    if args.command == "validate-m0-closure":
        receipt = write_m0_closure_receipt(
            args.run,
            args.receipt,
        )
        print(json.dumps(receipt.to_dict(), indent=2, sort_keys=True))
        return 0 if receipt.passed else 2

    if args.command == "build-body-model":
        profile = build_body_model_from_spec(args.spec, args.output)
        print(json.dumps(profile.to_dict(), indent=2, sort_keys=True))
        return 0

    if args.command == "evaluate-body-registration":
        report = write_body_registration_report(
            args.profile,
            args.camera_session,
            args.output,
        )
        print(
            json.dumps(
                {
                    "schema_version": report["schema_version"],
                    "profile_id": report["profile"]["model_id"],
                    "camera_session_id": report["camera_session"]["session_id"],
                    "frame_accounting": report["frame_accounting"],
                    "output": args.output,
                },
                indent=2,
                sort_keys=True,
            )
        )
        return 0

    if args.command == "validate-body-model":
        profile = load_body_model_profile(args.profile)
        source_artifact_sha256 = None
        if args.source_artifact is not None:
            source_artifact_sha256 = verify_body_model_source_artifact(
                profile,
                args.source_artifact,
            )
        print(
            json.dumps(
                {
                    "schema_version": profile.schema_version,
                    "model_id": profile.model_id,
                    "profile_sha256": profile.profile_sha256,
                    "source_type": profile.source.type,
                    "source_artifact_sha256": source_artifact_sha256,
                    "frame_convention": profile.frame_convention,
                    "height_m": profile.height_m,
                    "landmark_count": len(profile.landmarks_m),
                    "segment_count": len(profile.segments_m),
                    "registration_landmarks": list(
                        profile.registration_landmarks
                    ),
                    "segments_m": dict(
                        sorted(profile.segments_m.items())
                    ),
                },
                indent=2,
                sort_keys=True,
            )
        )
        return 0

    if args.command == "import-camera-evidence":
        print(
            import_camera_evidence(
                args.input,
                args.out,
                athlete_id=args.athlete_id,
                sport=args.sport,
            )
        )
        return 0

    if args.command == "validate-camera":
        receipt = write_camera_capture_receipt(
            args.session,
            args.receipt,
            min_duration_s=args.min_duration,
        )
        print(json.dumps(receipt.to_dict(), indent=2, sort_keys=True))
        return 0 if receipt.passed else 2

    if args.command == "validate-operator-evidence":
        receipt = write_operator_evidence_receipt(
            args.directory,
            args.receipt,
        )
        print(json.dumps(receipt.to_dict(), indent=2, sort_keys=True))
        return 0 if receipt.passed else 2

    if args.command == "import-opengo-export":
        print(
            import_opengo_text_export(
                args.input,
                args.out,
                session_id=args.session_id,
                athlete_id=args.athlete_id,
                sport=args.sport,
            )
        )
        return 0

    if args.command == "validate-p2":
        receipt = write_p2_capture_receipt(
            args.session,
            args.receipt,
            min_duration_s=args.min_duration,
        )
        print(json.dumps(receipt.to_dict(), indent=2, sort_keys=True))
        return 0 if receipt.capture_passed else 2

    if args.command == "validate-p2-physical":
        receipt = write_p2_physical_receipt(
            args.field_session,
            args.controlled_session,
            args.spec,
            args.receipt,
            min_controlled_duration_s=args.min_controlled_duration,
            min_field_duration_s=args.min_field_duration,
        )
        print(json.dumps(receipt.to_dict(), indent=2, sort_keys=True))
        return 0 if receipt.passed else 2

    if args.command == "validate-p1":
        if not args.capture_only:
            required = {
                "--rate-tolerance": args.rate_tolerance,
                "--max-gap-multiple": args.max_gap_multiple,
                "--sync-observations": args.sync_observations,
                "--max-sync-residual-ms": args.max_sync_residual_ms,
            }
            missing = [name for name, value in required.items() if value is None]
            if missing:
                parser = _parser()
                parser.error(
                    "full P1 qualification requires " + ", ".join(missing)
                )

        receipt = write_p1_receipt(
            args.session,
            args.receipt,
            min_duration_s=args.min_duration,
            rate_tolerance_fraction=args.rate_tolerance,
            max_gap_multiple=args.max_gap_multiple,
            sync_observations_path=args.sync_observations,
            max_sync_residual_ms=args.max_sync_residual_ms,
        )
        print(json.dumps(receipt.to_dict(), indent=2, sort_keys=True))
        if args.capture_only:
            return 0 if receipt.capture_passed else 2
        return 0 if receipt.passed else 2

    raise AssertionError("unreachable")


if __name__ == "__main__":
    raise SystemExit(main())

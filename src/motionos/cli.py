from __future__ import annotations

import argparse
import json

from .equipment_cli import calibrate_equipment_mount_file
from .insole import import_opengo_text_export, write_p2_capture_receipt
from .mcap_io import export_mcap
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

from __future__ import annotations

import argparse
import json

from .equipment_cli import calibrate_equipment_mount_file
from .mcap_io import export_mcap
from .p0 import import_watch_journal, write_p0_receipt
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

    raise AssertionError("unreachable")


if __name__ == "__main__":
    raise SystemExit(main())

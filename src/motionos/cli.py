from __future__ import annotations

import argparse
import json

from .annotation_contract import (
    build_annotation_manifest,
    validate_annotation_manifest,
    validate_teacher_labels,
)
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
from .clock_uncertainty import (
    analyze_clock_uncertainty,
    query_clock_uncertainty,
)
from .closure import write_m0_closure_receipt
from .cross_modal_residuals import build_cross_modal_residual_report
from .data_governance import (
    validate_external_dataset_registry,
    validate_public_export_manifest,
)
from .equipment_cli import calibrate_equipment_mount_file
from .experiments import (
    build_experiment_manifest,
    build_grouped_split,
    verify_experiment_manifest,
    verify_grouped_split,
)
from .indo_annotations import (
    build_annotation_queue,
    export_equipment_observations,
)
from .indo_board_state import (
    analyze_board_observations,
    load_board_observations,
)
from .indo_equipment_eval import (
    evaluate_equipment_predictions,
)
from .indo_fiducial_teacher import (
    extract_fiducial_teacher_labels,
)
from .indo_knowledge import (
    build_session_learning_targets,
    classify_observable_skills,
    cold_start_plan,
    generate_coaching_suggestions,
    load_indo_skill_taxonomy,
)
from .indo_markerless_dataset import (
    build_markerless_dataset_index,
    verify_markerless_dataset_index,
)
from .indo_model_qualification import (
    build_equipment_model_qualification_registry,
)
from .indo_pose_metrics import analyze_indo_camera_session
from .indo_public_corpus import (
    build_indo_video_knowledge_base,
    discover_indo_youtube,
    enrich_public_video_urls_with_ytdlp,
    merge_public_video_specs,
)
from .indo_runtime_equipment_eval import (
    evaluate_runtime_equipment_predictions,
)
from .indo_session_report import (
    build_indo_session_report,
    load_json_object,
    write_indo_session_report,
)
from .indo_shadow_eval import (
    summarize_shadow_equipment_evaluation,
)
from .indo_shadow_gate import (
    assess_markerless_shadow_gate,
)
from .insole import (
    import_opengo_text_export,
    write_p2_capture_receipt,
    write_p2_physical_receipt,
)
from .mcap_io import export_mcap
from .observability import load_observability_registry
from .operator_evidence import write_operator_evidence_receipt
from .p0 import import_watch_journal, write_p0_receipt
from .p1 import (
    import_pod_journal,
    write_impulse_clock_observations,
    write_p1_receipt,
)
from .public_data import index_totalcapture
from .public_video import build_public_video_catalog
from .qc import session_qc
from .replay import replay_frames
from .session import SessionReader
from .simulate import simulate_session
from .validate import validate_m0_session
from .video_alignment import write_video_alignment
from .world_geometry import (
    build_camera_rig_receipt,
    triangulate_multiview,
    write_camera_calibration_receipt,
)


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

    video_alignment = sub.add_parser(
        "build-video-alignment",
        help=(
            "fit a hash-bound external-video PTS to MotionOS reference-time "
            "mapping from explicit sync anchors"
        ),
    )
    video_alignment.add_argument("spec")
    video_alignment.add_argument("output")

    annotation_manifest = sub.add_parser(
        "build-annotation-manifest",
        help=(
            "bind synchronized video, derived evidence, renderer versions, "
            "and observed/derived/inferred replay layers"
        ),
    )
    annotation_manifest.add_argument("spec")
    annotation_manifest.add_argument("output")

    annotation_validate = sub.add_parser(
        "validate-annotation-manifest",
        help="revalidate all hashes and layer semantics in an annotation manifest",
    )
    annotation_validate.add_argument("manifest")

    labels_validate = sub.add_parser(
        "validate-teacher-labels",
        help=(
            "validate time-indexed teacher labels against an annotation "
            "manifest and its exact video time map"
        ),
    )
    labels_validate.add_argument("labels")
    labels_validate.add_argument("manifest")

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

    observability = sub.add_parser(
        "validate-observability",
        help="validate and summarize an M1 observability registry",
    )
    observability.add_argument("registry")

    experiment = sub.add_parser(
        "build-experiment-manifest",
        help="build a provenance-bound M1 experiment manifest",
    )
    experiment.add_argument("spec")
    experiment.add_argument("output")

    experiment_verify = sub.add_parser(
        "verify-experiment-manifest",
        help="recompute hashes and target eligibility for an M1 experiment",
    )
    experiment_verify.add_argument("manifest")

    grouped_split = sub.add_parser(
        "build-grouped-split",
        help="build a deterministic leakage-safe grouped dataset split",
    )
    grouped_split.add_argument("index")
    grouped_split.add_argument("output")
    grouped_split.add_argument(
        "--group-by",
        type=_channel_keys,
        required=True,
        help="comma-separated acquisition fields defining an indivisible group",
    )
    grouped_split.add_argument("--seed", required=True)
    grouped_split.add_argument("--train-fraction", type=float, default=0.7)
    grouped_split.add_argument(
        "--validation-fraction",
        type=float,
        default=0.15,
    )
    grouped_split.add_argument(
        "--purpose",
        choices=("primary", "development"),
        default="primary",
    )

    split_verify = sub.add_parser(
        "verify-grouped-split",
        help="verify a grouped split against its exact sample index",
    )
    split_verify.add_argument("split")
    split_verify.add_argument("index")

    totalcapture = sub.add_parser(
        "index-totalcapture",
        help="index an authorized local TotalCapture extraction without copying it",
    )
    totalcapture.add_argument("root")
    totalcapture.add_argument("output")

    public_video = sub.add_parser(
        "build-public-video-catalog",
        help="build a rights-aware catalog of public movement-video references",
    )
    public_video.add_argument("spec")
    public_video.add_argument("output")

    indo_discover = sub.add_parser(
        "discover-indo-youtube",
        help="discover Indo Board videos through the official YouTube Data API",
    )
    indo_discover.add_argument("queries")
    indo_discover.add_argument("output")

    indo_enrich = sub.add_parser(
        "enrich-indo-video-urls",
        help="extract metadata only for an explicit list of public video URLs",
    )
    indo_enrich.add_argument("urls")
    indo_enrich.add_argument("output")

    indo_merge = sub.add_parser(
        "merge-indo-video-specs",
        help="merge and deduplicate Indo Board public-video discovery specs",
    )
    indo_merge.add_argument("inputs", nargs="+")
    indo_merge.add_argument("output")

    indo_kb = sub.add_parser(
        "build-indo-video-kb",
        help="build a weak-label retrieval index from an Indo video catalog",
    )
    indo_kb.add_argument("catalog")
    indo_kb.add_argument("output")

    indo_observability = sub.add_parser(
        "indo-skill-observability",
        help="classify which INDO BOARD skills are measurable with available channels",
    )
    indo_observability.add_argument("taxonomy")
    indo_observability.add_argument(
        "--channels",
        type=_channel_keys,
        required=True,
        help="comma-separated observation channels available to the session",
    )

    indo_cold_start = sub.add_parser(
        "indo-cold-start-plan",
        help="emit the first-session INDO BOARD protocol supported by available channels",
    )
    indo_cold_start.add_argument("taxonomy")
    indo_cold_start.add_argument(
        "--channels",
        type=_channel_keys,
        required=True,
    )

    indo_coach = sub.add_parser(
        "indo-coach",
        help="apply conservative INDO BOARD coaching rules to session metrics",
    )
    indo_coach.add_argument("taxonomy")
    indo_coach.add_argument("metrics")
    indo_coach.add_argument("--max-suggestions", type=int, default=2)

    indo_body_metrics = sub.add_parser(
        "indo-body-metrics",
        help="derive body-only INDO BOARD posture metrics from camera pose evidence",
    )
    indo_body_metrics.add_argument("session")

    indo_board_state = sub.add_parser(
        "indo-board-state",
        help="derive deck/roller balance state and recovery metrics",
    )
    indo_board_state.add_argument("observations")

    indo_annotation_queue = sub.add_parser(
        "indo-annotation-queue",
        help="build creator-grouped INDO BOARD deck/roller annotation tasks",
    )
    indo_annotation_queue.add_argument("catalog")
    indo_annotation_queue.add_argument("taxonomy")
    indo_annotation_queue.add_argument("output")
    indo_annotation_queue.add_argument("--max-sources", type=int)

    indo_equipment_export = sub.add_parser(
        "indo-export-equipment-labels",
        help="export human-reviewed deck/roller labels into the runtime equipment contract",
    )
    indo_equipment_export.add_argument("annotations")
    indo_equipment_export.add_argument("output")
    indo_equipment_export.add_argument(
        "--allow-model-proposals",
        action="store_true",
        help="include model-proposed labels instead of requiring human review",
    )

    indo_equipment_eval = sub.add_parser(
        "indo-evaluate-equipment-model",
        help="evaluate deck/roller predictions against human-reviewed labels",
    )
    indo_equipment_eval.add_argument("reference")
    indo_equipment_eval.add_argument("predictions")
    indo_equipment_eval.add_argument("output")

    indo_fiducial_teacher = sub.add_parser(
        "indo-extract-fiducial-teacher-labels",
        help="extract QR-derived deck/roller teacher labels from a camera JSONL journal",
    )
    indo_fiducial_teacher.add_argument("camera_journal")
    indo_fiducial_teacher.add_argument("output")

    indo_runtime_eval = sub.add_parser(
        "indo-evaluate-runtime-equipment-model",
        help="evaluate markerless runtime geometry against QR or reviewed runtime references",
    )
    indo_runtime_eval.add_argument("reference")
    indo_runtime_eval.add_argument("predictions")
    indo_runtime_eval.add_argument("output")

    indo_shadow_eval = sub.add_parser(
        "indo-summarize-shadow-equipment-eval",
        help="aggregate on-device QR-versus-markerless shadow comparisons from a camera journal",
    )
    indo_shadow_eval.add_argument("camera_journal")
    indo_shadow_eval.add_argument("output")

    indo_shadow_gate = sub.add_parser(
        "indo-assess-markerless-shadow-gate",
        help="evaluate explicit markerless engineering thresholds without authorizing runtime use",
    )
    indo_shadow_gate.add_argument("shadow_evaluation")
    indo_shadow_gate.add_argument("spec")
    indo_shadow_gate.add_argument("output")

    indo_markerless_index = sub.add_parser(
        "indo-build-markerless-dataset-index",
        help="build a hash-bound frame index for QR/human teacher labels and source videos",
    )
    indo_markerless_index.add_argument("spec")
    indo_markerless_index.add_argument("output")

    indo_markerless_verify = sub.add_parser(
        "indo-verify-markerless-dataset-index",
        help="recheck markerless dataset source hashes, sample identities, and acquisition groups",
    )
    indo_markerless_verify.add_argument("index")

    indo_model_qualification = sub.add_parser(
        "indo-build-equipment-model-qualification",
        help="build an explicit runtime authorization registry from an equipment evaluation report",
    )
    indo_model_qualification.add_argument("evaluation")
    indo_model_qualification.add_argument("output")
    indo_model_qualification.add_argument(
        "--model-id",
        required=True,
    )
    indo_model_qualification.add_argument(
        "--status",
        choices=(
            "unqualified",
            "evaluation_only",
            "qualified_for_beta_tracking",
            "qualified_for_beta_coaching",
        ),
        default="evaluation_only",
    )
    indo_model_qualification.add_argument(
        "--evaluation-dataset-id",
    )
    indo_model_qualification.add_argument(
        "--authorization-note",
    )

    indo_report = sub.add_parser(
        "indo-session-report",
        help="merge body/board evidence into a conservative INDO BOARD coaching report",
    )
    indo_report.add_argument("session_id")
    indo_report.add_argument("taxonomy")
    indo_report.add_argument("output")
    indo_report.add_argument("--body-metrics")
    indo_report.add_argument("--board-observations")
    indo_report.add_argument("--profile")

    indo_next = sub.add_parser(
        "indo-next-skills",
        help="choose measurable next INDO BOARD skills from completed prerequisites",
    )
    indo_next.add_argument("taxonomy")
    indo_next.add_argument(
        "--completed",
        type=_channel_keys,
        default=(),
        help="comma-separated completed skill ids",
    )
    indo_next.add_argument(
        "--channels",
        type=_channel_keys,
        required=True,
    )
    indo_next.add_argument("--limit", type=int, default=4)

    public_export = sub.add_parser(
        "validate-public-export",
        help="validate a conservative public-release manifest and artifact hashes",
    )
    public_export.add_argument("manifest")

    dataset_registry = sub.add_parser(
        "validate-dataset-registry",
        help="validate external-dataset authorization and redistribution metadata",
    )
    dataset_registry.add_argument("registry")

    clock_uncertainty = sub.add_parser(
        "analyze-clock-uncertainty",
        help="derive weighted timing uncertainty from a validated clock-sync v1 receipt",
    )
    clock_uncertainty.add_argument("reference_session")
    clock_uncertainty.add_argument("target_session")
    clock_uncertainty.add_argument("clock_sync")
    clock_uncertainty.add_argument("output")
    clock_uncertainty.add_argument(
        "--default-uncertainty-ms",
        type=float,
        help=(
            "explicit fallback for v1 landmarks whose uncertainty_ns is zero; "
            "omitting it fails closed"
        ),
    )

    clock_query = sub.add_parser(
        "query-clock-uncertainty",
        help="map one target device timestamp with M1 timing uncertainty",
    )
    clock_query.add_argument("analysis")
    clock_query.add_argument("device_time_ns", type=int)

    residuals = sub.add_parser(
        "build-cross-modal-residual-report",
        help=(
            "build deterministic IMU/video, pressure/video, and geometry "
            "residual evidence"
        ),
    )
    residuals.add_argument("spec")
    residuals.add_argument("output")

    camera_calibration = sub.add_parser(
        "validate-camera-calibration",
        help="validate a metric camera calibration and write its receipt",
    )
    camera_calibration.add_argument("calibration")
    camera_calibration.add_argument(
        "--receipt",
        default="camera-calibration-receipt.json",
    )

    camera_rig = sub.add_parser(
        "build-camera-rig",
        help="qualify a fixed multi-camera metric world-frame rig",
    )
    camera_rig.add_argument("spec")
    camera_rig.add_argument("output")

    triangulate = sub.add_parser(
        "triangulate-multiview",
        help="triangulate frozen multi-camera correspondences in world coordinates",
    )
    triangulate.add_argument("rig")
    triangulate.add_argument("correspondences")
    triangulate.add_argument("output")
    triangulate.add_argument("--measurements-output")
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

    if args.command == "build-video-alignment":
        receipt = write_video_alignment(args.spec, args.output)
        print(json.dumps(receipt.to_dict(), indent=2, sort_keys=True))
        return 0 if receipt.coverage.passed else 2

    if args.command == "build-annotation-manifest":
        manifest = build_annotation_manifest(args.spec, args.output)
        print(json.dumps(manifest, indent=2, sort_keys=True))
        return 0

    if args.command == "validate-annotation-manifest":
        manifest = validate_annotation_manifest(args.manifest)
        print(json.dumps(manifest, indent=2, sort_keys=True))
        return 0

    if args.command == "validate-teacher-labels":
        result = validate_teacher_labels(args.labels, args.manifest)
        print(json.dumps(result.to_dict(), indent=2, sort_keys=True))
        return 0 if result.passed else 2

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

    if args.command == "validate-observability":
        registry = load_observability_registry(args.registry)
        counts = {
            state: sum(
                item.observability == state
                for item in registry.variables
            )
            for state in ("observable", "conditional", "unidentifiable")
        }
        print(
            json.dumps(
                {
                    "schema_version": registry.schema_version,
                    "registry_id": registry.registry_id,
                    "sport": registry.sport,
                    "variable_count": len(registry.variables),
                    "teacher_eligible_count": sum(
                        item.teacher_eligible
                        for item in registry.variables
                    ),
                    "observability_counts": counts,
                },
                indent=2,
                sort_keys=True,
            )
        )
        return 0

    if args.command == "build-experiment-manifest":
        manifest = build_experiment_manifest(args.spec, args.output)
        print(json.dumps(manifest.to_dict(), indent=2, sort_keys=True))
        return 0

    if args.command == "verify-experiment-manifest":
        result = verify_experiment_manifest(args.manifest)
        print(json.dumps(result, indent=2, sort_keys=True))
        return 0

    if args.command == "build-grouped-split":
        split = build_grouped_split(
            args.index,
            args.output,
            group_by=args.group_by,
            seed=args.seed,
            train_fraction=args.train_fraction,
            validation_fraction=args.validation_fraction,
            purpose=args.purpose,
        )
        print(json.dumps(split.to_dict(), indent=2, sort_keys=True))
        return 0 if split.leakage_check_passed else 2

    if args.command == "verify-grouped-split":
        result = verify_grouped_split(args.split, args.index)
        print(json.dumps(result, indent=2, sort_keys=True))
        return 0

    if args.command == "index-totalcapture":
        payload = index_totalcapture(args.root, args.output)
        print(
            json.dumps(
                {
                    "schema_version": payload["schema_version"],
                    "dataset": payload["dataset"],
                    "sample_count": len(payload["samples"]),
                    "output": args.output,
                },
                indent=2,
                sort_keys=True,
            )
        )
        return 0

    if args.command == "build-public-video-catalog":
        payload = build_public_video_catalog(args.spec, args.output)
        print(
            json.dumps(
                {
                    "schema_version": payload["schema_version"],
                    "record_count": len(payload["records"]),
                    "output": args.output,
                },
                indent=2,
                sort_keys=True,
            )
        )
        return 0

    if args.command == "discover-indo-youtube":
        payload = discover_indo_youtube(args.queries, args.output)
        print(
            json.dumps(
                {
                    "schema_version": payload["schema_version"],
                    "unique_video_count": len(payload["records"]),
                    "output": args.output,
                },
                indent=2,
                sort_keys=True,
            )
        )
        return 0

    if args.command == "enrich-indo-video-urls":
        payload = enrich_public_video_urls_with_ytdlp(
            args.urls,
            args.output,
        )
        print(
            json.dumps(
                {
                    "schema_version": payload["schema_version"],
                    "record_count": len(payload["records"]),
                    "failure_count": len(payload["failures"]),
                    "output": args.output,
                },
                indent=2,
                sort_keys=True,
            )
        )
        return 0

    if args.command == "merge-indo-video-specs":
        payload = merge_public_video_specs(args.inputs, args.output)
        print(
            json.dumps(
                {
                    "schema_version": payload["schema_version"],
                    "record_count": len(payload["records"]),
                    "output": args.output,
                },
                indent=2,
                sort_keys=True,
            )
        )
        return 0

    if args.command == "build-indo-video-kb":
        payload = build_indo_video_knowledge_base(
            args.catalog,
            args.output,
        )
        print(
            json.dumps(
                {
                    "schema_version": payload["schema_version"],
                    "source_count": payload["source_count"],
                    "topic_count": len(payload["topics"]),
                    "output": args.output,
                },
                indent=2,
                sort_keys=True,
            )
        )
        return 0

    if args.command == "indo-skill-observability":
        taxonomy = load_indo_skill_taxonomy(args.taxonomy)
        result = classify_observable_skills(
            taxonomy,
            set(args.channels),
        )
        print(json.dumps(result, indent=2, sort_keys=True))
        return 0

    if args.command == "indo-cold-start-plan":
        taxonomy = load_indo_skill_taxonomy(args.taxonomy)
        result = cold_start_plan(
            taxonomy,
            available_channels=set(args.channels),
        )
        print(json.dumps(result, indent=2, sort_keys=True))
        return 0

    if args.command == "indo-coach":
        taxonomy = load_indo_skill_taxonomy(args.taxonomy)
        with open(args.metrics, encoding="utf-8") as handle:
            payload = json.load(handle)
        if not isinstance(payload, dict):
            raise TypeError("metrics input must be a JSON object")
        metrics = payload.get("metrics", payload)
        confidences = payload.get("confidence", {})
        if not isinstance(metrics, dict):
            raise TypeError("metrics must be a JSON object")
        if not isinstance(confidences, dict):
            raise TypeError("confidence must be a JSON object")
        result = generate_coaching_suggestions(
            taxonomy,
            metrics,
            metric_confidence=confidences,
            max_suggestions=args.max_suggestions,
        )
        print(
            json.dumps(
                [item.to_dict() for item in result],
                indent=2,
                sort_keys=True,
            )
        )
        return 0

    if args.command == "indo-body-metrics":
        result = analyze_indo_camera_session(args.session)
        print(json.dumps(result, indent=2, sort_keys=True))
        return 0

    if args.command == "indo-board-state":
        payload = load_board_observations(args.observations)
        result = analyze_board_observations(payload)
        print(json.dumps(result, indent=2, sort_keys=True))
        return 0

    if args.command == "indo-annotation-queue":
        payload = build_annotation_queue(
            args.catalog,
            args.taxonomy,
            args.output,
            max_sources=args.max_sources,
        )
        print(
            json.dumps(
                {
                    "schema_version": payload["schema_version"],
                    "task_count": payload["task_count"],
                    "split_counts": payload["split_counts"],
                    "output": args.output,
                },
                indent=2,
                sort_keys=True,
            )
        )
        return 0

    if args.command == "indo-export-equipment-labels":
        payload = export_equipment_observations(
            args.annotations,
            args.output,
            require_human_review=not args.allow_model_proposals,
        )
        print(
            json.dumps(
                {
                    "schema_version": payload["schema_version"],
                    "observation_count":
                        payload["observation_count"],
                    "skipped_unreviewed_count":
                        payload["skipped_unreviewed_count"],
                    "output": args.output,
                },
                indent=2,
                sort_keys=True,
            )
        )
        return 0

    if args.command == "indo-evaluate-equipment-model":
        payload = evaluate_equipment_predictions(
            args.reference,
            args.predictions,
            args.output,
        )
        print(
            json.dumps(
                {
                    "schema_version": payload["schema_version"],
                    "reference_count": payload["reference_count"],
                    "matched_count": payload["matched_count"],
                    "reference_coverage_fraction":
                        payload["reference_coverage_fraction"],
                    "metrics": payload["metrics"],
                    "output": args.output,
                },
                indent=2,
                sort_keys=True,
            )
        )
        return 0

    if args.command == "indo-extract-fiducial-teacher-labels":
        payload = extract_fiducial_teacher_labels(
            args.camera_journal,
            args.output,
        )
        print(
            json.dumps(
                {
                    "schema_version": payload["schema_version"],
                    "pose_event_count": payload["pose_event_count"],
                    "observation_count": payload["observation_count"],
                    "skipped_non_fiducial_count":
                        payload["skipped_non_fiducial_count"],
                    "output": args.output,
                },
                indent=2,
                sort_keys=True,
            )
        )
        return 0

    if args.command == "indo-evaluate-runtime-equipment-model":
        payload = evaluate_runtime_equipment_predictions(
            args.reference,
            args.predictions,
            args.output,
        )
        print(
            json.dumps(
                {
                    "schema_version": payload["schema_version"],
                    "reference_count": payload["reference_count"],
                    "prediction_count": payload["prediction_count"],
                    "matched_count": payload["matched_count"],
                    "reference_coverage_fraction":
                        payload["reference_coverage_fraction"],
                    "metrics": payload["metrics"],
                    "output": args.output,
                },
                indent=2,
                sort_keys=True,
            )
        )
        return 0

    if args.command == "indo-summarize-shadow-equipment-eval":
        payload = summarize_shadow_equipment_evaluation(
            args.camera_journal,
            args.output,
        )
        print(
            json.dumps(
                {
                    "schema_version": payload["schema_version"],
                    "pose_event_count": payload["pose_event_count"],
                    "routing_event_count": payload["routing_event_count"],
                    "comparison_count": payload["comparison_count"],
                    "groups": payload["groups"],
                    "detector_execution_groups":
                        payload["detector_execution_groups"],
                    "output": args.output,
                },
                indent=2,
                sort_keys=True,
            )
        )
        return 0

    if args.command == "indo-assess-markerless-shadow-gate":
        payload = assess_markerless_shadow_gate(
            args.shadow_evaluation,
            args.spec,
            args.output,
        )
        print(
            json.dumps(
                {
                    "schema_version": payload["schema_version"],
                    "model_id": payload["model_id"],
                    "candidate_detector_id":
                        payload["candidate_detector_id"],
                    "passed": payload["passed"],
                    "authorization_effect":
                        payload["authorization_effect"],
                    "criteria": payload["criteria"],
                    "output": args.output,
                },
                indent=2,
                sort_keys=True,
            )
        )
        return 0

    if args.command == "indo-build-markerless-dataset-index":
        payload = build_markerless_dataset_index(
            args.spec,
            args.output,
        )
        print(
            json.dumps(
                {
                    "schema_version": payload["schema_version"],
                    "sample_count": payload["sample_count"],
                    "source_count": payload["source_count"],
                    "output": args.output,
                },
                indent=2,
                sort_keys=True,
            )
        )
        return 0

    if args.command == "indo-verify-markerless-dataset-index":
        payload = verify_markerless_dataset_index(
            args.index,
        )
        print(
            json.dumps(
                payload,
                indent=2,
                sort_keys=True,
            )
        )
        return 0

    if args.command == "indo-build-equipment-model-qualification":
        payload = build_equipment_model_qualification_registry(
            args.evaluation,
            args.output,
            model_id=args.model_id,
            status=args.status,
            evaluation_dataset_id=args.evaluation_dataset_id,
            authorization_note=args.authorization_note,
        )
        qualification = payload["qualifications"][0]
        print(
            json.dumps(
                {
                    "schema_version": payload["schema_version"],
                    "model_id": qualification["model_id"],
                    "status": qualification["status"],
                    "evaluation_dataset_id":
                        qualification["evaluation_dataset_id"],
                    "evaluation_report_sha256":
                        qualification["evaluation_report_sha256"],
                    "output": args.output,
                },
                indent=2,
                sort_keys=True,
            )
        )
        return 0

    if args.command == "indo-session-report":
        body = (
            load_json_object(args.body_metrics)
            if args.body_metrics
            else None
        )
        board = (
            load_json_object(args.board_observations)
            if args.board_observations
            else None
        )
        profile = (
            load_json_object(args.profile)
            if args.profile
            else None
        )
        report = build_indo_session_report(
            session_id=args.session_id,
            taxonomy_path=args.taxonomy,
            body_metrics=body,
            board_observations=board,
            profile=profile,
        )
        write_indo_session_report(args.output, report)
        print(
            json.dumps(
                {
                    "schema_version": report["schema_version"],
                    "session_id": report["session_id"],
                    "primary_rule": report[
                        "primary_coaching"
                    ]["rule_id"],
                    "output": args.output,
                },
                indent=2,
                sort_keys=True,
            )
        )
        return 0

    if args.command == "indo-next-skills":
        taxonomy = load_indo_skill_taxonomy(args.taxonomy)
        result = build_session_learning_targets(
            taxonomy,
            completed_skill_ids=set(args.completed),
            available_channels=set(args.channels),
            limit=args.limit,
        )
        print(json.dumps(result, indent=2, sort_keys=True))
        return 0

    if args.command == "validate-public-export":
        result = validate_public_export_manifest(args.manifest)
        print(json.dumps(result, indent=2, sort_keys=True))
        return 0

    if args.command == "validate-dataset-registry":
        result = validate_external_dataset_registry(args.registry)
        print(json.dumps(result, indent=2, sort_keys=True))
        return 0

    if args.command == "analyze-clock-uncertainty":
        default_ns = (
            args.default_uncertainty_ms * 1e6
            if args.default_uncertainty_ms is not None
            else None
        )
        result = analyze_clock_uncertainty(
            args.reference_session,
            args.target_session,
            args.clock_sync,
            args.output,
            default_uncertainty_ns=default_ns,
        )
        print(json.dumps(result, indent=2, sort_keys=True))
        return 0

    if args.command == "query-clock-uncertainty":
        result = query_clock_uncertainty(
            args.analysis,
            args.device_time_ns,
        )
        print(json.dumps(result, indent=2, sort_keys=True))
        return 0

    if args.command == "build-cross-modal-residual-report":
        result = build_cross_modal_residual_report(
            args.spec,
            args.output,
        )
        print(json.dumps(result, indent=2, sort_keys=True))
        return 0

    if args.command == "validate-camera-calibration":
        result = write_camera_calibration_receipt(
            args.calibration,
            args.receipt,
        )
        print(json.dumps(result, indent=2, sort_keys=True))
        return 0

    if args.command == "build-camera-rig":
        result = build_camera_rig_receipt(
            args.spec,
            args.output,
        )
        print(json.dumps(result, indent=2, sort_keys=True))
        return 0 if result["passed"] else 2

    if args.command == "triangulate-multiview":
        result = triangulate_multiview(
            args.rig,
            args.correspondences,
            args.output,
            measurements_output_path=args.measurements_output,
        )
        print(json.dumps(result, indent=2, sort_keys=True))
        return 0

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

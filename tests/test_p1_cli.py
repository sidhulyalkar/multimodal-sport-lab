from types import SimpleNamespace

import pytest

from motionos import cli


def test_validate_p1_capture_only_does_not_require_sync_gates(
    monkeypatch,
    tmp_path,
    capsys,
):
    receipt = SimpleNamespace(
        capture_passed=True,
        passed=False,
        to_dict=lambda: {
            "capture_passed": True,
            "passed": False,
        },
    )
    calls = []

    def fake_write(*args, **kwargs):
        calls.append((args, kwargs))
        return receipt

    monkeypatch.setattr(cli, "write_p1_receipt", fake_write)

    rc = cli.main(
        [
            "validate-p1",
            str(tmp_path / "session"),
            "--capture-only",
            "--min-duration",
            "600",
            "--receipt",
            str(tmp_path / "capture.json"),
        ]
    )

    assert rc == 0
    assert len(calls) == 1
    assert calls[0][1]["min_duration_s"] == 600.0
    assert calls[0][1]["rate_tolerance_fraction"] is None
    assert calls[0][1]["max_gap_multiple"] is None
    assert calls[0][1]["sync_observations_path"] is None
    assert calls[0][1]["max_sync_residual_ms"] is None

    output = capsys.readouterr().out
    assert '"capture_passed": true' in output
    assert '"passed": false' in output


def test_validate_p1_full_gate_rejects_missing_thresholds(tmp_path):
    with pytest.raises(SystemExit) as exc_info:
        cli.main(
            [
                "validate-p1",
                str(tmp_path / "session"),
                "--rate-tolerance",
                "0.05",
            ]
        )

    assert exc_info.value.code == 2


def test_validate_p1_full_gate_passes_all_frozen_arguments(
    monkeypatch,
    tmp_path,
):
    receipt = SimpleNamespace(
        capture_passed=True,
        passed=True,
        to_dict=lambda: {
            "capture_passed": True,
            "passed": True,
        },
    )
    calls = []

    def fake_write(*args, **kwargs):
        calls.append((args, kwargs))
        return receipt

    monkeypatch.setattr(cli, "write_p1_receipt", fake_write)

    sync = tmp_path / "sync.json"
    sync.write_text("[]\n", encoding="utf-8")

    rc = cli.main(
        [
            "validate-p1",
            str(tmp_path / "session"),
            "--min-duration",
            "600",
            "--rate-tolerance",
            "0.05",
            "--max-gap-multiple",
            "2.0",
            "--sync-observations",
            str(sync),
            "--max-sync-residual-ms",
            "20",
            "--receipt",
            str(tmp_path / "receipt.json"),
        ]
    )

    assert rc == 0
    assert len(calls) == 1
    kwargs = calls[0][1]
    assert kwargs["min_duration_s"] == 600.0
    assert kwargs["rate_tolerance_fraction"] == 0.05
    assert kwargs["max_gap_multiple"] == 2.0
    assert kwargs["sync_observations_path"] == str(sync)
    assert kwargs["max_sync_residual_ms"] == 20.0


def test_validate_p1_full_gate_returns_failure_for_failed_receipt(
    monkeypatch,
    tmp_path,
):
    receipt = SimpleNamespace(
        capture_passed=True,
        passed=False,
        to_dict=lambda: {
            "capture_passed": True,
            "passed": False,
        },
    )
    monkeypatch.setattr(
        cli,
        "write_p1_receipt",
        lambda *args, **kwargs: receipt,
    )

    rc = cli.main(
        [
            "validate-p1",
            str(tmp_path / "session"),
            "--rate-tolerance",
            "0.05",
            "--max-gap-multiple",
            "2.0",
            "--sync-observations",
            str(tmp_path / "sync.json"),
            "--max-sync-residual-ms",
            "20",
        ]
    )

    assert rc == 2

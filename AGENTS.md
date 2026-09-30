# MotionOS Agent Contract

This repository may be edited by multiple human- or model-driven coding agents. The goal is parallelism without sacrificing scientific traceability, hardware safety, or reproducibility.

## Ground rules

- Treat repository contracts, tests, receipts, and raw evidence as authoritative. Never turn a simulation or compile success into a claim of physical qualification.
- Keep raw sensor evidence immutable. Derived artifacts may be regenerated; raw journals, hashes, provenance, and qualification receipts must remain auditable.
- Prefer the smallest change that closes a stated requirement. Do not casually broaden platform targets, data schemas, timing semantics, or sensor assumptions.
- Never weaken tests, thresholds, provenance checks, or validation gates merely to make CI pass.
- Hardware-facing behavior must fail closed when evidence is ambiguous.
- Do not commit secrets, signing credentials, personal health data, raw participant media, provisioning profiles, or device identifiers.
- Do not use destructive Git commands on work you did not create.

## Apple project source of truth

`apple/MotionOSHost/project.yml` is the source of truth for generated Xcode project structure, capabilities, package dependencies, and deployment targets.

Do not hand-edit `apple/MotionOSHost/MotionOSHost.xcodeproj/project.pbxproj` as a durable fix. Regenerate it with:

```bash
cd apple/MotionOSHost
bash bootstrap.sh --reset-packages --no-open
```

If Xcode 27.2's JSON project format is evaluated, do so on an isolated branch. Do not introduce a second project-authority format while XcodeGen remains canonical.

## Agent lanes

Agents may cross lanes when a task genuinely requires it, but each PR should have one primary owner.

- **apple**: Swift, SwiftUI, HealthKit, Core Motion, WatchConnectivity, Xcode configuration, iPhone/Watch lifecycle, simulator/device integration.
- **sensors**: MetaWear, BLE, equipment pods, insoles, adapters, device clocks, packet integrity, hardware fault handling.
- **models**: Python core, schemas, synchronization, QC, replay, body/world models, multimodal residuals, datasets and evaluation.
- **product**: operator UX, guided protocols, field observability, accessibility, experiment workflow and evidence export.
- **verify**: independent review, adversarial tests, CI reproduction, regression analysis, qualification evidence review. The verifier should not silently rewrite the implementation it is reviewing.

## Worktree policy

One writable worktree per agent. Do not have multiple agents edit the same checkout.

Before starting any new assignment or baseline audit, prove that the worktree is on the intended integration commit:

```bash
bash scripts/agent_baseline_check.sh origin/fix/apple-bootstrap-package-resolution
```

If the check reports a stale snapshot, fast-forward before auditing. Every audit or PR handoff must include the exact audited `git rev-parse HEAD`. Do not present findings from an older worktree snapshot as findings against the current integration baseline.

Create the standard fleet with:

```bash
bash scripts/setup_agent_worktrees.sh
```

Agent branches use `agent/<lane>`. Task branches may be cut from a lane branch when parallel work inside one lane is required.

Before opening a PR:

```bash
git status --short
git diff --check
```

## Xcode agent access

Run:

```bash
bash scripts/xcode_agent_preflight.sh
```

The script detects the capabilities of the selected Xcode toolchain.

- If `xcrun mcp-server` exists, headless Xcode MCP may be available.
- Otherwise use Apple's supported bridge path, `xcrun mcpbridge`, with the MotionOS project open in Xcode.
- Never enable an "always allow all agents" mode on a normal developer workstation.
- Keep Xcode agent permissions scoped to the commands and project tree actually needed.

## Required validation

Choose the smallest relevant set, but changes must not skip applicable layers.

Python/core:

```bash
ruff check .
pytest -q
```

Swift contract:

```bash
swift test --package-path apple/MotionOSAppleCapture
```

Apple host bootstrap:

```bash
cd apple/MotionOSHost
bash bootstrap.sh --reset-packages --no-open
```

iOS/watchOS compile checks should use the generated project and repository-local SwiftPM cache. Hardware-facing PRs additionally require the relevant physical protocol and receipt.

## Physical qualification boundary

Simulator, unit-test, build, and agent-driven UI verification are software evidence only.

A claim involving real Watch IMU continuity, HealthKit workout lifecycle, BLE hardware, clock behavior, background survival, transfer durability, or biomechanics requires real-device evidence under the corresponding runbook. P0/P1/P2 receipts must not be synthesized or inferred by an agent.

## Dependency policy

Transitive deprecation warnings should be fixed at the narrowest dependency boundary. Do not raise MotionOS deployment targets or suppress warnings globally to hide third-party manifest warnings.

For the current MetaWear graph, firmware/DFU dependencies are not part of the MotionOS capture path. If a core-only MetaWear fork or upstream package split is introduced, pin it to an exact revision and preserve a documented update path.

## PR handoff

Every substantial PR should state:

1. requirement being closed;
2. files/contracts changed;
3. tests executed and their result;
4. evidence not yet collected;
5. known risks or follow-ups;
6. whether independent verification is required.

The verifier should attempt to falsify the PR's claims, not merely confirm that the happy path compiles.

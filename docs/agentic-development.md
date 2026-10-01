# Agentic Development for MotionOS

MotionOS benefits from parallel coding agents only when parallelism is bounded by explicit interfaces and independent verification. The objective is not maximum agent count. It is maximum useful throughput per unit of integration risk.

## Recommended topology

```text
                         human owner
                              |
                      integration queue
                              |
        +---------------------+---------------------+
        |          |          |          |          |
      apple      sensors    models     product    verify
        |          |          |          |          |
   own worktree own worktree own worktree own worktree own worktree
        \          |          |          /          /
         +----------+----------+---------+----------+
                              |
                          reviewed PRs
                              |
                              CI
                              |
                  physical qualification gates
```

Five lanes are enough to expose useful parallelism without creating an integration swarm.

## Lane ownership

### Apple

Owns iPhone/watchOS application code, HealthKit, Core Motion, WatchConnectivity, Xcode generation, signing-facing configuration, simulator behavior, and native UI lifecycle.

### Sensors

Owns MetaWear and future hardware adapters, BLE behavior, packet logging, per-device clock handling, reconnect behavior, sensor fault injection, and equipment/insole integration.

### Models

Owns schemas, synchronization, replay, QC, uncertainty, body/world registration, multimodal residuals, datasets, experiments, and model evaluation.

### Product

Owns guided protocols, operator workflow, field diagnostics, experiment setup, accessibility, evidence export, and the presentation layer around capture state.

### Verify

Starts from the PR's stated claims and tries to disprove them. Reproduces CI, adds adversarial coverage when needed, checks provenance boundaries, and calls out any missing physical evidence.

## Xcode 27 integration modes

MotionOS supports two Xcode-agent modes.

### Bridge mode

This is the default and currently documented Apple workflow.

1. In Xcode, open Settings > Intelligence.
2. Enable external agents under Model Context Protocol.
3. Open `apple/MotionOSHost/MotionOSHost.xcodeproj`.
4. Register `xcrun mcpbridge` with the coding agent.

Examples:

```bash
codex mcp add xcode -- xcrun mcpbridge
claude mcp add --transport stdio xcode -- xcrun mcpbridge
```

The bridge talks to the running Xcode session.

### Headless preview mode

Some Xcode 27 builds expose `xcrun mcp-server`, an early-preview service that can work without an open workspace.

Detect rather than assume:

```bash
xcrun --find mcp-server
```

If present, enable headless access once, grant only the project folder needed by the agent, then open the project. In Xcode 27.2 beta the server is launched by `open`; there is no separate `start` command.

```bash
sudo xcrun mcp-server enable
sudo xcrun mcp-server allow-folder "$HOME/Documents/Projects/multimodal-sport-lab" --for-24-hours
xcrun mcp-server open apple/MotionOSHost/MotionOSHost.xcodeproj
xcrun mcp-server status
```

For isolated agent worktrees, grant the worktree root separately after creating it:

```bash
sudo xcrun mcp-server allow-folder "$HOME/Documents/Projects/motionos-agents" --for-24-hours
```

Use `xcrun mcp-server stop` when headless Xcode is no longer needed. Do not configure blanket unattended approval on a normal workstation.

Use:

```bash
bash scripts/xcode_agent_preflight.sh
```

to select the available path.

## Task sizing

Good parallel tasks have a narrow contract and mostly disjoint files. Examples:

- Apple: make P0 workout restart/recovery state explicit.
- Sensors: isolate MetaWear core from unused firmware/DFU package dependencies.
- Models: add replay/QC checks for a new timing invariant.
- Product: improve guided P0 failure recovery and operator messaging.
- Verify: add adversarial tests for interrupted Watch transfer.

Bad parallel tasks all rewrite the same coordinator, schema, or project file.

## Handoff contract

A task description should contain:

- **Goal**: observable behavior to change.
- **Owned surface**: expected files/modules.
- **Interfaces frozen**: contracts the agent must not change.
- **Acceptance tests**: commands and expected evidence.
- **Physical evidence**: whether real hardware is required.
- **Stop conditions**: situations that require escalation rather than improvisation.

This keeps agents from solving the wrong problem very efficiently.

## Integration cadence

Prefer short-lived branches and small PRs. Merge interface-defining changes before dependent implementation branches. Rebase or refresh downstream agent branches after interface changes rather than letting them drift for days.

For hardware work, use a two-stage completion state:

```text
software-qualified -> physically-qualified
```

No agent should collapse those into one state.

## Dependency cleanup strategy

The Xcode 27 warnings currently visible from NordicDFU and ZIPFoundation originate in transitive package manifests, not in MotionOS's watchOS deployment target.

The preferred cleanup is to remove unused firmware/DFU dependencies from the MotionOS package graph, either through an upstream MetaWear package split or an exact-revision core-only fork. Do not hide the warnings with global compiler-warning suppression and do not raise MotionOS deployment targets merely to silence a transitive manifest.

Treat that cleanup as a Sensors-lane task with Apple-lane verification.


## Fleet operations

Check all lane baselines before starting work:

```bash
bash scripts/agent_fleet_status.sh
```

For an idle, clean lane with no lane-local commits, fast-forward it safely:

```bash
bash scripts/sync_agent_lane.sh apple
```

The sync helper refuses dirty, ahead, or diverged worktrees. Those states require an explicit human/agent decision rather than an automatic rewrite.

A productive default cadence is:

1. refresh idle lanes;
2. assign one bounded task per active lane;
3. keep human-only device work running in parallel;
4. require exact-commit evidence in handoff;
5. merge small PRs;
6. refresh idle lanes again before the next assignment.

Do not keep every lane busy merely because it exists. Activate lanes only when they are off the current critical path or can produce evidence without creating integration contention.

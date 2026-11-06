# INDO BOARD rest annotation ingestion v1

Status: **experimental, opt-in, not clinical recovery guidance**.

## Implemented

The normal Indo Board 120-second product session remains intact. When the
optional **Experimental rest annotations** option is enabled, the iPhone exposes
an operator panel for marking bouts, breaks, and effort while safely off-board.
Events are appended to the *existing* operator journal using the same canonical
run identifier, monotonic host timestamp and sequence stream.

A pure Swift state reducer in MotionOSAppleCapture prevents illegal event
transitions (overlapping bout/rest, duplicate ID, an effort rating without a
finished bout, or a post-rest phase without completed rest). FieldRunCoordinator
writes the event before adopting the resulting state; failed file writes must
not silently advance the UI state.

The Python module `motionos.indo_rest_events.extract_indo_rest_events`
independently verifies a journal's SHA-256 against a caller-provided expected
digest, enforces run identity, contiguous sequence and host monotonicity, and
reconstructs finished bouts, rest intervals and rider effort annotations.

**Critical trust boundary:** The expected SHA-256 must itself come from a
trusted, sealed product manifest. This is integrity validation, not identity
authentication. The extractor does not verify the original video's hash,
independent Watch-clock alignment, or board geometry. Its result sets
`source_verified=false` on every output bout so the descriptive analyzer
cannot accidentally treat operator markers as physically qualified movement.

## Annotated kinds

All operator-journal events retain the established
`motionos.operator-events.v1` envelope and
`annotation_only_not_sync_authority` timing semantics.

The pilot markers carry `payload.event_schema=motionos.indo-rest-events.v1`,
a unique event ID, and where applicable a bout ID, phase, skill, setup, stance
and tracking mode.

- `indo_rest_bout_started`
- `indo_rest_bout_finished`
- `indo_rest_rest_started`
- `indo_rest_rest_finished`
- `indo_rest_effort_reported`

The phases are `reference`, `late`, and `post_rest`. The source preserves
what the participant/operator entered; the app does not label a phase as
physiological fatigue. No population-average symmetry rule is applied.

## Not yet implemented

- Watch-only start/end/rest/effort UI when the rider is away from the iPhone.
- A distinct extended, rest-capable protocol. The standard session still ends
  automatically at 120 seconds. The operator panel is suitable for exploratory
  annotations only, not the complete multi-bout intervention experiment.
- Cross-clock physical synchronization and camera/roller quality gating for
  per-bout metrics. The extractor returns an empty metric map deliberately.
- Directly connected HealthKit historical data or predictive rest prompts.
- A native signed, end-to-end verified report surfaced in the session library.

## Next acceptance

1. Python tests and Swift package tests pass in repository CI.
2. iPhone/watchOS host builds pass without changing standard M0 behavior.
3. Exercise the experiment on paired hardware, including disconnected Watch,
   early finish, duplicate tap, and incomplete rest.
4. Add Watch-originated persistent annotations with retransmission and receipt
   verification before enabling a full recovery pilot for a solo rider.
5. Only then connect qualified per-bout features and source provenance to
   `build_indo_rest_pilot_report`.

All pilot interpretation remains descriptive, not an instruction to exercise
through pain, dizziness, or other concerning symptoms.

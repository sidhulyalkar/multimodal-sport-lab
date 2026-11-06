# Watch-native Indo Board rest annotations v1

Status: opt-in research feature, not a validated recovery assessment.

## Purpose

During an iPhone-launched MotionOS workout, the rider may opt into a **Rest
study** section on Apple Watch. At a safe pause, they can mark an attempt
start/end, a break start/end, and optional exertion (0–10). This requires no
live Watch-to-iPhone message; it works if the iPhone temporarily disconnects.

**The ordinary two-minute Indo Board protocol is unchanged** and still
auto-finishes. This is a small collection substrate and does NOT yet implement
a complete multi-bout extended study. Do not reach for controls while actively
riding.

## Watch recording contract

The WatchSessionController publishes an optional, typed state reducer. A marker
is first validated against current bout/rest state. Only after the existing
CaptureSessionJournal successfully appends a SensorEnvelope is the UI state
advanced. While an append is in flight, duplicate actions are blocked. The
normal Watch journal is then sealed, hashed, transferred, acknowledged and
retained by the existing transfer protocol.

- Source event schema: motionos.m0.v1
- Stream: /experiments/indo/rest_annotation
- Device time: device_time_ns from Watch monotonic clock
- Session: native Watch session ID
- Sequence: independent contiguous sequence, starting at zero
- Event payload event_schema: motionos.indo-rest-events.v1
- Event payload event_type: same typed event kind as the phone operator journal
- Event payload event_id: unique UUID
- Event payload run_binding: bound/unbound
- Event payload linked_run_id: included **only** when Watch has verified/bound
  the current iPhone product run ID
- Clock semantics: watch_monotonic_input_time

The current Watch interface records setup_id=watch_setup_unverified and
tracking_mode=watch_only. This is intentional: it cannot certify the physical
camera or board tracking context and must not be treated as qualified
deck-relative evidence.

## Offline verification

The stdlib-only Python function extract_watch_rest_events reads a
Watch-native JSONL file and verifies its SHA-256 against a **trusted expected
digest** from the iPhone's receipt; it checks source identity, per-stream
sequences, monotonic annotation timestamps, event IDs, phases, and state
transitions. It produces Watch-native nanosecond bout boundaries, breaks, and
ratings.

No output uses iPhone/camera session seconds or qualifies movement metrics.
An unbound marker remains explicitly unbound even when the journal itself is
valid.

The standalone analyzer build_indo_rest_pilot_report still requires verified,
session-clock-aligned per-bout measurements. Passing raw Watch-native times
directly to it is not allowed.

## Required next qualification

1. Physical iPhone + Watch session, with a simulated WatchConnectivity
   outage during markers, should still yield a complete local watch journal.
2. Reconnected journal transfer must return matching digest and bytes before
   deleting the original.
3. The Python decoder must reconstruct event order and report unknown
   Watch/iPhone time alignment rather than assigning phone timestamps.
4. Implement an optional extended rest protocol, explicitly separate from
   the 120-second M0 standard protocol, with a robust interrupted-session
   recovery path and comfortable breaks.
5. Use independent clock-alignment receipts and qualified video/equipment
   sources before computing any early/late/post-rest movement comparison.
6. Add real rider ergonomics, accessibility and duplicate-gesture testing
   before calling the Watch path suitable for a solo study.

Tests: pytest tests/test_indo_watch_rest_events.py; Swift package
IndoRestWatchJournalTests plus IndoRestPilotAnnotationsTests; native iPhone and
Watch builds in CI. These do not replace physical verification.

This is scientific research instrumentation, not an injury predictor, a
fatigue diagnosis, a rest prescription, or a medical alert.

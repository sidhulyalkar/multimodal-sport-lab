# MotionOS Consumer Product Experience v1

Status: product UX contract for turning the current research-grade capture stack
into a broadly usable athlete product without weakening evidence provenance.

## Product promise

A person should be able to understand MotionOS without knowing what an IMU,
journal, clock model, qualification receipt, source hash, or annotation stream
is.

The default loop is:

1. choose an activity;
2. let MotionOS check the required setup;
3. record;
4. review what happened;
5. repeat comparable sessions;
6. see what changed over time.

Technical evidence remains available, but it is progressive disclosure rather
than the primary navigation model.

## Primary information architecture

The four primary jobs are:

- **Home**: what is happening now and what should I do next?
- **Record**: choose an activity and start a guided session.
- **Progress**: understand repeated-session changes and personal ranges.
- **Sessions**: replay and inspect previous recordings.

Devices, qualification, source integrity, transfer diagnostics, and developer
tools are secondary setup/details surfaces.

Hardware is part of the product, but it should not define the product
navigation.

## Activity-first architecture

The UI should route through an activity descriptor rather than hard-code the
entire product around one sport.

An activity descriptor can eventually define:

- display name and icon;
- supported session templates;
- required sources;
- optional sources;
- setup guidance;
- minimum evidence quality;
- progress dimensions;
- validated interpretation rules.

Indo Board is the first guided activity. A future activity should plug into the
same Home / Record / Progress / Sessions shell rather than creating a separate
app inside the app.

Do not display unsupported sports as if they are usable merely to make the
catalog look broad.

## Progressive setup

Do not ask every user for every permission, sensor, body measurement, or
profile field during onboarding.

Ask for information only when a feature needs it.

Examples:

- camera permission when the user starts an activity that uses video;
- Health access when the Watch workflow needs a workout;
- height or segment measurements when a metric actually depends on scale;
- stance and equipment when an activity comparison requires that context;
- external camera setup only when the user enables an external camera.

This makes the first-run experience short and keeps every question explainable.

## Progressive profiling

A multi-user product needs explicit profiles, but profile collection should be
incremental.

Separate:

1. **Identity/preferences**: display name, preferred units, activities, goals.
2. **Stable body context**: height and only measurements required by supported
   metrics.
3. **Activity context**: stance, equipment, skill familiarity, setup.
4. **Session context**: effort, conditions, discomfort, notes.
5. **Inferred personal model**: learned only from qualified repeated evidence.

Never silently treat inferred traits as user-entered facts.

## Readiness model

The athlete-facing setup should answer one question:

> Can I start safely and get a useful recording?

Use three levels:

- **Ready**: all required items are available.
- **One thing left**: exactly what the user needs to fix.
- **Optional improvement**: an extra source may improve later analysis but does
  not block the session.

Avoid exposing transport-layer states such as reachability, journal sealing,
hash verification, or clock fitting unless the user opens technical details.

## Language boundary

Preferred default language:

- session, not capture;
- saved, not sealed;
- Watch recording, not journal;
- timing/alignment, not clock fit;
- camera view, not teacher stream;
- recording source, not evidence artifact;
- needs review, not unqualified;
- experimental cue, not confident coaching recommendation.

Technical terms remain available in advanced surfaces because they are useful
for debugging and scientific inspection.

## Trust hierarchy in the UI

The user should be able to tell the difference between:

1. **Recorded**: directly captured data.
2. **Measured**: derived from a validated measurement path.
3. **Estimated**: model output with uncertainty.
4. **Reviewed**: explicitly checked by a human.
5. **Experimental guidance**: a hypothesis or cue that has not yet earned a
   validated personalized interpretation.

A model confidence percentage must not be presented as the probability that a
coaching recommendation is correct.

## Session review hierarchy

Default session detail order:

1. activity/date/status;
2. replay;
3. movement summary;
4. comparison with prior comparable sessions;
5. athlete reflection / feedback;
6. technical details.

Technical details may contain:

- source availability;
- synchronization;
- protocol events;
- rates/gaps;
- immutable identifiers;
- hashes/provenance;
- import status.

Nothing is discarded. The ordering changes.

## Progress

Progress should prioritize within-person, like-for-like comparison.

The product should not invent a universal movement score merely because a
single number is visually convenient.

A good progression is:

- first session: reference point;
- second comparable session: descriptive trend;
- repeated sessions: personal range;
- reviewed repeated sessions: stronger personal baseline;
- new exact-context session: personal delta;
- validated interpretation: explain whether a change is relevant;
- validated intervention loop: suggest and test a cue.

The UI should be comfortable saying “different” without pretending that
different means “better.”

## Empty states

Every empty state should tell the user the next useful action.

Examples:

- no sessions -> record first session;
- one session -> repeat the same activity;
- no matching baseline -> repeat under comparable context;
- camera not ready -> one camera adjustment;
- Watch missing -> open/install Watch app;
- optional source absent -> continue without it or add it.

Never use an empty state as a diagnostic dump.

## Error recovery

Errors should be:

- specific;
- actionable;
- local to the failed source;
- non-destructive.

If one optional source fails, preserve the rest of the session.

If a required source fails before recording, explain the one blocking action.

If a transfer fails after recording, say the recording is still safe when that
is actually true and provide a retry path.

## Accessibility and ergonomics

Primary controls should:

- meet the 44-point minimum interaction target;
- support Dynamic Type;
- avoid meaning conveyed by color alone;
- use short labels on Watch;
- preserve one dominant action per state;
- avoid requiring phone interaction while the athlete is balancing or moving.

Camera setup should increasingly support voice/Watch guidance so tripod
placement can be corrected from the activity position.

## Beta boundary

The current heuristic Indo Board coach predates the new reviewed-label ->
personal-baseline -> session-delta trust chain.

Until those layers are explicitly connected to a validated interpretation
contract, the consumer surface should label those outputs as experimental cues,
not authoritative personalized coaching.

## Near-term product milestones

1. Consumer navigation and first-run experience.
2. Activity descriptor/catalog boundary around the current Indo Board flow.
3. Simplified readiness and guided setup.
4. Progress tab using repeated-session history.
5. Personal baseline/session delta imported into the iPhone product layer.
6. Versioned interpretation contract with explicit abstention.
7. Small external-user usability test with no developer assistance.
8. Add the next activity only after the shell works cleanly for a new user.

## Success criteria for usability testing

A new participant should be able to:

- explain what MotionOS does after onboarding;
- find how to record without instruction;
- understand what hardware is required vs optional;
- complete a supported session without developer help;
- find the replay;
- understand whether data is saved;
- find progress;
- distinguish an observation from an experimental suggestion;
- recover from a common setup failure;
- find technical details if they want them.

The product has passed the usability bar only when those tasks work without
knowledge of the repository or measurement architecture.

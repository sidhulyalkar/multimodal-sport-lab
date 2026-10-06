# MotionOS Session Context v1

Status: product contract for attaching user-declared comparison context to
recorded sessions without turning onboarding into a questionnaire.

## Why this exists

MotionOS now has a reviewed personal-baseline engine that compares only exact
contexts. The consumer app therefore needs to preserve the small amount of
context that makes two sessions meaningfully comparable.

That context must come from the product workflow itself. It should not depend on
a developer reconstructing JSON after the session.

## Principles

### Ask only when it matters

Do not ask every user for height, weight, shoe size, dominant side, experience,
goals, equipment, injuries, and every sport during first launch.

Collect a field only when a supported feature needs it.

For the first Indo Board workflow, the first user-declared comparison dimension
is foot position:

- left foot forward;
- right foot forward;
- varies / not sure.

The selection is remembered locally and remains editable before later sessions.

### Recording must remain possible with ambiguity

The value varies_or_unsure does not block recording.

It does mean a downstream stance-specific personal comparison should abstain
until the relevant setup is declared precisely enough. Ambiguous context must
not become a convenient bucket for silently pooling physically different
sessions.

### Local profile identity

Each installation receives a stable pseudonymous local profile ID.

The ID is intentionally not:

- the user's name;
- email address;
- Apple ID;
- Health identifier;
- advertising identifier;
- account credential.

Its purpose is to bind longitudinal artifacts to one local movement profile.

The raw profile ID is not shown in the ordinary athlete UI.

Future account/profile sync requires a separate privacy and identity design. A
local UUID should not quietly become an account system.

## Manifest contract

ProductSessionManifest now optionally carries:

    context
      profileID
      activityID
      protocolID
      dimensions

For the current Indo Board flow the dimensions include stance and capture mode.

The protocol ID is stored separately so a future protocol revision does not get
silently pooled with an older task.

The field is optional so existing motionos.product-session.v1 artifacts remain
decodable.

## User-entered versus inferred context

Session context is declared metadata.

It is distinct from learned athlete traits.

Declared examples:
- stance;
- board/equipment choice;
- drill variant;
- assisted versus unassisted setup;
- environment option selected by the user.

Observed examples:
- camera/device availability;
- recorded session duration;
- sensor presence.

Inferred examples:
- balance strategy;
- movement primitive;
- asymmetry;
- skill estimate;
- fatigue proxy.

An inferred trait must not be written into the user-declared context merely
because a model predicted it.

## Activity-specific expansion

The activity catalog should eventually declare which context fields matter for
that activity.

Examples may include:

- Indo Board: stance, board/setup variant;
- cycling/MTB: bike/equipment profile, seated/standing drill where applicable;
- skiing: stance/task/equipment and terrain protocol;
- climbing: route/problem identifier and intended exercise;
- running: protocol/surface where required for a particular comparison.

These examples are product architecture, not a promise that every field is
already scientifically qualified.

## Comparison policy

A strict personal comparison should require:

1. same profile;
2. same activity;
3. compatible protocol version;
4. exact required context dimensions;
5. accepted/reviewed metric evidence required by the comparison;
6. no current-session leakage into the baseline.

Missing or ambiguous required context should produce an abstention, not a
best-effort comparison with an unrelated session.

## UX

Before recording, the context control should:

- be short;
- explain why it matters;
- remember the prior answer;
- allow "not sure" when appropriate;
- avoid blocking recording unless the field is genuinely required for capture.

After recording, Session Details may show human-readable context such as
"Left foot forward."

Do not expose internal profile IDs in the default UI.

## Privacy boundary

Context should be no broader than the feature requires.

Adding a field to a session manifest is a product/data decision, not a free
opportunity to collect more user attributes.

Sensitive health information, diagnoses, pain, injury, rehabilitation status,
or other medical context requires a separate feature and privacy review rather
than being added to this generic dictionary.

## Next step

The native Progress layer should consume reviewed personal-baseline and
session-delta artifacts using this context.

The first useful states are:

- no compatible history;
- one compatible session;
- personal range available;
- current session compared with personal range;
- comparison unavailable because required context is ambiguous or changed.

Only after that should a validated interpretation layer translate a delta into
a recommendation.

# Local Athlete Profiles v1

Status: product identity boundary for shared-device use.

## Goal

MotionOS should be effortless for one person and safe for many people.

A single-user install starts with one local profile:

- profile ID: `local-athlete`
- display name: `Me`
- units: automatic

The user does not have to create an account, enter body measurements, or answer
a setup questionnaire before recording.

If more than one person uses the same iPhone, they can add local profiles and
choose who a new guided session belongs to.

## Why profile identity belongs in the session manifest

Progress, personal baselines, prior-session comparisons, and later
personalized guidance must never silently combine different people.

Every new guided product session therefore carries:

- `profileID`
- `sport`

in `motionos.product-session.v1`.

The fields are additive and backward-compatible. Older manifests without a
profile ID remain readable and are interpreted by the product library as the
legacy local profile.

The operator readiness metadata also carries `profile_id` so an interrupted
run can retain identity even before the final product manifest is available.

## Local-first UX

Profile configuration intentionally contains only:

- local display name;
- preferred units.

Stable body measurements, stance, equipment, goals, health permissions, and
sport-specific context are not collected here. MotionOS should request those
only when a supported measurement or activity actually needs them.

Profiles are stored in Application Support on the device.

## Session ownership

The guided session shows **Recording for <profile>** before start.

Once a session begins, its profile association is locked for the lifetime of
that run. Changing the app's active profile later does not rewrite the saved
session.

External-video imports preserve the original manifest profile and sport.

## Progress isolation

Product-run history and descriptive trends are filtered to the active profile.

Previous-session comparisons additionally require the candidate run to have the
same `profileID` as the current run.

Standalone Watch-only recordings do not yet carry profile identity. They remain
visible as explicitly unassigned recordings and do not enter profile-scoped
guided-session progress by assumption.

## Legacy behavior

Historical guided sessions created before profile support did not include a
profile field. The library maps those sessions to `local-athlete`, matching
the previous single-user behavior.

This migration is intentionally conservative: it does not infer names or split
historical sessions among newly created profiles.

## Privacy and deletion

v1 does not implement destructive profile deletion.

Deleting a display preference and deleting all recordings belonging to a person
are different operations. A later deletion/export flow must make that
distinction explicit and must not orphan session data accidentally.

## Next

The next profile tranche should add:

1. profile-aware export and deletion;
2. explicit assignment of standalone Watch recordings when desired;
3. activity context collected only when needed;
4. connection from profile-bound product sessions into the reviewed personal
   baseline and session-delta pipeline.

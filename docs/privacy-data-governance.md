# MotionOS Privacy and Data Governance

MotionOS records movement, sensor telemetry, video, and optionally body geometry.
Those artifacts can identify a person even when names are removed.

This document defines the repository's default engineering/research handling
policy. It is not legal advice and does not replace requirements imposed by
applicable law, an employer, an institution, an ethics board, a dataset owner,
or a signed participant agreement.

## Core rules

1. Raw participant evidence is private by default.
2. A participant identifier is pseudonymous, never a name, email, initials,
   birth date, or other meaningful label.
3. Raw evidence and consent records never belong in the public Git repository.
4. A derived artifact does not automatically become anonymous.
5. Public release requires a separate export decision and a reproducible
   manifest.
6. Consent and external-dataset licenses are permissions, not data-quality
   evidence.
7. De-identification creates a new derived artifact; it never rewrites the
   preserved source evidence.

## Artifact classes

### raw_identifying

Examples:
- face/body video or audio;
- body scan, mesh, or point cloud;
- precise location trace;
- files containing names/contact information;
- consent forms;
- device exports containing account identifiers.

Default:
- private storage only;
- excluded from the default public-export validator.

### pseudonymized_sensitive

Examples:
- raw Watch/IMU/pressure sessions labeled only by participant ID;
- synchronized movement traces;
- operator notes stripped of direct identifiers.

Pseudonymization reduces direct identification risk. It does not make movement
data anonymous.

Default:
- private/restricted project storage;
- excluded from the default public-export validator.

### derived_restricted

Examples:
- reconstructed body trajectories;
- detailed personalized body geometry;
- pose sequences derived from identifying video;
- analysis tables that retain rare participant characteristics.

Default:
- restricted project storage unless separately reviewed;
- excluded from the default public-export validator.

### publishable

A non-synthetic artifact reviewed for public release with:
- appropriate self-authorization, participant consent, or dataset license;
- metadata minimization;
- no raw identifying artifact;
- a frozen hash in the public-export manifest.

### synthetic

Data generated without a real participant.

Synthetic/demo data must say so explicitly. It must not be presented as physical
validation evidence.

## Participant IDs

Use:

```text
p-<8 to 32 random lowercase alphanumeric characters>
```

Example:

```text
p-a1b2c3d4
```

Do not encode:
- name or initials;
- birthday/age;
- sport team;
- diagnosis;
- location;
- email;
- sequential recruitment number if that mapping is public.

The participant-ID to identity mapping, if one is needed, is private and stored
separately from sensor evidence.

## Recommended directory boundary

Private participant material should live outside tracked source trees, for
example:

```text
private/
  consent/
  participants/
  raw-media/
  body-scans/
  location/
```

MotionOS also ignores `data/`, `participant-data/`, `private/`,
`profiles/private/`, and `exports/private/`.

A .gitignore entry is a guardrail, not an access-control system. Sensitive files
should additionally use appropriate filesystem/cloud permissions and encryption
where available.

## Consent before recording another person

Before collecting another participant's data, record:
- participant pseudonymous ID;
- collection purpose;
- sensors/modalities;
- whether identifiable video/audio is recorded;
- whether a body scan is recorded;
- expected retention period;
- who can access raw data;
- whether derived research artifacts may be retained;
- whether any artifact may be publicly released;
- how withdrawal/deletion requests are handled.

Use `docs/participant-consent-template.md` as an operational starting point.

A signed/recorded consent artifact remains private. Public manifests may carry a
non-identifying consent reference ID, not the consent document itself.

## Operational retention default

Unless a stricter agreement or requirement applies:

- **raw_identifying**: retain through the active calibration campaign and
  verification period, then review for deletion within 90 days of campaign
  closure;
- **pseudonymized_sensitive**: retain while the experiment is active, with a
  review at least annually;
- **derived_restricted**: retain only while scientifically/product necessary,
  with an annual review;
- **publishable/synthetic**: may be retained with the associated provenance.

For participant studies, the collection-specific consent record must state the
actual planned retention period. It overrides these repository defaults when it
is more restrictive.

Do not silently extend retention because storage is cheap.

## Withdrawal and deletion workflow

Given a participant ID:

1. stop new processing/export for that participant;
2. inventory raw sessions, video, scans, derived artifacts, caches, manifests,
   and controlled backups;
3. determine which artifacts are subject to the request/agreement;
4. delete controlled copies that should be removed;
5. invalidate or regenerate aggregate artifacts whose continued retention is not
   permitted;
6. record a private deletion receipt containing artifact identifiers/hashes, not
   deleted personal content;
7. ensure future pipelines do not recreate deleted artifacts from retained
   sources.

Material already distributed publicly may not be fully retractable from third
parties. That limitation should be disclosed before public release rather than
promised away after the fact.

## Video privacy reduction

If video must be shared, create a separate derivative when appropriate:
- crop irrelevant bystanders/background;
- remove audio unless necessary;
- blur or mask faces and other direct identifiers;
- remove embedded location/device metadata;
- preserve the transformation description and source hash privately.

A blurred face does **not** make full-body motion or body shape anonymous.
Therefore privacy-reduced video remains restricted unless separately approved
for public release.

Never overwrite the immutable source video with a redacted derivative.

## Body scans

Body scans and meshes are `raw_identifying` by default.

Do not commit them to Git, even when filenames are pseudonymous.

For reproducible MotionOS results, public artifacts may reference:
- a private source artifact hash;
- non-identifying aggregate segment lengths when approved;
- synthetic/example geometry.

The source bytes remain outside the public repository unless an explicit,
separately reviewed release is intended.

## Location

Precise GPS/route traces can identify homes, workplaces, routines, and preferred
training locations.

Before public export:
- remove unnecessary exact timestamps;
- crop or coarsen start/end location when route geometry is not scientifically
  necessary;
- remove EXIF/GPS metadata from media;
- prefer derived distance/elevation summaries when exact geometry is irrelevant.

## Public export gate

Create a `motionos.public-export.v1` manifest and run:

```bash
motionos validate-public-export public-export.json
```

The conservative default rejects:
- `raw_identifying`;
- `pseudonymized_sensitive`;
- `derived_restricted`.

Only `publishable` and `synthetic` artifacts pass the default gate, and all
file hashes plus release-basis fields must verify.

This intentionally requires a human decision to promote an artifact to
`publishable`.

## Public export checklist

Before release verify:

- [ ] artifact purpose is stated;
- [ ] exact bytes are hash-bound;
- [ ] raw identifying artifacts are excluded;
- [ ] participant/dataset authorization is appropriate;
- [ ] names, emails, device account IDs, and unnecessary timestamps removed;
- [ ] location metadata minimized;
- [ ] video/audio reviewed for bystanders and direct identifiers;
- [ ] body-scan source bytes excluded unless explicitly reviewed;
- [ ] model output is labeled derived/inferred;
- [ ] synthetic/demo data is labeled synthetic;
- [ ] external dataset redistribution terms checked;
- [ ] README/caption does not overstate physical validation.

## External datasets

Track external datasets in a
`motionos.external-dataset-registry.v1` document.

For each dataset record:
- source reference;
- license/terms reference;
- authorization status;
- whether redistribution is permitted.

Validate the registry with:

```bash
motionos validate-dataset-registry external-datasets.json
```

Do not copy third-party dataset bytes into the repository merely because an
adapter exists.

## Repository demos

Repository examples and Replay Lab demos must be clearly one of:
- synthetic;
- transformed/publishable evidence with an export manifest.

A visually realistic synthetic replay is still synthetic and cannot close a
physical qualification gate.

# P2-A OpenGo Exported-Data Runbook

This protocol qualifies the MotionOS **export/import evidence path** for
bilateral OpenGo sensor-insole data.

It does not yet qualify direct BLE control, onboard-log recovery through a
custom iPhone app, or biomechanical validity.

## 1. Record both insoles

Use an OpenGo acquisition mode that preserves the raw channels needed by
MotionOS.

For each side export:

- 16 pressure sensors;
- X/Y/Z acceleration;
- X/Y/Z angular rate;
- total force;
- X/Y center of pressure;
- time.

Keep the original OpenGo measurement/export as immutable evidence.

If one side has a transient missing sample, do not fill it manually.

## 2. Export text data

Export a tab-delimited OpenGo text file with the full bilateral channels.

A valid file includes a header such as:

```text
# Start time: ...
# Sensor insoles: Left <serial>, Right <serial>
# Size: ...
# Recording type: ...
# time    left pressure 1[N/cm²] ... right center of pressure Y[-0.5...+0.5]
```

MotionOS binds side identity from the explicit left/right serial metadata.

## 3. Import without gap filling

```bash
motionos import-opengo-export \
  /path/to/export.txt \
  --out data/p2 \
  --session-id p2-opengo-run-001 \
  --athlete-id local-athlete \
  --sport longboard
```

The importer:

- hashes the exact source file with SHA-256;
- preserves the common OpenGo relative-time axis;
- never forward-fills blank-side rows;
- emits four raw MotionOS streams;
- converts acceleration to m/s²;
- converts angular rate to rad/s;
- converts pressure from N/cm² to kPa while retaining the source values;
- preserves total force in N;
- preserves CoP in the vendor's normalized coordinate system.

## 4. Validate capture integrity

For a 10-minute P2-A capture:

```bash
motionos validate-p2 \
  data/p2/p2-opengo-run-001 \
  --min-duration 600 \
  --receipt data/p2/p2-opengo-run-001/p2-capture-receipt.json
```

Or run import + validation together:

```bash
bash scripts/process_p2_opengo.sh \
  /path/to/export.txt \
  data/p2 \
  600 \
  p2-opengo-run-001 \
  local-athlete \
  longboard
```

## What a capture pass means

`capture_passed=true` means:

- all four left/right pressure + IMU streams exist;
- left/right serial metadata exists;
- each stream spans the required duration;
- stream timestamps are monotonic;
- IMU samples contain finite six-axis SI values;
- pressure arrays contain exactly 16 source and 16 canonical values;
- N/cm² → kPa conversion is internally consistent;
- total normal force is finite;
- normalized CoP is present and numerically plausible;
- source provenance hash exists.

The receipt also reports left/right timestamp overlap separately for IMU and
pressure.

## What a capture pass does NOT mean

It does not establish:

- pressure calibration accuracy;
- total-force accuracy;
- CoP accuracy;
- exact left/right hardware-clock error;
- direct-BLE reliability;
- onboard-record recovery behavior;
- full 3D ground-reaction force;
- clinical validity;
- sport-specific biomechanical validity.

Those require physical validation.

## CoP coordinate boundary

OpenGo text exports represent CoP in normalized insole coordinates.

Do not rename these values to meters.

Metric CoP can be added only when MotionOS has a versioned geometry profile for
the exact insole model/size/side and an explicit validated transform.

The geometry contract is implemented separately from raw ingestion for this
reason.

## Bilateral overlap

The text export uses one common relative-time column, but either side can be
missing at a row.

MotionOS reports:

```text
shared_timestamps / union_timestamps
```

for both IMU and pressure streams.

No universal overlap threshold is hard-coded in P2-A. A physical qualification
protocol must freeze that acceptance threshold before reviewing the result.

## Physical P2-B qualification

MotionOS now has a strict physical P2 receipt in addition to the P2-A capture
receipt. It deliberately requires **two distinct real sessions**:

1. a controlled session of at least 10 minutes by default;
2. a field session of at least 30 minutes by default.

Before reviewing the result, copy
`examples/p2-physical-qualification.example.json`, replace every placeholder,
set `example_only` to `false`, and freeze the acceptance thresholds. The
template is intentionally non-runnable so placeholder thresholds cannot
accidentally qualify hardware.

The controlled session must declare explicit device-time windows for:

- unloaded baseline before loading;
- known static load;
- repeatability trial A;
- repeatability trial B after don/doff;
- unloaded baseline after loading.

The physical spec also records the operator attestations that the thresholds
were frozen before review, the wireless-separation challenge was completed, and
the controlled don/doff action was completed.

Then run:

~~~bash
motionos validate-p2-physical \
  data/p2/<field-session> \
  data/p2/<controlled-session> \
  p2-physical-spec.json \
  --receipt data/p2/p2-physical-receipt.json
~~~

The default duration gates are 600 seconds controlled and 1800 seconds field.
They may be shortened only for development/test fixtures, not for the physical
P2-B claim.

`passed=true` requires all of the following to recompute:

- both sessions independently pass P2-A capture integrity;
- pressure and IMU bilateral overlap meet the frozen threshold in both runs;
- both unloaded windows remain below the frozen total-force threshold;
- the known-load median total force is within the frozen tolerance;
- don/doff repeatability satisfies both the frozen total-force and left-load
  fraction tolerances;
- all required physical-protocol attestations are true.

The receipt hashes the qualification spec and both MotionOS session bundles.
It does not qualify cross-device timing. Insole→Watch synchronization remains a
separate start/middle/end clock receipt in the calibration bundle, which keeps
sensor-local qualification and cross-device timing evidence independent.

## Direct BLE dependency

Moticon publishes an Insole SDK for direct BLE control, but the protocol/SDK is
licensed.

P2-A intentionally proves the MotionOS downstream evidence model first.

Direct iPhone integration should begin only after legitimate SDK/protocol access
is available.

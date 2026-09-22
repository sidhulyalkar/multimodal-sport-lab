# Bilateral Insole Adapter Contract

MotionOS treats smart insoles as two independent body-mounted sensors whose raw
evidence can share an export time axis without pretending that all future vendor
transports use the same clock semantics.

Canonical stream families:

```text
/body/left_foot/imu
/body/left_foot/pressure
/body/right_foot/imu
/body/right_foot/pressure
```

## Scientific claim boundary

Plantar-pressure insoles measure pressure beneath the foot and can expose or
derive a total **normal/vertical load**.

That is not the same measurement as a force plate's full 3D ground-reaction
force vector.

MotionOS therefore does not call insole output full 3D GRF and does not infer
unmeasured shear-force components from pressure alone.

Appropriate downstream quantities include, once separately validated:

- plantar pressure distribution;
- total normal force;
- center-of-pressure trajectory;
- stance/contact timing;
- load-transfer and asymmetry measures;
- normal-force impulse-like integrals;
- foot IMU kinematics.

## OpenGo text-export ingress

The first P2-A adapter targets the documented OpenGo text export rather than a
licensed BLE SDK.

Moticon's public Python tooling and sample exports define a tab-delimited format
with a metadata header and one common relative-time axis.

Reference implementation:

- https://github.com/moticon-rego/moticon-opengo
- https://github.com/moticon-rego/moticon-opengo/blob/main/src/moticon_opengo/txt_export.py

Public OpenGo product/programming documentation:

- https://moticon.com/opengo/sensor-insoles
- https://moticon.com/opengo/app
- https://moticon.com/documentation/opengo-programmers-guide

### Vendor source channels

For a full bilateral raw export MotionOS expects, per side:

```text
16 × pressure             N/cm²
3 × acceleration          g
3 × angular rate          deg/s (dps)
1 × total force           N
2 × center of pressure    normalized [-0.5, +0.5]
```

OpenGo export time is a relative measurement time in seconds.

Rows can be sparse on one side. The public Moticon parser offers duplicate/drop/
keep fill behaviors, but the MotionOS importer intentionally implements the
equivalent of **keep**: it never forward-fills missing left/right evidence.

A blank side at a timestamp therefore becomes an observable time gap.

## Canonical foot IMU payload

MotionOS converts the primary channels to SI while preserving the source values:

```json
{
  "ax": 9.80665,
  "ay": 0.0,
  "az": -9.80665,
  "gx": 3.141592653589793,
  "gy": 0.0,
  "gz": -1.5707963267948966,

  "acceleration_g": [1.0, 0.0, -1.0],
  "angular_rate_dps": [180.0, 0.0, -90.0],

  "source_time_s": 0.0,
  "timestamp_basis": "opengo_export_relative_time",
  "source": "moticon_opengo_text_export",

  "units": {
    "acceleration": "m/s^2",
    "angular_rate": "rad/s",
    "raw_acceleration": "g",
    "raw_angular_rate": "deg/s"
  }
}
```

Conversion constants:

```text
1 g = 9.80665 m/s²
1 deg/s = π/180 rad/s
```

## Canonical plantar-pressure payload

OpenGo exports each pressure channel in `N/cm²`.

Because:

```text
1 N/cm² = 10 kPa
```

MotionOS stores both the vendor and canonical values:

```json
{
  "pressure_n_per_cm2": [1.0, 1.1],
  "pressure_kpa": [10.0, 11.0],

  "normal_force_n": 500.0,

  "cop_x_normalized": -0.25,
  "cop_y_normalized": 0.15,
  "cop_coordinate_basis": "normalized_insole_-0.5_to_0.5",

  "source_time_s": 0.0,
  "timestamp_basis": "opengo_export_relative_time",
  "source": "moticon_opengo_text_export",

  "pressure_units": {
    "raw": "N/cm^2",
    "canonical": "kPa"
  }
}
```

### CoP is not converted to meters without geometry

The OpenGo text export gives CoP in normalized insole coordinates.

MotionOS does **not** fabricate `cop_x_m` / `cop_y_m` from those numbers.

Metric CoP requires a separately versioned insole-geometry profile tied to the
actual size/layout. That transform belongs in a later deterministic
interpretation layer while normalized source coordinates remain intact.

## Timestamps and sequence numbers

For OpenGo text-imported evidence:

```text
device_time_ns = round(export_relative_time_seconds × 1e9)
timestamp_basis = "opengo_export_relative_time"
```

This is the exported measurement axis, not a claim about an undocumented BLE
hardware counter.

MotionOS-assigned `sequence` values represent import order only. Missing
samples are assessed from timestamps/counts and bilateral overlap, not by
pretending importer sequence numbers came from the insole firmware.

## Side identity

Left/right device identity comes from the export header, for example:

```text
# Sensor insoles: Left SN5968, Right SN9171
```

The importer keeps these serial identities bound to their side-specific streams.

It never swaps sides based on row density, ordering, pressure magnitude, or
which foot contacts first.

## Provenance

The imported session records SHA-256 for the exact OpenGo text export.

This hash travels with the MotionOS manifest/receipt so later replay and analysis
can be traced back to the source bytes.

## P2 capture receipt

The first P2 receipt validates only exported-data integrity:

- all four bilateral streams exist;
- left/right serial identities exist;
- all streams meet the requested minimum duration;
- timestamps are monotonic;
- IMU samples have six finite SI channels;
- each pressure event has exactly 16 source + canonical pressure values;
- `N/cm² → kPa` conversion is internally consistent;
- total normal force is finite;
- normalized CoP is present and within a small numeric tolerance of the
  documented range;
- bilateral timestamp-overlap fractions are reported;
- source provenance hash is present.

The overlap fraction is reported, not yet promoted to a universal product
threshold. A physical qualification protocol should freeze any required
left/right overlap tolerance before reviewing the run.

## Direct BLE SDK boundary

Moticon currently offers an Insole SDK for direct control over BLE and also
supports onboard recording.

That integration is intentionally a later tranche because SDK/protocol access is
commercial/licensed.

Until licensed protocol files are available, MotionOS will:

1. validate the downstream contract using documented exported raw data;
2. avoid reverse-engineering proprietary BLE as its primary integration path;
3. keep direct transport objects outside the MotionOS event schema;
4. preserve source timestamps when direct acquisition is eventually added.

## Next evidence gates

### P2-A software
- raw export parser;
- bilateral identity;
- gap-preserving import;
- unit conversion;
- 16-channel pressure contract;
- provenance;
- capture receipt;
- replay compatibility.

### P2-B hardware
- controlled 10-minute bilateral run;
- 30-minute field run;
- pressure zero/unloaded baseline;
- known static-load sanity test;
- left/right timing coherence;
- don/doff repeatability;
- synchronization landmarks against Watch/pod;
- wireless-separation/onboard-recovery test if direct SDK capture is enabled.

Only those physical runs can qualify the selected insole hardware.

# MotionOS UI Product Specification

The interface should feel like a motion laboratory that disappears when the athlete starts moving.

## Navigation model

Five primary destinations:

1. **Today** — readiness, recent sessions, quick-start sport.
2. **Capture** — device readiness, calibration, live workout state.
3. **Replay** — synchronized athlete/equipment reconstruction.
4. **Compare** — cross-session and cross-sport analysis.
5. **Lab** — body model, devices, calibration, experiments, data quality.

The Watch application stays deliberately smaller:
- start/resume/end
- live heart rate
- elapsed time
- device-health summary
- one sport-specific metric
- haptic warnings

## Capture flow

### A. Sport chooser
Large tiles: Longboard, Skateboard, RipStik, Run, Hike, Climb, MTB, Ski, Custom.

Every sport is a configuration of:
- required sensors
- optional sensors
- expected sample rates
- calibration steps
- live metrics
- post-session analyses

### B. Device readiness
Each device receives one state:
- ready
- connecting
- degraded
- missing
- unsynchronized
- low battery

Never reduce this to a generic green dot. Show why a device is degraded.

Example card:

```text
Equipment Pod                         READY
MetaMotionS · board-center
100 Hz stream · local log armed
Sync residual 2.1 ms · Battery 82%
X forward · Y left · Z up
```

### C. Calibration wizard
A full-screen sequence, one action at a time:
1. stand still
2. neutral stance
3. board level
4. left/right weight shift
5. deliberate sync impulse
6. camera framing check (calibration mode only)

Each step records a receipt. Calibration is never a hidden boolean.

### D. Live capture HUD
Phone:
- elapsed time
- sport
- device health
- HR / speed / altitude as available
- left/right loading
- board orientation
- sync quality
- recording status

Watch:
- one-glance workout state
- large Stop/Pause affordances
- haptic warning if a required stream fails

## Replay screen

The central canvas is the athlete + equipment, not a chart.

```text
┌──────────────────────────────────────────────┐
│ Session: Longboard · 18:42                  │
│                                              │
│           estimated body skeleton            │
│                  ○                           │
│                 /|\                          │
│                 / \                         │
│          ═════════════════ board             │
│                                              │
│ L foot 38%                    R foot 62%      │
│ board roll -14° · speed 7.8 m/s · HR 154    │
│ pose confidence 0.86 · sync ±3.2 ms          │
├──────────────────────────────────────────────┤
│ pressure │ board │ HR │ events │ uncertainty │
│───────────────●──────────────────────────────│
└──────────────────────────────────────────────┘
```

### Replay interactions
- scrub timeline
- pinch/rotate 3D body view
- choose camera, world, body, or equipment reference frame
- toggle measured vs inferred overlays
- tap any inference to see provenance
- jump to detected events
- compare camera teacher vs wearable-only pose
- display uncertainty as translucent joint volumes / bands

## Pressure view

Each foot is a spatial heatmap with:
- raw sensor locations
- interpolated visualization clearly marked as interpolated
- COP trace
- total load
- left/right contribution
- saturation warning
- zeroing/calibration status

Never visually imply spatial pressure resolution that the hardware does not actually measure.

## Balance view

Do not show a single mysterious "balance score."

Expose:
- left/right load ratio
- within-foot COP
- COP velocity
- board roll/yaw
- pressure→equipment response lag
- stabilization events
- uncertainty/confidence

A future summary score may be added only after its definition and validation are inspectable.

## Compare screen

Two modes:

### Session vs session
Align the same movement primitive across two sessions.

### Cross-sport
Compare universal quantities:
- cardiovascular load
- impact exposure
- unilateral loading
- balance corrections
- movement smoothness
- repetition/oscillation frequency
- recovery

Do not compare arbitrary sport-specific metrics on a fake common scale.

## Lab screen

Contains:
- body scan / skeleton
- device inventory
- equipment profiles
- mount orientation
- sensor calibration receipts
- raw data browser
- experiment flags
- model versions
- data export/delete
- permission status

## Visual language

- dark background is preferred for outdoor readability and dense telemetry
- one accent color per modality, but never rely on color alone
- measured values use solid marks
- inferred values use outlined/translucent marks
- degraded/estimated values carry explicit glyphs/text
- all charts have units
- every model output can reveal confidence and source modalities

## Accessibility

- Dynamic Type
- VoiceOver labels for live metrics
- non-color status indicators
- high-contrast mode
- large touch targets during workout
- reduced-motion option for replay

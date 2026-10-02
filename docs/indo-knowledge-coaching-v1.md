# INDO BOARD Knowledge + Coaching Model v1

Status: research/product specification  
Scope: INDO BOARD roller balance board, not geographic "Indo" content

## Product goal

MotionOS should be useful on the first recorded session.

The system should begin with a population prior learned from official INDO BOARD instruction, public rider footage, forum discussions, and an explicit exercise/trick taxonomy. It should then personalize by measuring how one rider executes the same movement families over time.

The core loop is:

**observe -> classify -> explain -> suggest one experiment -> measure the next attempt -> update the rider model**

The system must separate:

1. directly observed events,
2. estimated physical state,
3. recognized exercise/trick,
4. coaching hypothesis,
5. verified within-rider improvement.

A coaching hypothesis is never silently upgraded into fact.

## Evidence hierarchy

### A. Official instruction

Primary references:

- https://indoboard.com/pages/how-to-ride-an-indo-board
- https://indoboard.com/blogs/balance-board/balance-board-exercises
- https://indoboard.com/blogs/balance-board/roller-board-workout
- https://indoboard.com/pages/roller-tricks
- https://indoboard.com/blogs/balance-board/surf-training-at-home

These provide the cleanest initial vocabulary: centered stance, soft knees, deliberate weight transfer, partial/deep squats, single-leg work, hip rotation, dynamic transitions, cross stepping, surf-stance work, nose/tail loading, and ollie mechanics.

### B. Community practice

Useful hypothesis sources include:

- https://surfing-waves.com/forum/viewtopic.php?f=9&t=26396
- https://www.reddit.com/r/snowboarding/comments/1gc96ed/the_balance_board_can_they_really_help_improve/
- https://www.reddit.com/r/surfing/comments/mz0984
- https://www.reddit.com/r/surfing/comments/188qeg2

These add section balancing, deliberately asymmetric 70/30 loading, switch-oriented practice, deep squats, cross-step repetition, and emphasis on hip-led rather than shoulder-led control.

Community reports are not treated as proof that a drill causes sport-specific improvement.

## Movement families

### Foundation

- mount / assisted mount
- neutral balance hold
- centered micro-corrections
- safe step-off / bailout
- stable dismount

### Weight transfer

- controlled left/right shift
- toe/heel rock
- nose/tail loading
- section balancing
- 70/30 asymmetric hold
- return-to-center control

### Strength under instability

- partial squat hold
- controlled squat
- deep squat
- single-leg unweight
- single-leg squat progression
- loaded upper-body exercise, future

### Reactive control

- faster deliberate transitions
- perturbation/recovery
- overshoot / secondary correction
- edge/stop approach and recovery
- failed recovery / bailout

### Rotation

- hip rotation with quiet shoulders
- body-board relative rotation
- pivots / turn-like movements, future board-tracker milestone

### Footwork and sport transfer

- surf stance
- pop-up to balanced stance
- cross-step
- nose approach
- tail drop
- switch stance
- barrel/crouched stance
- drop-knee-like transitions, future classification

### Tricks

- ollie attempt
- jump / unload
- landing + recovery
- advanced pivots / rail-style tricks after board-state tracking is qualified

## What can be useful before board detection

With body pose alone, MotionOS can already estimate or classify:

- stable vs moving stance
- stance width
- knee flexion
- hip flexion
- trunk angle / trunk excursion
- pelvis lateral motion
- shoulder vs pelvis rotation
- squat phases and depth
- single-leg unweight events
- cross-step candidates
- pop-up candidates
- step-off / bailout candidates
- arm timing and amplitude
- left/right recovery timing proxies

These should be labeled **body-derived** rather than full balance-state measurements.

## What board + roller tracking unlocks

Board/roller state turns the app from a pose coach into a balance coach.

Required state:

- deck center
- deck long-axis / orientation
- deck endpoints
- deck angular velocity
- roller center
- roller axis
- roller position relative to deck
- edge/stop proximity
- floor/contact geometry confidence

Derived behavior:

- center-time fraction
- excursion from center
- intentional vs reactive shifts
- approach velocity to edge/stop
- recovery latency
- overshoot
- secondary correction count
- section-hold error
- squat-induced deck disturbance
- body-to-board phase lag
- left/right recovery symmetry
- landing stabilization after trick attempts

## Cold-start session

A first-time user should not need a large personal dataset.

The initial structured block is intentionally short:

1. 30 s neutral hold
2. 5 controlled shifts each direction
3. 3 partial squats with a short hold
4. 20 s neutral hold

This produces multiple within-session contrasts:

- early vs late hold
- left vs right
- neutral vs intentional perturbation
- upright vs squat
- stable windows vs recovery windows

That is enough to generate a first coaching hypothesis without comparing the rider against a fictitious universal "ideal."

## First-session coaching strategy

Prefer self-comparison in this order:

1. **successful vs unstable moments in the same session**
2. **left vs right in the same movement**
3. **early reps vs late reps**
4. **current session vs previous comparable sessions**
5. population reference distributions only when acquisition and skill context match

This means one session can answer questions such as:

- What happened immediately before my cleanest recovery?
- Do my large corrections begin later than my small successful corrections?
- Does one direction require more secondary corrections?
- Does adding knee flexion reduce torso excursion?
- Does my squat destabilize the board disproportionately?
- When I cross-step, which foot transfer creates the largest disturbance?

## Coaching output contract

The app should usually emit only one primary cue and one drill.

Example:

**Observed**  
Your large rightward recoveries took longer and crossed center twice more often than your clean recoveries.

**Try**  
Start the return earlier and make the second correction smaller.

**Drill**  
Five slow controlled right shifts, pausing briefly at center.

**Evidence**  
Camera + board tracking, medium confidence.

**Retest**  
MotionOS compares the next five reps with the previous five.

This makes coaching falsifiable. The drill either improves the target behavior or it does not.

## Personalization

Do not retrain a large model per rider.

Maintain a compact PersonalBalanceProfile containing:

- neutral stance distribution
- normal knee-flexion range
- normal trunk/pelvis relationship
- correction latency distribution
- overshoot distribution
- left/right recovery distributions
- preferred stance / orientation
- skill-specific baselines
- camera geometry history
- confidence per trait
- number of comparable observations

Population priors should shrink quickly as reliable personal observations accumulate.

Personalization should also learn which cues work. If a cue is followed by a consistent measurable improvement across repetitions, increase its rider-specific utility. If not, reduce it and try a different intervention.

## Real-time behavior architecture

The runtime should be hierarchical rather than one giant action classifier:

**Frame observations**  
pose + board + roller + Watch

-> **physical state**  
body angles, board state, velocities, confidence

-> **primitive events**  
shift, squat, step, unload, rotation, edge approach, recovery

-> **behavior grammar**  
neutral hold, squat, cross-step, nose press, ollie attempt

-> **quality metrics**  
timing, smoothness, symmetry, overshoot, repeatability

-> **coach**  
one evidence-linked cue + drill

This hierarchy makes errors inspectable and allows simple deterministic logic to coexist with learned sequence models.

## Training data strategy

Public video is primarily for:

- behavior vocabulary
- viewpoint diversity
- pose robustness
- board/roller detector robustness
- weak action labels
- difficult occlusions
- negative examples
- sequence pretraining

It should not establish personalized biomechanics or causal coaching claims.

User data is primarily for:

- calibration
- longitudinal comparison
- rider-specific movement residuals
- cue effectiveness
- personal best / ghost comparison

## Data flywheel

Each user session can generate:

- raw video when the user has consented to retain it
- derived pose
- derived board/roller state
- behavior segments
- confidence
- suggested cue
- drill performed
- before/after metric delta
- user feedback such as "helpful", "wrong", or "not understood"

The highest-value training examples are not merely videos. They are:

**state -> cue -> controlled retry -> measured response**

That structure lets MotionOS learn which feedback is useful rather than simply learning what movements look like.

## Near-term implementation order

1. Keep the Watch-guided camera + stable-stance start path small and reliable.
2. Use the machine-readable skill taxonomy as the product vocabulary.
3. Add board/roller tracking.
4. Emit the first deterministic metrics: center time, excursion, recovery time, overshoot, correction count, squat disturbance.
5. Connect those metrics to the conservative coaching rule engine.
6. Show one cue and one drill after a session.
7. Add an immediate "Try again" block so one session becomes a mini experiment.
8. Record before/after response and update PersonalBalanceProfile.
9. Only then add learned sequence classification where it beats the deterministic baseline.

The desired first beta is not "AI understands every trick." It is:

**MotionOS sees what I did, identifies a small number of meaningful balance events, gives me one understandable thing to try, and can tell whether that change helped on the next attempt.**

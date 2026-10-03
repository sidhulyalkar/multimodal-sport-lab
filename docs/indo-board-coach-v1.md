# Indo Board Coach v1: camera-first product plan

Status: product/engineering design for the MotionOS beta path  
Primary beta user: a single rider repeatedly recording comparable Indo Board sessions  
Product principle: **camera-first, sensor-enhanced, evidence-aware**

## 1. Product promise

A rider should be able to put an iPhone on a tripod, step onto the Indo Board, and get useful feedback without manually calibrating a camera, editing video, placing landmarks, or understanding sensor diagnostics.

The app should answer four questions after every session:

1. **What happened?** A short replay with the important balance events marked.
2. **What changed?** A small set of comparable metrics versus the rider's own recent baseline.
3. **Why might it have happened?** One or two mechanically interpretable observations with explicit confidence.
4. **What should I try next?** One concrete technique cue and one short drill.

The UI should expose confidence and provenance rather than pretending that every quantity is directly measured.

## 2. Camera-first capture contract

The core Indo Board experience must work with iPhone video alone. Apple Watch, equipment pods, pressure insoles, and a second camera should increase confidence or unlock extra measurements, not gate the session.

### Setup flow

Target interaction budget: one tap after the phone is physically placed.

1. Open Indo Board mode.
2. Camera preview starts automatically after permission is available.
3. Vision runs during preview and evaluates framing continuously.
4. The app shows one setup instruction at a time, for example:
   - move the phone farther back
   - move closer
   - shift left/right
   - leave more room below the feet
   - leave more headroom
   - improve lighting / face the camera more clearly
5. A safe-frame guide changes state as setup improves.
6. When framing is stable for several seconds, the app announces **Ready**.
7. The rider starts immediately or enables a short hands-free countdown.
8. During recording the UI should avoid asking for interaction.

A user may always choose **Record Anyway**. Setup guidance is an aid, not a brittle gate.

### What the preview must verify

Minimum viable checks:

- enough body joints are visible with usable confidence
- head / upper body are represented
- both foot regions are represented
- subject is neither too small nor clipping the frame
- lateral movement margin exists
- space remains below the feet for board / roller tracking
- headroom remains for arm recovery movements

Future checks:

- board/deck visible
- roller visible
- floor plane is recoverable
- camera is sufficiently stable
- exposure / shutter conditions are usable for motion
- camera viewpoint is within the supported range
- expected movement region is not occluded

## 3. One-time room memory

After a successful session, store a non-sensitive setup profile locally:

- camera model / lens
- approximate framing region
- floor geometry estimate
- board movement region
- preferred tripod position description if user enters one
- confidence statistics from successful captures

On the next session, revalidate rather than recalibrate from scratch. If the geometry still matches, show a quick "same setup detected" state.

## 4. Short calibration ritual

Avoid calibration targets for the normal consumer flow.

Use a 5–10 second motion ritual:

1. neutral stance
2. gentle controlled shift left
3. gentle controlled shift right
4. return to neutral

Optional extension: one comfortable squat.

This gives the model a short labeled sequence for body scale, board axis, likely roller direction, lateral range, response latency, and the rider's own neutral posture. A printed target or small board fiducial can remain an engineering/debug option, never a normal-user requirement.

## 5. State model

### Direct observations

Camera:

- 2D body keypoints + confidence
- Vision 3D root-relative body pose
- camera intrinsics when available
- image-space person bounds
- future board polygon / keypoints
- future roller center / axis
- video PTS and frame-health evidence

Optional Watch:

- wrist linear acceleration
- wrist angular velocity / attitude-derived features
- heart rate / workout context when authorized
- haptic/user-control events
- synchronization evidence

### Estimated physical state

Only publish these when the supporting measurements are adequate:

- pelvis trajectory
- center-of-mass proxy or model estimate
- stance width
- knee flexion
- trunk angle
- board angle and angular velocity
- roller translation
- support region
- body-board relative motion
- correction onset and recovery state
- arm counterbalance timing

Every estimated state should carry confidence/provenance.

### Events

- mounted / dismounted
- neutral hold
- deliberate tilt
- recovery
- edge approach / edge contact when detectable
- step-off / bailout
- squat
- arm reach / rapid counterbalance
- loss and reacquisition of visual tracking

## 6. Metrics that can become meaningful to riders

Prioritize interpretable longitudinal metrics over a single opaque score.

### Stability

- stable-time fraction
- lateral excursion
- correction frequency
- correction magnitude
- movement smoothness / jerk
- time spent near the usable center region

### Recovery

- perturbation-to-recovery time
- peak deviation before recovery
- number of secondary corrections
- overshoot after correction
- recovery consistency across repetitions

### Coordination

- board-to-pelvis phase relationship
- pelvis-to-shoulder timing
- arm onset relative to destabilization
- arm motion magnitude relative to successful recovery
- left/right recovery differences

### Technique

- stance width
- knee flexion distribution
- trunk flexion / stacking proxy
- squat depth and stability
- lateral movement symmetry

### Training load

Video should not pretend to measure physiology. If Watch data is available, it may add session duration, heart-rate context, and wrist-specific movement load.

## 7. Coaching model

Do not convert every detected difference into a correction. The coach should find the smallest actionable change with the strongest evidence.

Each cue should have this shape:

**Observation -> likely mechanism -> experiment**

Examples:

- "Your largest recoveries start after the board has already moved far from center. Try a smaller knee/hip correction earlier."
- "You recover the first tilt, then make two large counter-corrections. Try reducing the second correction rather than fighting all the way back at once."
- "Your shoulders move before your hips on several unstable repetitions. Try initiating the correction through knees and hips."
- "Your right-side recoveries are consistently slower than your left in this session. Try five controlled right-side recoveries at a slower tempo."

Arm movement must be interpreted contextually. Large arm motion is not automatically bad. The model should distinguish useful early counterbalance from late, high-amplitude recovery motion.

The app should never infer an injury, diagnose weakness, or prescribe rehabilitation from ordinary camera evidence alone. It can say that a movement pattern suggests a training experiment worth testing.

## 8. Drill library

Start with a small set whose intent is measurable:

- neutral balance hold
- slow left/right controlled shifts
- five tilt-and-recover repetitions
- partial squat hold
- slow controlled squats
- deliberate arm-counterbalance reaches
- quiet-upper-body challenge
- eyes-forward / external-focus challenge

For each drill define:

- target behavior
- measurable success criteria
- minimum evidence needed
- contraindication / stop language where appropriate
- progression and regression
- which metrics should improve if the drill is working

Personalization should select drills from observed patterns rather than assigning a permanent "type" to the athlete.

## 9. What Apple Watch is for

The Watch should not be required for Indo Board v1.

Its strongest roles are:

1. **Remote control:** start/stop without walking back to the phone.
2. **Haptic interaction:** countdown, block changes, sync cues, completion.
3. **Occlusion-resistant wrist dynamics:** arm timing and angular velocity when vision is ambiguous.
4. **Clock/synchronization evidence:** an independent sensor stream for multimodal alignment.
5. **Physiology:** heart rate and workout context where authorized.
6. **Continuity:** useful evidence during brief camera tracking degradation.

This makes the architecture resilient: camera provides the global movement story; Watch adds a high-rate local wrist stream and user interface.

## 10. Public-video learning program

Public internet video can accelerate robustness, but it should not be treated as unquestioned coaching ground truth.

### Dataset layers

**A. Discovery catalog**

Store:

- canonical public URL
- source platform
- creator/channel
- title/date when available
- search query / discovery provenance
- license or permission status
- segment timestamps
- processing status
- hashes of derived artifacts

**B. Derived movement evidence**

Process allowed material into:

- 2D pose tracks
- optional 3D pose estimates
- board / roller tracks
- motion embeddings
- camera/viewpoint descriptors
- balance-event candidates
- quality / occlusion labels

**C. Coaching labels**

Keep these separate from raw movement observations:

- explicitly instructional / demonstration
- beginner practice
- advanced/trick
- fall/recovery
- uncertain

Do not assume that a popular or polished clip demonstrates ideal technique.

### Acquisition policy

Prefer:

1. official Indo Board instructional material
2. Creative Commons or otherwise explicitly licensed material
3. videos for which the creator grants permission
4. opt-in user uploads

Use official platform APIs where available. Do not make the product depend on bypassing access controls or maintaining a brittle downloader against platform changes. If local retention is not licensed, store the URL/provenance and only the derived artifacts permitted by the acquisition path.

### What public video is good for

- viewpoint diversity
- clothing/background diversity
- body-size diversity
- occlusion robustness
- board/roller detector pretraining
- event taxonomy discovery
- representation learning
- hard-negative mining
- discovering candidate movement strategies

### What it is not sufficient for

- causal claims about which technique is best
- muscle activation ground truth
- injury risk prediction
- personalized biomechanics
- verified skill level unless the source provides a trustworthy label

## 11. Modeling sequence

### Stage A: deterministic baseline

Before training a large model:

- Vision pose
- board/roller detector
- smoothing + confidence gates
- geometry-derived features
- event detector
- interpretable metrics
- rule-based cue selection

This makes errors inspectable.

### Stage B: sequence model

Train a temporal model over:

- body joints
- board/roller state
- derivatives
- confidence masks
- optional wrist IMU

Targets:

- event segmentation
- stable/recovery phase
- next-state prediction
- recovery quality
- representation embedding

### Stage C: personalized residual model

Use the rider's own sessions to learn the difference between population priors and their repeated movement signature. The main comparison should become "you versus your own prior comparable attempts," not an arbitrary global norm.

## 12. Beta milestone sequence

### M2.0: frictionless camera setup

Implemented on feature branch:

- Vision 2D framing evidence alongside existing 3D pose
- pose analysis during preview, not only during recording
- deterministic camera-framing assessment
- safe-frame visual state
- one actionable setup instruction
- explicit Ready state
- Record Anyway escape hatch

### M2.1: hands-free session start

- require Ready to be stable for a short interval
- optional 5-second countdown
- spoken / haptic countdown
- auto-start capture
- Watch remote start if available
- no screen touches after mounting

### M2.2: board state

- collect board/roller annotations from beta recordings
- prototype detector/tracker
- estimate deck angle + roller displacement
- quantify detector confidence and failure modes

### M2.3: post-session balance report

- trim mount/dismount automatically
- segment protocol blocks
- stability/recovery/coordination metrics
- confidence per metric
- one technique cue + one drill
- replay timeline with marked events

### M2.4: longitudinal progress

- baseline from repeated comparable sessions
- personal-best / ghost overlay
- trend view
- separate improvement from capture-quality changes

### M2.5: public-video corpus

- source catalog + rights/provenance metadata
- pose/board extraction workers
- derived-feature store
- event review queue
- model evaluation split by creator/viewpoint so the benchmark cannot memorize a channel

## 13. Beta success criteria

The first real win is not a perfect balance score. It is this loop:

**place phone -> receive clear setup guidance -> record without touching phone -> get a trustworthy replay -> understand one thing to change -> repeat and see whether it improved**

For the first ten beta sessions, log every moment where the rider has to stop and think about the app. Those are product defects until proven otherwise.

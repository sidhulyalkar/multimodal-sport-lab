# INDO BOARD Computer-Vision Stack v1

Goal: maximize learning speed without making the shipping iPhone app depend on a heavyweight or licensing-fragile research stack.

## Production principle

Use large open-source models as **teachers, annotators, and evaluation tools**.

Ship the smallest stack that reproduces the useful state variables on device.

## Runtime target

### Human

- Apple Vision 2D pose
- Apple Vision 3D root-relative pose
- confidence / occlusion masks
- Watch IMU as an independent wrist channel

### Equipment

Train a small CoreML-compatible detector or segmenter for:

- INDO BOARD deck
- roller
- deck endpoints / corners
- roller endpoints / centerline

Then derive geometry deterministically.

The first shipping version does not need a general foundation model on every frame.

## Offline research stack

### Grounded-SAM-2

Repository: IDEA-Research/Grounded-SAM-2  
Observed license: Apache-2.0

Use for:

- prompting "balance board", "wooden deck", "roller"
- rapidly bootstrapping masks on public/authorized footage
- discovering hard negatives
- generating candidate annotations for human review

Do not treat zero-shot masks as ground truth.

### SAM 2

Repository: facebookresearch/sam2  
Observed license: Apache-2.0

Use for:

- propagating reviewed deck/roller masks through clips
- accelerating annotation of user beta sessions
- testing how much segmentation quality is needed before geometry becomes stable

### CoTracker

Repository: facebookresearch/co-tracker

Use for:

- deck-corner trajectories
- roller endpoint trajectories
- floor reference points
- recovering short gaps between detector frames

License metadata should be reviewed before any product dependency.

### MMPose

Repository: open-mmlab/mmpose  
Observed license: Apache-2.0

Use as an offline comparison baseline for:

- 2D whole-body pose
- joint confidence
- viewpoint failure analysis
- validating whether Apple Vision misses movement patterns important to INDO BOARD

Do not add it to the iPhone app unless it clearly improves downstream metrics.

### VGGT

Repository: facebookresearch/vggt

Use as an offline geometry teacher for:

- camera pose hypotheses
- scene geometry
- floor reconstruction
- multi-frame consistency checks

This is research infrastructure, not a realtime dependency.

### MoGe

Repository: microsoft/MoGe

Use when a lighter single-image / monocular geometry hypothesis is enough:

- floor/depth priors
- scale-free scene geometry
- difficult camera placements

### Ultralytics

Repository: ultralytics/ultralytics  
Observed license: AGPL-3.0

Useful for fast detector experiments, but avoid making the shipping MotionOS product depend on it without an explicit licensing decision.

## Efficient board/roller pipeline

1. Manually review 100 to 300 representative frames from beta + permitted public clips.
2. Use Grounded-SAM-2 / SAM 2 to propose deck and roller masks.
3. Correct masks rather than drawing every annotation from scratch.
4. Use CoTracker to propagate deck corners / roller endpoints.
5. Train a small dedicated detector/segmenter.
6. Export to CoreML.
7. Benchmark only downstream state quality:
   - deck-center error
   - deck-angle error
   - roller-center error
   - edge/stop proximity error
   - recovery-event timing error
8. Reject a visually impressive model if those quantities do not improve.

## State estimator

Per frame:

- body joints + confidence
- deck geometry + confidence
- roller geometry + confidence
- Watch wrist state when present

Temporal filter:

- smooth geometry
- preserve sudden genuine corrections
- explicitly track missing/occluded evidence
- never fill long gaps without marking uncertainty

Derived state:

- deck center and orientation
- roller position relative to deck
- athlete pelvis relative to deck
- knee / hip strategy
- arm strategy
- correction onset
- peak deviation
- return-to-center time
- overshoot
- secondary correction count

## Behavior recognition

Do not begin with a monolithic action-recognition network.

Use a grammar:

- **primitives:** squat, shift, step, unload, rotation, jump, recovery
- **state:** centered, moving, near edge, unstable, recovering
- **sequence:** cross-step, nose press, dynamic transfer, ollie attempt
- **quality:** smoothness, timing, symmetry, repeatability

A small temporal model can later replace parts of the grammar only when it beats the inspectable baseline on creator/viewpoint-separated evaluation data.

## Deployment gate

A model earns a place in the app only if it improves at least one user-facing measurement enough to change coaching reliability.

"Better segmentation" by itself is not a product result.

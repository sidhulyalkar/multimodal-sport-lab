# MotionOS M0-B Field Protocols

## Protocol P0 — desk capture
Hardware: iPhone + Watch.

1. Start MotionOS calibration session.
2. Keep both devices stationary for 30 s.
3. Rotate wrist through three deliberate axes.
4. Perform three synchronization impulses.
5. Walk for 2 min.
6. Background the phone app.
7. Lock phone.
8. Return and stop from Watch.
9. Verify transferred journal, sequence continuity, and replay.

## Protocol P1 — equipment pod bench
Hardware: iPhone + Watch + equipment pod.

1. Mark pod axes physically.
2. Mount pod rigidly to a board.
3. Record level board for 30 s.
4. Tilt board to repeatable approximate angles.
5. Rotate board left/right.
6. Perform shared impulse visible in Watch and pod.
7. Walk out of BLE range while pod continues logging.
8. Reconnect and recover data.
9. Compare stream vs recovered local log.

## Protocol P2 — first calibration ride
Hardware: Watch + pod + phone camera.

Use a low-risk flat area.

Blocks:
- 30 s quiet stance
- 10 push/coast cycles
- 10 left carves
- 10 right carves
- 10 front/rear weight shifts
- 5 controlled stops
- 5 deliberate minor balance corrections
- 3 sync impulses at start and end

Keep blocks separated by a clear neutral stance to simplify labeling.

## Protocol P3 — bilateral feet
Add insoles only after P2 is stable.

Repeat P2 and add:
- heel/toe shifts
- medial/lateral shifts
- single-foot board loading while stationary
- repeated stance transitions

## Protocol P4 — repeatability
Repeat the same short protocol on at least three different days.

The objective is not model performance yet. It is to quantify:
- calibration repeatability
- sensor placement sensitivity
- clock stability
- mount reproducibility
- pressure zero drift
- session-to-session feature stability

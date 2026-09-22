# MotionOS M0-B Hardware BOM

This BOM is intentionally staged. Buy only hardware that unlocks the next evidence gate.

## Buy now

### 1. One MbientLab MetaMotionS (MMS)
Purpose: first swappable equipment pod.

Why:
- BLE 5
- open Swift, Python, JavaScript, C/C++ APIs
- synchronized timestamps
- 512 MB onboard NAND logging
- accelerometer, gyroscope, magnetometer, barometer
- raw streaming up to 100 Hz and higher-rate onboard logging
- small rechargeable package

Initial role:
- longboard/skateboard/RipStik equipment frame
- later doubles as pelvis/torso sensor

Do not buy the MMS+ for M0 unless haptic feedback on the pod is immediately useful. Its vibration motor can perturb the magnetometer.

### 2. Mounting development kit
Use inexpensive consumables first:
- 3M Dual Lock SJ3550/SJ3560 or equivalent
- thin VHB adhesive pads
- small hook-and-loop straps
- reusable zip ties
- small polycarbonate/TPU enclosure
- painter's tape for temporary axis marks
- printed X/Y/Z mount labels

The first mount is deliberately ugly but must be rigid and repeatable. Pretty quarter-turn hardware comes only after we know the preferred sensor orientation and mounting location.

### 3. Phone tripod / clamp
Calibration sessions need repeatable, stable video. Any rigid phone tripod is acceptable.

### 4. Floor/board calibration markers
High-contrast removable tape or AprilTag/ArUco-style printed fiducials are useful for camera-scale and equipment-frame experiments.

## Optional cheap parallel pod

A WitMotion WT901SDCL-BT50 is useful as a low-cost independent logger because it combines BLE 5, SD-card recording, 9-axis motion, USB-C charging, and configurable sampling up to 200 Hz. It is not the canonical M0 pod because the MMS has a cleaner open Swift/Python development path.

## Do not buy yet

### Research pressure insoles
Do not commit several thousand dollars until raw API access, size, synchronization behavior, and export rights are confirmed.

Candidate classes:
- Moticon OpenGo: 16 pressure channels + 6-axis IMU per foot, professional research stack.
- ORPHE INSOLE beta: 6 pressure sensors + 6-axis IMU per foot, 100/200 Hz, raw-data developer libraries.
- custom sparse pressure insole: FSR/piezoresistive nodes + 6-axis IMU + BLE.

The adapter contract is already frozen, so any of these can be substituted without changing replay/ML code.

## Hardware selection gates

A sensor must earn entry into MotionOS by passing:
1. raw-data access
2. documented units/ranges
3. device timestamps or recoverable sample timing
4. stable identity
5. repeatable axis orientation
6. >=30-minute continuous capture
7. disconnect/reconnect behavior
8. export rights compatible with analysis
9. acceptable comfort for its sport
10. deterministic replay through the MotionOS event contract

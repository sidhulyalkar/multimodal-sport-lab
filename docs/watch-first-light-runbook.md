# Apple Watch first-light runbook

This is a **non-qualifying** physical smoke test. Its job is to isolate install,
companion communication, Watch sensing, journal sealing, and transfer before
running P0-A or P0-B.

## 0. Record provenance

Before the run, record:

- repository commit / PR under test;
- MotionOS app version + build;
- iPhone model + OS;
- Watch model + OS;
- which wrist is wearing the Watch.

Do not reuse this smoke run as P0 qualification evidence.

## 1. Companion installation gate

Build/run `MotionOS-iOS` on the physical iPhone. The built iPhone product must
contain the modern Watch app under `PlugIns/MotionOS.app`.

CI runs `verify_companion_bundle.sh` to assert the bundle IDs,
`WKCompanionAppBundleIdentifier`, `WKApplication=true`, and
`WKRunsIndependentlyOfCompanionApp=false`.

Pass when:

- MotionOS remains present in the Watch app launcher;
- MotionOS opens on the Watch;
- the Watch readiness screen remains usable after Xcode detaches.

If the icon disappears, capture the Xcode install log before reinstalling.

## 2. Presence-handshake gate

Open MotionOS on both devices.

Watch should show one of:

- **Connected**: immediate WatchConnectivity messaging is available;
- **Handshake seen**: the iPhone's latest-state presence packet was received;
- **Companion ready**: the system reports the iPhone companion installed.

iPhone should show:

- Watch paired;
- Watch app installed or **handshake confirmed**;
- a Watch handshake version/build row once `watch_presence_v1` arrives.

A valid MotionOS presence packet is operator/control-plane evidence only. It is
not raw measurement evidence.

## 3. Watch-local Sensor Check

Use **Run Sensor Check** on the Watch before testing phone-launched workouts.

Suggested 60–90 second sequence:

1. 10 s stationary;
2. slow roll, pitch, and yaw wrist rotations;
3. three deliberate impulses;
4. 20–30 s walking;
5. 10 s stationary;
6. stop from the Watch.

During capture, confirm:

- elapsed time advances;
- IMU sample count continuously rises;
- recent motion rate warms toward the requested 50 Hz;
- LIVE stays green after samples begin;
- max-gap is visible and non-monotonic timing does not appear;
- heart rate appears when Health read access is available.

No single smoke-run threshold is a P0 pass criterion.

## 4. Journal shutdown gate

Stop from the Watch and observe:

`FINISHING → SAFE → QUEUED → VERIFYING → VERIFIED`

The shutdown boundary must:

- stop admitting new events before journal close;
- preserve appends already admitted;
- avoid a transient false `failed` state from late callbacks;
- keep the Watch journal locally safe if transfer is unavailable.

Do not begin another capture while an unverified journal is waiting for retry.

## 5. iPhone recovery gate

When the phone is available, confirm:

- the received Watch journal is copied out of WatchConnectivity's temporary URL;
- SHA-256 and byte count are recomputed;
- the iPhone displays the recovered session;
- the Watch reaches **Verified on iPhone** only after the matching receipt.

An identical retransmission should be idempotent. Different bytes for the same
session ID must fail closed.

Export/share the recovered `watch.jsonl` and run the deliberately
non-qualifying smoke analyzer:

```bash
bash scripts/process_watch_smoke.sh /path/to/watch.jsonl data/watch-smoke 60 --require-hr
```

A passing `watch-smoke-v1` report confirms only that the short Watch capture
had coherent IMU timing/sequence continuity and, with `--require-hr`, at least
one integrity-clean HR event. It must never be reported as P0.

## 6. Phone-launched smoke

Only after the Watch-local Sensor Check works:

1. open MotionOS on both devices;
2. authorize HealthKit on iPhone if needed;
3. start the Watch capture from the iPhone;
4. confirm iPhone state reaches `waitingForMirror` then `running`;
5. confirm the Watch reaches `RECORDING`;
6. repeat a short motion sequence;
7. stop on Watch;
8. verify journal recovery.

This isolates HealthKit launch/mirroring from the underlying Watch sensor path.

## Failure localization

| Observation | Likely boundary |
| --- | --- |
| Watch icon disappears after install | companion packaging / device install |
| Watch opens but no handshake on either side | WatchConnectivity activation / companion association |
| Handshake works but Sensor Check will not start | HealthKit authorization / workout lifecycle |
| Sensor Check starts but IMU count stays flat | Core Motion acquisition |
| IMU works but HR never appears | HealthKit heart-rate read path or permission |
| Stop remains in FINISHING | workout completion / journal close |
| Journal is SAFE but never QUEUED | WatchConnectivity activation |
| QUEUED/SENT but phone has no recovered journal | file transfer / phone inbox |
| Hash receipt never returns | verification / acknowledgment path |
| Phone launch fails but local Sensor Check passes | HealthKit iPhone→Watch launch/mirroring |

After this smoke test is clean, proceed to the real P0-A runbook.

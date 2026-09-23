import test from "node:test";
import assert from "node:assert/strict";
import {
  adaptReplayLabPayload,
  balanceAsymmetry,
  buildPressureCells,
  deriveCaptureGate,
  formatSync,
  maxSyncResidualMs,
  nearestFrame,
  normalizedCopToDisplay,
  normalizedPressure,
  projectRootRelativePose,
  replayDeviceState
} from "../model.mjs";

test("capture gate blocks required missing or unsynchronized devices", () => {
  const result = deriveCaptureGate(
    [
      { id: "watch", state: "ready" },
      { id: "pod", state: "unsynchronized" }
    ],
    ["watch", "pod", "left"]
  );
  assert.equal(result.canStart, false);
  assert.deepEqual(result.blockers, [
    { id: "pod", reason: "unsynchronized" },
    { id: "left", reason: "missing" }
  ]);
});

test("degraded device is visible but does not silently block capture", () => {
  const result = deriveCaptureGate(
    [{ id: "watch", state: "degraded" }],
    ["watch"]
  );
  assert.equal(result.canStart, true);
});

test("balance asymmetry is bounded for nonnegative loads", () => {
  assert.equal(balanceAsymmetry(50, 50), 0);
  assert.equal(balanceAsymmetry(0, 10), 1);
  assert.equal(balanceAsymmetry(10, 0), -1);
});

test("nearest frame selects closest replay sample", () => {
  const frames = [{ t: 0 }, { t: 100 }, { t: 200 }];
  assert.equal(nearestFrame(frames, 149).t, 100);
  assert.equal(nearestFrame(frames, 151).t, 200);
});

test("pressure normalization preserves shape and range", () => {
  const normalized = normalizedPressure([0, 5, 10]);
  assert.deepEqual(normalized, [0, 0.5, 1]);
  assert.equal(buildPressureCells(new Array(16).fill(1), "left").length, 16);
});

test("sync formatting communicates precision", () => {
  assert.equal(formatSync(0.4), "sub-ms");
  assert.equal(formatSync(3.24), "±3.2 ms");
  assert.equal(formatSync(18.3), "±18 ms");
});


test("generated replay adapter preserves missing frame data as null", () => {
  const adapted = adaptReplayLabPayload({
    schema_version: "motionos.replay-lab.v1",
    run: { run_id: "r1", sport: "longboard" },
    devices: [
      {
        id: "watch",
        role: "watch",
        session_id: "watch-1",
        qualification: { state: "qualified" },
        clock: { reference: true, residual_rms_ms: 0 },
        streams: {
          "/body/watch/imu": { effective_hz: 50 }
        },
        gap_count: 0
      },
      {
        id: "equipment",
        role: "equipment",
        session_id: "pod-1",
        qualification: { state: "capture_only" },
        clock: { reference: false, residual_rms_ms: 2.5 },
        streams: {},
        gap_count: 1
      }
    ],
    frames: [
      {
        t_ms: 0,
        watch: { heart_rate_bpm: null },
        equipment: {
          accel_magnitude_m_s2: null,
          gyro_magnitude_rad_s: null
        },
        left_foot: { pressure: null },
        right_foot: { pressure: null },
        camera: { pose3d: null },
        derived: { left_load_fraction: null },
        active_gap_streams: ["equipment:/equipment/imu/accel"],
        streams_present: []
      }
    ],
    gaps: []
  });

  assert.equal(adapted.frames[0].hr, null);
  assert.equal(adapted.frames[0].pressureL, null);
  assert.equal(adapted.frames[0].leftLoad, null);
  assert.equal(adapted.frames[0].boardAccel, null);
  assert.deepEqual(
    adapted.frames[0].activeGaps,
    ["equipment:/equipment/imu/accel"]
  );
  assert.equal(adapted.devices[0].state, "ready");
  assert.equal(adapted.devices[1].state, "degraded");
  assert.equal(adapted.syncMs, 2.5);
});

test("root-relative pose projection is visualization-only and bounded", () => {
  const projected = projectRootRelativePose({
    root: [0, 0, 0],
    head: [0, 1.8, 0],
    leftHand: [-0.5, 1.1, 0.2],
    rightHand: [0.5, 1.1, -0.2]
  });
  for (const point of Object.values(projected)) {
    assert.ok(point[0] >= 15 && point[0] <= 85);
    assert.ok(point[1] >= 13 && point[1] <= 95);
  }
});

test("normalized CoP display conversion does not relabel source units", () => {
  assert.deepEqual(normalizedCopToDisplay([0, 0]), [50, 68]);
  assert.equal(normalizedCopToDisplay(null), null);
});

test("device and sync summaries retain qualification distinctions", () => {
  assert.equal(replayDeviceState({ state: "qualified" }), "ready");
  assert.equal(replayDeviceState({ state: "capture_only" }), "degraded");
  assert.equal(replayDeviceState({ state: "failed" }), "missing");
  assert.equal(
    maxSyncResidualMs([
      { clock: { reference: true, residual_rms_ms: 0 } },
      { clock: { reference: false, residual_rms_ms: 3.4 } }
    ]),
    3.4
  );
});


test("generated replay retains registered pose alongside raw Vision evidence", () => {
  const adapted = adaptReplayLabPayload({
    schema_version: "motionos.replay-lab.v1",
    run: { run_id: "r1", sport: "longboard" },
    devices: [],
    frames: [
      {
        t_ms: 0,
        watch: { heart_rate_bpm: null },
        equipment: {
          accel_magnitude_m_s2: null,
          gyro_magnitude_rad_s: null
        },
        left_foot: { pressure: null },
        right_foot: { pressure: null },
        camera: {
          pose3d: {
            joints_root_relative_m: {
              root: [0, 0, 0]
            },
            registered_pose: {
              joints_body_model_m: {
                root: [1, 2, 3]
              },
              coordinate_frame: "personalized_body_model",
              derived: true
            }
          }
        },
        derived: { left_load_fraction: null },
        active_gap_streams: [],
        streams_present: []
      }
    ],
    gaps: []
  });

  assert.deepEqual(
    adapted.frames[0].pose.registered_pose.joints_body_model_m.root,
    [1, 2, 3]
  );
  assert.deepEqual(
    adapted.frames[0].pose.joints_root_relative_m.root,
    [0, 0, 0]
  );
});

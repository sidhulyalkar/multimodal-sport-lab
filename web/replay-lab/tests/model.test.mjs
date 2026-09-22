import test from "node:test";
import assert from "node:assert/strict";
import {
  balanceAsymmetry,
  buildPressureCells,
  deriveCaptureGate,
  formatSync,
  nearestFrame,
  normalizedPressure
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

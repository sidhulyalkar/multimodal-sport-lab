export const DEVICE_STATES = Object.freeze({
  ready: { label: "Ready", severity: 0 },
  connecting: { label: "Connecting", severity: 1 },
  degraded: { label: "Degraded", severity: 2 },
  missing: { label: "Missing", severity: 3 },
  unsynchronized: { label: "Unsynchronized", severity: 3 },
  lowBattery: { label: "Low battery", severity: 2 }
});

export function deriveCaptureGate(devices, requiredIds) {
  const byId = new Map(devices.map((device) => [device.id, device]));
  const blockers = [];
  for (const id of requiredIds) {
    const device = byId.get(id);
    if (!device) {
      blockers.push({ id, reason: "missing" });
      continue;
    }
    if (["missing", "unsynchronized"].includes(device.state)) {
      blockers.push({ id, reason: device.state });
    }
  }
  return {
    canStart: blockers.length === 0,
    blockers
  };
}

export function balanceAsymmetry(left, right) {
  const total = left + right;
  if (total <= 0) return 0;
  return (right - left) / total;
}

export function nearestFrame(frames, timeMs) {
  if (!frames.length) return null;
  return frames.reduce((best, frame) =>
    Math.abs(frame.t - timeMs) < Math.abs(best.t - timeMs) ? frame : best
  );
}

export function buildPressureCells(values, side) {
  const anchors = [
    [50, 10], [30, 22], [50, 24], [70, 22],
    [28, 40], [47, 39], [66, 40], [35, 57],
    [57, 57], [42, 72], [58, 72], [44, 88],
    [58, 88], [45, 105], [58, 105], [51, 122]
  ];
  return anchors.map(([x, y], index) => ({
    x: side === "left" ? 100 - x : x,
    y,
    value: Number(values[index] ?? 0)
  }));
}

export function normalizedPressure(values) {
  const max = Math.max(1, ...values.map(Number));
  return values.map((value) => Math.max(0, Math.min(1, Number(value) / max)));
}

export function formatSync(ms) {
  const magnitude = Math.abs(ms);
  if (magnitude < 1) return "sub-ms";
  if (magnitude < 10) return `±${magnitude.toFixed(1)} ms`;
  return `±${Math.round(magnitude)} ms`;
}

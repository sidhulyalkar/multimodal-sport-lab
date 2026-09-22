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
  const value = Number(ms);
  if (!Number.isFinite(value)) return "sync n/a";
  const magnitude = Math.abs(value);
  if (magnitude < 1) return "sub-ms";
  if (magnitude < 10) return `±${magnitude.toFixed(1)} ms`;
  return `±${Math.round(magnitude)} ms`;
}

export function replayDeviceState(qualification) {
  const state = qualification?.state ?? "missing";
  if (state === "qualified") return "ready";
  if (["capture_only", "reported"].includes(state)) return "degraded";
  return "missing";
}

export function primaryStreamRate(streams = {}) {
  const rates = Object.values(streams)
    .map((stream) => Number(stream?.effective_hz))
    .filter((value) => Number.isFinite(value) && value > 0);
  if (!rates.length) return null;
  return Math.max(...rates);
}

export function maxSyncResidualMs(devices = []) {
  const values = devices
    .filter((device) => !device.clock?.reference)
    .map((device) => Number(device.clock?.residual_rms_ms))
    .filter((value) => Number.isFinite(value));
  return values.length ? Math.max(...values) : 0;
}

export function normalizedCopToDisplay(cop) {
  if (!Array.isArray(cop) || cop.length !== 2) return null;
  const x = Number(cop[0]);
  const y = Number(cop[1]);
  if (!Number.isFinite(x) || !Number.isFinite(y)) return null;
  return [50 + x * 70, 68 - y * 105];
}

export function projectRootRelativePose(joints = {}) {
  const entries = Object.entries(joints)
    .map(([name, point]) => [
      name,
      Array.isArray(point) ? point.map(Number) : []
    ])
    .filter(([, point]) =>
      point.length >= 2
      && Number.isFinite(point[0])
      && Number.isFinite(point[1])
    );

  if (!entries.length) return {};

  const xs = entries.map(([, point]) => point[0]);
  const ys = entries.map(([, point]) => point[1]);
  const minX = Math.min(...xs);
  const maxX = Math.max(...xs);
  const minY = Math.min(...ys);
  const maxY = Math.max(...ys);
  const spanX = Math.max(1e-9, maxX - minX);
  const spanY = Math.max(1e-9, maxY - minY);

  return Object.fromEntries(entries.map(([name, point]) => [
    name,
    [
      15 + ((point[0] - minX) / spanX) * 70,
      95 - ((point[1] - minY) / spanY) * 82
    ]
  ]));
}

export function adaptReplayLabPayload(payload) {
  if (payload?.schema_version !== "motionos.replay-lab.v1") {
    return payload;
  }

  const devices = (payload.devices ?? []).map((device) => {
    const rate = primaryStreamRate(device.streams);
    const residual = device.clock?.reference
      ? 0
      : Number(device.clock?.residual_rms_ms);

    return {
      id: device.id,
      name: ({
        watch: "Apple Watch",
        equipment: "Equipment pod",
        insoles: "Bilateral insoles",
        camera: "Camera teacher"
      })[device.role] ?? device.role,
      detail: device.session_id + " · " + (device.gap_count ?? 0) + " gap region(s)",
      state: replayDeviceState(device.qualification),
      rate: rate === null ? "rate n/a" : rate.toFixed(1) + " Hz max",
      battery: null,
      syncMs: Number.isFinite(residual) ? residual : null,
      clock: device.clock,
      qualification: device.qualification
    };
  });

  const syncMs = maxSyncResidualMs(payload.devices ?? []);
  const frames = (payload.frames ?? []).map((frame) => {
    const leftPressure = frame.left_foot?.pressure;
    const rightPressure = frame.right_foot?.pressure;
    const leftFraction = frame.derived?.left_load_fraction;
    const numericLeftFraction = leftFraction == null
      ? null
      : Number(leftFraction);
    const leftLoad = numericLeftFraction !== null
      && Number.isFinite(numericLeftFraction)
      ? numericLeftFraction
      : null;
    const rightLoad = leftLoad === null ? null : 1 - leftLoad;

    return {
      t: Number(frame.t_ms ?? 0),
      hr: frame.watch?.heart_rate_bpm ?? null,
      boardAccel: frame.equipment?.accel_magnitude_m_s2 ?? null,
      boardGyro: frame.equipment?.gyro_magnitude_rad_s ?? null,
      syncMs,
      leftLoad,
      rightLoad,
      leftForceN: leftPressure?.normal_force_n ?? null,
      rightForceN: rightPressure?.normal_force_n ?? null,
      copL: normalizedCopToDisplay(leftPressure?.cop_normalized),
      copR: normalizedCopToDisplay(rightPressure?.cop_normalized),
      pressureL: leftPressure?.pressure_kpa ?? null,
      pressureR: rightPressure?.pressure_kpa ?? null,
      pose: frame.camera?.pose3d ?? null,
      activeGaps: frame.active_gap_streams ?? [],
      streamsPresent: frame.streams_present ?? []
    };
  });

  return {
    source: "generated",
    sport: payload.run?.sport ?? "Calibration",
    runId: payload.run?.run_id ?? "unknown",
    duration: frames.length
      ? (frames.at(-1).t / 1000).toFixed(1) + " s"
      : "0.0 s",
    devices,
    requiredIds: devices.map((device) => device.id),
    frames,
    syncMs,
    gaps: payload.gaps ?? [],
    claimBoundary: payload.claim_boundary ?? ""
  };
}

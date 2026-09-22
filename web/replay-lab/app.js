import {
  adaptReplayLabPayload,
  balanceAsymmetry,
  buildPressureCells,
  deriveCaptureGate,
  formatSync,
  nearestFrame,
  normalizedPressure,
  projectRootRelativePose
} from "./model.mjs";
import { demoSession } from "./demo-session.mjs";

const $ = (selector) => document.querySelector(selector);
const $$ = (selector) => [...document.querySelectorAll(selector)];
const timeline = $("#timeline");
const deviceGrid = $("#devices");

async function loadSession() {
  const requested = new URLSearchParams(window.location.search).get("session");
  const candidates = requested ? [requested] : ["./session.json"];

  for (const url of candidates) {
    try {
      const response = await fetch(url, { cache: "no-store" });
      if (!response.ok) continue;
      return adaptReplayLabPayload(await response.json());
    } catch {
      // Fall through to the deterministic development demo.
    }
  }

  return { ...demoSession, source: "demo" };
}

const session = await loadSession();
const captureGate = deriveCaptureGate(session.devices, session.requiredIds);

function deviceCard(device) {
  return `
    <article class="device-card ${device.state}">
      <div class="device-title-row">
        <div>
          <h3>${device.name}</h3>
          <p>${device.detail}</p>
        </div>
        <span class="status-pill">${device.state}</span>
      </div>
      <div class="device-stats">
        <span>${device.rate}</span>
        <span>${formatSync(device.syncMs)}</span>
        <span>${device.battery != null && Number.isFinite(Number(device.battery)) ? device.battery + "%" : "battery n/a"}</span>
      </div>
    </article>`;
}

function renderDevices() {
  deviceGrid.innerHTML = session.devices.map(deviceCard).join("");
  const gate = $("#capture-gate");
  gate.textContent = captureGate.canStart
    ? "Capture gate: ready"
    : `Capture gate: ${captureGate.blockers.length} blocker(s)`;
  gate.dataset.state = captureGate.canStart ? "ready" : "blocked";
}

function skeletonSVG(joints) {
  const line = (a, b) =>
    `<line x1="${joints[a][0]}" y1="${joints[a][1]}" x2="${joints[b][0]}" y2="${joints[b][1]}" />`;
  return `
    <svg viewBox="0 0 100 105" class="skeleton" aria-label="Estimated athlete pose">
      <g class="bones">
        ${line("head","neck")}
        ${line("neck","pelvis")}
        ${line("neck","leftHand")}
        ${line("neck","rightHand")}
        ${line("pelvis","leftFoot")}
        ${line("pelvis","rightFoot")}
      </g>
      <g class="joints">
        ${Object.values(joints).map(([x,y]) => `<circle cx="${x}" cy="${y}" r="2.2" />`).join("")}
      </g>
      <g class="board">
        <line x1="28" y1="91" x2="76" y2="91" />
        <circle cx="34" cy="94" r="1.7" />
        <circle cx="70" cy="94" r="1.7" />
      </g>
    </svg>`;
}

function generatedPoseSVG(pose) {
  const joints = projectRootRelativePose(
    pose?.joints_root_relative_m ?? {}
  );
  if (!Object.keys(joints).length) {
    return '<div class="no-sample">No pose sample in this frame</div>';
  }

  const parents = pose?.joint_parents ?? {};
  const bones = Object.entries(parents)
    .filter(([child, parent]) => parent && joints[child] && joints[parent])
    .map(([child, parent]) =>
      '<line x1="' + joints[parent][0] + '" y1="' + joints[parent][1]
      + '" x2="' + joints[child][0] + '" y2="' + joints[child][1] + '" />'
    )
    .join("");

  const points = Object.values(joints)
    .map(([x, y]) => '<circle cx="' + x + '" cy="' + y + '" r="1.8" />')
    .join("");

  return `
    <svg viewBox="0 0 100 105" class="skeleton" aria-label="Vision 3D pose projected for display">
      <g class="bones">${bones}</g>
      <g class="joints">${points}</g>
      <text x="4" y="101" class="pose-note">root-relative XY projection</text>
    </svg>`;
}

function poseSVG(frame) {
  if (frame.pose) return generatedPoseSVG(frame.pose);
  if (frame.joints) return skeletonSVG(frame.joints);
  return '<div class="no-sample">No pose sample in this frame</div>';
}
function pressureSVG(values, side, cop) {
  if (!Array.isArray(values) || !values.length) {
    return `
      <svg viewBox="0 0 100 135" class="foot-map" aria-label="${side} foot pressure unavailable">
        <path class="foot-outline" d="M50 4 C25 5 18 25 24 44 C29 59 34 68 32 85 C29 106 36 128 50 131 C65 130 72 108 68 86 C65 69 73 60 78 44 C84 25 76 7 50 4Z" />
        <text x="50" y="70" text-anchor="middle" class="no-sample-svg">no sample</text>
      </svg>`;
  }

  const cells = buildPressureCells(values, side);
  const levels = normalizedPressure(values);
  const copMarker = Array.isArray(cop)
    ? `<circle cx="${cop[0]}" cy="${cop[1]}" r="3.2" class="cop" />`
    : "";
  return `
    <svg viewBox="0 0 100 135" class="foot-map" aria-label="${side} foot pressure">
      <path class="foot-outline" d="M50 4 C25 5 18 25 24 44 C29 59 34 68 32 85 C29 106 36 128 50 131 C65 130 72 108 68 86 C65 69 73 60 78 44 C84 25 76 7 50 4Z" />
      ${cells.map((cell, i) =>
        `<circle cx="${cell.x}" cy="${cell.y}" r="${5 + levels[i] * 5}" style="--p:${levels[i].toFixed(3)}" class="pressure-node" />`
      ).join("")}
      ${copMarker}
    </svg>`;
}
function renderFrame(frame) {
  if (!frame) {
    $("#hr").textContent = "—";
    $("#metric-one").textContent = "—";
    $("#metric-two").textContent = "—";
    $("#confidence").textContent = "—";
    $("#sync").textContent = formatSync(null);
    $("#gap-state").textContent = "no frame";
    $("#pose-stage").innerHTML = '<div class="no-sample">No synchronized frame data</div>';
    return;
  }

  $("#hr").textContent = frame.hr == null
    ? "—"
    : Number(frame.hr).toFixed(0) + " bpm";

  const generated = session.source === "generated";
  $("#metric-one-label").textContent = generated ? "Board accel" : "Speed";
  $("#metric-two-label").textContent = generated ? "Board gyro" : "Board roll";
  $("#metric-one").textContent = generated
    ? (frame.boardAccel == null ? "—" : Number(frame.boardAccel).toFixed(2) + " m/s²")
    : Number(frame.speed).toFixed(1) + " m/s";
  $("#metric-two").textContent = generated
    ? (frame.boardGyro == null ? "—" : Number(frame.boardGyro).toFixed(2) + " rad/s")
    : (frame.boardRoll > 0 ? "+" : "") + Number(frame.boardRoll).toFixed(1) + "°";

  $("#confidence").textContent = generated
    ? (frame.pose ? "observed" : "no sample")
    : Number(frame.poseConfidence).toFixed(2);
  $("#sync").textContent = formatSync(frame.syncMs);
  $("#gap-state").textContent = frame.activeGaps?.length
    ? frame.activeGaps.length + " active"
    : "clear";

  if (frame.leftLoad == null || frame.rightLoad == null) {
    $("#balance-value").textContent = "—";
    $("#balance-dot").style.visibility = "hidden";
    $("#left-load").textContent = "—";
    $("#right-load").textContent = "—";
  } else {
    const asymmetry = balanceAsymmetry(frame.leftLoad, frame.rightLoad);
    $("#balance-value").textContent = asymmetry.toFixed(2);
    $("#balance-dot").style.visibility = "visible";
    $("#balance-dot").style.left = (50 + asymmetry * 44) + "%";
    $("#left-load").textContent = Math.round(frame.leftLoad * 100) + "%";
    $("#right-load").textContent = Math.round(frame.rightLoad * 100) + "%";
  }

  $("#pose-stage").innerHTML = poseSVG(frame);
  $("#left-pressure").innerHTML = pressureSVG(frame.pressureL, "left", frame.copL);
  $("#right-pressure").innerHTML = pressureSVG(frame.pressureR, "right", frame.copR);
}
function onTimeline() {
  const time = Number(timeline.value);
  renderFrame(nearestFrame(session.frames, time));
  $("#time-readout").textContent = `${(time / 1000).toFixed(1)} s`;
}

function showScreen(name) {
  $$(".tab").forEach((button) => {
    button.classList.toggle("is-active", button.dataset.screen === name);
  });
  $$(".screen").forEach((screen) => {
    screen.classList.toggle("is-active", screen.dataset.screenPanel === name);
  });
}

$$(".tab").forEach((button) =>
  button.addEventListener("click", () => showScreen(button.dataset.screen))
);

$("#session-sport").textContent = session.sport;
$("#session-duration").textContent = session.duration;
timeline.max = String(session.frames.at(-1)?.t ?? 0);
timeline.disabled = session.frames.length === 0;
timeline.addEventListener("input", onTimeline);
$("#session-source").textContent = session.source === "generated"
  ? "generated evidence"
  : "development demo";
renderDevices();
onTimeline();

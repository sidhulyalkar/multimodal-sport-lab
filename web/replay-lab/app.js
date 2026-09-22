import {
  balanceAsymmetry,
  buildPressureCells,
  deriveCaptureGate,
  formatSync,
  nearestFrame,
  normalizedPressure
} from "./model.mjs";
import { demoSession } from "./demo-session.mjs";

const $ = (selector) => document.querySelector(selector);
const $$ = (selector) => [...document.querySelectorAll(selector)];
const timeline = $("#timeline");
const deviceGrid = $("#devices");
const captureGate = deriveCaptureGate(demoSession.devices, demoSession.requiredIds);

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
        <span>${device.battery}%</span>
      </div>
    </article>`;
}

function renderDevices() {
  deviceGrid.innerHTML = demoSession.devices.map(deviceCard).join("");
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

function pressureSVG(values, side, cop) {
  const cells = buildPressureCells(values, side);
  const levels = normalizedPressure(values);
  return `
    <svg viewBox="0 0 100 135" class="foot-map" aria-label="${side} foot pressure">
      <path class="foot-outline" d="M50 4 C25 5 18 25 24 44 C29 59 34 68 32 85 C29 106 36 128 50 131 C65 130 72 108 68 86 C65 69 73 60 78 44 C84 25 76 7 50 4Z" />
      ${cells.map((cell, i) =>
        `<circle cx="${cell.x}" cy="${cell.y}" r="${5 + levels[i] * 5}" style="--p:${levels[i].toFixed(3)}" class="pressure-node" />`
      ).join("")}
      <circle cx="${cop[0]}" cy="${cop[1]}" r="3.2" class="cop" />
    </svg>`;
}

function renderFrame(frame) {
  $("#hr").textContent = `${frame.hr} bpm`;
  $("#speed").textContent = `${frame.speed.toFixed(1)} m/s`;
  $("#roll").textContent = `${frame.boardRoll > 0 ? "+" : ""}${frame.boardRoll.toFixed(1)}°`;
  $("#confidence").textContent = frame.poseConfidence.toFixed(2);
  $("#sync").textContent = formatSync(frame.syncMs);

  const asymmetry = balanceAsymmetry(frame.leftLoad, frame.rightLoad);
  $("#balance-value").textContent = asymmetry.toFixed(2);
  $("#balance-dot").style.left = `${50 + asymmetry * 44}%`;
  $("#left-load").textContent = `${Math.round(frame.leftLoad * 100)}%`;
  $("#right-load").textContent = `${Math.round(frame.rightLoad * 100)}%`;

  $("#pose-stage").innerHTML = skeletonSVG(frame.joints);
  $("#left-pressure").innerHTML = pressureSVG(frame.pressureL, "left", frame.copL);
  $("#right-pressure").innerHTML = pressureSVG(frame.pressureR, "right", frame.copR);
}

function onTimeline() {
  const time = Number(timeline.value);
  renderFrame(nearestFrame(demoSession.frames, time));
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

$("#session-sport").textContent = demoSession.sport;
$("#session-duration").textContent = demoSession.duration;
timeline.max = String(demoSession.frames.at(-1).t);
timeline.addEventListener("input", onTimeline);
renderDevices();
onTimeline();

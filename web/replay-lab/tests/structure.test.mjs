import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

const html = await readFile(
  new URL("../index.html", import.meta.url),
  "utf8"
);

for (const screen of ["today", "capture", "replay", "compare", "lab"]) {
  test(`Product Lab includes ${screen} navigation and screen panel`, () => {
    assert.match(html, new RegExp(`data-screen="${screen}"`));
    assert.match(html, new RegExp(`data-screen-panel="${screen}"`));
  });
}

test("capture screen exposes device readiness and calibration progression", () => {
  assert.match(html, /Device readiness/);
  assert.match(html, /Sync impulse/);
  assert.match(html, /Camera check/);
});

test("replay screen exposes measured pressure and synchronization quality", () => {
  assert.match(html, /Plantar loading/);
  assert.match(html, /SYNCHRONIZED MULTIMODAL STATE/);
  assert.match(html, /SYNCHRONIZED TIMELINE/);
});


test("replay screen exposes generated-evidence provenance and gap state", () => {
  assert.match(html, /session-source/);
  assert.match(html, /gap-state/);
  assert.match(html, /metric-one-label/);
  assert.match(html, /metric-two-label/);
});

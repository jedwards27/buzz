import assert from "node:assert/strict";
import test from "node:test";
import { clipFrameToViewport } from "./nativeReviewSemanticProbe.ts";

const viewport = { width: 1440, height: 792 };

test("a frame wholly inside the viewport is unchanged", () => {
  const frame = { x: 11, y: 297, width: 260, height: 32 };
  assert.deepEqual(clipFrameToViewport(frame, viewport), frame);
});

test("a frame that overflows the viewport is clipped to its visible part", () => {
  assert.deepEqual(
    clipFrameToViewport({ x: 1400, y: 700, width: 100, height: 200 }, viewport),
    { x: 1400, y: 700, width: 40, height: 92 },
  );
  assert.deepEqual(
    clipFrameToViewport({ x: -20, y: -10, width: 100, height: 50 }, viewport),
    { x: 0, y: 0, width: 80, height: 40 },
  );
});

test("a frame wholly outside the viewport has no visible part", () => {
  // The visually hidden 1px elements UI libraries park at -1px.
  assert.equal(
    clipFrameToViewport({ x: -1, y: -1, width: 1, height: 1 }, viewport),
    undefined,
  );
  assert.equal(
    clipFrameToViewport({ x: 0, y: 800, width: 10, height: 10 }, viewport),
    undefined,
  );
});

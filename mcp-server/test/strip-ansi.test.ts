import { test } from "node:test";
import assert from "node:assert/strict";

import { stripAnsi } from "../src/mra-executor.js";

test("strips SGR color sequences", () => {
  assert.equal(stripAnsi("\x1b[0;32mok\x1b[0m"), "ok");
});

test("strips cursor movement and erase sequences", () => {
  assert.equal(stripAnsi("\x1b[2Aok\x1b[K"), "ok");
  assert.equal(stripAnsi("\x1b[2Jcleared"), "cleared");
});

test("strips OSC sequences (terminal title)", () => {
  assert.equal(stripAnsi("\x1b]0;title\x07ok"), "ok");
  assert.equal(stripAnsi("\x1b]8;;https://x\x1b\\link\x1b]8;;\x1b\\"), "link");
});

test("normalizes carriage returns so progress overwrites stay readable", () => {
  assert.equal(stripAnsi("step 1\rstep 2\r\ndone"), "step 1\nstep 2\ndone");
});

test("plain text passes through untouched", () => {
  assert.equal(stripAnsi("hello\nworld"), "hello\nworld");
});

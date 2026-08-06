import { test } from "node:test";
import assert from "node:assert/strict";

import {
  validateToolInput,
  toolTimeout,
  InputValidationError,
} from "../src/input-validation.js";
import { findTool } from "../src/tools.js";

function mustFind(name: string) {
  const tool = findTool(name);
  assert.ok(tool, `tool ${name} should exist`);
  return tool;
}

// Undeclared keys must never reach argv. That was previously achieved by
// dropping them; it is now achieved by refusing the call, which contains them
// just as firmly and does not also mislead the caller. See the rejection tests
// at the end of this file for what dropping cost.
test("declared input passes through unchanged", () => {
  const tool = mustFind("mra_deps");
  const input = validateToolInput(tool, {
    workspace: "/tmp/ws",
    project: "my-app",
  });
  assert.equal(input.workspace, "/tmp/ws");
  assert.equal(input.project, "my-app");
});

test("an undeclared key never reaches the returned arguments", () => {
  const tool = mustFind("mra_deps");
  assert.throws(
    () => validateToolInput(tool, { workspace: "/tmp/ws", extraneous: "x" }),
    InputValidationError,
  );
});

test("path traversal project name is rejected by the schema pattern", () => {
  const tool = mustFind("mra_deps");
  assert.throws(
    () => validateToolInput(tool, { workspace: "/tmp/ws", project: "../../etc" }),
    InputValidationError
  );
});

test("non-string values are rejected, not silently stringified", () => {
  const tool = mustFind("mra_deps");
  for (const bad of [42, null, { a: 1 }, ["x"], true]) {
    assert.throws(
      () => validateToolInput(tool, { workspace: "/tmp/ws", project: bad }),
      InputValidationError,
      `project=${JSON.stringify(bad)} should be rejected`
    );
  }
});

test("missing required argument is rejected", () => {
  const tool = mustFind("mra_ask");
  assert.throws(
    () => validateToolInput(tool, { workspace: "/tmp/ws", project: "my-app" }),
    InputValidationError
  );
});

test("undefined arguments object is rejected when fields are required", () => {
  const tool = mustFind("mra_status");
  assert.throws(() => validateToolInput(tool, undefined), InputValidationError);
});

test("enum fields only accept declared values", () => {
  const tool = mustFind("mra_graph");
  const ok = validateToolInput(tool, { workspace: "/tmp/ws", format: "mermaid" });
  assert.equal(ok.format, "mermaid");
  assert.throws(
    () => validateToolInput(tool, { workspace: "/tmp/ws", format: "--evil" }),
    InputValidationError
  );
});

test("mra_ask question has an upper length bound", () => {
  const tool = mustFind("mra_ask");
  const huge = "x".repeat(100_000);
  assert.throws(
    () =>
      validateToolInput(tool, {
        workspace: "/tmp/ws",
        project: "my-app",
        question: huge,
      }),
    InputValidationError
  );
});

test("toolTimeout returns declared timeout or the default", () => {
  assert.equal(toolTimeout(mustFind("mra_ask")), 300000);
  assert.equal(toolTimeout(mustFind("mra_status")), 180000);
  assert.equal(toolTimeout({ timeout: "soon" }), 180000);
});

// An argument the tool does not declare was silently dropped: the loop only
// walks declared properties, so anything else in the payload never got looked
// at. A client calling mra_diff with {"project": "web"} — a parameter that tool
// has never had — received a successful, authoritative-looking answer about
// every project, with nothing to indicate its filter was discarded.
//
// Found by driving the server over stdio: `mra_diff` with a nonexistent project
// returned "all projects clean".
test("an undeclared argument is rejected, not dropped", () => {
  const tool = {
    name: "mra_diff",
    inputSchema: {
      properties: { workspace: { type: "string" } },
      required: ["workspace"],
    },
  };
  assert.throws(
    () => validateToolInput(tool, { workspace: "/ws", project: "web" }),
    (e: Error) => e.name === "InputValidationError" && /project/.test(e.message),
    "an argument the tool does not accept must be refused",
  );
});

test("the rejection names every unknown argument", () => {
  const tool = {
    name: "mra_status",
    inputSchema: { properties: { workspace: { type: "string" } }, required: [] },
  };
  try {
    validateToolInput(tool, { workspace: "/ws", project: "a", branch: "b" });
    assert.fail("should have thrown");
  } catch (e) {
    const m = (e as Error).message;
    assert.match(m, /project/);
    assert.match(m, /branch/);
  }
});

test("declared arguments still pass", () => {
  const tool = {
    name: "mra_deps",
    inputSchema: {
      properties: { workspace: { type: "string" }, project: { type: "string" } },
      required: ["workspace"],
    },
  };
  assert.deepEqual(validateToolInput(tool, { workspace: "/ws", project: "web" }), {
    workspace: "/ws",
    project: "web",
  });
});

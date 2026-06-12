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

test("valid input passes through and keeps only schema-declared keys", () => {
  const tool = mustFind("mra_deps");
  const input = validateToolInput(tool, {
    workspace: "/tmp/ws",
    project: "my-app",
    extraneous: "dropped",
  });
  assert.equal(input.workspace, "/tmp/ws");
  assert.equal(input.project, "my-app");
  assert.equal("extraneous" in input, false);
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

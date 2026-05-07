import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, realpathSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { delimiter, join } from "node:path";

import {
  loadWorkspacePolicy,
  isWorkspaceAllowed,
  assertWorkspaceAllowed,
  WorkspaceNotAllowedError,
} from "../src/workspace-policy.js";

function makeTempRoot(): string {
  const dir = mkdtempSync(join(tmpdir(), "mra-policy-"));
  return realpathSync(dir);
}

test("empty allowlist accepts any workspace (open mode)", () => {
  const policy = loadWorkspacePolicy({});
  assert.equal(policy.allowedRoots.length, 0);
  assert.equal(policy.envHadValue, false);
  assert.equal(isWorkspaceAllowed("/anything", policy), true);
});

test("env set but all entries empty denies everything (no silent downgrade)", () => {
  const policy = loadWorkspacePolicy({
    MRA_ALLOWED_WORKSPACES: `${delimiter}${delimiter}  ${delimiter}`,
  });
  assert.equal(policy.allowedRoots.length, 0);
  assert.equal(policy.envHadValue, true);
  assert.equal(isWorkspaceAllowed("/anything", policy), false);
});

test("populated allowlist rejects outside paths", () => {
  const root = makeTempRoot();
  try {
    const policy = loadWorkspacePolicy({ MRA_ALLOWED_WORKSPACES: root });
    assert.equal(isWorkspaceAllowed(root, policy), true);
    assert.equal(isWorkspaceAllowed("/etc", policy), false);
    assert.equal(isWorkspaceAllowed("", policy), false);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("subdirectories of an allowed root are accepted", () => {
  const root = makeTempRoot();
  try {
    const sub = join(root, "child");
    mkdirSync(sub);
    const policy = loadWorkspacePolicy({ MRA_ALLOWED_WORKSPACES: root });
    assert.equal(isWorkspaceAllowed(sub, policy), true);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("path traversal cannot escape the allowed root", () => {
  const root = makeTempRoot();
  try {
    const policy = loadWorkspacePolicy({ MRA_ALLOWED_WORKSPACES: root });
    const escape = join(root, "..", "siblingdir");
    assert.equal(isWorkspaceAllowed(escape, policy), false);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("multiple roots are platform-delimiter separated", () => {
  const a = makeTempRoot();
  const b = makeTempRoot();
  try {
    const policy = loadWorkspacePolicy({
      MRA_ALLOWED_WORKSPACES: `${a}${delimiter}${b}`,
    });
    assert.equal(policy.allowedRoots.length, 2);
    assert.equal(isWorkspaceAllowed(a, policy), true);
    assert.equal(isWorkspaceAllowed(b, policy), true);
  } finally {
    rmSync(a, { recursive: true, force: true });
    rmSync(b, { recursive: true, force: true });
  }
});

test("sibling directory with shared prefix is rejected", () => {
  // Guards against the old `startsWith(root + "/")` bug where /foo-bar
  // would match a root of /foo. With path.relative() the sibling fails.
  const parent = makeTempRoot();
  const root = join(parent, "foo");
  const sibling = join(parent, "foo-bar");
  mkdirSync(root);
  mkdirSync(sibling);
  try {
    const policy = loadWorkspacePolicy({ MRA_ALLOWED_WORKSPACES: root });
    assert.equal(isWorkspaceAllowed(root, policy), true);
    assert.equal(isWorkspaceAllowed(sibling, policy), false);
  } finally {
    rmSync(parent, { recursive: true, force: true });
  }
});

test("assertWorkspaceAllowed throws WorkspaceNotAllowedError", () => {
  const root = makeTempRoot();
  try {
    const policy = loadWorkspacePolicy({ MRA_ALLOWED_WORKSPACES: root });
    assert.throws(
      () => assertWorkspaceAllowed("/nope", policy),
      (err: unknown) => err instanceof WorkspaceNotAllowedError,
    );
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

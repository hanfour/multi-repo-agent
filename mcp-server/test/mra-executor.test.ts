import { test } from "node:test";
import assert from "node:assert";
import { executeMra } from "../src/mra-executor.js";

const activeTimeouts = () =>
  process.getActiveResourcesInfo().filter((r) => r === "Timeout").length;

// executeMra registers a timeout and clears it in the `close` handler. The
// `error` handler resolved without clearing it, and `close` may not fire after
// `error`, so a failed spawn left the timer armed for the full timeout — up to
// three minutes of an event loop that cannot drain (#38).
test("a failed spawn does not leave the timeout armed", async () => {
  const before = activeTimeouts();

  // An unreadable cwd makes spawn emit 'error' rather than starting a process.
  const result = await executeMra(["--version"], "/nonexistent-mra-cwd", 600_000);

  assert.strictEqual(result.exitCode, 1);
  assert.match(result.error, /Failed to execute mra/);
  assert.strictEqual(
    activeTimeouts(),
    before,
    "timeout still armed after the spawn error path resolved",
  );
});

test("a timed-out run reports exit code 124", async () => {
  const before = activeTimeouts();

  // 1ms is shorter than any real spawn, so this lands on the timeout path.
  const result = await executeMra(["--help"], process.cwd(), 1);

  assert.strictEqual(result.exitCode, 124);
  assert.strictEqual(result.error, "Command timed out");
  assert.strictEqual(
    activeTimeouts(),
    before,
    "timeout still armed after the timeout path resolved",
  );
});

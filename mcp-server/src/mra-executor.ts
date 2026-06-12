import { spawn } from "child_process";
import { resolve } from "path";
import { fileURLToPath } from "url";
import { dirname } from "path";

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

// Resolve mra.sh path relative to mcp-server location
const MRA_BIN = resolve(__dirname, "..", "..", "bin", "mra.sh");

export interface MraResult {
  output: string;
  exitCode: number;
  error: string;
}

export async function executeMra(
  args: string[],
  workspace: string,
  timeoutMs: number = 180000
): Promise<MraResult> {
  return new Promise((resolve_promise) => {
    const proc = spawn("bash", [MRA_BIN, ...args], {
      cwd: workspace,
      env: { ...process.env, MRA_WORKSPACE: workspace },
      stdio: ["pipe", "pipe", "pipe"],
    });

    proc.stdin.end();

    let stdout = "";
    let stderr = "";

    proc.stdout.on("data", (data: Buffer) => {
      stdout += data.toString();
    });

    proc.stderr.on("data", (data: Buffer) => {
      stderr += data.toString();
    });

    proc.on("error", (err) => {
      resolve_promise({
        output: "",
        exitCode: 1,
        error: `Failed to execute mra: ${err.message}`,
      });
    });

    const timeout = setTimeout(() => {
      proc.kill("SIGTERM");
      resolve_promise({
        output: stdout.trim(),
        exitCode: 124,
        error: "Command timed out",
      });
    }, timeoutMs);

    proc.on("close", (code) => {
      clearTimeout(timeout);
      resolve_promise({
        output: stdout.trim(),
        exitCode: code ?? 1,
        error: stderr.trim(),
      });
    });
  });
}

// Strip terminal escape sequences so MCP clients receive plain text:
// CSI (colors, cursor movement, erase), OSC (titles, hyperlinks,
// terminated by BEL or ST), and carriage-return overwrites.
const TERMINAL_ESCAPES = /\x1b(?:\[[0-9;?]*[a-zA-Z]|\][^\x07\x1b]*(?:\x07|\x1b\\)?)/g;

export function stripAnsi(text: string): string {
  return text
    .replace(TERMINAL_ESCAPES, "")
    .replace(/\r\n/g, "\n")
    .replace(/\r/g, "\n");
}

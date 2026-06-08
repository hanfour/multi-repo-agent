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

// Strip ANSI color codes from output
export function stripAnsi(text: string): string {
  return text.replace(/\x1b\[[0-9;]*m/g, "");
}

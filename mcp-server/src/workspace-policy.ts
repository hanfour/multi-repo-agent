import { realpathSync } from "fs";
import { resolve } from "path";

/**
 * Workspace access policy for the MCP server.
 *
 * The server runs as the user with full shell privileges. Without a
 * constraint anyone calling a tool can pass *any* path on disk as
 * `workspace`, and we will execute `mra <command>` inside it. The policy
 * here gates that — operators can pin the server to a fixed list of
 * workspace roots via `MRA_ALLOWED_WORKSPACES`.
 *
 * Format: colon-separated absolute paths, e.g.
 *   MRA_ALLOWED_WORKSPACES=/Users/me/work/main:/Users/me/work/sandbox
 *
 * Empty / unset = open mode (legacy behavior). The server logs a warning
 * at startup so the operator can opt into the allowlist explicitly.
 */
export interface WorkspacePolicy {
  readonly allowedRoots: readonly string[];
}

function safeRealpath(p: string): string {
  try {
    return realpathSync(p);
  } catch {
    return resolve(p);
  }
}

export function loadWorkspacePolicy(
  env: NodeJS.ProcessEnv = process.env,
): WorkspacePolicy {
  const raw = env.MRA_ALLOWED_WORKSPACES ?? "";
  const allowedRoots = raw
    .split(":")
    .map((s) => s.trim())
    .filter(Boolean)
    .map(safeRealpath);
  return { allowedRoots };
}

export function isWorkspaceAllowed(
  workspace: string,
  policy: WorkspacePolicy,
): boolean {
  if (!workspace) return false;
  if (policy.allowedRoots.length === 0) {
    return true;
  }
  const real = safeRealpath(workspace);
  return policy.allowedRoots.some(
    (root) => real === root || real.startsWith(root + "/"),
  );
}

export class WorkspaceNotAllowedError extends Error {
  constructor(workspace: string, policy: WorkspacePolicy) {
    const list = policy.allowedRoots.join(", ") || "(none configured)";
    super(
      `workspace "${workspace}" is not in MRA_ALLOWED_WORKSPACES (${list})`,
    );
    this.name = "WorkspaceNotAllowedError";
  }
}

export function assertWorkspaceAllowed(
  workspace: string,
  policy: WorkspacePolicy,
): void {
  if (!isWorkspaceAllowed(workspace, policy)) {
    throw new WorkspaceNotAllowedError(workspace, policy);
  }
}

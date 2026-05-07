import { realpathSync } from "fs";
import { delimiter, isAbsolute, normalize, relative, resolve } from "path";

/**
 * Workspace access policy for the MCP server.
 *
 * The server runs as the user with full shell privileges. Without a
 * constraint anyone calling a tool can pass *any* path on disk as
 * `workspace`, and we will execute `mra <command>` inside it. The policy
 * here gates that — operators can pin the server to a fixed list of
 * workspace roots via `MRA_ALLOWED_WORKSPACES`.
 *
 * Format: paths separated by the platform delimiter (`:` on POSIX, `;`
 * on Windows). Example:
 *   POSIX:   MRA_ALLOWED_WORKSPACES=/Users/me/work/main:/Users/me/work/sandbox
 *   Windows: MRA_ALLOWED_WORKSPACES=C:\work\main;C:\work\sandbox
 *
 * Empty / unset = open mode (legacy behavior). The server logs a warning
 * at startup so the operator can opt into the allowlist explicitly.
 *
 * `envHadValue` captures whether the operator set the variable at all.
 * If they did but every entry failed to resolve, we deny instead of
 * silently downgrading to open mode — that would be a security footgun.
 */
export interface WorkspacePolicy {
  readonly allowedRoots: readonly string[];
  readonly envHadValue: boolean;
}

function safeRealpath(p: string): string | null {
  try {
    return realpathSync(p);
  } catch {
    return null;
  }
}

function normalizePath(p: string): string {
  // resolve() handles `..` segments; normalize() collapses redundant separators.
  return normalize(resolve(p));
}

export function loadWorkspacePolicy(
  env: NodeJS.ProcessEnv = process.env,
): WorkspacePolicy {
  const raw = env.MRA_ALLOWED_WORKSPACES ?? "";
  const envHadValue = raw.trim().length > 0;
  const allowedRoots = raw
    .split(delimiter)
    .map((s) => s.trim())
    .filter(Boolean)
    .map((p) => safeRealpath(p) ?? normalizePath(p));
  return { allowedRoots, envHadValue };
}

function isInsideRoot(real: string, root: string): boolean {
  if (real === root) return true;
  const rel = relative(root, real);
  // `relative` returns "" for same path, ".." for parent, "../foo" for sibling.
  return !!rel && !rel.startsWith("..") && !isAbsolute(rel);
}

export function isWorkspaceAllowed(
  workspace: string,
  policy: WorkspacePolicy,
): boolean {
  if (!workspace) return false;
  if (policy.allowedRoots.length === 0) {
    // If the operator set MRA_ALLOWED_WORKSPACES but no entry resolved,
    // deny everything rather than silently downgrade to open mode.
    return !policy.envHadValue;
  }
  const real = safeRealpath(workspace) ?? normalizePath(workspace);
  return policy.allowedRoots.some((root) => isInsideRoot(real, root));
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

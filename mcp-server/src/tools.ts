// Tool definitions with inputSchema as JSON Schema objects

export const TOOLS = [
  {
    name: "mra_status",
    description:
      "Show workspace status overview: all projects with branch, changes, type, and database status",
    inputSchema: {
      type: "object" as const,
      properties: {
        workspace: {
          type: "string",
          description: "Workspace root path (e.g., /Users/you/OneAD)",
        },
      },
      required: ["workspace"],
    },
    mraArgs: (_input: Record<string, string>) => ["status"],
  },
  {
    name: "mra_deps",
    description: "Show dependency graph for a project or all projects",
    inputSchema: {
      type: "object" as const,
      properties: {
        workspace: {
          type: "string",
          description: "Workspace root path",
        },
        project: {
          type: "string",
          description: "Project name (optional, shows all if omitted)",
        },
      },
      required: ["workspace"],
    },
    mraArgs: (input: Record<string, string>) =>
      input.project ? ["deps", input.project] : ["deps"],
  },
  {
    name: "mra_ask",
    description:
      "Query a project's codebase using Claude AI. Returns technical analysis based on actual source code.",
    inputSchema: {
      type: "object" as const,
      properties: {
        workspace: {
          type: "string",
          description: "Workspace root path",
        },
        project: {
          type: "string",
          description: "Project name to query",
        },
        question: {
          type: "string",
          description: "Technical question about the codebase",
        },
      },
      required: ["workspace", "project", "question"],
    },
    mraArgs: (input: Record<string, string>) => [
      "ask",
      input.project,
      input.question,
    ],
    timeout: 300000, // 5 min for AI queries
  },
  {
    name: "mra_export",
    description:
      "Export project context file (routes, schema, deps, env vars) as markdown",
    inputSchema: {
      type: "object" as const,
      properties: {
        workspace: {
          type: "string",
          description: "Workspace root path",
        },
        project: {
          type: "string",
          description: "Project name (optional, exports all if omitted)",
        },
      },
      required: ["workspace"],
    },
    mraArgs: (input: Record<string, string>) =>
      input.project ? ["export", input.project] : ["export"],
  },
  {
    name: "mra_diff",
    description:
      "Show cross-repo diff summary: which projects have uncommitted or unpushed changes",
    inputSchema: {
      type: "object" as const,
      properties: {
        workspace: {
          type: "string",
          description: "Workspace root path",
        },
      },
      required: ["workspace"],
    },
    mraArgs: (_input: Record<string, string>) => ["diff"],
  },
  {
    name: "mra_doctor",
    description:
      "Run three-level environment health check: tools, databases, project dependencies",
    inputSchema: {
      type: "object" as const,
      properties: {
        workspace: {
          type: "string",
          description: "Workspace root path",
        },
        project: {
          type: "string",
          description: "Check specific project only (optional)",
        },
      },
      required: ["workspace"],
    },
    mraArgs: (input: Record<string, string>) =>
      input.project ? ["doctor", input.project] : ["doctor"],
  },
  {
    name: "mra_graph",
    description:
      "Generate dependency graph in text, Mermaid, or DOT format",
    inputSchema: {
      type: "object" as const,
      properties: {
        workspace: {
          type: "string",
          description: "Workspace root path",
        },
        format: {
          type: "string",
          enum: ["terminal", "mermaid", "dot"],
          description: "Output format (default: terminal)",
        },
      },
      required: ["workspace"],
    },
    mraArgs: (input: Record<string, string>) => {
      const args = ["graph"];
      if (input.format === "mermaid") args.push("--mermaid");
      else if (input.format === "dot") args.push("--dot");
      return args;
    },
  },
  {
    name: "mra_scan",
    description:
      "Run dependency scanners to detect cross-repo relationships. Updates dep-graph.json.",
    inputSchema: {
      type: "object" as const,
      properties: {
        workspace: {
          type: "string",
          description: "Workspace root path",
        },
      },
      required: ["workspace"],
    },
    mraArgs: (_input: Record<string, string>) => ["scan"],
  },
  {
    name: "mra_test",
    description:
      "Run tests for a project in Docker with environment isolation. Auto-detects if integration or mock tests are needed based on API change detection.",
    inputSchema: {
      type: "object" as const,
      properties: {
        workspace: {
          type: "string",
          description: "Workspace root path",
        },
        project: {
          type: "string",
          description: "Project name to test",
        },
        mode: {
          type: "string",
          enum: ["auto", "integration", "mock"],
          description: "Test mode (default: auto)",
        },
      },
      required: ["workspace", "project"],
    },
    mraArgs: (input: Record<string, string>) => {
      const args = ["test", input.project];
      if (input.mode === "integration") args.push("--integration");
      else if (input.mode === "mock") args.push("--mock");
      return args;
    },
    timeout: 600000, // 10 min for tests
  },
] as const;

export type ToolName = (typeof TOOLS)[number]["name"];

export function findTool(name: string) {
  return TOOLS.find((t) => t.name === name);
}

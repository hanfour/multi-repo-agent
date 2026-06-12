#!/usr/bin/env node
import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";
import { TOOLS, findTool } from "./tools.js";
import { executeMra, stripAnsi } from "./mra-executor.js";
import {
  validateToolInput,
  toolTimeout,
  InputValidationError,
} from "./input-validation.js";
import {
  loadWorkspacePolicy,
  assertWorkspaceAllowed,
  WorkspaceNotAllowedError,
} from "./workspace-policy.js";

const policy = loadWorkspacePolicy();

const server = new Server(
  {
    name: "mra-mcp-server",
    version: "1.0.0",
  },
  {
    capabilities: {
      tools: {},
    },
  }
);

// List available tools
server.setRequestHandler(ListToolsRequestSchema, async () => {
  return {
    tools: TOOLS.map((tool) => ({
      name: tool.name,
      description: tool.description,
      inputSchema: tool.inputSchema,
    })),
  };
});

// Handle tool calls
server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const { name, arguments: args } = request.params;
  const tool = findTool(name);

  if (!tool) {
    return {
      content: [{ type: "text", text: `Unknown tool: ${name}` }],
      isError: true,
    };
  }

  let input: Record<string, string>;
  try {
    input = validateToolInput(tool, args);
  } catch (error) {
    if (error instanceof InputValidationError) {
      return {
        content: [{ type: "text", text: error.message }],
        isError: true,
      };
    }
    throw error;
  }

  const workspace = input.workspace;
  if (!workspace) {
    return {
      content: [{ type: "text", text: "workspace parameter is required" }],
      isError: true,
    };
  }

  try {
    assertWorkspaceAllowed(workspace, policy);
  } catch (error) {
    if (error instanceof WorkspaceNotAllowedError) {
      return {
        content: [{ type: "text", text: error.message }],
        isError: true,
      };
    }
    throw error;
  }

  const mraArgs = tool.mraArgs(input);
  const timeout = toolTimeout(tool);

  try {
    const result = await executeMra(mraArgs, workspace, timeout);
    const cleanOutput = stripAnsi(result.output);

    if (result.exitCode !== 0 && !cleanOutput) {
      return {
        content: [
          {
            type: "text",
            text: `mra ${mraArgs.join(" ")} failed (exit ${result.exitCode}): ${stripAnsi(result.error)}`,
          },
        ],
        isError: true,
      };
    }

    return {
      content: [{ type: "text", text: cleanOutput || "(no output)" }],
    };
  } catch (error) {
    return {
      content: [
        {
          type: "text",
          text: `Error executing mra: ${error instanceof Error ? error.message : String(error)}`,
        },
      ],
      isError: true,
    };
  }
});

// Start server
async function main(): Promise<void> {
  const transport = new StdioServerTransport();
  await server.connect(transport);
  if (policy.allowedRoots.length === 0) {
    if (policy.openMode) {
      console.error(
        "mra MCP server started on stdio — WARNING: MRA_MCP_OPEN_MODE=1 is set and MRA_ALLOWED_WORKSPACES is empty; any workspace path will be accepted. This is intended only for trusted single-user setups. Set MRA_ALLOWED_WORKSPACES=<root1>:<root2> to restrict.",
      );
    } else {
      console.error(
        "mra MCP server started on stdio — DENY mode: MRA_ALLOWED_WORKSPACES is empty so every tool call will be rejected. Set MRA_ALLOWED_WORKSPACES=<root1>:<root2> to authorize workspaces, or MRA_MCP_OPEN_MODE=1 to enable open mode (not recommended).",
      );
    }
  } else {
    console.error(
      `mra MCP server started on stdio — workspace allowlist: ${policy.allowedRoots.join(", ")}`,
    );
  }
}

main().catch((error: unknown) => {
  console.error("Fatal error:", error);
  process.exit(1);
});

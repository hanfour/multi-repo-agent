#!/usr/bin/env node
import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";
import { TOOLS, findTool } from "./tools.js";
import { executeMra, stripAnsi } from "./mra-executor.js";

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

  const input = (args ?? {}) as Record<string, string>;
  const workspace = input.workspace;

  if (!workspace) {
    return {
      content: [{ type: "text", text: "workspace parameter is required" }],
      isError: true,
    };
  }

  const mraArgs = tool.mraArgs(input);
  const timeout = "timeout" in tool ? (tool as { timeout: number }).timeout : 180000;

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
  console.error("mra MCP server started on stdio");
}

main().catch((error: unknown) => {
  console.error("Fatal error:", error);
  process.exit(1);
});

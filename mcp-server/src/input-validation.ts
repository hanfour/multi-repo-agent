// Server-side enforcement of each tool's inputSchema.
//
// The MCP SDK exposes inputSchema to clients but does NOT validate
// incoming arguments against it, and these values end up as argv for
// bin/mra.sh. Casting `args` to Record<string, string> would silently
// bypass the pattern/enum constraints declared in tools.ts, leaving the
// shell layer as the only defense. Validate here, fail closed.

interface PropertySchema {
  type?: string;
  pattern?: string;
  enum?: readonly string[];
  maxLength?: number;
}

interface ToolLike {
  name: string;
  inputSchema: {
    properties: Record<string, PropertySchema>;
    required?: readonly string[];
  };
}

export class InputValidationError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "InputValidationError";
  }
}

export function validateToolInput(
  tool: ToolLike,
  args: unknown
): Record<string, string> {
  const raw = args ?? {};
  if (typeof raw !== "object" || Array.isArray(raw)) {
    throw new InputValidationError(`${tool.name}: arguments must be an object`);
  }
  const input = raw as Record<string, unknown>;
  const { properties, required = [] } = tool.inputSchema;

  for (const key of required) {
    const value = input[key];
    if (value === undefined || value === null || value === "") {
      throw new InputValidationError(
        `${tool.name}: missing required argument '${key}'`
      );
    }
  }

  // Refuse arguments the tool does not declare rather than dropping them. The
  // loop below only walks declared properties, so anything else used to vanish
  // in silence — a client calling mra_diff with {"project": "web"}, a parameter
  // that tool has never had, received a confident answer about every project
  // with no sign its filter had been discarded. Found by driving the server
  // over stdio, not by any test: the tools' own schemas were all satisfied.
  const unknown = Object.keys(input).filter((k) => !(k in properties));
  if (unknown.length > 0) {
    throw new InputValidationError(
      `${tool.name}: does not accept ${unknown.map((k) => `'${k}'`).join(", ")}` +
        ` (accepts: ${Object.keys(properties).join(", ")})`,
    );
  }

  const validated: Record<string, string> = {};
  for (const [key, schema] of Object.entries(properties)) {
    const value = input[key];
    if (value === undefined) continue;
    if (typeof value !== "string") {
      throw new InputValidationError(
        `${tool.name}: argument '${key}' must be a string`
      );
    }
    if (schema.maxLength !== undefined && value.length > schema.maxLength) {
      throw new InputValidationError(
        `${tool.name}: argument '${key}' exceeds ${schema.maxLength} characters`
      );
    }
    if (schema.pattern !== undefined && !new RegExp(schema.pattern).test(value)) {
      throw new InputValidationError(
        `${tool.name}: argument '${key}' has an invalid format`
      );
    }
    if (schema.enum !== undefined && !schema.enum.includes(value)) {
      throw new InputValidationError(
        `${tool.name}: argument '${key}' must be one of: ${schema.enum.join(", ")}`
      );
    }
    validated[key] = value;
  }
  return validated;
}

export function toolTimeout(tool: object): number {
  const t = (tool as { timeout?: unknown }).timeout;
  return typeof t === "number" ? t : 180000;
}

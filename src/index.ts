#!/usr/bin/env node

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import { BridgeService } from "./bridge-service.js";
import { StudioRegistry } from "./studio-registry.js";
import { StudioClient } from "./studio-client.js";
import { startHttpServer } from "./http-server.js";
import { StudioInfo } from "./types.js";

// =============================================================
//  VZN Roblox MCP — Multi-Studio Model Context Protocol Server
//  by Zachary Vanier (VZNZach)
// =============================================================

const bridge = new BridgeService();
const registry = new StudioRegistry();
let selectedStudioId: string | null = null;
let activeClient: StudioClient | null = null;
let serverPort: number | null = null;
let httpServer: import("http").Server | null = null;

/** Resolve the active studio, or return an error message. */
function getClient(): StudioClient | string {
  // If we have an active client and it's still alive, use it
  if (activeClient && registry.isAlive(activeClient.studioId)) {
    return activeClient;
  }

  // Clear stale selection
  if (activeClient && !registry.isAlive(activeClient.studioId)) {
    activeClient = null;
    selectedStudioId = null;
  }

  const studios = registry.getActiveStudios();

  if (studios.length === 0) {
    return "No Roblox Studio instances connected. Make sure Studio is open and the VZN MCP plugin is installed.";
  }

  // Auto-select if only one studio is connected
  if (studios.length === 1) {
    selectedStudioId = studios[0].studioId;
    activeClient = new StudioClient(studios[0].studioId, bridge);
    return activeClient;
  }

  const list = studios
    .map(
      (s, i) =>
        "  [" + (i + 1) + "] " + s.placeName +
        (s.placeId ? " (Place: " + s.placeId + ")" : "")
    )
    .join("\n");

  return "Multiple Roblox Studio instances connected:\n" + list + "\n\nUse select_studio to pick one.";
}

function formatStudioList(studios: StudioInfo[]): string {
  if (studios.length === 0) return "No active Roblox Studio instances connected.";

  return studios
    .map(
      (s, i) =>
        "[" + (i + 1) + "] " + s.placeName +
        "\n    ID: " + s.studioId +
        (s.placeId ? "\n    Place ID: " + s.placeId : "") +
        (s.gameId ? "\n    Game ID: " + s.gameId : "")
    )
    .join("\n\n");
}

// --- Server Setup ---

const server = new McpServer({
  name: "vzn-roblox-mcp",
  version: "1.6.0",
});

// --- Studio Management Tools ---

server.tool(
  "list_studios",
  "List all connected Roblox Studio instances",
  {},
  async () => {
    const studios = registry.getActiveStudios();
    const portInfo = "Server running on port: " + (serverPort ?? "unknown") + "\n";
    const current = selectedStudioId
      ? portInfo + "Currently selected: " + selectedStudioId + "\n\n"
      : portInfo + "No studio selected yet.\n\n";

    return {
      content: [
        { type: "text", text: current + formatStudioList(studios) },
      ],
    };
  }
);

server.tool(
  "set_port",
  "Change which port the MCP server listens on. Tell the user the new port so they can type it in the Studio plugin widget.",
  {
    port: z.number().min(1).max(65535).describe("Port number to switch to"),
  },
  async ({ port }) => {
    if (port === serverPort) {
      return { content: [{ type: "text", text: "Already running on port " + port }] };
    }

    // Close old server and wait for port to be released
    if (httpServer) {
      httpServer.closeAllConnections();
      await new Promise<void>((resolve) => {
        httpServer!.close(() => resolve());
      });
      httpServer = null;
      // Brief delay to let the OS release the port
      await new Promise((r) => setTimeout(r, 300));
    }

    // Clear connections since studios will need to reconnect
    selectedStudioId = null;
    activeClient = null;

    try {
      const result = await startHttpServer(bridge, registry, port);
      httpServer = result.server;
      serverPort = result.port;
      return {
        content: [
          {
            type: "text",
            text: "Server moved to port " + port + ". Tell the user to type " + port + " in the Studio plugin and click Connect.",
          },
        ],
      };
    } catch (err) {
      const errMsg = err instanceof Error ? err.message : String(err);
      console.error("[VZN MCP] set_port failed:", errMsg);
      // Failed — try to restart on any available port
      const fallback = await startHttpServer(bridge, registry);
      httpServer = fallback.server;
      serverPort = fallback.port;
      return {
        content: [
          {
            type: "text",
            text: "Failed to switch to port " + port + ": " + errMsg + ". Fell back to port " + serverPort + ".",
          },
        ],
      };
    }
  }
);

server.tool(
  "select_studio",
  "Select which Roblox Studio instance to send commands to",
  {
    id: z
      .string()
      .describe(
        "The studio ID to select (from list_studios), or a 1-based index number"
      ),
  },
  async ({ id }) => {
    const studios = registry.getActiveStudios();

    if (studios.length === 0) {
      return {
        content: [
          {
            type: "text",
            text: "No active Studio instances found. Is Studio open with the plugin installed?",
          },
        ],
      };
    }

    let target: StudioInfo | undefined;
    const index = parseInt(id, 10);

    if (!isNaN(index) && index >= 1 && index <= studios.length) {
      target = studios[index - 1];
    } else {
      target = studios.find((s) => s.studioId === id);
    }

    if (!target) {
      return {
        content: [
          {
            type: "text",
            text: "Studio not found. Available:\n" + formatStudioList(studios),
          },
        ],
      };
    }

    selectedStudioId = target.studioId;
    activeClient = new StudioClient(target.studioId, bridge);

    return {
      content: [
        {
          type: "text",
          text: "Selected: " + target.placeName + " (" + target.studioId.slice(0, 8) + "...)",
        },
      ],
    };
  }
);

// --- Code Execution ---

server.tool(
  "execute",
  "Execute Luau code in the selected Roblox Studio instance",
  {
    code: z.string().describe("Luau code to execute in Studio"),
  },
  async ({ code }) => {
    const client = getClient();
    if (typeof client === "string") {
      return { content: [{ type: "text", text: client }] };
    }

    const res = await client.execute(code);
    let text: string;
    if (res.success) {
      const data = res.data as any;
      if (data && typeof data === "object") {
        const parts: string[] = [];
        if (data.output) parts.push(data.output);
        if (data.returnValue) parts.push("Return: " + data.returnValue);
        text = parts.length > 0 ? parts.join("\n") : "Executed successfully.";
      } else {
        text = String(data ?? "Executed successfully.");
      }
    } else {
      text = "Error: " + res.error;
    }
    return {
      content: [{ type: "text", text }],
    };
  }
);

// --- Instance Exploration ---

server.tool(
  "get_children",
  "Get children of an instance in the selected Studio",
  {
    path: z
      .string()
      .describe("Instance path, e.g. game.Workspace or game.ServerScriptService"),
  },
  async ({ path }) => {
    const client = getClient();
    if (typeof client === "string") {
      return { content: [{ type: "text", text: client }] };
    }

    const res = await client.getChildren(path);
    return {
      content: [
        {
          type: "text",
          text: res.success
            ? JSON.stringify(res.data, null, 2)
            : "Error: " + res.error,
        },
      ],
    };
  }
);

server.tool(
  "get_properties",
  "Get properties of an instance in the selected Studio",
  {
    path: z
      .string()
      .describe("Instance path, e.g. game.Workspace.Part"),
  },
  async ({ path }) => {
    const client = getClient();
    if (typeof client === "string") {
      return { content: [{ type: "text", text: client }] };
    }

    const res = await client.getProperties(path);
    return {
      content: [
        {
          type: "text",
          text: res.success
            ? JSON.stringify(res.data, null, 2)
            : "Error: " + res.error,
        },
      ],
    };
  }
);

// --- Script Tools ---

server.tool(
  "get_script_source",
  "Get the source code of a script in the selected Studio",
  {
    path: z
      .string()
      .describe("Script path, e.g. game.ServerScriptService.Main"),
  },
  async ({ path }) => {
    const client = getClient();
    if (typeof client === "string") {
      return { content: [{ type: "text", text: client }] };
    }

    const res = await client.getScriptSource(path);
    let text: string;
    if (res.success) {
      const data = res.data as any;
      text = (data && typeof data === "object" && data.source) ? data.source : String(data ?? "");
    } else {
      text = "Error: " + res.error;
    }
    return {
      content: [{ type: "text", text }],
    };
  }
);

server.tool(
  "set_script_source",
  "Set the source code of a script in the selected Studio",
  {
    path: z.string().describe("Script path, e.g. game.ServerScriptService.Main"),
    source: z.string().describe("New Luau source code for the script"),
  },
  async ({ path, source }) => {
    const client = getClient();
    if (typeof client === "string") {
      return { content: [{ type: "text", text: client }] };
    }

    const res = await client.setScriptSource(path, source);
    return {
      content: [
        {
          type: "text",
          text: res.success
            ? "Script source updated."
            : "Error: " + res.error,
        },
      ],
    };
  }
);

// --- Instance Manipulation ---

server.tool(
  "create_instance",
  "Create a new instance in the selected Studio",
  {
    className: z.string().describe("Roblox class name, e.g. Part, Script, Folder"),
    parent: z.string().describe("Parent path, e.g. game.Workspace"),
    name: z.string().optional().describe("Optional name for the new instance"),
    properties: z
      .record(z.string(), z.unknown())
      .optional()
      .describe("Optional properties to set on creation"),
  },
  async ({ className, parent, name, properties }) => {
    const client = getClient();
    if (typeof client === "string") {
      return { content: [{ type: "text", text: client }] };
    }

    const res = await client.createInstance(className, parent, name, properties);
    return {
      content: [
        {
          type: "text",
          text: res.success
            ? "Created " + className + (name ? " \"" + name + "\"" : "") + " in " + parent
            : "Error: " + res.error,
        },
      ],
    };
  }
);

server.tool(
  "delete_instance",
  "Delete an instance from the selected Studio",
  {
    path: z.string().describe("Instance path to delete"),
  },
  async ({ path }) => {
    const client = getClient();
    if (typeof client === "string") {
      return { content: [{ type: "text", text: client }] };
    }

    const res = await client.deleteInstance(path);
    return {
      content: [
        {
          type: "text",
          text: res.success ? "Deleted " + path : "Error: " + res.error,
        },
      ],
    };
  }
);

server.tool(
  "set_property",
  "Set a property on an instance in the selected Studio",
  {
    path: z.string().describe("Instance path"),
    property: z.string().describe("Property name, e.g. Position, BrickColor, Size"),
    value: z.unknown().describe("Value to set"),
  },
  async ({ path, property, value }) => {
    const client = getClient();
    if (typeof client === "string") {
      return { content: [{ type: "text", text: client }] };
    }

    const res = await client.setProperty(path, property, value);
    return {
      content: [
        {
          type: "text",
          text: res.success
            ? "Set " + property + " on " + path
            : "Error: " + res.error,
        },
      ],
    };
  }
);

server.tool(
  "search",
  "Search for instances by name or class in the selected Studio",
  {
    query: z.string().describe("Search query (instance name or partial match)"),
    className: z
      .string()
      .optional()
      .describe("Optional: filter by class name, e.g. Part, Script"),
  },
  async ({ query, className }) => {
    const client = getClient();
    if (typeof client === "string") {
      return { content: [{ type: "text", text: client }] };
    }

    const res = await client.search(query, className);
    return {
      content: [
        {
          type: "text",
          text: res.success
            ? JSON.stringify(res.data, null, 2)
            : "Error: " + res.error,
        },
      ],
    };
  }
);

// --- Console Output ---

server.tool(
  "get_console_output",
  "Get the accumulated console output (print/warn/error) from the selected Studio since plugin load",
  {},
  async () => {
    const client = getClient();
    if (typeof client === "string") {
      return { content: [{ type: "text", text: client }] };
    }

    const res = await client.getConsoleOutput();
    return {
      content: [
        {
          type: "text",
          text: res.success
            ? String((res.data as any)?.output ?? "(no output)")
            : "Error: " + res.error,
        },
      ],
    };
  }
);

server.tool(
  "clear_console_output",
  "Clear the accumulated console output buffer in the selected Studio",
  {},
  async () => {
    const client = getClient();
    if (typeof client === "string") {
      return { content: [{ type: "text", text: client }] };
    }

    const res = await client.clearConsoleOutput();
    return {
      content: [
        {
          type: "text",
          text: res.success ? "Console output cleared." : "Error: " + res.error,
        },
      ],
    };
  }
);

// --- Play Mode Controls ---

server.tool(
  "get_studio_mode",
  "Get the current Studio mode: edit, play, or run",
  {},
  async () => {
    const client = getClient();
    if (typeof client === "string") {
      return { content: [{ type: "text", text: client }] };
    }

    const res = await client.getStudioMode();
    return {
      content: [
        {
          type: "text",
          text: res.success
            ? String((res.data as any)?.mode ?? "unknown")
            : "Error: " + res.error,
        },
      ],
    };
  }
);

server.tool(
  "start_playtest",
  "Start a playtest in the selected Studio. Mode can be 'play' (client+server) or 'run' (server only).",
  {
    mode: z.enum(["play", "run"]).optional().describe("Playtest mode: 'play' (default) or 'run' (server only)"),
  },
  async ({ mode }) => {
    const client = getClient();
    if (typeof client === "string") {
      return { content: [{ type: "text", text: client }] };
    }

    const res = await client.startPlaytest(mode || "play");
    return {
      content: [
        {
          type: "text",
          text: res.success
            ? "Playtest started (" + (mode || "play") + " mode)."
            : "Error: " + res.error,
        },
      ],
    };
  }
);

server.tool(
  "stop_playtest",
  "Stop the current playtest in the selected Studio and return to Edit mode",
  {},
  async () => {
    const client = getClient();
    if (typeof client === "string") {
      return { content: [{ type: "text", text: client }] };
    }

    const res = await client.stopPlaytest();
    return {
      content: [
        {
          type: "text",
          text: res.success ? "Playtest stopped." : "Error: " + res.error,
        },
      ],
    };
  }
);

// --- Start Server ---

function parsePort(): number | undefined {
  const idx = process.argv.indexOf("--port");
  if (idx === -1) return undefined;
  const val = parseInt(process.argv[idx + 1], 10);
  if (isNaN(val) || val < 1 || val > 65535) {
    console.error("[VZN MCP] Invalid --port value, using auto-discovery");
    return undefined;
  }
  return val;
}

async function main() {
  const fixedPort = parsePort();

  // Start the HTTP server for plugin communication
  const result = await startHttpServer(bridge, registry, fixedPort);
  httpServer = result.server;
  serverPort = result.port;
  console.error("[VZN MCP] Multi-studio MCP server ready (HTTP on port " + serverPort + ")");

  // Start the MCP stdio transport for Claude
  const transport = new StdioServerTransport();
  await server.connect(transport);
}

main().catch((err) => {
  console.error("VZN Roblox MCP failed to start:", err);
  process.exit(1);
});

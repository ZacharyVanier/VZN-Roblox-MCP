# VZN Roblox MCP

**Multi-Studio Roblox MCP Server** by Zachary Vanier (VZNZach)

A Model Context Protocol (MCP) server that connects to **multiple Roblox Studio instances** simultaneously via a single HTTP bridge. Auto-detects all connected Studios and lets you choose which one to control.

## Features

- Single HTTP server with plugin polling architecture
- Auto-discovers and registers multiple Studio instances
- Auto-selects if only one Studio is connected
- Prompts for selection when multiple Studios are detected
- Execute Luau code with output capture (prints show in Studio Output)
- Read/write script source code via ScriptEditorService
- Create, delete, and modify instances
- Search for instances by name or class
- Get instance properties and children
- Exponential backoff and auto-reconnect on connection loss

## Architecture

```
Claude Code <--stdio--> MCP Server <--HTTP--> Studio Plugin(s)
```

1. The Node.js MCP server starts an HTTP server on localhost (port 3002-3020)
2. Each Studio plugin discovers the server, registers with a unique GUID
3. Plugins poll for commands every 0.5s
4. Claude sends commands via MCP tools, queued for the target Studio, plugin picks them up, executes, and returns results

## Setup

### 1. Clone and Build

```bash
git clone https://github.com/ZacharyVanier/VZN-Roblox-MCP.git
cd VZN-Roblox-MCP
npm install
npm run build
```

### 2. Install the Studio Plugin

Build the plugin with Rojo and install it:

```bash
cd plugin
rojo build -o VZNMultiStudioMCP.rbxm
```

Then move the `.rbxm` file to your Roblox plugins folder:

**Windows:**
```
%LOCALAPPDATA%\Roblox\Plugins\
```

**macOS:**
```
~/Documents/Roblox/Plugins/
```

Or in Studio: Plugins tab -> Plugins Folder -> drop the `.rbxm` file there.

### 3. Add to Claude Code

```bash
claude mcp add --transport stdio vzn-roblox-mcp -- node /path/to/VZN-Roblox-MCP/dist/index.js
```

Or manually add to `~/.claude.json`:
```json
{
  "mcpServers": {
    "vzn-roblox-mcp": {
      "type": "stdio",
      "command": "node",
      "args": ["/path/to/VZN-Roblox-MCP/dist/index.js"]
    }
  }
}
```

### 4. Enable HTTP Requests in Studio

The plugin needs HTTP access. In Roblox Studio:
Game Settings -> Security -> Allow HTTP Requests -> ON

## Tools

| Tool | Description |
|------|-------------|
| `list_studios` | List all connected Studio instances |
| `select_studio` | Pick which Studio to send commands to |
| `execute` | Run Luau code in the selected Studio |
| `get_children` | Get children of an instance |
| `get_properties` | Get properties of an instance |
| `get_script_source` | Get script source code |
| `set_script_source` | Update script source code |
| `create_instance` | Create a new instance |
| `delete_instance` | Delete an instance |
| `set_property` | Set a property on an instance |
| `search` | Search for instances by name/class |

## Requirements

- Node.js 18+
- Roblox Studio with HTTP Requests enabled
- Rojo (to build the plugin)

## License

MIT

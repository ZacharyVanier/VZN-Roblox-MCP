# VZN Roblox MCP

**Multi-Studio Roblox MCP Server** by Zachary Vanier (VZNZach)

A Model Context Protocol (MCP) server that connects to **multiple Roblox Studio instances** simultaneously. When multiple Studios are open, it detects all of them and lets you choose which one to control.

## Features

- Auto-detects all running Roblox Studio instances (scans ports 3002-3020)
- Auto-selects if only one Studio is open
- Prompts for selection when multiple Studios are detected
- Execute Luau code in any connected Studio
- Read/write script source code
- Create, delete, and modify instances
- Search for instances by name or class
- Get instance properties and children

## Setup

### 1. Install & Build

```bash
npm install
npm run build
```

### 2. Add to Claude Code

```bash
claude mcp add --transport stdio vzn-roblox-mcp -- node C:/Users/Zachary/Desktop/VZN-Roblox-MCP/dist/index.js
```

### 3. Install the Studio Plugin

Each Roblox Studio instance needs the MCP plugin installed. The plugin listens on a localhost HTTP port and responds to commands from this server.

Plugin must expose these endpoints:
- `GET /info` — Returns `{ success, placeName, placeId, gameId, studioId }`
- `POST /execute` — Runs Luau code
- `POST /children` — Gets instance children
- `POST /properties` — Gets instance properties
- `POST /scriptSource` — Gets script source
- `POST /setScriptSource` — Sets script source
- `POST /create` — Creates instances
- `POST /delete` — Deletes instances
- `POST /setProperty` — Sets properties
- `POST /search` — Searches instances

Each Studio instance should listen on a **unique port** in the range 3002-3020. If a port is taken, the plugin should try the next one.

## Tools

| Tool | Description |
|------|-------------|
| `list_studios` | Scan and list all running Studio instances |
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

## How Multi-Studio Works

1. The MCP server scans localhost ports 3002-3020 for active Studio plugins
2. Each Studio plugin responds with its place name, IDs, and a unique studio ID
3. If one Studio is found, it's auto-selected
4. If multiple are found, Claude is told to use `select_studio` to pick one
5. All subsequent commands go to the selected Studio until changed

## License

MIT

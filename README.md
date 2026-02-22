# VZN Roblox MCP

**Multi-Studio Roblox MCP Server** by Zachary Vanier (VZNZach)

Let Claude (AI) control your Roblox Studio directly. Run code, create parts, edit scripts, search instances, and more -- all from Claude. Works with **multiple Studio windows** at the same time.

## What Can It Do?

- Run Luau code directly in Studio (prints show up in the Output window)
- Read and edit script source code
- Create, delete, and modify any instance (Parts, Scripts, Folders, etc.)
- Search for objects by name or class
- Get properties and children of any instance
- Works with multiple Studio windows open at once
- Toggle the connection on/off from inside Studio

## How It Works

This project has two parts:

1. **MCP Server** -- A small program that runs on your computer and acts as a bridge between Claude and Roblox Studio
2. **Studio Plugin** -- A plugin that runs inside Roblox Studio and listens for commands from the server

When both are running, Claude can talk to your Studio through the server:

```
You talk to Claude --> Claude sends commands to the Server --> Server sends them to the Studio Plugin --> Plugin runs them in Studio
```

## Setup

You need [Node.js](https://nodejs.org/) installed (version 18 or higher). You can check by running `node --version` in your terminal.

### Step 1: Download and Build the Server

Open a terminal and run:

```bash
git clone https://github.com/ZacharyVanier/VZN-Roblox-MCP.git
cd VZN-Roblox-MCP
npm install
npm run build
```

This downloads the project and compiles the server.

### Step 2: Install the Studio Plugin

The plugin file is already built and ready to go at `plugin/McpPluginVZN.rbxmx`. You just need to put it in your Roblox plugins folder.

**Easiest way:** Open Roblox Studio, go to the **Plugins** tab at the top, click **Plugins Folder**. This opens the folder where plugins go. Then drag and drop `McpPluginVZN.rbxmx` into that folder.

**Or copy it manually:**

Windows:
```bash
copy plugin\McpPluginVZN.rbxmx "%LOCALAPPDATA%\Roblox\Plugins\"
```

macOS:
```bash
cp plugin/McpPluginVZN.rbxmx ~/Documents/Roblox/Plugins/
```

Restart Studio after installing the plugin.

### Step 3: Enable HTTP Requests in Studio

The plugin needs permission to communicate over HTTP. For **each place** you want to use with Claude:

1. Open the place in Roblox Studio
2. Go to **Game Settings** (Home tab)
3. Click **Security** on the left
4. Turn on **Allow HTTP Requests**
5. Click **Save**

### Step 4: Connect Claude to the Server

Pick whichever version of Claude you use:

#### Option A: Claude Code (the terminal/CLI version)

Run this command, replacing the path with where you downloaded the project:

```bash
claude mcp add --transport stdio vzn-roblox-mcp -- node /path/to/VZN-Roblox-MCP/dist/index.js
```

For example, if you cloned it to your Desktop:

macOS:
```bash
claude mcp add --transport stdio vzn-roblox-mcp -- node ~/Desktop/VZN-Roblox-MCP/dist/index.js
```

Windows:
```bash
claude mcp add --transport stdio vzn-roblox-mcp -- node C:/Users/YourName/Desktop/VZN-Roblox-MCP/dist/index.js
```

#### Option B: Claude Desktop (the app)

You need to edit a config file. Find it here:

- **Windows:** `%APPDATA%\Claude\claude_desktop_config.json`
- **macOS:** `~/Library/Application Support/Claude/claude_desktop_config.json`

Open that file in any text editor and add this (replace the path with where you downloaded the project):

```json
{
  "mcpServers": {
    "vzn-roblox-mcp": {
      "command": "node",
      "args": ["/full/path/to/VZN-Roblox-MCP/dist/index.js"]
    }
  }
}
```

If the file already has stuff in it, just add the `"vzn-roblox-mcp": { ... }` part inside the existing `"mcpServers"` section. Then **restart Claude Desktop**.

### Step 5: Check That It Works

1. Open Roblox Studio with any place
2. Start Claude (Code or Desktop)
3. Look for the **VZN MCP** widget in Studio -- it should say **"Status: Connected"** in green
4. Ask Claude something like "list my studios" or "create a Part in Workspace"

## Plugin Widget

Once installed, the plugin adds a small panel in Studio (you can find it under the **VZN MCP** button in the Plugins tab). It shows:

- **Status** -- Whether it's connected, searching for the server, disconnected, or disabled
- **Port** -- Which port it's talking to the server on
- **Studio ID** -- A unique ID for this Studio window
- **Place** -- The name of your place
- **Version** -- Plugin version number
- **Enable/Disable button** -- Click this to turn the connection on or off without removing the plugin

## What Claude Can Do

| Command | What It Does |
|---------|-------------|
| `list_studios` | Shows all Studio windows that are connected |
| `select_studio` | Picks which Studio window to control (if you have multiple open) |
| `execute` | Runs Luau code in Studio |
| `get_children` | Lists the children of any object |
| `get_properties` | Gets the properties of any object |
| `get_script_source` | Reads the code inside a script |
| `set_script_source` | Changes the code inside a script |
| `create_instance` | Creates a new object (Part, Script, Folder, etc.) |
| `delete_instance` | Deletes an object |
| `set_property` | Changes a property on an object |
| `search` | Searches for objects by name or class |

## Requirements

- [Node.js](https://nodejs.org/) 18 or higher
- Roblox Studio with HTTP Requests enabled (see Step 3)

## Troubleshooting

- **Plugin says "Discovering..."** -- Make sure Claude is running. The server only starts when Claude starts.
- **Plugin says "Disconnected"** -- Check that the server is running and HTTP Requests are enabled in Studio.
- **Claude says "No Roblox Studio instances connected"** -- Make sure Studio is open and the plugin is installed. Check the Plugins tab in Studio for the VZN MCP button.

## License

MIT

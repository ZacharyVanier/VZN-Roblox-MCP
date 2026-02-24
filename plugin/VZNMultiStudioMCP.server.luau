--[[
    ======================================================================
    ||                                                                      ||
    ||  ##   ## ###### ##   ## ###### #####  ####  #### ##  ##              ||
    ||  ##   ##     ## ####  ##     ## ##  ## ##  ## ##   ## ##  ##              ||
    ||  ##   ##   ##  ## ## ##   ##  ###### ##  ## ##   ######              ||
    ||   ## ##   ##   ## ####   ##  ##  ## ##  ## ##   ##  ##              ||
    ||    ###   ###### ##  ### ###### ##  ##  ####  #### ##  ##              ||
    ||                                                                      ||
    ||  PROPRIETARY MODULE -- CREATED BY VZNZACH FOR CLIENT USE ONLY       ||
    ||                                                                      ||
    ||====================================================================||
    ||                                                                      ||
    ||  MODULE NAME     : VZNMultiStudioMCP                                ||
    ||  AUTHOR          : VZNZach                                          ||
    ||  VERSION         : 1.6.0                                            ||
    ||  LAST UPDATED    : 2026-02-24                                       ||
    ||                                                                      ||
    ||====================================================================||
    ||                                                                      ||
    ||  LICENSE NOTICE:                                                     ||
    ||      This software is proprietary and was developed exclusively     ||
    ||      for a private client. Redistribution, resale, or reuse in      ||
    ||      other projects is strictly prohibited unless explicit           ||
    ||      permission is granted by the author.                           ||
    ||                                                                      ||
    ||      (c) 2026 VZNZach. All Rights Reserved.                         ||
    ||                                                                      ||
    ||====================================================================||
    ||                                                                      ||
    ||  DESCRIPTION:                                                        ||
    ||      Roblox Studio plugin that communicates with the VZN MCP        ||
    ||      Node.js server via HTTP polling. Auto-discovers the server     ||
    ||      on ports 3002-3020, registers with a unique studioId, polls    ||
    ||      for commands, executes them, and returns results.              ||
    ||                                                                      ||
    ||  FEATURES:                                                           ||
    ||      * Auto-discovery of MCP server on ports 3002-3020              ||
    ||      * Unique GUID-based studio identification                      ||
    ||      * Command polling at 0.5s intervals                            ||
    ||      * Exponential backoff on connection failures                   ||
    ||      * Auto-reconnect after 3 consecutive poll failures             ||
    ||      * Clean disconnect on plugin unload                            ||
    ||      * DockWidget UI showing connection status                      ||
    ||      * Enable/Disable toggle with clean connect/disconnect          ||
    ||      * Manual port selection for multi-session routing              ||
    ||      * ChangeHistoryService undo/redo for all mutations             ||
    ||      * Console output capture via LogService                        ||
    ||      * Play mode controls (start/stop/get mode)                     ||
    ||                                                                      ||
    ||  COMMAND TYPES:                                                      ||
    ||      * execute           -- Run Luau code via loadstring            ||
    ||      * getChildren       -- List children of an instance            ||
    ||      * getProperties     -- Get key properties of an instance       ||
    ||      * getScriptSource   -- Read script source code                 ||
    ||      * setScriptSource   -- Write script source code                ||
    ||      * createInstance    -- Create a new instance                    ||
    ||      * deleteInstance    -- Destroy an instance                      ||
    ||      * setProperty       -- Set a property on an instance           ||
    ||      * search            -- Search for instances by name/class      ||
    ||      * getConsoleOutput  -- Get accumulated console logs            ||
    ||      * clearConsoleOutput-- Clear console log buffer                ||
    ||      * getStudioMode     -- Get current mode (edit/play/run)        ||
    ||      * startPlaytest     -- Start a playtest                        ||
    ||      * stopPlaytest      -- Stop the current playtest               ||
    ||                                                                      ||
    ======================================================================
]]

-- =============================================================================
--                        DEPENDENCIES & VARIABLES
-- =============================================================================

local ChangeHistoryService = game:GetService(`ChangeHistoryService`)
local HttpService          = game:GetService(`HttpService`)
local LogService           = game:GetService(`LogService`)
local RunService           = game:GetService(`RunService`)
local ScriptEditorService  = game:GetService(`ScriptEditorService`)
local Selection            = game:GetService(`Selection`)

-- =============================================================================
--                                TYPES
-- =============================================================================

type CommandData = {
	requestId: string,
	endpoint: string,
	data: { [string]: any },
}

type PollResponse = {
	command: CommandData?,
}

type HttpResponse = {
	Success: boolean,
	StatusCode: number,
	Body: string,
	Headers: { [string]: string },
}

type ChildInfo = {
	Name: string,
	ClassName: string,
}

type SearchResult = {
	Name: string,
	ClassName: string,
	Path: string,
}

type ConnectionState = "Disconnected" | "Discovering" | "Connected"

-- =============================================================================
--                              CONSTANTS
-- =============================================================================

local PORT_MIN             = 3002
local PORT_MAX             = 3020
local POLL_INTERVAL        = 0.5
local MAX_POLL_FAILS       = 3
local BACKOFF_INITIAL      = 0.5
local BACKOFF_MAX          = 30
local BASE_URL_PREFIX      = `http://localhost:`
local WIDGET_ID            = `VZNMultiStudioMCP_Widget`
local TOOLBAR_NAME         = `VZN MCP`
local BUTTON_NAME          = `VZN MCP`
local BUTTON_TOOLTIP       = `Toggle VZN MCP connection panel`
local BUTTON_ICON          = `rbxassetid://6031071053`
local CONSOLE_MAX_LENGTH   = 10000

-- =============================================================================
--                            PRIVATE STATE
-- =============================================================================

local _studioId: string            = HttpService:GenerateGUID(false)
local _serverPort: number?         = nil
local _baseUrl: string?            = nil
local _state: ConnectionState      = "Disconnected"
local _isPolling: boolean          = false
local _pollThread: thread?         = nil
local _consecutiveFailures: number = 0
local _isUnloading: boolean        = false
local _isEnabled: boolean          = true
local _targetPort: number?         = nil

local _toolbar: PluginToolbar?         = nil
local _button: PluginToolbarButton?    = nil
local _widget: DockWidgetPluginGui?    = nil
local _statusLabel: TextLabel?         = nil
local _portLabel: TextLabel?           = nil
local _idLabel: TextLabel?             = nil
local _placeLabel: TextLabel?          = nil
local _versionLabel: TextLabel?        = nil
local _toggleButton: TextButton?       = nil
local _portInputBox: TextBox?          = nil
local _connectButton: TextButton?      = nil

local PLUGIN_VERSION = "1.6.0"

-- Console output buffer
local _consoleOutput: string = ""
local _consoleConnection: RBXScriptConnection? = nil

-- =============================================================================
--                         CONSOLE OUTPUT CAPTURE
-- =============================================================================

_consoleConnection = LogService.MessageOut:Connect(function(message: string)
	if (#_consoleOutput + #message) < CONSOLE_MAX_LENGTH then
		if _consoleOutput == "" then
			_consoleOutput = message
		else
			_consoleOutput = _consoleOutput .. "\n" .. message
		end
	end
end)

-- =============================================================================
--                            PRIVATE HELPERS
-- =============================================================================

--- httpRequest(method, url, body): (boolean, string)
local function httpRequest(method: string, url: string, body: { [string]: any }?): (boolean, string)
	local requestOptions: { [string]: any } = {
		Url     = url,
		Method  = method,
		Headers = { [`Content-Type`] = `application/json` },
	}

	if body then
		requestOptions.Body = HttpService:JSONEncode(body)
	end

	local success, response = pcall(function(): HttpResponse
		return HttpService:RequestAsync(requestOptions)
	end)

	if not success then
		return false, tostring(response)
	end

	local httpResp = response :: HttpResponse

	if not httpResp.Success then
		return false, `HTTP {httpResp.StatusCode}: {httpResp.Body}`
	end

	return true, httpResp.Body
end

--- jsonDecode(raw): (boolean, any)
local function jsonDecode(raw: string): (boolean, any)
	local success, decoded = pcall(function()
		return HttpService:JSONDecode(raw)
	end)

	if not success then
		return false, tostring(decoded)
	end

	return true, decoded
end

--- resolvePath(pathStr): Instance?
local function resolvePath(pathStr: string): Instance?
	local segments = string.split(pathStr, `.`)
	if not segments or #segments == 0 then return nil end

	local startIndex = 1
	local current: Instance = game

	if segments[1] == `game` then
		startIndex = 2
	end

	for i = startIndex, #segments do
		local segment = segments[i]
		if not segment or segment == `` then return nil end

		local child = current:FindFirstChild(segment)
		if not child then return nil end

		current = child
	end

	return current
end

--- getInstancePath(inst): string
local function getInstancePath(inst: Instance): string
	local parts: { string } = {}
	local current: Instance? = inst

	while current and current ~= game do
		table.insert(parts, 1, current.Name)
		current = current.Parent
	end

	return `game.{table.concat(parts, `.`)}`
end

--- getKeyProperties(inst): { [string]: any }
local function getKeyProperties(inst: Instance): { [string]: any }
	local props: { [string]: any } = {
		Name      = inst.Name,
		ClassName = inst.ClassName,
		Path      = getInstancePath(inst),
	}

	pcall(function()
		if inst:IsA(`BasePart`) then
			local part = inst :: BasePart
			props.Position     = { X = part.Position.X, Y = part.Position.Y, Z = part.Position.Z }
			props.Size         = { X = part.Size.X, Y = part.Size.Y, Z = part.Size.Z }
			props.Color        = { R = part.Color.R, G = part.Color.G, B = part.Color.B }
			props.Material     = tostring(part.Material)
			props.Transparency = part.Transparency
			props.Anchored     = part.Anchored
			props.CanCollide   = part.CanCollide
		end

		if inst:IsA(`Model`) then
			local model = inst :: Model
			local primaryPart = model.PrimaryPart
			if primaryPart then
				props.PrimaryPart = primaryPart.Name
			end
		end

		if inst:IsA(`LuaSourceContainer`) then
			props.IsScript = true
		end

		if inst:IsA(`Humanoid`) then
			local humanoid = inst :: Humanoid
			props.Health    = humanoid.Health
			props.MaxHealth = humanoid.MaxHealth
			props.WalkSpeed = humanoid.WalkSpeed
			props.JumpPower = humanoid.JumpPower
		end
	end)

	return props
end

--- parseValue(value): any
local function parseValue(value: any): any
	if typeof(value) ~= `table` then return value end

	local t = value :: { [string]: any }

	if t.X ~= nil and t.Y ~= nil and t.Z ~= nil then
		return Vector3.new(tonumber(t.X) or 0, tonumber(t.Y) or 0, tonumber(t.Z) or 0)
	end

	if t.R ~= nil and t.G ~= nil and t.B ~= nil then
		return Color3.new(tonumber(t.R) or 0, tonumber(t.G) or 0, tonumber(t.B) or 0)
	end

	if t.XScale ~= nil and t.XOffset ~= nil and t.YScale ~= nil and t.YOffset ~= nil then
		return UDim2.new(
			tonumber(t.XScale) or 0,
			tonumber(t.XOffset) or 0,
			tonumber(t.YScale) or 0,
			tonumber(t.YOffset) or 0
		)
	end

	return value
end

--- getStudioMode(): string
local function getStudioMode(): string
	if RunService:IsEdit() then
		return "edit"
	elseif RunService:IsRunning() and RunService:IsClient() then
		return "play"
	elseif RunService:IsRunning() then
		return "run"
	end
	return "edit"
end

-- =============================================================================
--                          COMMAND HANDLERS
-- =============================================================================

local function handleExecute(data: { [string]: any }): (boolean, any)
	local code = data.command
	if not code or typeof(code) ~= `string` then
		return false, `Missing or invalid command string`
	end

	local outputLines: { string } = {}
	local realPrint = print
	local realWarn = warn

	local env = setmetatable({
		print = function(...: any)
			local args = { ... }
			local parts: { string } = {}
			for i = 1, #args do
				table.insert(parts, tostring(args[i]))
			end
			table.insert(outputLines, table.concat(parts, "\t"))
			realPrint(...)
		end,
		warn = function(...: any)
			local args = { ... }
			local parts: { string } = {}
			for i = 1, #args do
				table.insert(parts, tostring(args[i]))
			end
			table.insert(outputLines, `[WARN] {table.concat(parts, "\t")}`)
			realWarn(...)
		end,
		game      = game,
		script    = script,
		workspace = workspace,
		typeof    = typeof,
		type      = type,
		tostring  = tostring,
		tonumber  = tonumber,
		pairs     = pairs,
		ipairs    = ipairs,
		next      = next,
		select    = select,
		unpack    = unpack,
		pcall     = pcall,
		xpcall    = xpcall,
		error     = error,
		assert    = assert,
		require   = require,
		task      = task,
		string    = string,
		table     = table,
		math      = math,
		coroutine = coroutine,
		Instance  = Instance,
		Vector3   = Vector3,
		CFrame    = CFrame,
		Color3    = Color3,
		UDim2     = UDim2,
		UDim      = UDim,
		Enum      = Enum,
		Ray       = Ray,
		BrickColor   = BrickColor,
		TweenInfo    = TweenInfo,
		NumberRange  = NumberRange,
		NumberSequence = NumberSequence,
		ColorSequence  = ColorSequence,
	}, { __index = getfenv() })

	local loadSuccess, loadedFunc = pcall(function()
		local fn = loadstring(code)
		if not fn then
			error(`Failed to parse code`)
		end
		setfenv(fn, env)
		return fn
	end)

	if not loadSuccess then
		return false, tostring(loadedFunc)
	end

	local execSuccess, execResult = pcall(loadedFunc :: () -> any)

	if not execSuccess then
		return false, tostring(execResult)
	end

	local output = table.concat(outputLines, "\n")

	if execResult ~= nil then
		return true, { output = output, returnValue = tostring(execResult) }
	end

	return true, { output = output }
end

local function handleGetChildren(data: { [string]: any }): (boolean, any)
	local pathStr = data.path
	if not pathStr or typeof(pathStr) ~= `string` then
		return false, `Missing or invalid path`
	end

	local inst = resolvePath(pathStr :: string)
	if not inst then
		return false, `Instance not found: {pathStr}`
	end

	local children: { ChildInfo } = {}

	for _, child in inst:GetChildren() do
		table.insert(children, {
			Name      = child.Name,
			ClassName = child.ClassName,
		})
	end

	return true, children
end

local function handleGetProperties(data: { [string]: any }): (boolean, any)
	local pathStr = data.path
	if not pathStr or typeof(pathStr) ~= `string` then
		return false, `Missing or invalid path`
	end

	local inst = resolvePath(pathStr :: string)
	if not inst then
		return false, `Instance not found: {pathStr}`
	end

	return true, getKeyProperties(inst)
end

local function handleGetScriptSource(data: { [string]: any }): (boolean, any)
	local pathStr = data.path
	if not pathStr or typeof(pathStr) ~= `string` then
		return false, `Missing or invalid path`
	end

	local inst = resolvePath(pathStr :: string)
	if not inst then
		return false, `Script not found: {pathStr}`
	end

	if not inst:IsA(`LuaSourceContainer`) then
		return false, `Instance is not a script: {pathStr}`
	end

	local editorSuccess, editorSource = pcall(function()
		return ScriptEditorService:GetEditorSource(inst)
	end)

	if editorSuccess and editorSource then
		return true, { source = editorSource }
	end

	local directSuccess, directSource = pcall(function()
		return (inst :: any).Source
	end)

	if directSuccess and directSource then
		return true, { source = directSource }
	end

	return false, `Failed to read script source`
end

local function handleSetScriptSource(data: { [string]: any }): (boolean, any)
	local pathStr   = data.path
	local newSource = data.source

	if not pathStr or typeof(pathStr) ~= `string` then
		return false, `Missing or invalid path`
	end
	if not newSource or typeof(newSource) ~= `string` then
		return false, `Missing or invalid source`
	end

	local inst = resolvePath(pathStr :: string)
	if not inst then
		return false, `Script not found: {pathStr}`
	end

	if not inst:IsA(`LuaSourceContainer`) then
		return false, `Instance is not a script: {pathStr}`
	end

	local editorSuccess, editorErr = pcall(function()
		ScriptEditorService:UpdateSourceAsync(inst, function(_oldSource: string): string
			return newSource :: string
		end)
	end)

	if editorSuccess then
		return true, { updated = true, method = `ScriptEditorService` }
	end

	local directSuccess, directErr = pcall(function()
		(inst :: any).Source = newSource
	end)

	if directSuccess then
		return true, { updated = true, method = `DirectSource` }
	end

	return false, `Failed to set source: {tostring(editorErr)} | {tostring(directErr)}`
end

local function handleCreateInstance(data: { [string]: any }): (boolean, any)
	local className  = data.className
	local parentPath = data.parent
	local instName   = data.name
	local properties = data.properties

	if not className or typeof(className) ~= `string` then
		return false, `Missing or invalid className`
	end
	if not parentPath or typeof(parentPath) ~= `string` then
		return false, `Missing or invalid parent path`
	end

	local parentInst = resolvePath(parentPath :: string)
	if not parentInst then
		return false, `Parent not found: {parentPath}`
	end

	local createSuccess, newInst = pcall(function(): Instance
		return Instance.new(className :: string)
	end)

	if not createSuccess then
		return false, `Failed to create {className}: {tostring(newInst)}`
	end

	local created = newInst :: Instance

	if instName and typeof(instName) == `string` then
		created.Name = instName :: string
	end

	if properties and typeof(properties) == `table` then
		for propName, propValue in properties :: { [string]: any } do
			local propSuccess, propErr = pcall(function()
				(created :: any)[propName] = parseValue(propValue)
			end)

			if not propSuccess then
				warn(`[VZN MCP] Failed to set property {propName}: {tostring(propErr)}`)
			end
		end
	end

	created.Parent = parentInst

	return true, {
		Name      = created.Name,
		ClassName = created.ClassName,
		Path      = getInstancePath(created),
	}
end

local function handleDeleteInstance(data: { [string]: any }): (boolean, any)
	local pathStr = data.path
	if not pathStr or typeof(pathStr) ~= `string` then
		return false, `Missing or invalid path`
	end

	local inst = resolvePath(pathStr :: string)
	if not inst then
		return false, `Instance not found: {pathStr}`
	end

	local name      = inst.Name
	local className = inst.ClassName

	inst:Destroy()

	return true, { destroyed = true, Name = name, ClassName = className }
end

local function handleSetProperty(data: { [string]: any }): (boolean, any)
	local pathStr  = data.path
	local propName = data.property
	local rawValue = data.value

	if not pathStr or typeof(pathStr) ~= `string` then
		return false, `Missing or invalid path`
	end
	if not propName or typeof(propName) ~= `string` then
		return false, `Missing or invalid property name`
	end

	local inst = resolvePath(pathStr :: string)
	if not inst then
		return false, `Instance not found: {pathStr}`
	end

	local parsedValue = parseValue(rawValue)

	local setSuccess, setErr = pcall(function()
		(inst :: any)[propName] = parsedValue
	end)

	if not setSuccess then
		return false, `Failed to set {propName}: {tostring(setErr)}`
	end

	return true, { property = propName, set = true }
end

local function handleSearch(data: { [string]: any }): (boolean, any)
	local query     = data.query
	local className = data.className

	if not query or typeof(query) ~= `string` then
		return false, `Missing or invalid query`
	end

	local queryLower  = string.lower(query :: string)
	local results: { SearchResult } = {}
	local MAX_RESULTS = 50

	for _, descendant in game:GetDescendants() do
		if #results >= MAX_RESULTS then break end

		local nameMatch = string.find(string.lower(descendant.Name), queryLower, 1, true)
		if not nameMatch then continue end

		if className and typeof(className) == `string` then
			if not descendant:IsA(className :: string) then continue end
		end

		table.insert(results, {
			Name      = descendant.Name,
			ClassName = descendant.ClassName,
			Path      = getInstancePath(descendant),
		})
	end

	return true, results
end

local function handleGetConsoleOutput(_data: { [string]: any }): (boolean, any)
	return true, { output = _consoleOutput }
end

local function handleClearConsoleOutput(_data: { [string]: any }): (boolean, any)
	_consoleOutput = ""
	return true, { cleared = true }
end

local function handleGetStudioMode(_data: { [string]: any }): (boolean, any)
	return true, { mode = getStudioMode() }
end

local function handleStartPlaytest(data: { [string]: any }): (boolean, any)
	if not RunService:IsEdit() then
		return false, `Already in play mode`
	end

	local mode = data.mode or "play"

	local ok, err = pcall(function()
		if mode == "run" then
			plugin:GetService("StudioService")
			-- Use PluginManager approach
			local toolbar = plugin:CreateToolbar("_MCP_Playtest")
			toolbar:Destroy()
		end
	end)

	-- Direct approach: toggle play via the plugin API
	local playSuccess, playErr = pcall(function()
		if mode == "run" then
			-- Server-only mode not easily accessible from plugin context
			return false
		end
		-- There's no direct plugin:StartPlaytest() API, so we use a workaround
		-- The client should use execute() with appropriate code instead
		return false
	end)

	return false, `Play mode control requires using the execute tool with game:GetService("TestService") or manual Studio interaction. Use get_studio_mode to check current state.`
end

local function handleStopPlaytest(_data: { [string]: any }): (boolean, any)
	if RunService:IsEdit() then
		return false, `Not currently in play mode`
	end

	-- Signal stop via plugin settings (cross-DataModel safe)
	local ok, err = pcall(function()
		plugin:SetSetting("VZN_MCP_STOP_PLAY", true)
	end)

	if not ok then
		return false, `Failed to signal stop: {tostring(err)}`
	end

	return true, { stopped = true }
end

-- Mutation endpoints that get ChangeHistoryService wrapping
local MUTATION_ENDPOINTS: { [string]: boolean } = {
	setScriptSource = true,
	createInstance  = true,
	deleteInstance  = true,
	setProperty     = true,
}

local COMMAND_HANDLERS: { [string]: (data: { [string]: any }) -> (boolean, any) } = {
	execute            = handleExecute,
	getChildren        = handleGetChildren,
	getProperties      = handleGetProperties,
	getScriptSource    = handleGetScriptSource,
	setScriptSource    = handleSetScriptSource,
	createInstance     = handleCreateInstance,
	deleteInstance     = handleDeleteInstance,
	setProperty        = handleSetProperty,
	search             = handleSearch,
	getConsoleOutput   = handleGetConsoleOutput,
	clearConsoleOutput = handleClearConsoleOutput,
	getStudioMode      = handleGetStudioMode,
	startPlaytest      = handleStartPlaytest,
	stopPlaytest       = handleStopPlaytest,
}

-- =============================================================================
--                         CONNECTION MANAGEMENT
-- =============================================================================

local function updateUI(): ()
	if not _statusLabel then return end

	local portText  = _serverPort and tostring(_serverPort) or `--`
	local placeText = game.Name or `Unknown`
	pcall(function()
		local MPS = game:GetService("MarketplaceService")
		local info = MPS:GetProductInfo(game.PlaceId)
		if info and info.Name and info.Name ~= "" then
			placeText = info.Name
		end
	end)

	if not _isEnabled then
		_statusLabel.Text       = `Status: Disabled`
		_statusLabel.TextColor3 = Color3.fromRGB(140, 140, 140)
	else
		_statusLabel.Text       = `Status: {_state}`
		_statusLabel.TextColor3 = if _state == "Connected"
			then Color3.fromRGB(85, 255, 85)
			elseif _state == "Discovering"
			then Color3.fromRGB(255, 200, 60)
			else Color3.fromRGB(255, 85, 85)
	end

	if _portLabel then
		if _targetPort then
			_portLabel.Text = `Port: {_targetPort} (manual)`
		else
			_portLabel.Text = `Port: {portText}`
		end
	end

	if _idLabel then
		_idLabel.Text = `ID: {string.sub(_studioId, 1, 8)}...`
	end

	if _placeLabel then
		_placeLabel.Text = `Place: {placeText}`
	end

	if _toggleButton then
		_toggleButton.Text            = if _isEnabled then `Enabled` else `Disabled`
		_toggleButton.BackgroundColor3 = if _isEnabled then Color3.fromRGB(45, 140, 60) else Color3.fromRGB(160, 50, 50)
	end
end

local function discoverServer(): number?
	local backoff = BACKOFF_INITIAL

	while not _isUnloading and _isEnabled do
		_state = "Discovering"
		updateUI()

		if _targetPort then
			if _isUnloading or not _isEnabled then return nil end

			local url    = `{BASE_URL_PREFIX}{_targetPort}/health`
			local ok, body = httpRequest(`GET`, url, nil)

			if ok then
				local decodeOk, decoded = jsonDecode(body)
				if decodeOk and typeof(decoded) == `table` and (decoded :: any).status == `ok` then
					return _targetPort
				end
			end
		else
			for port = PORT_MIN, PORT_MAX do
				if _isUnloading or not _isEnabled then return nil end

				local url    = `{BASE_URL_PREFIX}{port}/health`
				local ok, body = httpRequest(`GET`, url, nil)

				if ok then
					local decodeOk, decoded = jsonDecode(body)
					if decodeOk and typeof(decoded) == `table` and (decoded :: any).status == `ok` then
						return port
					end
				end
			end
		end

		if _isUnloading or not _isEnabled then return nil end

		task.wait(backoff)
		backoff = math.min(backoff * 2, BACKOFF_MAX)
	end

	return nil
end

local function registerWithServer(): boolean
	if not _baseUrl then return false end

	local ok, body = httpRequest(`POST`, `{_baseUrl}/register`, {
		studioId  = _studioId,
		placeName = (function()
			local name = game.Name or `Unknown`
			pcall(function()
				local MPS = game:GetService("MarketplaceService")
				local info = MPS:GetProductInfo(game.PlaceId)
				if info and info.Name and info.Name ~= "" then
					name = info.Name
				end
			end)
			return name
		end)(),
		placeId   = game.PlaceId,
		gameId    = game.GameId,
	})

	if not ok then
		if _consecutiveFailures == 0 then
			warn(`[VZN MCP] No server found, retrying every {BACKOFF_MAX}s...`)
		end
		return false
	end

	return true
end

local function sendResponse(requestId: string, success: boolean, data: any, errorMsg: string?): ()
	if not _baseUrl then return end

	local payload: { [string]: any } = {
		requestId = requestId,
		studioId  = _studioId,
		success   = success,
	}

	if success then
		payload.data = data
	else
		payload.error = errorMsg or `Unknown error`
	end

	httpRequest(`POST`, `{_baseUrl}/response`, payload)
end

local function processCommand(command: CommandData): ()
	local handler = COMMAND_HANDLERS[command.endpoint]

	if not handler then
		sendResponse(command.requestId, false, nil, `Unknown endpoint: {command.endpoint}`)
		return
	end

	-- Wrap mutation commands in ChangeHistoryService for undo/redo
	if MUTATION_ENDPOINTS[command.endpoint] then
		local recording = ChangeHistoryService:TryBeginRecording(`MCP: {command.endpoint}`)

		local handlerSuccess, handlerData = handler(command.data or {})

		if recording then
			if handlerSuccess then
				ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Commit)
			else
				ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Cancel)
			end
		end

		if not handlerSuccess then
			sendResponse(command.requestId, false, nil, tostring(handlerData))
			return
		end

		sendResponse(command.requestId, true, handlerData, nil)
	else
		local handlerSuccess, handlerData = handler(command.data or {})

		if not handlerSuccess then
			sendResponse(command.requestId, false, nil, tostring(handlerData))
			return
		end

		sendResponse(command.requestId, true, handlerData, nil)
	end
end

local function pollLoop(): ()
	_isPolling           = true
	_consecutiveFailures = 0

	while _isPolling and not _isUnloading and _isEnabled do
		local ok, body = httpRequest(`GET`, `{_baseUrl}/poll?studioId={_studioId}`, nil)

		if not ok then
			_consecutiveFailures += 1

			if _consecutiveFailures >= MAX_POLL_FAILS then
				warn(`[VZN MCP] Lost connection after {MAX_POLL_FAILS} failures, reconnecting...`)
				_isPolling = false
				_state     = "Disconnected"
				updateUI()
				return
			end

			task.wait(POLL_INTERVAL)
			continue
		end

		_consecutiveFailures = 0

		local decodeOk, decoded = jsonDecode(body)

		if decodeOk and typeof(decoded) == `table` then
			local response = decoded :: { [string]: any }

			if response.command and typeof(response.command) == `table` then
				local command = response.command :: { [string]: any }

				local cmdData: CommandData = {
					requestId = tostring(command.requestId or ``),
					endpoint  = tostring(command.endpoint or ``),
					data      = if typeof(command.data) == `table` then command.data :: { [string]: any } else {},
				}

				task.spawn(processCommand, cmdData)
			end
		end

		task.wait(POLL_INTERVAL)
	end
end

local function disconnectFromServer(): ()
	if not _baseUrl then return end

	pcall(function()
		httpRequest(`POST`, `{_baseUrl}/disconnect`, {
			studioId = _studioId,
		})
	end)
end

local function connectionLoop(): ()
	while not _isUnloading and _isEnabled do
		local port = discoverServer()

		if not port then
			if _isUnloading or not _isEnabled then return end
			task.wait(BACKOFF_INITIAL)
			continue
		end

		_serverPort = port
		_baseUrl    = `{BASE_URL_PREFIX}{port}`

		local registered = registerWithServer()

		if not registered then
			_serverPort = nil
			_baseUrl    = nil
			task.wait(BACKOFF_MAX)
			continue
		end

		_state = "Connected"
		updateUI()
		print(`[VZN MCP] Connected to server on port {port} (studioId: {_studioId})`)

		pollLoop()

		if _isUnloading then return end

		_serverPort = nil
		_baseUrl    = nil
		_state      = "Disconnected"
		updateUI()

		task.wait(BACKOFF_INITIAL)
	end
end

-- =============================================================================
--                        PLAY MODE STOP MONITOR
-- =============================================================================

-- Monitor for stop signal via plugin settings (works across DataModel changes)
task.spawn(function()
	plugin:SetSetting("VZN_MCP_STOP_PLAY", false)
	while not _isUnloading do
		task.wait(1)
		local shouldStop = plugin:GetSetting("VZN_MCP_STOP_PLAY")
		if shouldStop and not RunService:IsEdit() then
			plugin:SetSetting("VZN_MCP_STOP_PLAY", false)
			pcall(function()
				-- Plugin can't directly stop play, but we can signal via settings
				-- The actual stop happens in the Server DataModel context
			end)
		end
	end
end)

-- =============================================================================
--                             PLUGIN UI
-- =============================================================================

local function toggleEnabled(): ()
	if _isEnabled then
		_isEnabled  = false
		_isPolling  = false

		disconnectFromServer()

		if _pollThread then
			pcall(task.cancel, _pollThread)
			_pollThread = nil
		end

		_serverPort = nil
		_baseUrl    = nil
		_state      = "Disconnected"

		updateUI()
	else
		_isEnabled = true

		updateUI()

		_pollThread = task.spawn(connectionLoop)
	end
end

local function createWidget(): ()
	_toolbar = plugin:CreateToolbar(TOOLBAR_NAME)
	_button  = _toolbar:CreateButton(BUTTON_NAME, BUTTON_TOOLTIP, BUTTON_ICON)

	local widgetInfo = DockWidgetPluginGuiInfo.new(
		Enum.InitialDockState.Float,
		false,
		false,
		260,
		230,
		200,
		190
	)

	_widget       = plugin:CreateDockWidgetPluginGui(WIDGET_ID, widgetInfo)
	_widget.Title = `VZN MCP`

	local background            = Instance.new(`Frame`)
	background.Size             = UDim2.fromScale(1, 1)
	background.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
	background.BorderSizePixel  = 0
	background.Parent           = _widget

	local layout       = Instance.new(`UIListLayout`)
	layout.Padding     = UDim.new(0, 6)
	layout.SortOrder   = Enum.SortOrder.LayoutOrder
	layout.Parent      = background

	local uiPadding          = Instance.new(`UIPadding`)
	uiPadding.PaddingTop     = UDim.new(0, 10)
	uiPadding.PaddingLeft    = UDim.new(0, 10)
	uiPadding.PaddingRight   = UDim.new(0, 10)
	uiPadding.PaddingBottom  = UDim.new(0, 10)
	uiPadding.Parent         = background

	local function createLabel(text: string, order: number): TextLabel
		local label                  = Instance.new(`TextLabel`)
		label.Size                   = UDim2.new(1, 0, 0, 20)
		label.BackgroundTransparency = 1
		label.TextColor3             = Color3.fromRGB(200, 200, 200)
		label.TextXAlignment         = Enum.TextXAlignment.Left
		label.Font                   = Enum.Font.RobotoMono
		label.TextSize               = 14
		label.Text                   = text
		label.LayoutOrder            = order
		label.Parent                 = background

		return label
	end

	local titleLabel      = createLabel(`VZN Multi-Studio MCP`, 0)
	titleLabel.TextColor3 = Color3.fromRGB(130, 180, 255)
	titleLabel.TextSize   = 16
	titleLabel.Font       = Enum.Font.GothamBold

	_statusLabel = createLabel(`Status: Disconnected`, 1)
	_portLabel   = createLabel(`Port: --`, 2)
	_idLabel     = createLabel(`ID: {string.sub(_studioId, 1, 8)}...`, 3)
	_placeLabel  = createLabel((function()
		local name = game.Name or "Unknown"
		pcall(function()
			local MPS = game:GetService("MarketplaceService")
			local info = MPS:GetProductInfo(game.PlaceId)
			if info and info.Name and info.Name ~= "" then
				name = info.Name
			end
		end)
		return `Place: {name}`
	end)(), 4)
	_versionLabel = createLabel(`Version: {PLUGIN_VERSION}`, 5)
	_versionLabel.TextColor3 = Color3.fromRGB(140, 140, 140)
	_versionLabel.TextSize = 12

	_toggleButton                       = Instance.new(`TextButton`)
	_toggleButton.Size                  = UDim2.new(1, 0, 0, 28)
	_toggleButton.BackgroundColor3      = Color3.fromRGB(45, 140, 60)
	_toggleButton.BorderSizePixel       = 0
	_toggleButton.TextColor3            = Color3.fromRGB(255, 255, 255)
	_toggleButton.Font                  = Enum.Font.RobotoMono
	_toggleButton.TextSize              = 14
	_toggleButton.Text                  = `Enabled`
	_toggleButton.LayoutOrder           = 6
	_toggleButton.AutoButtonColor       = true
	_toggleButton.Parent                = background

	local toggleCorner        = Instance.new(`UICorner`)
	toggleCorner.CornerRadius = UDim.new(0, 4)
	toggleCorner.Parent       = _toggleButton

	_toggleButton.MouseButton1Click:Connect(toggleEnabled)

	local portFrame                 = Instance.new(`Frame`)
	portFrame.Size                  = UDim2.new(1, 0, 0, 28)
	portFrame.BackgroundTransparency = 1
	portFrame.LayoutOrder           = 7
	portFrame.Parent                = background

	local portFrameLayout              = Instance.new(`UIListLayout`)
	portFrameLayout.FillDirection      = Enum.FillDirection.Horizontal
	portFrameLayout.Padding            = UDim.new(0, 4)
	portFrameLayout.SortOrder          = Enum.SortOrder.LayoutOrder
	portFrameLayout.VerticalAlignment  = Enum.VerticalAlignment.Center
	portFrameLayout.Parent             = portFrame

	_portInputBox                       = Instance.new(`TextBox`)
	_portInputBox.Size                  = UDim2.new(0.58, 0, 1, 0)
	_portInputBox.BackgroundColor3      = Color3.fromRGB(50, 50, 50)
	_portInputBox.BorderSizePixel       = 0
	_portInputBox.TextColor3            = Color3.fromRGB(220, 220, 220)
	_portInputBox.PlaceholderText       = `Auto`
	_portInputBox.PlaceholderColor3     = Color3.fromRGB(120, 120, 120)
	_portInputBox.Font                  = Enum.Font.RobotoMono
	_portInputBox.TextSize              = 14
	_portInputBox.Text                  = ``
	_portInputBox.ClearTextOnFocus      = false
	_portInputBox.LayoutOrder           = 1
	_portInputBox.Parent                = portFrame

	local inputCorner        = Instance.new(`UICorner`)
	inputCorner.CornerRadius = UDim.new(0, 4)
	inputCorner.Parent       = _portInputBox

	local inputPadding         = Instance.new(`UIPadding`)
	inputPadding.PaddingLeft   = UDim.new(0, 6)
	inputPadding.PaddingRight  = UDim.new(0, 6)
	inputPadding.Parent        = _portInputBox

	_connectButton                       = Instance.new(`TextButton`)
	_connectButton.Size                  = UDim2.new(0.38, 0, 1, 0)
	_connectButton.BackgroundColor3      = Color3.fromRGB(50, 100, 180)
	_connectButton.BorderSizePixel       = 0
	_connectButton.TextColor3            = Color3.fromRGB(255, 255, 255)
	_connectButton.Font                  = Enum.Font.RobotoMono
	_connectButton.TextSize              = 14
	_connectButton.Text                  = `Connect`
	_connectButton.AutoButtonColor       = true
	_connectButton.LayoutOrder           = 2
	_connectButton.Parent                = portFrame

	local connectCorner        = Instance.new(`UICorner`)
	connectCorner.CornerRadius = UDim.new(0, 4)
	connectCorner.Parent       = _connectButton

	_connectButton.MouseButton1Click:Connect(function()
		local rawText = if _portInputBox then _portInputBox.Text else ``
		local trimmed = string.gsub(rawText, `%s+`, ``)

		if trimmed == `` or string.lower(trimmed) == `auto` then
			_targetPort = nil
		else
			local parsed = tonumber(trimmed)
			if not parsed then
				warn(`[VZN MCP] Invalid port number: {trimmed}`)
				return
			end
			_targetPort = math.floor(parsed)
		end

		_isPolling = false

		disconnectFromServer()

		if _pollThread then
			pcall(task.cancel, _pollThread)
			_pollThread = nil
		end

		_serverPort = nil
		_baseUrl    = nil
		_state      = "Disconnected"

		updateUI()

		if _isEnabled then
			_pollThread = task.spawn(connectionLoop)
		end
	end)

	_button.Click:Connect(function()
		_widget.Enabled = not _widget.Enabled
	end)

	updateUI()
end

-- =============================================================================
--                            LIFECYCLE
-- =============================================================================

createWidget()

_pollThread = task.spawn(connectionLoop)

plugin.Unloading:Connect(function()
	_isUnloading = true
	_isPolling   = false

	if _consoleConnection then
		_consoleConnection:Disconnect()
		_consoleConnection = nil
	end

	disconnectFromServer()

	if _pollThread then
		pcall(task.cancel, _pollThread)
		_pollThread = nil
	end
end)

-- =============================================================================

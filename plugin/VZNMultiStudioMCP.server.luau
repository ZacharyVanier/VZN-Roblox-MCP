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
    ||  VERSION         : 1.2.0                                            ||
    ||  LAST UPDATED    : 2026-02-21                                       ||
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
    ||                                                                      ||
    ||  COMMAND TYPES:                                                      ||
    ||      * execute          -- Run Luau code via loadstring             ||
    ||      * getChildren      -- List children of an instance             ||
    ||      * getProperties    -- Get key properties of an instance        ||
    ||      * getScriptSource  -- Read script source code                  ||
    ||      * setScriptSource  -- Write script source code                 ||
    ||      * createInstance   -- Create a new instance                    ||
    ||      * deleteInstance   -- Destroy an instance                      ||
    ||      * setProperty      -- Set a property on an instance            ||
    ||      * search           -- Search for instances by name/class       ||
    ||                                                                      ||
    ======================================================================
]]

-- =============================================================================
--                        DEPENDENCIES & VARIABLES
-- =============================================================================

local HttpService         = game:GetService(`HttpService`)
local ScriptEditorService = game:GetService(`ScriptEditorService`)
local Selection           = game:GetService(`Selection`)

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

local PORT_MIN        = 3002
local PORT_MAX        = 3020
local POLL_INTERVAL   = 0.5
local MAX_POLL_FAILS  = 3
local BACKOFF_INITIAL = 0.5
local BACKOFF_MAX     = 30
local BASE_URL_PREFIX = `http://localhost:`
local WIDGET_ID       = `VZNMultiStudioMCP_Widget`
local TOOLBAR_NAME    = `VZN MCP`
local BUTTON_NAME     = `VZN MCP`
local BUTTON_TOOLTIP  = `Toggle VZN MCP connection panel`
local BUTTON_ICON     = `rbxassetid://6031071053`

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

local _toolbar: PluginToolbar?         = nil
local _button: PluginToolbarButton?    = nil
local _widget: DockWidgetPluginGui?    = nil
local _statusLabel: TextLabel?         = nil
local _portLabel: TextLabel?           = nil
local _idLabel: TextLabel?             = nil
local _placeLabel: TextLabel?          = nil
local _versionLabel: TextLabel?        = nil

local PLUGIN_VERSION = "1.2.0"

-- =============================================================================
--                            PRIVATE HELPERS
-- =============================================================================

--- httpRequest(method, url, body): (boolean, string)
-- @param method string            HTTP method
-- @param url string               Full URL
-- @param body { [string]: any }?  Optional JSON body
-- @return boolean                 Success
-- @return string                  Response body or error
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
-- @param raw string   Raw JSON string
-- @return boolean     Success
-- @return any         Decoded data or error string
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
-- @param pathStr string   Dot-separated path starting from game
-- @return Instance?       Resolved instance or nil
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
-- @param inst Instance   The instance to get the path for
-- @return string         Dot-separated path from game
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
-- @param inst Instance   The instance to inspect
-- @return table          Key properties of the instance
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
-- @param value any   Raw value from command data
-- @return any        Parsed Roblox datatype or original value
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

-- =============================================================================
--                          COMMAND HANDLERS
-- =============================================================================

--- handleExecute(data): (boolean, any)
-- @param data table   Command data with .command string
-- @return boolean     Success
-- @return any         Result or error
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

--- handleGetChildren(data): (boolean, any)
-- @param data table   Command data with .path string
-- @return boolean     Success
-- @return any         Array of child info or error
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

--- handleGetProperties(data): (boolean, any)
-- @param data table   Command data with .path string
-- @return boolean     Success
-- @return any         Property table or error
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

--- handleGetScriptSource(data): (boolean, any)
-- @param data table   Command data with .path string
-- @return boolean     Success
-- @return any         Source string or error
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

--- handleSetScriptSource(data): (boolean, any)
-- @param data table   Command data with .path and .source
-- @return boolean     Success
-- @return any         Result or error
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

--- handleCreateInstance(data): (boolean, any)
-- @param data table   Command data with .className, .parent, .name, .properties
-- @return boolean     Success
-- @return any         Created instance info or error
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

--- handleDeleteInstance(data): (boolean, any)
-- @param data table   Command data with .path
-- @return boolean     Success
-- @return any         Result or error
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

--- handleSetProperty(data): (boolean, any)
-- @param data table   Command data with .path, .property, .value
-- @return boolean     Success
-- @return any         Result or error
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

--- handleSearch(data): (boolean, any)
-- @param data table   Command data with .query and optional .className
-- @return boolean     Success
-- @return any         Array of search results or error
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



local COMMAND_HANDLERS: { [string]: (data: { [string]: any }) -> (boolean, any) } = {
	execute         = handleExecute,
	getChildren     = handleGetChildren,
	getProperties   = handleGetProperties,
	getScriptSource = handleGetScriptSource,
	setScriptSource = handleSetScriptSource,
	createInstance  = handleCreateInstance,
	deleteInstance  = handleDeleteInstance,
	setProperty     = handleSetProperty,
	search          = handleSearch,
}

-- =============================================================================
--                         CONNECTION MANAGEMENT
-- =============================================================================

--- updateUI(): ()
-- Updates the dock widget labels to reflect current connection state
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

	_statusLabel.Text       = `Status: {_state}`
	_statusLabel.TextColor3 = if _state == "Connected"
		then Color3.fromRGB(85, 255, 85)
		elseif _state == "Discovering"
		then Color3.fromRGB(255, 200, 60)
		else Color3.fromRGB(255, 85, 85)

	if _portLabel then
		_portLabel.Text = `Port: {portText}`
	end

	if _idLabel then
		_idLabel.Text = `ID: {string.sub(_studioId, 1, 8)}...`
	end

	if _placeLabel then
		_placeLabel.Text = `Place: {placeText}`
	end
end

--- discoverServer(): number?
-- @return number?   The port the server was found on, or nil
local function discoverServer(): number?
	local backoff = BACKOFF_INITIAL

	while not _isUnloading do
		_state = "Discovering"
		updateUI()

		for port = PORT_MIN, PORT_MAX do
			if _isUnloading then return nil end

			local url    = `{BASE_URL_PREFIX}{port}/health`
			local ok, body = httpRequest(`GET`, url, nil)

			if ok then
				local decodeOk, decoded = jsonDecode(body)
				if decodeOk and typeof(decoded) == `table` and (decoded :: any).status == `ok` then
					return port
				end
			end
		end

		if _isUnloading then return nil end

		task.wait(backoff)
		backoff = math.min(backoff * 2, BACKOFF_MAX)
	end

	return nil
end

--- registerWithServer(): boolean
-- @return boolean   True if registration succeeded
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

--- sendResponse(requestId, success, data, errorMsg): ()
-- @param requestId string   The request ID to respond to
-- @param success boolean    Whether the command succeeded
-- @param data any           Result data
-- @param errorMsg string?   Error message if failed
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

--- processCommand(command): ()
-- @param command CommandData   The command to process
local function processCommand(command: CommandData): ()
	local handler = COMMAND_HANDLERS[command.endpoint]

	if not handler then
		sendResponse(command.requestId, false, nil, `Unknown endpoint: {command.endpoint}`)
		return
	end

	local handlerSuccess, handlerData = handler(command.data or {})

	if not handlerSuccess then
		sendResponse(command.requestId, false, nil, tostring(handlerData))
		return
	end

	sendResponse(command.requestId, true, handlerData, nil)
end

--- pollLoop(): ()
-- Main polling loop that fetches and processes commands
local function pollLoop(): ()
	_isPolling           = true
	_consecutiveFailures = 0

	while _isPolling and not _isUnloading do
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

--- disconnectFromServer(): ()
-- Sends a clean disconnect to the server
local function disconnectFromServer(): ()
	if not _baseUrl then return end

	pcall(function()
		httpRequest(`POST`, `{_baseUrl}/disconnect`, {
			studioId = _studioId,
		})
	end)
end

--- connectionLoop(): ()
-- Main connection lifecycle: discover -> register -> poll -> reconnect
local function connectionLoop(): ()
	while not _isUnloading do
		local port = discoverServer()

		if not port then
			if _isUnloading then return end
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
--                             PLUGIN UI
-- =============================================================================

--- createWidget(): ()
-- Creates the toolbar, button, and dock widget UI
local function createWidget(): ()
	_toolbar = plugin:CreateToolbar(TOOLBAR_NAME)
	_button  = _toolbar:CreateButton(BUTTON_NAME, BUTTON_TOOLTIP, BUTTON_ICON)

	local widgetInfo = DockWidgetPluginGuiInfo.new(
		Enum.InitialDockState.Float,
		false,
		false,
		260,
		180,
		200,
		140
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

	disconnectFromServer()

	if _pollThread then
		pcall(task.cancel, _pollThread)
		_pollThread = nil
	end
end)

-- =============================================================================

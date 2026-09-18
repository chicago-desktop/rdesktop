-- The Remote Desktop session window: another computer's desktop, driven.
--
-- Opened by "Remote Desktop Connection" (chicago.rdesktop:window) with args
-- `{"computer": "<node id>", "name": "<caption>", "keys": "local"?}`. An
-- ordinary window on the shell's SDK (app.main): its tree is one `terminal`
-- view holding the remote screen's rows and cursor, drawn by the shell's
-- renderer in pixels (each row decoded, in the mono face) and placed as it
-- came in cells.
--
-- THE REMOTE SCREEN IS MEASURED IN MONO COLUMNS in pixels, not in terminal
-- cells: (client width × cell width) // ui.MONO_PX — the grid the view draws
-- it on. The remote side is opened and resized to that number, or it lays
-- itself out on a grid nobody draws. In cells a column is a cell.
--
-- The loop is the SDK's: the session's `updates` and `ended` are watched
-- channels. A watermark asks for the next delta, acknowledging the revision
-- the window shows (one frame in flight). A key no component took — every
-- key: the view takes none — goes to the remote desktop through the key
-- mode of chicago.rdesktop:inputs; so do pastes, and a pointer standing on
-- the view, which the SDK (chicago/shell 0.4.3, ui.terminal_at) hands over
-- with the column and row of that screen already worked out.
--
-- A refused connection or an ended session opens the connection window
-- again with the reason and the computer still selected, and this window
-- goes — the way the Remote Desktop client returns to its dialog. Closing
-- this window ends the session and nothing else.
--
-- The remote desktop is reached only through the session interface of the
-- library imported as `transport` (loopback.lua, mesh.lua). The logon is the
-- remote computer's own "Welcome to Chicago".
local app = require("app")
local json = require("json")
local ui = require("ui")
local transport = require("transport")
local frames = require("frames")
local inputs = require("inputs")
local desktop = require("desktop")

local session = {}

-- The desktop a session asks for: the Chicago shell, on the host that runs a
-- desktop's windows. Fixed here, not taken from args: the loopback transport
-- starts it with the window's own rights. The mesh transport only checks it
-- against what the remote computer offers.
session.TARGET = {entry = "chicago.shell:shell", host = "chicago.tui_desktop:workers"}

-- The connection window this one returns to.
session.CONNECTION = "chicago.rdesktop:window"

-- options(args) -> {computer, name, keys}
function session.options(args: any): any
    local decoded: any = nil
    if type(args) == "string" and args ~= "" then
        local value, err = json.decode(args)
        if err == nil and type(value) == "table" then decoded = value end
    end
    local computer: any = decoded and decoded.computer
    local name: any = decoded and decoded.name
    return {
        computer = type(computer) == "string" and computer ~= "" and computer or nil,
        name = type(name) == "string" and name ~= "" and name or nil,
        keys = inputs.mode(decoded and decoded.keys),
    }
end

-- return_args(computer, reason) -> the connection window's args
function session.return_args(computer: any, reason: string): string
    local encoded = json.encode({notice = reason, selected = computer})
    return tostring(encoded)
end

-- geometry(context) -> columns, rows — the remote screen for this client:
-- mono columns when there are pixels, cells otherwise (docs/sdk.md,
-- `terminal`).
function session.geometry(context: any): (integer, integer)
    local columns = math.tointeger(context.width) or 1
    local cell: any = context.cell
    if type(cell) == "table" and (math.tointeger(cell.w) or 0) > 0 then
        columns = (columns * (math.tointeger(cell.w) or 0)) // ui.MONO_PX
    end
    local rows = math.tointeger(context.height) or 1
    if columns < 1 then columns = 1 end
    if rows < 1 then rows = 1 end
    return columns, rows
end

-- graphics(context) -> what the viewer's screen is, for `open`: the protocol
-- and the grid it draws the remote screen on. Carried and not yet used: the
-- serving side would tell its desktop (view:terminal) only once rasters
-- travel over the wire — telling it earlier makes it draw its chrome as
-- pictures that never arrive (README, "Rows and a cursor only").
function session.graphics(context: any): any
    local cell: any = context.cell
    if type(cell) ~= "table" then return nil end
    return {cell_w = ui.MONO_PX, cell_h = math.tointeger(cell.h) or 0}
end

-- tree(model, context) -> the window's tree: the remote screen, the notice
-- (connecting, waiting) on its last row until the first frame.
function session.tree(model: any, context: any): any
    local columns, rows = session.geometry(context)
    local cursor: any = model.screen.cursor
    local shown = model.notice == nil and type(cursor) == "table" and cursor.visible == true
    return {kind = "column", children = {
        {kind = "terminal", rows = frames.compose(model.screen, columns, rows, model.notice),
            cursor = shown and {x = cursor.x, y = cursor.y, visible = true} or nil},
    }}
end

-- back(model, context, reason) — the connection window again, and go.
local function back(model: any, context: any, reason: string)
    model.session = nil
    desktop.open({entry = session.CONNECTION, args = session.return_args(model.options.computer, reason)})
    context.close()
end

-- dial(model, context) — open the session at the client's current size.
local function dial(model: any, context: any)
    local columns, rows = session.geometry(context)
    local opened, why = transport.open({
        node = model.options.computer, entry = session.TARGET.entry, host = session.TARGET.host,
        width = columns, height = rows, graphics = session.graphics(context),
    })
    if not opened then return back(model, context, tostring(why)) end
    model.session = opened
    model.screen = frames.blank(columns, rows)
    model.notice = "Connected to " .. model.name .. "; waiting for its screen..."
    context.watch(opened:updates())
    context.watch(opened:ended())
end

local definition: any = {}

-- The caption the connection window opened this one with, kept on every
-- frame (an empty title would fall back to the menu entry's).
function definition.title(model: any): string
    return model.name .. " - Remote Desktop"
end

function definition.init(args: any, context: any): any
    local options = session.options(args)
    local columns, rows = session.geometry(context)
    local model: any = {options = options, session = nil, screen = frames.blank(columns, rows),
        name = options.name or options.computer or "this computer"}
    model.notice = "Connecting to " .. model.name .. "..."
    -- Connected on the first tick of the loop, not here: the window shows
    -- "Connecting…" while the other computer is asked.
    context.after("1ms", "dial")
    return model
end

function definition.view(model: any, context: any): any
    local tree = session.tree(model, context)
    return tree
end

function definition.update(model: any, action: any, context: any): boolean
    local live: any = model.session
    if action.type == "timer" and action.tag == "dial" then
        dial(model, context)
        return true
    elseif action.type == "channel" and live then
        if action.channel == live:updates() then
            -- The revision the window shows is the acknowledgement: the next
            -- delta is cut from it, and nothing more is asked for until this
            -- one is applied.
            local delta = live:snapshot(model.screen.revision)
            if delta == nil then return false end
            frames.apply(model.screen, delta)
            model.notice = nil
            return true
        elseif action.channel == live:ended() then
            live:close()
            back(model, context, tostring(action.value or "The remote session ended."))
            return false
        end
        return false
    elseif action.type == "resize" then
        if live then
            local columns, rows = session.geometry(context)
            live:resize(columns, rows)
        end
        return true
    elseif live == nil then
        return false
    elseif action.type == "key" then
        live:send(inputs.key({type = "key", key = action.key, key_type = action.key_type, action = "press",
            alt = action.alt, ctrl = action.ctrl, shift = action.shift}, model.options.keys))
        return false
    elseif action.type == "mouse" then
        -- The column and row of THAT screen, from the SDK — the one place the
        -- grid is decided. A pointer without them is not over the view, and
        -- is not guessed at here.
        if action.column == nil or action.row == nil then return false end
        local columns, rows = session.geometry(context)
        live:send(inputs.mouse({type = "mouse", action = action.action, button = action.button,
            x = action.column, y = action.row, alt = action.alt, ctrl = action.ctrl, shift = action.shift},
            columns, rows))
        return false
    elseif action.type == "paste" then
        live:send({type = "paste", text = action.text})
        return false
    elseif action.type == "close" then
        live:close()
        model.session = nil
        return false
    end
    return false
end

function definition.dispose(model: any, context: any)
    if model.session then model.session:close() end
end

session.definition = definition
session.main = app.main(definition)

return session

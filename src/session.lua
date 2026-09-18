-- The Remote Desktop session window: another computer's desktop, driven.
--
-- Opened by "Remote Desktop Connection" (chicago.rdesktop:window) with args
-- `{"computer": "<node id>", "name": "<caption>", "keys": "local"?}`. A
-- custom cells window (the SDK's "custom window" contract, docs/sdk.md):
-- its content is the remote desktop's styled terminal rows, which no
-- declarative component carries — on a pixel desktop the compositor lays
-- them as terminal characters inside the frame, as it does for Bash.
--
-- The loop: a watermark on `updates` asks for the next delta, acknowledging
-- the revision the window has applied (one frame in flight); keys and the
-- mouse go to the remote desktop (keys through the key mode of
-- chicago.rdesktop:inputs); a resize of the window resizes the remote
-- screen. The logon is the remote computer's own "Welcome to Chicago".
--
-- A refused connection or an ended session opens the connection window
-- again with the reason and the computer still selected, and this window
-- goes — the way the Remote Desktop client returns to its dialog. Closing
-- this window ends the session and nothing else.
--
-- The remote desktop is reached only through the session interface of the
-- library imported as `transport` (loopback.lua, mesh.lua).
local tty = require("tty")
local json = require("json")
local channel = require("channel")
local transport = require("transport")
local frames = require("frames")
local inputs = require("inputs")
local input = require("input")
local desktop = require("desktop")

-- The desktop a session asks for: the Chicago shell, on the host that runs a
-- desktop's windows. Fixed here, not taken from args: the loopback transport
-- starts it with the window's own rights. The mesh transport only checks it
-- against what the remote computer offers.
local TARGET = {entry = "chicago.shell:shell", host = "chicago.tui_desktop:workers"}

-- The connection window this one returns to.
local CONNECTION = "chicago.rdesktop:window"

-- options(args) -> {computer, name, keys}
local function options(args: any): any
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
local function return_args(computer: any, reason: string): string
    local encoded = json.encode({notice = reason, selected = computer})
    return tostring(encoded)
end

local function main(args: any)
    assert(tty.start())
    local events = assert(tty.events())
    local surface = assert(tty.surface({hide_cursor = true, synchronized_output = true}))

    -- Mutable loop state lives in a table (go-lua and pcall, AGENTS.md).
    local run: any = {width = 1, height = 1, options = options(args), session = nil, notice = nil, screen = nil}
    run.width, run.height = tty.screen_size()
    run.screen = frames.blank(run.width, run.height)
    local name = run.options.name or run.options.computer or "this computer"

    local function present()
        local canvas = tty.canvas(run.width, run.height)
        canvas:clear()
        canvas:put_rows(1, 1, frames.compose(run.screen, run.width, run.height, run.notice), run.width)
        local cursor: any = run.screen.cursor
        local shown = run.notice == nil and type(cursor) == "table" and cursor.visible == true
        surface:present(canvas:rows(), {cursor = {
            x = shown and cursor.x or 1, y = shown and cursor.y or 1, visible = shown,
        }})
    end

    -- back(reason) — the connection window again, with the reason.
    local function back(reason: string)
        desktop.open({entry = CONNECTION, args = return_args(run.options.computer, reason)})
    end

    run.notice = "Connecting to " .. name .. "..."
    present()
    local session, why = transport.open({
        node = run.options.computer, entry = TARGET.entry, host = TARGET.host,
        width = run.width, height = run.height,
    })
    if not session then
        back(tostring(why))
        pcall(tty.stop)
        return
    end
    run.session = session
    run.notice = "Connected to " .. name .. "; waiting for its screen..."
    present()

    while true do
        local picked = channel.select({events:case_receive(), session:updates():case_receive(),
            session:ended():case_receive()})
        if picked.channel == events then
            if not picked.ok then break end
            local event: any = input.normalize(picked.value)
            if event.type == "close" then break end
            if event.type == "resize" then
                run.width, run.height = tty.screen_size()
                session:resize(run.width, run.height)
                surface:invalidate()
                present()
            elseif event.type == "key" then
                session:send(inputs.key(event, run.options.keys))
            elseif event.type == "mouse" then
                session:send(inputs.mouse(event, run.width, run.height))
            elseif event.type == "paste" then
                session:send({type = "paste", text = event.text})
            end
        elseif picked.channel == session:updates() then
            -- The revision the window shows is the acknowledgement: the next
            -- delta is cut from it, and nothing more is asked for until this
            -- one is applied.
            local delta = session:snapshot(run.screen.revision)
            if delta then
                frames.apply(run.screen, delta)
                run.notice = nil
                present()
            end
        else
            -- `ended`: the remote desktop is gone, its node or its server.
            run.session = nil
            session:close()
            back(tostring(picked.value or "The remote session ended."))
            break
        end
    end

    if run.session then run.session:close() end
    pcall(tty.stop)
end

return {main = main, options = options, return_args = return_args, TARGET = TARGET, CONNECTION = CONNECTION}

-- Remote Desktop — pick a computer, connect, and drive its desktop.
--
-- A custom cells window (the SDK's "custom window" contract, docs/sdk.md)
-- with two screens in one loop:
--
--   CONNECT  the Remote Desktop Connection screen (chicago.rdesktop:connect):
--            the computers of the network, Connect, Cancel, a status line.
--            Drawn and driven by the SDK's own pure halves — ui.plan,
--            cells.rows, ui.event — the ones app.run uses in cells.
--   SESSION  the remote desktop's styled terminal rows, which no declarative
--            component carries. A watermark on `updates` asks for the next
--            delta, acknowledging the revision the window has applied (one
--            frame in flight); keys and the mouse go to the remote desktop
--            (keys through the key mode of chicago.rdesktop:inputs); a resize
--            of the window resizes the remote screen.
--
-- The logon is not this window's: the remote computer asks for it with its
-- own "Welcome to Chicago" inside the session. A refused connection and an
-- ended session both come back to CONNECT with the reason on the status
-- line, so the person can connect again without closing the window.
--
-- The remote desktop is reached only through the session interface of the
-- library imported as `transport` (loopback.lua, mesh.lua): the tty
-- Viewport's snapshot, updates, send, resize and close, and ended.
--
-- Cells only: a viewport snapshot has rows, a cursor and a revision — no
-- rasters — so the remote desktop is shown as its cells rendering, whatever
-- the local desktop draws its own chrome with.
local tty = require("tty")
local json = require("json")
local channel = require("channel")
local transport = require("transport")
local frames = require("frames")
local inputs = require("inputs")
local input = require("input")
local connect = require("connect")
local facts = require("facts")
local ui = require("ui")
local cells = require("cells")

-- The desktop a session asks for: the Chicago shell, on the host that runs a
-- desktop's windows. Fixed here, not taken from the window's args: the
-- loopback transport starts it with the window's own rights, and an entry
-- named by whoever opens the window would run with them too. The mesh
-- transport only checks it against what the remote computer offers.
local TARGET = {entry = "chicago.shell:shell", host = "chicago.tui_desktop:workers"}

-- What the connection screen reads of the runtime.
local FACTS = {"node_id", "node_role", "members", "hostname"}

-- options(args) -> {keys, computer}
--
-- The window's args are a JSON object (`desktop.open` carries them as a
-- string). `{"computer": "<node id>"}` connects to that computer at once,
-- skipping the connection screen — Network Neighborhood opens the window so;
-- without it the screen is shown. `{"keys": "local"}` switches the key mode.
-- Anything unreadable is the default.
local function options(args: any): any
    local decoded: any = nil
    if type(args) == "string" and args ~= "" then
        local value, err = json.decode(args)
        if err == nil and type(value) == "table" then decoded = value end
    end
    local computer: any = decoded and decoded.computer
    return {
        keys = inputs.mode(decoded and decoded.keys),
        computer = type(computer) == "string" and computer ~= "" and computer or nil,
    }
end

local function main(args: any)
    assert(tty.start())
    local events = assert(tty.events())
    local surface = assert(tty.surface({hide_cursor = true, synchronized_output = true}))

    -- Mutable loop state lives in a table (go-lua and pcall, AGENTS.md).
    local run: any = {
        width = 1, height = 1,
        options = options(args),
        mode = "connect",
        screen_model = nil,
        interaction = ui.interaction(),
        plan = nil,
        session = nil,
        notice = nil,
        screen = nil,
        closing = false,
    }
    run.width, run.height = tty.screen_size()
    run.screen_model = connect.model(facts.read(FACTS))

    local function show(rows: {string}, cursor: any)
        local canvas = tty.canvas(run.width, run.height)
        canvas:clear()
        canvas:put_rows(1, 1, rows, run.width)
        surface:present(canvas:rows(), {cursor = cursor or {x = 1, y = 1, visible = false}})
    end

    local function present()
        if run.mode == "connect" then
            run.plan = ui.plan(connect.tree(run.screen_model), run.width, run.height, run.interaction, {scroll_cols = 1})
            local drawn = cells.rows(run.plan, run.interaction, run.width, run.height) :: {string}
            show(drawn, nil)
            return
        end
        local cursor: any = run.screen.cursor
        local shown = run.notice == nil and type(cursor) == "table" and cursor.visible == true
        show(frames.compose(run.screen, run.width, run.height, run.notice), {
            x = shown and cursor.x or 1, y = shown and cursor.y or 1, visible = shown,
        })
    end

    -- back(reason) — the connection screen again, the list re-read, the
    -- reason on its status line.
    local function back(reason: string)
        run.session = nil
        run.mode = "connect"
        connect.refresh(run.screen_model, facts.read(FACTS))
        run.screen_model.notice = reason
        present()
    end

    local function dial(node: any)
        local name = node and connect.name_of(run.screen_model, node) or "this computer"
        run.screen_model.notice = "Connecting to " .. name .. "..."
        present()
        local session, why = transport.open({
            node = node, entry = TARGET.entry, host = TARGET.host,
            width = run.width, height = run.height,
        })
        if not session then return back(tostring(why)) end
        run.session = session
        run.mode = "session"
        run.screen = frames.blank(run.width, run.height)
        run.notice = "Connected to " .. name .. "; waiting for its screen..."
        present()
    end

    local function on_connect_event(event: any)
        local action: any = ui.event(run.plan, run.interaction, event)
        -- A key no component took reaches the screen, as app.run passes it
        -- to `update`: Esc cancels, F5 re-reads the network.
        if action == nil and event.type == "key" and event.action ~= "release" then
            if event.key_type == "f5" then
                connect.refresh(run.screen_model, facts.read(FACTS))
                present()
                return
            end
            action = {type = "key", key = event.key, key_type = event.key_type}
        end
        local result, changed = connect.update(run.screen_model, action)
        if result and result.cancel then run.closing = true
        elseif result and result.connect then dial(result.connect)
        elseif changed or action ~= nil then present() end
    end

    present()
    if run.options.computer then dial(run.options.computer) end

    while not run.closing do
        local cases = {events:case_receive()}
        local session: any = run.session
        if session then
            cases[#cases + 1] = session:updates():case_receive()
            cases[#cases + 1] = session:ended():case_receive()
        end
        local picked = channel.select(cases)
        if picked.channel == events then
            if not picked.ok then break end
            local event: any = input.normalize(picked.value)
            if event.type == "close" then break end
            if event.type == "resize" then
                run.width, run.height = tty.screen_size()
                if session then session:resize(run.width, run.height) end
                surface:invalidate()
                present()
            elseif run.mode == "connect" then
                if event.type == "key" or event.type == "mouse" then on_connect_event(event) end
            elseif event.type == "key" then
                session:send(inputs.key(event, run.options.keys))
            elseif event.type == "mouse" then
                session:send(inputs.mouse(event, run.width, run.height))
            elseif event.type == "paste" then
                session:send({type = "paste", text = event.text})
            end
        elseif session and picked.channel == session:updates() then
            -- The revision the window shows is the acknowledgement: the next
            -- delta is cut from it, and nothing more is asked for until this
            -- one is applied.
            local delta = session:snapshot(run.screen.revision)
            if delta then
                frames.apply(run.screen, delta)
                run.notice = nil
                present()
            end
        elseif session then
            -- `ended`: the remote desktop is gone, its node or its server.
            session:close()
            back(tostring(picked.value or "The remote session ended."))
        end
    end

    if run.session then run.session:close() end
    pcall(tty.stop)
end

return {main = main, options = options, TARGET = TARGET, FACTS = FACTS}

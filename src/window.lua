-- Remote Desktop — a window that shows another desktop and drives it.
--
-- A custom cells window (the SDK's "custom window" contract, docs/sdk.md):
-- the content is the remote desktop's styled terminal rows, which no
-- declarative component carries, so the window owns its loop. It draws on
-- its own tty port, which the local compositor gives it as for any cells
-- window, and it reaches the remote desktop only through the session
-- interface of the library imported as `transport` (see loopback.lua): the
-- tty Viewport's snapshot, updates, send, resize and close, and ended.
--
-- The loop: a watermark on `updates` asks for the next delta, acknowledging
-- the revision the window has applied — one frame in flight; the delta is
-- applied to a copy and presented; keys and the mouse go to the remote desktop (keys through the
-- key mode of chicago.rdesktop:inputs); a resize of this window resizes the
-- remote screen, so the remote desktop is always laid out for the size it
-- is shown at.
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

-- The desktop a session asks for: the Chicago shell, on the host that runs a
-- desktop's windows. Fixed here, not taken from the window's args: the
-- loopback transport starts it with the window's own rights, and an entry
-- named by whoever opens the window would run with them too. The mesh
-- transport only checks it against what the remote computer offers.
local TARGET = {entry = "chicago.shell:shell", host = "chicago.tui_desktop:workers"}

-- options(args) -> {keys, computer}
--
-- The window's args are a JSON object (`desktop.open` carries them as a
-- string): `{"computer": "<node id>"}` is the computer to connect to (none:
-- this one), `{"keys": "local"}` switches the key mode. Anything unreadable
-- is the default.
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
        session = nil,
        notice = nil,
        screen = nil,
    }
    run.width, run.height = tty.screen_size()
    run.screen = frames.blank(run.width, run.height)

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

    run.notice = "Connecting to " .. (run.options.computer or "this computer") .. "..."
    present()
    local session, why = transport.open({
        node = run.options.computer, entry = TARGET.entry, host = TARGET.host,
        width = run.width, height = run.height,
    })
    if session then
        run.session = session
    else
        run.notice = tostring(why) .. " (Esc closes)"
    end
    present()

    while true do
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
            elseif session == nil then
                -- Nothing to drive: the session never opened or has ended.
                if event.type == "key" and event.action ~= "release" and event.key_type == "esc" then break end
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
            -- `ended`: the remote desktop is gone (or its viewport closed).
            session:close()
            run.session = nil
            run.notice = tostring(picked.value or "the remote desktop ended") .. " (Esc closes)"
            present()
        end
    end

    if run.session then run.session:close() end
    pcall(tty.stop)
end

return {main = main, options = options, TARGET = TARGET}

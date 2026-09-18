-- The mesh transport end to end on one node: a viewer in this process, a
-- broker and its sessions in others, the protocol between them. What one
-- node cannot show — a node that dies — is covered by the membership check
-- (wire_test) and by the two-node stand.
local test = require("test")
local channel = require("channel")
local time = require("time")
local process = require("process")
local fs = require("fs")
local security = require("security")
local gfx = require("gfx")
local mesh = require("mesh")
local exits = require("exits")
local inputs = require("inputs")
local frames = require("frames")

local ECHO_BROKER = {entry = "app:echo", host = "app:processes"}

-- What the broker service runs under (src/_index.yaml, broker.service): a
-- broker started with it meets the same permission checks — a cancel the
-- policy does not allow is refused there, and nowhere in a permissive test.
local SERVICE_POLICIES = {"chicago.rdesktop:serving", "chicago.shell.security:shell_runtime",
    "chicago.shell.security:shell_env"}

-- A broker under the service's own actor and policies, serving `entry`.
local function start_service_like_broker(name: string, entry: string)
    local scope = security.new_scope()
    for _, id in ipairs(SERVICE_POLICIES) do
        local policy: any = assert(security.policy(id))
        scope = scope:with(policy :: security.Policy)
    end
    assert(process.with_context({}):with_actor(security.new_actor("chicago.rdesktop.broker", {})):with_scope(scope)
        :spawn("chicago.rdesktop:broker", "app:processes", {name = name, entry = entry, host = "app:processes"}))
    local deadline = time.after("5s")
    while process.registry.lookup(name) == nil do
        local picked = channel.select({deadline:case_receive(), time.after("50ms"):case_receive()})
        if picked.channel == deadline then error("the broker did not take " .. name) end
    end
end

-- open_reporting(broker) -> session, desktop pid
local function open_reporting(broker: string): (any, string)
    process.registry.register("rdesktop.test.echoes")
    local started = process.listen("echo.started")
    local session = assert(mesh.open({broker = broker, width = 20, height = 3}))
    local picked = channel.select({started:case_receive(), time.after("10s"):case_receive()})
    process.unlisten(started)
    process.registry.unregister("rdesktop.test.echoes")
    assert(picked.channel == started, "the desktop did not report its pid")
    return session, tostring(picked.value)
end

-- A broker of its own for a test producer, under a name of its own.
local function start_broker_offering(name: string, entry: string): string
    local pid = assert(process.spawn("chicago.rdesktop:broker", "app:processes",
        {name = name, entry = entry, host = ECHO_BROKER.host}))
    local deadline = time.after("5s")
    while process.registry.lookup(name) == nil do
        local picked = channel.select({deadline:case_receive(), time.after("50ms"):case_receive()})
        if picked.channel == deadline then error("the broker did not take " .. name) end
    end
    return tostring(pid)
end

local function start_broker(name: string): string
    local pid = start_broker_offering(name, ECHO_BROKER.entry)
    return pid
end

-- wait(session, screen, accept, seconds) -> delta | nil, seen
local function wait(session: any, screen: any, accept: any, seconds: integer): (any, any)
    local deadline = time.after(tostring(seconds) .. "s")
    local seen: any = {}
    while true do
        local picked = channel.select({deadline:case_receive(), session:updates():case_receive(),
            session:ended():case_receive()})
        if picked.channel == deadline then return nil, seen end
        if picked.channel == session:ended() then
            seen.ended = tostring(picked.value)
            return nil, seen
        end
        local delta = session:snapshot(screen.revision)
        if delta then
            seen[#seen + 1] = delta
            frames.apply(screen, delta)
            if accept(screen, delta) then return delta, seen end
        end
    end
end

-- gone(pid, seconds) -> boolean — whether the process exits in time.
local function gone(pid: string, seconds: integer): boolean
    local exit = exits.watch(pid)
    process.monitor(pid)
    local picked = channel.select({exit:case_receive(), time.after(tostring(seconds) .. "s"):case_receive()})
    exits.forget(pid)
    return picked.channel == exit
end

local function row_is(y: integer, text: string): any
    return function(screen: any) return screen.rows[y] == text end
end

local function any_row(pattern: string): any
    return function(screen: any)
        for _, row in ipairs(screen.rows) do
            if string.find(row, pattern, 1, true) then return true end
        end
        return false
    end
end

local function screen_text(screen: any): string
    return table.concat(screen.rows, "\n")
end

local function key(name: string): any
    return {type = "key", key_type = "runes", key = name, action = "press"}
end

local function define_tests()
    test.describe("the mesh transport", function()
        test.it("says a computer without a broker is not accessible", function()
            local session, why = mesh.open({node = "no-such-node", width = 20, height = 4})
            test.is_nil(session)
            test.eq(why, "The computer is not accessible. Remote Desktop is not enabled on no-such-node.")
        end)

        test.it("refuses a desktop the computer does not offer, in the computer's words", function()
            start_broker("test.broker.offer")
            local session, why = mesh.open({broker = "test.broker.offer", entry = "app:something_else", width = 20, height = 4})
            test.is_nil(session)
            test.eq(why, "This computer does not offer app:something_else.")
        end)

        test.it("carries the screen as deltas, input and a resize through the broker's session", function()
            start_broker("test.broker.echo")
            local session, why = mesh.open({broker = "test.broker.echo", width = 30, height = 6})
            test.not_nil(session, tostring(why))
            local screen = frames.blank(30, 6)
            local first = wait(session, screen, row_is(1, "ready 30x6"), 10)
            test.not_nil(first, "the first frame: " .. screen_text(screen))
            test.is_true(first.full)

            test.is_true(session:send(inputs.key(key("x"), "remote")))
            local typed = wait(session, screen, row_is(2, "got x"), 10)
            test.not_nil(typed, screen_text(screen))
            test.is_false(typed.full)
            test.eq(typed.changed, 1)

            test.is_true(session:send(inputs.key({type = "key", key_type = "home", key = "home",
                action = "press", alt = true}, "remote")))
            test.not_nil(wait(session, screen, row_is(2, "got alt+o"), 10), screen_text(screen))

            test.is_true(session:send(inputs.mouse({type = "mouse", action = "press", button = "left", x = 7, y = 4}, 30, 6)))
            test.not_nil(wait(session, screen, row_is(2, "got mouse press 7,4"), 10), screen_text(screen))

            test.is_true(session:resize(40, 8))
            local _, on_resize = wait(session, screen, row_is(1, "ready 40x8"), 10)
            test.not_nil(on_resize[1], "a frame after the resize")
            test.is_true(on_resize[1].full and on_resize[1].width == 40 and on_resize[1].height == 8,
                "the first frame at a new size has every row")

            local server = session.server
            session:close()
            test.is_true(gone(server, 10), "closing the window ends the served session")
        end)

        test.it("keeps one frame in flight and sends the latest screen, not every screen", function()
            start_broker("test.broker.flow")
            local session = assert(mesh.open({broker = "test.broker.flow", width = 24, height = 4}))
            local screen = frames.blank(24, 4)
            test.not_nil(wait(session, screen, row_is(1, "ready 24x4"), 10))
            local before = session:received()

            -- A keystroke and no ask: its frame arrives and is held.
            session:send(key("a"))
            local deadline = time.after("10s")
            while session:received() == before do
                local picked = channel.select({deadline:case_receive(), time.after("20ms"):case_receive()})
                if picked.channel == deadline then break end
            end
            test.eq(session:received(), before + 1, "the frame for the first keystroke")

            -- More keystrokes while it is not acked: the server sends nothing.
            for _, name in ipairs({"b", "c", "d", "e"}) do session:send(key(name)) end
            time.sleep("500ms")
            test.eq(session:received(), before + 1, "one frame in flight: nothing more until the ack")

            -- Taking it acks it; the next is cut from the live screen — "e",
            -- and b, c, d are never sent.
            local held = session:snapshot(screen.revision)
            test.not_nil(held)
            frames.apply(screen, held)
            test.eq(screen.rows[2], "got a")
            test.not_nil(wait(session, screen, row_is(2, "got e"), 10), screen_text(screen))
            test.eq(session:received(), before + 2, "the latest screen, not every screen")
            session:close()
        end)

        test.it("answers a window that lost its copy with every row", function()
            start_broker("test.broker.resync")
            local session = assert(mesh.open({broker = "test.broker.resync", width = 20, height = 3}))
            local screen = frames.blank(20, 3)
            test.not_nil(wait(session, screen, row_is(1, "ready 20x3"), 10))
            session:send(key("z"))
            -- The window claims a revision it never had: the held frame is
            -- dropped and the next one is whole.
            local picked = channel.select({session:updates():case_receive(), time.after("5s"):case_receive()})
            test.eq(picked.channel, session:updates())
            test.is_nil(session:snapshot(screen.revision + 1000))
            local fresh = frames.blank(20, 3)
            local whole = wait(session, fresh, row_is(2, "got z"), 10)
            test.not_nil(whole, screen_text(fresh))
            test.is_true(whole.full, "resent in full")
            session:close()
        end)

        test.it("ends the served session when the viewer's process is gone", function()
            start_broker("test.broker.viewer")
            local replies = process.listen("probe")
            local probe = assert(process.spawn("app:viewer_probe", "app:processes", tostring(process.pid()), "test.broker.viewer"))
            local picked = channel.select({replies:case_receive(), time.after("10s"):case_receive()})
            test.eq(picked.channel, replies, "the probe opened a session")
            local server = tostring(picked.value)
            test.not_nil(string.find(server, "{", 1, true), server)
            process.send(tostring(probe), "die", true)
            test.is_true(gone(server, 10), "the served session noticed its viewer had gone")
            process.unlisten(replies)
        end)

        test.it("tells the window why when the served session dies", function()
            start_broker("test.broker.server")
            local session = assert(mesh.open({broker = "test.broker.server", width = 20, height = 3}))
            local screen = frames.blank(20, 3)
            test.not_nil(wait(session, screen, row_is(1, "ready 20x3"), 10))
            process.terminate(tostring(session.server))
            local _, seen = wait(session, screen, function() return false end, 10)
            test.not_nil(seen.ended, "the end is reported")
            test.not_nil(string.find(tostring(seen.ended), "The remote session", 1, true), tostring(seen.ended))
        end)

        test.it("survives a LINK_DOWN and tells it as an end — the path a node's departure takes", function()
            local replies = process.listen("probe.link")
            assert(process.spawn("app:link_probe", "app:processes", tostring(process.pid())))
            local picked = channel.select({replies:case_receive(), time.after("10s"):case_receive()})
            process.unlisten(replies)
            test.eq(picked.channel, replies, "the watcher lived to report (without trap_links it dies with the link)")
            local told: any = picked.value
            test.is_true(told.link_down, "told as a link that went down")
        end)

        test.it("takes the desktop down with a served session that dies", function()
            start_broker("test.broker.orphan")
            process.registry.register("rdesktop.test.echoes")
            local started = process.listen("echo.started")
            local session = assert(mesh.open({broker = "test.broker.orphan", width = 20, height = 3}))
            local picked = channel.select({started:case_receive(), time.after("10s"):case_receive()})
            process.unlisten(started)
            process.registry.unregister("rdesktop.test.echoes")
            test.eq(picked.channel, started, "the desktop's pid")
            local desktop = tostring(picked.value)
            process.terminate(tostring(session.server))
            test.is_true(gone(desktop, 10), "no orphaned desktop: it is linked to its session")
        end)

        test.it("ends the desktop when the window closes normally, under the service's own policy", function()
            start_service_like_broker("test.broker.close", "app:echo")
            local session, desktop = open_reporting("test.broker.close")
            session:close()
            -- Asked with a cancel it obeys: gone well inside the grace. A
            -- cancel the policy refuses would leave it to the terminate.
            test.is_true(gone(desktop, 4), "a desktop that acts on CANCEL goes at once")
        end)

        test.it("terminates a desktop that ignores the request once the grace is over", function()
            start_service_like_broker("test.broker.stubborn", "app:stubborn")
            local session, desktop = open_reporting("test.broker.stubborn")
            session:close()
            test.is_true(gone(desktop, 12), "a cancel is a request; the terminate is the guarantee")
        end)

        test.it("ends the desktop too when the viewer's process vanishes", function()
            start_service_like_broker("test.broker.vanish", "app:stubborn")
            process.registry.register("rdesktop.test.echoes")
            local started = process.listen("echo.started")
            local replies = process.listen("probe")
            local probe = assert(process.spawn("app:viewer_probe", "app:processes", tostring(process.pid()), "test.broker.vanish"))
            local first = channel.select({started:case_receive(), time.after("10s"):case_receive()})
            channel.select({replies:case_receive(), time.after("10s"):case_receive()})
            process.unlisten(started)
            process.unlisten(replies)
            process.registry.unregister("rdesktop.test.echoes")
            test.eq(first.channel, started)
            local desktop = tostring(first.value)
            process.send(tostring(probe), "die", true)
            test.is_true(gone(desktop, 15), "no orphaned desktop after the viewer is gone")
        end)

        test.it("names the computer when its session ends", function()
            test.eq(mesh.ended_reason("node-b", {error = "node disconnected"}), "The connection to node-b was lost.")
            test.eq(mesh.ended_reason("node-b", {link_down = true, error = "linked process failed"}),
                "The connection to node-b was lost.")
            test.eq(mesh.ended_reason("node-b", {error = "boom"}), "The remote session on node-b failed: boom")
            test.eq(mesh.ended_reason("node-b", {}), "The remote session on node-b ended.")
        end)

        test.it("sends a picture's pixels once per identity, and its geometry with every frame", function()
            start_broker_offering("test.broker.pictures", "app:painter")
            -- Sixel: the served desktop must hear the viewer's protocol,
            -- not one the serving side picked.
            local graphics = {cell_w = 8, cell_h = 20, protocol = "sixel"}
            local session = assert(mesh.open({broker = "test.broker.pictures", width = 20, height = 5, graphics = graphics}))
            local screen = frames.blank(20, 5)
            test.not_nil(wait(session, screen, row_is(1, "painter start"), 10))
            test.eq(screen.rows[2], "gfx sixel 8x20", "the desktop was told the viewer's protocol and grid")
            test.eq(#screen.images, 1, "the picture on the screen")
            local picture: any = screen.images[1]
            test.eq(table.concat({picture.id, picture.x, picture.y, picture.cols, picture.rows}, ","), "pic,2,2,2,2")
            test.is_nil(picture.raster, "no raster: a tree carrying one could not be published")
            test.eq(type(picture.png), "string", "its pixels arrived, as PNG bytes")
            local w, h = assert(gfx.image(picture.png)):size()
            test.eq(tostring(w) .. "x" .. tostring(h), "16x40")
            test.eq(picture.key, tostring(session.node) .. ":" .. tostring(session.number) .. ":pic",
                "keyed by its source: node, session, id")
            local first = session:picture_bytes()
            test.is_true(first > 0)

            -- Only the text changes: the picture goes as its geometry alone.
            session:send(key("x"))
            test.not_nil(wait(session, screen, row_is(1, "painter x"), 10))
            test.eq(session:picture_bytes(), first, "no pixels for a picture the viewer has")
            test.eq(#screen.images, 1)

            -- The same picture moved: the geometry changes, the pixels do not travel.
            session:send(key("m"))
            test.not_nil(wait(session, screen, row_is(1, "painter m"), 10))
            test.eq(session:picture_bytes(), first, "a move sends no pixels")
            test.eq(screen.images[1].x, 3)

            -- A new picture under the same id: its pixels travel, once, and
            -- the viewer shows them — the cache is keyed by identity, not id.
            local before: any = screen.images[1]
            session:send(key("n"))
            test.not_nil(wait(session, screen, row_is(1, "painter n"), 10))
            test.is_true(session:picture_bytes() > first, "a new identity sends its pixels")
            local after: any = screen.images[1]
            test.is_false(after.serial == before.serial and after.version == before.version, "a new identity")
            test.is_true(after.png ~= before.png, "the new pixels are shown, not the old ones under the same id")
            session:close()

            -- A new session starts clean: the pixels travel again.
            local again = assert(mesh.open({broker = "test.broker.pictures", width = 20, height = 5, graphics = graphics}))
            local fresh = frames.blank(20, 5)
            test.not_nil(wait(again, fresh, row_is(1, "painter start"), 10))
            test.is_true(again:picture_bytes() > 0, "a reopened window is sent everything")
            test.eq(type(fresh.images[1].png), "string")
            test.is_false(fresh.images[1].key == before.key, "a new session is a new source key")
            again:close()
        end)

        test.it("sends no pictures to a viewer that draws in cells", function()
            start_broker_offering("test.broker.cells", "app:painter")
            local session = assert(mesh.open({broker = "test.broker.cells", width = 20, height = 5}))
            local screen = frames.blank(20, 5)
            test.not_nil(wait(session, screen, row_is(1, "painter start"), 10))
            test.is_nil(screen.images, "no pictures without graphics")
            test.eq(session:picture_bytes(), 0)
            session:close()

            -- A grid without a protocol is not graphics: nothing is guessed.
            local unsaid = assert(mesh.open({broker = "test.broker.cells", width = 20, height = 5,
                graphics = {cell_w = 8, cell_h = 20}}))
            local plain = frames.blank(20, 5)
            test.not_nil(wait(unsaid, plain, row_is(1, "painter start"), 10))
            test.is_nil(plain.images, "no pictures without the viewer's protocol")
            test.eq(string.sub(tostring(plain.rows[2]), 1, 8), "gfx nil ", "the desktop heard no protocol")
            unsaid:close()
        end)

        test.it("reaches this node's own broker service and its Chicago desktop", function()
            local session, why = mesh.open({width = 90, height = 26})
            test.not_nil(session, tostring(why))
            local screen = frames.blank(90, 26)
            local up, seen = wait(session, screen, any_row("Start"), 25)
            test.not_nil(up, "the served desktop (ended: " .. tostring(seen.ended) .. ")\n" .. screen_text(screen))
            test.is_true(session:send(inputs.key({type = "key", key_type = "home", key = "home",
                action = "press", alt = true}, "remote")))
            test.not_nil(wait(session, screen, any_row("Programs"), 10), "its Start menu\n" .. screen_text(screen))
            local shots = fs.get("app:shots")
            if shots then shots:writefile("mesh-shell-menu.txt", screen_text(screen) .. "\n") end
            local server = session.server
            session:close()
            test.is_true(gone(server, 15), "closed")
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return {run = function(options) return run_cases(options) end}

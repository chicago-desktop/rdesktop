-- One served desktop session: the server's end of the wire.
--
-- The broker spawns one of these per `open`, on its own node. It creates a
-- local tty viewport, starts the desktop in it with the viewport's grant,
-- answers `opened` to the viewer and then talks to the viewer directly.
--
-- ONE FRAME IN FLIGHT. The queue between nodes is unbounded and never
-- refuses (cluster/internode/state_manager.go, newClassQueue with a zero
-- cap): frames sent to a viewer that stopped reading pile up in this node's
-- memory. So at most one frame is in flight: after a frame, nothing is sent
-- until the viewer acks it, and the next frame is cut FRESH from the live
-- viewport at that moment — revisions in between are never sent. A frame
-- goes out as soon as it is allowed, so the viewer usually holds the next
-- screen before its window asks for it.
--
-- The session ends — the desktop is cancelled, the viewport closed, the
-- process exits — when the viewer closes it, when the viewer's process
-- exits or its node leaves (a LINK_DOWN, trapped: see exits.lua), when the
-- membership says the viewer's node is gone, when nothing has confirmed the
-- viewer for SILENCE_LIMIT while the membership cannot be read, or when the
-- desktop ends by itself (the viewer is told why). The desktop is LINKED to
-- this process: should the session die any other way, the desktop goes
-- with it instead of living on unseen.
local tty = require("tty")
local process = require("process")
local channel = require("channel")
local time = require("time")
local system = require("system")
local logger = require("logger")
local base64 = require("base64")
local frames = require("frames")
local wire = require("wire")
local exits = require("exits")

local host_session = {}

-- How often the viewer's node is looked for in the cluster's membership.
host_session.CHECK_EVERY = "2s"

-- How long a session keeps a viewer nothing confirms — no message from it,
-- no membership that shows its node — before it ends (milliseconds).
host_session.SILENCE_LIMIT = 30000

-- How long the desktop gets to shut down when the session ends; after it,
-- plus a second of slack for the exit to arrive, it is terminated.
--
-- CANCEL IS A REQUEST, NOT A KILL. process.cancel only delivers `pid.cancel`
-- to the target's events; nothing ends a process that does not act on it,
-- whatever the deadline says. The compositor does act on it — as Shut Down,
-- which waits for its windows — so it is asked first, and terminated if it
-- has not gone when the grace is over: the way the runtime's SSH host ends
-- a desktop (service/terminal/ssh.go, cancel). A link does not help either:
-- a session that ends normally does not take its linked desktop along.
host_session.CLOSE_GRACE = "5s"
host_session.CLOSE_WAIT = "6s"

-- base_of(state, revision) -> rows of the frame in flight | nil
--
-- The base of the next frame: the frame in flight when the viewer acked
-- exactly its revision; anything else is answered with every row.
local function base_of(state: any, revision: any): any
    if state.sent_revision == nil or revision ~= state.sent_revision or not state.sent_last then return nil end
    return state.sent_last
end

local function now_ms(): integer
    return math.tointeger(time.now():unix_nano() // 1000000) or 0
end

-- forward(view, event) — a viewer's event into the viewport; one the
-- viewport does not accept is dropped, as a local one would be.
local function forward(view: any, event: any)
    view:send(event)
end

-- stop(desktop, exit, log) — ask the desktop to finish, then make sure.
-- Every refusal is logged: a cancel that is not allowed returns nil, err
-- and was once dropped here silently, leaving the desktop running.
local function stop(desktop: string, exit: any, log: any)
    local asked, why = process.cancel(desktop, host_session.CLOSE_GRACE)
    if not asked then log:warn("desktop not asked to finish", {desktop = desktop, error = tostring(why)}) end
    local picked = channel.select({exit:case_receive(), time.after(host_session.CLOSE_WAIT):case_receive()})
    if picked.channel == exit then return end
    local ended, err = process.terminate(desktop)
    if ended then
        log:warn("desktop terminated after the grace", {desktop = desktop})
    else
        log:error("desktop could not be ended", {desktop = desktop, error = tostring(err)})
    end
end

-- pictures(state, images) -> the frame's `p`: every picture on the screen,
-- the PNG only for a (serial, version) this viewer has not been sent.
--
-- The cache is not an optimisation: a desktop's wallpaper re-sent with
-- every keystroke would fill the unbounded queue between the nodes. It
-- lives as long as the session; a new `open` is a new session and starts
-- empty, so a viewer that forgot everything (a reopened window) is sent
-- everything again.
local function pictures(state: any, images: any, log: any): any
    local out: any = {}
    for _, entry in ipairs(type(images) == "table" and images or {}) do
        local image: any = entry
        local key = wire.picture_key(image.serial, image.version)
        local picture: any = {i = tostring(image.id), x = image.x, y = image.y, c = image.cols, r = image.rows,
            z = image.z, s = image.serial, v = image.version}
        if not state.known[key] then
            local png, err = image.raster:encode("png")
            if png then
                picture.b = base64.encode(tostring(png))
                state.known[key] = true
                state.sent_bytes = state.sent_bytes + #picture.b
            else
                log:warn("picture not encoded", {id = tostring(image.id), error = tostring(err)})
            end
        end
        out[#out + 1] = picture
    end
    return out
end

-- main(viewer, session, width, height, entry, host, graphics?)
--
-- `graphics` is the viewer's grid and protocol from `open` (wire.lua, `g`).
-- With it the desktop is told, BEFORE it starts, that it has the VIEWER'S
-- protocol on exactly that grid (view:terminal) — the grid the viewer draws
-- the remote screen on, not any terminal's cell — and the frames carry its
-- pictures. The protocol is the viewer's, never one chosen here: the desktop
-- decides by it how to draw, and a constant that happens to match one
-- viewer diverges from the next one without a word. Without `graphics`, or
-- with a protocol the runtime refuses, the desktop stays in cells and no
-- picture is sent.
function host_session.main(viewer: any, session: any, width: any, height: any, entry: any, host: any, graphics: any)
    local log = logger:named("chicago.rdesktop.session")
    local number = math.tointeger(session) or 0
    viewer = tostring(viewer)
    local viewer_node = wire.node_of(viewer)
    -- Before any link or monitor: a departure must arrive as an event.
    exits.trap()
    local inbox = process.listen(wire.TOPIC, {message = true})

    local function fail(reason: string)
        log:warn("session refused", {viewer = viewer, session = number, reason = reason})
        wire.send(viewer, {k = "failed", s = number, m = reason})
    end

    local cols, rows = math.tointeger(width), math.tointeger(height)
    if cols == nil or cols < 1 or rows == nil or rows < 1 then return fail("the screen size is not positive") end
    local view, verr = tty.viewport({width = cols, height = rows})
    if not view then return fail("the remote computer could not make a screen: " .. tostring(verr)) end
    local updates = assert(view:updates())
    local drawn: any = type(graphics) == "table" and (math.tointeger(graphics.cell_w) or 0) > 0
        and (math.tointeger(graphics.cell_h) or 0) > 0 and type(graphics.protocol) == "string"
        and graphics or nil
    if drawn then
        local told, why = view:terminal(tostring(drawn.protocol), math.tointeger(drawn.cell_w) or 0,
            math.tointeger(drawn.cell_h) or 0)
        if not told then
            log:warn("desktop not told it has graphics; it stays in cells",
                {protocol = tostring(drawn.protocol), error = tostring(why)})
            drawn = nil
        end
    elseif graphics ~= nil then
        log:warn("desktop not told it has graphics; it stays in cells",
            {error = "the viewer's graphics name no grid or no protocol"})
    end
    local grant = assert(view:grant())
    local desktop, derr = process.with_options({terminal = grant})
        :spawn_linked_monitored(tostring(entry), tostring(host))
    if not desktop then
        view:close()
        return fail("the remote computer could not start its desktop: " .. tostring(derr))
    end
    desktop = tostring(desktop)
    local desktop_exit = exits.watch(desktop)
    process.monitor(viewer)
    local viewer_exit = exits.watch(viewer)

    -- Mutable state in a table (go-lua and pcall).
    local state: any = {inflight = false, acked = -1, sent_revision = nil, sent_last = nil,
        reason = nil, tell = true, life = now_ms(), known = {}, sent_bytes = 0}

    wire.send(viewer, {k = "opened", s = number, x = cols, y = rows})

    local function pump()
        if state.inflight then return end
        local snapshot: any = view:snapshot(math.tointeger(state.acked) or -1)
        if snapshot == nil then return end
        local delta: any, last: any = frames.delta(base_of(state, state.acked), snapshot)
        local message: any = wire.frame(number, delta)
        if drawn then message.p = pictures(state, snapshot.images, log) end
        local sent, why = wire.send(viewer, message)
        if not sent then
            log:error("frame not sent", {viewer = viewer, session = number, error = tostring(why)})
            return
        end
        state.inflight = true
        state.sent_revision, state.sent_last = snapshot.revision, last
    end

    local check = time.after(host_session.CHECK_EVERY)
    while state.reason == nil do
        local picked = channel.select({inbox:case_receive(), updates:case_receive(),
            desktop_exit:case_receive(), viewer_exit:case_receive(), check:case_receive()})
        if picked.channel == inbox then
            local message: any = picked.value
            local data: any = message:payload():data()
            if tostring(message:from()) == viewer and type(data) == "table"
                and math.tointeger(data.s) == number then
                state.life = now_ms()
                if data.k == "ack" then
                    local revision = math.tointeger(data.r)
                    if base_of(state, revision) then
                        state.acked = revision
                    else
                        -- Not the frame in flight: the viewer has nothing
                        -- this side can cut from — every row next.
                        state.acked, state.sent_last = -1, nil
                    end
                    state.inflight = false
                    pump()
                elseif data.k == "input" and type(data.e) == "table" then
                    forward(view, data.e)
                elseif data.k == "resize" then
                    local w, h = math.tointeger(data.x), math.tointeger(data.y)
                    if w and h and w > 0 and h > 0 then view:resize(w, h) end
                elseif data.k == "close" then
                    state.reason, state.tell = "the viewer closed the session", true
                end
            end
        elseif picked.channel == updates then
            pump()
        elseif picked.channel == desktop_exit then
            local result: any = picked.value
            state.reason = type(result) == "table" and result.error ~= nil
                and ("The remote desktop failed: " .. tostring(result.error)) or "The remote desktop ended."
            desktop = nil
        elseif picked.channel == viewer_exit then
            local result: any = picked.value
            if type(result) == "table" and result.link_down then
                state.reason = "the viewer's computer left the cluster"
            else
                state.reason = "the viewer's process is gone"
            end
            state.tell = false
        else
            check = time.after(host_session.CHECK_EVERY)
            local members = system.cluster.members()
            local present = wire.present(members, viewer_node)
            if present == true then state.life = now_ms() end
            local verdict = wire.judge(present, math.tointeger(state.life) or 0, now_ms(), host_session.SILENCE_LIMIT)
            if verdict == "gone" then
                state.reason, state.tell = "the viewer's computer left the cluster", false
            elseif verdict == "expired" then
                state.reason = "nothing has confirmed the viewer for " .. tostring(host_session.SILENCE_LIMIT // 1000) .. " s"
            end
        end
    end

    log:info("session ends", {viewer = viewer, session = number, reason = state.reason,
        pictures_sent = state.sent_bytes})
    exits.forget(viewer)
    -- The viewer hears first: the desktop's shutdown takes up to the grace.
    if state.tell then wire.send(viewer, {k = "closed", s = number, m = state.reason}) end
    if desktop then stop(desktop, desktop_exit, log) end
    view:close()
end

return host_session

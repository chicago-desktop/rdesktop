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
-- exits, when the viewer's node leaves the cluster, or when the desktop
-- ends by itself (the viewer is told why).
local tty = require("tty")
local process = require("process")
local channel = require("channel")
local time = require("time")
local system = require("system")
local logger = require("logger")
local frames = require("frames")
local wire = require("wire")
local exits = require("exits")

local host_session = {}

-- How often the viewer's node is looked for in the cluster's membership.
host_session.CHECK_EVERY = "2s"

-- How long the desktop gets to shut down when the session ends.
host_session.CLOSE_GRACE = "5s"

-- base_of(state, revision) -> rows of the frame in flight | nil
--
-- The base of the next frame: the frame in flight when the viewer acked
-- exactly its revision; anything else is answered with every row.
local function base_of(state: any, revision: any): any
    if state.sent_revision == nil or revision ~= state.sent_revision or not state.sent_last then return nil end
    return state.sent_last
end

-- forward(view, event) — a viewer's event into the viewport; one the
-- viewport does not accept is dropped, as a local one would be.
local function forward(view: any, event: any)
    view:send(event)
end

-- main(viewer, session, width, height, entry, host)
function host_session.main(viewer: any, session: any, width: any, height: any, entry: any, host: any)
    local log = logger:named("chicago.rdesktop.session")
    local number = math.tointeger(session) or 0
    viewer = tostring(viewer)
    local viewer_node = wire.node_of(viewer)
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
    local grant = assert(view:grant())
    local desktop, derr = process.with_options({terminal = grant})
        :spawn_monitored(tostring(entry), tostring(host))
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
        reason = nil, tell = true}

    wire.send(viewer, {k = "opened", s = number, x = cols, y = rows})

    local function pump()
        if state.inflight then return end
        local snapshot: any = view:snapshot(math.tointeger(state.acked) or -1)
        if snapshot == nil then return end
        local delta: any, last: any = frames.delta(base_of(state, state.acked), snapshot)
        local sent, why = wire.send(viewer, wire.frame(number, delta))
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
            state.reason, state.tell = "the viewer's process is gone", false
        else
            check = time.after(host_session.CHECK_EVERY)
            local members = system.cluster.members()
            if wire.present(members, viewer_node) == false then
                state.reason, state.tell = "the viewer's computer left the cluster", false
            end
        end
    end

    log:info("session ends", {viewer = viewer, session = number, reason = state.reason})
    if desktop then process.cancel(desktop, host_session.CLOSE_GRACE) end
    exits.forget(viewer)
    view:close()
    if state.tell then wire.send(viewer, {k = "closed", s = number, m = state.reason}) end
end

return host_session

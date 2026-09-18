-- The loopback transport of a remote-desktop session: the "remote" desktop
-- runs on this node, in a local tty viewport.
--
-- THE SESSION INTERFACE. The window reaches the remote desktop only through
-- it, so a network transport replaces this library by changing the one
-- `transport:` import of the window entry. A session has the shape of the
-- runtime's tty Viewport (api/tty/service.go, the `tty` module's Viewport),
-- name for name, plus what a viewport does not say — that its producer is
-- gone:
--
--   transport.open(spec)            -> session | nil, reason
--       spec = {entry, host, width, height, args?}: create the viewport and
--       start the desktop `entry` on process host `host` with its grant.
--       (`node` is ignored: the loopback desktop is always on this node.)
--   session:grant()                 -> nil, reason
--       the producer grant; one-shot, and open() has already given it to
--       the desktop it started, so it is always consumed here.
--   session:handle()                -> string | nil
--       a viewer handle for another local viewer; a remote session has none.
--   session:snapshot(after_revision) -> delta | nil
--       nil when the screen is still at `after_revision`. Otherwise a DELTA
--       from `after_revision` to the current screen (chicago.rdesktop:frames):
--       only the changed rows when `after_revision` is the revision of the
--       previous delta, every row (`full`) otherwise. `after_revision` is the
--       viewer's acknowledgement — "I have applied this one".
--   session:updates()               -> channel
--       coalesced revision watermarks; a watermark means "call snapshot".
--   session:send(event)             -> true | nil, reason
--       a key, mouse or paste event in the remote screen's coordinates.
--   session:resize(width, height)   -> true | nil, reason
--   session:close()                 -> true
--       ends the remote desktop and releases the session; idempotent.
--   session:ended()                 -> channel
--       receives one value, the reason, when the remote desktop has ended.
--
-- ONE FRAME IN FLIGHT. A viewer asks for the next delta only after it has
-- applied the previous one, and a delta is always cut from the live
-- viewport at the moment it is asked for: revisions between two asks are
-- never sent, the wire carries the latest screen, not every screen. That is
-- the viewport's own contract (updates are coalesced watermarks) and the
-- one a network transport must keep — a queue of frames towards a viewer
-- that stopped reading is memory, not lost frames. The deltas are computed
-- here, on the producer's side; a network transport computes them on the
-- producer's node and ships only them.
local tty = require("tty")
local process = require("process")
local channel = require("channel")
local frames = require("frames")
local exits = require("exits")

local loopback = {}

loopback.NAME = "loopback"

-- How long the remote desktop gets to shut down on close: it closes its
-- windows as Shut Down does, then its process is terminated.
loopback.CLOSE_GRACE = "5s"

local function dimension(value: any): integer?
    local number = math.tointeger(value)
    if number == nil or number < 1 then return nil end
    return number
end

-- acknowledged(state, after) -> rows of the last delta | nil
--
-- The base of the next delta: the previous one only when the viewer says it
-- has applied exactly that one; anything else gets the whole screen.
local function acknowledged(state: any, after: integer): any
    if state.sent_revision ~= after or not state.sent_last then return nil end
    return state.sent_last
end

-- open(spec) -> session | nil, reason
function loopback.open(spec: any): (any, string?)
    if type(spec) ~= "table" then return nil, "no session spec" end
    local width, height = dimension(spec.width), dimension(spec.height)
    if width == nil or height == nil then
        return nil, "the screen size is not positive: " .. tostring(spec.width) .. "x" .. tostring(spec.height)
    end
    if type(spec.entry) ~= "string" or spec.entry == "" then return nil, "no desktop entry to start" end
    if type(spec.host) ~= "string" or spec.host == "" then return nil, "no process host to start it on" end

    local view, verr = tty.viewport({width = width, height = height})
    if not view then return nil, "viewport: " .. tostring(verr) end
    local updates, uerr = view:updates()
    if not updates then
        view:close()
        return nil, "viewport updates: " .. tostring(uerr)
    end
    local grant, gerr = view:grant()
    if not grant then
        view:close()
        return nil, "viewport grant: " .. tostring(gerr)
    end
    local pid, perr = process.with_options({terminal = grant})
        :spawn_monitored(spec.entry, spec.host, spec.args)
    if not pid then
        view:close()
        return nil, "Could not connect: the host did not start " .. spec.entry .. " with the terminal: " .. tostring(perr)
    end
    -- The desktop's end, worded, on a channel of the session's own.
    local ended = channel.new(1)
    local exit = exits.watch(tostring(pid))
    coroutine.spawn(function()
        local result: any = exit:receive()
        if type(result) == "table" and result.error ~= nil then
            ended:send("the remote desktop failed: " .. tostring(result.error))
        else
            ended:send("the remote desktop ended")
        end
    end)

    -- Mutable state lives in a table: after an error under pcall go-lua
    -- stops sharing a local between a closure and its owner.
    -- `sent_revision` / `sent_last` — the revision and the rows of the last
    -- delta handed out (no delta yet: a revision no snapshot has).
    local state: any = {view = view, updates = updates, ended = ended, pid = tostring(pid), closed = false,
        sent_revision = -2, sent_last = false}
    local session: any = {pid = tostring(pid), transport = loopback.NAME}

    function session:grant(): (string?, string?)
        return nil, "the grant was given to " .. tostring(spec.entry) .. " when the session opened"
    end

    function session:handle()
        if state.closed then return nil end
        local handle = state.view:handle()
        return handle
    end

    function session:snapshot(after_revision: any): any
        if state.closed then return nil end
        local after = math.tointeger(after_revision) or -1
        local snapshot: any = state.view:snapshot(after)
        if snapshot == nil then return nil end
        local base = acknowledged(state, after)
        local delta: any, last: any = frames.delta(base, snapshot)
        state.sent_revision, state.sent_last = snapshot.revision, last
        return delta
    end

    function session:updates(): any
        return state.updates
    end

    function session:send(event: any): (boolean?, string?)
        if state.closed then return nil, "the session is closed" end
        local ok, err = state.view:send(event)
        if not ok then return nil, tostring(err) end
        return true, nil
    end

    function session:resize(w: any, h: any): (boolean?, string?)
        if state.closed then return nil, "the session is closed" end
        local cols, rows = dimension(w), dimension(h)
        if cols == nil or rows == nil then return nil, "the size is not positive" end
        local ok, err = state.view:resize(cols, rows)
        if not ok then return nil, tostring(err) end
        return true, nil
    end

    function session:close(): boolean
        if state.closed then return true end
        state.closed = true
        -- Its end is still sent to `ended` (buffered, nobody need read it).
        -- Cancelling a desktop that has already ended is refused harmlessly.
        process.cancel(tostring(state.pid), loopback.CLOSE_GRACE)
        state.view:close()
        return true
    end

    function session:ended(): any
        return state.ended
    end

    return session, nil
end

return loopback

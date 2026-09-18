-- The mesh transport of a remote-desktop session: the desktop runs on
-- another node of the cluster, served by that node's broker
-- (chicago.rdesktop:broker) over the session protocol (chicago.rdesktop:wire).
--
-- The same session interface as chicago.rdesktop:loopback — the window does
-- not know which one it has:
--
--   transport.open{node?, entry?, width, height, graphics?} -> session | nil, reason
--       `node` is a node id from system.cluster.members(); none is this node.
--       `entry` is only checked against what the node offers.
--   session:grant() / handle()      -> nil (the viewport is on the other node)
--   session:snapshot(after_revision) -> delta | nil
--   session:updates()               -> channel of "a frame is here"
--   session:send(event), session:resize(width, height), session:close()
--   session:ended()                 -> channel of the reason
--
-- ONE FRAME IN FLIGHT, from this side: the server sends a frame only after
-- the previous one was acked. The frame that arrives is kept here until the
-- window asks (`snapshot`), so the window never waits for the network; the
-- ack goes out as the frame is handed over, and the server cuts the next
-- one from its live viewport. `after_revision` other than the revision this
-- side last handed over means the window lost its copy: the frame is
-- dropped and the ack asks for every row.
--
-- A session ends when the server says so (closed, failed), when the server
-- session's process exits or its node leaves (a LINK_DOWN, trapped: see
-- exits.lua), when the membership says the node is gone, or when nothing
-- has confirmed the server for SILENCE_LIMIT while the membership cannot
-- be read; the reason arrives on `ended()`, never silence — and never the
-- window's own death.
local process = require("process")
local channel = require("channel")
local time = require("time")
local system = require("system")
local wire = require("wire")
local exits = require("exits")
local base64 = require("base64")

local mesh = {}

mesh.NAME = "mesh"

-- How long `open` waits for the node to answer.
mesh.OPEN_TIMEOUT = "10s"

-- How often the server's node is looked for in the cluster's membership.
mesh.CHECK_EVERY = "2s"

-- How long a session keeps a server nothing confirms — no message from it,
-- no membership that shows its node — before it ends (milliseconds).
mesh.SILENCE_LIMIT = 30000

local function now_ms(): integer
    return math.tointeger(time.now():unix_nano() // 1000000) or 0
end

-- Module state, one per process: the sessions by number, and one reader of
-- the protocol topic for all of them.
local viewer: any = {sessions = {}, next = 0, started = false}

local function finish(entry: any, reason: string)
    if entry.over then return end
    entry.over = true
    viewer.sessions[entry.number] = nil
    if entry.server then exits.forget(tostring(entry.server)) end
    entry.ended:send(reason)
end

local function deliver(entry: any, data: any, from: string)
    if entry.server == nil or entry.server == from then entry.life = now_ms() end
    if data.k == "opened" and entry.opening then
        entry.server = from
        entry.opening:send({ok = true, width = data.x, height = data.y})
    elseif data.k == "failed" then
        if entry.opening then entry.opening:send({ok = false, reason = tostring(data.m or "the remote computer refused")})
        else finish(entry, tostring(data.m or "The remote computer refused.")) end
    elseif data.k == "frame" and entry.server == from then
        entry.pending = data
        entry.received = entry.received + 1
        -- A watermark, not a queue: one slot, a full slot is enough.
        channel.select({entry.updates:case_send(true)}, true)
    elseif data.k == "closed" and entry.server == from then
        finish(entry, tostring(data.m or "The remote session ended."))
    end
end

local function run()
    local inbox = process.listen(wire.TOPIC, {message = true})
    local check = time.after(mesh.CHECK_EVERY)
    while true do
        local picked = channel.select({inbox:case_receive(), check:case_receive()})
        if picked.channel == inbox then
            if not picked.ok then
                for _, entry in pairs(viewer.sessions) do finish(entry, "The connection can no longer be read.") end
                viewer.started = false
                return
            end
            local message: any = picked.value
            local data: any = message:payload():data()
            if type(data) == "table" then
                local entry: any = viewer.sessions[math.tointeger(data.s) or -1]
                if entry then deliver(entry, data, tostring(message:from())) end
            end
        else
            check = time.after(mesh.CHECK_EVERY)
            if next(viewer.sessions) ~= nil then
                local members = system.cluster.members()
                for _, entry in pairs(viewer.sessions) do
                    local present = wire.present(members, tostring(entry.node))
                    if present == true then entry.life = now_ms() end
                    local verdict = wire.judge(present, math.tointeger(entry.life) or 0, now_ms(), mesh.SILENCE_LIMIT)
                    if verdict == "gone" then
                        finish(entry, "The connection to " .. entry.node .. " was lost.")
                    elseif verdict == "expired" and entry.opening == nil then
                        finish(entry, "Nothing has confirmed " .. entry.node .. " for "
                            .. tostring(mesh.SILENCE_LIMIT // 1000) .. " s.")
                    end
                end
            end
        end
    end
end

-- images(entry, list) -> the pictures of a frame, as the terminal view takes
-- them: {id, key, png, serial, version, x, y, cols, rows, z}
--
-- A picture's PNG arrives once per (serial, version) and is kept, as bytes,
-- for the session; later frames name it by that pair. It is handed on as
-- bytes, never decoded here: the window's tree is PUBLISHED to the
-- compositor, and a raster does not survive being sent to another process
-- (it arrives nil — the owner saw white rectangles where the remote windows
-- were). The compositor's renderer decodes it once, by `key`.
--
-- `key` is "<node>:<session>:<id>": unique to this source. A serial is
-- counted per process, so two nodes can both have "bars" with serial 3, and
-- keyed by id:serial:version the renderer would show the other one's.
local function images(entry: any, list: any): any
    local out: any = {}
    for _, item in ipairs(type(list) == "table" and list or {}) do
        local picture: any = item
        local identity = wire.picture_key(picture.s, picture.v)
        if type(picture.b) == "string" then
            entry.picture_bytes = entry.picture_bytes + #picture.b
            if entry.pngs[identity] == nil then
                local bytes = base64.decode(picture.b)
                if bytes then entry.pngs[identity] = bytes end
            end
        end
        local png: any = entry.pngs[identity]
        if png then
            out[#out + 1] = {id = tostring(picture.i),
                key = tostring(entry.node) .. ":" .. tostring(entry.number) .. ":" .. tostring(picture.i),
                png = png, serial = picture.s, version = picture.v,
                x = picture.x, y = picture.y, cols = picture.c, rows = picture.r, z = picture.z}
        end
    end
    return out
end

-- take(entry) -> the frame held for the window | nil; it is no longer held.
local function take(entry: any): any
    if entry.over then return nil end
    local data = entry.pending
    entry.pending = nil
    return data
end

-- ended_reason(node, result) -> the words for the serving session's end
--
-- The node is named here: the runtime's own reason for a departed node
-- ("node disconnected", minted in boot/components/system/topology.go) does
-- not say which one, and this side knows — it opened the session.
function mesh.ended_reason(node: string, result: any): string
    local r: any = type(result) == "table" and result or {}
    local why = r.error ~= nil and tostring(r.error) or nil
    if r.link_down or (why and string.find(why, "disconnect", 1, true)) then
        return "The connection to " .. node .. " was lost."
    elseif why then
        return "The remote session on " .. node .. " failed: " .. why
    end
    return "The remote session on " .. node .. " ended."
end

-- The server session's exit, told as the end of the session.
local function watch_server(entry: any)
    local server = tostring(entry.server)
    local exit = exits.watch(server)
    process.monitor(server)
    coroutine.spawn(function()
        local result: any = exit:receive()
        finish(entry, mesh.ended_reason(tostring(entry.node), result))
    end)
end

-- open(spec) -> session | nil, reason
function mesh.open(spec: any): (any, string?)
    if type(spec) ~= "table" then return nil, "no session spec" end
    local width, height = math.tointeger(spec.width), math.tointeger(spec.height)
    if width == nil or width < 1 or height == nil or height < 1 then
        return nil, "the screen size is not positive: " .. tostring(spec.width) .. "x" .. tostring(spec.height)
    end
    local node: any = spec.node
    if type(node) ~= "string" or node == "" then
        local own, err = system.node.id()
        if not own then return nil, "this computer has no node id: " .. tostring(err) end
        node = tostring(own)
    end
    -- Before any monitor: a departure must arrive as an event (exits.lua).
    exits.trap()
    -- `broker` names another broker (tests); a window never passes it.
    local name = type(spec.broker) == "string" and spec.broker ~= "" and spec.broker or wire.broker_name(node)
    local broker_pid = process.registry.lookup(name)
    if not broker_pid then
        return nil, "The computer is not accessible. Remote Desktop is not enabled on " .. node .. "."
    end

    viewer.next = viewer.next + 1
    local entry: any = {number = viewer.next, node = node, server = nil, pending = nil, received = 0, life = now_ms(),
        pngs = {}, picture_bytes = 0,
        handed = nil, over = false, opening = channel.new(1),
        updates = channel.new(1), ended = channel.new(1)}
    viewer.sessions[entry.number] = entry
    if not viewer.started then
        viewer.started = true
        coroutine.spawn(run)
    end

    local asked: any = {k = "open", s = entry.number, x = width, y = height}
    if type(spec.entry) == "string" and spec.entry ~= "" then asked.n = spec.entry end
    if type(spec.graphics) == "table" then
        asked.g = {cell_w = math.tointeger(spec.graphics.cell_w) or 0, cell_h = math.tointeger(spec.graphics.cell_h) or 0}
    end
    local sent, serr = wire.send(tostring(broker_pid), asked)
    if not sent then
        viewer.sessions[entry.number] = nil
        return nil, "The computer is not accessible: " .. tostring(serr)
    end
    local deadline = time.after(mesh.OPEN_TIMEOUT)
    local picked = channel.select({entry.opening:case_receive(), deadline:case_receive()})
    entry.opening = nil
    if picked.channel == deadline then
        viewer.sessions[entry.number] = nil
        return nil, "The remote computer " .. node .. " did not answer."
    end
    local answer: any = picked.value
    if not answer.ok then
        viewer.sessions[entry.number] = nil
        return nil, tostring(answer.reason)
    end
    watch_server(entry)

    local session: any = {transport = mesh.NAME, node = node, number = entry.number}
    session.server = entry.server

    local function tell(message: any): (boolean?, string?)
        if entry.over then return nil, "the session is over" end
        message.s = entry.number
        local ok, err = wire.send(tostring(entry.server), message)
        return ok, err
    end

    function session:grant(): (string?, string?)
        return nil, "the grant is on " .. node
    end

    function session:handle(): string?
        return nil
    end

    function session:snapshot(after_revision: any): any
        local data = take(entry)
        if data == nil then return nil end
        local after = math.tointeger(after_revision) or -1
        local handed = entry.handed ~= nil and entry.handed or -1
        if after ~= handed then
            -- The window's copy is not what this side handed over: ask for
            -- every row rather than hand a delta against the wrong base.
            entry.handed = nil
            tell({k = "ack"})
            return nil
        end
        local delta = wire.delta(data)
        if delta == nil then
            tell({k = "ack"})
            return nil
        end
        if data.p ~= nil then delta.images = images(entry, data.p) end
        entry.handed = delta.revision
        tell({k = "ack", r = delta.revision})
        return delta
    end

    function session:updates(): any
        return entry.updates
    end

    function session:send(event: any): (boolean?, string?)
        local ok, err = tell({k = "input", e = event})
        return ok, err
    end

    function session:resize(w: any, h: any): (boolean?, string?)
        local cols, rows = math.tointeger(w), math.tointeger(h)
        if cols == nil or rows == nil or cols < 1 or rows < 1 then return nil, "the size is not positive" end
        local ok, err = tell({k = "resize", x = cols, y = rows})
        return ok, err
    end

    function session:close(): boolean
        if not entry.over then
            tell({k = "close"})
            finish(entry, "closed")
        end
        return true
    end

    function session:ended(): any
        return entry.ended
    end

    -- For tests: frames received so far (one in flight, never a queue), and
    -- the picture bytes they carried (each picture's pixels once).
    function session:received(): integer
        return math.tointeger(entry.received) or 0
    end

    function session:picture_bytes(): integer
        return math.tointeger(entry.picture_bytes) or 0
    end

    return session, nil
end

return mesh

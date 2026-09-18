-- The session protocol between a viewer and the node that serves a desktop,
-- as Lua tables. The same frame as runtime/service/rdesktop/protocol.go
-- (`Frame`), field for field:
--
--   k  kind       open | opened | frame | ack | input | resize | close | closed | failed
--   s  session    the viewer's number for the session; the server keys on
--                 (viewer PID, s), so two viewers never collide
--   r  revision   the viewport revision a frame carries or an ack acknowledges
--   x  width      cells; on open, resize, opened and every frame
--   y  height
--   w  rows       ONLY the rows that changed since the acknowledged revision,
--                 keyed by the row's ZERO-based index from the top; a full
--                 screen is the case where every row changed
--   c  cursor     zero-based {x, y, visible}, as api/tty has it; absent keeps
--                 the last one
--   e  event      one terminal event (input)
--   n  entry      the desktop entry asked for on open; absent is the
--                 server's default
--   m  reason     why a session closed or failed, in words for the status line
--   g  graphics   on open: the viewer's grid and its terminal's graphics,
--                 {cell_w, cell_h, protocol} (cell_w is the mono column the
--                 remote screen is drawn in; protocol is "kitty" or "sixel",
--                 what the viewer's own terminal speaks); absent when the
--                 viewer draws in cells or does not know its protocol. With
--                 it the serving side tells its desktop it has THAT protocol
--                 on that grid (view:terminal) and sends pictures; without
--                 it, neither.
--   p  pictures   on a frame, when the viewer has graphics: EVERY picture
--                 standing on the screen, a list of {i = id, x, y, c = cols,
--                 r = rows, z, s = serial, v = version, b = bytes?}; x and y
--                 one-based on the remote screen's grid. `b` (the PNG,
--                 base64) is sent once per (serial, version) per session:
--                 the pair is the picture's identity, kept as it crossed the
--                 viewport, and a picture the viewer has is sent as its
--                 geometry alone. A new `open` is a clean slate.
--
-- Who sends what: the viewer sends open, ack, input, resize and close; the
-- server sends opened, frame, closed and failed.
--
-- WHAT SURVIVES THE HOP. Between nodes a Lua payload is turned into Go values
-- (engine/value.ToGoAny) and msgpack: a table whose MaxN is above zero
-- becomes a list 1..MaxN and every key past the first gap is DROPPED without
-- a word, and a key 0 is never in the list. On one node the table is passed
-- as it is, so a single-node test cannot see it. So row keys travel as
-- decimal strings ("0", "7"), and `send` refuses any message that has a
-- table that is neither a gapless list nor string-keyed (`safe`).
--
-- Only the Lua side converts: rows and the cursor are one-based in `frames`
-- and the `tty` module, zero-based on the wire.
local process = require("process")

local wire = {}

wire.TOPIC = "chicago.rdesktop"

wire.KINDS = {open = true, opened = true, frame = true, ack = true, input = true,
    resize = true, close = true, closed = true, failed = true}

-- The name a node's broker answers to in the cluster's name registry
-- (EVENTUAL scope): derived from the node's id, the one `system.cluster.members()`
-- reports. The relay's node id in a PID must be that same id
-- (relay.node_name = cluster.name), or a viewer addresses a node that does
-- not exist.
wire.BROKER_PREFIX = "chicago.rdesktop.broker@"

function wire.broker_name(node: string): string
    return wire.BROKER_PREFIX .. node
end

-- node_of(pid) -> node | nil — the node id in "{node@host|0x…}".
function wire.node_of(pid: any): string?
    local node = string.match(tostring(pid or ""), "^{([^@|}]+)@")
    return node
end

-- host_of(pid) -> host | nil — the process host in "{node@host|0x…}".
function wire.host_of(pid: any): string?
    local host = string.match(tostring(pid or ""), "^{[^@|}]+@([^|}]+)|")
    return host
end

-- safe(value) -> true | nil, where
--
-- Whether a value comes out of the hop as it went in: every table is either
-- a gapless list 1..n with nothing else, or has string keys only.
local function safe_at(value: any, where: string): (boolean?, string?)
    if type(value) ~= "table" then return true, nil end
    local count, strings, integers = 0, 0, 0
    local top = 0
    for key, item in pairs(value) do
        count = count + 1
        if type(key) == "string" then
            strings = strings + 1
        elseif type(key) == "number" and math.tointeger(key) ~= nil then
            -- math.type is not "integer" for a list key in go-lua: ask the value.
            local index = math.tointeger(key) or 0
            integers = integers + 1
            if index > top then top = index end
        else
            return nil, where .. " has a key of type " .. type(key)
        end
        local ok, why = safe_at(item, where .. "." .. tostring(key))
        if not ok then return nil, why end
    end
    if integers > 0 then
        if strings > 0 then return nil, where .. " mixes list and string keys" end
        if top ~= integers or value[1] == nil then
            return nil, where .. " is a list with gaps or not starting at 1"
        end
    end
    return true, nil
end

function wire.safe(value: any): (boolean?, string?)
    local ok, why = safe_at(value, "message")
    return ok, why
end

-- send(pid, message) -> true | nil, reason
--
-- The one way a message leaves: checked for its kind and its shape first,
-- so a table that would lose rows between nodes fails here, on every node.
function wire.send(pid: string, message: any): (boolean?, string?)
    if type(message) ~= "table" or not wire.KINDS[message.k] then
        return nil, "not a session message: " .. tostring(type(message) == "table" and message.k or message)
    end
    local ok, why = wire.safe(message)
    if not ok then return nil, "refused to send a " .. tostring(message.k) .. " that would not survive the hop: " .. tostring(why) end
    local sent, err = process.send(pid, wire.TOPIC, message)
    if not sent then return nil, tostring(err) end
    return true, nil
end

-- frame(session, delta) -> message
--
-- A `frames` delta (one-based rows and cursor) as a frame on the wire.
function wire.frame(session: integer, delta: any): any
    local rows = {}
    for y, row in pairs(delta.rows) do rows[tostring(y - 1)] = row end
    local message: any = {k = "frame", s = session, r = delta.revision,
        x = delta.width, y = delta.height, w = rows}
    local cursor: any = delta.cursor
    if type(cursor) == "table" then
        message.c = {x = (math.tointeger(cursor.x) or 1) - 1, y = (math.tointeger(cursor.y) or 1) - 1,
            visible = cursor.visible == true}
    end
    return message
end

-- delta(message) -> delta | nil, reason
--
-- A frame from the wire as a `frames` delta. `full` is not on the wire: a
-- full screen is a frame that carries every row.
function wire.delta(message: any): (any, string?)
    local width = math.tointeger(message.x)
    local height = math.tointeger(message.y)
    if width == nil or width < 1 or height == nil or height < 1 then
        return nil, "a frame without a size"
    end
    local rows = {}
    local changed = 0
    for key, row in pairs(type(message.w) == "table" and message.w or {}) do
        local index = math.tointeger(tonumber(key))
        if index ~= nil and index >= 0 and index < height and type(row) == "string" then
            rows[index + 1] = row
            changed = changed + 1
        end
    end
    local cursor: any = nil
    local c: any = message.c
    if type(c) == "table" then
        cursor = {x = (math.tointeger(c.x) or 0) + 1, y = (math.tointeger(c.y) or 0) + 1, visible = c.visible == true}
    end
    return {revision = math.tointeger(message.r) or 0, width = width, height = height,
        rows = rows, cursor = cursor, full = changed == height, changed = changed}, nil
end

-- judge(present, last_life, now, ceiling) -> "gone" | "here" | "unknown" | "expired"
--
-- What a session does about the other side, in three states and a ceiling.
-- `present` is wire.present's answer. Gone (the membership says so) ends
-- the session; here keeps it. Unknown (the membership could not be read —
-- a node that lost its quorum answers nothing) keeps it too, but not for
-- ever: with no sign of the other side — a message from it, or a
-- membership that confirmed it — for longer than `ceiling` it is expired,
-- and the session ends. Times are in milliseconds.
function wire.judge(present: boolean?, last_life: integer, now: integer, ceiling: integer): string
    if present == false then return "gone" end
    if present == true then return "here" end
    if now - last_life > ceiling then return "expired" end
    return "unknown"
end

-- picture_key(serial, version) -> the identity a picture is cached by
function wire.picture_key(serial: any, version: any): string
    return tostring(math.tointeger(serial) or 0) .. ":" .. tostring(math.tointeger(version) or 0)
end

-- present(members, node) -> boolean | nil
--
-- Whether `node` is in a `system.cluster.members()` answer; nil when the
-- answer says nothing (no list), so "unknown" is never taken for "gone".
function wire.present(members: any, node: string?): boolean?
    if type(members) ~= "table" or node == nil then return nil end
    for _, member in ipairs(members) do
        if type(member) == "table" and member.id == node then return true end
    end
    return false
end

return wire

-- The screen of a remote desktop as row deltas.
--
-- A viewport snapshot carries EVERY row whenever anything changed; over a
-- network that is a whole screen per keystroke. So the transport never hands
-- the window a snapshot: it hands a delta — the rows that differ from the
-- previous delta it produced — and the window applies it to its own copy.
-- A transport that runs on the producer's node computes the delta there and
-- ships only it; the window's side stays the same.
--
-- Pure: no IO, no runtime modules. Rows are the producer's styled strings,
-- opaque here; they are compared whole.
local frames = {}

-- blank(width, height) -> screen
--
-- The window's copy of the remote screen before the first delta arrives.
function frames.blank(width: integer, height: integer): any
    local rows = {}
    for y = 1, height do rows[y] = "" end
    return {revision = -1, width = width, height = height, rows = rows, cursor = nil}
end

-- delta(last, snapshot) -> delta, last
--
-- `last` is what the previous delta described (nil before the first one);
-- `snapshot` is a viewport snapshot `{revision, width, height, rows,
-- cursor?}`. The delta is `{revision, width, height, cursor, full, rows =
-- {[y] = row}, changed = n}`: `full` when there was nothing to compare with
-- or the size changed (every row is sent), otherwise only the rows that
-- differ. The returned `last` is the base for the next call.
function frames.delta(last: any, snapshot: any): (any, any)
    local width = math.tointeger(snapshot.width) or 0
    local height = math.tointeger(snapshot.height) or 0
    local source: any = snapshot.rows or {}
    local full = last == nil or last.width ~= width or last.height ~= height
    local rows = {}
    local copy = {}
    local changed = 0
    for y = 1, height do
        local row = source[y]
        if type(row) ~= "string" then row = "" end
        copy[y] = row
        if full or last.rows[y] ~= row then
            rows[y] = row
            changed = changed + 1
        end
    end
    local delta = {
        revision = snapshot.revision, width = width, height = height,
        cursor = snapshot.cursor, full = full, rows = rows, changed = changed,
    }
    return delta, {width = width, height = height, rows = copy}
end

-- apply(screen, delta) -> screen
--
-- Brings the window's copy up to the delta. A full delta replaces the size
-- and every row; a partial one only the rows it names.
function frames.apply(screen: any, delta: any): any
    if delta.full then
        local rows = {}
        for y = 1, delta.height do rows[y] = delta.rows[y] or "" end
        screen.rows = rows
        screen.width, screen.height = delta.width, delta.height
    else
        for y, row in pairs(delta.rows) do screen.rows[y] = row end
    end
    screen.revision = delta.revision
    screen.cursor = delta.cursor
    return screen
end

-- compose(screen, width, height, notice?) -> rows
--
-- The rows the window presents at its own size: the remote rows, blank
-- rows below them when the remote screen is shorter (the window has just
-- grown and the remote desktop has not redrawn yet), none past the window's
-- height. Columns are cut by the canvas the rows are placed on. A `notice`
-- (connecting, ended) takes the last row, reversed, so it cannot be
-- mistaken for the remote desktop's own status line.
function frames.compose(screen: any, width: integer, height: integer, notice: string?): {string}
    local rows: {string} = {}
    for y = 1, height do
        local row = screen.rows[y]
        rows[y] = type(row) == "string" and row or ""
    end
    if notice ~= nil and notice ~= "" and height > 0 then
        local text = " " .. notice
        if #text < width then text = text .. string.rep(" ", width - #text) end
        rows[height] = "\27[7m" .. text .. "\27[0m"
    end
    return rows
end

return frames

-- What the viewer forwards to the remote desktop, and how.
--
-- The local compositor takes some combinations before any window sees them
-- (the base's `handle_key`): Ctrl+Q (Shut Down), Alt+N, Alt+W, Alt+M, Alt+O
-- and Alt+Tab. A remote desktop needs the same combinations for ITS windows,
-- so the viewer offers them on combinations the local compositor lets
-- through — the way the Remote Desktop client of Windows maps Alt+Tab to
-- Alt+Page Up when "Windows key combinations apply to" is not "the remote
-- computer":
--
--   Alt+Page Up        → Alt+Tab        (the next window on the remote desktop)
--   Alt+Page Down      → Alt+Shift+Tab
--   Alt+Home           → Alt+O          (the remote Start menu)
--   Ctrl+Alt+End       → Ctrl+Q         (the remote Shut Down, as Ctrl+Alt+End is Ctrl+Alt+Del there)
--   Ctrl+Alt+N/W/M/O   → Alt+N/W/M/O    (the remote desktop's own accelerators)
--
-- That is the "remote" key mode, the default. The "local" mode forwards
-- every key as it arrives and maps nothing: the combinations above then do
-- nothing on either side. Every other key goes through unchanged in both.
--
-- Pure: tables in, tables out.
local input = require("input")

local inputs = {}

inputs.MODES = {remote = true, ["local"] = true}
inputs.DEFAULT_MODE = "remote"

-- The Ctrl+Alt+<letter> combinations that reach the remote desktop as
-- Alt+<letter>: exactly the letters the base's compositor takes on Alt.
local ALT_LETTERS = {n = true, w = true, m = true, o = true}

local function copy(event: any): any
    local out: any = {}
    for key, value in pairs(event) do out[key] = value end
    return out
end

local function key_event(from: any, key_type: string, key: string, mods: any): any
    return {
        type = "key", key_type = key_type, key = key,
        action = from.action == "release" and "release" or "press",
        alt = mods.alt == true, ctrl = mods.ctrl == true, shift = mods.shift == true,
    }
end

-- mode(value) -> "remote" | "local"
function inputs.mode(value: any): string
    if type(value) == "string" and inputs.MODES[value] then return value end
    return inputs.DEFAULT_MODE
end

-- key(event, mode) -> event
--
-- The key event to send to the remote desktop for a key the window got.
-- `event` is a tty key event (`key`, `key_type`, `action`, `alt`, `ctrl`,
-- `shift`); the answer is a new table the viewport accepts.
function inputs.key(event: any, mode: string): any
    local e = input.normalize(event)
    local out = copy(e)
    out.action = e.action == "release" and "release" or "press"
    out.key = tostring(e.key or e.key_type or "")
    out.key_type = tostring(e.key_type or "runes")
    if mode ~= "remote" then return out end
    local alt, ctrl, shift = e.alt == true, e.ctrl == true, e.shift == true
    if alt and not ctrl and e.key_type == "pgup" then
        return key_event(e, "tab", "tab", {alt = true, shift = shift})
    elseif alt and not ctrl and e.key_type == "pgdown" then
        return key_event(e, "tab", "tab", {alt = true, shift = true})
    elseif alt and not ctrl and e.key_type == "home" then
        return key_event(e, "runes", "o", {alt = true})
    elseif alt and ctrl and e.key_type == "end" then
        return key_event(e, "runes", "q", {ctrl = true})
    elseif alt and ctrl and e.key_type == "runes" then
        local letter = string.lower(tostring(e.key or ""))
        if ALT_LETTERS[letter] then
            return key_event(e, "runes", letter, {alt = true, shift = shift})
        end
    end
    return out
end

-- mouse(event, width, height) -> event
--
-- The mouse event to send. The remote screen is the window's whole client
-- area, so the coordinates stay; only a drag captured outside the client
-- (the compositor keeps sending motion and the release there) is pinned to
-- the edge, because the viewport accepts positive coordinates only.
function inputs.mouse(event: any, width: integer, height: integer): any
    local out = copy(event)
    local x = math.tointeger(event.x) or 1
    local y = math.tointeger(event.y) or 1
    if x < 1 then x = 1 elseif width > 0 and x > width then x = width end
    if y < 1 then y = 1 elseif height > 0 and y > height then y = height end
    out.x, out.y = x, y
    out.time = nil
    return out
end

return inputs

-- A tty producer that does not act on CANCEL: the served desktop that only
-- a terminate ends. Reports its pid like app:echo.
local tty = require("tty")
local process = require("process")

local function main()
    local watcher = process.registry.lookup("rdesktop.test.echoes")
    if watcher then process.send(tostring(watcher), "echo.started", tostring(process.pid())) end
    local events = assert(tty.events())
    assert(tty.start())
    local surface = assert(tty.surface({}))
    local width, height = tty.screen_size()
    local rows = {}
    for y = 1, height do rows[y] = "" end
    rows[1] = "stubborn " .. tostring(width) .. "x" .. tostring(height)
    surface:present(rows, {})
    while true do
        local _, ok = events:receive()
        if not ok then break end
    end
end

return {main = main}

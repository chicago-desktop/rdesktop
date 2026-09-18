-- A tty producer for loopback_test: row 1 is its size, row 2 the last input.
local tty = require("tty")
local process = require("process")
local channel = require("channel")

local function main()
    -- A test that wants to know this producer's pid registers the name.
    local watcher = process.registry.lookup("rdesktop.test.echoes")
    if watcher then process.send(tostring(watcher), "echo.started", tostring(process.pid())) end
    local events = assert(tty.events())
    assert(tty.start())
    local surface = assert(tty.surface({}))
    local lifecycle = process.events()
    local state: any = {last = "none"}
    state.width, state.height = tty.screen_size()

    local function draw()
        local rows = {}
        for y = 1, state.height do rows[y] = "" end
        rows[1] = "ready " .. tostring(state.width) .. "x" .. tostring(state.height)
        if state.height > 1 then rows[2] = "got " .. state.last end
        surface:present(rows, {cursor = {x = 1, y = 1, visible = false}})
    end

    draw()
    while true do
        local picked = channel.select({events:case_receive(), lifecycle:case_receive()})
        if not picked.ok or picked.channel == lifecycle then break end
        local event: any = picked.value
        if event.type == "close" then break end
        if event.type == "resize" then
            state.width, state.height = tty.screen_size()
            draw()
        elseif event.type == "key" and event.action ~= "release" then
            state.last = (event.ctrl and "ctrl+" or "") .. (event.alt and "alt+" or "")
                .. (event.shift and "shift+" or "") .. tostring(event.key)
            draw()
        elseif event.type == "mouse" then
            state.last = "mouse " .. tostring(event.action) .. " " .. tostring(event.x) .. "," .. tostring(event.y)
            draw()
        end
    end
    surface:close()
    tty.stop()
end

return {main = main}

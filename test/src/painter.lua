-- A tty producer that puts a picture on its screen, for the picture wire:
-- row 1 says what it last did; "x" changes only the text, "m" moves the same
-- picture, "n" replaces it with a new one (a new serial). Reports its pid
-- like app:echo.
local tty = require("tty")
local gfx = require("gfx")
local process = require("process")
local channel = require("channel")

local function main()
    local events = assert(tty.events())
    assert(tty.start())
    local surface = assert(tty.surface({}))
    local lifecycle = process.events()
    local state: any = {last = "start", x = 2}
    state.raster = gfx.raster(16, 40)
    state.raster:fill("#ff0000")
    state.width, state.height = tty.screen_size()

    local function draw()
        local rows = {}
        for y = 1, state.height do rows[y] = "" end
        rows[1] = "painter " .. state.last
        surface:present(rows, {images = {{id = "pic", x = state.x, y = 2, cols = 2, rows = 2, raster = state.raster}}})
    end

    draw()
    while true do
        local picked = channel.select({events:case_receive(), lifecycle:case_receive()})
        if not picked.ok or picked.channel == lifecycle then break end
        local event: any = picked.value
        if event.type == "close" then break end
        if event.type == "key" and event.action ~= "release" then
            if event.key == "m" then
                state.x = state.x + 1
            elseif event.key == "n" then
                state.raster = gfx.raster(16, 40)
                state.raster:fill("#0000ff")
            end
            state.last = tostring(event.key)
            draw()
        end
    end
    surface:close()
    tty.stop()
end

return {main = main}

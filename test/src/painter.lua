-- A tty producer that puts a picture on its screen, for the picture wire:
-- row 1 says what it last did; "x" changes only the text, "m" moves the same
-- picture, "n" replaces it with a new one (a new serial). Row 2 says what
-- its gfx hears of the terminal: "gfx <protocol> <w>x<h>", the viewer's
-- protocol and grid when the serving side told the viewport so.
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
    local protocol = gfx.supported()
    local cell_w, cell_h = gfx.cell_size()
    state.heard = "gfx " .. tostring(protocol) .. " " .. tostring(cell_w) .. "x" .. tostring(cell_h)

    local function draw()
        local rows = {}
        for y = 1, state.height do rows[y] = "" end
        rows[1] = "painter " .. state.last
        if state.height > 1 then rows[2] = state.heard end
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

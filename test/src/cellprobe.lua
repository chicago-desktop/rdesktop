-- A producer that reports what it hears about its terminal, before and
-- after it starts its tty: the graphics protocol and the cell size.
local tty = require("tty")
local gfx = require("gfx")
local process = require("process")
local function say(v: any, e: any): string return tostring(v) .. "/" .. tostring(e) end
local function main(parent: string)
    local p1, r1 = gfx.supported()
    local w1, h1 = gfx.cell_size()
    local events = tty.events()
    tty.start()
    local p2, r2 = gfx.supported()
    local w2, h2 = gfx.cell_size()
    process.send(parent, "cellprobe", "before=" .. say(p1, r1) .. " " .. say(w1, h1) .. " | after=" .. say(p2, r2) .. " " .. say(w2, h2))
    tty.stop()
end
return {main = main}

-- Renders a window's tree in ANOTHER process, the way the compositor gets it:
-- the tree arrives in a message (as desktop.publish_state carries it), is
-- checked by ui.problem, searched for userdata, drawn by the shell's renderer
-- here and written to test/shots/<name>.png. What reaches this process is
-- the only honest evidence: a tree rendered where it was built draws
-- perfectly even when half of it cannot cross a process boundary.
local process = require("process")
local fs = require("fs")
local gfx = require("gfx")
local ui = require("ui")
local render = require("render")
local rasters = require("rasters")

local function userdata_in(value: any, where: string): string?
    local kind = type(value)
    if kind == "userdata" or kind == "function" or kind == "thread" then return where .. " is " .. kind end
    if kind == "table" then
        for key, item in pairs(value) do
            local found = userdata_in(item, where .. "." .. tostring(key))
            if found then return found end
        end
    end
    return nil
end

local function count_png(value: any): integer
    local n = 0
    if type(value) ~= "table" then return 0 end
    if type(value.images) == "table" then
        for _, image in ipairs(value.images) do
            if type(image) == "table" and type(image.png) == "string" and #image.png > 0 then n = n + 1 end
        end
    end
    for _, child in ipairs(type(value.children) == "table" and value.children or {}) do n = n + count_png(child) end
    return n
end

local function main(parent: string)
    local inbox = process.listen("render.tree")
    local job: any = inbox:receive()
    local report: any = {userdata = userdata_in(job.tree, "tree"), problem = ui.problem(job.tree),
        pictures = count_png(job.tree)}
    local files = assert(fs.get("app:system_fonts"))
    local fonts = {
        face = gfx.font(assert(files:readfile("LiberationSans-Regular.ttf")), {size = 13, smooth = true}),
        mono = gfx.font(assert(files:readfile("LiberationMono-Regular.ttf")), {size = 13, smooth = true}),
    }
    local store = rasters.store()
    store.begin()
    local placed, why = render.placement({id = tostring(job.name), state_revision = 1, content_state = {sdk = 1,
        revision = 1, ui = job.tree, interaction = job.interaction}},
        {x = 1, y = 1, cols = job.cols, rows = job.rows}, {w = job.cell_w, h = job.cell_h}, fonts, store)
    if placed then
        local png = placed.raster:encode("png")
        assert(fs.get("app:shots")):writefile(tostring(job.name) .. ".png", tostring(png))
        report.drawn = true
    else
        report.why = tostring(why)
    end
    process.send(parent, "render.done", report)
end

return {main = main}

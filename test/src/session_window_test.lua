-- The session window as the SDK runs it, against this node's broker service:
-- the remote screen opened in MONO COLUMNS when there are pixels, its rows in
-- the terminal view, keys forwarded, and test/shots/session.png drawn by the
-- shell's own renderer — the evidence a text snapshot cannot give.
local test = require("test")
local channel = require("channel")
local time = require("time")
local fs = require("fs")
local gfx = require("gfx")
local app = require("app")
local ui = require("ui")
local render = require("render")
local rasters = require("rasters")
local session = require("session")

local definition = session.definition
local CLIENT = {w = 58, h = 20}
local CELL = {w = 10, h = 20}

local function font(file: string): any
    local files = assert(fs.get("app:system_fonts"))
    return assert(gfx.font(assert(files:readfile(file)), {size = 13, smooth = true}))
end

local function screen_has(model: any, pattern: string): boolean
    for _, row in ipairs(model.screen.rows) do
        if string.find(row, pattern, 1, true) then return true end
    end
    return false
end

-- pump(model, ctx, accept, seconds) — what app.run does with the watched
-- channels, until `accept(model)` holds.
local function pump(model: any, ctx: any, accept: any, seconds: integer): boolean
    local deadline = time.after(tostring(seconds) .. "s")
    while not accept(model) do
        local live: any = model.session
        if live == nil then return false end
        local picked = channel.select({deadline:case_receive(), live:updates():case_receive(),
            live:ended():case_receive()})
        if picked.channel == deadline then return false end
        app.dispatch(definition, model, ctx, {type = "channel", channel = picked.channel, value = picked.value, ok = picked.ok})
    end
    return true
end

local function define_tests()
    test.describe("the session window", function()
        test.it("measures the remote screen in mono columns with pixels, in cells without", function()
            local pixels = app.context({width = 58, height = 20, native = true, cell_w = 10, cell_h = 20})
            local columns, rows = session.geometry(pixels)
            test.eq(columns .. "x" .. rows, "72x20", "58 cells of 10 px hold 72 glyphs of " .. tostring(ui.MONO_PX))
            local cells = app.context({width = 58, height = 20})
            columns, rows = session.geometry(cells)
            test.eq(columns .. "x" .. rows, "58x20")
            test.is_nil(session.graphics(cells))
            test.eq(session.graphics(pixels).cell_w, ui.MONO_PX)
        end)

        test.it("opens the remote desktop at that size, drives it, and is drawn: test/shots/session.png", function()
            local ctx = app.context({width = CLIENT.w, height = CLIENT.h, native = true, cell_w = CELL.w, cell_h = CELL.h})
            local model = definition.init('{"name":"this one"}', ctx)
            test.eq(tostring(definition.title(model)), "this one - Remote Desktop")
            app.dispatch(definition, model, ctx, {type = "timer", tag = "dial"})
            test.not_nil(model.session, "the session opened")
            test.is_true(pump(model, ctx, function(m: any) return screen_has(m, "Start") end, 25),
                "the remote desktop:\n" .. table.concat(model.screen.rows, "\n"))
            test.eq(model.screen.width, 72, "the remote side laid itself out on the mono grid")

            -- A key through update: Alt+Home is the remote Start menu.
            app.dispatch(definition, model, ctx, {type = "key", key = "home", key_type = "home", alt = true})
            test.is_true(pump(model, ctx, function(m: any) return screen_has(m, "Programs") end, 10),
                "the remote Start menu:\n" .. table.concat(model.screen.rows, "\n"))

            local tree = definition.view(model, ctx)
            test.is_nil(ui.problem(tree))
            local store = rasters.store()
            store.begin()
            local placed = assert(render.placement({id = "session", state_revision = 1, content_state = {sdk = 1, revision = 1,
                ui = tree, interaction = ctx.interaction}}, {x = 1, y = 1, cols = ctx.width, rows = ctx.height},
                CELL, {face = font("LiberationSans-Regular.ttf"), mono = font("LiberationMono-Regular.ttf")}, store))
            assert(assert(fs.get("app:shots")):writefile("session.png", assert(placed.raster:encode("png"))))

            -- A resize goes to the remote side in mono columns too.
            ctx.width = 48
            app.dispatch(definition, model, ctx, {type = "resize", width = 48, height = CLIENT.h})
            test.is_true(pump(model, ctx, function(m: any) return m.screen.width == 60 end, 10),
                "48 cells of 10 px are 60 mono columns; the screen is " .. tostring(model.screen.width))
            definition.dispose(model, ctx)
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return {run = function(options) return run_cases(options) end}

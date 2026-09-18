-- "Remote Desktop Connection" as the SDK runs it: init, update through
-- app.dispatch, the session window it opens, and the window drawn by the
-- shell's own pixel renderer into test/shots/connect.png — the evidence a
-- text snapshot cannot give (it read the same for cell-drawn buttons).
local test = require("test")
local process = require("process")
local channel = require("channel")
local time = require("time")
local json = require("json")
local fs = require("fs")
local gfx = require("gfx")
local app = require("app")
local ui = require("ui")
local render = require("render")
local rasters = require("rasters")
local window = require("window")

local definition = window.definition
local DESKTOP = "chicago.tui_desktop.desktop"
local CLIENT = {w = 58, h = 15}
local CELL = {w = 10, h = 20}

-- A stand-in desktop: this process under the base's default desktop name,
-- catching `desktop.open`.
local function stand_in(): any
    process.registry.register(DESKTOP)
    return process.listen("desktop.open")
end

local function done(opens: any)
    process.unlisten(opens)
    process.registry.unregister(DESKTOP)
end

local function next_open(opens: any): any
    local picked = channel.select({opens:case_receive(), time.after("3s"):case_receive()})
    if picked.channel ~= opens then return nil end
    return picked.value
end

local function context(pixels: boolean?): any
    return app.context({width = CLIENT.w, height = CLIENT.h, native = pixels == true,
        cell_w = CELL.w, cell_h = CELL.h})
end

local function face_font(): any
    local files = assert(fs.get("app:system_fonts"))
    return assert(gfx.font(assert(files:readfile("LiberationSans-Regular.ttf")), {size = 13, smooth = true}))
end

local function define_tests()
    test.describe("Remote Desktop Connection", function()
        test.it("opens the session window for the chosen computer and goes", function()
            local opens = stand_in()
            local ctx = context()
            local model = definition.init("", ctx)
            test.is_false(ctx.closing, "no args: the screen stays")
            local chosen = model.selected
            app.dispatch(definition, model, ctx, {type = "activate", id = "connect"})
            local asked: any = next_open(opens)
            done(opens)
            test.not_nil(asked, "desktop.open was sent")
            test.eq(asked.entry, "chicago.rdesktop:session")
            local args: any = json.decode(tostring(asked.args))
            test.eq(args.computer, chosen)
            test.not_nil(string.find(tostring(asked.title), " - Remote Desktop", 1, true), tostring(asked.title))
            test.is_true(ctx.closing, "the connection window gives way to the session")
        end)

        test.it("closes on Cancel and Esc, opening nothing", function()
            local opens = stand_in()
            local ctx = context()
            local model = definition.init("", ctx)
            app.dispatch(definition, model, ctx, {type = "activate", id = "cancel"})
            test.is_true(ctx.closing)
            local esc = context()
            app.dispatch(definition, definition.init("", esc), esc, {type = "key", key_type = "esc", key = "esc"})
            test.is_true(esc.closing)
            test.is_nil(next_open(opens), "nothing opened")
            done(opens)
        end)

        test.it("comes back with the reason and the computer still selected", function()
            local ctx = context()
            local first = definition.init("", ctx)
            local own = first.selected
            local model = definition.init(json.encode({notice = "The remote desktop ended.", selected = own}), ctx)
            test.eq(model.notice, "The remote desktop ended.")
            test.eq(model.selected, own)
            test.is_false(ctx.closing)
        end)

        test.it("connects at once for a computer in its args", function()
            local opens = stand_in()
            local ctx = context()
            definition.init(json.encode({computer = "node-b"}), ctx)
            local asked: any = next_open(opens)
            done(opens)
            test.not_nil(asked)
            test.eq(json.decode(tostring(asked.args)).computer, "node-b")
            test.is_true(ctx.closing)
        end)

        test.it("is drawn by the shell's renderer with real dialog buttons: test/shots/connect.png", function()
            local ctx = context(true)
            local model = definition.init(json.encode({notice = "The computer is not accessible. Remote Desktop is not enabled on node-b."}), ctx)
            local tree = definition.view(model, ctx)
            test.is_nil(ui.problem(tree))
            local store = rasters.store()
            store.begin()
            local placed = assert(render.placement({id = "connect", state_revision = 1, content_state = {sdk = 1, revision = 1,
                ui = tree, interaction = ctx.interaction}}, {x = 1, y = 1, cols = ctx.width, rows = ctx.height},
                CELL, {face = face_font()}, store))
            assert(assert(fs.get("app:shots")):writefile("connect.png", assert(placed.raster:encode("png"))))
            test.eq(placed.cols .. "x" .. placed.rows, tostring(ctx.width) .. "x" .. tostring(ctx.height))
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return {run = function(options) return run_cases(options) end}

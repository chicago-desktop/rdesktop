-- The sample window as data: the initial tree, the click count, Exit, About,
-- the layout in cells, and a shot (test/shots/hello.png) drawn by the shell's
-- own renderer — evidence for the eye, next to the checks for the machine.
--
-- Every test file ends with `test.run_cases(define_tests)`. A file that puts
-- `test.describe` inside a `run` function and returns it is counted, printed
-- green in under a millisecond, and never executed: break a test on purpose
-- once and see it go red before trusting it.
local test = require("test")
local gfx = require("gfx")
local fs = require("fs")
local ui = require("ui")
local app = require("app")
local render = require("render")
local rasters = require("rasters")
local view = require("view")

local PACK = view.PACK
-- The client size the tests lay the window out in (the entry's outer size
-- minus the frame), and the cell of the stand this was measured on.
local CLIENT = {w = 40, h = 11}
local CELL = {w = 10, h = 20}

-- A fresh model and a context of the client size; `pixels` picks the
-- renderer the plan rounds for.
local function open(pixels: boolean?): (any, any)
    local model = view.init("")
    local context = app.context({width = CLIENT.w, height = CLIENT.h, native = pixels == true,
        cell_w = CELL.w, cell_h = CELL.h})
    return model, context
end

-- Every node of a tree with an `id`, by id.
local function nodes(tree: any, out: any?): any
    local found: any = out or {}
    if type(tree) ~= "table" then return found end
    if tree.id then found[tree.id] = tree end
    for _, item in ipairs(tree.children or {}) do nodes(item, found) end
    return found
end

local function status(model: any, context: any): string
    local tree = view.tree(model, context)
    return tostring(tree.children[#tree.children].fields[1].text)
end

local function click(model: any, context: any, id: string): boolean
    return view.update(model, {type = "activate", id = id}, context)
end

local function face_font(): any
    local files = assert(fs.get("app:system_fonts"))
    return assert(gfx.font(assert(files:readfile("LiberationSans-Regular.ttf")), {size = 13, smooth = true}))
end

local LEAVES: any = {button = true, field = true, statusbar = true, label = true}

-- The first pair of laid out controls that overlap or leave the client.
local function clash(plan: any, width: integer, height: integer): string
    local items: any = {}
    for _, item in ipairs(plan.items) do
        if LEAVES[item.node.kind] and item.rect.w > 0 and item.rect.h > 0 then items[#items + 1] = item end
    end
    for index, a in ipairs(items) do
        local r = a.rect
        if r.x < 1 or r.y < 1 or r.x + r.w > width + 1 or r.y + r.h > height + 1 then
            return tostring(a.node.id or a.node.kind) .. " leaves the client"
        end
        for other = index + 1, #items do
            local s = items[other].rect
            if r.x < s.x + s.w and s.x < r.x + r.w and r.y < s.y + s.h and s.y < r.y + r.h then
                return tostring(a.node.id or a.node.kind) .. " overlaps " .. tostring(items[other].node.id or items[other].node.kind)
            end
        end
    end
    return "none"
end

local function define_tests()
    test.describe("Hello window view", function()
        test.it("starts with the menu, the greeting, the button, no clicks and a ready status", function()
            local model, context = open(false)
            local tree = view.tree(model, context)
            test.is_nil(ui.problem(tree), "the tree lays out")
            local found = nodes(tree)
            test.eq(found.bar.kind, "menu")
            test.eq(found.bar.entries[1].title .. "|" .. found.bar.entries[2].title, "File|Help")
            test.eq(found.bar.entries[1].items[1].id .. "|" .. found.bar.entries[2].items[1].id, "exit|about")
            test.eq(found.count.text, "Click me")
            test.is_true(found.count.default, "Enter presses the button")
            test.eq(found.counted.text, "Not clicked yet.")
            test.eq(status(model, context), "Ready")
            test.is_false(model.about)
        end)

        test.it("counts the clicks on the button and shows the count in the text and the status bar", function()
            local model, context = open(false)
            test.is_true(click(model, context, "count"), "a click redraws")
            test.eq(model.clicks, 1)
            test.eq(nodes(view.tree(model, context)).counted.text, "Clicked once.")
            test.eq(status(model, context), "1 click")
            click(model, context, "count")
            click(model, context, "count")
            test.eq(model.clicks, 3)
            test.eq(nodes(view.tree(model, context)).counted.text, "Clicked 3 times.")
            test.eq(status(model, context), "3 clicks")
            test.is_false(click(model, context, "elsewhere"), "an unknown control changes nothing")
            test.is_false(view.update(model, {type = "key", key_type = "runes", key = "x"}, context), "a stray key changes nothing")
            test.is_false(view.update(model, "not an action", context))
        end)

        test.it("File - Exit closes the window", function()
            local model, context = open(false)
            test.is_false(context.closing)
            test.is_true(view.update(model, {type = "activate", id = "exit", menu = "bar"}, context))
            test.is_true(context.closing, "the window asked the compositor to close it")
        end)

        test.it("Help - About opens the sheet; OK and Esc close it, the count stays", function()
            local model, context = open(false)
            click(model, context, "count")
            test.is_true(view.update(model, {type = "activate", id = "about", menu = "bar"}, context))
            test.is_true(model.about)
            local sheet = view.tree(model, context)
            test.is_nil(ui.problem(sheet), "the sheet lays out")
            test.is_nil(nodes(sheet).count, "the button is not on screen under the sheet")
            test.is_false(click(model, context, "count"), "so a click on it cannot count")
            test.is_true(click(model, context, "about_ok"))
            test.is_false(model.about, "OK closes the sheet")
            view.update(model, {type = "activate", id = "about", menu = "bar"}, context)
            test.is_true(view.update(model, {type = "key", key_type = "esc"}, context))
            test.is_false(model.about, "so does Esc")
            test.eq(model.clicks, 1, "the count survived the sheet")
            test.is_false(context.closing, "and the window is still open")
        end)

        test.it("lays out in the client without overlaps, in cells and in pixels", function()
            for _, pixels in ipairs({false, true}) do
                local model, context = open(pixels)
                local tree = view.tree(model, context)
                local plan = ui.plan(tree, CLIENT.w, CLIENT.h, context.interaction, pixels and {cell = CELL} or nil)
                local where = pixels and "in pixels" or "in cells"
                test.eq(clash(plan, CLIENT.w, CLIENT.h), "none", where)
                local button = plan.by_id.count.rect
                test.eq(button.w, 14, where .. ": the button's width is its size")
                test.eq(button.x, 2, where .. ": one cell of padding")
                local bar = plan.by_id.bar.rect
                test.eq(bar.y .. "|" .. bar.h, "1|1", where .. ": the menu bar on the first row")
                test.is_true(plan.by_id.counted.rect.y > button.y, where .. ": the count under the button")
            end
        end)

        test.it("draws the window after two clicks into test/shots/hello.png", function()
            local model, context = open(true)
            click(model, context, "count")
            click(model, context, "count")
            local tree = view.tree(model, context)
            test.is_nil(ui.problem(tree))
            local store = rasters.store()
            store.begin()
            local placed = assert(render.placement({id = "hello", state_revision = 1, content_state = {sdk = 1, revision = 1,
                ui = tree, interaction = context.interaction}}, {x = 1, y = 1, cols = context.width, rows = context.height},
                CELL, {face = face_font()}, store))
            assert(assert(fs.get("app:shots")):writefile("hello.png", assert(placed.raster:encode("png"))))
            test.eq(placed.cols .. "x" .. placed.rows, tostring(context.width) .. "x" .. tostring(context.height))
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return {run = function(options) return run_cases(options) end}

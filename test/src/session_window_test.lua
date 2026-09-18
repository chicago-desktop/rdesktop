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
local session = require("session")
local mesh = require("mesh")
local frames = require("frames")
local process = require("process")

local definition = session.definition
local CLIENT = {w = 58, h = 20}
local CELL = {w = 10, h = 20}

-- render_elsewhere(name, tree, ctx) -> report — the tree sent to ANOTHER
-- process, as desktop.publish_state sends it to the compositor, and drawn
-- there (app:render_probe) into test/shots/<name>.png. A tree drawn where it
-- was built proves nothing about what the compositor gets.
local function render_elsewhere(name: string, tree: any, ctx: any): any
    local done = process.listen("render.done")
    local probe = assert(process.spawn("app:render_probe", "app:processes", tostring(process.pid())))
    process.send(tostring(probe), "render.tree", {name = name, tree = tree, interaction = ctx.interaction,
        cols = ctx.width, rows = ctx.height, cell_w = CELL.w, cell_h = CELL.h})
    local picked = channel.select({done:case_receive(), time.after("15s"):case_receive()})
    process.unlisten(done)
    if picked.channel ~= done then return {drawn = false, why = "the render probe did not answer"} end
    local report: any = picked.value
    return report
end

-- A served desktop in pixels draws its chrome as pictures: the taskbar is
-- `bars`, an open menu `menu:<n>` (the shell's pixel theme's placement ids).
local function picture(model: any, prefix: string): any
    for _, image in ipairs(model.screen.images or {}) do
        if string.sub(tostring(image.id), 1, #prefix) == prefix then return image end
    end
    return nil
end

local function pictures_named(model: any): string
    local names = {}
    for _, image in ipairs(model.screen.images or {}) do names[#names + 1] = tostring(image.id) end
    return table.concat(names, ", ")
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

        test.it("draws the pictures that crossed the wire: test/shots/pictures.png", function()
            local name = "test.broker.window.pictures"
            assert(process.spawn("chicago.rdesktop:broker", "app:processes",
                {name = name, entry = "app:painter", host = "app:processes"}))
            local deadline = time.after("5s")
            while process.registry.lookup(name) == nil do
                local picked = channel.select({deadline:case_receive(), time.after("50ms"):case_receive()})
                if picked.channel == deadline then error("the broker did not take " .. name) end
            end
            local ctx = app.context({width = 20, height = 5, native = true, cell_w = 10, cell_h = 20})
            local columns, rows = session.geometry(ctx)
            local live = assert(mesh.open({broker = name, width = columns, height = rows, graphics = session.graphics(ctx)}))
            local model: any = {screen = frames.blank(columns, rows), notice = nil}
            local until_ = time.after("10s")
            while model.screen.images == nil or #model.screen.images == 0 do
                local picked = channel.select({until_:case_receive(), live:updates():case_receive()})
                if picked.channel == until_ then break end
                local delta = live:snapshot(model.screen.revision)
                if delta then frames.apply(model.screen, delta) end
            end
            test.eq(#(model.screen.images or {}), 1, "the painter's picture arrived")
            local tree = session.tree(model, ctx)
            test.eq(#tree.children[1].images, 1, "and is handed to the terminal view")
            local report = render_elsewhere("pictures", tree, ctx)
            test.is_nil(report.userdata, "nothing that cannot cross to the compositor")
            test.is_nil(report.problem)
            test.eq(report.pictures, 1, "the picture's bytes reached the other process")
            test.is_true(report.drawn, tostring(report.why))
            live:close()
        end)

        test.it("forwards pastes, and a pointer only with the view's own column and row", function()
            local ctx = app.context({width = 30, height = 10, native = true, cell_w = 10, cell_h = 20})
            local model = definition.init("", ctx)
            local sent: any = {}
            model.session = {send = function(_, event: any) sent[#sent + 1] = event; return true end}
            app.dispatch(definition, model, ctx, {type = "paste", text = "hello"})
            app.dispatch(definition, model, ctx, {type = "mouse", action = "press", button = "left", x = 3, y = 2})
            app.dispatch(definition, model, ctx, {type = "mouse", action = "press", button = "left", x = 3, y = 2,
                column = 4, row = 2})
            test.eq(#sent, 2, "the pointer without the view's column is not guessed at")
            test.eq(sent[1].type .. ":" .. tostring(sent[1].text), "paste:hello")
            test.eq(sent[2].x .. "," .. sent[2].y, "4,2", "the column of that screen, not the cell")
        end)

        test.it("opens the remote desktop in pixels at that size, drives it, and is drawn: test/shots/session.png", function()
            local ctx = app.context({width = CLIENT.w, height = CLIENT.h, native = true, cell_w = CELL.w, cell_h = CELL.h})
            local model = definition.init('{"name":"this one"}', ctx)
            test.eq(tostring(definition.title(model)), "this one - Remote Desktop")
            app.dispatch(definition, model, ctx, {type = "timer", tag = "dial"})
            test.not_nil(model.session, "the session opened")
            -- The served desktop comes up IN PIXELS: it was told, before it
            -- started, that it has graphics on our grid, and its chrome
            -- arrives as pictures — the taskbar among them.
            test.is_true(pump(model, ctx, function(m: any) return picture(m, "bars") ~= nil end, 25),
                "the remote taskbar as a picture; pictures: " .. pictures_named(model))
            test.eq(model.screen.width, 72, "the remote side laid itself out on the mono grid")
            local taskbar: any = picture(model, "bars")
            test.eq(tostring(taskbar.cols) .. "x" .. tostring(taskbar.rows), "72x2", "the taskbar spans the screen")
            test.eq(type(taskbar.png), "string", "its pixels arrived, as PNG bytes")
            test.is_true(model.session:picture_bytes() > 0)

            -- A click on the remote Start button, mapped by the SDK itself
            -- (ui.terminal_at): the client cell (4, last row) is a column of
            -- the mono grid, not a cell.
            local plan = ui.plan(definition.view(model, ctx), ctx.width, ctx.height, ctx.interaction,
                {cell = ctx.cell, scroll_cols = ctx.scroll_cols})
            local item, column, row = ui.terminal_at(plan, 4, CLIENT.h)
            test.not_nil(item, "the pointer stands on the view")
            test.eq(tostring(column) .. "," .. tostring(row), "5," .. tostring(CLIENT.h), "the middle of cell 4 is mono column 5")
            for _, phase in ipairs({"press", "release"}) do
                app.dispatch(definition, model, ctx, {type = "mouse", action = phase, button = "left",
                    x = 4, y = CLIENT.h, column = column, row = row})
            end
            test.is_true(pump(model, ctx, function(m: any) return picture(m, "menu:") ~= nil end, 10),
                "a click opened the remote Start menu; pictures: " .. pictures_named(model))
            app.dispatch(definition, model, ctx, {type = "key", key = "esc", key_type = "esc"})
            test.is_true(pump(model, ctx, function(m: any) return picture(m, "menu:") == nil end, 10), "Esc closed it")

            -- A key through update: Alt+Home is the remote Start menu.
            app.dispatch(definition, model, ctx, {type = "key", key = "home", key_type = "home", alt = true})
            test.is_true(pump(model, ctx, function(m: any) return picture(m, "menu:") ~= nil end, 10),
                "the remote Start menu; pictures: " .. pictures_named(model))

            -- The window's tree, as the compositor gets it: sent to another
            -- process and drawn there.
            local tree = definition.view(model, ctx)
            test.is_nil(ui.problem(tree))
            local report = render_elsewhere("session", tree, ctx)
            test.is_nil(report.userdata, "nothing that cannot cross to the compositor")
            test.is_nil(report.problem)
            test.is_true((math.tointeger(report.pictures) or 0) >= 2, "the taskbar and the menu reached the other process as bytes")
            test.is_true(report.drawn, tostring(report.why))

            -- A resize goes to the remote side in mono columns too.
            ctx.width = 48
            app.dispatch(definition, model, ctx, {type = "resize", width = 48, height = CLIENT.h})
            test.is_true(pump(model, ctx, function(m: any)
                local bar: any = picture(m, "bars")
                return m.screen.width == 60 and bar ~= nil and bar.cols == 60
            end, 10), "48 cells of 10 px are 60 mono columns, and the remote taskbar was laid out anew; the screen is "
                .. tostring(model.screen.width))
            definition.dispose(model, ctx)
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return {run = function(options) return run_cases(options) end}

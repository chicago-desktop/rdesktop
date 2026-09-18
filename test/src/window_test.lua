-- The two windows' registry entries and their args.
local test = require("test")
local registry = require("registry")
local window = require("window")
local session = require("session")

local function define_tests()
    test.describe("Remote Desktop Connection", function()
        test.it("is an SDK window drawn by the shell's renderer, in Programs/Accessories", function()
            local entry = assert(registry.get("chicago.rdesktop:window"))
            local meta: any = entry.meta
            test.eq(table.concat({meta.type, meta.title, meta.group, meta.image, meta.pixel_render, meta.pixel_state}, "|"),
                "tui_desktop.window|Remote Desktop|Programs/Accessories|dialup|chicago.shell.sdk:render|chicago.rdesktop:window")
            local data: any = entry.data
            test.eq(data.imports.app, "chicago.shell.sdk:app")
            test.eq(table.concat(data.security.policies, ","), "chicago.shell.security:view_state,chicago.rdesktop:viewing")
        end)

        test.it("reads its args: connect at once, or come back with a reason", function()
            test.is_nil(window.options(nil).computer, "no args shows the screen")
            test.eq(window.options('{"computer":"node-b"}').computer, "node-b")
            local back = window.options('{"notice":"The remote desktop ended.","selected":"node-b"}')
            test.eq(back.notice .. "|" .. back.selected, "The remote desktop ended.|node-b")
            test.is_nil(window.options("not json").computer)
        end)
    end)

    test.describe("the session window", function()
        test.it("is a cells window outside the menu, on the mesh transport", function()
            local entry = assert(registry.get("chicago.rdesktop:session"))
            local meta: any = entry.meta
            test.is_nil(meta.pixel_render, "a viewport snapshot has no rasters: the session draws in cells")
            test.is_false(meta.in_menu)
            local data: any = entry.data
            test.eq(data.imports.transport, "chicago.rdesktop:mesh")
            test.eq(table.concat(data.security.policies, ","), "chicago.rdesktop:viewing",
                "on the mesh the desktop runs under the serving broker, not the window")
        end)

        test.it("starts a fixed desktop and takes the computer, its name and the key mode from its args", function()
            test.eq(session.TARGET.entry, "chicago.shell:shell")
            test.eq(session.CONNECTION, "chicago.rdesktop:window")
            local given = session.options('{"computer":"node-b","name":"B","keys":"local","entry":"app:evil"}')
            test.eq(given.computer .. "|" .. given.name .. "|" .. given.keys, "node-b|B|local")
            test.is_nil(given.entry)
            test.eq(session.options(nil).keys, "remote")
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return {run = function(options) return run_cases(options) end}

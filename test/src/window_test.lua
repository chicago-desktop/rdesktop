-- The Remote Desktop window's registry entry and its args.
local test = require("test")
local registry = require("registry")
local window = require("window")

local function define_tests()
    test.describe("Remote Desktop window", function()
        test.it("is a cells window in Programs/Accessories", function()
            local entry = assert(registry.get("chicago.rdesktop:window"))
            local meta: any = entry.meta
            test.eq(table.concat({meta.type, meta.title, meta.group, meta.image}, "|"),
                "tui_desktop.window|Remote Desktop|Programs/Accessories|dialup")
            test.is_nil(meta.pixel_render, "a viewport snapshot has no rasters: the window draws in cells")
            test.is_true(meta.resizable)
        end)

        test.it("reaches the remote desktop through the one transport import", function()
            local entry = assert(registry.get("chicago.rdesktop:window"))
            local data: any = entry.data
            test.eq(data.imports.transport, "chicago.rdesktop:loopback")
            local policies = table.concat(data.security.policies, ",")
            test.eq(policies, "chicago.rdesktop:session_spawn,chicago.shell.security:shell_runtime,chicago.shell.security:shell_env")
        end)

        test.it("starts a fixed desktop and takes only the key mode from its args", function()
            test.eq(window.TARGET.entry, "chicago.shell:shell")
            test.eq(window.TARGET.host, "chicago.tui_desktop:workers")
            test.eq(window.options(nil).keys, "remote")
            test.eq(window.options('{"keys":"local"}').keys, "local")
            test.eq(window.options('{"keys":"local","entry":"app:evil"}').entry, nil)
            test.eq(window.options("not json").keys, "remote")
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return {run = function(options) return run_cases(options) end}

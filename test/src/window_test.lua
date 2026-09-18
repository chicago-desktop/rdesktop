-- The sample window's process: the registry entry the Start menu reads, the
-- module's picture found by the shell, and the process running `view`.
local test = require("test")
local registry = require("registry")
local app = require("app")
local images = require("images")
local view = require("view")
local window = require("window")

local definition = window.definition

local function define_tests()
    test.describe("Hello window", function()
        test.it("is a window on the shell SDK in Programs, with the pack's picture at both sizes", function()
            local entry = assert(registry.get("chicago.rdesktop:window"))
            local meta: any = entry.meta
            test.eq(table.concat({meta.type, meta.title, meta.group, meta.image, meta.pixel_render, meta.pixel_state}, "|"),
                "tui_desktop.window|Hello Window|Programs/Remote Desktop|chicago.rdesktop:images/hello|"
                    .. "chicago.shell.sdk:render|chicago.rdesktop:window")
            test.eq(view.PACK, "chicago.rdesktop:images/")
            for _, size in ipairs({32, 16}) do
                local picture, why = images.get(view.PACK .. "hello", size)
                test.not_nil(picture, "hello@" .. tostring(size) .. ": " .. tostring(why))
            end
            local missing, reason = images.get(view.PACK .. "nothing", 16)
            test.is_nil(missing)
            test.not_nil(reason, "a missing picture is refused with a reason, not drawn as nothing")
        end)

        test.it("runs the view: a fresh model, the view's tree, the view's answers, Esc closes", function()
            local context = app.context({width = 40, height = 11})
            local model = definition.init("", context)
            test.eq(model.clicks, 0)
            test.eq(definition.view(model, context).children[1].id, "bar", "the view's tree")
            test.is_true(definition.update(model, {type = "activate", id = "count"}, context))
            test.eq(model.clicks, 1)
            test.is_false(definition.update(model, {type = "key", key_type = "runes", key = "x"}, context))
            -- `app.dispatch` runs one action the way the loop does: an Esc that
            -- `update` did not take closes the window (`close_on_escape`).
            test.is_true(definition.close_on_escape)
            app.dispatch(definition, model, context, {type = "key", key_type = "esc"})
            test.is_true(context.closing, "Esc closes the window")
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return {run = function(options) return run_cases(options) end}

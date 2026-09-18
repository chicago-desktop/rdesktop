-- The module's "Did you know..." tip for the Welcome window: the entry the
-- window finds (a registry.entry of meta.type chicago.tip), its text, the
-- picture it names found in this module's pack at 32 px, and the window its
-- Show Me button opens. chicago/welcome is not in the harness and need not
-- be: a tip is plain registry data, and these are the checks the Welcome
-- window makes when it reads one.
local test = require("test")
local registry = require("registry")
local images = require("images")
local view = require("view")

local TIP = "chicago.rdesktop:tip"
local TIP_TYPE = "chicago.tip"
-- The namespace of this module's entries, `<namespace>:`.
local NS = TIP:match("^([^:]+:)")

local function tip_data(): any
    local entry: any = assert(registry.get(TIP))
    return type(entry.data) == "table" and entry.data or {}
end

local function define_tests()
    test.describe("Welcome tip", function()
        test.it("is a chicago.tip entry with an order, found by the Welcome window's own query", function()
            local entry: any = assert(registry.get(TIP))
            test.eq(entry.kind, "registry.entry")
            test.eq(entry.meta.type, TIP_TYPE)
            test.not_nil(tonumber(entry.meta.order), "an order places it among the other modules' tips")
            local found, err = registry.find({[".kind"] = "registry.entry", ["meta.type"] = TIP_TYPE})
            test.is_nil(err, tostring(err))
            local listed = false
            for _, raw in ipairs(found or {}) do
                local item: any = raw
                if item.id == TIP then listed = true end
            end
            test.is_true(listed, "the Welcome window's registry.find lists the tip")
        end)

        test.it("has a short paragraph of text", function()
            local data = tip_data()
            test.eq(type(data.text), "string", "a tip without text is skipped")
            local text = tostring(data.text):gsub("^%s+", ""):gsub("%s+$", "")
            test.is_true(#text > 0, "a tip of blanks is skipped")
            test.is_true(#text <= 300, "short enough for the Welcome panel, " .. tostring(#text) .. " characters")
        end)

        test.it("names a picture of this module's pack, drawn at 32 px", function()
            local image = tostring(tip_data().image)
            test.eq(image:sub(1, #view.PACK), view.PACK, "the picture is in the module's own pack")
            test.is_nil(image:find("/pictures/", 1, true), "a square pack picture, not an illustration")
            local icon, why = images.get(image, 32)
            test.not_nil(icon, image .. "@32: " .. tostring(why))
        end)

        test.it("Show Me opens a window of this module", function()
            local data = tip_data()
            local open = tostring(data.open)
            test.eq(open:sub(1, #NS), NS, "a window of this module")
            local target: any, err = registry.get(open)
            test.is_nil(err, open .. ": " .. tostring(err))
            test.eq(target and target.kind, "process.lua")
            test.eq(target and target.meta and target.meta.type, "tui_desktop.window", open .. " is a window")
            test.is_nil(data.args, "the sample opens as from the Start menu")
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return {run = function(options) return run_cases(options) end}

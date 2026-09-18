-- The key modes and the mouse pinning of the viewer.
local test = require("test")
local inputs = require("inputs")

local function key(key_type: string, key_name: string?, mods: any?): any
    local m: any = mods or {}
    return {type = "key", key_type = key_type, key = key_name or key_type, action = m.action or "press",
        alt = m.alt == true, ctrl = m.ctrl == true, shift = m.shift == true}
end

local function spell(event: any): string
    return (event.ctrl and "ctrl+" or "") .. (event.alt and "alt+" or "") .. (event.shift and "shift+" or "")
        .. tostring(event.key) .. "/" .. tostring(event.key_type) .. "/" .. tostring(event.action)
end

local function define_tests()
    test.describe("inputs.key in the remote mode", function()
        test.it("maps the combinations the local compositor takes", function()
            local cases = {
                {key("pgup", nil, {alt = true}), "alt+tab/tab/press"},
                {key("pgdown", nil, {alt = true}), "alt+shift+tab/tab/press"},
                {key("home", nil, {alt = true}), "alt+o/runes/press"},
                {key("end", nil, {alt = true, ctrl = true}), "ctrl+q/runes/press"},
                {key("runes", "w", {alt = true, ctrl = true}), "alt+w/runes/press"},
                {key("runes", "n", {alt = true, ctrl = true}), "alt+n/runes/press"},
                {key("runes", "m", {alt = true, ctrl = true}), "alt+m/runes/press"},
                {key("runes", "o", {alt = true, ctrl = true}), "alt+o/runes/press"},
            }
            for _, case in ipairs(cases) do
                test.eq(spell(inputs.key(case[1], "remote")), case[2])
            end
        end)

        test.it("maps a release to a release, so the remote desktop sees a whole keystroke", function()
            test.eq(spell(inputs.key(key("pgup", nil, {alt = true, action = "release"}), "remote")), "alt+tab/tab/release")
        end)

        test.it("leaves every other key as it came", function()
            test.eq(spell(inputs.key(key("runes", "x"), "remote")), "x/runes/press")
            test.eq(spell(inputs.key(key("runes", "x", {alt = true, ctrl = true}), "remote")), "ctrl+alt+x/runes/press")
            test.eq(spell(inputs.key(key("pgup"), "remote")), "pgup/pgup/press")
            test.eq(spell(inputs.key(key("esc"), "remote")), "esc/esc/press")
            test.eq(spell(inputs.key(key("tab", nil, {shift = true}), "remote")), "shift+tab/tab/press")
        end)

        test.it("normalizes the key names the base normalizes", function()
            test.eq(spell(inputs.key(key("page_up", nil, {alt = true}), "remote")), "alt+tab/tab/press")
        end)
    end)

    test.describe("inputs.key in the local mode", function()
        test.it("maps nothing", function()
            test.eq(spell(inputs.key(key("pgup", nil, {alt = true}), "local")), "alt+pgup/pgup/press")
            test.eq(spell(inputs.key(key("end", nil, {alt = true, ctrl = true}), "local")), "ctrl+alt+end/end/press")
        end)
    end)

    test.describe("inputs.mode", function()
        test.it("is remote unless local is asked for", function()
            test.eq(inputs.mode(nil), "remote")
            test.eq(inputs.mode("local"), "local")
            test.eq(inputs.mode("sideways"), "remote")
        end)
    end)

    test.describe("inputs.mouse", function()
        test.it("keeps a click inside and pins a captured drag to the edge", function()
            local inside = inputs.mouse({type = "mouse", action = "press", button = "left", x = 5, y = 3, time = 9}, 80, 24)
            test.eq(inside.x * 100 + inside.y, 503)
            test.is_nil(inside.time)
            local outside = inputs.mouse({type = "mouse", action = "motion", button = "left", x = -4, y = 40}, 80, 24)
            test.eq(outside.x, 1)
            test.eq(outside.y, 24)
            test.eq(outside.button, "left")
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return {run = function(options) return run_cases(options) end}

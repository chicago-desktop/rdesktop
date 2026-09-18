-- The sample window as data: the component tree for a model and what an
-- action does to that model. Pure — no clock, no files, no messages — so
-- the tests exercise it without a compositor (test/src/view_test.lua), and
-- the process in window.lua only runs it on the shell's SDK.
--
-- Replace this file with your own window. Keep the split: everything a test
-- should see lives here, the process stays a thin wrapper.
local ui = require("ui")

local view = {}

-- The module's own image pack, `<pack entry>/<file>` (src/_index.yaml,
-- entry `images`; the files are assets/images/{32,16}/hello.png).
view.PACK = "chicago.rdesktop:images/"
-- The picture for cells, where there is no pixel: one character.
view.ICON = "☺"

-- The menu bar: a list of titles, each with its rows. `accel` is the
-- 1-based letter of the title that Alt+letter opens. A row's `id` arrives
-- in `update` as `{type = "activate", id = ..., menu = "bar"}`.
view.MENU = {
    {title = "File", accel = 1, items = {
        {id = "exit", text = "Exit"},
    }},
    {title = "Help", accel = 1, items = {
        {id = "about", text = "About Hello Window"},
    }},
}

-- init(args) -> the model. `args` is what opened the window (a string from
-- the Start menu is empty); the sample ignores it.
function view.init(args: any): any
    return {clicks = 0, about = false}
end

-- counted(model) -> the line under the button.
function view.counted(model: any): string
    local n = math.tointeger(model.clicks) or 0
    if n == 0 then return "Not clicked yet." end
    if n == 1 then return "Clicked once." end
    return "Clicked " .. tostring(n) .. " times."
end

-- status(model) -> the status bar's text.
function view.status(model: any): string
    local n = math.tointeger(model.clicks) or 0
    if n == 0 then return "Ready" end
    return tostring(n) .. (n == 1 and " click" or " clicks")
end

-- tree(model, context) -> the window's component tree.
--
-- Plain tables only: no functions, no handles. Every interactive component
-- has a stable, unique `id`; the SDK keeps focus by it between frames. A
-- child's `size` is its extent along the parent's axis; without one it takes
-- the remaining space. The About sheet replaces the whole tree while it is up.
function view.tree(model: any, context: any): any
    if model.about then
        return ui.message({title = "Hello Window", image = view.PACK .. "hello", icon = view.ICON, ok = "about_ok",
            lines = {"A sample window on the shell SDK.", "Made from the Chicago module template."}})
    end
    return {kind = "column", children = {
        {kind = "menu", id = "bar", size = 1, entries = view.MENU},
        {kind = "column", padding = 1, gap = 1, children = {
            {kind = "label", size = 1, text = "Hello from the Chicago shell."},
            -- A button takes the middle row of its rectangle; two rows give
            -- the pixel renderer room for the Windows 95 button height.
            {kind = "row", size = 2, children = {
                {kind = "button", id = "count", size = 14, text = "Click me", default = true},
            }},
            {kind = "label", id = "counted", size = 1, text = view.counted(model)},
        }},
        {kind = "statusbar", size = 1, fields = {{text = view.status(model)}}},
    }}
end

-- update(model, action, context) -> redraw?
--
-- `false` means "nothing changed, do not draw". Actions the sample sees:
-- `activate` from the button and the menu rows, `key` for a key no component
-- took (Esc is handled by the process's `close_on_escape` once `update`
-- answered false). `context.close()` asks the compositor to close the window.
function view.update(model: any, action: any, context: any): boolean
    if type(action) ~= "table" then return false end
    if action.type == "activate" and action.id == "about_ok" then
        model.about = false
        return true
    end
    if model.about then
        -- Under the sheet only Esc does something; the window's controls
        -- are not on screen, so their actions cannot arrive.
        if action.type == "key" and action.key_type == "esc" then
            model.about = false
            return true
        end
        return false
    end
    if action.type == "activate" then
        local id = tostring(action.id or "")
        if id == "count" then
            model.clicks = (math.tointeger(model.clicks) or 0) + 1
            return true
        elseif id == "about" then
            model.about = true
            return true
        elseif id == "exit" then
            context.close()
            return true
        end
    end
    return false
end

return view

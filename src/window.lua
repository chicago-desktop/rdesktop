-- The sample window's process: the shell SDK's loop over the pure `view`.
--
-- `app.main(definition)` returns the `main` the registry entry names. The
-- compositor calls it in cells (a tty viewport) or in pixels (a state
-- provider for the shared renderer); the SDK hides the difference, the
-- window sees `init`, `view` and `update` either way.
local app = require("app")
local view = require("view")

local definition = {}

-- An Esc that `update` did not take (returned false) closes the window.
definition.close_on_escape = true

-- init(args, context) — once, when the window opens. `context` has the
-- client size (`width`, `height`), `native` (pixels or cells), `close()`,
-- `after(duration, tag)` for a one-shot timer and `watch(ch)` for a channel.
function definition.init(args: any, context: any): any
    return view.init(args)
end

-- view(model, context) — the tree for the current model; read no files and
-- send no messages here.
function definition.view(model: any, context: any): any
    local tree = view.tree(model, context)
    return tree
end

-- update(model, action, context) — one action; return false when nothing
-- changed so the SDK skips the redraw.
function definition.update(model: any, action: any, context: any): boolean
    local changed = view.update(model, action, context)
    return changed
end

return {main = app.main(definition), definition = definition}

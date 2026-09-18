-- Remote Desktop Connection — pick a computer of the network and connect.
--
-- An ordinary window on the shell's SDK (app.main): the screen is a plain
-- component tree (chicago.rdesktop:connect), drawn by the shell's shared
-- renderer in pixels and by the SDK in cells, like Calculator and Date/Time.
--
-- Connect opens the session window (chicago.rdesktop:session) for the
-- chosen computer and this window goes, as the Remote Desktop client's
-- dialog gives way to the session. The session window opens this one again
-- when a connection is refused or a session ends, with args
-- `{"notice": "<reason>", "selected": "<node id>"}`: the reason above the
-- buttons, the computer still selected.
--
-- `{"computer": "<node id>"}` in the args connects at once without showing
-- anything — how Network Neighborhood opens Remote Desktop for a node.
--
-- The logon is not this window's: the remote computer asks with its own
-- "Welcome to Chicago" inside the session.
local app = require("app")
local json = require("json")
local connect = require("connect")
local facts = require("facts")
local desktop = require("desktop")

-- What the screen reads of the runtime.
local FACTS = {"node_id", "node_role", "members", "hostname"}

-- The session window Connect opens.
local SESSION = "chicago.rdesktop:session"

-- options(args) -> {computer, notice, selected, keys}
local function options(args: any): any
    local decoded: any = nil
    if type(args) == "string" and args ~= "" then
        local value, err = json.decode(args)
        if err == nil and type(value) == "table" then decoded = value end
    end
    local function text(field: string): string?
        local value: any = decoded and decoded[field]
        if type(value) == "string" and value ~= "" then return value end
        return nil
    end
    return {computer = text("computer"), notice = text("notice"), selected = text("selected"), keys = text("keys")}
end

-- dial(model, context, id) — open the session window for a computer and go.
-- A refusal to open it stays here, on the screen.
local function dial(model: any, context: any, id: any)
    local name = connect.name_of(model, id)
    local opened, why = desktop.open({
        entry = SESSION,
        title = name .. " - Remote Desktop",
        args = tostring(json.encode({computer = id, name = name, keys = model.keys})),
    })
    if not opened then
        model.notice = "The session window did not open: " .. tostring(why)
        return
    end
    context.close()
end

local definition: any = {}

definition.title = "Remote Desktop Connection"

function definition.init(args: any, context: any): any
    local given = options(args)
    local model = connect.model(facts.read(FACTS), given.notice)
    model.keys = given.keys
    if given.selected then
        for _, row in ipairs(model.rows) do
            if row.id == given.selected then model.selected = given.selected end
        end
    end
    if given.computer then dial(model, context, given.computer) end
    return model
end

function definition.view(model: any, context: any): any
    local tree = connect.tree(model)
    return tree
end

function definition.update(model: any, action: any, context: any): boolean
    -- F5 reads the network again, as in Explorer.
    if action.type == "key" and action.key_type == "f5" then
        connect.refresh(model, facts.read(FACTS))
        return true
    end
    local result, changed = connect.update(model, action)
    if result and result.cancel then
        context.close()
        return false
    elseif result and result.connect then
        dial(model, context, result.connect)
        return true
    end
    return changed
end

return {main = app.main(definition), definition = definition, options = options, SESSION = SESSION, FACTS = FACTS}

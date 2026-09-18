-- The Remote Desktop Connection screen as data: the network from a
-- stand-in `system`, read through the shell's facts library as the window
-- reads it; the tree; what each action does.
local test = require("test")
local connect = require("connect")
local facts = require("facts")
local ui = require("ui")
local cells = require("cells")

local FACTS = {"node_id", "node_role", "members", "hostname"}
local OWN = "4a53358e-d8af-4e2b-9a55-0c1d2e3f4a5b"

-- A stand-in `system`: the sections and calls facts.read looks for.
local function stub(members: any, members_error: any?, role: string?): any
    return {
        node = {
            id = function() return OWN, nil end,
            role = function() return role or "voter", nil end,
        },
        cluster = {members = function()
            if members_error then return nil, members_error end
            return members, nil
        end},
        process = {hostname = function() return "zeta-9", nil end},
    }
end

local MESH = {
    {id = OWN, is_local = true, addr = "10.0.0.7:7946"},
    {id = "node-c", addr = "10.0.0.9:7946"},
    {id = "node-b", addr = "10.0.0.8:7946"},
}

local function names(rows: any): string
    local out = {}
    for _, row in ipairs(rows) do out[#out + 1] = row.name end
    return table.concat(out, ",")
end

-- find(tree, kind) -> the first child of that kind
local function find(tree: any, kind: string): any
    for _, child in ipairs(tree.children) do
        if child.kind == kind then return child end
    end
    return nil
end

-- the notice label, when there is one
local function notice(tree: any): any
    for _, child in ipairs(tree.children) do
        if child.kind == "label" and child.alert then return child.text end
    end
    return nil
end

-- Every string in a tree, for "is this word anywhere on the screen".
local function strings(node: any, out: any): any
    if type(node) == "string" then out[#out + 1] = node
    elseif type(node) == "table" then
        for _, value in pairs(node) do strings(value, out) end
    end
    return out
end

local function define_tests()
    test.describe("the computers of the network", function()
        test.it("come from the membership, this computer first and by its host name", function()
            local rows, status = connect.computers(facts.read(FACTS, stub(MESH)))
            test.eq(names(rows), "zeta-9,node-b,node-c", "this computer first even where the alphabet puts it last")
            test.is_true(rows[1].is_local)
            test.eq(rows[1].id, OWN, "connecting uses the node id, whatever the caption")
            test.eq(status, "3 computers on the network.")
        end)

        test.it("are only this computer, said plainly, when there is no cluster", function()
            local rows, status = connect.computers(facts.read(FACTS, stub({{id = OWN, is_local = true}}, nil, "non-member")))
            test.eq(#rows, 1)
            test.eq(status, "The network is off: this computer is not in a cluster.")
            local alone = select(2, connect.computers(facts.read(FACTS, stub({{id = OWN, is_local = true}}))))
            test.eq(alone, "No other computers are on the network.")
        end)

        test.it("keep this computer when the membership answers empty or its own id is unknown", function()
            local rows, status = connect.computers(facts.read(FACTS, stub({})))
            test.eq(#rows, 1, "this computer, from its node id")
            test.eq(rows[1].id, OWN)
            test.eq(status, "The network listed no computers just now; it is read again every few seconds.")
            local nameless = connect.computers({node_id = "", hostname = "zeta-9", members = {}, problems = {}})
            test.eq(#nameless, 1)
            test.eq(nameless[1].id, "", "an empty id dials this node")
            test.eq(nameless[1].name, "zeta-9")
            test.is_true(nameless[1].is_local)
        end)

        test.it("keep this computer and give the reason when the membership cannot be read", function()
            local rows, status = connect.computers(facts.read(FACTS, stub(nil, "no cluster information available")))
            test.eq(#rows, 1)
            test.eq(rows[1].id, OWN)
            test.eq(status, "cluster members: unavailable (no cluster information available)")
        end)
    end)

    test.describe("the screen", function()
        test.it("shows only what is known — no Status column, Address only when advertised", function()
            local model = connect.model(facts.read(FACTS, stub(MESH)))
            local titles = {}
            for _, column in ipairs(connect.columns(model)) do titles[#titles + 1] = column.title end
            test.eq(table.concat(titles, ","), "Computer,Address")
            local words = table.concat(strings(connect.tree(model), {}), "|")
            test.is_nil(string.find(words, "Online", 1, true), "no invented liveness")
            test.is_nil(string.find(words, "Status", 1, true))
            local bare = connect.model(facts.read(FACTS, stub({{id = OWN, is_local = true}, {id = "node-b"}})))
            test.eq(#connect.columns(bare), 1, "no Address column when nobody advertises one")
        end)

        test.it("lays out with the SDK: the list, the reason whole, Connect as default, Cancel, the status line", function()
            local long = "The computer is not accessible. Remote Desktop is not enabled on node-with-a-rather-long-name.example."
            local model = connect.model(facts.read(FACTS, stub(MESH)), long)
            local interaction = ui.interaction()
            local plan = ui.plan(connect.tree(model), 60, 14, interaction, {scroll_cols = 1})
            test.eq(interaction.focus, "computers", "the list has the focus: arrows and Enter work at once")
            local screen = table.concat(cells.rows(plan, interaction, 60, 14), "\n")
            screen = (string.gsub(screen, "\27%[[0-9;:]*[A-Za-z]", ""))
            local flat = (string.gsub(screen, "%s+", " "))
            for _, word in ipairs({"Choose the computer", "zeta-9 (this computer)", "node-b", "Connect", "Cancel",
                "3 computers on the network."}) do
                test.not_nil(string.find(screen, word, 1, true), word .. " on\n" .. screen)
            end
            test.not_nil(string.find(flat, "node-with-a-rather-long-name.example.", 1, true),
                "the reason is not cut:\n" .. screen)
            test.eq(model.selected, OWN, "this computer is selected first")

            -- Enter on the list, through the SDK's own event handling.
            local action = ui.event(plan, interaction, {type = "key", key = "enter", key_type = "enter", action = "press"})
            local result = connect.update(model, action)
            test.eq(result and result.connect, OWN)
        end)
    end)

    test.describe("the actions", function()
        test.it("connect on a double click, Enter and Connect; cancel on Cancel and Esc", function()
            local model = connect.model(facts.read(FACTS, stub(MESH)))
            local picked, changed = connect.update(model, {type = "select", id = "computers", index = 2,
                value = {id = "node-b"}, pointer = true})
            test.is_nil(picked, "a first click selects")
            test.is_true(changed)
            test.eq(model.selected, "node-b")
            picked = connect.update(model, {type = "select", id = "computers", index = 2, value = {id = "node-b"}, pointer = true})
            test.eq(picked.connect, "node-b", "a second click on the selected row is a double click")
            test.eq(connect.update(model, {type = "activate", id = "computers", index = 2}).connect, "node-b")
            test.eq(connect.update(model, {type = "activate", id = "connect"}).connect, "node-b")
            test.is_true(connect.update(model, {type = "activate", id = "cancel"}).cancel)
            test.is_true(connect.update(model, {type = "key", key_type = "esc"}).cancel)
            test.is_nil(connect.update(model, {type = "key", key_type = "runes", key = "x"}))
        end)

        test.it("keeps the reason until the person acts, and refuses Connect with nothing chosen", function()
            local model = connect.model(facts.read(FACTS, stub(MESH)), "The computer is not accessible.")
            test.eq(notice(connect.tree(model)), "The computer is not accessible.")
            test.eq(find(connect.tree(model), "statusbar").fields[1].text, "3 computers on the network.",
                "the network's state stays on the status line")
            connect.update(model, {type = "select", id = "computers", index = 1, value = {id = OWN}})
            test.is_nil(notice(connect.tree(model)), "gone once the person acts")
            -- The list always holds this computer; nothing selected is the
            -- only way to have nothing to connect to.
            local empty = connect.model({problems = {}})
            test.eq(#empty.rows, 1)
            empty.selected = nil
            test.is_true(find(connect.tree(empty), "row").children[1].disabled)
            test.is_nil(connect.update(empty, {type = "activate", id = "connect"}))
            test.eq(empty.notice, "Choose a computer first.")
        end)

        test.it("keeps the selection across a refresh while the computer is still there", function()
            local model = connect.model(facts.read(FACTS, stub(MESH)))
            model.selected = "node-c"
            connect.refresh(model, facts.read(FACTS, stub(MESH)))
            test.eq(model.selected, "node-c")
            connect.refresh(model, facts.read(FACTS, stub({{id = OWN, is_local = true}})))
            test.eq(model.selected, OWN, "a computer that left falls back to the first")
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return {run = function(options) return run_cases(options) end}

-- The Remote Desktop window run the way the compositor runs it after a
-- logon: in a viewport of its own, spawned under a person's actor and a
-- narrow scope. What it shows is what the person would see. The window is
-- on the mesh: it reaches this node's broker service, which serves the
-- desktop under its own identity.
local test = require("test")
local tty = require("tty")
local channel = require("channel")
local time = require("time")
local process = require("process")
local security = require("security")
local fs = require("fs")
local system = require("system")

-- wait_rows(view, accept, seconds) -> rows | nil, last rows
local function wait_rows(view: any, updates: any, accept: any, seconds: integer): (any, any)
    local deadline = time.after(tostring(seconds) .. "s")
    local last: any = {}
    while true do
        local snapshot: any = view:snapshot()
        last = snapshot.rows
        if accept(last) then return last, last end
        local picked = channel.select({deadline:case_receive(), updates:case_receive()})
        if picked.channel == deadline then return nil, last end
    end
end

local function has(pattern: string): any
    return function(rows: any)
        for _, row in ipairs(rows) do
            if string.find(row, pattern, 1, true) then return true end
        end
        return false
    end
end

local function text(rows: any): string
    local plain = {}
    for index, row in ipairs(rows or {}) do plain[index] = (string.gsub(tostring(row), "\27%[[0-9;:]*[A-Za-z]", "")) end
    return table.concat(plain, "\n")
end

-- open(args?) -> view, updates, pid — the window in a viewport of its own,
-- spawned under a person's actor and the narrow scope, as after a logon.
local function open(args: string?): (any, any, any)
    local view = assert(tty.viewport({width = 80, height = 24}))
    local updates = assert(view:updates())
    local narrow: any = assert(security.policy("app:narrow"))
    local scope = security.new_scope():with(narrow :: security.Policy)
    local actor = security.new_actor("rdesktop-test-person", {})
    local pid = assert(process.with_options({terminal = assert(view:grant())})
        :with_actor(actor):with_scope(scope)
        :spawn_monitored("chicago.rdesktop:window", "chicago.tui_desktop:workers", args))
    return view, updates, tostring(pid)
end

local function key(name: string, key_type: string?, mods: any?): any
    local m: any = mods or {}
    return {type = "key", key = name, key_type = key_type or name, action = "press",
        alt = m.alt == true, ctrl = m.ctrl == true, shift = false}
end

local function shot(name: string, rows: any)
    local shots = fs.get("app:shots")
    if shots then shots:writefile(name, text(rows) .. "\n") end
end

-- exits(pid, seconds) -> whether the process ended in time
local function exits_within(pid: string, seconds: integer): boolean
    local events = process.events()
    local deadline = time.after(tostring(seconds) .. "s")
    while true do
        local picked = channel.select({events:case_receive(), deadline:case_receive()})
        if picked.channel == deadline then return false end
        local event: any = picked.value
        if type(event) == "table" and event.kind == process.event.EXIT and tostring(event.from) == pid then return true end
    end
    return false
end

local function define_tests()
    test.describe("Remote Desktop under a logged-on person's narrow scope", function()
        test.it("opens on the connection screen, connects, and comes back to it when the desktop ends", function()
            local view, updates, pid = open(nil)
            local screen, seen = wait_rows(view, updates, has("(this computer)"), 15)
            shot("window-connect.txt", seen)
            test.not_nil(screen, "the connection screen:\n" .. text(seen))
            test.is_true(has("Connect")(seen), "a Connect button")
            test.is_false(has("Welcome")(seen), "no logon of ours: the remote computer asks for it")

            -- Enter on the list connects to the selected computer: this one.
            assert(view:send(key("enter")))
            local desk
            desk, seen = wait_rows(view, updates, has("Start"), 25)
            shot("window-session.txt", seen)
            test.not_nil(desk, "the remote desktop inside the window:\n" .. text(seen))

            -- Alt+Home through the window's key mode opens the remote Start menu.
            assert(view:send(key("home", "home", {alt = true})))
            local menu
            menu, seen = wait_rows(view, updates, has("Programs"), 10)
            test.not_nil(menu, "the remote Start menu:\n" .. text(seen))
            assert(view:send(key("esc")))

            -- Ctrl+Alt+End shuts the remote desktop down: the window is back
            -- on its connection screen with the reason, not dead.
            assert(view:send(key("end", "end", {ctrl = true, alt = true})))
            local back
            back, seen = wait_rows(view, updates, has("The remote desktop ended."), 20)
            shot("window-ended.txt", seen)
            test.not_nil(back, "back on the connection screen:\n" .. text(seen))
            test.is_true(has("(this computer)")(seen), "with the list to connect again")

            -- Esc there is Cancel: the window closes.
            assert(view:send(key("esc")))
            test.is_true(exits_within(pid, 10), "Cancel closes the window")
            view:close()
        end)

        test.it("connects at once to the computer in its args, skipping the screen", function()
            local own = assert(system.node.id())
            local view, updates, pid = open('{"computer":"' .. tostring(own) .. '"}')
            local desk, seen = wait_rows(view, updates, has("Start"), 25)
            test.not_nil(desk, "the remote desktop straight away:\n" .. text(seen))
            test.is_false(has("Choose the computer")(seen))
            assert(view:send({type = "close"}))
            test.is_true(exits_within(pid, 15), "the window exits on close")
            view:close()
        end)

        test.it("comes back to the screen with the reason when the computer refuses", function()
            local view, updates, pid = open('{"computer":"no-such-node"}')
            local screen, seen = wait_rows(view, updates, has("The computer is not accessible"), 15)
            shot("window-refused.txt", seen)
            test.not_nil(screen, "the refusal on the connection screen:\n" .. text(seen))
            test.is_true(has("no-such-node.")(seen), "the reason names the computer:\n" .. text(seen))
            test.is_false(has("Connecting to")(seen), "the attempt is over")
            test.is_true(has("Connect")(seen), "the screen, not a dead window")
            assert(view:send({type = "close"}))
            test.is_true(exits_within(pid, 10))
            view:close()
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return {run = function(options) return run_cases(options) end}

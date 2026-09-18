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
local json = require("json")

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

-- open(entry, args?) -> view, updates, pid — a window in a viewport of its
-- own, spawned under a person's actor and the narrow scope, as after a logon.
local function open(entry: string, args: string?): (any, any, any)
    local view = assert(tty.viewport({width = 80, height = 24}))
    local updates = assert(view:updates())
    local narrow: any = assert(security.policy("app:narrow"))
    local scope = security.new_scope():with(narrow :: security.Policy)
    local actor = security.new_actor("rdesktop-test-person", {})
    local pid = assert(process.with_options({terminal = assert(view:grant())})
        :with_actor(actor):with_scope(scope)
        :spawn_monitored(entry, "chicago.tui_desktop:workers", args))
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

-- exits_within(pid, seconds) -> whether the process ended in time
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

-- A stand-in desktop under the base's default name, catching desktop.open:
-- a window spawned here has no compositor in its context and asks that name.
local DESKTOP = "chicago.tui_desktop.desktop"

local function stand_in(): any
    process.registry.register(DESKTOP)
    return process.listen("desktop.open", {message = true})
end

local function done(opens: any)
    process.unlisten(opens)
    process.registry.unregister(DESKTOP)
end

-- next_open(opens, seconds, from) -> the spec a window asked to open
--
-- Only `from`'s: a window of an earlier case may still be finishing and
-- asking this same stand-in desktop.
local function next_open(opens: any, seconds: integer, from: string): any
    local deadline = time.after(tostring(seconds) .. "s")
    while true do
        local picked = channel.select({opens:case_receive(), deadline:case_receive()})
        if picked.channel ~= opens then return nil end
        local message: any = picked.value
        if tostring(message:from()) == from then
            local body: any = message:payload():data()
            return body
        end
    end
end

local function define_tests()
    test.describe("Remote Desktop under a logged-on person's narrow scope", function()
        test.it("shows the connection screen in cells and opens the session window on Enter", function()
            local opens = stand_in()
            local view, updates, pid = open("chicago.rdesktop:window", nil)
            local screen, seen = wait_rows(view, updates, has("(this computer)"), 15)
            shot("window-connect.txt", seen)
            test.not_nil(screen, "the connection screen:\n" .. text(seen))
            test.is_true(has("Connect")(seen), "a Connect button")
            assert(view:send(key("enter")))
            local asked: any = next_open(opens, 10, tostring(pid))
            done(opens)
            test.not_nil(asked, "the session window was asked for")
            test.eq(asked and asked.entry, "chicago.rdesktop:session")
            test.eq(json.decode(tostring(asked.args)).computer, tostring(system.node.id()))
            test.is_true(exits_within(pid, 10), "the connection window gives way")
            view:close()
        end)

        test.it("drives the remote desktop and hands back to the connection window when it ends", function()
            local own = tostring(system.node.id())
            local opens = stand_in()
            local view, updates, pid = open("chicago.rdesktop:session", json.encode({computer = own, name = "this one"}))
            local desk, seen = wait_rows(view, updates, has("Start"), 25)
            shot("window-session.txt", seen)
            test.not_nil(desk, "the remote desktop inside the window:\n" .. text(seen))

            -- Alt+Home through the window's key mode opens the remote Start menu.
            assert(view:send(key("home", "home", {alt = true})))
            local menu
            menu, seen = wait_rows(view, updates, has("Programs"), 10)
            test.not_nil(menu, "the remote Start menu:\n" .. text(seen))
            assert(view:send(key("esc")))

            -- Ctrl+Alt+End shuts the remote desktop down: the connection
            -- window is asked for with the reason, and this one goes.
            assert(view:send(key("end", "end", {ctrl = true, alt = true})))
            local asked: any = next_open(opens, 20, tostring(pid))
            done(opens)
            test.not_nil(asked, "the connection window was asked for")
            test.eq(asked and asked.entry, "chicago.rdesktop:window")
            local back: any = json.decode(tostring(asked.args))
            test.eq(back.notice, "The remote desktop ended.")
            test.eq(back.selected, own, "the computer stays selected")
            test.is_true(exits_within(pid, 10), "the session window goes")
            view:close()
        end)

        test.it("hands a refusal back to the connection window, whole", function()
            local opens = stand_in()
            local view, _, pid = open("chicago.rdesktop:session", json.encode({computer = "no-such-node"}))
            local asked: any = next_open(opens, 15, tostring(pid))
            done(opens)
            test.not_nil(asked)
            test.eq(json.decode(tostring(asked.args)).notice,
                "The computer is not accessible. Remote Desktop is not enabled on no-such-node.")
            test.is_true(exits_within(pid, 10))
            view:close()
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return {run = function(options) return run_cases(options) end}

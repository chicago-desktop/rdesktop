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

local function define_tests()
    test.describe("Remote Desktop under a logged-on person's narrow scope", function()
        test.it("brings the remote desktop up with the rights of its own entry", function()
            local view = assert(tty.viewport({width = 80, height = 24}))
            local updates = assert(view:updates())
            local narrow, perr = security.policy("app:narrow")
            test.not_nil(narrow, tostring(perr))
            local scope = security.new_scope():with(narrow)
            local actor = security.new_actor("rdesktop-test-person", {})
            local pid, why = process.with_options({terminal = assert(view:grant())})
                :with_actor(actor):with_scope(scope)
                :spawn_monitored("chicago.rdesktop:window", "chicago.tui_desktop:workers")
            test.not_nil(pid, tostring(why))
            local rows, last = wait_rows(view, updates, has("Start"), 25)
            local shots = fs.get("app:shots")
            if shots then shots:writefile("window-narrow-scope.txt", text(last) .. "\n") end
            test.not_nil(rows, "the remote desktop inside the window:\n" .. text(last))

            -- Alt+Home through the window's key mode opens the remote Start menu.
            assert(view:send({type = "key", key = "home", key_type = "home", action = "press", alt = true}))
            local menu, seen = wait_rows(view, updates, has("Programs"), 10)
            test.not_nil(menu, "the remote Start menu:\n" .. text(seen))

            -- Closing the window ends the remote desktop with it.
            assert(view:send({type = "close"}))
            local events = process.events()
            local deadline = time.after("15s")
            local closed = false
            while not closed do
                local picked = channel.select({events:case_receive(), deadline:case_receive()})
                if picked.channel == deadline then break end
                local event: any = picked.value
                if type(event) == "table" and event.kind == process.event.EXIT and event.from == pid then closed = true end
            end
            test.is_true(closed, "the window exits on close")
            view:close()
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return {run = function(options) return run_cases(options) end}

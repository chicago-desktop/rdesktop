-- The loopback transport end to end: a real producer in a real local
-- viewport, driven only through the session interface.
local test = require("test")
local channel = require("channel")
local time = require("time")
local process = require("process")
local loopback = require("loopback")
local inputs = require("inputs")
local frames = require("frames")
local fs = require("fs")

local ECHO = {entry = "app:echo", host = "app:processes"}
local SHELL = {entry = "chicago.shell:shell", host = "chicago.tui_desktop:workers"}

-- wait(session, screen, accept, seconds) -> delta | nil, deltas
--
-- Does what the window does: on every watermark asks for the delta from the
-- revision `screen` shows and applies it, until `accept(screen, delta)`
-- holds or the time runs out. Returns the accepted delta and every delta
-- seen on the way (`seen.ended` — the reason, when the desktop ended).
local function wait(session: any, screen: any, accept: any, seconds: integer): (any, any)
    local deadline = time.after(tostring(seconds) .. "s")
    local seen: any = {}
    while true do
        local picked = channel.select({deadline:case_receive(), session:updates():case_receive(),
            session:ended():case_receive()})
        if picked.channel == deadline then return nil, seen end
        if picked.channel == session:ended() then
            seen.ended = tostring(picked.value)
            return nil, seen
        end
        local delta = session:snapshot(screen.revision)
        if delta then
            seen[#seen + 1] = delta
            frames.apply(screen, delta)
            if accept(screen, delta) then return delta, seen end
        end
    end
end

local function row_is(y: integer, text: string): any
    return function(screen: any) return screen.rows[y] == text end
end

local function any_row(pattern: string): any
    return function(screen: any)
        for _, row in ipairs(screen.rows) do
            if string.find(row, pattern, 1, true) then return true end
        end
        return false
    end
end

local function screen_text(screen: any): string
    return table.concat(screen.rows, "\n")
end

-- The screen as text, into test/shots/ — the evidence to read, beside the
-- assertions that only say a word was found.
local function shot(name: string, screen: any)
    local shots = fs.get("app:shots")
    if shots then shots:writefile(name, screen_text(screen) .. "\n") end
end

local function define_tests()
    test.describe("the loopback transport", function()
        test.it("refuses a spec it cannot start, with the reason", function()
            local session, why = loopback.open({entry = ECHO.entry, host = ECHO.host, width = 0, height = 5})
            test.is_nil(session)
            test.not_nil(string.find(tostring(why), "not positive", 1, true), tostring(why))
            session, why = loopback.open({entry = "app:no_such_entry", host = ECHO.host, width = 20, height = 5})
            test.is_nil(session)
            test.not_nil(string.find(tostring(why), "did not start", 1, true), tostring(why))
        end)

        test.it("carries a producer's screen as deltas, input to it and a resize both ways", function()
            local session, why = loopback.open({entry = ECHO.entry, host = ECHO.host, width = 30, height = 6})
            test.not_nil(session, tostring(why))
            local screen = frames.blank(30, 6)

            local first = wait(session, screen, row_is(1, "ready 30x6"), 10)
            test.not_nil(first, "the first frame: " .. screen_text(screen))
            test.is_true(first.full, "the first delta has every row")

            -- A key: the producer redraws, and the delta carries row 2 alone.
            test.is_true(session:send(inputs.key({type = "key", key_type = "runes", key = "x", action = "press"}, "remote")))
            local typed = wait(session, screen, row_is(2, "got x"), 10)
            test.not_nil(typed, "the key reached the producer: " .. screen_text(screen))
            test.is_false(typed.full)
            test.eq(typed.changed, 1)
            test.eq(typed.rows[2], "got x")
            test.is_nil(typed.rows[1])

            -- A mapped key arrives as what it maps to.
            test.is_true(session:send(inputs.key({type = "key", key_type = "home", key = "home",
                action = "press", alt = true}, "remote")))
            test.not_nil(wait(session, screen, row_is(2, "got alt+o"), 10), screen_text(screen))

            -- The mouse, in the remote screen's coordinates.
            test.is_true(session:send(inputs.mouse({type = "mouse", action = "press", button = "left", x = 7, y = 4}, 30, 6)))
            test.not_nil(wait(session, screen, row_is(2, "got mouse press 7,4"), 10), screen_text(screen))

            -- A resize reaches the producer, which redraws at the new size.
            test.is_true(session:resize(40, 8))
            local resized, on_resize = wait(session, screen, row_is(1, "ready 40x8"), 10)
            test.not_nil(resized, "the producer saw the resize: " .. screen_text(screen))
            test.is_true(on_resize[1].full and on_resize[1].width == 40 and on_resize[1].height == 8,
                "the first delta at a new size has every row")
            test.eq(screen.width * 100 + screen.height, 4008)

            -- Close ends the producer: it is cancelled, and the session says so.
            session:close()
            test.is_nil(session:snapshot(), "a closed session has no screen")
            local sent, refused = session:send({type = "key", key_type = "runes", key = "y", action = "press"})
            test.is_nil(sent)
            test.not_nil(refused)
        end)

        test.it("cuts a delta from the revision the viewer acknowledges, and skips the ones between", function()
            local session, why = loopback.open({entry = ECHO.entry, host = ECHO.host, width = 24, height = 4})
            test.not_nil(session, tostring(why))
            local screen = frames.blank(24, 4)
            test.not_nil(wait(session, screen, row_is(1, "ready 24x4"), 10))
            test.is_nil(session:snapshot(screen.revision), "nothing new at the acknowledged revision")

            -- Two keystrokes while the viewer does not ask: one delta, the latest screen.
            session:send({type = "key", key_type = "runes", key = "a", action = "press"})
            session:send({type = "key", key_type = "runes", key = "b", action = "press"})
            time.sleep("300ms")
            local latest = session:snapshot(screen.revision)
            test.not_nil(latest)
            test.eq(latest.rows[2], "got b", "the latest screen, not every screen")
            test.is_false(latest.full)
            frames.apply(screen, latest)

            -- A viewer that says it has an older revision gets every row.
            local again = session:snapshot(screen.revision - 1)
            test.not_nil(again)
            test.is_true(again.full, "an acknowledgement of anything but the last delta is answered in full")
            test.eq(again.changed, 4)

            test.is_nil(session:grant(), "the grant went to the desktop the session started")
            test.not_nil(session:handle(), "a local viewport has a viewer handle")
            session:close()
            test.is_nil(session:handle())
        end)

        test.it("says the session ended when the producer exits by itself", function()
            local session, why = loopback.open({entry = ECHO.entry, host = ECHO.host, width = 20, height = 4})
            test.not_nil(session, tostring(why))
            local screen = frames.blank(20, 4)
            test.not_nil(wait(session, screen, row_is(1, "ready 20x4"), 10))
            process.cancel(tostring(session.pid), "1s")
            local _, seen = wait(session, screen, function() return false end, 10)
            test.not_nil(seen.ended, "the end is reported, not silence")
            test.eq(seen.ended, "the remote desktop ended")
            session:close()
        end)

        test.it("tells each of two sessions in one process its own end", function()
            local first = assert(loopback.open({entry = ECHO.entry, host = ECHO.host, width = 20, height = 3}))
            local second = assert(loopback.open({entry = ECHO.entry, host = ECHO.host, width = 20, height = 3}))
            test.not_nil(wait(first, frames.blank(20, 3), row_is(1, "ready 20x3"), 10))
            test.not_nil(wait(second, frames.blank(20, 3), row_is(1, "ready 20x3"), 10))
            process.cancel(tostring(second.pid), "1s")
            local _, seen = wait(second, frames.blank(20, 3), function() return false end, 10)
            test.eq(seen.ended, "the remote desktop ended", "the second session learns its end")
            local quiet = channel.select({first:ended():case_receive()}, true)
            test.is_true(quiet.default == true, "the first session is still running")
            process.cancel(tostring(first.pid), "1s")
            _, seen = wait(first, frames.blank(20, 3), function() return false end, 10)
            test.eq(seen.ended, "the remote desktop ended", "the first learns its own end, not lost to the second")
            first:close()
            second:close()
        end)

        test.it("starts the Chicago shell itself in the viewport, on the base's window host", function()
            local session, why = loopback.open({entry = SHELL.entry, host = SHELL.host, width = 90, height = 26})
            test.not_nil(session, "the window host took the terminal grant: " .. tostring(why))
            local screen = frames.blank(90, 26)
            local up, seen = wait(session, screen, any_row("Start"), 25)
            test.not_nil(up, "the shell drew its desktop (ended: " .. tostring(seen.ended) .. ")\n" .. screen_text(screen))
            shot("loopback-shell-desktop.txt", screen)
            test.eq(screen.width * 100 + screen.height, 9026)

            -- Drive it: Alt+Home is the remote Start menu's Alt+O.
            test.is_true(session:send(inputs.key({type = "key", key_type = "home", key = "home",
                action = "press", alt = true}, "remote")))
            local menu, menu_seen = wait(session, screen, any_row("Programs"), 10)
            test.not_nil(menu, "the remote Start menu opened\n" .. screen_text(screen))
            shot("loopback-shell-menu.txt", screen)
            local partial = false
            for _, delta in ipairs(menu_seen) do
                if not delta.full and delta.changed < screen.height then partial = true end
            end
            test.is_true(partial, "a menu opening is sent as the rows it changed, not the whole screen")

            -- A resize lays the remote desktop out anew.
            test.is_true(session:resize(70, 20))
            test.not_nil(wait(session, screen, function(s, delta) return delta.full and s.width == 70 and s.height == 20 end, 10),
                "the remote desktop redrew at 70x20")

            session:close()
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return {run = function(options) return run_cases(options) end}

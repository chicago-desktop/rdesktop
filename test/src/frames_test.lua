-- Row deltas: what the transport hands the window instead of whole screens.
local test = require("test")
local frames = require("frames")

local function snapshot(revision: integer, width: integer, rows: {string}, cursor: any?): any
    return {revision = revision, width = width, height = #rows, rows = rows, cursor = cursor}
end

local function count(rows: any): integer
    local n = 0
    for _ in pairs(rows) do n = n + 1 end
    return n
end

local function define_tests()
    test.describe("frames.delta", function()
        test.it("sends every row the first time", function()
            local delta, last = frames.delta(nil, snapshot(3, 10, {"a", "b", "c"}))
            test.is_true(delta.full)
            test.eq(delta.changed, 3)
            test.eq(delta.rows[1] .. delta.rows[2] .. delta.rows[3], "abc")
            test.eq(delta.revision, 3)
            test.eq(#last.rows, 3)
        end)

        test.it("then only the rows that changed", function()
            local _, last = frames.delta(nil, snapshot(1, 10, {"a", "b", "c", "d"}))
            local delta = frames.delta(last, snapshot(2, 10, {"a", "B", "c", "D"}))
            test.is_false(delta.full)
            test.eq(delta.changed, 2)
            test.eq(count(delta.rows), 2)
            test.eq(delta.rows[2], "B")
            test.eq(delta.rows[4], "D")
            test.is_nil(delta.rows[1])
        end)

        test.it("sends nothing but the revision and cursor when no row changed", function()
            local _, last = frames.delta(nil, snapshot(1, 10, {"a", "b"}))
            local delta = frames.delta(last, snapshot(2, 10, {"a", "b"}, {x = 2, y = 1, visible = true}))
            test.eq(delta.changed, 0)
            test.eq(delta.cursor.x, 2)
        end)

        test.it("sends every row again when the size changed", function()
            local _, last = frames.delta(nil, snapshot(1, 10, {"a", "b"}))
            local wider = frames.delta(last, snapshot(2, 12, {"a", "b"}))
            test.is_true(wider.full)
            test.eq(wider.changed, 2)
            local taller = frames.delta(last, snapshot(2, 10, {"a", "b", "c"}))
            test.is_true(taller.full)
            test.eq(taller.changed, 3)
        end)
    end)

    test.describe("frames.apply", function()
        test.it("keeps the window's copy equal to the producer's rows", function()
            local screen = frames.blank(10, 3)
            local delta, last = frames.delta(nil, snapshot(1, 10, {"a", "b", "c"}))
            frames.apply(screen, delta)
            delta = frames.delta(last, snapshot(2, 10, {"a", "x", "c"}, {x = 1, y = 2, visible = true}))
            frames.apply(screen, delta)
            test.eq(table.concat(screen.rows, "|"), "a|x|c")
            test.eq(screen.revision, 2)
            test.eq(screen.cursor.y, 2)
        end)

        test.it("takes a full delta's size and drops rows past it", function()
            local screen = frames.blank(10, 4)
            local delta = frames.delta({width = 10, height = 4, rows = {"", "", "", ""}}, snapshot(5, 8, {"p", "q"}))
            frames.apply(screen, delta)
            test.eq(screen.width, 8)
            test.eq(screen.height, 2)
            test.eq(#screen.rows, 2)
        end)
    end)

    test.describe("frames.compose", function()
        test.it("pads a shorter remote screen and cuts a taller one to the window", function()
            local screen = frames.blank(10, 2)
            frames.apply(screen, (frames.delta(nil, snapshot(1, 10, {"a", "b"}))))
            local rows = frames.compose(screen, 10, 4)
            test.eq(#rows, 4)
            test.eq(rows[3], "")
            test.eq(#frames.compose(screen, 10, 1), 1)
        end)

        test.it("puts a notice on the last row, reversed and as wide as the window", function()
            local rows = frames.compose(frames.blank(20, 3), 20, 3, "Connecting")
            test.eq(rows[3], "\27[7m Connecting         \27[0m")
            test.eq(rows[2], "")
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return {run = function(options) return run_cases(options) end}

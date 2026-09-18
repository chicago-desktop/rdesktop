-- Process ends, told to whoever waits for them.
--
-- A process has ONE lifecycle channel (process.events()). Two readers of it
-- take each other's events: a session that waits for its desktop's EXIT
-- would lose it to a reader that waits for another pid and drops the rest.
-- So one reader per process, here, hands each end to the channel of that
-- pid. Every transport in this module watches through it.
--
-- AN END IS EXIT OR LINK_DOWN. When a node leaves the cluster, the runtime
-- tells every local process that monitors OR links a pid there with a
-- LINK_DOWN, not an EXIT (system/topology HandleNodeExit). A process
-- without trap_links is terminated by a LINK_DOWN ("linked process
-- failed", runtime/lua/engine/process.go) — so a window watching a remote
-- session vanished at the moment the remote node left, and a served
-- session died without ending its desktop. `watch` therefore turns
-- trap_links on for the process: a departure is an event it can word.
local process = require("process")
local channel = require("channel")

local exits = {}

-- Module state, one per process: the channel of every watched pid.
local watching: any = {channels = {}, started = false, trapping = false}

local function run()
    local events = process.events()
    while true do
        local event: any, ok = events:receive()
        if not ok then
            for pid, ch in pairs(watching.channels) do
                ch:send({error = "the process can no longer be watched"})
                watching.channels[pid] = nil
            end
            watching.started = false
            return
        end
        local kind: any = type(event) == "table" and event.kind or nil
        if kind == process.event.EXIT or kind == process.event.LINK_DOWN then
            local pid = tostring(event.from)
            local ch: any = watching.channels[pid]
            if ch then
                watching.channels[pid] = nil
                local result: any = event.result
                local told: any = {}
                if type(result) == "table" then
                    for key, value in pairs(result) do told[key] = value end
                end
                if kind == process.event.LINK_DOWN then
                    told.link_down = true
                    if told.error == nil then told.error = "the link went down" end
                end
                ch:send(told)
            end
        end
    end
end

-- trap() — turn trap_links on for this process, once. Call it BEFORE the
-- first link or monitor: a LINK_DOWN that arrives earlier still kills.
function exits.trap()
    if watching.trapping then return end
    watching.trapping = true
    process.set_options({trap_links = true})
end

-- watch(pid) -> channel
--
-- A channel that receives the pid's end once: its exit result (`{error = …}`
-- when it failed), or `{link_down = true, error = …}` when its node left or
-- a linked process failed. The caller monitors or links the pid itself
-- (spawn_monitored, spawn_linked_monitored, process.monitor); this only
-- delivers — and turns trap_links on, once, for the whole process.
function exits.watch(pid: string): any
    exits.trap()
    local ch = channel.new(1)
    watching.channels[pid] = ch
    if not watching.started then
        watching.started = true
        coroutine.spawn(run)
    end
    return ch
end

-- forget(pid) — stop delivering the pid's exit.
function exits.forget(pid: string)
    watching.channels[pid] = nil
end

return exits

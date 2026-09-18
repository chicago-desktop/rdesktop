-- Process ends, told to whoever waits for them.
--
-- A process has ONE lifecycle channel (process.events()). Two readers of it
-- take each other's events: a session that waits for its desktop's EXIT
-- would lose it to a reader that waits for another pid and drops the rest.
-- So one reader per process, here, hands each EXIT to the channel of that
-- pid. Every transport in this module watches through it.
local process = require("process")
local channel = require("channel")

local exits = {}

-- Module state, one per process: the channel of every watched pid.
local watching: any = {channels = {}, started = false}

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
        if type(event) == "table" and event.kind == process.event.EXIT then
            local pid = tostring(event.from)
            local ch: any = watching.channels[pid]
            if ch then
                watching.channels[pid] = nil
                local result: any = event.result
                ch:send(type(result) == "table" and result or {})
            end
        end
    end
end

-- watch(pid) -> channel
--
-- A channel that receives the pid's exit result (`{error = …}` when it
-- failed) once. The caller monitors the pid itself (spawn_monitored,
-- process.monitor); this only delivers.
function exits.watch(pid: string): any
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

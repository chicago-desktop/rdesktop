-- The Remote Desktop broker of a node: "Remote Desktop is enabled on this
-- computer".
--
-- The runtime has no remote spawn, so a viewer cannot start a desktop on
-- another node itself. Each node that serves runs this resident process: it
-- takes the name wire.broker_name(<this node's id>) in the cluster's name
-- registry (EVENTUAL scope), and on every `open` spawns a
-- chicago.rdesktop:host_session on its own host, which starts the desktop
-- and serves the viewer from then on. The broker holds no session state.
--
-- It offers ONE desktop: `open` names no entry (the server's default) or
-- exactly that one; a viewer does not choose what runs on this computer.
local process = require("process")
local channel = require("channel")
local system = require("system")
local logger = require("logger")
local wire = require("wire")

local broker = {}

-- What this computer serves: the Chicago shell on the base's window host.
broker.DESKTOP = {entry = "chicago.shell:shell", host = "chicago.tui_desktop:workers"}

broker.SESSION = "chicago.rdesktop:host_session"

-- offer(options) -> {name, entry, host} | nil, reason
--
-- `options` exists for tests (a broker under another name serving a test
-- producer); the service is started without it.
local function offer(options: any): (any, string?)
    local o: any = type(options) == "table" and options or {}
    local name: any = o.name
    if type(name) ~= "string" or name == "" then
        local node, err = system.node.id()
        if not node then return nil, "this node has no id: " .. tostring(err) end
        name = wire.broker_name(tostring(node))
    end
    return {
        name = name,
        entry = type(o.entry) == "string" and o.entry ~= "" and o.entry or broker.DESKTOP.entry,
        host = type(o.host) == "string" and o.host ~= "" and o.host or broker.DESKTOP.host,
    }, nil
end

-- unclustered(err) -> boolean — the refusal of a runtime without a cluster.
function broker.unclustered(err: any): boolean
    return err ~= nil and string.find(tostring(err), "eventual registry not available", 1, true) ~= nil
end

function broker.main(options: any)
    local log = logger:named("chicago.rdesktop.broker")
    local served, why = offer(options)
    if not served then
        log:error("broker not started", {reason = why})
        return nil, why
    end
    local registered, rerr = process.registry.register(tostring(served.name), tostring(process.pid()), process.registry.EVENTUAL)
    if not registered and broker.unclustered(rerr) then
        -- A runtime without a cluster has no EVENTUAL registry: this node
        -- serves only viewers on itself, under a node-local name. Any other
        -- refusal (a permission, a name taken) stops the broker, named.
        log:warn("no cluster name registry; Remote Desktop serves this node only", {name = served.name})
        registered, rerr = process.registry.register(tostring(served.name))
    end
    if not registered then
        log:error("broker name not taken", {name = served.name, error = tostring(rerr)})
        return nil, tostring(rerr)
    end
    -- Sessions run on the broker's own host: the PID names it.
    local session_host = wire.host_of(process.pid())
    log:info("remote desktop enabled", {name = served.name, desktop = served.entry, sessions_on = session_host})

    local inbox = process.listen(wire.TOPIC, {message = true})
    local lifecycle = process.events()
    while true do
        local picked = channel.select({inbox:case_receive(), lifecycle:case_receive()})
        if not picked.ok then break end
        if picked.channel == lifecycle then
            local event: any = picked.value
            if type(event) == "table" and event.kind == process.event.CANCEL then break end
        else
            local message: any = picked.value
            local data: any = message:payload():data()
            local viewer = tostring(message:from())
            if type(data) == "table" and data.k == "open" then
                local number = math.tointeger(data.s)
                local asked: any = data.n
                if number == nil then
                    log:warn("open without a session number", {viewer = viewer})
                elseif asked ~= nil and asked ~= "" and asked ~= served.entry then
                    wire.send(viewer, {k = "failed", s = number,
                        m = "This computer does not offer " .. tostring(asked) .. "."})
                elseif session_host == nil then
                    wire.send(viewer, {k = "failed", s = number, m = "The remote computer cannot start sessions."})
                else
                    local pid, serr = process.spawn(broker.SESSION, session_host, viewer, number,
                        data.x, data.y, served.entry, served.host)
                    if not pid then
                        log:error("session not started", {viewer = viewer, error = tostring(serr)})
                        wire.send(viewer, {k = "failed", s = number,
                            m = "The remote computer could not start a session: " .. tostring(serr)})
                    end
                end
            end
        end
    end
    process.registry.unregister(tostring(served.name))
end

return broker

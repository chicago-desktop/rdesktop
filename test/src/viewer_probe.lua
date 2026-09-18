-- A viewer for mesh_test that disappears without closing its session: it
-- opens one through the named broker, tells the test the served session's
-- pid, and returns when told to — no close, no goodbye.
local process = require("process")
local mesh = require("mesh")

local function main(parent: string, broker: string)
    local session = assert(mesh.open({broker = broker, width = 20, height = 3}))
    process.send(parent, "probe", tostring(session.server))
    local die = process.listen("die")
    die:receive()
end

return {main = main}

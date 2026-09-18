-- Watches a LINKED child that fails, the way a session watches a pid whose
-- node leaves: the runtime sends LINK_DOWN in both cases (HandleNodeExit
-- does so for monitors too). Reports what it was told; a process that does
-- not trap links never gets to report — it dies with its child.
local process = require("process")
local exits = require("exits")

local function main(parent: string)
    exits.trap()
    local child = tostring(assert(process.spawn_linked("app:crasher", "app:processes")))
    local ended = exits.watch(child)
    process.send(child, "crash", true)
    local told: any = ended:receive()
    process.send(parent, "probe.link", {link_down = told.link_down == true, error = tostring(told.error)})
end

return {main = main}

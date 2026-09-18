-- A process that fails on request — the linked child of link_probe.
local process = require("process")

local function main()
    local told = process.listen("crash")
    told:receive()
    error("a deliberate failure for the link test")
end

return {main = main}

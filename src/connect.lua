-- The Remote Desktop Connection screen, the pure half: the computers of the
-- network, the one the person picks, Connect and Cancel, and a status line
-- that says why the last connection failed or ended.
--
-- The list comes from a snapshot of chicago.shell.config:system (a value OR
-- a reason for each field — the same source as Network Neighborhood), read
-- by the window; this file only shapes it, so the tests hand it any mesh.
--
-- Only what is known is shown. The membership says which computers are in
-- the cluster and, optionally, the address each advertises — not whether
-- one is serving or even reachable right now, and not the role of any node
-- but this one. So there is a Computer column, an Address column only when
-- a member advertises one, and no "Status": a column that would say
-- "Online" for every member measures nothing.
local connect = {}

-- A node id the runtime generated (no cluster name configured): a uuid tells
-- a person nothing, so this computer is captioned by its host name there,
-- as Network Neighborhood does.
local function looks_generated(id: string): boolean
    return id:match("^%x%x%x%x%x%x%x%x%-%x%x%x%x%-") ~= nil
end

-- computers(snapshot) -> rows, status
--
-- rows = {{id, name, addr, is_local}, …}, this computer first, then by name.
-- `status` says what the network is when the list alone cannot: off, alone,
-- or unreadable (with the reason).
function connect.computers(snapshot: any): (any, string)
    local snap: any = type(snapshot) == "table" and snapshot or {}
    local problems: any = type(snap.problems) == "table" and snap.problems or {}
    local own = type(snap.node_id) == "string" and snap.node_id or nil
    local host = type(snap.hostname) == "string" and snap.hostname ~= "" and snap.hostname or nil

    local function caption(id: string, is_local: boolean): string
        if is_local and host and looks_generated(id) then return tostring(host) end
        return id
    end

    local rows: any = {}
    local seen_local = false
    for _, entry in ipairs(type(snap.members) == "table" and snap.members or {}) do
        local member: any = entry
        local id = tostring(member.id or "")
        if id ~= "" then
            local is_local = member.is_local == true or id == own
            seen_local = seen_local or is_local
            rows[#rows + 1] = {id = id, name = caption(id, is_local),
                addr = type(member.addr) == "string" and member.addr or "", is_local = is_local}
        end
    end
    -- This computer is always there to connect to, even when the membership
    -- could not be read.
    if not seen_local and own then
        rows[#rows + 1] = {id = own, name = caption(own, true), addr = "", is_local = true}
    end
    table.sort(rows, function(a: any, b: any)
        if a.is_local ~= b.is_local then return a.is_local end
        return a.name < b.name
    end)

    local status: string
    if problems.members ~= nil then
        status = tostring(problems.members)
    elseif #rows <= 1 and snap.node_role == "non-member" then
        status = "The network is off: this computer is not in a cluster."
    elseif #rows <= 1 then
        status = "No other computers are on the network."
    else
        status = tostring(#rows) .. " computers on the network."
    end
    if own == nil and problems.node_id ~= nil then
        status = tostring(problems.node_id) .. "; " .. status
    end
    return rows, status
end

-- model(snapshot, notice?) -> the screen's model
--
-- `notice` is why the last connection failed or ended; it stands above the
-- buttons until the person acts, the status line keeps the network's state.
function connect.model(snapshot: any, notice: any?): any
    local rows, status = connect.computers(snapshot)
    local first: any = rows[1]
    return {rows = rows, status = status, notice = notice, selected = first and first.id or nil}
end

function connect.refresh(model: any, snapshot: any): any
    local rows, status = connect.computers(snapshot)
    model.rows, model.status = rows, status
    local kept = false
    for _, row in ipairs(rows) do
        if row.id == model.selected then kept = true end
    end
    if not kept then
        local first: any = rows[1]
        model.selected = first and first.id or nil
    end
    return model
end

local function has_address(rows: any): boolean
    for _, row in ipairs(rows) do
        if row.addr ~= "" then return true end
    end
    return false
end

-- columns(model) -> the table's columns: Computer, and Address when known.
function connect.columns(model: any): any
    local columns: any = {{title = "Computer", weight = 3}}
    if has_address(model.rows) then columns[2] = {title = "Address", weight = 2} end
    return columns
end

-- tree(model) -> the SDK component tree of the screen
function connect.tree(model: any): any
    local addresses = has_address(model.rows)
    local rows: any = {}
    for _, row in ipairs(model.rows) do
        local name = row.is_local and (row.name .. " (this computer)") or row.name
        local cells: any = {name}
        if addresses then cells[2] = row.addr end
        rows[#rows + 1] = {id = row.id, cells = cells}
    end
    local children: any = {
        {kind = "label", size = 1, text = "Choose the computer to connect to:"},
        {kind = "table", id = "computers", columns = connect.columns(model), rows = rows,
            selected = model.selected},
    }
    -- Why the last connection failed or ended: whole, wrapped over two rows,
    -- never cut to the width of a status field.
    if model.notice ~= nil and model.notice ~= "" then
        children[#children + 1] = {kind = "label", size = 2, wrap = true, alert = true, text = model.notice}
    end
    children[#children + 1] = {kind = "row", size = 2, align = "right", gap = 1, children = {
        -- The classic dialog buttons: 75x23 px, 6 px apart (docs/sdk.md).
        {kind = "button", id = "connect", size = 12, size_px = 81, width_px = 75, text = "Connect",
            default = true, disabled = model.selected == nil},
        {kind = "button", id = "cancel", size = 12, size_px = 81, width_px = 75, text = "Cancel"},
    }}
    children[#children + 1] = {kind = "statusbar", size = 1, fields = {{text = model.status}}}
    return {kind = "column", padding = 1, gap = 1, padding_bottom = 0, children = children}
end

local function row_id(model: any, action: any): any
    local value: any = action.value
    if type(value) == "table" and value.id ~= nil then return value.id end
    local row: any = model.rows[math.tointeger(action.index) or 0]
    return row and row.id or nil
end

-- update(model, action) -> result | nil, changed
--
-- result = {connect = <node id>} or {cancel = true}. A second click on the
-- selected row is a double click (the SDK marks a click `pointer`), Enter on
-- the list and the Connect button connect, Cancel and Esc cancel.
function connect.update(model: any, action: any): (any, boolean)
    if type(action) ~= "table" then return nil, false end
    if action.id == "computers" and action.type == "select" then
        local id = row_id(model, action)
        if action.pointer and id ~= nil and id == model.selected then return {connect = id}, false end
        model.selected = id
        model.notice = nil
        return nil, true
    elseif (action.id == "computers" or action.id == "connect") and action.type == "activate" then
        if model.selected == nil then
            model.notice = "Choose a computer first."
            return nil, true
        end
        return {connect = model.selected}, false
    elseif action.id == "cancel" and action.type == "activate" then
        return {cancel = true}, false
    elseif action.type == "key" and action.key_type == "esc" then
        return {cancel = true}, false
    end
    return nil, false
end

-- name_of(model, id) -> how the screen calls a computer
function connect.name_of(model: any, id: any): string
    for _, row in ipairs(model.rows) do
        if row.id == id then return tostring(row.name) end
    end
    return tostring(id)
end

return connect

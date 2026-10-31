-- Pure viewer selection. This never changes the game's worldline cursor.
local Selection = {}

function Selection.ids(state)
    local result, seen = {}, {}
    for _, id in ipairs(state.selection_order or {}) do
        if state.selections and state.selections[id] and not seen[id] then
            result[#result + 1], seen[id] = id, true
        end
    end
    -- Keep older callers that set the primary detail node directly compatible.
    if state.selected and not seen[state.selected] then return {state.selected} end
    return result
end

function Selection.set(state, ids, primary, anchor)
    local order, selected = {}, {}
    for _, id in ipairs(ids or {}) do
        if not selected[id] then order[#order + 1], selected[id] = id, true end
    end
    primary = selected[primary] and primary or order[#order]
    local previous, changed = Selection.ids(state), state.selected ~= primary
        or not state.selections or not state.selection_order or #state.selection_order ~= #order
    if #previous ~= #order then changed = true end
    for i, id in ipairs(order) do
        if previous[i] ~= id or not (state.selections and state.selections[id]) then changed = true end
    end
    if not changed then state.selection_anchor = anchor; return false end
    state.selections, state.selection_order, state.selected = selected, order, primary
    state.selection_anchor = anchor
    state.compare_ids = #order == 2 and {order[1], order[2]} or nil
    state.selection_revision = (state.selection_revision or 0) + 1
    state.detail_scroll = 0
    if #order == 2 then state.detail_tab = 'diff'
    elseif state.detail_tab == 'diff' then state.detail_tab = 'overview' end
    return changed
end

function Selection.prune(state, layout)
    local ids = {}
    for _, id in ipairs(Selection.ids(state)) do
        if layout.by_id[id] then ids[#ids + 1] = id end
    end
    local anchor = state.selection_anchor
    if not layout.by_id[anchor] then anchor = nil end
    return Selection.set(state, ids, state.selected, anchor)
end

-- Shift follows the tree's unique connecting path through its lowest common
-- ancestor, even across sibling branches. Hidden folded nodes remain hidden.
function Selection.path(tree, layout, first, last)
    local function node(id)
        if tree and type(tree.get) == 'function' then return tree:get(id) end
        return layout.by_id[id]
    end
    local ancestors, first_path, visited, id = {}, {}, {}, first
    while id and id ~= 0 and not visited[id] do
        visited[id], ancestors[id] = true, #first_path + 1
        first_path[#first_path + 1] = id
        local item = node(id)
        id = item and item.parent
    end
    local last_path = {}
    visited, id = {}, last
    while id and id ~= 0 and not ancestors[id] and not visited[id] do
        visited[id], last_path[#last_path + 1] = true, id
        local item = node(id)
        id = item and item.parent
    end
    if not id or not ancestors[id] then return layout.by_id[last] and {last} or {} end
    local result = {}
    for i = 1, ancestors[id] do
        if layout.by_id[first_path[i]] then result[#result + 1] = first_path[i] end
    end
    for i = #last_path, 1, -1 do
        if layout.by_id[last_path[i]] then result[#result + 1] = last_path[i] end
    end
    return result
end

local function union(first, second)
    local result, seen = {}, {}
    for _, list in ipairs({first, second}) do
        for _, id in ipairs(list) do
            if not seen[id] then result[#result + 1], seen[id] = id, true end
        end
    end
    return result
end

function Selection.click(state, id, ctrl, shift, tree, layout)
    if not id then
        if not ctrl then return Selection.set(state, {}, nil, nil) end
        return false
    end
    local anchor = state.selection_anchor or state.selected or id
    if shift then
        local path = Selection.path(tree, layout, anchor, id)
        return Selection.set(state, ctrl and union(Selection.ids(state), path) or path, id, anchor)
    elseif ctrl then
        local ids, found = {}, false
        for _, selected in ipairs(Selection.ids(state)) do
            if selected == id then found = true else ids[#ids + 1] = selected end
        end
        if not found then ids[#ids + 1] = id end
        return Selection.set(state, ids, not found and id or state.selected, id)
    end
    return Selection.set(state, {id}, id, id)
end

function Selection.in_rect(layout, rect)
    local ids = {}
    for _, node in ipairs(layout.nodes) do
        if node.x <= rect.x + rect.w and node.x + node.w >= rect.x
            and node.y <= rect.y + rect.h and node.y + node.h >= rect.y then
            ids[#ids + 1] = node.id
        end
    end
    return ids
end

function Selection.box(state, ids, base, additive)
    local result = additive and union(base or {}, ids) or ids
    return Selection.set(state, result, result[#result], result[1])
end

return Selection

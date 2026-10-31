-- Pure layout and viewport math. Rendering/input remain in ui.lua.
local Graph = { MIN_SCALE = 0.25, MAX_SCALE = 1.6 }
local visibility_cache = setmetatable({}, {__mode = 'k'})

local function finite(value)
    return type(value) == 'number' and value == value and math.abs(value) ~= math.huge
end

local function positive(value, name, allow_zero)
    assert(finite(value) and (allow_zero and value >= 0 or value > 0), 'Invalid ' .. name)
    return value
end

local function bounds_for(view, bounds)
    bounds = bounds or {}
    return bounds.x or 0, bounds.y or 0,
        bounds.w or bounds.width or view.width or 0,
        bounds.h or bounds.height or view.height or 0
end

local function scale_for(view)
    return math.max(Graph.MIN_SCALE, math.min(Graph.MAX_SCALE, view.scale or 1))
end

local function edge_box(points)
    local min_x, min_y, max_x, max_y = points[1], points[2], points[1], points[2]
    for i = 3, #points, 2 do
        min_x, max_x = math.min(min_x, points[i]), math.max(max_x, points[i])
        min_y, max_y = math.min(min_y, points[i + 1]), math.max(max_y, points[i + 1])
    end
    return min_x, min_y, max_x - min_x, max_y - min_y
end

local function by_y(a, b)
    if a.y == b.y then return (a.id or a.child) < (b.id or b.child) end
    return a.y < b.y
end

local function interval_index(items, first, last)
    if first > last then return nil end
    local middle = math.floor((first + last) / 2)
    local item = items[middle]
    local left, right = interval_index(items, first, middle - 1), interval_index(items, middle + 1, last)
    return {item = item, left = left, right = right,
        max_y = math.max(item.y + item.h, left and left.max_y or -math.huge, right and right.max_y or -math.huge)}
end

local function build_index(layout)
    local columns, max_depth = {}, 0
    for _, node in ipairs(layout.nodes) do
        local column = columns[node.depth]
        if not column then column = {nodes = {}, edges = {}}; columns[node.depth] = column end
        column.nodes[#column.nodes + 1] = node
        max_depth = math.max(max_depth, node.depth)
    end
    for _, edge in ipairs(layout.edges) do
        local column = columns[layout.by_id[edge.parent].depth]
        column.edges[#column.edges + 1] = edge
    end
    for _, column in pairs(columns) do
        table.sort(column.nodes, by_y)
        table.sort(column.edges, by_y)
        column.edge_index = interval_index(column.edges, 1, #column.edges)
    end
    layout.columns, layout.max_depth = columns, max_depth
end

function Graph.layout(rows, options)
    options = options or {}
    local node_w = positive(options.node_w or options.node_width or 190, 'node width')
    local node_h = positive(options.node_h or options.node_height or node_w * 95 / 71, 'node height')
    local gap_x = positive(options.gap_x or 118, 'horizontal gap', true)
    local gap_y = positive(options.gap_y or 64, 'vertical gap', true)
    local padding = positive(options.padding or 32, 'padding', true)
    local result = {nodes = {}, by_id = {}, edges = {}, fold_regions = {}, width = 0, height = 0,
        node_w = node_w, node_h = node_h, gap_x = gap_x, gap_y = gap_y, padding = padding}
    local roots = {}
    for _, row in ipairs(rows or {}) do
        assert(type(row) == 'table' and row.id ~= nil, 'A graph row needs an ID')
        assert(not result.by_id[row.id], 'Repeated graph node ID')
        local node = {id = row.id, parent = row.parent or 0, row = row,
            children = {}, w = node_w, h = node_h}
        result.by_id[node.id] = node
        result.nodes[#result.nodes + 1] = node
    end
    for _, node in ipairs(result.nodes) do
        if node.parent == 0 then
            roots[#roots + 1] = node.id
        else
            local parent = assert(result.by_id[node.parent], 'Missing graph parent')
            parent.children[#parent.children + 1] = node.id
        end
    end
    if #result.nodes == 0 then return result end

    -- Build preorder iteratively; reversing it gives children-before-parent order.
    -- Each node owns one parent, so any remaining unvisited component is cyclic.
    local stack, preorder, visited = {}, {}, {}
    for i = #roots, 1, -1 do stack[#stack + 1] = {id = roots[i], depth = 0} end
    while #stack > 0 do
        local position = table.remove(stack)
        assert(not visited[position.id], 'Cyclic graph node')
        visited[position.id] = true
        local node = result.by_id[position.id]
        node.depth = position.depth
        node.x = padding + node.depth * (node_w + gap_x)
        preorder[#preorder + 1] = node.id
        for i = #node.children, 1, -1 do
            stack[#stack + 1] = {id = node.children[i], depth = node.depth + 1}
        end
    end
    assert(#preorder == #result.nodes, 'Graph contains a cycle or disconnected component')

    local leaf = 0
    for _, id in ipairs(preorder) do
        local node = result.by_id[id]
        if #node.children == 0 then
            node.cy = padding + node_h / 2 + leaf * (node_h + gap_y)
            leaf = leaf + 1
        end
    end
    for index = #preorder, 1, -1 do
        local node = result.by_id[preorder[index]]
        if #node.children > 0 then
            local first = result.by_id[node.children[1]]
            local last = result.by_id[node.children[#node.children]]
            node.cy = (first.cy + last.cy) / 2
        end
        node.y, node.cx = node.cy - node_h / 2, node.x + node_w / 2
        result.width = math.max(result.width, node.x + node_w + padding)
        result.height = math.max(result.height, node.y + node_h + padding)
    end
    for _, child in ipairs(result.nodes) do
        if child.parent ~= 0 then
            local parent = result.by_id[child.parent]
            local from_x, to_x = parent.x + parent.w, child.x
            local turn_x = (from_x + to_x) / 2
            local points = {from_x, parent.cy, turn_x, parent.cy,
                turn_x, child.cy, to_x, child.cy}
            local x, y, w, h = edge_box(points)
            result.edges[#result.edges + 1] = {parent = parent.id, child = child.id,
                points = points, x = x, y = y, w = w, h = h}
        end
    end
    for _, region in ipairs(rows and rows.fold_regions or {}) do
        local start, finish = result.by_id[region.start_id], result.by_id[region.end_id]
        -- Projection guarantees distinct, visible endpoints. Keep malformed
        -- external presentation metadata from drawing a misleading single card.
        if region.collapsed and start and finish and start ~= finish then
            local x, y = math.min(start.x, finish.x), math.min(start.y, finish.y)
            result.fold_regions[#result.fold_regions + 1] = {
                id = region.id, start_id = region.start_id, end_id = region.end_id,
                label = region.label, hidden_count = region.hidden_count, collapsed = true,
                x = x, y = y, w = math.max(start.x + start.w, finish.x + finish.w) - x,
                h = math.max(start.y + start.h, finish.y + finish.h) - y,
            }
        end
    end
    result.roots = roots
    build_index(result)
    return result
end

function Graph.world_to_screen(view, world_x, world_y, bounds)
    local x, y = bounds_for(view, bounds)
    local scale = scale_for(view)
    return x + (view.pan_x or 0) + world_x * scale,
        y + (view.pan_y or 0) + world_y * scale
end

function Graph.screen_to_world(view, screen_x, screen_y, bounds)
    local x, y = bounds_for(view, bounds)
    local scale = scale_for(view)
    return (screen_x - x - (view.pan_x or 0)) / scale,
        (screen_y - y - (view.pan_y or 0)) / scale
end

function Graph.fit(view, layout, bounds)
    local _, _, width, height = bounds_for(view, bounds)
    view.width, view.height = width, height
    if not layout or layout.width <= 0 or layout.height <= 0 then
        view.scale, view.pan_x, view.pan_y = 1, 0, 0
        return view
    end
    local inset = view.fit_padding or 24
    local fit = math.min(math.max(1, width - inset * 2) / layout.width,
        math.max(1, height - inset * 2) / layout.height)
    view.scale = math.max(Graph.MIN_SCALE, math.min(Graph.MAX_SCALE, fit))
    view.pan_x = (width - layout.width * view.scale) / 2
    view.pan_y = (height - layout.height * view.scale) / 2
    return view
end

function Graph.new_view(width, height, layout)
    local view = {width = positive(width, 'viewport width'), height = positive(height, 'viewport height'),
        pan_x = 0, pan_y = 0, scale = 1}
    return Graph.fit(view, layout)
end

function Graph.zoom(view, factor, screen_x, screen_y, bounds)
    positive(factor, 'zoom factor')
    local x, y, width, height = bounds_for(view, bounds)
    screen_x, screen_y = screen_x or x + width / 2, screen_y or y + height / 2
    local world_x, world_y = Graph.screen_to_world(view, screen_x, screen_y, bounds)
    view.scale = math.max(Graph.MIN_SCALE, math.min(Graph.MAX_SCALE, scale_for(view) * factor))
    view.pan_x, view.pan_y = screen_x - x - world_x * view.scale,
        screen_y - y - world_y * view.scale
    return view
end

-- A minimap supplies a graph-world point, not a main-canvas pixel. Keep that
-- point at its existing main-canvas position, including offscreen positions.
function Graph.zoom_world(view, factor, world_x, world_y, bounds)
    assert(finite(world_x) and finite(world_y), 'Invalid world zoom anchor')
    local screen_x, screen_y = Graph.world_to_screen(view, world_x, world_y, bounds)
    return Graph.zoom(view, factor, screen_x, screen_y, bounds)
end

function Graph.focus_node(view, node, bounds)
    if not node then return view end
    local _, _, width, height = bounds_for(view, bounds)
    local scale = scale_for(view)
    view.pan_x = width / 2 - (node.x + node.w / 2) * scale
    view.pan_y = height / 2 - (node.y + node.h / 2) * scale
    return view
end

function Graph.reveal_node(view, node, bounds)
    if not node then return view end
    local x, y, width, height = bounds_for(view, bounds)
    local sx, sy = Graph.world_to_screen(view, node.x, node.y, bounds)
    local margin, scale = 20, scale_for(view)
    local dx, dy = 0, 0
    if sx < x + margin then dx = x + margin - sx
    elseif sx + node.w * scale > x + width - margin then dx = x + width - margin - sx - node.w * scale end
    if sy < y + margin then dy = y + margin - sy
    elseif sy + node.h * scale > y + height - margin then dy = y + height - margin - sy - node.h * scale end
    view.pan_x, view.pan_y = (view.pan_x or 0) + dx, (view.pan_y or 0) + dy
    return view
end

function Graph.hit_test(layout, view, screen_x, screen_y, bounds)
    if not layout then return nil end
    local x, y, width, height = bounds_for(view, bounds)
    if screen_x < x or screen_y < y or screen_x > x + width or screen_y > y + height then return nil end
    local world_x, world_y = Graph.screen_to_world(view, screen_x, screen_y, bounds)
    local nodes = Graph.visible_nodes(layout, view, bounds)
    for index = #nodes, 1, -1 do
        local node = nodes[index]
        if world_x >= node.x and world_x <= node.x + node.w
            and world_y >= node.y and world_y <= node.y + node.h then return node end
    end
end

function Graph.node_visible(node, view, bounds, margin)
    local x, y, width, height = bounds_for(view, bounds)
    local sx, sy = Graph.world_to_screen(view, node.x, node.y, bounds)
    local scale = scale_for(view)
    margin = margin or 0
    return sx + node.w * scale >= x - margin and sx <= x + width + margin
        and sy + node.h * scale >= y - margin and sy <= y + height + margin
end

function Graph.edge_visible(edge, view, bounds, margin)
    return Graph.node_visible(edge, view, bounds, margin)
end

local function intersect(item, left, top, right, bottom)
    return item.x + item.w >= left and item.x <= right
        and item.y + item.h >= top and item.y <= bottom
end

local function query_edges(index, left, top, right, bottom, output)
    if not index or index.max_y < top then return end
    query_edges(index.left, left, top, right, bottom, output)
    local edge = index.item
    if edge.y <= bottom then
        if intersect(edge, left, top, right, bottom) then output[#output + 1] = edge end
        query_edges(index.right, left, top, right, bottom, output)
    end
end

-- Layouts are immutable until rebuilt. Cache the viewport result and use a
-- column + Y interval index when panning, instead of walking every hidden card
-- and connector each frame. Arrays contain references, never copied summaries.
function Graph.query_visible(layout, view, bounds, margin)
    if not layout then return {nodes = {}, edges = {}} end
    local bx, by, bw, bh = bounds_for(view, bounds)
    local scale, px, py = scale_for(view), view.pan_x or 0, view.pan_y or 0
    margin = margin or 0
    local cached = visibility_cache[layout]
    if cached and cached.px == px and cached.py == py and cached.scale == scale
        and cached.bx == bx and cached.by == by and cached.bw == bw and cached.bh == bh
        and cached.margin == margin then return cached end
    if not cached then cached = {nodes = {}, edges = {}}; visibility_cache[layout] = cached end
    for i = #cached.nodes, 1, -1 do cached.nodes[i] = nil end
    for i = #cached.edges, 1, -1 do cached.edges[i] = nil end
    cached.px, cached.py, cached.scale, cached.bx, cached.by, cached.bw, cached.bh, cached.margin = px, py, scale, bx, by, bw, bh, margin
    if #layout.nodes == 0 then return cached end
    local left, top = (-margin - px) / scale, (-margin - py) / scale
    local right, bottom = (bw + margin - px) / scale, (bh + margin - py) / scale
    if not layout.columns then
        for _, node in ipairs(layout.nodes) do
            if intersect(node, left, top, right, bottom) then cached.nodes[#cached.nodes + 1] = node end
        end
        for _, edge in ipairs(layout.edges or {}) do
            if intersect(edge, left, top, right, bottom) then cached.edges[#cached.edges + 1] = edge end
        end
        return cached
    end
    local step = layout.node_w + layout.gap_x
    local first = math.max(0, math.floor((left - layout.padding - layout.node_w) / step))
    local last = math.min(layout.max_depth, math.floor((right - layout.padding) / step))
    for depth = first, last do
        local column = layout.columns[depth]
        if column then
            local nodes, low, high = column.nodes, 1, #column.nodes + 1
            while low < high do
                local middle = math.floor((low + high) / 2)
                if nodes[middle] and nodes[middle].y + nodes[middle].h < top then low = middle + 1 else high = middle end
            end
            for i = low, #nodes do
                local node = nodes[i]
                if node.y > bottom then break end
                if intersect(node, left, top, right, bottom) then cached.nodes[#cached.nodes + 1] = node end
            end
            query_edges(column.edge_index, left, top, right, bottom, cached.edges)
        end
    end
    return cached
end

function Graph.visible_nodes(layout, view, bounds, margin)
    return Graph.query_visible(layout, view, bounds, margin).nodes
end

function Graph.visible_edges(layout, view, bounds, margin)
    return Graph.query_visible(layout, view, bounds, margin).edges
end

return Graph

local Graph = dofile('src/ui/graph.lua')
local function near(a, b) assert(math.abs(a - b) < 0.000001, tostring(a) .. ' ~= ' .. tostring(b)) end
local rows = {
    {id = 1, parent = 0}, {id = 2, parent = 1},
    {id = 4, parent = 2}, {id = 5, parent = 2},
    {id = 3, parent = 1}, {id = 6, parent = 3},
}
local layout = Graph.layout(rows)
assert(#layout.nodes == 6 and #layout.edges == 5)
near(layout.node_w / layout.node_h, 71 / 95) -- Preserve the native card silhouette.
assert(layout.by_id[1].x < layout.by_id[2].x and layout.by_id[2].x < layout.by_id[4].x)
near(layout.by_id[2].x, layout.by_id[3].x)
near(layout.by_id[2].cy, (layout.by_id[4].cy + layout.by_id[5].cy) / 2)
near(layout.by_id[1].cy, (layout.by_id[2].cy + layout.by_id[3].cy) / 2)
assert(rows[1].x == nil and rows[1].depth == nil, 'layout never mutates decision data')
for i, a in ipairs(layout.nodes) do
    for j = i + 1, #layout.nodes do
        local b = layout.nodes[j]
        assert(a.x + a.w <= b.x or b.x + b.w <= a.x or a.y + a.h <= b.y or b.y + b.h <= a.y,
            'cards must not overlap')
    end
end
for _, edge in ipairs(layout.edges) do
    local parent, child = layout.by_id[edge.parent], layout.by_id[edge.child]
    near(edge.points[1], parent.x + parent.w)
    near(edge.points[2], parent.cy)
    near(edge.points[#edge.points - 1], child.x)
    near(edge.points[#edge.points], child.cy)
    for i = 1, #edge.points - 2, 2 do
        local x1, y1, x2, y2 = edge.points[i], edge.points[i + 1], edge.points[i + 2], edge.points[i + 3]
        assert(x1 == x2 or y1 == y2, 'connectors are orthogonal')
        for _, node in ipairs(layout.nodes) do
            if x1 == x2 then
                assert(not (x1 > node.x and x1 < node.x + node.w
                    and math.max(y1, y2) > node.y and math.min(y1, y2) < node.y + node.h),
                    'vertical connector may not cross card interior')
            else
                assert(not (y1 > node.y and y1 < node.y + node.h
                    and math.max(x1, x2) > node.x and math.min(x1, x2) < node.x + node.w),
                    'horizontal connector may not cross card interior')
            end
        end
    end
end
local bounds = {x = 70, y = 90, w = 900, h = 600}
local view = Graph.new_view(900, 600, layout)
Graph.focus_node(view, layout.by_id[4], bounds)
local sx, sy = Graph.world_to_screen(view, layout.by_id[4].cx, layout.by_id[4].cy, bounds)
near(sx, bounds.x + bounds.w / 2); near(sy, bounds.y + bounds.h / 2)
assert(Graph.hit_test(layout, view, sx, sy, bounds).id == 4)
assert(Graph.hit_test(layout, view, bounds.x - 1, sy, bounds) == nil)
assert(Graph.node_visible(layout.by_id[4], view, bounds))
local old_x, old_y = view.pan_x, view.pan_y
Graph.reveal_node(view, layout.by_id[4], bounds)
near(view.pan_x, old_x); near(view.pan_y, old_y)
local narrow = {x = bounds.x, y = bounds.y, w = 230, h = bounds.h}
Graph.reveal_node(view, layout.by_id[4], narrow)
local visible_x, visible_y = Graph.world_to_screen(view, layout.by_id[4].x, layout.by_id[4].y, narrow)
assert(visible_x >= narrow.x + 19 and visible_x + layout.by_id[4].w * view.scale <= narrow.x + narrow.w - 19)
near(view.pan_y, old_y)
Graph.focus_node(view, layout.by_id[4], bounds)
local anchor_x, anchor_y = 277, 362
local wx, wy = Graph.screen_to_world(view, anchor_x, anchor_y, bounds)
Graph.zoom(view, 1.25, anchor_x, anchor_y, bounds)
local after_x, after_y = Graph.screen_to_world(view, anchor_x, anchor_y, bounds)
near(wx, after_x); near(wy, after_y)
Graph.zoom(view, 100, anchor_x, anchor_y, bounds)
near(view.scale, Graph.MAX_SCALE)
after_x, after_y = Graph.screen_to_world(view, anchor_x, anchor_y, bounds)
near(wx, after_x); near(wy, after_y)
Graph.zoom(view, 0.00001, anchor_x, anchor_y, bounds)
near(view.scale, Graph.MIN_SCALE)
after_x, after_y = Graph.screen_to_world(view, anchor_x, anchor_y, bounds)
near(wx, after_x); near(wy, after_y)
-- Minimap wheel zoom preserves a non-central graph-world point's existing
-- main-canvas projection; it must not jump that point to the canvas centre.
local map_view = {width = bounds.w, height = bounds.h, pan_x = 74, pan_y = -38, scale = 0.8}
local map_world_x, map_world_y = layout.width * 0.23, layout.height * 0.67
local projected_x, projected_y = Graph.world_to_screen(map_view, map_world_x, map_world_y, bounds)
assert(math.abs(projected_x - (bounds.x + bounds.w / 2)) > 20)
Graph.zoom_world(map_view, 1.4, map_world_x, map_world_y, bounds)
near(map_view.scale, 1.12)
after_x, after_y = Graph.world_to_screen(map_view, map_world_x, map_world_y, bounds)
near(projected_x, after_x); near(projected_y, after_y)
Graph.zoom_world(map_view, 1000, map_world_x, map_world_y, bounds)
near(map_view.scale, Graph.MAX_SCALE)
after_x, after_y = Graph.world_to_screen(map_view, map_world_x, map_world_y, bounds)
near(projected_x, after_x); near(projected_y, after_y)
local clamped_pan_x, clamped_pan_y = map_view.pan_x, map_view.pan_y
Graph.zoom_world(map_view, 3, map_world_x, map_world_y, bounds)
near(map_view.pan_x, clamped_pan_x); near(map_view.pan_y, clamped_pan_y)
Graph.zoom_world(map_view, 0.000000001, map_world_x, map_world_y, bounds)
near(map_view.scale, Graph.MIN_SCALE)
after_x, after_y = Graph.world_to_screen(map_view, map_world_x, map_world_y, bounds)
near(projected_x, after_x); near(projected_y, after_y)
map_view.pan_x, map_view.pan_y, map_view.scale = -10000, 20000, 0.8
projected_x, projected_y = Graph.world_to_screen(map_view, map_world_x, map_world_y, bounds)
assert(projected_x < bounds.x and projected_y > bounds.y + bounds.h)
Graph.zoom_world(map_view, 0.7, map_world_x, map_world_y, bounds)
after_x, after_y = Graph.world_to_screen(map_view, map_world_x, map_world_y, bounds)
near(projected_x, after_x); near(projected_y, after_y)
assert(not pcall(Graph.zoom_world, map_view, 1.1, 0/0, 1, bounds))
local deep = {}
for i = 1, 10000 do deep[i] = {id = i, parent = i == 1 and 0 or i - 1} end
local deep_layout = Graph.layout(deep)
assert(#deep_layout.nodes == 10000 and #deep_layout.edges == 9999)
assert(deep_layout.by_id[10000].depth == 9999)
near(deep_layout.by_id[10000].y, deep_layout.by_id[1].y)
Graph.fit(view, deep_layout, bounds)
near(view.scale, Graph.MIN_SCALE)
local wide = {{id = 1, parent = 0}}
for i = 2, 1001 do wide[#wide + 1] = {id = i, parent = 1} end
local wide_layout = Graph.layout(wide, {node_w = 180, node_h = 220, gap_x = 80, gap_y = 50, padding = 16})
for i = 3, 1001 do
    assert(wide_layout.by_id[i].y >= wide_layout.by_id[i - 1].y + 220 + 50)
end
near(wide_layout.by_id[1].cy, (wide_layout.by_id[2].cy + wide_layout.by_id[1001].cy) / 2)
local empty = Graph.layout({})
assert(empty.width == 0 and empty.height == 0)
assert(Graph.new_view(800, 600, empty).scale == 1)
assert(not pcall(Graph.layout, {{id = 1, parent = 2}, {id = 2, parent = 1}}))
assert(not pcall(Graph.layout, {{id = 1, parent = 999}}))
assert(not pcall(Graph.layout, {{id = 1, parent = 0}, {id = 1, parent = 0}}))

-- Each collapsed linear interval supplies its own visible boundary pair and
-- exact card bounding box; adjacent intervals never become one large region.
local projected = {{id = 1, parent = 0}, {id = 4, parent = 1}, {id = 8, parent = 4}, {id = 9, parent = 1}}
projected.fold_regions = {
    {id = 11, start_id = 1, end_id = 4, label = 'Opening', hidden_count = 2, collapsed = true},
    {id = 12, start_id = 4, end_id = 8, label = 'Middle', hidden_count = 3, collapsed = true},
    {id = 13, start_id = 9, label = 'Legacy suworldline', collapsed = false},
}
local projected_layout = Graph.layout(projected)
assert(#projected_layout.fold_regions == 2)
for index, region in ipairs(projected_layout.fold_regions) do
    local source = projected.fold_regions[index]
    local a, b = projected_layout.by_id[region.start_id], projected_layout.by_id[region.end_id]
    assert(region ~= source and region.id == source.id and region.hidden_count == source.hidden_count)
    assert(region.x == math.min(a.x, b.x) and region.y == math.min(a.y, b.y))
    assert(region.x + region.w == math.max(a.x + a.w, b.x + b.w)
        and region.y + region.h == math.max(a.y + a.h, b.y + b.h))
    assert(source.x == nil, 'layout never mutates fold presentation metadata')
end
assert(projected_layout.fold_regions[1].end_id == projected_layout.fold_regions[2].start_id)

-- Indexed culling must agree exactly with full scans for both dimensions,
-- deep chains, wide branches and partially visible orthogonal connectors.
for _, sample in ipairs({layout, deep_layout, wide_layout, empty}) do
    for _, scale in ipairs({0.25, 0.73, 1.6}) do
        for _, location in ipairs({-0.2, 0, 0.45, 0.9, 1.3}) do
            local camera = {width = bounds.w, height = bounds.h, scale = scale,
                pan_x = -sample.width * location * scale, pan_y = -sample.height * location * scale}
            local found = Graph.query_visible(sample, camera, bounds, 25)
            assert(found == Graph.query_visible(sample, camera, bounds, 25), 'unchanged viewport uses cached visibility')
            local nodes, edges = {}, {}
            for _, node in ipairs(found.nodes) do nodes[node.id] = true end
            for _, edge in ipairs(found.edges) do edges[edge.child] = true end
            for _, node in ipairs(sample.nodes) do
                assert((nodes[node.id] == true) == Graph.node_visible(node, camera, bounds, 25), 'indexed node culling mismatch')
            end
            for _, edge in ipairs(sample.edges) do
                assert((edges[edge.child] == true) == Graph.edge_visible(edge, camera, bounds, 25), 'indexed edge culling mismatch')
            end
        end
    end
end
print('PASS graph: iterative deep/wide layout, orthogonal connectors, no overlap, viewport hit/zoom/focus')

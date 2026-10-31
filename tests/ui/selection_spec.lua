local Selection = dofile('src/ui/selection.lua')
local Graph = dofile('src/ui/graph.lua')
local rows = {
    {id = 1, parent = 0}, {id = 2, parent = 1}, {id = 3, parent = 2},
    {id = 4, parent = 2}, {id = 5, parent = 4}, {id = 6, parent = 1},
}
local tree = {get = function(_, id) return rows[id] end}
local layout = Graph.layout(rows)
local state = {detail_tab = 'overview'}
local function order(expected)
    assert(table.concat(state.selection_order, ',') == expected)
    for _, id in ipairs(state.selection_order) do assert(state.selections[id]) end
end
Selection.click(state, 2, false, false, tree, layout)
order('2'); assert(state.selected == 2 and state.selection_anchor == 2 and not state.compare_ids)
Selection.click(state, 5, true, false, tree, layout)
order('2,5'); assert(state.selected == 5 and state.detail_tab == 'diff'
    and state.compare_ids[1] == 2 and state.compare_ids[2] == 5)
Selection.click(state, 5, true, false, tree, layout)
order('2'); assert(state.selected == 2 and state.detail_tab == 'overview')
Selection.click(state, 3, false, false, tree, layout)
Selection.click(state, 5, false, true, tree, layout)
order('3,2,4,5'); assert(state.selection_anchor == 3 and state.selected == 5)
Selection.click(state, 6, false, true, tree, layout)
order('3,2,1,6'); assert(state.selection_anchor == 3, 'repeated Shift retains its first anchor')
Selection.click(state, 5, true, true, tree, layout)
order('3,2,1,6,4,5')
local visible = Graph.layout({rows[1], {id = 3, parent = 1}, {id = 5, parent = 3}, rows[6]})
local path = Selection.path(tree, visible, 3, 5)
assert(table.concat(path, ',') == '3,5', 'folded nodes are omitted without changing real ancestry')
Selection.prune(state, visible)
order('3,1,6,5'); assert(not state.selections[2] and not state.selections[4])

local n = layout.by_id[4]
local found = Selection.in_rect(layout, {x = n.x + 1, y = n.y + 1, w = n.w - 2, h = n.h - 2})
assert(#found == 1 and found[1] == 4)
Selection.box(state, found, {1}, true)
order('1,4'); assert(state.selected == 4 and state.compare_ids)
Selection.box(state, {5}, {1}, true)
order('1,5'); assert(not state.selections[4], 'each drag recomputes from its frozen initial selection')
Selection.box(state, {}, {}, false)
order(''); assert(not state.selected and not state.compare_ids)
Selection.click(state, nil, true, false, tree, layout); order('')
Selection.set(state, {2,2,5}, 2, 2); order('2,5')
local revision = state.selection_revision
local old_selections, old_order, old_pair = state.selections, state.selection_order, state.compare_ids
Selection.set(state, {2,5}, 2, 2)
assert(state.selection_revision == revision and state.selections == old_selections
    and state.selection_order == old_order and state.compare_ids == old_pair,
    'unchanged selection does not invalidate renderer caches')
Selection.set(state, {5,2}, 2, 2); order('5,2')
assert(state.compare_ids[1] == 5 and state.compare_ids[2] == 2, 'comparison direction is ordered')
assert(tree:get(2).parent == 1 and not tree.current, 'selection never mutates gameplay or the tree cursor')
print('PASS selection: single/Ctrl/Shift tree paths, clipped visibility, immutable box baseline, ordered comparison')

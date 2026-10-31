local Tree = dofile('src/domain/tree.lua')
local Codec = dofile('src/storage/codec.lua')
local function snapshot(id) return {seed = 'NAVTEST', content = id} end
local tree = Tree.new(snapshot(1), {run_id = 'navigation', seed = 'NAVTEST'})
local function append(parent, id)
    tree:checkout(parent)
    return tree:commit({kind = 'phase', choices = {{kind = 'buy', card_key = 'j_joker'}}}, snapshot(id), {state = 'SHOP'})
end
append(1, 2); append(2, 3); append(3, 4); append(2, 5); append(5, 6); append(1, 7)
local original = tree:export()
assert(tree:set_bookmark(4, '  决战前  '))
assert(tree.annotations.bookmarks[4] == '决战前')
assert(not tree:set_bookmark(4, '决战前'))
assert(tree:set_bookmark(6, 'Shopping plan B'))
assert(#tree:bookmark_rows() == 2 and tree:bookmark_rows()[1].node_id == 4)
assert(not pcall(tree.set_bookmark, tree, 9, 'missing'))
assert(not pcall(tree.set_bookmark, tree, 1, ''))
assert(not pcall(tree.set_bookmark, tree, 1, 'line\nbreak'))
assert(not pcall(tree.set_bookmark, tree, 1, string.rep('a', 65)))
assert(not pcall(tree.set_bookmark, tree, 1, '\192\128'))
assert(not pcall(tree.set_bookmark, tree, 1, '\237\160\128'))
assert(not pcall(tree.set_bookmark, tree, 1, '\244\144\128\128'))
assert(tree:set_bookmark(1, string.rep('牌', 64)))

assert(not pcall(tree.add_fold, tree, 1, 4, 'Cannot hide branching point 2'))
local fold = tree:add_fold(2, 4, '起手路线')
local rows = tree:visible_rows()
assert(rows == tree:visible_rows(), 'unchanged presentation rows are cached')
local seen = {}; for _, row in ipairs(rows) do seen[row.id] = row end
assert(seen[2] and not seen[3] and seen[4] and seen[5] and seen[6] and seen[7])
assert(seen[4].parent == 2 and seen[4].source_parent == 3 and seen[4].hidden_steps == 1)
assert(seen[5].parent == 2 and seen[5].source_parent == 2 and seen[5].hidden_steps == 0,
    'a branching boundary remains visible and other branches keep their actual parent')
assert(seen[6].parent == 5 and seen[2].collapsed_count == 1 and seen[4].bookmark == '决战前')
assert(#rows.fold_regions == 1 and rows.fold_regions[1].start_id == 2
    and rows.fold_regions[1].end_id == 4 and rows.fold_regions[1].hidden_count == 1)
assert(tree.nodes[4].parent == 3 and #tree.nodes[2].children == 2, 'folds never modify graph history')
assert(not pcall(tree.add_fold, tree, 4, 1, 'reversed'))
assert(not pcall(tree.add_fold, tree, 1, 2, 'no intermediate'))
assert(not pcall(tree.add_fold, tree, 4, nil, 'leaf'))
assert(tree:reveal_node(3) and not tree.annotations.folds[fold].collapsed)
assert(#tree:visible_rows() == 7 and not tree:reveal_node(3))
assert(not pcall(tree.add_fold, tree, 1, nil, 'Ambiguous branch'))
assert(tree:add_fold(4, 2, 'Renamed') == fold and #tree:fold_rows() == 1,
    'selecting the same linear endpoints in reverse order reuses the normalized region')
tree:reveal_node(3)
local other = tree:add_fold(2, 6, 'Parallel linear region')
tree:set_fold_collapsed(fold, true)
assert(#tree:visible_rows() == 5 and #tree:visible_rows().fold_regions == 2,
    'disjoint linear regions with a shared boundary remain separate')
assert(tree:reveal_node(3) and tree.annotations.folds[other].collapsed)
assert(tree:remove_fold(other) and not tree:remove_fold(other))

local frozen = tree:export_save_view()
tree:set_bookmark(4, 'Changed later')
tree:set_fold_collapsed(fold, true)
assert(frozen.annotations.bookmarks[4] == '决战前' and not frozen.annotations.folds[fold].collapsed,
    'in-flight asynchronous exports freeze mutable annotation data')
tree.resume = {parent = tree.current, snapshot = snapshot(8), summary = {}, choices = {{kind = 'reroll_shop'}}}
assert(tree:export_save_view().resume.choices[1].kind == 'reroll_shop')
local checkpoint_view, isolated_checkpoint = tree:undo_checkpoint_view(), tree:undo_checkpoint()
assert(checkpoint_view.resume ~= tree.resume and checkpoint_view.resume.snapshot == tree.resume.snapshot)
assert(isolated_checkpoint.resume.snapshot ~= tree.resume.snapshot)
local retained_resume = tree.resume
tree.resume = {parent = tree.current, snapshot = snapshot(999), summary = {}, choices = {{kind = 'buy'}}}
assert(checkpoint_view.resume.snapshot.content == 8 and checkpoint_view.resume.choices[1].kind == 'reroll_shop',
    'new actions replace resume shells/immutable choice arrays without changing retained Undo state')
tree:restore_cursor(checkpoint_view)
assert(tree.resume.snapshot.content == 8 and tree.resume.snapshot ~= checkpoint_view.resume.snapshot,
    'restoring an internal checkpoint still copies its data before exposing it as live resume')
tree.resume = retained_resume
local encoded = Codec.encode(tree:export(), TEST_JSON)
local restored = assert(Tree.import(assert(Codec.decode(encoded, TEST_JSON))))
assert(restored.annotations.bookmarks[4] == 'Changed later' and restored.annotations.folds[fold].collapsed)
assert(restored.resume.choices[1].kind == 'reroll_shop' and #restored:visible_rows() == 6)
local old = tree:export(); old.annotations = nil
local imported_old = assert(Tree.import(old))
assert(#imported_old:bookmark_rows() == 0 and #imported_old:fold_rows() == 0)
local invalid = tree:export(); invalid.annotations.bookmarks[500] = 'missing'
assert(not Tree.import(invalid))
invalid = tree:export(); invalid.annotations.folds[fold].end_id = 7
local incompatible = assert(Tree.import(invalid))
assert(not incompatible.annotations.folds[fold].collapsed and not incompatible:fold_rows()[1].available,
    'legacy incompatible paths are retained but safely expanded instead of rejecting the archive')

-- One-step Undo removes just annotations targeting its pruned suffix. If the
-- player enables continuous Undo, restoring that suffix also restores notes.
tree:checkout(6)
local checkpoint = tree:undo_checkpoint()
append(6, 8); append(8, 9)
tree:set_bookmark(8, 'Retained future')
local suffix_fold = tree:add_fold(6, 9, 'Later sequence')
local _, tail = tree:rollback(checkpoint, true)
assert(not tree.annotations.bookmarks[8] and not tree.annotations.folds[suffix_fold])
assert(tree.annotations.bookmarks[4] == 'Changed later')
tree:set_bookmark(4, 'Edited while rewound')
assert(tree:restore_tail(tail))
assert(tree.annotations.bookmarks[8] == 'Retained future' and tree.annotations.folds[suffix_fold])
assert(tree.annotations.bookmarks[4] == 'Edited while rewound', 'tail recovery never replaces current prefix annotations')
local serial = tree.annotation_revision
tree:restore_cursor(checkpoint)
assert(tree.annotation_revision == serial and tree.annotations.bookmarks[8], 'continuous Undo keeps all annotations')
for id = 1, 7 do
    assert(tree.nodes[id].snapshot.content == original.nodes[id].snapshot.content)
    assert(tree.nodes[id].parent == original.nodes[id].parent)
end

local chain = Tree.new(snapshot(1), {run_id = 'linear-folds', seed = 'NAVTEST'})
for id = 2, 9 do chain:commit({kind = 'phase'}, snapshot(id), {}) end
local automatic = chain:add_fold(1, nil, 'To the nearest leaf')
assert(chain.annotations.folds[automatic].end_id == 9)
assert(#chain:visible_rows() == 2 and chain:visible_rows()[1].id == 1 and chain:visible_rows()[2].id == 9)
assert(not pcall(chain.add_fold, chain, 2, 8, 'Overlapping region'))
assert(chain:fold_rows()[1].available and chain:fold_rows()[1].hidden_count == 7)
chain:set_fold_collapsed(automatic, false)
local first_half = chain:add_fold(1, 5, 'First half')
local second_half = chain:add_fold(5, 9, 'Second half')
assert(#chain:visible_rows() == 3 and #chain:visible_rows().fold_regions == 2)
local outer_row = chain:fold_rows()[1]
assert(not outer_row.available and outer_row.reason_code == 'overlap')
assert(not pcall(chain.set_fold_collapsed, chain, automatic, true), 're-collapsing must not hide another region boundary')
local older = chain:export()
older.annotations.folds[automatic].collapsed = true
local normalized = assert(Tree.import(older))
assert(normalized.annotations.folds[automatic].collapsed
    and not normalized.annotations.folds[first_half].collapsed and not normalized.annotations.folds[second_half].collapsed,
    'legacy overlapping active regions resolve deterministically without merging their records')
assert(#normalized:visible_rows().fold_regions == 1)
chain:checkout(3)
chain:commit({kind = 'alternate'}, snapshot(10), {})
assert(not chain.annotations.folds[first_half].collapsed and chain.annotations.folds[second_half].collapsed,
    'creating an interior branch immediately expands only the affected region')
assert(chain:fold_rows()[2].reason_code == 'branch' and not chain:fold_rows()[2].available)
local branch_rows = {}; for _, row in ipairs(chain:visible_rows()) do branch_rows[row.id] = row end
assert(branch_rows[3] and branch_rows[4] and branch_rows[10] and not branch_rows[6])
assert(not pcall(chain.add_fold, chain, 1, 5, 'Cannot hide new branch'))
local short_auto = chain:add_fold(1, nil, 'Until nearest branch')
assert(chain.annotations.folds[short_auto].end_id == 3, 'automatic range stops at a branch boundary')

local legacy = chain:export()
legacy.annotations.folds[automatic] = {id = automatic, start_id = 1, label = 'Old suworldline', collapsed = true}
legacy.annotations.folds[first_half].collapsed = true
local legacy_import = assert(Tree.import(legacy))
assert(not legacy_import.annotations.folds[automatic].collapsed and not legacy_import.annotations.folds[first_half].collapsed)
assert(legacy_import:fold_rows()[1].reason_code == 'missing_end' and legacy_import:fold_rows()[2].reason_code == 'branch')
assert(#legacy_import:rows() == 10, 'old fold incompatibility never removes historical nodes')
assert(not pcall(legacy_import.set_fold_collapsed, legacy_import, automatic, true))
local roundtrip = assert(Tree.import(assert(Codec.decode(Codec.encode(legacy_import:export(), TEST_JSON), TEST_JSON))))
assert(roundtrip.annotations.folds[automatic].label == 'Old suworldline' and roundtrip:fold_rows()[1].reason_code == 'missing_end')

-- Tail reattachment may restore a branch inside a fold created while rewound.
local forked = Tree.new(snapshot(1), {run_id = 'tail-fold', seed = 'NAVTEST'})
for id = 2, 4 do forked:commit({kind = 'phase'}, snapshot(id), {}) end
local before_fork = forked:undo_checkpoint()
forked:checkout(2); forked:commit({kind = 'alternate'}, snapshot(5), {})
local _, fork_tail = forked:rollback(before_fork, true)
local new_fold = forked:add_fold(1, 4, 'Created without the branch')
assert(forked:restore_tail(fork_tail))
assert(not forked.annotations.folds[new_fold].collapsed and #forked:visible_rows() == 5,
    'recovering historical branches also expands incompatible linear folds')
print('PASS navigation: named bookmarks, linear endpoint folds, branch/overlap protection, legacy compatibility, Undo recovery')

local Tree = dofile("src/domain/tree.lua")
local function state(dollars) return {seed = "SAME", save = {GAME = {dollars = dollars}}} end
local initial = state(4)
local tree = Tree.new(initial, {seed = "SAME", run_id = "unit"})
initial.save.GAME.dollars = 100
assert(tree:peek(1).save.GAME.dollars == 4)
local first = tree:commit({kind = "buy"}, state(0), {dollars = 0})
tree:commit({kind = "sell"}, state(2), {})
assert(tree.current == 3)
tree:checkout(1)
tree:commit({kind = "reroll"}, state(3), {})
assert(tree.current == 4 and #tree:get(1).children == 2 and tree:get(3).parent == first.id)
local viewed = tree:peek(2)
viewed.save.GAME.dollars = 900
assert(tree:peek(2).save.GAME.dollars == 0)
local rows = tree:rows()
assert(rows[1].id == 1 and rows[2].id == 2 and rows[3].id == 3 and rows[4].id == 4)
assert(rows[3].depth == 2 and rows[4].depth == 1)
local exported = tree:export()
local restored = assert(Tree.import(exported))
assert(restored.current == 4 and restored.next_id == 5 and #restored:get(1).children == 2)
exported.nodes[2].parent = 4
assert(not Tree.import(exported), "cycles/backward parent references must fail")
local bad = tree:export()
bad.nodes[1].children[2] = 2
assert(not Tree.import(bad), "repeated child references must fail")
bad = tree:export(); bad.nodes[2].snapshot.seed = "OTHER"
assert(not Tree.import(bad), "one tree cannot contain different seeds")
local before = tree.next_id
assert(not pcall(function() tree:commit({kind = "bad"}, {seed = "OTHER"}, {}) end))
assert(tree.next_id == before)
tree.resume = {parent = tree.current, snapshot = state(17), summary = {dollars = 17}}
local resumed = assert(Tree.import(tree:export()))
assert(resumed.resume.parent == 4 and resumed.resume.snapshot.save.GAME.dollars == 17)
assert(#resumed:rows() == 4, "in-phase progress must not add a public tree node")
local wrong_parent = tree:export(); wrong_parent.resume.parent = 1
assert(not Tree.import(wrong_parent))
resumed:checkout(1)
assert(resumed.resume == nil)
local rollback_point = tree:undo_checkpoint()
tree:commit({kind = 'next_round'}, state(11), {})
tree:checkout(1)
tree:commit({kind = 'skip'}, state(13), {})
tree.metadata.progress_locked = true
assert(tree.next_id == 7)
tree:rollback(rollback_point)
assert(tree.current == 4 and tree.next_id == 5 and #tree:get(1).children == 2)
assert(tree:get(2) and tree:get(3) and tree:get(4) and not tree:get(5) and not tree:get(6))
assert(#tree:get(4).children == 0 and tree.resume.snapshot.save.GAME.dollars == 17)
assert(tree.metadata.progress_locked and Tree.import(tree:export()), 'Undo preserves eligibility lock and valid structure')
rollback_point.resume.snapshot.save.GAME.dollars = 999
assert(tree.resume.snapshot.save.GAME.dollars == 17, 'restored private progress is isolated')
assert(not pcall(tree.rollback, tree, {run_id = 'other', current = 1, next_id = 2}))
assert(tree.current == 4 and tree.next_id == 5, 'invalid rollback cannot mutate a tree')
local view = tree:export_view()
assert(view.nodes[1] == tree:get(1) and view.metadata == tree.metadata and view.resume == tree.resume,
    'the internal synchronous encoding view does not copy immutable checkpoints')
local public = tree:export()
public.metadata.seed, public.nodes[1].snapshot.save.GAME.dollars, public.resume.snapshot.save.GAME.dollars = 'CHANGED', -1, -1
assert(tree.metadata.seed == 'SAME' and tree:get(1).snapshot.save.GAME.dollars == 4
    and tree.resume.snapshot.save.GAME.dollars == 17, 'public exports remain deeply isolated')

local function same(a, b)
    assert(type(a) == type(b))
    if type(a) ~= 'table' then assert(a == b); return end
    for k, v in pairs(a) do same(v, b[k]) end
    for k in pairs(b) do assert(a[k] ~= nil) end
end
local function tail_fixture()
    local t = Tree.new(state(4), {seed = 'SAME', run_id = 'tail'})
    assert(t.structure_revision == 0)
    local root_checkpoint = t:undo_checkpoint()
    t:commit({kind = 'blind'}, state(5), {})
    t.resume = {parent = 2, snapshot = state(6), summary = {dollars = 6}}
    local checkpoint = t:undo_checkpoint()
    local suffix = t:commit({kind = 'shop'}, state(7), {})
    t:checkout(1)
    t:commit({kind = 'skip'}, state(8), {})
    local revision = t.structure_revision
    local ok, stash = t:rollback(checkpoint, true)
    assert(ok and stash and t.structure_revision == revision + 1)
    assert(t.next_id == 3 and t.current == 2 and not t:get(3) and not t:get(4))
    assert(stash.nodes[3] == suffix and stash.nodes[3].snapshot == suffix.snapshot,
        'stash retains immutable suffix snapshots without copying their game data')
    assert(stash.parents[1].kept ~= t:get(1).children and stash.parents[1].original ~= t:get(1).children,
        'the stash owns its boundary-link arrays before prefix links mutate')
    return t, checkpoint, root_checkpoint, stash
end
local tail, checkpoint, root_checkpoint, stash = tail_fixture()
tail.metadata.progress_locked, tail.metadata.continuous_undo = true, true
tail:restore_cursor(root_checkpoint)
local held_resume = {parent = 1, snapshot = state(9), summary = {dollars = 9}}
tail.resume = held_resume
local cursor_revision = tail.structure_revision
assert(tail:restore_tail(stash))
assert(tail.current == 1 and tail.resume == held_resume and tail.next_id == 5,
    'reattaching history preserves the actual current operation and resume')
assert(tail:get(1).children[1] == 2 and tail:get(1).children[2] == 4
    and tail:get(2).children[1] == 3 and tail:get(3).parent == 2)
assert(tail.metadata.progress_locked and tail.metadata.continuous_undo)
assert(tail.structure_revision == cursor_revision + 1 and Tree.import(tail:export()))
assert(not pcall(tail.restore_tail, tail, stash), 'a tail can only be reattached once')
assert(tail:restore_cursor(checkpoint) and tail.current == 2 and tail.next_id == 5
    and tail.resume.snapshot.save.GAME.dollars == 6, 'old operation checkpoints move the cursor without deleting later branches')
assert(tail.structure_revision == cursor_revision + 1, 'cursor-only restores need no structural layout invalidation')
checkpoint.resume.snapshot.save.GAME.dollars = 999
assert(tail.resume.snapshot.save.GAME.dollars == 6)
tail:commit({kind = 'alternate'}, state(10), {})
assert(tail.current == 5 and tail:get(2).children[2] == 5 and tail:get(3), 'continuing after historical Undo adds a parallel branch')
local wire = tail:export()
assert(wire.structure_revision == nil and Tree.import(wire).structure_revision == 0,
    'runtime cache revisions do not change archive or sharing format')

-- Conflicts, modified link arrays and malformed suffixes fail before changing
-- any live current/resume, node, child link, revision or metadata.
for _, corrupt in ipairs({
    function(_, s) s.nodes[3] = nil end,
    function(_, s) s.nodes[3].parent = 0 end,
    function(_, s) s.parents[1].original = {2, 2} end,
    function(_, s) s.expected_revision = s.expected_revision - 1 end,
    function(_, s) s.owner = {} end,
}) do
    local t, _, _, s = tail_fixture()
    corrupt(t, s)
    local before, before_revision = t:export(), t.structure_revision
    assert(not pcall(t.restore_tail, t, s))
    same(before, t:export()); assert(before_revision == t.structure_revision)
end
local replaced, _, _, old_tail = tail_fixture()
local before_revision, same_count = replaced.structure_revision, replaced.next_id
local new_node = replaced:commit({kind = 'replacement'}, state(42), {})
assert(replaced.current == 3 and replaced.next_id == same_count + 1 and replaced.structure_revision > before_revision)
local before_restore = replaced:export()
assert(not pcall(replaced.restore_tail, replaced, old_tail))
same(before_restore, replaced:export()); assert(replaced:get(3) == new_node, 'stale tails never overwrite reused IDs')
local revision_fixture, original_checkpoint = tail_fixture()
local initial_revision = revision_fixture.structure_revision
revision_fixture:commit({kind = 'same_size_old'}, state(30), {})
local cached_count, cached_revision = revision_fixture.next_id, revision_fixture.structure_revision
revision_fixture:rollback(original_checkpoint)
revision_fixture:commit({kind = 'same_size_new'}, state(31), {})
assert(revision_fixture.next_id == cached_count and revision_fixture.structure_revision > cached_revision
    and revision_fixture.structure_revision > initial_revision, 'same-sized replacement history invalidates cached layouts')
local bad_cursor = revision_fixture:undo_checkpoint()
bad_cursor.resume = {parent = bad_cursor.current, snapshot = state(3), summary = {}}
bad_cursor.resume.summary.loop = bad_cursor.resume
local before_cursor, before_cursor_revision = revision_fixture:export(), revision_fixture.structure_revision
assert(not pcall(revision_fixture.restore_cursor, revision_fixture, bad_cursor))
same(before_cursor, revision_fixture:export()); assert(revision_fixture.structure_revision == before_cursor_revision)

-- Matching is opt-in and only checks children of the current checkpoint. It
-- reuses the first existing node without rewriting old summary/snapshot data.
local matching = Tree.new(state(4), {seed = 'SAME', run_id = 'matching'})
local buy = {kind = 'phase', order = 'buy,sell'}
local existing, reused = matching:commit(buy, state(9), {original = true})
assert(not reused)
matching:commit({kind = 'next'}, state(10), {})
matching:checkout(1)
local alternate = matching:commit({kind = 'phase', order = 'sell,buy'}, state(9), {})
matching:checkout(1)
matching.resume = {parent = 1, snapshot = state(5), summary = {}}
local before_match = matching:undo_checkpoint()
local before_match_revision, before_next = matching.structure_revision, matching.next_id
local calls = 0
local function matcher(old_action, old_snapshot, action, snapshot)
    calls = calls + 1
    return old_action.kind == action.kind and old_action.order == action.order
        and old_snapshot.save.GAME.dollars == snapshot.save.GAME.dollars
end
local reused_node, matched = matching:commit(buy, state(9), {replacement = true}, matcher)
assert(matched and reused_node == existing and matching.current == existing.id and matching.resume == nil)
assert(calls == 1 and matching.next_id == before_next and matching.structure_revision == before_match_revision)
assert(existing.summary.original and not existing.summary.replacement and #existing.children == 1)
local _, reused_tail = matching:rollback(before_match, true)
assert(not reused_tail and matching.current == 1 and matching.next_id == before_next
    and matching:get(existing.id) == existing and matching:get(alternate.id) == alternate,
    'one-action rollback after reuse must never prune an already-existing branch')
matching:commit(buy, state(9), {}, matcher)
local restored_revision = matching.structure_revision
matching:restore_cursor(before_match)
assert(matching.current == 1 and matching.next_id == before_next and matching:get(3)
    and matching.structure_revision == restored_revision, 'cursor Undo after reuse keeps the complete history')
local different, different_reused = matching:commit(buy, state(8), {}, matcher)
assert(not different_reused and different.id == before_next, 'same action with a different result creates a new branch')
matching:checkout(1)
matching.MAX_NODES = matching.next_id - 1
local at_limit, reused_at_limit = matching:commit(buy, state(9), {}, matcher)
assert(reused_at_limit and at_limit == existing, 'matching precedes the archive size limit')
matching:checkout(1)
assert(not pcall(matching.commit, matching, buy, state(7), {}, matcher))
local unchanged = matching:export()
assert(not pcall(matching.commit, matching, buy, state(9), {}, function() error('matcher failure') end))
same(unchanged, matching:export())
matching.MAX_NODES = Tree.MAX_NODES
local duplicate, no_matcher_reuse = matching:commit(buy, state(9), {})
assert(not no_matcher_reuse and duplicate.id ~= existing.id, 'callers without a matcher preserve append-only behavior')
matching:checkout(1)
local first_match = matching:commit(buy, state(9), {}, matcher)
assert(first_match == existing and matching:get(duplicate.id), 'existing duplicate history is never retroactively merged')
print("PASS tree: immutable checkpoints, safe tail/cursor Undo, opt-in branch reuse, atomic conflicts, runtime cache revisions")

local Progress = dofile('src/domain/progress.lua')
local Tree = dofile('src/domain/tree.lua')
local function clone(value)
    if type(value) ~= 'table' then return value end
    local result = {}
    for key, item in pairs(value) do result[key] = clone(item) end
    return result
end
local function equal(a, b)
    if type(a) ~= type(b) then return false end
    if type(a) ~= 'table' then return a == b end
    for key, item in pairs(a) do if not equal(item, b[key]) then return false end end
    for key in pairs(b) do if a[key] == nil then return false end end
    return true
end
local function snapshot(seeded, id)
    return {seed = 'SAMESEED', save = {GAME = {seeded = seeded, worldline_run_id = id,
        pseudorandom = {seed = 'SAMESEED', stream = 0.217}, dollars = 10, challenge = nil}},
        extra = {state = 'BLIND_SELECT'}}
end
local original_random, original_G, original_SM = math.random, G, SMODS
math.random = function() error('Progress policy must not consume RNG') end
G = {PROFILES = {one = {unlocked = 10, discoveries = 7}}, SETTINGS = {achievements = true},
    F_NO_ACHIEVEMENTS = false, GAME = {seeded = false, unrelated = true}}
SMODS = {config = {seeded_unlocks = true, achievements = 3}}
local globals_before, settings_before = clone(G), clone(SMODS)

local root = snapshot(false, 'progress-run-one')
local tree = Tree.new(root, {seed = root.seed, run_id = 'progress-run-one'})
local live = clone(root.save.GAME)
local api = {tree = tree, game_ref = live}
local undo_tree = tree:export()
local undo_snapshot = tree:peek(1)

-- Passive recording, autosave/export serialization and Undo apply no lock.
local before = clone(tree:export())
local changed, locked = Progress.apply_live(api)
assert(not changed and not locked and live.seeded == false)
local same, snapshot_changed = Progress.apply_to_snapshot(undo_snapshot, tree)
assert(same == undo_snapshot and not snapshot_changed and undo_snapshot.save.GAME.seeded == false)
assert(equal(tree:export(), before), 'background policy must not touch progress or immutable data')
tree:commit({kind = 'enter_shop'}, snapshot(false, 'progress-run-one'), {})
assert(live.seeded == false and tree.metadata.progress_locked == nil,
    'recording a phase and serializing a tree do not count as active feature use')

-- A caller explicitly announces any capability other than Undo.
assert(Progress.lock(api))
assert(tree.metadata.progress_locked == true and live.seeded == true)
assert(not Progress.lock(api), 'locking is idempotent')
assert(root.save.GAME.seeded == false and tree:peek(1).save.GAME.seeded == false,
    'old stored snapshots remain immutable; only restore/export copies are patched')
assert(live.pseudorandom.seed == 'SAMESEED' and live.pseudorandom.stream == 0.217 and live.dollars == 10)
assert(live.challenge == nil, 'only native seeded is added, never challenge or global achievement flags')

-- Undo tries to bring back both old tree metadata and a seeded=false snapshot.
api.tree = assert(Tree.import(undo_tree))
assert(api.tree.metadata.progress_locked == nil)
same, snapshot_changed = Progress.apply_to_snapshot(undo_snapshot, api)
assert(same == undo_snapshot and snapshot_changed)
assert(undo_snapshot.save.GAME.seeded == true and api.tree.metadata.progress_locked == true,
    'Undo cannot remove a lock recorded later in the same run')
api.game_ref = clone(snapshot(false, 'progress-run-one').save.GAME)
changed, locked = Progress.apply_live(api)
assert(changed and locked and api.game_ref.seeded == true)
assert(not Progress.apply_live(api), 'reapplying an enforced live lock changes nothing')

-- Persisted metadata recovers the policy even in a newly loaded module/session.
local fresh = dofile('src/domain/progress.lua')
local imported = assert(Tree.import(api.tree:export()))
local restored = snapshot(false, 'progress-run-one')
assert(fresh.apply_to_snapshot(restored, imported) == restored)
assert(restored.save.GAME.seeded == true and imported.metadata.progress_locked)
local next_live = clone(snapshot(false, 'progress-run-one').save.GAME)
assert(fresh.apply_live(imported, next_live) and next_live.seeded == true)

-- A separate run with the same seed never inherits another run's policy.
local other = Tree.new(snapshot(false, 'progress-run-two'), {seed = 'SAMESEED', run_id = 'progress-run-two'})
local other_live = clone(snapshot(false, 'progress-run-two').save.GAME)
changed, locked = Progress.apply_live(other, other_live)
assert(not changed and not locked and other_live.seeded == false and other.metadata.progress_locked == nil)
local naturally_seeded = snapshot(true, 'progress-natural-seed')
local native_tree = Tree.new(naturally_seeded, {seed = 'SAMESEED', run_id = 'progress-natural-seed'})
local native_live = clone(naturally_seeded.save.GAME)
assert(not Progress.apply_live(native_tree, native_live) and native_live.seeded == true)
assert(native_tree.metadata.progress_locked == nil, 'native seeded is not an active Mod capability')
Progress.apply_to_snapshot(naturally_seeded, native_tree)
assert(naturally_seeded.save.GAME.seeded == true)

-- GAME-only use remains sticky for that object/run marker, without touching G.
local direct = {seeded = false, worldline_run_id = 'progress-direct'}
assert(Progress.lock(direct) and direct.seeded)
direct.seeded = false
assert(Progress.apply_live(direct) and direct.seeded)
local direct_tree = Tree.new(snapshot(false, 'progress-direct'), {seed = 'SAMESEED', run_id = 'progress-direct'})
local direct_copy = snapshot(false, 'progress-direct')
Progress.apply_to_snapshot(direct_copy, direct_tree)
assert(direct_tree.metadata.progress_locked and direct_copy.save.GAME.seeded)

-- Explicit GAME overrides stale API references; metadata-only preview can lock.
local preview = {metadata = {run_id = 'progress-preview', seed = 'SAMESEED'}}
assert(Progress.lock(preview) and preview.metadata.progress_locked)
local target = {seeded = false}
assert(Progress.apply_live(preview, target) and target.seeded)
local stale = {seeded = false}
local selected_game = {seeded = false}
assert(Progress.lock({tree = preview, game_ref = stale}, selected_game))
assert(selected_game.seeded and stale.seeded == false)
local not_bootstrapped = {core = Tree, game_ref = {seeded = false}}
local early_undo = {save = {GAME = {seeded = false}}}
assert(Progress.lock(not_bootstrapped))
Progress.apply_to_snapshot(early_undo, not_bootstrapped)
assert(early_undo.save.GAME.seeded == true, 'a pending tree still honors its explicitly locked live run')
not_bootstrapped.tree = {metadata = {run_id = 'progress-bootstrapped'}}
Progress.apply_live(not_bootstrapped)
assert(not_bootstrapped.tree.metadata.progress_locked, 'persist the early lock when the tree becomes available')
assert(not Progress.lock(nil))
local invalid = {seed = 'SAMESEED'}
assert(Progress.apply_to_snapshot(invalid, other) == invalid and invalid.save == nil)

assert(equal(G, globals_before), 'policy never reads or changes global game/profile progress')
assert(equal(SMODS, settings_before), 'native seeded treatment must honor user Steamodded settings')
math.random, G, SMODS = original_random, original_G, original_SM
print('PASS progress: Undo-only stays native; explicit capability lock survives rollback and persistence')

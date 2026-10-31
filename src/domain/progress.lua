-- Native progress policy: recording/Undo do nothing until an active feature
-- explicitly calls lock(). Once locked, only GAME.seeded is changed. Vanilla
-- checks this flag in check_for_unlock, unlock_card, discover_card, high scores
-- and inc_career_stat (Balatro 1.0.1o); user Steamodded settings stay untouched.
local Progress = {}

-- Undo can replace the whole tree with an earlier exported copy. Keep the
-- monotonic bit outside that copy, keyed by run_id, as well as in its metadata.
-- A seed is deliberately not a run identity: separate runs may share a seed.
local locked_runs = {}
local locked_objects = setmetatable({}, {__mode = 'k'})

local function run_id(value)
    return type(value) == 'string' and value ~= '' and value or nil
end

local function targets(source, explicit_game)
    if type(source) ~= 'table' then return nil, explicit_game end
    if type(source.metadata) == 'table' then return source, explicit_game end
    if source.tree ~= nil or source.game_ref ~= nil or source.core ~= nil or source.storage ~= nil then
        return type(source.tree) == 'table' and source.tree or nil,
            explicit_game or source.game_ref
    end
    return nil, explicit_game or source
end

local function ids(tree, game)
    return tree and tree.metadata and run_id(tree.metadata.run_id),
        type(game) == 'table' and run_id(game.worldline_run_id)
end

local function is_locked(tree, game)
    local tree_id, game_id = ids(tree, game)
    return not not (tree and tree.metadata and tree.metadata.progress_locked == true
        or tree_id and locked_runs[tree_id]
        or game_id and locked_runs[game_id]
        or tree and locked_objects[tree]
        or type(game) == 'table' and locked_objects[game])
end

local function remember(tree, game)
    local changed = false
    local tree_id, game_id = ids(tree, game)
    if tree_id then locked_runs[tree_id] = true end
    if game_id then locked_runs[game_id] = true end
    if tree then
        locked_objects[tree] = true
        if type(tree.metadata) == 'table' and tree.metadata.progress_locked ~= true then
            tree.metadata.progress_locked = true
            changed = true
        end
    end
    if type(game) == 'table' then
        locked_objects[game] = true
        if game.seeded ~= true then game.seeded = true; changed = true end
    end
    return changed
end

-- Accept API {tree=..., game_ref=...}, a tree plus explicit GAME, or GAME alone.
-- The caller supplies the current run; this module never guesses from global G.
-- Returns whether persistent metadata or GAME.seeded actually changed.
function Progress.lock(source, game)
    local tree, live = targets(source, game)
    return remember(tree, live)
end

-- Call after replacing an Undo tree/live GAME, including when its old metadata
-- says false. The remembered run_id restores the lock without locking new runs.
-- Native seeded runs remain seeded even if no Tree feature has been used.
function Progress.apply_live(source, game)
    local tree, live = targets(source, game)
    local locked = is_locked(tree, live)
    return locked and remember(tree, live) or false, locked
end

-- Mutate the caller's restore/export copy, not an immutable stored checkpoint.
-- Call before native loading so construction/discovery sees seeded=true too.
-- Returns the same snapshot and whether metadata or its GAME flag changed.
function Progress.apply_to_snapshot(snapshot, source)
    local tree, live = targets(source)
    local game = type(snapshot) == 'table' and type(snapshot.save) == 'table'
        and type(snapshot.save.GAME) == 'table' and snapshot.save.GAME or nil
    if not is_locked(tree, game) and not is_locked(tree, live) then return snapshot, false end
    return snapshot, remember(tree, game)
end

return Progress

-- Read-only, on-demand presentation of differences between two checkpoints.
local Loader
if SMODS and SMODS.load_file then
    Loader = assert(SMODS.load_file('loader.lua', 'WorldLine'))()
else
    Loader = dofile('src/loader.lua')
end
local module = Loader.load
local Details, Replay = module('details'), module('replay')
local Diff = {}
local function copy(value)
    if type(value) ~= 'table' then return value end
    local result = {}
    for key, item in pairs(value) do result[key] = copy(item) end
    return result
end
local function equal(a, b)
    if type(a) ~= type(b) then return false end
    if type(a) ~= 'table' then return a == b end
    for key, value in pairs(a) do
        if key ~= 'name' and key ~= 'atlas' and key ~= 'pos' and not equal(value, b[key]) then return false end
    end
    for key in pairs(b) do
        if key ~= 'name' and key ~= 'atlas' and key ~= 'pos' and a[key] == nil then return false end
    end
    return true
end
local function identity(item)
    if item.card_id ~= nil then return 'id:' .. tostring(item.card_id) end
    return 'key:' .. tostring(item.key or item.card_key or '')
end
local function card_changes(before, after)
    local changes, buckets, used = {}, {}, {}
    for index, item in ipairs(after or {}) do
        local key = identity(item)
        buckets[key] = buckets[key] or {}
        buckets[key][#buckets[key] + 1] = index
    end
    local cursors = {}
    for index, item in ipairs(before or {}) do
        local key = identity(item)
        local next_index = (cursors[key] or 0) + 1
        cursors[key] = next_index
        local target = buckets[key] and buckets[key][next_index]
        if not target then
            changes[#changes + 1] = {kind = 'removed', before = item, before_index = index}
        else
            used[target] = true
            local replacement = after[target]
            if not equal(item, replacement) or target ~= index then
                changes[#changes + 1] = {kind = equal(item, replacement) and 'moved' or 'changed',
                    before = item, after = replacement, before_index = index, after_index = target}
            end
        end
    end
    for index, item in ipairs(after or {}) do
        if not used[index] then changes[#changes + 1] = {kind = 'added', after = item, after_index = index} end
    end
    return changes
end
local metrics = {'state', 'ante', 'round', 'dollars', 'hands_left', 'discards_left',
    'hands_limit', 'discards_limit', 'score', 'target_score', 'blind_key', 'blind_reward',
    'deck', 'stake', 'reroll_cost', 'joker_limit', 'consumable_limit', 'hand_limit',
    'hand_count', 'deck_count', 'discard_count', 'total_cards'}
local groups = {'jokers', 'consumables', 'vouchers', 'tags', 'playing_cards',
    'shop_jokers', 'shop_vouchers', 'shop_booster', 'pack_cards'}
function Diff.compare(before_node, after_node)
    assert(type(before_node) == 'table' and type(after_node) == 'table', 'Choose two valid nodes')
    local before = Details.from_snapshot(before_node.snapshot, before_node.summary)
    local after = Details.from_snapshot(after_node.snapshot, after_node.summary)
    local result = {before_id = before_node.id, after_id = after_node.id,
        before = before, after = after, metrics = {}, groups = {}, hand_levels = {}}
    for _, key in ipairs(metrics) do
        if not equal(before[key], after[key]) then
            local a, b = before[key], after[key]
            result.metrics[#result.metrics + 1] = {key = key, before = a, after = b,
                delta = type(a) == 'number' and type(b) == 'number' and b - a or nil}
        end
    end
    for _, key in ipairs(groups) do
        local changes = card_changes(before[key], after[key])
        if #changes > 0 then result.groups[#result.groups + 1] = {key = key, changes = changes} end
    end
    local hands, order = {}, {}
    for _, hand in ipairs(before.hand_levels or {}) do hands[hand.key] = {before = hand}; order[#order + 1] = hand.key end
    for _, hand in ipairs(after.hand_levels or {}) do
        if not hands[hand.key] then hands[hand.key] = {}; order[#order + 1] = hand.key end
        hands[hand.key].after = hand
    end
    for _, key in ipairs(order) do
        local pair = hands[key]
        if not equal(pair.before, pair.after) then
            result.hand_levels[#result.hand_levels + 1] = {key = key, before = pair.before, after = pair.after}
        end
    end
    local old_game = before_node.snapshot and before_node.snapshot.save and before_node.snapshot.save.GAME or {}
    local new_game = after_node.snapshot and after_node.snapshot.save and after_node.snapshot.save.GAME or {}
    result.rng_changed = not equal(old_game.pseudorandom, new_game.pseudorandom)
    result.choices = {before = copy(before_node.action and before_node.action.choices or {}),
        after = copy(after_node.action and after_node.action.choices or {})}
    result.choices.same = Replay.same_actions(result.choices.before, result.choices.after)
    result.state_equal = Replay.same_state(before_node.snapshot, after_node.snapshot)
    result.same = result.state_equal and result.choices.same
    result.other_state_changed = not result.state_equal and #result.metrics == 0 and #result.groups == 0
        and #result.hand_levels == 0 and not result.rng_changed
    return result
end
return Diff

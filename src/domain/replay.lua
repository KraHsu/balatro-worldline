-- Conservative replay matching. No hashes, captures, RNG or serialized copies.
-- Only children of the current node are candidates (the Tree owns that scope).
local Replay = {}
-- Explicit structural contexts avoid constructing and pattern-matching a path
-- string for every scalar in every card when testing an existing branch.
local function child_context(context, key)
    if context == 'root' then
        if key == 'save' then return 'save' elseif key == 'extra' then return 'extra' end
    elseif context == 'save' then
        if key == 'GAME' then return 'game' elseif key == 'cardAreas' then return 'areas' end
    elseif context == 'areas' then return 'area'
    elseif context == 'area' and key == 'cards' then return 'cards'
    elseif context == 'cards' and type(key) == 'number' and key >= 1 and key % 1 == 0 then return 'card'
    elseif context == 'extra' then
        if key == 'counters' then return 'counters' elseif key == 'opened_booster' then return 'card' end
    end
end
local function ignored(context, key, mode)
    if mode == 'action' then
        return key == 'label' or key == 'name' or key == 'atlas' or key == 'pos'
    end
    return context == 'counters' and key == 'ID'
        or context == 'extra' and (key == 'selected' or key=='cashout')
        or context == 'game' and (key == 'seeded' or key == 'worldline_run_id' or key == 'worldline_node_id')
        or context == 'card' and (key == 'highlighted' or key == 'unique_val__saved_ID')
end
local function equal(a, b, mode, context)
    if type(a) ~= type(b) then return false end
    if type(a) ~= 'table' then return a == b end
    for key, value in pairs(a) do
        if not ignored(context, key, mode) and not equal(value, b[key], mode, child_context(context, key)) then
            return false
        end
    end
    for key in pairs(b) do
        if not ignored(context, key, mode) and a[key] == nil then return false end
    end
    return true
end
-- Preserve native gameplay unique_val exactly. Relative unique order alone
-- cannot prove equal full Card:get_nominal comparisons after its rank/suit
-- terms and float rounding. An uncertain match becomes a separate branch;
-- matching never rewrites IDs, RNG or gameplay values in either checkpoint.
function Replay.same_state(a, b)
    return equal(a, b, 'state', 'root')
end
function Replay.same_actions(a, b) return equal(a, b, 'action') end
function Replay.matches(old_action, old_snapshot, action, snapshot)
    -- Older histories did not retain all action inputs. Preserve them instead
    -- of claiming an identical route from incomplete historical evidence.
    if type(old_action) ~= 'table' or type(action) ~= 'table'
        or old_action.replay_schema ~= 1 or action.replay_schema ~= 1 then return false end
    return Replay.same_actions(old_action, action) and Replay.same_state(old_snapshot, snapshot)
end
return Replay

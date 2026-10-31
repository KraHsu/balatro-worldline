-- Plain-data descriptions of decisions made between two phase-entry nodes.
-- This module only reads existing objects/snapshots. It never captures a game,
-- invokes a card method, consumes RNG, or mutates a stored choice list.
local Choices = {}

local function finite(value)
    return type(value) == 'number' and value == value and math.abs(value) ~= math.huge
end

local function scalar(value)
    local kind = type(value)
    if kind == 'string' or kind == 'boolean' or finite(value) then return value end
end

local function plain_map(value)
    if type(value) ~= 'table' then return scalar(value) end
    local result = {}
    for key, item in pairs(value) do
        if type(key) == 'string' then
            item = scalar(item)
            if item ~= nil then result[key] = item end
        end
    end
    return next(result) and result or nil
end

local function copy(value)
    if type(value) ~= 'table' then return value end
    local result = {}
    for key, item in pairs(value) do result[key] = copy(item) end
    return result
end

-- Descriptions may encounter callbacks or cyclic references in a live ability;
-- keep only bounded plain data without invoking anything on the card.
local function plain_data(value, seen, depth)
    if type(value) ~= 'table' then return scalar(value) end
    seen, depth = seen or {}, (depth or 0) + 1
    if seen[value] or depth > 12 then return nil end
    seen[value] = true
    local result = {}
    for key, item in pairs(value) do
        if type(key) == 'string' or finite(key) then result[key] = plain_data(item, seen, depth) end
    end
    seen[value] = nil
    return result
end

local function ordered_ids(area, selected_only)
    local result, selected = {}, {}
    if type(area) ~= 'table' then return result end
    for _, card in ipairs(area.highlighted or {}) do selected[card] = true end
    for _, card in ipairs(area.cards or area.highlighted or {}) do
        if not selected_only or selected[card] then
            if type(card)=='table' and finite(card.sort_id) then result[#result + 1] = card.sort_id end
        end
    end
    return result
end

local function localized(set, key, fallback)
    if type(localize) == 'function' and type(key) == 'string' then
        local ok, name = pcall(localize, {type = 'name_text', set = set, key = key})
        if ok and type(name) == 'string' and name ~= '' and name ~= 'ERROR' then return name end
    end
    return type(fallback) == 'string' and fallback or key
end

function Choices.card(card)
    if type(card) ~= 'table' then return nil end
    local config = type(card.config) == 'table' and card.config or {}
    local center = type(config.center) == 'table' and config.center or {}
    local ability = type(card.ability) == 'table' and card.ability or {}
    local base = type(card.base) == 'table' and card.base or {}
    local key = scalar(center.key) or scalar(config.center_key)
    local set = scalar(center.set) or scalar(ability.set)
    if not key and not set and not base.suit then return nil end
    local position = type(center.pos) == 'table' and center.pos or {}
    local result = {
        key = key, card_key = key, card_id = scalar(card.sort_id), set = set,
        name = localized(set or 'Joker', key, center.name or card.label or ability.name),
        atlas = scalar(center.atlas) or (set == 'Joker' and 'Joker' or nil),
        pos = {x = finite(position.x) and position.x or 0, y = finite(position.y) and position.y or 0},
        cost = finite(card.cost) and card.cost or nil,
        sell_cost = finite(card.sell_cost) and card.sell_cost or nil,
        edition = plain_map(card.edition), seal = scalar(card.seal),
        rank = scalar(base.value) or scalar(base.id), suit = scalar(base.suit),
        enhancement = (set == 'Enhanced' or set == 'Default') and key or nil,
        eternal = ability.eternal == true, rental = ability.rental == true,
        perishable = ability.perishable == true,
        perish_tally = scalar(ability.perish_tally),
        debuffed = card.debuff == true,
        ability = plain_data(ability), base = plain_data(base), base_key = scalar(config.card_key),
    }
    -- Standard-pack cards should be recognizable by rank/suit as well as their
    -- enhancement. Keep machine keys separately for the current UI language.
    if result.suit and result.rank then
        local rank, suit = tostring(result.rank), tostring(result.suit)
        if type(localize) == 'function' then
            local rok, r = pcall(localize, rank, 'ranks')
            local sok, s = pcall(localize, suit, 'suits_plural')
            if rok and type(r) == 'string' and r ~= '' and r ~= 'ERROR' then rank = r end
            if sok and type(s) == 'string' and s ~= '' and s ~= 'ERROR' then suit = s end
        end
        result.name = rank .. ' ' .. suit
    end
    return result
end

local renamed = {
    open_booster = {'打开卡包', 'Open pack'},
    redeem = {'兑换优惠券', 'Redeem voucher'},
    take_from_pack = {'选取卡包内卡牌', 'Take from pack'},
}

-- Called before native callbacks remove a shop card, alter its price or dissolve
-- it. A later buy-and-use continuation stays part of this outer description.
function Choices.describe(action, event, translate)
    assert(type(action) == 'table' and type(action.kind) == 'string', 'Invalid phase choice')
    local result = copy(action)
    -- Selection clicks are still not recorded as actions. These compact IDs
    -- describe inputs at an irreversible action so replay matching can tell
    -- different hands/targets/order apart even if they end with the same cash.
    result.decision = {schema = 1,
        hand = ordered_ids(G and G.hand, true),
        hand_order = ordered_ids(G and G.hand),
        playing_card_order = ordered_ids({cards=G and G.playing_cards}),
        counters = {sort_id=G and G.sort_id,playing_card=G and G.playing_card},
        hand_sort = G and G.hand and G.hand.config and scalar(G.hand.config.sort),
        jokers = ordered_ids(G and G.jokers),
        consumables = ordered_ids(G and G.consumeables)}
    local card = type(event) == 'table' and type(event.config) == 'table' and event.config.ref_table
    local item = Choices.card(card)
    if item then
        for key, value in pairs(item) do result[key] = value end
        result.key = nil
        if action.kind == 'sell' then result.cost = item.sell_cost end
        if action.kind == 'use' then
            if item.set == 'Booster' then result.kind = 'open_booster'
            elseif item.set == 'Voucher' then result.kind = 'redeem'
            elseif G and G.pack_cards and card.area == G.pack_cards then
                result.from_pack = true
                -- Vanilla Arcana/Celestial/Spectral cards are used immediately;
                -- only Buffoon/Standard selections enter the player's inventory.
                -- Do not call selectable_from_pack/check_use while observing:
                -- their native callback owns all gameplay effects.
                if item.set == 'Joker' or item.set == 'Default' or item.set == 'Enhanced' then
                    result.kind = 'take_from_pack'
                end
            end
        end
        -- A consumable's internal resale/base price is not a charge for using
        -- it, and pack picks have no separate displayed purchase price.
        if result.kind == 'use' or result.kind == 'take_from_pack' then result.cost = nil end
    end
    if renamed[result.kind] and result.kind ~= action.kind then
        local names = renamed[result.kind]
        result.label = translate and translate(names[1], names[2]) or names[2]
    end
    local game = G and G.GAME or {}
    if action.kind == 'reroll_shop' then
        local price = game.current_round and game.current_round.reroll_cost
        result.cost = finite(price) and price or nil
    end
    if action.kind == 'buy' and type(event) == 'table' and type(event.config) == 'table' then
        result.use_after = event.config.id == 'buy_and_use' or nil
    end
    if action.kind == 'play' or action.kind == 'discard' then
        result.cards_count = G and G.hand and #(G.hand.highlighted or {}) or 0
        -- Individual hand selection is deliberately absent from phase history.
        result.card_key, result.card_id, result.name = nil, nil, nil
    end
    if action.kind == 'select_blind' or action.kind == 'skip_blind' then
        local blind = type(card) == 'table' and card or {}
        local key = scalar(blind.key)
        if key then result.blind = {key = key, name = localized('Blind', key, blind.name)} end
    end
    return result
end

local function game_from(snapshot)
    return type(snapshot) == 'table' and type(snapshot.save) == 'table'
        and type(snapshot.save.GAME) == 'table' and snapshot.save.GAME or {}
end

local function state_from(snapshot)
    if type(snapshot) ~= 'table' then return nil end
    local state = type(snapshot.extra) == 'table' and snapshot.extra.state
        or type(snapshot.save) == 'table' and snapshot.save.STATE
    return scalar(state)
end

-- The lifecycle owner calls this only after its canonical before/after test
-- confirms a real irreversible mutation. A no-op never creates a decision row.
function Choices.finish(description, before, after)
    assert(type(description) == 'table' and type(description.kind) == 'string', 'Invalid phase choice')
    local result = copy(description)
    local old, new = game_from(before), game_from(after)
    result.count = 1
    if result.kind == 'play' or result.kind == 'discard' then
        result.steps = {copy(result.decision)}
        result.decision = nil
    end
    result.state_before, result.state_after = state_from(before), state_from(after)
    if finite(old.dollars) and finite(new.dollars) then
        result.money_before, result.money_after = old.dollars, new.dollars
        result.money_delta = new.dollars - old.dollars
    end
    result.ante = old.round_resets and scalar(old.round_resets.ante)
    result.round = scalar(old.round)
    return result
end

-- The native input ran, but overlapping event chains or a missing before-state
-- prevent an honest per-action result/Undo. Retain the ordered input and its
-- observed item/price; do not attribute an entire batch's money change to it.
function Choices.finish_untracked(description)
    local result = Choices.finish(description, nil, nil)
    result.replay_incomplete = true
    result.money_before, result.money_after, result.money_delta = nil, nil, nil
    result.state_before, result.state_after = nil, nil
    return result
end

function Choices.replay_complete(log)
    for _, record in ipairs(log or {}) do
        if record.replay_incomplete then return false end
    end
    return true
end

function Choices.append(log, record)
    assert(type(record) == 'table' and type(record.kind) == 'string', 'Invalid phase choice')
    local result = {}
    for index, item in ipairs(log or {}) do result[index] = item end
    local last = result[#result]
    -- Repeated hands/discards are summary counts, not a fine-grained card log.
    -- Commerce and consumable choices retain their separate displayed items.
    if last and (record.kind == 'play' or record.kind == 'discard') and last.kind == record.kind then
        local merged = copy(last)
        merged.replay_incomplete = last.replay_incomplete or record.replay_incomplete
        merged.count = (last.count or 1) + (record.count or 1)
        merged.cards_count = (last.cards_count or 0) + (record.cards_count or 0)
        if finite(last.money_delta) and finite(record.money_delta) then
            merged.money_delta = last.money_delta + record.money_delta
        else
            merged.money_delta = nil
        end
        merged.money_after, merged.state_after = record.money_after, record.state_after
        if last.steps and record.steps then
            merged.steps = {}
            for _, step in ipairs(last.steps) do merged.steps[#merged.steps + 1] = step end
            for _, step in ipairs(record.steps) do merged.steps[#merged.steps + 1] = step end
        else
            -- A legacy aggregate lacks per-operation inputs: never invent them.
            merged.steps = nil
        end
        result[#result] = merged
    else
        result[#result + 1] = copy(record)
    end
    return result
end

return Choices

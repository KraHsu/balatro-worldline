-- Rich, lazily reconstructable descriptions of existing checkpoint data.
-- Reads save tables and optional localization registries only; no Card objects,
-- native capture/restore methods, file writes, game callbacks or RNG are used.
local Loader
if SMODS and SMODS.load_file then
    Loader = assert(SMODS.load_file('loader.lua', 'WorldLine'))()
else
    Loader = dofile('src/loader.lua')
end
local Choices = Loader.load('choices')
local Tree = Loader.load('tree')
local Details = {}

local function finite(value)
    return type(value) == 'number' and value == value and math.abs(value) ~= math.huge
end
local function number(value, fallback) return finite(value) and value or fallback end
local function data_copy(value)
    if type(value) ~= 'table' then return value end
    local result = {}
    for key, item in pairs(value) do result[key] = data_copy(item) end
    return result
end
local function name(set, key, fallback)
    if type(localize) == 'function' and type(key) == 'string' then
        local ok, value = pcall(localize, {type = 'name_text', set = set, key = key})
        if ok and type(value) == 'string' and value ~= '' and value ~= 'ERROR' then return value end
    end
    return type(fallback) == 'string' and fallback or key
end
local function registry(which, key)
    return G and type(G[which]) == 'table' and G[which][key] or nil
end
local function limit(area)
    local config = type(area) == 'table' and type(area.config) == 'table' and area.config or {}
    if finite(config.card_limit) then return config.card_limit end
    local slots = type(config.card_limits) == 'table' and config.card_limits
    if slots and finite(slots.total_slots) then
        return slots.total_slots - number(slots.extra_slots_used, 0)
    end
end

local function card(saved)
    if type(saved) ~= 'table' then return nil end
    local fields = type(saved.save_fields) == 'table' and saved.save_fields or {}
    local key = fields.center or saved.config and saved.config.center_key
        or saved.config and saved.config.center and saved.config.center.key
    local center = registry('P_CENTERS', key)
        or saved.config and saved.config.center
        or {key = key, set = saved.ability and saved.ability.set, name = saved.label}
    -- A tiny view adapts native Card:save's save_fields to the common formatter.
    -- It shares read-only source tables; Choices.card returns detached data.
    local view = {config = {center = center, center_key = key}, ability = saved.ability,
        base = saved.base, edition = saved.edition, seal = saved.seal, sort_id = saved.sort_id,
        cost = saved.cost, sell_cost = saved.sell_cost, label = saved.label, debuff = saved.debuff}
    local item = Choices.card(view)
    if item then
        -- Snapshot tooltip data must never fall back to the live Card/GAME.
        item.ability, item.base = data_copy(saved.ability or {}), data_copy(saved.base or {})
        item.base_key = fields.card
        item.pinned, item.facing = saved.pinned == true, saved.facing
    end
    return item
end

local function inventory(area)
    if type(area) ~= 'table' or type(area.cards) ~= 'table' then return nil end
    local result = {}
    for _, value in ipairs(area.cards) do
        local item = card(value)
        if item then result[#result + 1] = item end
    end
    return result
end

local function increment(map, key)
    if type(key) == 'string' or finite(key) then map[key] = (map[key] or 0) + 1 end
end

function Details.from_snapshot(snapshot, base_summary)
    local result = data_copy(base_summary or {})
    if type(snapshot) ~= 'table' or type(snapshot.save) ~= 'table' then return result end
    local save, extra = snapshot.save, type(snapshot.extra) == 'table' and snapshot.extra or {}
    local game = type(save.GAME) == 'table' and save.GAME or {}
    local round = type(game.current_round) == 'table' and game.current_round or {}
    local resets = type(game.round_resets) == 'table' and game.round_resets or {}
    local blind = type(save.BLIND) == 'table' and save.BLIND or {}
    local back = type(save.BACK) == 'table' and save.BACK or {}
    local areas = type(save.cardAreas) == 'table' and save.cardAreas or {}
    result.state = extra.state or result.state
    result.ante, result.round = number(resets.ante, result.ante), number(game.round, result.round)
    result.dollars = number(game.dollars, result.dollars or result.money)
    result.money = result.dollars
    result.hands_left, result.discards_left = number(round.hands_left, result.hands_left),
        number(round.discards_left, result.discards_left)
    result.hands_limit, result.discards_limit = number(resets.hands, result.hands_limit),
        number(resets.discards, result.discards_limit)
    result.score, result.target_score = number(game.chips, result.score), number(blind.chips, result.target_score)
    result.blind_reward = number(blind.dollars, result.blind_reward)
    result.blind_key = type(blind.config_blind) == 'string' and blind.config_blind ~= '' and blind.config_blind
        or result.blind_key
    result.blind_name = name('Blind', result.blind_key, blind.name or result.blind_name)
    result.deck = Tree.deck_key(game.selected_back_key) or Tree.deck_key(back.key) or Tree.deck_key(result.deck)
    result.deck_name = name('Back', result.deck, back.name or result.deck_name)
    result.stake, result.reroll_cost = number(game.stake, result.stake), number(round.reroll_cost, result.reroll_cost)
    result.joker_limit, result.consumable_limit = limit(areas.jokers) or result.joker_limit,
        limit(areas.consumeables) or result.consumable_limit
    result.hand_limit = limit(areas.hand) or result.hand_limit
    result.jokers = inventory(areas.jokers) or result.jokers or {}
    result.consumables = inventory(areas.consumeables) or result.consumables or {}
    result.joker_count, result.consumable_count = #result.jokers, #result.consumables
    for _, area_name in ipairs({'hand', 'deck', 'discard', 'play'}) do
        if areas[area_name] and type(areas[area_name].cards) == 'table' then
            result[area_name .. '_count'] = #areas[area_name].cards
            result[area_name .. '_cards'] = inventory(areas[area_name])
        end
    end
    result.selected_count = type(extra.selected) == 'table' and type(extra.selected.hand) == 'table'
        and #extra.selected.hand or result.selected_count

    result.vouchers = inventory(areas.vouchers) or result.vouchers or {}
    local voucher_keys = {}
    for _, item in ipairs(result.vouchers) do
        local key = item.key or item.card_key
        if type(key) == 'string' then voucher_keys[key] = true end
    end
    local keys = {}
    for key, used in pairs(type(game.used_vouchers) == 'table' and game.used_vouchers or {}) do
        if type(key) == 'string' and used and not voucher_keys[key] then keys[#keys + 1] = key end
    end
    table.sort(keys)
    for _, key in ipairs(keys) do
        local center = registry('P_CENTERS', key) or {key = key, set = 'Voucher'}
        result.vouchers[#result.vouchers + 1] = Choices.card({config = {center = center}})
    end
    if type(save.tags) == 'table' then
        result.tags = {}
        for _, tag in ipairs(save.tags) do
            if type(tag) == 'table' and type(tag.key) == 'string' then
                local proto = registry('P_TAGS', tag.key) or {}
                result.tags[#result.tags + 1] = {key = tag.key, set = 'Tag', name = name('Tag', tag.key, proto.name),
                    tally = number(tag.tally), pos = data_copy(proto.pos), ability = data_copy(tag.ability or {})}
            end
        end
    end
    result.tags = result.tags or {}

    -- Reconstruct physical deck composition from the owned play areas only.
    -- Shop/pack offers must not inflate the player's deck. Duplicate references
    -- can temporarily appear during transitions; stable IDs count once.
    local playing, by_card_id = {}, {}
    local stats, seen, found = {total = 0, suits = {}, ranks = {}, enhanced = 0,
        editions = 0, seals = 0, stone = 0, wild = 0}, {}, false
    for _, area_name in ipairs({'hand', 'deck', 'discard', 'play'}) do
        local area = areas[area_name]
        if type(area) == 'table' and type(area.cards) == 'table' then
            found = true
            for index, saved in ipairs(area.cards) do
                if type(saved) == 'table' then
                    local id = saved.sort_id or saved
                    if not seen[id] then
                        seen[id] = true
                        local item = result[area_name .. '_cards'] and result[area_name .. '_cards'][index]
                        if item then
                            item.area = area_name
                            playing[#playing + 1] = item
                            if saved.sort_id then by_card_id[saved.sort_id] = item end
                        end
                        local base = type(saved.base) == 'table' and saved.base or {}
                        local key = type(saved.save_fields) == 'table' and saved.save_fields.center
                        stats.total = stats.total + 1
                        increment(stats.suits, base.suit)
                        increment(stats.ranks, base.value or base.id)
                        if key and key ~= 'c_base' then stats.enhanced = stats.enhanced + 1 end
                        if saved.edition then stats.editions = stats.editions + 1 end
                        if saved.seal then stats.seals = stats.seals + 1 end
                        if key == 'm_stone' then stats.stone = stats.stone + 1 end
                        if key == 'm_wild' then stats.wild = stats.wild + 1 end
                    end
                end
            end
        end
    end
    if found then
        result.deck_stats, result.total_cards = stats, stats.total
        local ordered, used = {}, {}
        for _, id in ipairs(extra.playing_order or {}) do
            if by_card_id[id] and not used[by_card_id[id]] then
                ordered[#ordered + 1], used[by_card_id[id]] = by_card_id[id], true
            end
        end
        for _, item in ipairs(playing) do if not used[item] then ordered[#ordered + 1] = item end end
        result.playing_cards = ordered
    end
    result.tooltip_context = {
        probabilities = data_copy(game.probabilities or {}),
        consumeable_usage_total = data_copy(game.consumeable_usage_total or {}),
        current_round = data_copy(round), hands = data_copy(game.hands or {}),
        joker_count = result.joker_count, deck_count = result.deck_count, total_cards = result.total_cards,
        dollars = result.dollars, round = result.round, ante = result.ante,
        hands_played = game.hands_played, discards_used = game.discards_used,
    }
    if not result.total_cards and type(extra.playing_order) == 'table' then result.total_cards = #extra.playing_order end

    if type(game.hands) == 'table' then
        result.hand_levels = {}
        for key, hand in pairs(game.hands) do
            if type(key) == 'string' and type(hand) == 'table'
                and (hand.visible ~= false or number(hand.played, 0) > 0 or number(hand.level, 1) > 1) then
                local label = key
                if type(localize) == 'function' then
                    local ok, text = pcall(localize, key, 'poker_hands')
                    if ok and type(text) == 'string' and text ~= '' and text ~= 'ERROR' then label = text end
                end
                result.hand_levels[#result.hand_levels + 1] = {key = key, name = label,
                    order = number(hand.order, 100), level = number(hand.level),
                    chips = number(hand.chips), mult = number(hand.mult), played = number(hand.played, 0)}
            end
        end
        table.sort(result.hand_levels, function(a, b)
            if a.order == b.order then return a.key < b.key end
            return a.order < b.order
        end)
    end
    result.hand_levels = result.hand_levels or {}
    for _, area_name in ipairs({'shop_jokers', 'shop_vouchers', 'shop_booster', 'pack_cards'}) do
        local items = inventory(areas[area_name])
        if items then result[area_name] = items end
    end
    return result
end

return Details

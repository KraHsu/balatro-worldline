local P = dofile('src/ui/card_presentation.lua')
local calls = 0
local function forbidden() calls = calls + 1; error('Presentation must not call gameplay/RNG/write functions') end
math.random, math.randomseed, pseudorandom, save_run, Card = forbidden, forbidden, forbidden, forbidden, forbidden
SMODS = {get_probability_vars = forbidden}
localize = function(key, set)
    if type(key) == 'table' then return 'Name:' .. key.key end
    return (set and set .. ':' or '') .. tostring(key)
end
G = setmetatable({localization = {descriptions = {Joker = {
    j_blue_joker = {text = {'{C:chips}#1#{} each, #2# now'}},
    j_unknown = {text = {'{C:mult}#1#{} and #2#'}},
}, Enhanced = {m_mult = {text = {'+#1# Mult'}}}}}}, {
    __index = function(_, key) error('Presentation read live G.' .. key) end,
    __newindex = forbidden,
})
local function item(key, extra, fields, set)
    local ability = {t_mult = 0, t_chips = 0, x_mult = 1, type = '', extra = extra}
    for k, v in pairs(fields or {}) do ability[k] = v end
    return {key = key, card_key = key, set = set or 'Joker', ability = ability}
end
local summary = {dollars = 20, tooltip_context = {deck_count = 12, total_cards = 52,
    joker_count = 4, consumeable_usage_total = {tarot = 7}, probabilities = {normal = 2},
    hands = {Pair = {level = 3, l_mult = 1, l_chips = 15}}}}
local blue = item('j_blue_joker', 2)
assert(P.variables(blue, summary)[2] == 24, 'Blue Joker uses saved remaining deck size, never total cards or live deck')
assert(P.variables(item('j_abstract', 3), summary)[2] == 12)
assert(P.variables(item('j_todo_list', {dollars = 4}, {to_do_poker_hand = 'Flush'}), summary)[2] == 'poker_hands:Flush',
    'native zero/default ability fields do not shadow named dynamic Joker branches')
assert(P.variables(item('j_sly', nil, {t_chips = 50, type = 'Pair'}), summary)[1] == 50)
assert(P.variables(item('j_duo', nil, {x_mult = 2, type = 'Pair'}), summary)[1] == 2)
assert(P.variables(item('j_jolly', nil, {t_mult = 8, type = 'Pair'}), summary)[1] == 8)
for _, key in ipairs({'j_hack', 'j_dusk', 'j_sock_and_buskin'}) do assert(P.variables(item(key, 1), summary)[1] == 2) end
local trousers = P.variables(item('j_spare_trousers', 2, {mult = 12}), summary)
assert(trousers[1] == 2 and trousers[2] == 'poker_hands:Two Pair' and trousers[3] == 12)
assert(P.variables(item('j_troubadour', {h_size = 2, h_plays = -1}), summary)[2] == 1)
assert(P.variables(item('j_fortune_teller', 1), summary)[2] == 7)
assert(P.variables(item('j_fortune_teller', 1), {tooltip_context = {consumeable_usage_total = {}}})[2] == 0)
assert(P.variables(item('j_fortune_teller', 1), nil)[2] == nil, 'an entirely absent saved context stays unknown')
assert(P.variables(item('j_steel_joker', 0.2), summary)[2] == 1)
assert(P.variables(item('j_stone', 25), summary)[2] == 0)
assert(P.variables(item('j_cloud_9', 1, {nine_tally = 4}), summary)[2] == 4)
assert(P.variables(item('j_bull', 2), summary)[2] == 40)
local glass = P.variables(item('m_glass', 4, {x_mult = 2}, 'Enhanced'), summary)
assert(glass[1] == 2 and glass[2] == 2 and glass[3] == 4)
local planet = P.variables(item('c_mercury', nil, {consumeable = {hand_type = 'Pair'}}, 'Planet'), summary)
assert(planet[1] == 3 and planet[2] == 'poker_hands:Pair' and planet[3] == 1 and planet[4] == 15)
assert(P.variables(item('c_strength', nil, {consumeable = {max_highlighted = 2}}, 'Tarot'), summary)[1] == 2)
assert(P.variables(item('v_seed_money', 50, nil, 'Voucher'), summary)[1] == 10)
assert(P.variables(item('v_tarot_merchant', 2, {extra_disp = 4}, 'Voucher'), summary)[1] == 4)

blue.sell_cost, blue.edition, blue.seal, blue.eternal = 4, {foil = true}, 'Red', true
local shown = P.tooltip(blue, summary)
assert(shown.name == 'Name:j_blue_joker' and shown.lines[1] == '2 each, 24 now')
assert(shown.lines[2] == 'Sell value $4' and #shown.badges == 3)
local unknown = P.tooltip(item('j_unknown'), summary)
assert(unknown.lines[1] == '? and ?' and unknown.lines[2] == 'Unknown saved value')
assert(P.tooltip(item('j_blue_joker', 2), nil).lines[1] == '2 each, ? now')
assert(blue.ability.extra == 2 and blue.edition.foil and summary.tooltip_context.deck_count == 12,
    'presentation cannot mutate the saved ability or comparison context')
assert(calls == 0)
print('PASS card presentation: saved native values, hand-Joker keys, retrigger counts, consumable config, unknown values, no live state/RNG')

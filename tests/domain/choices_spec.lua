local Choices = dofile('src/domain/choices.lua')
local Codec = dofile('src/storage/codec.lua')
local native_calls = 0
local forbidden = function() native_calls = native_calls + 1; error('Choice descriptions must be read-only') end
math.random, math.randomseed, pseudorandom, save_run = forbidden, forbidden, forbidden, forbidden
local object = {name = 'do not serialize me'}
object.self = object
localize = function(value, category)
    if type(value) == 'table' then return 'Localized ' .. value.key end
    if category == 'ranks' then return 'Ace' end
    if category == 'suits_plural' then return 'Spades' end
end
G = {GAME = {current_round = {reroll_cost = 3}}, pack_cards = {},
    hand = {highlighted = {{sort_id = 10}, {sort_id = 20}}}}
local joker = {
    sort_id = 42, cost = 8, sell_cost = 4, area = {},
    config = {center = {key = 'j_abstract', name = 'Abstract Joker', set = 'Joker',
        atlas = 'Joker', pos = {x = 1, y = 2}}},
    ability = {set = 'Joker', eternal = true, extra = object},
    edition = {foil = true, key = 'e_foil', object = object, calculate = forbidden},
    seal = 'Red', save = forbidden,
}
local original = {kind = 'buy', label = 'Buy', callback = 'buy_from_shop'}
local desc = Choices.describe(original, {config = {ref_table = joker, id = 'buy_and_use'}})
assert(desc.kind == 'buy' and desc.label == 'Buy' and desc.card_key == 'j_abstract'
    and desc.card_id == 42 and desc.name == 'Localized j_abstract')
assert(desc.cost == 8 and desc.sell_cost == 4 and desc.use_after and desc.eternal)
assert(desc.edition.foil and desc.edition.key == 'e_foil' and not desc.edition.object and not desc.edition.calculate)
assert(original.cost == nil and original.card_key == nil and joker.save == forbidden)
joker.cost, joker.config.center.pos.x, joker.edition.foil = 999, 99, false
assert(desc.cost == 8 and desc.pos.x == 1 and desc.edition.foil,
    'a later native purchase/price removal cannot mutate the displayed pre-choice data')
local before = {save = {GAME = {dollars = 10, round = 4, round_resets = {ante = 2}}}, extra = {state = 'SHOP'}}
local after = {save = {GAME = {dollars = 5}}, extra = {state = 'SHOP'}}
local bought = Choices.finish(desc, before, after)
assert(bought.cost == 8 and bought.money_delta == -5 and bought.money_before == 10 and bought.money_after == 5,
    'displayed price is distinct from net money changes caused by card effects')
assert(bought.count == 1 and bought.ante == 2 and bought.round == 4 and bought.state_before == 'SHOP')
assert(desc.count == nil and desc.money_delta == nil, 'finalizing does not mutate the Undo description')
local log = Choices.append(nil, bought)
bought.cost = -100
assert(#log == 1 and log[1].cost == 8)
local sold = Choices.describe({kind = 'sell'}, {config = {ref_table = joker}})
assert(sold.cost == 4)
local second = Choices.append(log, Choices.finish(sold, after, before))
assert(#log == 1 and #second == 2 and second[1] == log[1] and second[2].money_delta == 5,
    'append copies the list and shares only already-immutable prior records')
local reroll = Choices.describe({kind = 'reroll_shop'})
assert(reroll.cost == 3 and not reroll.card_key)

local translate = function(zh, en) return zh .. '/' .. en end
local booster = {ability = {set = 'Booster'}, config = {center = {key = 'p_buffoon', set = 'Booster'}}, cost = 4}
local opened = Choices.describe({kind = 'use'}, {config = {ref_table = booster}}, translate)
assert(opened.kind == 'open_booster' and opened.label == '打开卡包/Open pack')
local voucher = {ability = {set = 'Voucher'}, config = {center = {key = 'v_hone', set = 'Voucher'}}}
assert(Choices.describe({kind = 'use'}, {config = {ref_table = voucher}}).kind == 'redeem')
local packed = {area = G.pack_cards, cost = 3, ability = {set = 'Tarot'},
    config = {center = {key = 'c_fool', set = 'Tarot'}}, selectable_from_pack = forbidden, check_use = forbidden}
local pack_use = Choices.describe({kind = 'use'}, {config = {ref_table = packed}})
assert(pack_use.kind == 'use' and pack_use.from_pack and pack_use.cost == nil,
    'pack consumables are used immediately, without charging their internal card price')
for _, set in ipairs({'Planet', 'Spectral'}) do
    packed.config.center.set = set
    assert(Choices.describe({kind = 'use'}, {config = {ref_table = packed}}).kind == 'use')
end
for _, set in ipairs({'Joker', 'Default', 'Enhanced'}) do
    packed.config.center.set = set
    local take = Choices.describe({kind = 'use'}, {config = {ref_table = packed}})
    assert(take.kind == 'take_from_pack' and take.from_pack and take.cost == nil)
end
packed.area = {}
local held_use = Choices.describe({kind = 'use'}, {config = {ref_table = packed}})
assert(held_use.kind == 'use' and held_use.from_pack == nil and held_use.cost == nil)
local blind = Choices.describe({kind = 'skip_blind'}, {config = {ref_table = {key = 'bl_big', name = 'Big Blind'}}})
assert(blind.blind.key == 'bl_big' and blind.blind.name == 'Localized bl_big')
local playing = Choices.card({base = {id = 14, value = 'Ace', suit = 'Spades'},
    config = {center = {key = 'm_lucky', set = 'Enhanced'}}, ability = {set = 'Enhanced'}})
assert(playing.name == 'Ace Spades' and playing.rank == 'Ace' and playing.suit == 'Spades'
    and playing.enhancement == 'm_lucky')

local play = Choices.finish(Choices.describe({kind = 'play', label = 'Play hand'}), before, after)
assert(play.cards_count == 2 and not play.card_key and not play.card_id and not play.selected)
local hands = Choices.append(nil, play)
local more = Choices.append(hands, play)
assert(#hands == 1 and hands[1].count == 1 and #more == 1 and more[1].count == 2
    and more[1].cards_count == 4 and more[1].money_delta == -10)
local discard = Choices.finish(Choices.describe({kind = 'discard', label = 'Discard'}), after, before)
more = Choices.append(more, discard)
assert(#more == 2 and more[2].kind == 'discard', 'play/discard are separate aggregate counters')
more = Choices.append(more, desc)
more = Choices.append(more, desc)
assert(#more == 4, 'separate commerce decisions retain their separate item descriptions')
local restored = assert(Codec.decode(Codec.encode({choices = second}, TEST_JSON), TEST_JSON))
assert(restored.choices[1].edition.foil and restored.choices[2].money_delta == 5,
    'choice records remain ordinary archive-compatible data without references to live cards')
assert(Choices.card(nil) == nil and Choices.card(object) == nil)
assert(Choices.describe({kind = 'play'}, 'non-event').cards_count == 2)
assert(native_calls == 0, 'describing choices must not call gameplay/snapshot/save/RNG operations')
local unknown_buy = Choices.finish_untracked(desc)
assert(unknown_buy.replay_incomplete and unknown_buy.cost == desc.cost
    and unknown_buy.card_id == desc.card_id and not unknown_buy.money_delta
    and not unknown_buy.money_after and not unknown_buy.state_after,
    'untracked input keeps observed card/price, never inventing an individual result from batch totals')
assert(Choices.replay_complete(second) and not Choices.replay_complete({unknown_buy}))
local partial = Choices.append(hands, Choices.finish_untracked(Choices.describe({kind = 'play'})))
assert(partial[1].count == 2 and partial[1].replay_incomplete and partial[1].money_delta == nil
    and not Choices.replay_complete(partial), 'hand aggregation propagates missing replay evidence and removes partial money totals')
local restored_partial = assert(Codec.decode(Codec.encode(partial, TEST_JSON), TEST_JSON))
assert(not Choices.replay_complete(restored_partial), 'archive/Undo choice restoration retains conservative replay eligibility')
assert(Choices.replay_complete(hands) and hands[1].money_delta == -5, 'untracked append never changes prior phase choices')
print('PASS choices: immutable stage decisions, pre-action item details, actual money delta, aggregate hands, plain archives')

local previous_smods = SMODS
SMODS = nil
local Details = dofile('src/ui/details.lua')
SMODS = previous_smods
local Codec = dofile('src/storage/codec.lua')
local calls = 0
local forbidden = function() calls = calls + 1; error('No native operation in details') end
math.random, pseudorandom, save_run = forbidden, forbidden, forbidden
G = {P_CENTERS = {
    j_joker = {key = 'j_joker', name = 'Joker', set = 'Joker', atlas = 'Joker', pos = {x = 0, y = 0}},
    c_fool = {key = 'c_fool', name = 'The Fool', set = 'Tarot', pos = {x = 0, y = 0}},
    v_hone = {key = 'v_hone', name = 'Hone', set = 'Voucher', pos = {x = 0, y = 0}},
    v_glow_up = {key = 'v_glow_up', name = 'Glow Up', set = 'Voucher', pos = {x = 1, y = 0}},
    c_base = {key = 'c_base', set = 'Default'}, m_stone = {key = 'm_stone', set = 'Enhanced'},
}, P_TAGS = {tag_coupon = {name = 'Coupon Tag', pos = {x = 1, y = 1}}}}
localize = function(value, category)
    if type(value) == 'table' then return 'Native ' .. value.key end
    if category == 'poker_hands' then return 'Native ' .. value end
    return value
end
local function saved(id, key, set, suit, rank)
    return {sort_id = id, save_fields = {center = key}, ability = {set = set},
        base = {suit = suit, value = rank}, cost = 4, sell_cost = 2}
end
local hand = saved(1, 'c_base', 'Default', 'Spades', 'Ace')
local deck = saved(2, 'm_stone', 'Enhanced', 'Hearts', 'King')
deck.edition, deck.seal = {foil = true}, 'Red'
local joker = saved(3, 'j_joker', 'Joker')
joker.edition, joker.ability.rental = {negative = true}, true
local snapshot = {seed = 'TEST', extra = {state = 'SHOP', playing_order = {1, 2}, selected = {hand = {1}}},
    save = {
        GAME = {dollars = 17, round = 4, stake = 2, chips = 1200, selected_back_key = 'b_red',
            current_round = {hands_left = 3, discards_left = 2, reroll_cost = 7},
            round_resets = {ante = 2, hands = 4, discards = 3},
            used_vouchers = {v_hone = true, v_glow_up = true, v_unused = false},
            hands = {['High Card'] = {visible = true, order = 12, level = 3, chips = 25, mult = 3, played = 2},
                ['Pair'] = {visible = true, order = 11, level = 1, chips = 10, mult = 2},
                ['Flush Five'] = {visible = false, order = 1, level = 1, chips = 160, mult = 16}}},
        BLIND = {config_blind = 'bl_big', name = 'Big Blind', chips = 1600, dollars = 4},
        BACK = {key = 'b_red', name = 'Red Deck'}, tags = {{key = 'tag_coupon', tally = 3, ability = {orbital_hand = 'Pair'}}},
        cardAreas = {
            hand = {cards = {hand}, config = {card_limit = 8}},
            deck = {cards = {deck}, config = {}},
            discard = {cards = {hand}, config = {}}, -- duplicated transition reference: count once
            play = {cards = {}},
            jokers = {cards = {joker}, config = {card_limits = {total_slots = 6, extra_slots_used = 1}}},
            consumeables = {cards = {saved(4, 'c_fool', 'Tarot')}, config = {card_limit = 2}},
            vouchers = {cards = {saved(5, 'v_hone', 'Voucher')}},
            shop_jokers = {cards = {saved(6, 'j_joker', 'Joker')}},
            pack_cards = {cards = {saved(7, 'c_base', 'Default', 'Clubs', 'Ace')}},
        },
    }}
local base = {state = 'OLD', dollars = 1, custom = {keep = true}, deck_name = 'Fallback'}
local text_before = Codec.encode(snapshot, TEST_JSON)
local result = Details.from_snapshot(snapshot, base)
assert(result.state == 'SHOP' and result.ante == 2 and result.round == 4 and result.dollars == 17 and result.money == 17)
assert(result.score == 1200 and result.target_score == 1600 and result.blind_key == 'bl_big'
    and result.blind_name == 'Native bl_big' and result.blind_reward == 4)
assert(result.deck == 'b_red' and result.deck_name == 'Native b_red' and result.stake == 2)
assert(result.hands_left == 3 and result.hands_limit == 4 and result.discards_left == 2 and result.discards_limit == 3)
assert(result.joker_limit == 5 and result.consumable_limit == 2 and result.hand_limit == 8)
assert(result.joker_count == 1 and result.jokers[1].key == 'j_joker' and result.jokers[1].edition.negative
    and result.jokers[1].rental and result.jokers[1].name == 'Native j_joker')
assert(result.consumable_count == 1 and result.consumables[1].key == 'c_fool')
assert(#result.vouchers == 2 and result.vouchers[1].key == 'v_hone' and result.vouchers[2].key == 'v_glow_up',
    'used voucher map augments the area without duplicating visible voucher cards')
assert(#result.tags == 1 and result.tags[1].name == 'Native tag_coupon' and result.tags[1].tally == 3)
assert(result.tags[1].set == 'Tag' and result.tags[1].ability.orbital_hand == 'Pair')
assert(result.hand_count == 1 and result.deck_count == 1 and result.discard_count == 1 and result.play_count == 0)
assert(result.total_cards == 2 and result.deck_stats.total == 2 and result.deck_stats.enhanced == 1
    and result.deck_stats.editions == 1 and result.deck_stats.seals == 1 and result.deck_stats.stone == 1,
    'owned deck excludes shop/pack offers and deduplicates stable card IDs')
assert(result.deck_stats.suits.Spades == 1 and result.deck_stats.suits.Hearts == 1 and not result.deck_stats.suits.Clubs)
assert(result.selected_count == 1 and result.reroll_cost == 7)
assert(#result.hand_levels == 2 and result.hand_levels[1].key == 'Pair' and result.hand_levels[2].level == 3,
    'hand levels are ordered and undiscovered inactive hidden hands remain hidden')
assert(#result.shop_jokers == 1 and #result.pack_cards == 1)
assert(#result.playing_cards == 2 and result.playing_cards[1].card_id == 1
    and result.playing_cards[2].area == 'deck' and #result.hand_cards == 1)
assert(result.tooltip_context.current_round.reroll_cost == 7 and result.tooltip_context.deck_count == 1
    and result.tooltip_context.total_cards == 2)
result.jokers[1].ability.rental = false
result.hand_cards[1].base.suit = 'Diamonds'
result.tooltip_context.current_round.reroll_cost = 99
assert(joker.ability.rental and hand.base.suit == 'Spades'
    and snapshot.save.GAME.current_round.reroll_cost == 7, 'tooltip presentation owns detached snapshot data')
assert(Codec.encode(snapshot, TEST_JSON) == text_before and base.dollars == 1 and not base.jokers)
result.jokers[1].edition.negative = false; result.custom.keep = false
assert(joker.edition.negative and base.custom.keep, 'lazy details are detached from original snapshot and summary')
local restored = assert(Codec.decode(Codec.encode(result, TEST_JSON), TEST_JSON))
assert(restored.target_score == 1600 and restored.deck_stats.total == 2)

-- Legacy/minimal fixtures retain their existing summaries when no native areas
-- are present, instead of guessing inventory or replacing them with live cards.
G = nil; localize = nil
local minimal = Details.from_snapshot({save = {GAME = {}}, extra = {}}, {
    state = 'SELECTING_HAND', jokers = {{key = 'j_legacy', name = 'Legacy'}},
    hand_count = 7, deck_count = 40, dollars = 8, deck_name = 'Legacy Deck'})
assert(minimal.jokers[1].key == 'j_legacy' and minimal.hand_count == 7 and minimal.deck_count == 40
    and minimal.dollars == 8 and minimal.deck_name == 'Legacy Deck')
local without_registry = Details.from_snapshot(snapshot)
assert(without_registry.jokers[1].key == 'j_joker' and without_registry.total_cards == 2,
    'details work without native registries or gameplay objects')
assert(calls == 0)
print('PASS details: snapshot-only inventory, deck/hand statistics, native labels, legacy fallback, no source mutation')

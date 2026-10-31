local actions, prepared, recording, boundary = {}, 0, true, true
G = {
    STATE = 7, GAME = { round_resets = { ante = 1 }, round = 2 }, FUNCS = {},
    hand = { cards = {1, 2}, highlighted = {} },
}
CardArea = {}
function CardArea:add_to_highlighted(card) self.highlighted[#self.highlighted + 1] = card end
function CardArea:unhighlight_all() self.highlighted = {} end
local selection_original = CardArea.add_to_highlighted
local fine_calls = 0
local fine_names = {
    'play_cards_from_highlighted', 'discard_cards_from_highlighted', 'buy_from_shop',
    'use_card', 'sell_card', 'reroll_shop', 'reroll_boss', 'skip_booster',
    'sort_hand_suit', 'sort_hand_value',
}
local originals = {}
for _, name in ipairs(fine_names) do
    G.FUNCS[name] = function() fine_calls = fine_calls + 1; return name end
    originals[name] = G.FUNCS[name]
end
G.FUNCS.select_blind = function() return 'started', nil, 3 end
G.FUNCS.skip_blind = function() return false end
G.FUNCS.cash_out = function() return 'shop' end
G.FUNCS.toggle_shop = function(e)
    if e == 'error' then error('expected failure') end
    G.FUNCS.select_blind()
    return 'left'
end
local ctx = {
    record_action = function(value) actions[#actions + 1] = value end,
    before_action = function() prepared = prepared + 1 end,
    should_record = function() return recording end,
    is_input_boundary = function() return boundary end,
    text = function(_, en) return en end,
}
local Hooks = dofile('src/runtime/hooks.lua')
Hooks.install(ctx)
local result, middle, last = G.FUNCS.select_blind({config = {ref_table = {key = 'bl_small', name = 'Small Blind'}}})
assert(result == 'started' and middle == nil and last == 3, 'nil-bearing return values must survive')
assert(#actions == 1 and actions[1].kind == 'select_blind')
assert(actions[1].blind.key == 'bl_small' and actions[1].ante == 1 and actions[1].round == 2)
assert(actions[1].selected == nil and actions[1].card == nil, 'milestones do not log micro decisions')
G.FUNCS.skip_blind()
assert(#actions == 1, 'rejected actions do not record')
G.FUNCS.cash_out()
assert(#actions == 2 and actions[2].kind == 'enter_shop')
G.FUNCS.toggle_shop()
assert(#actions == 3 and actions[3].kind == 'leave_shop', 'nested stage calls produce one milestone')
for _, name in ipairs(fine_names) do
    assert(G.FUNCS[name] == originals[name], 'fine-grained callbacks must remain untouched: ' .. name)
    G.FUNCS[name]()
end
assert(fine_calls == #fine_names and #actions == 3)
assert(CardArea.add_to_highlighted == selection_original, 'selection methods must remain untouched')
CardArea.add_to_highlighted(G.hand, 1)
CardArea.unhighlight_all(G.hand)
G.hand.cards = {2, 1}
Hooks.reset(); Hooks.poll(ctx)
assert(#actions == 3, 'selection and ordering never add nodes')
assert(not pcall(G.FUNCS.toggle_shop, 'error'))
G.FUNCS.cash_out()
assert(#actions == 4, 'an exception must release callback nesting suppression')
recording = false
G.FUNCS.cash_out()
recording = true
boundary = false
G.FUNCS.cash_out()
boundary = true
ctx.restoring = true
G.FUNCS.cash_out()
ctx.restoring = false
ctx.busy = true
G.FUNCS.cash_out()
ctx.busy = false
assert(#actions == 4, 'lifecycle and input-boundary guards are respected')
assert(prepared >= 5)

-- Acknowledged stable scenes stay cheap and clean through idle frames. Neither
-- the observer nor card selection creates history nodes or calls card:save.
local node_count = #actions
local first_card, second_card = {sort_id = 1}, {sort_id = 2}
G.hand.cards, G.hand.highlighted = {first_card, second_card}, {}
G.hand.config = {card_limit = 8, card_count = 2}
G.hand.save = function() error('observation must not serialize cards') end
G.GAME.pseudorandom = {seed = 'FIXED_SEED', shop = 0.1}
G.GAME.current_round = {hands_left = 4, discards_left = 3}
G.GAME.round_resets = {ante = 1, blind_choices = {Small = 'bl_small'}, blind_states = {Small = 'Select'}}
Hooks.reset()
assert(Hooks.poll(ctx), 'a new run needs its initial observation')
Hooks.acknowledge()
collectgarbage('collect'); collectgarbage('stop')
local idle_memory = collectgarbage('count')
for _ = 1, 10000 do assert(Hooks.poll(ctx) == false) end
local idle_growth = collectgarbage('count') - idle_memory
collectgarbage('restart')
assert(idle_growth < 64, 'idle observation must reuse its buffers, growth KiB: ' .. tostring(idle_growth))
assert(#actions == node_count)

local function detect(change, label)
    change()
    assert(Hooks.poll(ctx), label .. ' must invalidate the resume snapshot')
    assert(Hooks.poll(ctx), 'reading dirty must not acknowledge ' .. label)
    Hooks.acknowledge()
    assert(Hooks.poll(ctx) == false, 'a completed snapshot acknowledges ' .. label)
end
detect(function() G.hand.cards[1], G.hand.cards[2] = second_card, first_card end, 'drag/sort order')
detect(function() G.hand.highlighted[1] = first_card end, 'selection')
detect(function() G.hand.highlighted = {} end, 'selection removal')
detect(function() G.hand.cards[2] = nil end, 'card removal')
detect(function() G.hand.config.card_limit = 9 end, 'card limit')
detect(function() G.GAME.dollars = 8 end, 'cash mutation')
detect(function() G.GAME.dollars = nil end, 'removed scalar')
detect(function() G.GAME.current_round.hands_left = 3 end, 'remaining hands')
detect(function() G.GAME.pseudorandom.shop = 0.2 end, 'seed-bound RNG state')
detect(function() G.GAME.round_resets.blind_choices.Small = 'bl_big' end, 'blind choice')
detect(function() G.STATE = 8 end, 'native phase transition')
detect(function() G.hand = nil end, 'card area removal')
G.GAME.worldline_run_id, G.GAME.worldline_node_id, G.GAME.seeded = 'RUN', 8, true
assert(Hooks.poll(ctx) == false, 'checkpoint labels/progress lock are not gameplay mutations')
Hooks.invalidate()
assert(Hooks.poll(ctx) and Hooks.poll(ctx), 'an action stays dirty even without visible scalar changes')
Hooks.acknowledge()
assert(Hooks.poll(ctx) == false)
assert(#actions == node_count, 'observation changes resume state, not the coarse tree')
print('PASS hooks: coarse milestones only; card inputs and shopping details create no nodes')

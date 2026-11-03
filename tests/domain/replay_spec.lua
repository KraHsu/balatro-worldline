local Replay = dofile('src/domain/replay.lua')
local Choices = dofile('src/domain/choices.lua')
local function copy(value)
    if type(value) ~= 'table' then return value end
    local out = {}; for k,v in pairs(value) do out[k] = copy(v) end; return out
end
local snapshot = {seed='SEED', schema=1, extra={state='SHOP', selected={hand={1}},
    counters={ID=20, sort_id=40}, playing_order={1,2}}, save={GAME={dollars=10,seeded=false,
        worldline_run_id='run',worldline_node_id=2,pseudorandom={seed='SEED',shop=.23}},
        cardAreas={jokers={cards={{sort_id=4,highlighted=false,ability={extra=2}}}}}}}
local action = {kind='enter_shop', replay_schema=1, label='Shop',choices={
    {kind='buy',card_key='j_joker',card_id=4,name='Joker',count=1,cost=2,decision={schema=1}},
    {kind='leave_shop',count=1,decision={schema=1}}}}
local s,a = copy(snapshot),copy(action)
assert(Replay.matches(action,snapshot,a,s))
s.extra.counters.ID=999;s.extra.selected.hand={2};s.save.GAME.seeded=true
s.save.GAME.worldline_run_id='different';s.save.GAME.worldline_node_id=99
s.save.cardAreas.jokers.cards[1].highlighted=true
a.label='商店';a.choices[1].name='小丑牌';a.choices[1].atlas='new_texture'
assert(Replay.matches(action,snapshot,a,s),'UI state, discovery eligibility and localized names do not create a route')
s.save.GAME.viewed_back = '\"MANUAL_REPLACE\"'
assert(Replay.matches(action,snapshot,a,s), 'a menu Back placeholder cannot force a new route')
s.save.BACK = {name = 'Blue Deck'}
assert(not Replay.matches(action,snapshot,a,s), 'the actual selected deck remains gameplay state')
s.save.BACK = nil
s.save.GAME.pseudorandom.shop=.24
assert(not Replay.matches(action,snapshot,a,s),'seeded random stream position is gameplay state')
s.save.GAME.pseudorandom.shop=.23;s.extra.counters.sort_id=41
assert(not Replay.matches(action,snapshot,a,s),'stable card identity counters remain significant')
s=copy(snapshot);s.save.cardAreas.jokers.cards[1].ability.extra=3
assert(not Replay.matches(action,snapshot,a,s),'evolving card ability is not just cosmetic')
s=copy(snapshot);a=copy(action);a.choices[1],a.choices[2]=a.choices[2],a.choices[1]
assert(not Replay.matches(action,snapshot,a,s),'same ending state with different operation order is a separate route')
a=copy(action);a.replay_schema=nil
assert(not Replay.matches(action,snapshot,a,s),'old incomplete history is not guessed into a replay match')

-- A restored run allocates new process IDs. Saved runtime IDs are ignored,
-- while gameplay unique values, physical identities and array order remain
-- strict, including same-rank/suit playing cards and unopened offers.
local cards = copy(snapshot)
cards.save.cardAreas.jokers.cards[1].unique_val = .97
cards.save.cardAreas.jokers.cards[1].unique_val__saved_ID = 100
cards.save.cardAreas.deck = {cards = {
    {sort_id = 11, playing_card = 1, unique_val = .95, unique_val__saved_ID = 110,
        base = {suit = 'Spades', value = 'Ace'}, ability = {set = 'Default'}},
    {sort_id = 12, playing_card = 2, unique_val = .94, unique_val__saved_ID = 120,
        base = {suit = 'Spades', value = 'Ace'}, ability = {set = 'Default'}},
}}
cards.save.cardAreas.pack_cards = {cards = {
    {sort_id = 13, unique_val = .93, unique_val__saved_ID = 130,
        base = {suit = 'Hearts', value = 'King'}, ability = {set = 'Enhanced'}},
}}
cards.extra.opened_booster = {sort_id = 14, unique_val = .92, unique_val__saved_ID = 140,
    ability = {set = 'Booster', extra = 3}}
local replayed = copy(cards)
replayed.save.cardAreas.jokers.cards[1].unique_val = .31
replayed.save.cardAreas.jokers.cards[1].unique_val__saved_ID = 1000
replayed.save.cardAreas.deck.cards[1].unique_val = .30
replayed.save.cardAreas.deck.cards[1].unique_val__saved_ID = 1100
replayed.save.cardAreas.deck.cards[2].unique_val = .29
replayed.save.cardAreas.deck.cards[2].unique_val__saved_ID = 1200
replayed.save.cardAreas.pack_cards.cards[1].unique_val = .28
replayed.save.cardAreas.pack_cards.cards[1].unique_val__saved_ID = 1300
replayed.extra.opened_booster.unique_val = .27
replayed.extra.opened_booster.unique_val__saved_ID = 1400
assert(not Replay.matches(action, cards, action, replayed), 'different native gameplay unique values remain strict')
for name, area in pairs(replayed.save.cardAreas) do
    for index, card in ipairs(area.cards) do card.unique_val = cards.save.cardAreas[name].cards[index].unique_val end
end
replayed.extra.opened_booster.unique_val = cards.extra.opened_booster.unique_val
assert(Replay.matches(action, cards, action, replayed), 'runtime saved IDs alone are independent of gameplay values')
local changed = copy(replayed)
changed.save.cardAreas.deck.cards[1].unique_val, changed.save.cardAreas.deck.cards[2].unique_val = .29, .30
assert(not Replay.matches(action, cards, action, changed), 'duplicate playing cards with reversed tie order remain distinct')
changed = copy(replayed); changed.save.cardAreas.pack_cards.cards[1].unique_val = .305
assert(not Replay.matches(action, cards, action, changed), 'playing-card offers participate before they enter the owned deck')
changed = copy(replayed)
changed.save.cardAreas.deck.cards[1], changed.save.cardAreas.deck.cards[2] =
    changed.save.cardAreas.deck.cards[2], changed.save.cardAreas.deck.cards[1]
assert(not Replay.matches(action, cards, action, changed), 'normalization never ignores actual card array order')
changed = copy(replayed); changed.save.cardAreas.deck.cards[1].unique_val = nil
assert(not Replay.matches(action, cards, action, changed), 'missing unique values cannot prove equivalent tie ordering')
local tied, tied_replay = copy(cards), copy(replayed)
tied.save.cardAreas.deck.cards[2].unique_val = .95
tied_replay.save.cardAreas.deck.cards[2].unique_val = .30
assert(not Replay.matches(action, tied, action, tied_replay), 'absolute gameplay unique values are no longer weakened to relative order')
changed = copy(replayed); changed.save.GAME.unique_val = .3
assert(not Replay.matches(action, cards, action, changed), 'same-named arbitrary gameplay fields are never ignored')
changed = copy(replayed); changed.save.cardAreas.deck.cards[1].ability.unique_val = .3
assert(not Replay.matches(action, cards, action, changed), 'nested card ability fields remain strict')
changed = copy(replayed); changed.extra.opened_booster.ability.extra = 5
assert(not Replay.matches(action, cards, action, changed), 'booster identity normalization does not hide ability changes')

-- Raw unique_val order is insufficient: its additive contribution can cross
-- the native original-suit term even while the unique ordering stays the same.
-- This is an arithmetic fixture, not a change to any native gameplay formula.
local function native_nominal(original_suit, object_id)
    return 100 + .03 + original_suit * .0001 + .000001 * (1 - object_id / 1603301)
end
assert(1 - 100 / 1603301 > 1 - 1000 / 1603301
    and 1 - 100 / 1603301 > 1 - 2000000 / 1603301)
assert(native_nominal(.01, 100) < native_nominal(.02, 1000)
    and native_nominal(.01, 100) > native_nominal(.02, 2000000),
    'same relative unique order can still reverse full native nominal comparisons')
local nominal_before, nominal_after = copy(cards), copy(cards)
nominal_before.save.cardAreas.deck.cards[1].unique_val = 1 - 100 / 1603301
nominal_before.save.cardAreas.deck.cards[2].unique_val = 1 - 1000 / 1603301
nominal_after.save.cardAreas.deck.cards[1].unique_val = 1 - 100 / 1603301
nominal_after.save.cardAreas.deck.cards[2].unique_val = 1 - 2000000 / 1603301
assert(not Replay.matches(action, nominal_before, action, nominal_after),
    'uncertain native states stay as separate branches instead of weakening vanilla equivalence')
local x,y={sort_id=1},{sort_id=2}
G={hand={cards={x,y},highlighted={x}},jokers={cards={}},consumeables={cards={}}}
local first=Choices.finish(Choices.describe({kind='play'}),snapshot,snapshot)
G.hand.highlighted={y}
local second=Choices.finish(Choices.describe({kind='play'}),snapshot,snapshot)
local forward=Choices.append(Choices.append(nil,first),second)
local reverse=Choices.append(Choices.append(nil,second),first)
assert(#forward==1 and forward[1].count==2 and #forward[1].steps==2)
assert(not Replay.same_actions(forward,reverse),'aggregated hands retain their distinct action input sequence internally')
G.hand.highlighted={y,x}
local xy=Choices.describe({kind='play'})
G.hand.highlighted={x,y}
assert(Replay.same_actions(xy,Choices.describe({kind='play'})),'selection click order is not an action')
print('PASS replay: exact operation inputs and seeded state, conservative legacy handling, presentation exclusions')

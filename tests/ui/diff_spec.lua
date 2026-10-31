local previous_smods = SMODS; SMODS=nil
local Diff = dofile('src/ui/diff.lua')
SMODS=previous_smods
local Codec = dofile('src/storage/codec.lua')
local function copy(value)
    if type(value)~='table' then return value end
    local out={};for k,v in pairs(value) do out[k]=copy(v) end;return out
end
local function card(id,key)
    return {sort_id=id,save_fields={center=key},ability={set='Joker',extra=2},base={},cost=4,sell_cost=2}
end
local a={id=1,action={choices={{kind='buy',card_key='j_one'}}},summary={},snapshot={seed='S',
    extra={state='SHOP',playing_order={}},save={GAME={dollars=10,pseudorandom={seed='S',x=.1},
        hands={Pair={level=1,chips=10,mult=2}}},cardAreas={jokers={cards={card(1,'j_one'),card(2,'j_two')}}}}}}
local original = Codec.encode(a,TEST_JSON)
local b=copy(a);b.id=2
local same=Diff.compare(a,b)
assert(same.same and same.state_equal and #same.groups==0 and #same.metrics==0)
b.snapshot.save.GAME.dollars=8
b.snapshot.save.cardAreas.jokers.cards={card(1,'j_one'),card(3,'j_three')}
b.snapshot.save.cardAreas.jokers.cards[1].ability.extra=5
b.snapshot.save.GAME.hands.Pair.level=2
b.snapshot.save.GAME.pseudorandom.x=.2
b.action.choices={{kind='sell',card_key='j_two'}}
local changed=Diff.compare(a,b)
assert(not changed.same and changed.before_id==1 and changed.after_id==2 and changed.rng_changed)
assert(changed.metrics[1].key=='dollars' and changed.metrics[1].delta==-2)
assert(changed.groups[1].key=='jokers' and #changed.groups[1].changes==3)
assert(changed.groups[1].changes[1].kind=='changed'
    and changed.groups[1].changes[2].kind=='removed' and changed.groups[1].changes[3].kind=='added')
assert(#changed.hand_levels==1 and changed.hand_levels[1].after.level==2 and not changed.choices.same)
local reversed=Diff.compare(b,a)
assert(reversed.metrics[1].delta==2 and reversed.before_id==2)
changed.before.jokers[1].ability.extra=999
changed.choices.before[1].kind='discard'
assert(Codec.encode(a,TEST_JSON)==original,'comparison is detached and never edits source nodes')
b=copy(a);b.snapshot.save.cardAreas.jokers.cards[1],b.snapshot.save.cardAreas.jokers.cards[2]=
    b.snapshot.save.cardAreas.jokers.cards[2],b.snapshot.save.cardAreas.jokers.cards[1]
local moved=Diff.compare(a,b)
assert(moved.groups[1].changes[1].kind=='moved' and #moved.groups[1].changes==2)
b=copy(a);b.snapshot.save.GAME.hidden_gameplay_flag=true
local hidden=Diff.compare(a,b)
assert(not hidden.same and hidden.other_state_changed,'unlisted state differences never claim complete equality')
assert(Diff.compare(a,a).same)
print('PASS diff: item additions/removals/evolution/order, scalar and RNG changes, lazy detached presentation')

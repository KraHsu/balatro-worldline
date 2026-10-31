local Identity=dofile('src/video/identity.lua')
local old=G
G={hand={cards={{sort_id=1},{sort_id=3}}},jokers={cards={{sort_id=2}}}}
local map=Identity.new()
map:synchronize{save={cardAreas={hand={cards={{sort_id=10},{sort_id=30}}},jokers={cards={{sort_id=20}}}}}}
assert(map:resolve(30)==3 and map.live_to_record[2]==20)
assert(map:vector{30,10}[1]==3)
assert(not pcall(map.bind,map,25,1),'Two recorded objects cannot alias a live card')
assert(not pcall(map.bind,map,25,4),'RNG candidate order cannot cross an established identity')
G.hand.cards[2]=nil;map:prune()
assert(map.record_to_live[30]==nil)
map:bind(30,4)
G=old
print('PASS legacy replay identity: live monotone bijection, reference translation, alias/cross-order rejection and dead-card pruning')

local H=dofile('src/runtime/hand_order.lua')
local original_pairs=pairs
local hands={Pair={visible=true},Flush={visible=true},Straight={visible=true}}
local order={'Straight','Pair','Flush'}
H.install();H.bind(hands,order);order[1]='changed'
local recorded=H.capture(hands)
assert(table.concat(recorded,',')=='Straight,Pair,Flush','Recorded candidate order must survive reconstruction')
local candidate={};for key,value in pairs(hands)do if value.visible then candidate[#candidate+1]=key end end
assert(table.concat(candidate,',')=='Straight,Pair,Flush')
assert(not H.validate({'Straight','Pair','Pair'},hands))
assert(not H.validate({'Straight','Pair'},hands))
local plain={a=1,b=2};local actual={};for key,value in pairs(plain)do actual[key]=value end
assert(actual.a==1 and actual.b==2,'Unregistered tables keep ordinary pairs behavior')
pairs=original_pairs
print('PASS poker-hand order: restored native RNG candidate enumeration, detached metadata and ordinary-table passthrough')

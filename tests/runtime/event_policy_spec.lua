local Policy = dofile('src/runtime/event_policy.lua')
local Queue = dofile('src/runtime/input_queue.lua')
local calls, predicates, pulses = 0, 0, 0
local native_error = {}
EventManager = {}
function EventManager:add_event(event, queue, front)
    calls = calls + 1
    assert(queue == nil or queue == 'other')
    local target = self.queues[queue or 'base']
    if front then table.insert(target, 1, event) else target[#target + 1] = event end
    return event, nil, 'native'
end
G = {STAGE=1, STAGES={RUN=1}, STATE=1, STATES={SELECTING_HAND=1,GAME_OVER=2},
    STATE_COMPLETE=true, SETTINGS={paused=false}, GAME={round=1,blind_on_deck='Small',STOP_USE=0},
    CONTROLLER={locks={},dragging={}}, E_MANAGER={queues={base={},other={}}}}
for _,name in ipairs{'hand','deck','discard','play','jokers','consumeables','vouchers'}do G[name]={cards={}}end
setmetatable(G.E_MANAGER,{__index=EventManager})
local card={sort_id=10,area=G.consumeables}
function card:juice_up()pulses=pulses+1 end
local a,b={sort_id=1},{sort_id=2}
G.hand.cards,G.hand.highlighted={a,b},{a,b}
juice_card_until = function(c, predicate, first, delay)
    if c.fail then error(native_error) end
    return G.E_MANAGER:add_event({trigger='after',timer='REAL',delay=delay or 0.1,
        blocking=false,blockable=false,func=function()
            if predicate(c) then c:juice_up();juice_card_until(c,predicate,nil,0.8) end
            return true
        end})
end
local native_pulse = juice_card_until
assert(Policy.install() and not Policy.install(),'Install pulse provenance hooks only once')
local first, absent, native = juice_card_until(card,function()predicates=predicates+1;return true end,true)
assert(absent==nil and native=='native' and calls==1 and Policy.is_visual(first))
assert(predicates==0 and pulses==0,'Installing/classifying an event must never invoke its callback')
local Snapshot=dofile('src/runtime/snapshot.lua')
assert(Snapshot.is_stable(false),'A pending DNA-style pulse is an idle boundary')
local gameplay={trigger='after',timer='REAL',blocking=false,blockable=false}
G.E_MANAGER:add_event(gameplay)
assert(not Policy.is_visual(gameplay) and not Snapshot.is_stable(false),
    'Identical flags on an unrelated gameplay event are not sufficient to skip it')
local ctx={tree={},should_record=function()return true end,is_input_boundary=function()return Snapshot.is_stable(false)end}
local q=Queue.new(ctx)
assert(q:should_defer())
local executed=0
q:enqueue('use_card',{n=1,{config={ref_table=card}}},function()
    assert(G.hand.highlighted[1]==a and G.hand.highlighted[2]==b)
    executed=executed+1
end)
assert(not q:update()and executed==0)
table.remove(G.E_MANAGER.queues.base,2)
assert(q:update()and q:count()==0 and executed==1,
    'A queued two-card consumable executes when only the native pulse remains')
assert(first.func()and predicates==1 and pulses==1)
assert(Policy.is_visual(G.E_MANAGER.queues.base[2]),'Recursive native pulses keep their provenance')
assert(Snapshot.is_stable(false),'A perpetually nonempty pulse queue cannot deadlock input')
local ok,err=pcall(juice_card_until,{fail=true},function()end)
assert(not ok and err==native_error,'Preserve the original exception and restore tracking depth')
local untracked={trigger='after',timer='REAL',blocking=false,blockable=false}
G.E_MANAGER:add_event(untracked,'other',true)
assert(not Policy.is_visual(untracked),'A failed pulse must not tag later unrelated work')
local wrong_timer={trigger='after',timer='TOTAL',blocking=false,blockable=false,_worldline_visual='juice_card_until'}
assert(not Policy.is_visual(wrong_timer))
assert(native_pulse~=juice_card_until)
print('PASS event policy: recurring native pulse provenance, no scheduling/RNG effects, unrelated-event barriers and consumable queue recovery')

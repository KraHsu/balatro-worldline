local Cashout=dofile('src/runtime/cashout.lua')
local manager={}
local add=function(_,event)event.func()end
setmetatable(manager,{__index={add_event=add}})
local delay_calls=0
delay=function()delay_calls=delay_calls+1 end
play_sound=function()end
local native_delay,native_sound=delay,play_sound
local original_card={sort_id=42,config={center={key='j_golden',set='Joker'}}}
G={round_eval={},GAME={current_round={dollars=12,dollars_to_be_earned=''},dollars=37,
    blind={chips=300,chip_text='300',pos={x=0,y=0}}},
    E_MANAGER=manager,VIBRATION=0,jokers={cards={original_card}},ROOM={T={y=0}}}
local rendered,fail={},false
add_round_eval_row=function(config)
    delay(1)
    G.E_MANAGER:add_event{func=function()
        if fail then error('synthetic render failure')end
        rendered[#rendered+1]=config
        if config.name=='blind1' then assert(G.GAME.blind.chip_text=='300','Native reward row lost its defeated blind target')end
        G.GAME.current_round.dollars=999
        G.VIBRATION=100
        return true
    end}
end
Cashout.install()
local config={name='blind1',dollars=3,pitch=1}
add_round_eval_row(config);config.dollars=99
add_round_eval_row{name='hands',dollars=2,disp=2,bonus=true}
add_round_eval_row{name='joker1',dollars=7,card=original_card,bonus=true}
add_round_eval_row{name='bottom',dollars=12}
local data=Cashout.capture()
assert(Cashout.validate(data) and #data.rows==3 and data.rows[1].dollars==3 and data.rows[3].card_id==42)
assert(data.total==12 and data.rows[3].card==nil,'Snapshots cannot retain a live card object')
assert(data.rows[1].blind.chips==300)
G.GAME.blind.chips=0;G.GAME.blind.chip_text='0'
local restored_card={sort_id=42}
G.jokers.cards={restored_card}
create_UIBox_round_evaluation=function()return {native=true}end
local function box(definition)
    return {definition=definition,alignment={offset={}},add_child=function()end,get_UIE_by_ID=function()return {}end}
end
G.FUNCS={evaluate_round=function()error('Rewards must not be evaluated twice')end}
local count=delay_calls
G.GAME.current_round.dollars=12;G.VIBRATION=0;rendered={}
Cashout.rebuild(data,false,box)
assert(#rendered==4 and rendered[3].card==restored_card and rendered[4].name=='bottom')
assert(G.GAME.dollars==37 and G.GAME.current_round.dollars==12 and G.VIBRATION==0)
assert(G.GAME.current_round.dollars_to_be_earned=='' and delay_calls==count)
assert(G.GAME.blind.chips==0 and G.GAME.blind.chip_text=='0','Presentation must not restore the live blind target')
assert(manager.add_event==add and rawget(manager,'add_event')==nil and delay==native_delay and play_sound==native_sound,
    'Presentation overrides must be scoped, including inherited event-manager methods')
fail=true
assert(not pcall(Cashout.rebuild,data,false,box))
assert(manager.add_event==add and rawget(manager,'add_event')==nil and delay==native_delay and play_sound==native_sound)
assert(G.GAME.current_round.dollars==12 and G.VIBRATION==0)
assert(G.GAME.blind.chips==0 and G.GAME.blind.chip_text=='0')
assert(not Cashout.validate{schema=1,rows={{name='hands',bad=function()end}},total=1,hidden=0})
assert(not Cashout.validate{schema=1,rows={{name='blind1',blind=true}},total=1,hidden=0})
assert(not Cashout.validate{schema=1,rows={{name='blind1',blind={chips=300,chip_text='300',pos={}}}},total=1,hidden=0})
print('PASS cashout presentation: recorded native rows, rebound cards, no reward recalculation and exception-safe UI restoration')

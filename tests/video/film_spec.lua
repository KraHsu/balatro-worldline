local Film=dofile('src/video/plan.lua')
local Runtime=dofile('src/video/playback.lua')
local function fails(fn) local ok=pcall(fn);assert(not ok) end
local snap={save={GAME={dollars=5,pseudorandom={seed='TEST',shop=0.5}},cardAreas={hand={cards={}}}},extra={state='SHOP'}}
local nodes={
 [1]={id=1,snapshot=snap},
 [2]={id=2,parent=1,snapshot=snap,action={replay_schema=1,choices={
   {kind='play',count=2,steps={{hand={1},hand_order={1,2}},{hand={2},hand_order={2}}}},
   {kind='enter_shop',decision={hand={}}}}}},
 [3]={id=3,parent=2,snapshot=snap,action={replay_schema=1,choices={{kind='buy',card_id=4,card_key='j_joker'}}}},
 [4]={id=4,parent=1,snapshot=snap,action={replay_schema=1,choices={}}},
}
local tree={get=function(_,id) return nodes[id] end}
local plan=Film.plan(tree,1,3)
assert(plan.total==4 and #plan.edges==2 and plan.edges[1].steps[2].decision.hand[1]==2)
assert(nodes[2].action.choices[1].steps[1].hand[1]==1,'Planning must not mutate history')
fails(function() Film.plan(tree,2,4) end)
nodes[3].action.choices[1].replay_incomplete=true
assert(Film.plan(tree,1,3).warnings.incomplete_records,'Unverified Undo snapshots must warn rather than block recorded inputs')
nodes[3].action.replay_schema=nil
assert(Film.plan(tree,1,3).total==4,'Historical incomplete batches retain playable input order')
nodes[3].action.replay_schema=1
nodes[3].action.choices[1].replay_incomplete=nil
assert(not Film.plan(tree,1,3).warnings.incomplete_records)
local saved_steps=nodes[2].action.choices[1].steps
nodes[2].action.choices[1].steps=nil
fails(function() Film.plan(tree,1,3) end)
nodes[2].action.choices[1].steps=saved_steps
fails(function() Film.plan(tree,1,4) end)
fails(function() Film.options{speed=0} end)
fails(function() Film.options{fps=144} end)
assert(Film.options{height=1440}.height==1440 and Film.options{}.height==720)
fails(function()Film.options{height=2160}end)
fails(function() Film.options{ffmpeg='ffmpeg\nBAD'} end)
assert(Film.options{ffmpeg='C:/测试 & 文件/ffmpeg.exe'}.ffmpeg=='C:/测试 & 文件/ffmpeg.exe')
assert(Film.options{output_dir='D:\\视频 & 导出\\'}.output_dir=='D:/视频 & 导出')
assert(Film.options{output_dir='D:/'}.output_dir=='D:/')
fails(function()Film.options{output_dir='relative/videos'}end)
fails(function()Film.options{output_dir='C:/bad\npath'}end)
local changed={save={GAME={dollars=6,pseudorandom={seed='TEST',shop=0.5}},cardAreas={hand={cards={}}}},extra={state='SHOP'}}
assert(not Film.verify(changed,snap),'Divergence cannot be hidden by injecting the next checkpoint')
changed.save.GAME.dollars=5;assert(Film.verify(changed,snap))
changed.save.GAME.viewed_back='\"MANUAL_REPLACE\"'
assert(Film.verify(changed,snap),'A discarded menu Back preview is not replay divergence')
changed.save.BACK={name='Blue Deck'}
assert(not Film.verify(changed,snap),'The actual selected deck must still match')
changed.save.BACK=nil
changed.save.GAME.pseudorandom.shop=0.6;assert(not Film.verify(changed,snap))
changed.save.GAME.pseudorandom.shop=0.5
changed.save.GAME.orbital_choices={Small='Pair'}
assert(not Film.verify(changed,snap))
assert(Film.verify(changed,snap,{ignore_unused_orbitals=true}))
changed.save.GAME.pseudorandom.shop=0.6
assert(not Film.verify(changed,snap,{ignore_unused_orbitals=true}),'Unused-cache policy must never ignore RNG state')
local visual={save={GAME=snap.save.GAME,cardAreas={hand={cards={},blueprint_compat_check='compatible',blueprint_compat_ui='Compatible'}}},extra=snap.extra}
assert(Film.verify(visual,snap),'Tooltip-only compatibility cache cannot reject playback')
local flat={save={GAME=snap.save.GAME,cardAreas={hand={cards={{ability={mod_num=1,consumeable={mod_num=1}}}}}}},extra=snap.extra}
local nested={save={GAME=snap.save.GAME,cardAreas={hand={cards={{ability={consumeable={mod_num=1}}}}}}},extra=snap.extra}
assert(Film.verify(flat,nested),'Unused top-level consumable config copies cannot reject playback')
nested.save.cardAreas.hand.cards[1].ability.consumeable.mod_num=2
assert(not Film.verify(flat,nested),'The native consumable use limit must remain strict')
changed.save.GAME.pseudorandom.shop=0.5;changed.save.GAME.orbital_choices=nil
changed.save.GAME.used_jokers={m_bonus=true};snap.save.GAME.used_jokers={}
assert(Film.verify(changed,snap),'Playing-card centres do not use duplicate-suppression entries')
changed.save.GAME.used_jokers.j_joker=true
assert(not Film.verify(changed,snap),'Joker pool suppression must remain strict')
changed.save.GAME.used_jokers={c_death=true}
assert(not Film.verify(changed,snap),'Consumable pool suppression must remain strict')
changed.save.GAME.used_jokers={}
local function serials(first,second)
 return {save={GAME=snap.save.GAME,cardAreas={deck={cards={{sort_id=1,playing_card=first},{sort_id=2,playing_card=second}}}}},extra=snap.extra}
end
assert(not Film.verify(serials(1,2),serials(10,20)))
assert(Film.verify(serials(1,2),serials(10,20),{legacy_playing_ids=true}))
assert(not Film.verify(serials(1,1),serials(10,20),{legacy_playing_ids=true}),'Legacy serial comparison must preserve identity, not erase numbers')
assert(not Film.verify(serials(1,nil),serials(10,20),{legacy_playing_ids=true}),'Card presence/type must remain strict')
local creation_a,creation_b=serials(1,2),serials(10,20)
for i=1,2 do
 creation_a.save.cardAreas.deck.cards[i].params={playing_card=30+i}
 creation_b.save.cardAreas.deck.cards[i].params={playing_card=50+i}
end
assert(not Film.verify(creation_a,creation_b))
creation_b.save.cardAreas.deck.cards[2].params.playing_card=nil
assert(Film.verify(creation_a,creation_b,{legacy_playing_ids=true}),'Legacy load may omit unused construction serials')
creation_b.save.cardAreas.deck.cards[2].playing_card=10
assert(not Film.verify(creation_a,creation_b,{legacy_playing_ids=true}),'Current playing-card serials must retain their identity')
local a,b={sort_id=1},{sort_id=2}
local calls=0
G={hand={cards={a,b},config={},highlighted={},unhighlight_all=function(self) self.highlighted={} end,
    add_to_highlighted=function(self,c) self.highlighted[#self.highlighted+1]=c end},
    jokers={cards={}},consumeables={cards={}},FUNCS={play_cards_from_highlighted=function()
        calls=calls+1;assert(G.hand.cards[1]==b and G.hand.highlighted[1]==a)
    end}}
Runtime.dispatch{callback='play_cards_from_highlighted',kind='play',decision={hand_order={2,1},hand={1},hand_sort='suit'}}
assert(calls==1 and G.hand.config.sort=='suit')
fails(function() Runtime.dispatch{callback='play_cards_from_highlighted',kind='play',decision={hand={99}}} end)
assert(calls==1,'Missing inputs must fail before a native callback')
G.shop_jokers={cards={{sort_id=4,config={center={key='j_joker'}}}}}
G.FUNCS.buy_from_shop=function(e) assert(e.config.ref_table.sort_id==4);calls=calls+1 end
Runtime.dispatch{kind='buy',callback='buy_from_shop',card_id=4,card_key='j_joker'}
assert(calls==2)
local Identity=dofile('src/video/identity.lua')
G.pack_cards={cards={{sort_id=5,config={center={key='c_base'}},base={value='Ten',suit='Spades'}},
    {sort_id=6,config={center={key='c_base'}},base={value='Ten',suit='Hearts'}}}}
G.FUNCS.use_card=function(e)assert(e.config.ref_table.sort_id==6);calls=calls+1 end
local identity=Identity.new()
Runtime.dispatch({kind='take_from_pack',callback='use_card',card_id=16,card_key='c_base',set='Default',rank='Ten',suit='Hearts'},identity)
assert(identity:resolve(16)==6 and calls==3,'Legacy pack references require a unique matching card and preserve identity order')
fails(function() Runtime.dispatch{kind='buy',callback='buy_from_shop',card_id=4,card_key='j_wrong'} end)
assert(calls==3)
local exits=0
G.GAME={won=true};G.OVERLAY_MENU={get_UIE_by_ID=function(_,id)return id=='you_win_UI' end}
G.FUNCS.exit_overlay_menu=function()exits=exits+1;G.OVERLAY_MENU=nil end
G.I={UIBOX={{config={button='exit_overlay_menu'}}}}
assert(not Runtime.continue_won_run({snapshot={save={GAME={won=true}}}},{kind='play'}))
assert(Runtime.continue_won_run({snapshot={save={GAME={won=true}}}},{kind='enter_shop'}) and exits==1)
assert(not Runtime.continue_won_run({snapshot={save={GAME={won=true}}}},{kind='enter_shop'}))
local input,output={},{}
local function channel(items)
    return {push=function(_,v) items[#items+1]=v end,
        pop=function() return table.remove(items,1) end,
        clear=function() for k in pairs(items) do items[k]=nil end end}
end
local finished=0
love={}
G.SETTINGS={GAMESPEED=4}
local r=Runtime.new({},Film,{},nil,function() finished=finished+1 end)
r.active,r.phase,r.requests,r.responses,r.old_speed=true,'starting',channel(input),channel(output),4
r:cancel()
assert(r.active and r.phase=='encoding' and input[1].kind=='cancel' and finished==0,
    'Startup cancellation must wait for worker acknowledgement')
output[1]={kind='cancelled'}
r:poll();r:complete()
assert(not r.active and finished==1 and #input==0 and #output==0,
    'Completed workers must release queued frame data')
print('PASS film: ancestor routes, incomplete-record warnings, missing-input rejection, native targets, RNG divergence and safe configuration')

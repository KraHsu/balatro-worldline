-- Record the native presentation messages, never re-evaluate round rewards.
local Cashout={}
local cache=setmetatable({},{__mode='k'})
local fields={'name','dollars','disp','bonus','saved','pitch','condition','pos','text','text_scale',
    'text_colour','number','number_scale','number_colour','loc_opts'}
local translate=function(_,en)return en end
local function plain(value,depth,seen)
    local kind=type(value)
    if kind=='nil' or kind=='boolean' then return value end
    if kind=='number' then assert(value==value and math.abs(value)~=math.huge,'Invalid cashout number');return value end
    if kind=='string' then assert(#value<=4096,'Cashout text is too long');return value end
    assert(kind=='table' and (depth or 0)<5,'Invalid cashout data')
    seen=seen or {};assert(not seen[value],'Cyclic cashout data');seen[value]=true
    local out,count={},0
    for key,item in pairs(value) do
        assert(type(key)=='number' or type(key)=='string','Invalid cashout key')
        count=count+1;assert(count<=128,'Cashout data is too large')
        out[key]=plain(item,(depth or 0)+1,seen)
    end
    seen[value]=nil;return out
end
function Cashout.validate(data)
    if data==nil then return true end
    local ok=pcall(function()
        assert(type(data)=='table' and data.schema==1 and type(data.rows)=='table' and #data.rows<=7)
        assert(type(data.total)=='number' and type(data.hidden)=='number' and data.hidden>=0 and data.hidden%1==0)
        plain(data.total);plain(data.hidden)
        for _,row in ipairs(data.rows) do
            assert(type(row)=='table' and type(row.name)=='string' and row.name~='bottom')
            plain(row)
            if row.card_id~=nil then assert(type(row.card_id)=='number' and row.card_id>=0 and row.card_id%1==0) end
            if row.blind~=nil then
                local blind=row.blind
                assert(type(blind)=='table' and type(blind.chips)=='number' and type(blind.chip_text)=='string')
                assert(type(blind.pos)=='table' and type(blind.pos.x)=='number' and type(blind.pos.y)=='number')
            end
        end
    end)
    return ok or nil,ok and nil or 'invalid_cashout_presentation'
end
function Cashout.install(text)
    translate=text or translate
    if Cashout.installed or type(add_round_eval_row)~='function' then return end
    Cashout.installed=true
    local original=add_round_eval_row
    add_round_eval_row=function(config,...)
        if G and G.round_eval and type(config)=='table' then
            local data=cache[G.round_eval]
            if not data or config.name=='blind1' then data={schema=1,rows={},hidden=0,total=0};cache[G.round_eval]=data end
            if config.name=='bottom' then data.total=config.dollars or 0
            elseif #data.rows<7 then
                local row={}
                for _,key in ipairs(fields) do row[key]=plain(config[key]) end
                if config.name=='blind1' and G.GAME and G.GAME.blind then
                    local blind=G.GAME.blind
                    -- The defeated blind clears itself before cashout settles.
                    -- Keep its displayed target/chip, not just the reward amount.
                    row.blind=plain{chips=blind.chips,chip_text=blind.chip_text,pos=blind.pos}
                end
                if config.card then
                    row.card_id=config.card.sort_id
                    local center=config.card.config and config.card.config.center
                    row.card_key=center and center.key;row.card_set=center and center.set
                end
                data.rows[#data.rows+1]=row
            else data.hidden=data.hidden+1 end
        end
        return original(config,...)
    end
end
function Cashout.capture() return G and G.round_eval and cache[G.round_eval] end
local function legacy()
    local game=G.GAME;local round=game.current_round;local modifiers=game.modifiers or {}
    local total=round.dollars or 0
    local blind=game.blind;local won=(game.chips or 0)>=(blind.chips or 0)
    local rows={{name='blind1',dollars=won and (blind.dollars or 0) or 0,saved=not won,pitch=1}}
    local accounted=rows[1].dollars
    local function add(name,dollars,disp)
        if dollars~=0 then rows[#rows+1]={name=name,dollars=dollars,disp=disp,bonus=true,pitch=1};accounted=accounted+dollars end
    end
    if not modifiers.no_extra_hand_money then add('hands',(round.hands_left or 0)*(modifiers.money_per_hand or 1),round.hands_left) end
    if modifiers.money_per_discard then add('discards',(round.discards_left or 0)*modifiers.money_per_discard,round.discards_left) end
    if (game.dollars or 0)>=5 and not modifiers.no_interest then
        add('interest',(game.interest_amount or 1)*math.min(math.floor(game.dollars/5),(game.interest_cap or 25)/5))
    end
    if accounted~=total then rows[#rows+1]={name='custom_legacy',text=translate(nil,'Other rewards'),dollars=total-accounted,bonus=true,pitch=1} end
    return {schema=1,rows=rows,hidden=0,total=total}
end
function Cashout.rebuild(data,hidden,box)
    data=data or legacy();assert(Cashout.validate(data))
    local cards={}
    for _,name in ipairs({'jokers','consumeables','hand','deck','discard','play'}) do
        for _,card in ipairs(G[name] and G[name].cards or {}) do cards[card.sort_id]=card end
    end
    G.round_eval=box(create_UIBox_round_evaluation(),'bm',hidden and G.ROOM.T.y+29 or -7.8)
    if hidden then G.round_eval.alignment.offset.py=-7.8 end
    local manager=G.E_MANAGER
    local previous_add=rawget(manager,'add_event')
    local previous_delay,previous_sound,previous_count=delay,play_sound,total_cashout_rows
    local previous_vibration=G.VIBRATION
    local blind=G.GAME.blind
    local blind_chips,blind_text,blind_pos=blind.chips,blind.chip_text,blind.pos
    local round=G.GAME.current_round;local earned,dollars=round.dollars_to_be_earned,round.dollars
    manager.add_event=function(_,event) if event.func then assert(event.func()~=false,'Cashout UI event did not finish') end end
    delay=function()end;play_sound=function()end;total_cashout_rows=0
    local ok,err=pcall(function()
        for _,saved in ipairs(data.rows) do
            local row=plain(saved)
            if row.card_id then
                row.card=cards[row.card_id]
                if not row.card then
                    row.name='custom_saved';row.text=localize{type='name_text',set=row.card_set or 'Joker',key=row.card_key}
                end
            end
            if row.name=='blind1' then
                round.dollars_to_be_earned=string.rep('$',math.min(60,math.max(0,math.floor(row.dollars or 0))))
                if row.blind then blind.chips,blind.chip_text,blind.pos=row.blind.chips,row.blind.chip_text,row.blind.pos end
            end
            add_round_eval_row(row)
            blind.chips,blind.chip_text,blind.pos=blind_chips,blind_text,blind_pos
        end
        if data.hidden>0 then
            G.round_eval:add_child({n=G.UIT.R,config={align='cm'},nodes={{n=G.UIT.T,config={
                text=localize{type='variable',key='cashout_hidden',vars={data.hidden}},scale=0.35,colour=G.C.UI.TEXT_LIGHT}}}},
                G.round_eval:get_UIE_by_ID('bonus_round_eval'))
        end
        add_round_eval_row{name='bottom',dollars=data.total,pitch=1}
    end)
    rawset(manager,'add_event',previous_add)
    delay,play_sound,total_cashout_rows=previous_delay,previous_sound,previous_count
    round.dollars_to_be_earned,round.dollars=earned,dollars;G.VIBRATION=previous_vibration
    blind.chips,blind.chip_text,blind.pos=blind_chips,blind_text,blind_pos
    if not ok then error(err,0) end
    cache[G.round_eval]=data
end
return Cashout

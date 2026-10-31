-- Pure recording plans. Only existing inputs on one ancestor path are replayed.
local Film = {}
local callbacks = {play='play_cards_from_highlighted', discard='discard_cards_from_highlighted',
    buy='buy_from_shop', sell='sell_card', reroll_shop='reroll_shop', use='use_card',
    open_booster='use_card', redeem='use_card', take_from_pack='use_card',
    skip_booster='skip_booster', select_blind='select_blind', skip_blind='skip_blind',
    enter_shop='cash_out', leave_shop='toggle_shop', reroll_boss='reroll_boss'}
Film.callbacks = callbacks
local function copy(value)
    if type(value)~='table' then return value end
    local out={} for k,v in pairs(value) do out[k]=copy(v) end return out
end
function Film.options(value)
    value=value or {}
    local out={speed=tonumber(value.speed) or 1, fps=tonumber(value.fps) or 30,
        pause_seconds=tonumber(value.pause_seconds) or 1.5,
        action_delay=tonumber(value.action_delay) or 0.35,
        pause_consumables=value.pause_consumables~=false, show_pack=value.show_pack~=false,
        ffmpeg=tostring(value.ffmpeg or 'ffmpeg'),output_dir=tostring(value.output_dir or ''),height=tonumber(value.height) or 720}
    assert(out.speed>=0.25 and out.speed<=8,'Recording speed must be between 0.25 and 8')
    assert(out.fps==30 or out.fps==60,'Recording frame rate must be 30 or 60')
    assert(out.height==720 or out.height==1080 or out.height==1440,'Video resolution must be 720p, 1080p or 2K')
    assert(out.pause_seconds>=0.25 and out.pause_seconds<=10,'Information pause must be between 0.25 and 10 seconds')
    assert(out.action_delay>=0 and out.action_delay<=5,'Action delay must be between 0 and 5 seconds')
    assert(#out.ffmpeg>0 and #out.ffmpeg<=2048 and not out.ffmpeg:find('[%z\r\n]'),'Invalid FFmpeg path')
    out.output_dir=out.output_dir:gsub('\\','/')
    if #out.output_dir>3 then out.output_dir=out.output_dir:gsub('/+$','') end
    assert(#out.output_dir<=2048 and not out.output_dir:find('[%z\r\n]'),'Invalid output directory')
    assert(out.output_dir=='' or out.output_dir:match('^%a:/') or out.output_dir:sub(1,2)=='//',
        'Use an absolute output directory')
    return out
end
local function expand(record, out, warnings)
    -- This flag describes an unverified Undo boundary, not lost input. The
    -- observer still retained callback order, target IDs and hand selections.
    if record.replay_incomplete then warnings.incomplete_records=true end
    local callback=callbacks[record.kind]
    if record.kind=='run_failed' then return end -- Terminal state follows the preceding play.
    assert(callback,'This route contains an unsupported recording action: '..tostring(record.kind))
    if record.kind=='play' or record.kind=='discard' then
        assert(type(record.steps)=='table' and #record.steps==(record.count or 1),
            'This legacy route lacks per-hand recording inputs')
        local description={}
        for key,value in pairs(record) do if key~='steps' then description[key]=value end end
        for _,decision in ipairs(record.steps) do
            assert(type(decision.hand)=='table' and #decision.hand>0,'Missing selected cards')
            local step=copy(description); step.decision=copy(decision); step.callback=callback
            out[#out+1]=step
        end
    else
        local step=copy(record); step.callback=callback
        out[#out+1]=step
    end
end
local function boundary_inputs(snapshot)
    -- Inventory/hand drags and deck-view sorting are player inputs, not new
    -- stage nodes. The recorded boundary retains their final arrangement.
    local input={playing_card_order=copy(snapshot.extra.playing_order),
        hand=copy(snapshot.extra.selected and snapshot.extra.selected.hand or {})}
    for area,key in pairs{jokers='jokers',consumeables='consumables',hand='hand_order'} do
        local saved=snapshot.save.cardAreas[area]
        if saved then
            local ids={};for _,card in ipairs(saved.cards or {})do ids[#ids+1]=card.sort_id end
            input[key]=ids
            if area=='hand' then input.hand_sort=saved.config and saved.config.sort end
        end
    end
    return input
end
function Film.plan(tree, first, last, options)
    assert(tree and tree.get,'No worldline available')
    first,last=tonumber(first),tonumber(last)
    assert(tree:get(first) and tree:get(last),'Select two recording endpoints')
    local path, node={},tree:get(last)
    while node and node.id~=first do
        path[#path+1]=node
        node=node.parent and tree:get(node.parent)
        assert(#path<=10000,'Recording route is too long')
    end
    assert(node and node.id==first,'Recording end must descend from its start')
    local edges,total,warnings={},0,{}
    warnings.legacy_poker_order=tree:get(first).snapshot.extra.poker_hand_order==nil or nil
    local no_blind_skips=true
    for i=#path,1,-1 do
        local target=path[i]
        local action=target.action or {}
        if not target.snapshot.extra.poker_hand_order then warnings.legacy_poker_order=true end
        if action.replay_schema~=1 then warnings.incomplete_records=true end
        local steps={}
        if type(action.choices)=='table' and #action.choices>0 then
            for _,record in ipairs(action.choices) do expand(record,steps,warnings) end
        elseif action.kind~='run_failed' then
            -- Without choices even milestone inputs may have been lost.
            error('This legacy route lacks recording inputs')
        end
        for _,step in ipairs(steps) do
            if step.kind=='skip_blind' then no_blind_skips=false end
            local d=step.decision
            if d and not d.hand_order then warnings.legacy_order=true end
            if d and not d.playing_card_order then warnings.legacy_playing_order=true end
            if d and not d.counters then warnings.legacy_identity=true end
            if (step.kind=='buy' or step.kind=='sell' or step.kind=='use'
                or step.kind=='open_booster' or step.kind=='redeem' or step.kind=='take_from_pack') then
                assert(step.card_id or step.card_key,'Missing recording card target')
            end
        end
        total=total+#steps
        assert(total<=20000,'Recording route contains too many actions')
        edges[#edges+1]={id=target.id,steps=steps,snapshot=target.snapshot,boundary_input=boundary_inputs(target.snapshot)}
    end
    return {first=first,last=last,start=tree:get(first).snapshot,edges=edges,total=total,
        options=Film.options(options),warnings=warnings,
        verification={ignore_unused_orbitals=warnings.legacy_poker_order and no_blind_skips or false,
            legacy_playing_ids=warnings.legacy_poker_order==true or warnings.legacy_playing_order==true,
            legacy_sort_ids=warnings.legacy_identity==true}}
end
-- Full saved gameplay data, excluding visual randomness, UI selection and clocks.
-- A mismatch stops export; checkpoints are never injected to hide a failed replay.
local ignored={unique_val=true,unique_val__saved_ID=true,highlighted=true,seeded=true,alerted=true,
    worldline_run_id=true,worldline_node_id=true,play_time=true,
    -- Blueprint/Brainstorm tooltip colour/text caches; native scoring uses
    -- the target centre's blueprint_compat instead of these hover fields.
    blueprint_compat_check=true,blueprint_compat_ui=true}
local saved_objects={blind=true,selected_back=true,current_scoring_calculation=true,tags=true}
local playing_centres={c_base=true,m_bonus=true,m_mult=true,m_wild=true,m_glass=true,
    m_steel=true,m_stone=true,m_gold=true,m_lucky=true}
local function omit(path,key,policy)
    return ignored[key] or path=='GAME' and saved_objects[key]
        -- Native Card:set_ability/remove also writes playing-card centres to
        -- this duplicate-suppression map. Enhanced pools explicitly bypass
        -- it; actual deck enhancements and every Joker/consumable entry remain
        -- checked. Pack/preview lifetime can leave these unused entries stale.
        or path=='GAME.used_jokers' and playing_centres[key]
        -- SMODS shares consumable.config with ability.consumeable. Native
        -- update writes mod_num there, so later cards may also copy a stale
        -- top-level value. Only consumeable.mod_num controls card use.
        or key=='mod_num' and path:match('^cardAreas%.[^.]+%.cards%.%d+%.ability$')
        -- Construction-only metadata. Card:load can omit it and copy_card
        -- overwrites it, even through a shared params table. Runtime uses the
        -- card.playing_card serial, which still requires a bijection below.
        or key=='playing_card' and path:match('^cardAreas%.[^.]+%.cards%.%d+%.params$')
            and policy and policy.legacy_playing_ids
        or path=='GAME' and key=='orbital_choices' and policy and policy.ignore_unused_orbitals
        or path=='GAME.round_resets.blind' and key=='discovered'
        or path:match('^GAME%.round_scores%.[^.]+$') and key=='high_score'
end
local function same(a,b,path,policy)
    if policy and policy.identity and path:match('^cardAreas%.[^.]+%.cards%.%d+%.sort_id$') then
        return policy.identity.live_to_record[a]==b,path
    end
    if policy and policy.legacy_playing_ids and path:match('^cardAreas%.[^.]+%.cards%.%d+%.playing_card$') then
        -- Native Card:remove renumbers these serials in G.playing_cards order.
        -- Legacy logs omit deck-view sorting. Keep a bijection, not arbitrary
        -- ID erasure; sort_id, unique nominal inputs and all card data still match.
        if type(a)=='number' and type(b)=='number' and a>0 and b>0 and a%1==0 and b%1==0 then
            local forward,reverse=policy.playing_forward,policy.playing_reverse
            if forward[a] and forward[a]~=b or reverse[b] and reverse[b]~=a then return false,path end
            forward[a],reverse[b]=b,a;return true
        end
    end
    if path=='SCORING_CALC.config' and (type(a)=='table' and next(a)==nil and b==nil
        or type(b)=='table' and next(b)==nil and a==nil) then return true end
    if type(a)~=type(b) then return false,path end
    if type(a)~='table' then return a==b,path end
    for k,v in pairs(a) do
        if not omit(path,k,policy) then local ok,why=same(v,b[k],path..'.'..tostring(k),policy);if not ok then return false,why end end
    end
    for k in pairs(b) do if not omit(path,k,policy) and a[k]==nil then return false,path..'.'..tostring(k) end end
    return true
end
function Film.verify(actual,expected,policy)
    if not actual or not expected then return false,'snapshot' end
    local ok,why=same(actual.save.GAME,expected.save.GAME,'GAME',policy)
    if not ok then return false,why end
    if actual.extra.state~=expected.extra.state then return false,'state' end
    if expected.extra.poker_hand_order then
        local equal,where=same(actual.extra.poker_hand_order,expected.extra.poker_hand_order,'poker_hand_order')
        if not equal then return false,where end
    end
    for _,key in ipairs({'BLIND','BACK','SCORING_CALC','tags'}) do
        local equal,where=same(actual.save[key],expected.save[key],key)
        if not equal then return false,where end
    end
    local context=policy and {legacy_playing_ids=policy.legacy_playing_ids,identity=policy.identity,
        playing_forward={},playing_reverse={}}
    return same(actual.save.cardAreas,expected.save.cardAreas,'cardAreas',context)
end
return Film

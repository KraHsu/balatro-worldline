local Loader
if SMODS and SMODS.load_file then
    Loader = assert(SMODS.load_file('loader.lua', 'WorldLine'))()
else
    Loader = dofile('src/loader.lua')
end
-- Native callback playback plus bounded screenshot streaming. The current run
-- and profile are restored on completion, cancellation, or a replay mismatch.
local Runtime={};Runtime.__index=Runtime
local Identity=Loader.load('film_identity')
local function copy(v) if type(v)~='table' then return v end local o={} for k,x in pairs(v) do o[k]=copy(x) end return o end
local areas={'hand','jokers','consumeables','shop_jokers','shop_vouchers','shop_booster','pack_cards'}
local function target_matches(step,card,name)
    if (step.from_pack or step.kind=='take_from_pack') and name~='pack_cards' then return false end
    local center=card.config and card.config.center
    if not center or center.key~=step.card_key then return false end
    local base=card.base or {}
    if step.rank~=nil and step.rank~=(base.value or base.id) then return false end
    if step.suit~=nil and step.suit~=base.suit then return false end
    if step.set then
        if step.seal~=card.seal then return false end
        for key,value in pairs(step.edition or {})do if (card.edition or {})[key]~=value then return false end end
        for key,value in pairs(card.edition or {})do if (step.edition or {})[key]~=value then return false end end
    end
    return true
end
local function find_card(step,identity)
    local matches={}
    for _,name in ipairs(areas) do for _,card in ipairs(G[name] and G[name].cards or {}) do
        local key=card.config and card.config.center and card.config.center.key
        local wanted=step.card_id and (not identity and step.card_id or identity.record_to_live[step.card_id])
        if wanted and card.sort_id==wanted then
            assert(not step.card_key or key==step.card_key,'Recording target card changed');return card
        end
        if target_matches(step,card,name) then matches[#matches+1]=card end
    end end
    if identity and #matches==1 and step.card_id then identity:bind(step.card_id,matches[1].sort_id);return matches[1]end
    assert(not step.card_id and #matches==1,'Recording target card is missing or ambiguous: '..tostring(step.kind)..' #'..tostring(step.card_id)..' / '..tostring(step.card_key))
    return matches[1]
end
local function arrange(area,ids)
    if not ids or #ids==0 then return end
    assert(area and #area.cards==#ids,'Recorded card order does not match the current area')
    local by_id={} for _,card in ipairs(area.cards) do by_id[card.sort_id]=card end
    for i,id in ipairs(ids) do assert(by_id[id],'Recorded card is missing');area.cards[i]=by_id[id];by_id[id]=nil end
    assert(next(by_id)==nil,'Recorded card order is incomplete')
    if area.align_cards then area:align_cards() end
end
local function prepare_inputs(step,identity)
    local d=step.decision or {}
    if identity then
        identity:prune()
        identity:area(G.jokers,d.jokers);identity:area(G.consumeables,d.consumables);identity:area(G.hand,d.hand_order)
        if d.playing_card_order and G.playing_cards then identity:area({cards=G.playing_cards},d.playing_card_order)end
        d=copy(d)
        for _,key in ipairs{'jokers','consumables','hand_order','hand','playing_card_order'}do d[key]=identity:vector(d[key])end
    end
    if d.counters then
        for key,value in pairs(d.counters)do
            assert((key=='sort_id' or key=='playing_card') and type(value)=='number' and value>=0
                and value<=9007199254740991 and value%1==0,'Invalid recorded card counter')
        end
        if d.counters.sort_id then
            for _,name in ipairs(Identity.AREAS)do for _,card in ipairs(G[name] and G[name].cards or {})do
                assert(card.sort_id<=d.counters.sort_id,'Recorded counter overlaps a live card')
            end end
            G.sort_id=d.counters.sort_id
        end
        if d.counters.playing_card then G.playing_card=d.counters.playing_card end
    end
    if d.hand_sort and G.hand and G.hand.config then G.hand.config.sort=d.hand_sort end
    arrange(G.jokers,d.jokers);arrange(G.consumeables,d.consumables)
    arrange(G.hand,d.hand_order)
    if d.playing_card_order and G.playing_cards then arrange({cards=G.playing_cards},d.playing_card_order) end
    if G.hand and G.hand.unhighlight_all then G.hand:unhighlight_all() end
    local selected={}
    for _,id in ipairs(d.hand or {}) do
        local found
        for _,card in ipairs(G.hand and G.hand.cards or {}) do if card.sort_id==id then found=card;break end end
        assert(found,'A selected recording card is missing')
        selected[#selected+1]=found
    end
    -- Legacy inputs retain the relative order of selected targets, enough for
    -- Death's left/right relationship. Full hand ordering is recorded in new runs.
    if not d.hand_order and #selected>1 then
        local set={} for _,card in ipairs(selected) do set[card]=true end
        local i=1 for slot,card in ipairs(G.hand.cards) do if set[card] then G.hand.cards[slot]=selected[i];i=i+1 end end
        if G.hand.align_cards then G.hand:align_cards() end
    end
    for _,card in ipairs(selected) do G.hand:add_to_highlighted(card,true) end
end
local function native_button(name,key)
    local seen={}
    local function walk(node)
        if type(node)~='table' or seen[node] then return end
        seen[node]=true
        if node.config and node.config.button==name and (not key
            or node.config.ref_table and node.config.ref_table.key==key) then return node end
        for _,child in pairs(node.children or {}) do local found=walk(child);if found then return found end end
        if node.UIRoot then return walk(node.UIRoot) end
    end
    local choice=G.blind_select_opts and G.GAME and G.blind_select_opts[G.GAME.blind_on_deck]
    if choice then local found=walk(choice);if found then return found end end
    for _,box in ipairs(G.I and G.I.UIBOX or {}) do local found=walk(box);if found then return found end end
end
function Runtime.continue_won_run(edge,step)
    -- A recorded cashout after the winning boss implies the player's Endless
    -- button. It only dismisses this exact native overlay; other menus and
    -- gameplay are never skipped or reconstructed.
    local overlay=G.OVERLAY_MENU
    if not (step and step.kind=='enter_shop' and edge and edge.snapshot.save.GAME.won
        and G.GAME and G.GAME.won and overlay and overlay.get_UIE_by_ID
        and overlay:get_UIE_by_ID('you_win_UI')) then return false end
    G.FUNCS.exit_overlay_menu(assert(native_button('exit_overlay_menu'),'Native Endless button is unavailable'))
    return true
end
function Runtime.dispatch(step,identity)
    prepare_inputs(step,identity)
    local callback=assert(G.FUNCS[step.callback],'Recording callback is unavailable')
    local event
    if step.card_id or step.card_key then
        local card=find_card(step,identity)
        event={config={ref_table=card,id=step.use_after and 'buy_and_use' or nil}}
    elseif step.kind=='select_blind' then
        local key=step.blind and step.blind.key
            or G.GAME.round_resets.blind_choices[G.GAME.blind_on_deck]
        event=assert(native_button('select_blind',key),'Native select-blind button is unavailable')
    elseif step.kind=='skip_blind' then
        event=assert(native_button('skip_blind'),'Native skip-blind button is unavailable')
    else event=native_button(step.callback) or {config={}} end
    local result=callback(event)
    assert(result~=false,'The native game rejected a recording action')
end
function Runtime.new(ctx,film,snapshot,worker_source,finished)
    return setmetatable({ctx=ctx,film=film,snapshot=snapshot,source=worker_source,finished=finished},Runtime)
end
function Runtime:start(plan)
    assert(not self.active,'A recording is already active')
    assert(love.thread and love.graphics.captureScreenshot,'Video capture is unavailable')
    assert(self.ctx.game_ref==G.GAME and self.snapshot.is_stable(true),'Start or load a run before recording')
    local backup,err=self.snapshot.capture(true);assert(backup,err)
    local w,h=love.graphics.getDimensions()
    assert(w*h<=3840*2160,'Recording resolution exceeds 3840x2160 pixels')
    assert(love.filesystem.createDirectory('WorldLine/recordings'),'Cannot create recording directory')
    local key=os.date('!%Y%m%dT%H%M%SZ')..'_'..tostring(math.floor(love.timer.getTime()*1000))
    local output=plan.output or love.filesystem.getSaveDirectory()..'/WorldLine/recordings/'..key..'.mp4'
    local input_name,output_name='WorldLine.film.in.'..key,'WorldLine.film.out.'..key
    self.requests,self.responses=love.thread.getChannel(input_name),love.thread.getChannel(output_name)
    self.requests:clear();self.responses:clear()
    self.thread=love.thread.newThread(self.source)
    self.plan,self.backup,self.output,self.width,self.height=plan,backup,output,w,h
    self.identity=plan.verification and plan.verification.legacy_sort_ids and Identity.new() or nil
    self.sent,self.acked,self.frames,self.edge,self.step=0,0,0,1,1
    self.pause,self.wait,self.active,self.phase=0,0,true,'starting'
    self.old_speed=G.SETTINGS.GAMESPEED
    self.old_title=love.window and love.window.getTitle and love.window.getTitle()
    self.requests:push{ffmpeg=plan.options.ffmpeg,width=w,height=h,fps=plan.options.fps,
        encoder_source=Loader.source('film_encoder'),
        partial=output..'.partial.mp4',output=output,log=output..'.ffmpeg.log'}
    local ok,why=pcall(self.thread.start,self.thread,input_name,output_name)
    if not ok then self.active=false;error(why) end
    return output
end
function Runtime:clear_hover()
    if self.hover_card and self.hover_card.stop_hover then pcall(self.hover_card.stop_hover,self.hover_card) end
    if self.hover_card and self.hover_card.states then self.hover_card.states.hover.is=false end
    self.hover_card=nil
end
function Runtime:hold(card)
    self:clear_hover();self.hover_card=card
    if card and card.hover then card:hover();card.states.hover.is=true end
    self.pause=math.ceil(self.plan.options.pause_seconds*self.plan.options.fps)
end
function Runtime:cancel()
    if self.active then
        self.cancelled=true
        if (self.phase=='encoding' or self.phase=='returning') and not self.encoder_done then
            self.requests:push{kind='cancel'}
        else self:stop_playback() end
    end
end
function Runtime:fail(reason)
    self.error=self.error or tostring(reason)
    self:stop_playback()
end
function Runtime:stop_playback()
    if not self.active or self.phase=='returning' or self.phase=='encoding' or self.phase=='stopping' then return end
    self:clear_hover();self.frame_due=false
    if not self.encoder_stopped then
        self.requests:push{kind=(self.error or self.cancelled) and 'cancel' or 'finish'}
        self.encoder_stopped=true
    end
    -- The worker may still own queued raw frames. Wait for its final response
    -- before releasing the channels, including cancellation during startup.
    if not self.guard then self.phase='encoding';return end
    if self.snapshot.restoring then self.phase='stopping';return end
    self.phase='returning'
    local ok,started,err=pcall(self.snapshot.restore,self.backup)
    if not ok or not started then
        self.error=(self.error or '')..' Restore failed: '..tostring(ok and err or started)
        self:complete()
    end
end
function Runtime:complete()
    if not self.active then return end
    if not self.encoder_done then self.phase='encoding';return end
    if self.requests then self.requests:clear() end
    if self.responses then self.responses:clear() end
    if self.guard then self.snapshot.end_readonly_session(self.guard);self.guard=nil end
    G.SETTINGS.GAMESPEED=self.old_speed
    if self.old_title and love.window and love.window.setTitle then love.window.setTitle(self.old_title) end
    self.ctx.busy,self.ctx.restoring=false,false
    self.ctx.game_ref=G.GAME
    self.active,self.phase=false,'done'
    self.finished(not self.error and not self.cancelled,self.error,self.output,self.cancelled)
end
function Runtime:poll()
    while true do
        local message=self.responses:pop();if not message then break end
        if message.kind=='frame' then self.acked=message.index
        elseif message.kind=='ready' then self.encoder_ready=true
        elseif message.kind=='done' then self.encoder_done=true
        elseif message.kind=='cancelled' then self.encoder_done=true
        elseif message.kind=='error' then self.encoder_done=true;self:fail(message.error..' / '..tostring(message.log)) end
    end
    if self.thread and self.thread:getError() then self.encoder_done=true;self:fail(self.thread:getError()) end
end
function Runtime:before_update()
    if not self.active then return true end
    if love.window and love.window.setTitle then
        local seconds=math.floor(self.sent/self.plan.options.fps)
        local title='WorldLine - '..self.ctx.text(nil,self.phase=='encoding' and 'Export video' or 'Record video')
            ..' '..string.format('%02d:%02d',math.floor(seconds/60),seconds%60)
        if title~=self.title then love.window.setTitle(title);self.title=title end
    end
    self:poll()
    if not self.active then return true end
    if self.phase=='starting' then
        if not self.encoder_ready then return false end
        self.ctx.busy,self.ctx.restoring=true,true
        self.guard=self.snapshot.begin_readonly_session()
        G.SETTINGS.GAMESPEED=self.plan.options.speed
        local ok,err=self.snapshot.restore(self.plan.start);assert(ok,err)
        self.phase='loading'
    end
    if self.phase=='encoding' then
        if self.encoder_done then self:complete() end
        return false
    end
    if self.frame_due or self.sent-self.acked>=3 then return false end
    return true,1/self.plan.options.fps
end
function Runtime:update()
    if not self.active then return end
    if self.phase=='loading' or self.phase=='returning' or self.phase=='stopping' then
        local done,err=self.snapshot.update()
        if self.phase=='stopping' then
            if not self.snapshot.restoring then self.phase='playing';self:stop_playback() end
            return
        end
        if err then
            if self.phase=='returning' then self.error=tostring(err);self:complete()
            else self:fail(err) end
        elseif done then
            if self.phase=='returning' then
                self.phase='encoding';if self.encoder_done then self:complete() end
            else
                self.phase='playing';G.GAME.seeded=true;self.delay=self.plan.options.fps/2
            end
        end
        return
    end
    if self.phase~='playing' then return end
    self.frames=self.frames+1
    assert(self.frames<=self.plan.options.fps*1800,'Recording exceeded 30 minutes')
    self.frame_due=true
    if self.hover_card and not self.hover_card.children.h_popup then self.hover_card:hover() end
    if self.pause>0 then self.pause=self.pause-1;return end
    self:clear_hover()
    if self.delay and self.delay>0 then self.delay=self.delay-1;return end
    local waiting_edge=self.plan.edges[self.edge]
    Runtime.continue_won_run(waiting_edge,waiting_edge and waiting_edge.steps[self.step])
    local stable,reason=self.snapshot.is_stable(false)
    if not stable then
        local edge=self.plan.edges[self.edge]
        local step=edge and edge.steps[self.step]
        self.wait=self.wait+1
        assert(self.wait<self.plan.options.fps*120,'Recording action timed out at #'
            ..tostring(edge and edge.id)..' / '..self.step..' ('..tostring(step and step.kind)
            ..', '..tostring(reason)..')')
        return
    end
    self.wait=0
    if self.plan.options.show_pack and G.pack_cards and G.pack_cards.cards and #G.pack_cards.cards>0
        and self.last_pack~=G.pack_cards then
        self.last_pack=G.pack_cards;self.pack_index=1
    end
    if self.pack_index then
        local card=G.pack_cards and G.pack_cards.cards and G.pack_cards.cards[self.pack_index]
        if card then self.pack_index=self.pack_index+1;self:hold(card);return end
        self.pack_index=nil
    end
    local edge=self.plan.edges[self.edge]
    if not edge then
        if not self.ending then self.ending=true;self.delay=self.plan.options.fps;return end
        self:stop_playback();return
    end
    local step=edge.steps[self.step]
    if not step then
        if edge.boundary_input and not self.boundary_ready then
            if self.identity then self.identity:synchronize(edge.snapshot)end
            prepare_inputs({decision=edge.boundary_input},self.identity)
            self.boundary_ready=true;return
        end
        -- Older logs did not observe the sort-button input. At an empty-hand
        -- stage boundary its saved mode is presentation state, not a card/RNG
        -- mutation. Carry it forward so subsequent native pack draws use the
        -- player's recorded display mode. Never reorder a saved deck here.
        local hand=edge.snapshot.save.cardAreas.hand
        if G.hand and G.hand.cards and #G.hand.cards==0 and hand and hand.config
            and type(hand.config.sort)=='string' then G.hand.config.sort=hand.config.sort end
        local actual,err=self.snapshot.capture(false);assert(actual,err)
        local policy={}
        for key,value in pairs(self.plan.verification or {})do policy[key]=value end
        policy.identity=self.identity
        local equal,where=self.film.verify(actual,edge.snapshot,policy)
        assert(equal,'Replay diverged at #'..edge.id..': '..tostring(where))
        self.edge,self.step,self.boundary_ready=self.edge+1,1,nil;return
    end
    if step.state_before then
        local name=self.snapshot.capture(false)
        assert(name and name.extra.state==step.state_before,'Recording action state changed')
    end
    if step.kind=='use' and self.plan.options.pause_consumables and not self.previewed then
        prepare_inputs(step,self.identity)
        self.previewed=true;self:hold(find_card(step,self.identity));return
    end
    self.previewed=nil
    local ok,err=pcall(Runtime.dispatch,step,self.identity)
    assert(ok,'Replay action at #'..edge.id..' / '..self.step..': '..tostring(err))
    self.step=self.step+1
    self.delay=math.ceil(self.plan.options.action_delay*self.plan.options.fps)
end
function Runtime:capture()
    if not self.active or not self.frame_due or self.capture_pending then return end
    self.capture_pending=true
    love.graphics.captureScreenshot(function(image)
        self.capture_pending=false
        if not self.active or self.phase~='playing' then
            self.frame_due=false;image:release();return
        end
        local ok,err=pcall(function()
            assert(image:getWidth()==self.width and image:getHeight()==self.height,
                'Window size changed during recording')
            assert(image:getFormat()=='rgba8','Unexpected screenshot pixel format')
            self.sent=self.sent+1;self.requests:push{kind='frame',data=image:getString()}
        end)
        image:release()
        self.frame_due=false
        if not ok then self:fail(err) end
    end)
end
return Runtime

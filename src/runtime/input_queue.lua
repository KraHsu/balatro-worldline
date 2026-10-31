-- Session-only player inputs. Native event continuations bypass this queue.
-- Keep actual target/selection references until the previous action settles;
-- callbacks still run through the ordinary observer and native game functions.
local Queue={};Queue.__index=Queue
Queue.LIMIT=16
local unpack_values=unpack or table.unpack
local expected={play_cards_from_highlighted='SELECTING_HAND',discard_cards_from_highlighted='SELECTING_HAND',
    select_blind='BLIND_SELECT',skip_blind='BLIND_SELECT',cash_out='ROUND_EVAL',toggle_shop='SHOP',
    buy_from_shop='SHOP',reroll_shop='SHOP'}

function Queue.new(ctx)return setmetatable({ctx=ctx,items={}},Queue)end
function Queue:count()return #self.items end
function Queue:clear()self.items={};self.draining=false end
function Queue:notice(key)
    if self.ctx.undo_input_notice then self.ctx.undo_input_notice(key)end
end
function Queue:ready()
    return not self.ctx.busy and not self.ctx.restoring and self.ctx.should_record()
        and self.ctx.is_input_boundary() and not G.OVERLAY_MENU and not G.SETTINGS.paused
end
function Queue:should_defer()
    return not self.draining and (#self.items>0 or not self:ready())
end
function Queue:enqueue(name,args,dispatch)
    if #self.items>=Queue.LIMIT then self:notice('Undo input queue is full');return nil,'queue_full'end
    local selected={}
    for _,card in ipairs(G.hand and G.hand.highlighted or {})do selected[#selected+1]=card end
    local event=args[1]
    local target=event and event.config and event.config.ref_table
    if not (type(target)=='table' and target.sort_id)then target=nil end
    self.items[#self.items+1]={name=name,args=args,dispatch=dispatch,game=G.GAME,tree=self.ctx.tree,
        target=target,area=target and target.area,selected=selected,
        state=expected[name] and G.STATES[expected[name]] or G.STATE,
        round=G.GAME.round,blind=G.GAME.blind_on_deck,pack=name=='skip_booster' and G.pack_cards or nil}
    self:notice('Input queued; waiting for animation')
    return true,'queued'
end
function Queue:update()
    local item=self.items[1]
    if not item or self.draining then return false end
    if item.game~=G.GAME or item.tree~=self.ctx.tree or G.STAGE~=G.STAGES.RUN
        or G.STATE==G.STATES.GAME_OVER and item.state~=G.STATE then
        self:clear();self:notice('Queued action cancelled: its cards or stage changed');return false
    end
    if not self:ready()then return false end
    table.remove(self.items,1)
    local valid=G.STATE==item.state and G.GAME.round==item.round and G.GAME.blind_on_deck==item.blind
        and (not item.pack or G.pack_cards==item.pack)
        and (not item.target or not item.target.REMOVED and item.target.area==item.area)
    local uses_hand=item.name=='play_cards_from_highlighted' or item.name=='discard_cards_from_highlighted'
        or item.name=='use_card'
    if uses_hand then
        local live={};for _,card in ipairs(G.hand and G.hand.cards or {})do live[card]=true end
        for _,card in ipairs(item.selected)do if not live[card]then valid=false end end
    end
    if not valid then self:notice('Queued action cancelled: its cards or stage changed');return false end
    if uses_hand and G.hand then
        -- Native add_to_highlighted reparses the hand and queues text/easing
        -- events. Recreating them here would invalidate the stable boundary
        -- immediately before Undo captures it. Restore presentation flags only;
        -- the native play/discard/consumable callback owns gameplay evaluation.
        local selected={}
        for _,card in ipairs(item.selected)do selected[card]=true end
        for _,card in ipairs(G.hand.cards)do card.highlighted=selected[card]==true end
        G.hand.highlighted={}
        for _,card in ipairs(item.selected)do G.hand.highlighted[#G.hand.highlighted+1]=card end
        if G.hand.align_cards then G.hand:align_cards()end
    end
    self.draining=true
    self.ctx.undo_notice=nil
    if self.ctx.invalidate_input_boundary then self.ctx.invalidate_input_boundary()end
    local ok,err=pcall(item.dispatch,unpack_values(item.args,1,item.args.n))
    self.draining=false
    if not ok then error(err,0)end
    return true
end
return Queue

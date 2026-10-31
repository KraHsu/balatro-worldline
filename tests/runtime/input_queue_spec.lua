local Queue=dofile('src/runtime/input_queue.lua')
local a,b={sort_id=1},{sort_id=2}
G={GAME={},STAGE=1,STATES={SELECTING_HAND=1,GAME_OVER=2},STAGES={RUN=1},STATE=1,SETTINGS={}}
G.hand={cards={a,b},highlighted={a},unhighlight_all=function(self)self.highlighted={}end,
 add_to_highlighted=function(self,c)self.highlighted[#self.highlighted+1]=c end}
local ready=false
local notices,actions={},{}
local ctx={tree={},should_record=function()return true end,is_input_boundary=function()return ready end,
 undo_input_notice=function(s)notices[#notices+1]=s end}
local q=Queue.new(ctx)
local function apply(value)
 assert(not q:should_defer(),'The queued callback must bypass requeueing')
 actions[#actions+1]={value,G.hand.highlighted[1]}
end
assert(q:should_defer()and q:enqueue('discard_cards_from_highlighted',{n=1,'first'},apply))
G.hand.highlighted={b}
assert(not q:update()and #actions==0,'No input runs during an unfinished animation')
ready=true;assert(q:update()and #actions==1 and actions[1][2]==a,'Restore the captured hand selection at execution')
assert(not q:update()and not q:should_defer())
q:enqueue('discard_cards_from_highlighted',{n=1,'stale'},apply)
G.hand.cards={b};assert(not q:update()and #actions==1,'Removed targets cancel instead of acting on other cards')
for i=1,Queue.LIMIT do assert(q:enqueue('discard_cards_from_highlighted',{n=0},apply))end
assert(not q:enqueue('discard_cards_from_highlighted',{n=0},apply),'Queued inputs have a fixed memory limit')
G.GAME={};assert(not q:update()and q:count()==0,'A new run cancels the old input queue')
G.hand.cards={a,b};G.hand.highlighted={a};G.GAME.round=1
q:enqueue('discard_cards_from_highlighted',{n=0},apply)
G.GAME.round=2
assert(not q:update()and #actions==1,'Matching state enums in a later round cannot replay stale input')
G.GAME.blind_on_deck='Small'
q:enqueue('discard_cards_from_highlighted',{n=0},apply)
G.GAME.blind_on_deck='Big'
assert(not q:update()and #actions==1,'A different blind invalidates the queued input')
local invalidated=false
ctx.invalidate_input_boundary=function()invalidated=true end
q:enqueue('discard_cards_from_highlighted',{n=0},function()
 assert(invalidated,'Restore the input selection before capturing its before-state')
end)
assert(q:update())
print('PASS input queue: stable boundaries, immutable target selection, stale-card cancellation, bounded memory and run isolation')

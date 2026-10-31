local Visuals=dofile('src/runtime/card_visuals.lua')
local calls=0
local center={set='Planet',discovered=false,pos={x=3,y=2}}
local card={config={center=center},params={bypass_discovery_center=true},edition={negative=true},sort_id=43,
 children={center={sprite_pos={x=7,y=2},set_sprite_pos=function(self,pos)calls=calls+1;self.sprite_pos=pos end}}}
local random=math.random
math.random=function()error('A face repair must not consume RNG')end
assert(Visuals.after_copy(card) and card.bypass_discovery_center and calls==1)
assert(card.children.center.sprite_pos==center.pos and not center.discovered)
assert(card.edition.negative and card.sort_id==43,'Only presentation fields may change')
assert(not Visuals.after_copy(card) and calls==1,'Repeated repair is a no-op')
card.bypass_discovery_center=nil;card.params.bypass_discovery_center=false
assert(not Visuals.after_copy(card) and not card.bypass_discovery_center,'Hidden collection previews retain discovery rules')
card.params.bypass_discovery_center=true;center.set='Joker'
assert(not Visuals.after_copy(card),'Other card types retain their native behavior')
center.set='Planet';local args
copy_card=function(...)args={...};return card end
assert(Visuals.install() and not Visuals.install())
assert(copy_card('source',nil,0.5)==card and args[1]=='source' and args[3]==0.5 and calls==2)
math.random=random
print('PASS card visuals: copied Planet faces follow inherited discovery bypass without RNG, progress or identity changes')

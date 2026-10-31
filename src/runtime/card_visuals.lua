-- copy_card assigns the source params after constructing a temporary base
-- card. A copied, undiscovered Planet can therefore keep the hidden face even
-- though its inherited params explicitly allow showing the actual card.
local Visuals={}
local installed=false

function Visuals.after_copy(card)
    local center=card and card.config and card.config.center
    local params=card and card.params
    if not (center and center.set=='Planet' and params and params.bypass_discovery_center==true)
        or card.bypass_discovery_center==true then return false end
    card.bypass_discovery_center=true
    local sprite=card.children and card.children.center
    local pos=center.pos
    if sprite and type(sprite.set_sprite_pos)=='function' and pos and not pos.v
        and type(pos.x)=='number' and type(pos.y)=='number' then
        sprite:set_sprite_pos(pos)
    end
    return true
end

function Visuals.install()
    if installed or type(copy_card)~='function' then return false end
    local native=copy_card
    copy_card=function(...)
        local card=native(...)
        Visuals.after_copy(card)
        return card
    end
    installed=true
    return true
end
return Visuals

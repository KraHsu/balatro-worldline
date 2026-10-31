-- Legacy UI previews consumed sort IDs without recording those constructions.
-- Translate references only through a monotone bijection of live cards. Never
-- change a card ID, RNG state, centre, ability or checkpoint to hide divergence.
local Identity={};Identity.__index=Identity
local areas={'hand','deck','discard','play','jokers','consumeables','vouchers','shop_jokers','shop_vouchers','shop_booster','pack_cards'}
Identity.AREAS=areas
function Identity.new()return setmetatable({record_to_live={},live_to_record={}},Identity)end
function Identity:prune()
    local live={}
    for _,name in ipairs(areas)do for _,card in ipairs(G[name] and G[name].cards or {})do live[card.sort_id]=true end end
    if SMODS and SMODS.OPENED_BOOSTER then live[SMODS.OPENED_BOOSTER.sort_id]=true end
    for record,id in pairs(self.record_to_live)do
        if not live[id]then self.record_to_live[record]=nil;self.live_to_record[id]=nil end
    end
end
function Identity:bind(record,id)
    assert(type(record)=='number' and type(id)=='number','Invalid recording identity')
    local existing=self.record_to_live[record]
    assert(not existing or existing==id,'Recording identity changed')
    assert(not self.live_to_record[id] or self.live_to_record[id]==record,'Recording identities overlap')
    for other,mapped in pairs(self.record_to_live)do
        assert((other<record)==(mapped<id) or other==record,'Recording RNG order changed')
    end
    self.record_to_live[record]=id;self.live_to_record[id]=record
    return id
end
function Identity:resolve(record)return self.record_to_live[record] or record end
function Identity:vector(ids)
    if not ids then return end
    local out={};for i,id in ipairs(ids)do out[i]=self:resolve(id)end;return out
end
function Identity:area(area,ids)
    if not ids then return end
    local cards=area and area.cards or {}
    assert(#ids==#cards,'Recording inventory size changed')
    local recorded,current={},{}
    for i,id in ipairs(ids)do recorded[i]=id end
    for i,card in ipairs(cards)do current[i]=card.sort_id end
    table.sort(recorded);table.sort(current)
    for i,id in ipairs(recorded)do self:bind(id,current[i])end
end
function Identity:synchronize(snapshot)
    self:prune()
    local recorded,current={},{}
    for _,name in ipairs(areas)do
        local saved=snapshot.save.cardAreas[name]
        for _,card in ipairs(saved and saved.cards or {})do recorded[#recorded+1]=card.sort_id end
        for _,card in ipairs(G[name] and G[name].cards or {})do current[#current+1]=card.sort_id end
    end
    assert(#recorded==#current,'Recording card inventory changed')
    table.sort(recorded);table.sort(current)
    for i,id in ipairs(recorded)do self:bind(id,current[i])end
end
return Identity

-- Gameplay flags omitted by native Card:save/load in Balatro 1.0.1o with
-- Steamodded 26.1002.0. Keep this list narrow and grounded in actual readers.
-- shop_voucher is already persisted by SMODS lovely/shop.toml:216-234.
local Runtime = {SCHEMA = 1}
local fields = {'from_tag'}
local allowed = {from_tag = true}

-- Native can_use_consumeable reads these caches while building highlighted
-- controls, before the first Card:update after a load. Rebuild references from
-- the restored inventory; never serialize live card references or run update.
function Runtime.prepare_controls(card)
    local name=card.ability and card.ability.name
    local field=name=='The Wheel of Fortune' and 'eligible_strength_jokers'
        or (name=='Ectoplasm' or name=='Hex') and 'eligible_editionless_jokers'
    if not field then return end
    local eligible={}
    for _,joker in pairs(G.jokers and G.jokers.cards or {})do
        if joker.ability.set=='Joker' and not joker.edition then eligible[#eligible+1]=joker end
    end
    card[field]=eligible
end

function Runtime.validate(entry)
    if entry == nil then return true end -- Older archives did not record this.
    if type(entry) ~= 'table' then return nil, 'invalid_card_runtime' end
    for key, value in pairs(entry) do
        if not allowed[key] or type(value) ~= 'boolean' then return nil, 'invalid_card_runtime_field' end
    end
    return true
end

function Runtime.capture(card)
    assert(type(card) == 'table', 'Invalid runtime card')
    local entry = {}
    for _, key in ipairs(fields) do
        local value = card[key]
        assert(value == nil or type(value) == 'boolean', 'Invalid live card runtime flag: ' .. key)
        entry[key] = value
    end
    return entry
end

function Runtime.restore(card, entry)
    assert(type(card) == 'table', 'Invalid runtime card')
    -- Do not invent whether a legacy voucher/booster came from a tag. The
    -- entire absent record is different from a newly recorded explicit nil.
    if entry == nil then return false, 'legacy_card_runtime' end
    local valid, reason = Runtime.validate(entry)
    assert(valid, reason)
    for _, key in ipairs(fields) do card[key] = entry[key] end
    return true
end

return Runtime

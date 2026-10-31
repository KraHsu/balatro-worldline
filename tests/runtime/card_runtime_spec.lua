local Runtime = dofile('src/runtime/card_runtime.lua')
local function copy(value)
    if type(value) ~= 'table' then return value end
    local result = {}; for key, item in pairs(value) do result[key] = copy(item) end; return result
end

-- Saving/restoring never inspects UI objects, invokes methods or touches IDs,
-- unrelated native card fields or either random source.
local source = {from_tag = true, shop_voucher = false, sort_id = 17, ID = 90,
    ability = {set = 'Voucher'}, children = {cycle = {}}}
source.children.cycle.self = source
source.save = function() error('capture must not invoke native methods') end
local entry = Runtime.capture(source)
assert(entry.from_tag == true and entry.ID == nil and entry.shop_voucher == nil and entry.children == nil)
source.from_tag = false
assert(entry.from_tag == true, 'retained capture is detached from the live card')
local loaded = {sort_id = 17, ID = 999, shop_voucher = false, ability = source.ability}
assert(Runtime.restore(loaded, entry) and loaded.from_tag == true)
assert(loaded.ID == 999 and loaded.sort_id == 17 and loaded.shop_voucher == false and loaded.ability == source.ability)
assert(Runtime.restore(loaded, entry), 'restoration is idempotent')
assert(Runtime.restore(loaded, Runtime.capture({from_tag = false})) and loaded.from_tag == false)
assert(Runtime.restore(loaded, Runtime.capture({})) and loaded.from_tag == nil,
    'new empty records restore a genuinely absent flag rather than leaving stale flags')
loaded.from_tag = true
local applied, reason = Runtime.restore(loaded, nil)
assert(not applied and reason == 'legacy_card_runtime' and loaded.from_tag == true,
    'old archives have unknown provenance, which must not be inferred or overwritten')
assert(Runtime.validate(nil) and Runtime.validate({}) and Runtime.validate({from_tag = false}))
for _, bad in ipairs({false, 'tag', {from_tag = 1}, {from_tag = {}}, {ID = 5}, {shop_voucher = true}}) do
    assert(not Runtime.validate(bad))
    assert(not pcall(Runtime.restore, loaded, bad) and loaded.from_tag == true,
        'invalid data is rejected before any live field is changed')
end
assert(not pcall(Runtime.capture, {from_tag = 'yes'}))

-- Reproduce the installed SMODS voucher-tag interaction (shop.toml:111-112).
-- Normal Card:save persists shop_voucher, but omits from_tag. Losing the latter
-- leaves the first regular offer eligible to respawn after a tagged voucher.
local initial = {voucher = {'v_regular', spawn = {v_regular = true, v_tagged = true}}}
local tagged = {sort_id = 31, from_tag = true, shop_voucher = false, config = {center_key = 'v_tagged'}}
local function redeem(game, card)
    if card.shop_voucher then game.voucher.spawn[card.config.center_key] = false end
    if card.from_tag then game.voucher.spawn[game.voucher[1]] = false end
end
local uninterrupted = copy(initial)
redeem(uninterrupted, tagged)
local captured = Runtime.capture(tagged)
local reconstructed = {sort_id = 31, shop_voucher = false, config = {center_key = 'v_tagged'}}
local wrong = copy(initial); redeem(wrong, reconstructed)
assert(wrong.voucher.spawn.v_regular and not uninterrupted.voucher.spawn.v_regular)
Runtime.restore(reconstructed, captured)
local resumed = copy(initial); redeem(resumed, reconstructed)
assert(resumed.voucher.spawn.v_regular == uninterrupted.voucher.spawn.v_regular
    and resumed.voucher.spawn.v_tagged == uninterrupted.voucher.spawn.v_tagged,
    'the restored flag preserves the existing native voucher candidate behavior')

-- The same provenance controls native booster purchase accounting. Preserve
-- both tag-sourced and paid boosters instead of forcing a global default.
local function purchase_count(card) return card.from_tag and 0 or 1 end
for _, from_tag in ipairs({true, false}) do
    local original = {from_tag = from_tag}
    local booster = {}
    Runtime.restore(booster, Runtime.capture(original))
    assert(purchase_count(booster) == purchase_count(original))
end
if TEST_JSON then
    local Codec = dofile('src/storage/codec.lua')
    local wire = {schema = Runtime.SCHEMA, cards = {[31] = captured, [60] = Runtime.capture({})}}
    local restored = assert(Codec.decode(Codec.encode(wire, TEST_JSON), TEST_JSON))
    assert(restored.schema == 1 and restored.cards[31].from_tag and next(restored.cards[60]) == nil)
end
local plain={ability={set='Joker'}}
local foil={ability={set='Joker'},edition={foil=true}}
local wheel={ability={name='The Wheel of Fortune'}}
local hex={ability={name='Hex'}}
G={jokers={cards={plain,foil}}}
Runtime.prepare_controls(wheel);Runtime.prepare_controls(hex)
assert(#wheel.eligible_strength_jokers==1 and wheel.eligible_strength_jokers[1]==plain)
assert(#hex.eligible_editionless_jokers==1 and hex.eligible_editionless_jokers[1]==plain)
G.jokers.cards={};Runtime.prepare_controls(wheel)
assert(next(wheel.eligible_strength_jokers)==nil,'Native use-button checks require an empty table, not nil')
print('PASS card runtime: tag provenance and restored consumable eligibility caches without gameplay updates')

-- Record run milestones, not individual card inputs or shopping transactions.
-- The checkpoint captured after each milestone contains its complete result.
local Hooks = {}
local unpack_values = unpack or table.unpack
local callback_depth = 0
local installed = false
local observation_dirty = true
local observed = {areas = {}}
local area_names = {'hand', 'deck', 'discard', 'play', 'jokers', 'consumeables',
    'vouchers', 'shop_jokers', 'shop_vouchers', 'shop_booster', 'pack_cards'}

-- A stable run does not change merely because its shader/hover animation has
-- advanced. Keep a small, reusable observation of native gameplay state rather
-- than serializing every card and deep-comparing a whole checkpoint on a timer.
-- Irreversible callbacks explicitly invalidate this observation (see Undo).
-- These shallow watches also notice native phase transitions and changes that
-- have no irreversible callback: selection, sorting and dragging card order.
local ignored_game_fields = {worldline_run_id = true, worldline_node_id = true, seeded = true}
local empty = {}
local function observe_map(previous, value, ignored)
    local changed = false
    value = type(value) == 'table' and value or nil
    for key, item in pairs(value or empty) do
        if not (ignored and ignored[key]) and previous[key] ~= item then
            previous[key], changed = item, true
        end
    end
    for key in pairs(previous) do
        if not value or value[key] == nil or ignored and ignored[key] then
            previous[key], changed = nil, true
        end
    end
    return changed
end

local function observe_list(previous, value)
    value = type(value) == 'table' and value or empty
    local changed = #previous ~= #value
    for i = 1, #value do
        if previous[i] ~= value[i] then previous[i], changed = value[i], true end
    end
    for i = #previous, #value + 1, -1 do previous[i] = nil end
    return changed
end

local function observe()
    local game = G and G.GAME
    if observed.game ~= game or observed.state ~= (G and G.STATE) then
        observed.game, observed.state, observation_dirty = game, G and G.STATE, true
    end
    if not game then return end
    observed.scalars = observed.scalars or {}
    observed.round = observed.round or {}
    observed.resets = observed.resets or {}
    observed.rng = observed.rng or {}
    observed.choices = observed.choices or {}
    observed.blind_states = observed.blind_states or {}
    if observe_map(observed.scalars, game, ignored_game_fields) then observation_dirty = true end
    if observe_map(observed.round, game.current_round) then observation_dirty = true end
    if observe_map(observed.resets, game.round_resets) then observation_dirty = true end
    if observe_map(observed.rng, game.pseudorandom) then observation_dirty = true end
    if observe_map(observed.choices, game.round_resets and game.round_resets.blind_choices) then observation_dirty = true end
    if observe_map(observed.blind_states, game.round_resets and game.round_resets.blind_states) then observation_dirty = true end
    for _, name in ipairs(area_names) do
        local area = G[name]
        local previous = observed.areas[name]
        if not previous then
            previous = {cards = {}, selected = {}, config = {}}
            observed.areas[name] = previous
        end
        if previous.area ~= area then previous.area, observation_dirty = area, true end
        if observe_list(previous.cards, area and area.cards) then observation_dirty = true end
        if observe_list(previous.selected, area and area.highlighted) then observation_dirty = true end
        if observe_map(previous.config, area and area.config) then observation_dirty = true end
    end
end

local function pack(...)
    return { n = select('#', ...), ... }
end

local function enabled(ctx)
    return not ctx.restoring and not ctx.busy
        and type(ctx.should_record) == 'function' and ctx.should_record()
        and (type(ctx.is_input_boundary) ~= 'function' or ctx.is_input_boundary())
end

local action_specs = {
    select_blind = { 'select_blind', '挑战盲注', 'Select blind' },
    skip_blind = { 'skip_blind', '跳过盲注', 'Skip blind' },
    cash_out = { 'enter_shop', '结束盲注，进入商店', 'Blind completed; enter shop' },
    toggle_shop = { 'leave_shop', '结束购物，选择盲注', 'Finish shopping; choose blind' },
}

local function action(ctx, spec, event)
    local result = {
        kind = spec[1], label = ctx.text and ctx.text(spec[2], spec[3]) or spec[3],
        state = G.STATE,
        ante = G.GAME and G.GAME.round_resets and G.GAME.round_resets.ante,
        round = G.GAME and G.GAME.round,
    }
    if spec[1] == 'select_blind' or spec[1] == 'skip_blind' then
        local blind = event and event.config and event.config.ref_table
        if type(blind) == 'table' then result.blind = { key = blind.key, name = blind.name } end
    end
    return result
end

function Hooks.install(ctx)
    if installed then return end
    installed = true
    for name, spec in pairs(action_specs) do
        local original = G.FUNCS[name]
        if type(original) == 'function' then
            G.FUNCS[name] = function(...)
                local args = pack(...)
                local record = callback_depth == 0 and enabled(ctx)
                local milestone
                if record then
                    if type(ctx.before_action) == 'function' then ctx.before_action() end
                    milestone = action(ctx, spec, args[1])
                end
                callback_depth = callback_depth + 1
                local result = pack(pcall(original, unpack_values(args, 1, args.n)))
                callback_depth = callback_depth - 1
                if not result[1] then error(result[2], 0) end
                if record and result[2] ~= false then ctx.record_action(milestone) end
                return unpack_values(result, 2, result.n)
            end
        end
    end
end

-- These only invalidate the in-phase resume snapshot, never create tree nodes.
-- Dirty stays latched through queued events until a successful full capture is
-- acknowledged. Polling or a failed/unstable capture cannot lose a mutation.
function Hooks.invalidate() observation_dirty = true end
function Hooks.reset()
    observed, observation_dirty = {areas = {}}, true
end
function Hooks.poll()
    observe()
    return observation_dirty
end
function Hooks.acknowledge()
    observe()
    observation_dirty = false
end

return Hooks

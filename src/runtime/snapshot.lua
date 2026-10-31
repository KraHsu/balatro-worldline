-- Adapter for stable, player-facing states in Balatro 1.0.1o + SMODS 26.1002.0.
-- It uses object save/load APIs, never save_run(), and never writes a file.
local Loader
if SMODS and SMODS.load_file then
    Loader = assert(SMODS.load_file('loader.lua', 'WorldLine'))()
else
    Loader = dofile('src/loader.lua')
end
local CardRuntime = Loader.load('card_runtime')
local HandOrder = Loader.load('hand_order')
local Snapshot = {restoring = false}
local Cashout = Loader.load('cashout')
Snapshot.install_cashout_capture=Cashout.install
Snapshot.install_hand_order=HandOrder.install
local pending, active_guard

-- A native save load is not a player "Continue" action. start_run otherwise
-- unlocks Throwback synchronously, and card reconstruction can discover cards
-- or update the profile's most-money record before its queued UI is discarded.
-- Keep this guard for the whole restore/rollback lifecycle, including frames
-- spent waiting for reconstruction. Usage helpers are intentionally untouched:
-- set_hand_usage/set_consumeable_usage also update genuine GAME fields.
local progress_functions = {
    'check_for_unlock', 'unlock_card', 'discover_card', 'unlock_achievement',
    'inc_career_stat', 'check_and_set_high_score'
}
local progress_methods = { 'save_progress', 'save_notify', 'save_settings' }
local progress_queues = { 'achievement', 'unlock' }
local progress_payloads = { 'save_progress', 'save_settings' }
local function ignore_progress() end

local function begin_progress_guard(context, replay)
    context.progress_refs, context.progress_queues, context.progress_payloads = {}, {}, {}
    local function suppress(owner, key)
        if type(owner[key]) ~= 'function' then return end
        -- Preserve an inherited method as an inherited method, not a new own
        -- field that permanently shadows its class after the guard is released.
        context.progress_refs[#context.progress_refs + 1] = { owner, key, rawget(owner, key) }
        owner[key] = ignore_progress
    end
    for _, key in ipairs(progress_functions) do
        -- High-score checking also updates genuine in-run round_scores. During
        -- playback seeded=true and the outer profile backup protect progress;
        -- checkpoint reconstruction still suppresses it as before.
        if not (replay and key=='check_and_set_high_score') then suppress(_G, key) end
    end
    for _, key in ipairs(progress_methods) do suppress(G, key) end
    for _, key in ipairs(progress_payloads) do
        context.progress_payloads[key] = G.ARGS and G.ARGS[key] or nil
    end
    for _, name in ipairs(progress_queues) do
        local saved = {}
        for _, event in ipairs(G.E_MANAGER and G.E_MANAGER.queues and G.E_MANAGER.queues[name] or {}) do
            saved[#saved + 1] = event
        end
        context.progress_queues[name] = saved
    end
    -- F_NO_SAVING only blocks creating a new run save. Game:update flushes an
    -- already queued FILE_HANDLER independently, so suspend its old payloads
    -- as well until finish_guard restores the genuine progress/settings work.
    G.FILE_HANDLER = {}
    if G.ARGS then G.ARGS.save_run = nil end
end

local function finish_progress_guard(context)
    for _, ref in ipairs(context.progress_refs or {}) do rawset(ref[1], ref[2], ref[3]) end
    context.progress_refs = nil
    if G and G.ARGS then
        for _, key in ipairs(progress_payloads) do G.ARGS[key] = context.progress_payloads and context.progress_payloads[key] end
    end
    if G and G.E_MANAGER and G.E_MANAGER.queues then
        for _, name in ipairs(progress_queues) do
            local original = context.progress_queues and context.progress_queues[name]
            if original and #original > 0 then
                local queue = G.E_MANAGER.queues[name] or {}
                G.E_MANAGER.queues[name] = queue
                for _, event in ipairs(original) do queue[#queue + 1] = event end
            end
        end
    end
    context.progress_queues = nil
end

local area_names = {
    "hand", "deck", "discard", "play", "jokers", "consumeables", "vouchers",
    "shop_jokers", "shop_vouchers", "shop_booster", "pack_cards"
}
local area_set = {}
for _, name in ipairs(area_names) do area_set[name] = true end
local base_areas = { "hand", "deck", "discard", "play", "jokers", "consumeables", "vouchers" }
local shop_areas = { "shop_jokers", "shop_vouchers", "shop_booster" }
local pack_names = {
    TAROT_PACK = "create_UIBox_arcana_pack",
    PLANET_PACK = "create_UIBox_celestial_pack",
    SPECTRAL_PACK = "create_UIBox_spectral_pack",
    STANDARD_PACK = "create_UIBox_standard_pack",
    BUFFOON_PACK = "create_UIBox_buffoon_pack",
    SMODS_BOOSTER_OPENED = false
}
local supported = {
    SELECTING_HAND = true, BLIND_SELECT = true, SHOP = true,
    ROUND_EVAL = true, GAME_OVER = true
}
for name in pairs(pack_names) do supported[name] = true end

local function clone(value, seen, depth, cull_objects)
    local kind = type(value)
    if kind ~= "table" then
        if kind ~= "nil" and kind ~= "string" and kind ~= "number" and kind ~= "boolean" then
            error("Snapshot contains unsupported value: " .. kind)
        end
        return value
    end
    -- Match Balatro's recursive_table_cull marker while making the validated,
    -- detached checkpoint in the same pass. Native Object instances (Blind,
    -- Back, scoring calculation, etc.) are restored from their explicit saves.
    if cull_objects and value.is and value:is(Object) then return '"MANUAL_REPLACE"' end
    depth = (depth or 0) + 1
    if depth > 96 then error("Snapshot exceeds nesting limit") end
    seen = seen or {}
    if seen[value] then error("Snapshot contains a cycle") end
    seen[value] = true
    local result = {}
    for key, item in pairs(value) do
        local key_type = type(key)
        if key_type ~= "string" and key_type ~= "number" and key_type ~= "boolean" then
            error("Snapshot contains unsupported table key")
        end
        result[key] = clone(item, seen, depth, cull_objects)
    end
    seen[value] = nil
    return result
end

local function state_name(state)
    if not G or not G.STATES then return nil end
    for name in pairs(supported) do
        if G.STATES[name] == state then return name end
    end
end

local function is_pack(name)
    return pack_names[name] ~= nil
end

local function queue_busy(allow_overlay)
    for queue_name, queue in pairs((G.E_MANAGER and G.E_MANAGER.queues) or {}) do
        -- Unlock/tutorial/achievement notices do not represent run decisions.
        if queue_name == "base" or queue_name == "other" then
            for _, event in ipairs(queue) do
                local persistent = event.trigger == "immediate"
                    and event.blocking == false and event.blockable == false
                local overlay_event = allow_overlay and event.created_on_pause
                if not event.complete and not persistent and not overlay_event then
                    return true
                end
            end
        end
    end
    return false
end

function Snapshot.is_stable(allow_overlay)
    if not G or not G.STAGES or G.STAGE ~= G.STAGES.RUN or not G.GAME then
        return false, "not_in_run"
    end
    local name = state_name(G.STATE)
    if not name then return false, "transition" end
    if not G.STATE_COMPLETE then return false, "transition" end
    local terminal = name == "GAME_OVER"
    if not allow_overlay and not terminal and (G.OVERLAY_MENU or (G.SETTINGS and G.SETTINGS.paused)) then
        return false, "overlay"
    end
    if G.screenwipe or G.TAROT_INTERRUPT or (G.GAME.STOP_USE or 0) > 0 then
        return false, "transition"
    end
    local controller = G.CONTROLLER or {}
    if controller.dragging and controller.dragging.target then return false, "dragging" end
    if controller.lock_input or (controller.locked and not Snapshot.restoring) then
        return false, "input_locked"
    end
    for key, locked in pairs(controller.locks or {}) do
        if locked and not (Snapshot.restoring and key == "worldline_restore") then
            return false, "input_locked"
        end
    end
    if queue_busy(allow_overlay or terminal) then return false, "events_pending" end
    for _, area in ipairs(base_areas) do
        if not G[area] or not G[area].cards then return false, "areas_pending" end
    end
    if name == "SHOP" and not G.shop then return false, "shop_pending" end
    if name == "BLIND_SELECT" and not G.blind_select then return false, "blind_pending" end
    if name == "ROUND_EVAL" and not G.round_eval then return false, "cashout_pending" end
    if is_pack(name) then
        if not G.booster_pack or not G.pack_cards or not G.pack_cards.cards then
            return false, "pack_pending"
        end
        if name == "SMODS_BOOSTER_OPENED" and not (SMODS and SMODS.OPENED_BOOSTER) then
            return false, "pack_pending"
        end
    end
    return true
end

local function identity(card)
    return card.sort_id
end

local function capture_impl()
    local name = state_name(G.STATE)
    local areas, selections, playing_order = {}, {}, {}
    local runtime = {schema = CardRuntime.SCHEMA, cards = {}}
    for _, area_name in ipairs(area_names) do
        local area = G[area_name]
        if area and area.cards and type(area.save) == "function" then
            areas[area_name] = area:save()
            selections[area_name] = {}
            for _, card in ipairs(area.highlighted or {}) do
                selections[area_name][#selections[area_name] + 1] = identity(card)
            end
            for _, card in ipairs(area.cards) do runtime.cards[identity(card)] = CardRuntime.capture(card) end
        end
    end
    for _, card in ipairs(G.playing_cards or {}) do
        playing_order[#playing_order + 1] = identity(card)
    end
    local tags = {}
    for _, tag in ipairs(G.GAME.tags or {}) do tags[#tags + 1] = tag:save() end
    local save = {
        cardAreas = areas,
        tags = tags,
        GAME = G.GAME,
        STATE = G.STATE,
        BLIND = G.GAME.blind:save(),
        BACK = G.GAME.selected_back:save(),
        SCORING_CALC = G.GAME.current_scoring_calculation:save(),
        VERSION = G.VERSION
    }
    -- Card:save in this game version misspells its highlighted field. Save the
    -- actual selection separately, including its sequence, rather than patch it.
    local extra = {
        state = name,
        selected = selections,
        playing_order = playing_order,
        card_runtime = runtime,
        counters = { sort_id = G.sort_id, playing_card = G.playing_card, ID = G.ID }
    }
    if SMODS and SMODS.last_hand then
        extra.last_hand = {}
        extra.last_hand.scoring_name = SMODS.last_hand.scoring_name
        for _, field in ipairs({ "scoring_hand", "full_hand" }) do
            extra.last_hand[field] = {}
            for _, card in ipairs(SMODS.last_hand[field] or {}) do
                extra.last_hand[field][#extra.last_hand[field] + 1] = identity(card)
            end
        end
    end
    if is_pack(name) then
        local opened = SMODS and SMODS.OPENED_BOOSTER
        if opened then
            extra.opened_booster = opened:save()
            runtime.cards[identity(opened)] = CardRuntime.capture(opened)
        elseif booster_obj and booster_obj.key then
            extra.booster_key = booster_obj.key
        end
        extra.pack_source = state_name(G.GAME.PACK_INTERRUPT)
    end
    if name=='ROUND_EVAL' or extra.pack_source=='ROUND_EVAL' then extra.cashout=Cashout.capture() end
    extra.poker_hand_order=HandOrder.capture(G.GAME.hands)
    return {
        schema = 1,
        seed = clone(G.GAME.pseudorandom.seed),
        save = clone(save, nil, 1, true),
        -- Only the native save used object culling before. Extras keep strict
        -- data-only validation instead of accepting new Object placeholders.
        extra = clone(extra, nil, 1)
    }
end

function Snapshot.capture(allow_overlay)
    if Snapshot.restoring then return nil, "restoring" end
    local stable, reason = Snapshot.is_stable(allow_overlay)
    if not stable then return nil, reason end
    local ok, result = pcall(capture_impl)
    if not ok then return nil, tostring(result) end
    return result
end

local function valid_array(value, limit)
    if type(value) ~= "table" or #value > limit then return false end
    local count = 0
    for key in pairs(value) do
        if type(key) ~= "number" or key < 1 or key % 1 ~= 0 or key > #value then return false end
        count = count + 1
    end
    return count == #value
end

local function validate_card(card)
    if type(card) ~= "table" or type(card.save_fields) ~= "table"
        or type(card.ability) ~= "table" or type(card.base) ~= "table"
        or type(card.params) ~= "table" or type(card.sort_id) ~= "number"
        or card.sort_id ~= card.sort_id or card.sort_id < 0 or card.sort_id % 1 ~= 0 then
        return false
    end
    if not G.P_CENTERS[card.save_fields.center] then return false end
    if card.save_fields.card and not G.P_CARDS[card.save_fields.card] then return false end
    return true
end

function Snapshot.validate(snapshot)
    if type(snapshot) ~= "table" or snapshot.schema ~= 1
        or type(snapshot.seed) ~= "string" or #snapshot.seed < 1 or #snapshot.seed > 64
        or type(snapshot.save) ~= "table" or type(snapshot.extra) ~= "table" then
        return nil, "invalid_snapshot"
    end
    local save, extra = snapshot.save, snapshot.extra
    if not HandOrder.validate(extra.poker_hand_order,type(save.GAME)=='table' and save.GAME.hands) then
        return nil,'invalid_poker_hand_order'
    end
    local cashout_ok,cashout_error=Cashout.validate(extra.cashout)
    if not cashout_ok then return nil,cashout_error end
    if not G or not G.STATES or not G.P_CENTERS or not G.P_CARDS then
        return nil, "game_not_ready"
    end
    if not supported[extra.state] or save.STATE ~= G.STATES[extra.state] then
        return nil, "unsupported_state"
    end
    if save.VERSION ~= G.VERSION then return nil, "game_version_mismatch" end
    if type(save.GAME) ~= "table" or type(save.GAME.pseudorandom) ~= "table"
        or save.GAME.pseudorandom.seed ~= snapshot.seed
        or type(save.GAME.round_resets) ~= "table" or type(save.GAME.current_round) ~= "table"
        or type(save.BACK) ~= "table" or type(save.BACK.name) ~= "string"
        or type(save.BLIND) ~= "table" or type(save.BLIND.name) ~= "string"
        or type(save.SCORING_CALC) ~= "table"
        or not (SMODS and SMODS.Scoring_Calculations[save.SCORING_CALC.key]) then
        return nil, "invalid_run_data"
    end
    if type(save.cardAreas) ~= "table" or type(extra.selected) ~= "table"
        or type(extra.counters) ~= "table" or not valid_array(extra.playing_order, 10000)
        or not valid_array(save.tags or {}, 1000) then
        return nil, "invalid_areas"
    end
    for _, key in ipairs({ "sort_id", "playing_card", "ID" }) do
        local value = extra.counters[key]
        if value ~= nil and (type(value) ~= "number" or value ~= value or value < 0
            or value == math.huge or value % 1 ~= 0) then
            return nil, "invalid_counter"
        end
    end
    for key, value in pairs(save.GAME.pseudorandom) do
        if key ~= "seed" and (type(value) ~= "number" or value ~= value
            or value == math.huge or value == -math.huge) then
            return nil, "invalid_rng"
        end
    end
    local ids, count = {}, 0
    for area_name, area in pairs(save.cardAreas) do
        if not area_set[area_name] or type(area) ~= "table" or type(area.config) ~= "table"
            or type(area.config.card_limits) ~= "table" or not valid_array(area.cards, 10000) then
            return nil, "invalid_area_" .. tostring(area_name)
        end
        local area_ids = {}
        for _, card in ipairs(area.cards) do
            if not validate_card(card) or ids[card.sort_id] then return nil, "invalid_card" end
            count = count + 1
            if count > 20000 then return nil, "too_many_cards" end
            ids[card.sort_id], area_ids[card.sort_id] = true, true
        end
        local selected = extra.selected[area_name] or {}
        if not valid_array(selected, 10000) then return nil, "invalid_selection" end
        local seen = {}
        for _, id in ipairs(selected) do
            if not area_ids[id] or seen[id] then return nil, "invalid_selection" end
            seen[id] = true
        end
    end
    for _, name in ipairs(base_areas) do
        if not save.cardAreas[name] then return nil, "missing_area_" .. name end
    end
    if extra.state == "SHOP" or (is_pack(extra.state) and extra.pack_source == "SHOP") then
        for _, name in ipairs(shop_areas) do
            if not save.cardAreas[name] then return nil, "missing_area_" .. name end
        end
    end
    if is_pack(extra.state) then
        if not save.cardAreas.pack_cards or not supported[extra.pack_source]
            or is_pack(extra.pack_source) then return nil, "invalid_pack" end
        if extra.state == "SMODS_BOOSTER_OPENED" and not validate_card(extra.opened_booster) then
            return nil, "invalid_booster"
        end
        local key = extra.opened_booster and extra.opened_booster.save_fields.center or extra.booster_key
        if not key or not G.P_CENTERS[key] or G.P_CENTERS[key].set ~= "Booster" then
            return nil, "missing_booster"
        end
    end
    if extra.card_runtime ~= nil then
        local runtime = extra.card_runtime
        if type(runtime) ~= 'table' or runtime.schema ~= CardRuntime.SCHEMA or type(runtime.cards) ~= 'table' then
            return nil, 'invalid_card_runtime'
        end
        local opened_id = is_pack(extra.state) and extra.opened_booster and extra.opened_booster.sort_id
        for id, entry in pairs(runtime.cards) do
            if not ids[id] and id ~= opened_id or type(entry) ~= 'table' or not CardRuntime.validate(entry) then
                return nil, 'invalid_card_runtime'
            end
        end
        -- A present schema records every card, including an empty entry for
        -- known nil. Only an entirely absent block means legacy unknown data.
        for id in pairs(ids) do if runtime.cards[id] == nil then return nil, 'missing_card_runtime' end end
        if opened_id and runtime.cards[opened_id] == nil then return nil, 'missing_card_runtime' end
    end
    for _, id in ipairs(extra.playing_order) do
        if not ids[id] then return nil, "missing_playing_card" end
    end
    for _, tag in ipairs(save.tags or {}) do
        if type(tag) ~= "table" or type(tag.key) ~= "string" or not G.P_TAGS[tag.key] then
            return nil, "invalid_tag"
        end
    end
    local ok = pcall(clone, snapshot)
    if not ok then return nil, "invalid_snapshot_data" end
    return true
end

local function box(definition, align, y)
    return UIBox({
        definition = definition,
        config = { align = align, offset = { x = 0, y = y }, major = G.hand, bond = "Weak" }
    })
end

local function restore_card_runtime(snapshot, card)
    local runtime = snapshot.extra.card_runtime
    if runtime then CardRuntime.restore(card, runtime.cards[identity(card)]) end
end

local function rebuild_shop(snapshot, hidden)
    local save = snapshot.save
    G.shop = box(G.UIDEF.shop(), "tmi", hidden and G.ROOM.T.y + 29 or -5.3)
    if hidden then G.shop.alignment.offset.py = -5.3 end
    for _, name in ipairs(shop_areas) do
        G[name]:load(clone(save.cardAreas[name]))
        for _, card in ipairs(G[name].cards) do
            restore_card_runtime(snapshot, card)
            create_shop_card_ui(card)
        end
        G["load_" .. name] = nil
    end
end

local function rebuild_blinds(hidden)
    G.blind_select = box(create_UIBox_blind_select(), "bmi", 0)
    local y = 0.8 - (G.hand.T.y - G.jokers.T.y) + G.blind_select.T.h
    G.blind_select.alignment.offset.y = hidden and G.ROOM.T.y + 39 or y
    if hidden then G.blind_select.alignment.offset.py = y end
    G.blind_select.alignment.offset.x = 0
end

local function rebuild_cashout(snapshot,hidden)
    if type(create_UIBox_round_evaluation)=='function' and type(add_round_eval_row)=='function' then
        return Cashout.rebuild(snapshot.extra.cashout,hidden,box)
    end
    -- Re-evaluating the round would repeat tag/deck rewards. Present the already
    -- computed amount and reuse the game's ordinary cash_out callback instead.
    local amount = tostring(G.GAME.current_round.dollars or 0)
    local definition = {
        n = G.UIT.ROOT,
        config = { align = "cm", colour = G.C.BLACK, r = 0.15, padding = 0.3 },
        nodes = {
            UIBox_button({
                label = { localize("b_cash_out") .. ": $" .. amount },
                button = "cash_out", colour = G.C.ORANGE, minw = 5, minh = 1
            })
        }
    }
    G.round_eval = box(definition, "bm", hidden and G.ROOM.T.y + 29 or -7.8)
    if hidden then G.round_eval.alignment.offset.py = -7.8 end
end

local function restore_selections(snapshot)
    local cards = {}
    for _, name in ipairs(area_names) do
        local area = G[name]
        if area and area.cards then
            area.highlighted = {}
            for _, card in ipairs(area.cards) do
                restore_card_runtime(snapshot, card)
                CardRuntime.prepare_controls(card)
                cards[identity(card)] = card
                card.highlighted = false
                if card.children and card.children.use_button then
                    card.children.use_button:remove()
                    card.children.use_button = nil
                end
            end
            for _, id in ipairs(snapshot.extra.selected[name] or {}) do
                local card = cards[id]
                if card and card.area == area then
                    -- Rebuild the native use/sell/select controls, not only
                    -- the boolean that lifts a selected card on screen.
                    if card.highlight then card:highlight(true) else card.highlighted = true end
                    area.highlighted[#area.highlighted + 1] = card
                end
            end
            area:align_cards()
            if area.hard_set_cards then area:hard_set_cards() end
        end
    end
    G.playing_cards = {}
    for _, id in ipairs(snapshot.extra.playing_order) do
        if cards[id] then G.playing_cards[#G.playing_cards + 1] = cards[id] end
    end
    local last_hand = snapshot.extra.last_hand
    SMODS.last_hand = nil
    if last_hand then
        SMODS.last_hand = { scoring_name = last_hand.scoring_name, scoring_hand = {}, full_hand = {} }
        for _, field in ipairs({ "scoring_hand", "full_hand" }) do
            for _, id in ipairs(last_hand[field] or {}) do
                if cards[id] then SMODS.last_hand[field][#SMODS.last_hand[field] + 1] = cards[id] end
            end
        end
    end
end

local runtime_fields = {
    ["blind"] = true, ["selected_back"] = true, ["current_scoring_calculation"] = true,
    ["tags"] = true, ["round_resets.blind"] = true
}

local function restore_game_data(target, saved, prefix)
    -- Preserve reconstructed object references and the tables used by UI labels,
    -- but undo load-time changes such as Tag:load incrementing tag_tally.
    prefix = prefix or ""
    for key in pairs(target) do
        local path = prefix .. tostring(key)
        if saved[key] == nil and not runtime_fields[path] then target[key] = nil end
    end
    for key, value in pairs(saved) do
        local path = prefix .. tostring(key)
        if not runtime_fields[path] then
            if type(value) == "table" and type(target[key]) == "table" then
                restore_game_data(target[key], value, path .. ".")
            else
                target[key] = clone(value)
            end
        end
    end
end

local function restore_impl(snapshot)
    -- This function must be called at a Game.update boundary, not inside an Event.
    -- clear_queue() alone retains no_delete events from the abandoned branch.
    for _, queue in pairs((G.E_MANAGER and G.E_MANAGER.queues) or {}) do
        for key in pairs(queue) do queue[key] = nil end
    end
    G:delete_run()
    G.E_MANAGER = EventManager()
    G.round_eval, G.blind_prompt_box = nil, nil
    G.booster_pack_sparkles, G.booster_pack_stars, G.booster_pack_meteors = nil, nil, nil
    G.GAME_OVER_UI, G.OVERLAY_MENU, G.OVERLAY_TUTORIAL = nil, nil, nil
    G.VIEWING_DECK, G.view_deck = nil, nil
    SMODS.OPENED_BOOSTER, booster_obj = nil, nil
    if G.CONTROLLER.dragging then G.CONTROLLER.dragging.target = nil end
    G.CONTROLLER.locked, G.CONTROLLER.lock_input = false, false
    G.CONTROLLER.locks = {}
    -- Native start_run only instantiates the base card areas. Shop/pack areas
    -- belong to the scene rebuilt below; handing them to the native loader
    -- creates "not instantiated before load" errors and stale load_* queues.
    local native_save = clone(snapshot.save)
    for _, area in ipairs(area_names) do G['load_' .. area] = nil end
    for _, area in ipairs(shop_areas) do native_save.cardAreas[area] = nil end
    native_save.cardAreas.pack_cards = nil
    G:start_run({ savetext = native_save })
    -- start_run schedules a delayed input unlock and unlock-notification work for
    -- loading an ordinary save. Objects are already rebuilt synchronously here;
    -- do not replay those notifications or wait on an artificial load delay.
    -- Keep easing/background events, whose only role is drawing the new scene.
    G.CONTROLLER.locks.load = nil
    for _, queue in pairs(G.E_MANAGER.queues or {}) do
        for index = #queue, 1, -1 do
            local event = queue[index]
            local background = event.trigger == "immediate"
                and event.blocking == false and event.blockable == false
            if not background and event.trigger ~= "ease" then table.remove(queue, index) end
        end
    end
    restore_game_data(G.GAME, snapshot.save.GAME)
    HandOrder.bind(G.GAME.hands,snapshot.extra.poker_hand_order)

    local name = snapshot.extra.state
    local source = is_pack(name) and snapshot.extra.pack_source or name
    if source == "SHOP" then rebuild_shop(snapshot, is_pack(name)) end
    if source == "BLIND_SELECT" then rebuild_blinds(is_pack(name)) end
    if source == "ROUND_EVAL" then rebuild_cashout(snapshot,is_pack(name)) end
    if is_pack(name) then
        local saved_booster = snapshot.extra.opened_booster
        local key = saved_booster and saved_booster.save_fields.center or snapshot.extra.booster_key
        booster_obj = G.P_CENTERS[key]
        if saved_booster then
            local card = Card(0, 0, G.CARD_W, G.CARD_H, G.P_CARDS.empty, booster_obj,
                { bypass_discovery_center = true, bypass_discovery_ui = true })
            card:load(clone(saved_booster))
            restore_card_runtime(snapshot, card)
            card.opening = true
            card.states.visible = false
            SMODS.OPENED_BOOSTER = card
        end
        local definition
        if name == "SMODS_BOOSTER_OPENED" then
            definition = booster_obj:create_UIBox()
        else
            definition = assert(_G[pack_names[name]], "Missing vanilla pack UI")()
        end
        G.booster_pack = box(definition, "tmi", -2.2)
        G.pack_cards:load(clone(snapshot.save.cardAreas.pack_cards))
        G.load_pack_cards = nil
        if booster_obj.ease_background_colour then booster_obj:ease_background_colour() end
    elseif name == "GAME_OVER" then
        G.FUNCS.overlay_menu({ definition = create_UIBox_game_over(), config = { no_esc = true } })
    end
    G.STATE = snapshot.save.STATE
    G.STATE_COMPLETE = true
    G.SETTINGS.paused = name == "GAME_OVER"
    G.TAROT_INTERRUPT = nil
    G.GAME.STOP_USE = 0
    G.CONTROLLER.interrupt.focus = nil
    restore_selections(snapshot)
    -- No constructor-created save flag may reach the following native frame.
    G.FILE_HANDLER = {}
end

local function finish_guard(context)
    -- Release function references first, even if later runtime cleanup fails.
    finish_progress_guard(context)
    G.F_NO_SAVING = context.no_saving
    local flags = context.file_flags
    if flags then
        flags.run = nil
        flags.update_queued = nil
        for _, value in pairs(flags) do
            if value then flags.update_queued = true; break end
        end
    end
    -- A queued vanilla save refers to the abandoned branch. Keep unrelated
    -- settings/progress flags, but never put that stale run payload back.
    G.FILE_HANDLER = flags
    if G.ARGS then G.ARGS.save_run = nil end
    if G.CONTROLLER then
        if G.CONTROLLER.locks then G.CONTROLLER.locks.worldline_restore = nil end
        G.CONTROLLER.locked = false
    end
    active_guard = nil
end

local function lock_restoration()
    G.CONTROLLER.locks.worldline_restore = true
    G.CONTROLLER.locked = true
end

local function recover(context, reason)
    if context.backup and not context.rollback_error then
        local backup = context.backup
        context.backup = nil
        context.rollback_error = "restore_failed_rolled_back: " .. tostring(reason)
        local ok, err = pcall(restore_impl, backup)
        if ok then
            context.snapshot, context.frames = backup, 0
            pending = context
            lock_restoration()
            return false
        end
        reason = tostring(reason) .. "; rollback_failed: " .. tostring(err)
    end
    -- Do not expose a half-built run for further recording if even the backup
    -- cannot load. The independent tree file remains available for retry.
    if type(G.delete_run) == "function" then pcall(G.delete_run, G) end
    if type(G.main_menu) == "function" then pcall(G.main_menu, G, "game") end
    finish_guard(context)
    pending = nil
    Snapshot.restoring = false
    return nil, tostring(reason)
end

-- A longer native replay may nest ordinary checkpoint reconstruction inside it.
-- Hold profile writes for the complete session, including error recovery.
function Snapshot.begin_readonly_session()
    local context={no_saving=G.F_NO_SAVING,file_flags=G.FILE_HANDLER and clone(G.FILE_HANDLER),
        profiles=clone(G.PROFILES or {}),prototypes={}}
    for _,name in ipairs({'P_CENTERS','P_BLINDS','P_TAGS','P_SEALS','P_STAKES'}) do
        local flags={};context.prototypes[name]=flags
        for key,prototype in pairs(G[name] or {}) do
            flags[key]={unlocked=prototype.unlocked,discovered=prototype.discovered,alerted=prototype.alerted}
        end
    end
    G.F_NO_SAVING=true
    begin_progress_guard(context,true)
    return context
end
function Snapshot.end_readonly_session(context)
    finish_progress_guard(context)
    G.PROFILES=context.profiles
    for name,group in pairs(context.prototypes) do
        for key,flags in pairs(group) do
            local prototype=G[name] and G[name][key]
            if prototype then
                prototype.unlocked,prototype.discovered,prototype.alerted=flags.unlocked,flags.discovered,flags.alerted
            end
        end
    end
    G.F_NO_SAVING=context.no_saving
    G.FILE_HANDLER=context.file_flags
    if G.ARGS then G.ARGS.save_run=nil end
end

function Snapshot.restore(snapshot)
    if Snapshot.restoring then return nil, "already_restoring" end
    local valid, reason = Snapshot.validate(snapshot)
    if not valid then return nil, reason end
    local context = {
        snapshot = clone(snapshot),
        backup = Snapshot.capture(true),
        frames = 0,
        no_saving = G.F_NO_SAVING,
        file_flags = G.FILE_HANDLER and clone(G.FILE_HANDLER) or nil
    }
    active_guard = context
    Snapshot.restoring = true
    G.F_NO_SAVING = true
    begin_progress_guard(context)
    local ok, err = pcall(restore_impl, context.snapshot)
    if not ok then
        local _, failure = recover(context, err)
        if failure then return nil, failure end
        return true -- Backup recovery is pending; update will report the error.
    end
    pending = context
    lock_restoration()
    return true
end

function Snapshot.update()
    if not pending then return nil end
    pending.frames = pending.frames + 1
    if pending.frames > 1200 then return recover(pending, "restore_timeout") end
    local ready = Snapshot.is_stable(false)
    if not ready then return false end
    local context, snapshot = pending, pending.snapshot
    local ok, err = pcall(function()
        restore_game_data(G.GAME, snapshot.save.GAME)
        restore_selections(snapshot)
        -- Leave global, non-run RNG alone; only rewind named gameplay streams.
        G.GAME.pseudorandom = clone(snapshot.save.GAME.pseudorandom)
        G.sort_id = snapshot.extra.counters.sort_id or G.sort_id
        G.playing_card = snapshot.extra.counters.playing_card or G.playing_card
        G.ID = math.max(snapshot.extra.counters.ID or 0, G.ID or 0)
    end)
    if not ok then return recover(context, err) end
    finish_guard(context)
    pending = nil
    Snapshot.restoring = false
    if context.rollback_error then return nil, context.rollback_error end
    return true
end

-- Emergency entry point for an unexpected exception outside update's ordinary
-- protected work. Keep the caller's job pending while one backup rollback runs;
-- update then returns nil,error, preventing checkout of the failed target.
function Snapshot.abort(reason)
    local message = "external_restore_error: " .. tostring(reason)
    if pending then
        local ok, waiting, failure = pcall(recover, pending, message)
        if ok then return waiting, failure end
        message = message .. "; abort_failed: " .. tostring(waiting)
    end
    -- Even a failure before pending was assigned has the original save guard.
    -- Do not change a pre-existing F_NO_SAVING flag when this adapter owns none.
    if active_guard and G then pcall(finish_guard, active_guard) end
    if G and G.CONTROLLER then
        if G.CONTROLLER.locks then G.CONTROLLER.locks.worldline_restore = nil end
        G.CONTROLLER.locked = false
    end
    pending, active_guard = nil, nil
    Snapshot.restoring = false
    return nil, message
end

return Snapshot

-- Offline contract checks. These mocks do not load Balatro or access its saves.
local Snapshot = dofile("src/runtime/snapshot.lua")

local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, item in pairs(value) do result[key] = copy(item) end
    return result
end

local saved_calls, opened_calls, deleted_calls, built_pack_ui
Object = {}
local card_serial, make_area
local function make_card(saved)
    card_serial = card_serial + 1
    local card = {
        sort_id = card_serial, playing_card = card_serial,
        params = {}, base = { id = 2 }, ability = { set = "Default" },
        save_fields = { center = "c_base", card = "S_2" },
        states = { visible = true },
        config = { center_key = "c_base", card_key = "S_2", center = G.P_CENTERS.c_base }
    }
    function card:save()
        return {
            sort_id = self.sort_id, playing_card = self.playing_card,
            params = copy(self.params), base = copy(self.base), ability = copy(self.ability),
            save_fields = copy(self.save_fields)
        }
    end
    function card:load(data)
        for key, value in pairs(data) do self[key] = copy(value) end
        self.config = {
            center_key = self.save_fields.center,
            card_key = self.save_fields.card,
            center = G.P_CENTERS[self.save_fields.center]
        }
        -- Simulate seeded initialization work in Card/Tag loading.
        G.GAME.pseudorandom.initialization = (G.GAME.pseudorandom.initialization or 0) + 1
    end
    function card:open() opened_calls = opened_calls + 1 end
    function card:highlight(value) self.highlighted = value; self.highlight_ui = value end
    if saved then card:load(saved) end
    return card
end

make_area = function(area_type, cards)
    local area = {
        cards = cards or {}, highlighted = {},
        config = { type = area_type, card_limits = { total_slots = 52, base = 52 } },
        T = { x = 0, y = 3, w = 5, h = 1 }
    }
    for _, card in ipairs(area.cards) do card.area = area end
    function area:save()
        local data = { config = copy(self.config), cards = {} }
        for _, card in ipairs(self.cards) do data.cards[#data.cards + 1] = card:save() end
        return data
    end
    function area:load(data)
        self.cards, self.highlighted, self.config = {}, {}, copy(data.config)
        for _, item in ipairs(data.cards) do
            local card = make_card(item)
            card.area = self
            self.cards[#self.cards + 1] = card
        end
    end
    function area:align_cards() end
    function area:hard_set_cards() end
    return area
end

local function game_object(data)
    return {
        object = true,
        is = function(_, class) return class == Object end,
        save = function() return copy(data) end
    }
end

local function setup(state)
    saved_calls, opened_calls, deleted_calls, built_pack_ui = 0, 0, 0, 0
    card_serial = 0
    G = {
        VERSION = "1.0.1o-FULL", STAGE = 1, STAGES = { RUN = 1 },
        STATES = {
            SELECTING_HAND = 1, BLIND_SELECT = 7, SHOP = 5, ROUND_EVAL = 8,
            GAME_OVER = 4, TAROT_PACK = 9, PLANET_PACK = 10, SPECTRAL_PACK = 11,
            STANDARD_PACK = 12, BUFFOON_PACK = 13, SMODS_BOOSTER_OPENED = 999
        },
        SETTINGS = { paused = false }, STATE_COMPLETE = true,
        CONTROLLER = { locks = {}, dragging = {}, interrupt = {} },
        FILE_HANDLER = { run = false }, sort_id = 80, playing_card = 52, ID = 100,
        ROOM = { T = { x = 0, y = 0 } }, ROOM_ATTACH = {},
        CARD_W = 1, CARD_H = 1.4, UIT = { ROOT = 1, R = 2 },
        C = { BLACK = {}, ORANGE = {} },
        P_CENTERS = {
            c_base = { key = "c_base", set = "Default" },
            v_grabber = { key = "v_grabber", set = "Voucher" }
        },
        P_CARDS = { S_2 = {}, empty = {} }, P_TAGS = { tag_skip = {} },
        FUNCS = {}, UIDEF = {}
    }
    G.STATE = G.STATES[state]
    EventManager = function()
        local result = { queues = { base = {}, other = {}, unlock = {} } }
        function result:clear_queue() self.queues = { base = {} } end
        return result
    end
    G.E_MANAGER = EventManager()
    SMODS = { Scoring_Calculations = { multiply = {} } }
    G.P_CENTERS.b_red = game_object({key = 'b_red'})
    G.P_CENTERS.b_red.key = 'b_red'
    G.GAME = {
        pseudorandom = { seed = "TREESEED", hashed_seed = 0.17, shuffle = 0.123 },
        round_resets = {}, current_round = { dollars = 12 }, STOP_USE = 0, tag_tally = 7,
        tags = {},
        blind = game_object({ name = "Small Blind" }),
        selected_back = game_object({ name = "Red Deck" }), selected_back_key = G.P_CENTERS.b_red,
        current_scoring_calculation = game_object({ key = "multiply", config = {} })
    }
    G.hand = make_area("hand", { make_card(), make_card() })
    G.deck = make_area("deck", { make_card() })
    G.discard = make_area("discard")
    G.play = make_area("play")
    G.jokers = make_area("joker", { make_card() })
    G.consumeables = make_area("joker")
    local redeemed_voucher = make_card()
    redeemed_voucher.playing_card = nil
    redeemed_voucher.save_fields.center = "v_grabber"
    redeemed_voucher.ability = { set = "Voucher", redeemed = true, retained_value = 42 }
    G.vouchers = make_area("voucher", { redeemed_voucher })
    G.playing_cards = { G.deck.cards[1], G.hand.cards[2], G.hand.cards[1] }
    G.hand.highlighted = { G.hand.cards[2], G.hand.cards[1] }
    for _, card in ipairs(G.hand.highlighted) do card.highlighted = true end
    SMODS.last_hand = { scoring_name = "High Card", full_hand = { G.hand.cards[2] }, scoring_hand = { G.hand.cards[2] } }

    UIBox = function(options)
        return {
            definition = options.definition, T = { h = 2 },
            alignment = { offset = copy((options.config or {}).offset or { x = 0, y = 0 }) },
            remove = function() end
        }
    end
    UIBox_button = function(options) return { button = options.button, label = options.label } end
    localize = function(key) return key end
    create_shop_card_ui = function(card) card.shop_ui = true end
    create_UIBox_blind_select = function() return {} end
    create_UIBox_game_over = function() return {} end
    G.UIDEF.shop = function()
        G.shop_jokers, G.shop_vouchers, G.shop_booster = make_area("shop"), make_area("shop"), make_area("shop")
        return {}
    end
    G.FUNCS.overlay_menu = function(options)
        G.OVERLAY_MENU = UIBox(options)
        G.SETTINGS.paused = true
    end
    Card = function() return make_card() end
    recursive_table_cull = function(value)
        if type(value) ~= "table" then return value end
        if value.is and value:is(Object) then return '"MANUAL_REPLACE"' end
        local result = {}
        for key, item in pairs(value) do result[key] = recursive_table_cull(item) end
        return result
    end
    save_run = function() saved_calls = saved_calls + 1; error("save_run must not be called") end

    function G:delete_run()
        deleted_calls = deleted_calls + 1
        self.OVERLAY_MENU = nil
        self.shop, self.round_eval, self.blind_select, self.booster_pack = nil, nil, nil, nil
        for _, name in ipairs({ "hand", "deck", "discard", "play", "jokers", "consumeables", "vouchers", "shop_jokers", "shop_vouchers", "shop_booster", "pack_cards" }) do self[name] = nil end
    end
    function G:start_run(args)
        local save = args.savetext
        for _, name in ipairs({'shop_jokers', 'shop_vouchers', 'shop_booster', 'pack_cards'}) do
            assert(save.cardAreas[name] == nil,
                'native loader cannot load scene card areas before their UI has created them')
            assert(self['load_' .. name] == nil, 'abandoned deferred card loads must not leak into a restore')
        end
        self.GAME, self.STATE = save.GAME, save.STATE
        self.GAME.blind = game_object(save.BLIND)
        self.GAME.selected_back = game_object(save.BACK)
        self.GAME.selected_back_key = self.P_CENTERS.b_red
        self.GAME.current_scoring_calculation = game_object(save.SCORING_CALC)
        self.GAME.tag_tally = self.GAME.tag_tally + 1
        self.GAME.current_round.dollars = self.GAME.current_round.dollars + 40
        self.SETTINGS.paused = false
        for _, name in ipairs({ "hand", "deck", "discard", "play", "jokers", "consumeables", "vouchers" }) do
            self[name] = make_area("hand")
            self[name]:load(save.cardAreas[name])
        end
        self.CONTROLLER.locks.load = true
        self.E_MANAGER.queues.base = {
            { trigger = "immediate", blocking = false, blockable = false },
            { trigger = "after", delay = 3.5, no_delete = true, timer = "TOTAL" },
            { trigger = "immediate", blocking = true }
        }
        self.FILE_HANDLER = { settings = true, update_queued = true }
    end
    if state == "SHOP" then
        G.shop = UIBox({})
        G.shop_jokers, G.shop_vouchers, G.shop_booster = make_area("shop", { make_card() }), make_area("shop"), make_area("shop")
    elseif state == "BLIND_SELECT" then
        G.blind_select = UIBox({})
    elseif state == "ROUND_EVAL" then
        G.round_eval = UIBox({})
    elseif state == "GAME_OVER" then
        G.OVERLAY_MENU, G.SETTINGS.paused = UIBox({}), true
    end
end

for _, state in ipairs({ "SELECTING_HAND", "SHOP", "BLIND_SELECT", "ROUND_EVAL", "GAME_OVER" }) do
    setup(state)
    assert(Snapshot.is_stable())
    local snapshot, reason = Snapshot.capture()
    assert(snapshot, reason)
    assert(Snapshot.validate(snapshot))
    assert(snapshot.save.GAME.blind == '"MANUAL_REPLACE"'
        and snapshot.save.GAME.selected_back == '"MANUAL_REPLACE"'
        and snapshot.save.GAME.current_scoring_calculation == '"MANUAL_REPLACE"',
        'single-pass capture must preserve the exact native Object cull marker')
    assert(saved_calls == 0 and not G.FILE_HANDLER.run)
    local hand_id = snapshot.save.cardAreas.hand.cards[2].sort_id
    G.GAME.pseudorandom.shuffle = 0.999
    G.hand.cards[2].ability.changed = true
    assert(snapshot.save.GAME.pseudorandom.shuffle == 0.123)
    assert(not snapshot.save.cardAreas.hand.cards[2].ability.changed)
    assert(Snapshot.restore(snapshot))
    assert(Snapshot.restoring)
    assert(Snapshot.update())
    assert(not Snapshot.restoring and not G.F_NO_SAVING)
    assert(G.GAME.pseudorandom.shuffle == 0.123 and G.GAME.pseudorandom.initialization == nil)
    assert(G.GAME.tag_tally == 7 and G.GAME.current_round.dollars == 12)
    assert(G.hand.highlighted[1].sort_id == hand_id)
    assert(#G.hand.highlighted == 2)
    assert(G.hand.highlighted[1].highlight_ui and G.hand.highlighted[2].highlight_ui,
        "restored selection must rebuild native card controls")
    assert(G.playing_cards[2].sort_id == hand_id)
    assert(SMODS.last_hand.full_hand[1].sort_id == hand_id)
    assert(#G.vouchers.cards == 1 and G.vouchers.cards[1].save_fields.center == "v_grabber")
    assert(G.vouchers.cards[1].ability.redeemed and G.vouchers.cards[1].ability.retained_value == 42)
    assert(saved_calls == 0 and opened_calls == 0 and deleted_calls == 1)
    assert(G.FILE_HANDLER.run == nil and G.FILE_HANDLER.settings == nil)
    assert(#G.E_MANAGER.queues.base == 1, "do not keep startup unlock/notification events")
    if state == "ROUND_EVAL" then
        assert(G.round_eval.definition.nodes[1].button == "cash_out")
        assert(G.round_eval.definition.nodes[1].label[1]:find("12"))
    end
end

-- Capture validates and detaches in one traversal, without a second native
-- recursive copy. Object cycles are culled; malformed data cycles still fail.
setup('SELECTING_HAND')
recursive_table_cull = function() error('capture must not make an intermediate deep copy') end
G.GAME.blind.cycle = G.GAME.blind
local one_pass = assert(Snapshot.capture())
assert(one_pass.save.GAME.blind == '"MANUAL_REPLACE"')
local shared = {value = 23}
G.GAME.capture_a, G.GAME.capture_b = shared, shared
one_pass = assert(Snapshot.capture())
assert(one_pass.save.GAME.capture_a ~= shared and one_pass.save.GAME.capture_a ~= one_pass.save.GAME.capture_b,
    'shared native data is detached independently, as before')
shared.value = 99
assert(one_pass.save.GAME.capture_a.value == 23 and one_pass.save.GAME.capture_b.value == 23)
G.GAME.capture_a.cycle = G.GAME.capture_a
local failed, capture_error = Snapshot.capture()
assert(not failed and capture_error:find('cycle'), 'data cycles must fail without partially saving')
G.GAME.capture_a, G.GAME.capture_b = nil, nil
G.GAME.capture_bad = function() end
failed, capture_error = Snapshot.capture()
assert(not failed and capture_error:find('unsupported value'), 'non-data values remain rejected')

-- Shop restoration is also used after purchase/sale and leaving the shop.
-- Repeated convergence must not hand the scene areas to native start_run or
-- retain its abandoned deferred load queues; our UI reconstruction owns them.
setup('SHOP')
G.shop_jokers.cards[1].from_tag = true
G.shop_vouchers.cards = {make_card()};G.shop_vouchers.cards[1].area=G.shop_vouchers
G.shop_vouchers.cards[1].ability={set='Voucher'}
G.shop_vouchers.cards[1].from_tag=true
G.shop_booster.cards={make_card()};G.shop_booster.cards[1].area=G.shop_booster
G.shop_booster.cards[1].from_tag=false
local shop_snapshot = assert(Snapshot.capture())
local shop_card_id = shop_snapshot.save.cardAreas.shop_jokers.cards[1].sort_id
assert(shop_snapshot.save.cardAreas.shop_jokers.cards[1].from_tag==nil,
    'fixture mirrors native save omitting the gameplay provenance flag')
assert(shop_snapshot.extra.card_runtime.schema==1
    and shop_snapshot.extra.card_runtime.cards[shop_card_id].from_tag==true)
assert(next(shop_snapshot.extra.card_runtime.cards[G.hand.cards[1].sort_id])==nil,
    'capture records known nil explicitly without inventing a false default')
create_shop_card_ui=function(card)
    assert(card.from_tag==shop_snapshot.extra.card_runtime.cards[card.sort_id].from_tag,
        'provenance must be restored before shop controls are rebuilt')
    card.shop_ui=true
end
for attempt = 1, 3 do
    G.load_shop_jokers, G.load_shop_vouchers, G.load_shop_booster = {stale = true}, {}, {}
    G.GAME.dollars = -attempt
    assert(Snapshot.restore(shop_snapshot))
    assert(Snapshot.update())
    assert(G.shop and #G.shop_jokers.cards == 1 and G.shop_jokers.cards[1].sort_id == shop_card_id)
    assert(G.shop_jokers.cards[1].from_tag==true and G.shop_vouchers.cards[1].from_tag==true
        and G.shop_booster.cards[1].from_tag==false and G.hand.cards[1].from_tag==nil)
    assert(G.load_shop_jokers == nil and G.load_shop_vouchers == nil and G.load_shop_booster == nil)
    assert(shop_snapshot.save.cardAreas.shop_jokers.cards[1].sort_id == shop_card_id,
        'deferring the native load never edits the immutable restore snapshot')
end

for _, kind in ipairs({ "arcana", "celestial", "spectral", "standard", "buffoon" }) do
    setup("SHOP")
    local key = "p_" .. kind .. "_test"
    G.P_CENTERS[key] = {
        key = key, set = "Booster",
        create_UIBox = function()
            built_pack_ui = built_pack_ui + 1
            G.pack_cards = make_area("consumeable")
            return {}
        end
    }
    local booster = make_card()
    booster.save_fields.center, booster.config.center = key, G.P_CENTERS[key]
    booster.playing_card = nil
    booster.from_tag=true
    SMODS.OPENED_BOOSTER = booster
    G.STATE = G.STATES.SMODS_BOOSTER_OPENED
    G.GAME.PACK_INTERRUPT, G.GAME.pack_choices = G.STATES.SHOP, 2
    G.pack_cards, G.booster_pack = make_area("consumeable", { make_card(), make_card() }), UIBox({})
    G.pack_cards.highlighted = { G.pack_cards.cards[2] }
    local snapshot = assert(Snapshot.capture())
    assert(Snapshot.validate(snapshot))
    local pack_id = snapshot.save.cardAreas.pack_cards.cards[2].sort_id
    assert(Snapshot.restore(snapshot))
    assert(Snapshot.update())
    assert(built_pack_ui == 1 and opened_calls == 0)
    assert(G.GAME.pack_choices == 2 and G.GAME.PACK_INTERRUPT == G.STATES.SHOP)
    assert(#G.pack_cards.cards == 2 and G.pack_cards.highlighted[1].sort_id == pack_id)
    assert(SMODS.OPENED_BOOSTER.config.center.key == key)
    assert(SMODS.OPENED_BOOSTER.from_tag==true,
        'an opened tagged booster is outside card areas but still needs provenance')
    assert(G.shop and G.shop.alignment.offset.py == -5.3)
    assert(G.GAME.pseudorandom.initialization == nil)
end

setup("SELECTING_HAND")
local good = assert(Snapshot.capture())
local bad = copy(good)
bad.seed = "OTHERSEED"
assert(not Snapshot.validate(bad))
assert(not Snapshot.restore(bad) and deleted_calls == 0)
bad = copy(good)
bad.save.cardAreas.hand.cards[1].save_fields.center = "missing_card"
assert(not Snapshot.validate(bad))
bad = copy(good)
bad.save.VERSION = "other_version"
assert(not Snapshot.validate(bad))
bad=copy(good);bad.extra.card_runtime.schema=2
assert(not Snapshot.validate(bad))
bad=copy(good);bad.extra.card_runtime.cards[good.save.cardAreas.hand.cards[1].sort_id]=nil
assert(not Snapshot.validate(bad), 'new runtime schemas cannot silently lose a card record')
bad=copy(good);bad.extra.card_runtime.cards[99999]={from_tag=true}
assert(not Snapshot.validate(bad), 'runtime records must refer to actual snapshot cards')
bad=copy(good);bad.extra.card_runtime.cards[good.save.cardAreas.hand.cards[1].sort_id]={from_tag='true'}
assert(not Snapshot.validate(bad), 'tag provenance only accepts native bool/nil values')
bad=copy(good);bad.extra.card_runtime=nil
assert(Snapshot.validate(bad), 'legacy snapshots remain loadable without guessed provenance')
G.CONTROLLER.locks.use = true
assert(not Snapshot.capture())
G.CONTROLLER.locks.use = nil
G.E_MANAGER.queues.base = { { trigger = "after", blocking = false, blockable = false } }
assert(not Snapshot.capture())
G.E_MANAGER.queues.base = { { trigger = 'after', timer = 'REAL', blocking = false, blockable = false } }
assert(not Snapshot.capture(), 'Unidentified nonblocking events can still change gameplay')
G.E_MANAGER.queues.base[1]._worldline_visual = 'juice_card_until'
assert(Snapshot.capture(), 'An identified repeating card pulse does not prevent stable snapshots')
G.E_MANAGER.queues.base[1].blocking = true
assert(not Snapshot.capture(), 'A visual marker never bypasses actual blocking events')

setup("SELECTING_HAND")
good = assert(Snapshot.capture())
G.FILE_HANDLER = { run = true, settings = true, update_queued = true }
G.ARGS = { save_run = { old_branch = true } }
assert(Snapshot.restore(good))
assert(Snapshot.update())
assert(G.FILE_HANDLER.run == nil and G.FILE_HANDLER.settings and G.FILE_HANDLER.update_queued)
assert(G.ARGS.save_run == nil, "never queue the abandoned branch save after restoration")

setup("SELECTING_HAND")
good = assert(Snapshot.capture())
G.GAME.current_round.dollars = 99
local start_run = G.start_run
local first = true
G.start_run = function(self, args)
    if first then first = false; error("injected target load failure") end
    return start_run(self, args)
end
assert(Snapshot.restore(good), "a valid backup recovery should remain pending")
assert(Snapshot.restoring)
local restored, failure = Snapshot.update()
assert(not restored and failure:find("restore_failed_rolled_back"))
assert(not Snapshot.restoring and G.GAME.current_round.dollars == 99)
assert(not G.CONTROLLER.locks.worldline_restore)

setup("SELECTING_HAND")
good = assert(Snapshot.capture())
G.GAME.current_round.dollars = 88
assert(Snapshot.restore(good))
G.CONTROLLER.locks.use = true
for _ = 1, 1200 do assert(Snapshot.update() == false) end
assert(Snapshot.update() == false, "timed-out target should begin restoring the backup once")
restored, failure = Snapshot.update()
assert(not restored and failure:find("restore_timeout"))
assert(G.GAME.current_round.dollars == 88 and not Snapshot.restoring)

setup("SELECTING_HAND")
good = assert(Snapshot.capture())
G.GAME.current_round.dollars = 77
G.FILE_HANDLER = { run = true, progress = true, update_queued = true }
G.ARGS = { save_run = { old_branch = true } }
assert(Snapshot.restore(good))
assert(Snapshot.abort("injected unexpected update error") == false)
assert(Snapshot.restoring and G.F_NO_SAVING and G.CONTROLLER.locks.worldline_restore)
restored, failure = Snapshot.update()
assert(not restored and failure:find("external_restore_error") and failure:find("injected unexpected update error"))
assert(G.GAME.current_round.dollars == 77 and not Snapshot.restoring)
assert(not G.F_NO_SAVING and not G.CONTROLLER.locked and not G.CONTROLLER.locks.worldline_restore)
assert(G.FILE_HANDLER.run == nil and G.FILE_HANDLER.progress and G.FILE_HANDLER.update_queued)
assert(G.ARGS.save_run == nil)
-- A repeated or out-of-band abort must terminate cleanly without reviving work.
Snapshot.restoring = true
G.CONTROLLER.locks.worldline_restore = true
G.CONTROLLER.locked = true
restored, failure = Snapshot.abort("no pending restore")
assert(not restored and failure:find("no pending restore"))
assert(not Snapshot.restoring and not G.CONTROLLER.locked and not G.CONTROLLER.locks.worldline_restore)

-- Loading a native save synchronously checks continue_game (Throwback) before
-- it assigns the saved GAME, and checks most_money after rebuilding. Clearing
-- its delayed notifications cannot undo those profile mutations.
local progress_names = {'check_for_unlock','unlock_card','discover_card',
    'unlock_achievement','inc_career_stat','check_and_set_high_score'}
local method_names = {'save_progress','save_notify','save_settings'}
local function progress_probe()
    local probe = { calls = 0, refs = {}, methods = {}, loads = 0 }
    for _, key in ipairs(progress_names) do
        _G[key] = function() probe.calls = probe.calls + 1 end
        probe.refs[key] = _G[key]
    end
    for _, key in ipairs(method_names) do
        G[key] = function() probe.calls = probe.calls + 1 end
        probe.methods[key] = G[key]
    end
    local native_start = G.start_run
    G.start_run = function(self, args)
        probe.loads = probe.loads + 1
        check_for_unlock({type='continue_game'})
        unlock_card(self.P_CENTERS.c_base)
        discover_card(self.P_CENTERS.c_base)
        unlock_achievement('synthetic_load_achievement')
        self:save_notify(self.P_CENTERS.c_base)
        self:save_progress()
        if probe.fail_always or probe.fail_first and probe.loads == 1 then error('progress probe load failure') end
        native_start(self, args)
        check_and_set_high_score('most_money', 999)
        inc_career_stat('c_losses', 1)
        self:save_settings()
    end
    function probe:assert_active()
        for _, key in ipairs(progress_names) do assert(_G[key] ~= self.refs[key]) end
        for _, key in ipairs(method_names) do assert(G[key] ~= self.methods[key]) end
        assert(self.calls == 0, 'reconstruction must not execute profile callbacks')
    end
    function probe:assert_released()
        for _, key in ipairs(progress_names) do assert(_G[key] == self.refs[key], key..' reference was not restored') end
        for _, key in ipairs(method_names) do assert(G[key] == self.methods[key], key..' reference was not restored') end
        assert(self.calls == 0, 'the restore guard must not undo a profile mutation after it happened')
    end
    return probe
end

setup('SELECTING_HAND')
good = assert(Snapshot.capture())
local probe = progress_probe()
local usage = function() return 'gameplay usage helper' end
set_hand_usage, set_consumeable_usage, set_voucher_usage = usage, usage, usage
local queued_unlock = {trigger='immediate',func=function()unlock_card(G.P_CENTERS.c_base)end}
local queued_achievement = {trigger='after',func=function()unlock_achievement('already_earned')end}
G.E_MANAGER.queues.unlock = {queued_unlock}
G.E_MANAGER.queues.achievement = {queued_achievement}
local queued_progress, queued_settings = {previous_progress=true}, {previous_settings=true}
G.ARGS = {save_progress=queued_progress,save_settings=queued_settings,save_run={abandoned=true}}
G.FILE_HANDLER = {progress=true,settings=true,run=true,update_queued=true}
assert(Snapshot.restore(good))
probe:assert_active()
assert(not G.FILE_HANDLER.update_queued and not G.FILE_HANDLER.run and not G.FILE_HANDLER.progress,
    'native update must not flush old or constructor-created save flags while restoring')
assert(set_hand_usage==usage and set_consumeable_usage==usage and set_voucher_usage==usage,
    'mixed profile/GAME usage helpers must remain callable')
G.CONTROLLER.locks.use = true
assert(Snapshot.update()==false)
check_for_unlock({type='continue_game'});discover_card(G.P_CENTERS.c_base);G:save_notify({})
probe:assert_active()
G.CONTROLLER.locks.use = nil
assert(Snapshot.update())
probe:assert_released()
assert(G.GAME.seeded==nil, 'restoring an ordinary run must not permanently mark it seeded')
assert(G.ARGS.save_progress==queued_progress and G.ARGS.save_settings==queued_settings)
assert(G.FILE_HANDLER.progress and G.FILE_HANDLER.settings and G.FILE_HANDLER.run==nil)
assert(G.E_MANAGER.queues.unlock[1]==queued_unlock and #G.E_MANAGER.queues.unlock==1)
assert(G.E_MANAGER.queues.achievement[1]==queued_achievement and #G.E_MANAGER.queues.achievement==1)
queued_unlock.func();queued_achievement.func()
assert(probe.calls==2, 'already-earned progress events resume after the guard ends')

for _, failure_mode in ipairs({'first_load','both_loads','timeout','abort','finalize'}) do
    setup('SELECTING_HAND')
    good = assert(Snapshot.capture())
    probe = progress_probe()
    G.F_NO_SAVING = true
    G.FILE_HANDLER = {progress=true,update_queued=true}
    G.E_MANAGER.queues.unlock = {queued_unlock}
    if failure_mode=='first_load' then probe.fail_first=true end
    if failure_mode=='both_loads' then probe.fail_always=true end
    local started = Snapshot.restore(good)
    if failure_mode=='both_loads' then
        assert(not started and not Snapshot.restoring)
    else
        assert(started);probe:assert_active()
        if failure_mode=='timeout' then
            G.CONTROLLER.locks.use=true
            for _=1,1200 do assert(Snapshot.update()==false) end
            assert(Snapshot.update()==false)
        elseif failure_mode=='abort' then
            assert(Snapshot.abort('progress guard abort')==false)
        elseif failure_mode=='finalize' then
            G.hand.align_cards=function()error('progress guard finalization failure')end
            assert(Snapshot.update()==false)
        end
        probe:assert_active()
        local ok, err=Snapshot.update()
        assert(not ok and err and not Snapshot.restoring)
    end
    probe:assert_released()
    assert(G.F_NO_SAVING==true and G.FILE_HANDLER.progress)
    assert(G.E_MANAGER.queues.unlock[1]==queued_unlock and #G.E_MANAGER.queues.unlock==1)
end

-- Class methods must not become permanent own fields after a temporary guard.
setup('SELECTING_HAND')
good=assert(Snapshot.capture())
local inherited=function()error('inherited profile save executed during restore')end
setmetatable(G,{__index={save_progress=inherited}})
assert(rawget(G,'save_progress')==nil)
assert(Snapshot.restore(good));assert(Snapshot.update())
assert(rawget(G,'save_progress')==nil and G.save_progress==inherited)

-- Replay protects profile writes for the complete session while retaining the
-- vanilla helper's in-run score updates. A nested restore must release back to
-- this outer guard rather than enabling profile writes early.
setup('SELECTING_HAND')
G.PROFILES={{career_stats={played=4}}}
G.P_CENTERS.c_base.discovered=false
G.P_TAGS={tag_skip={alerted=false}}
G.FILE_HANDLER={progress=true}
G.ARGS={save_progress={earned=true}}
local score=function(_,value) G.GAME.replay_score=value end
check_and_set_high_score=score
local session=Snapshot.begin_readonly_session()
assert(G.F_NO_SAVING and not G.FILE_HANDLER.progress)
assert(check_and_set_high_score==score)
check_and_set_high_score('furthest_round',9)
assert(G.GAME.replay_score==9,'Native in-run score updates are gameplay state')
good=assert(Snapshot.capture())
assert(Snapshot.restore(good));assert(Snapshot.update())
assert(check_and_set_high_score==score and G.F_NO_SAVING)
G.PROFILES[1].career_stats.played=99
G.P_CENTERS.c_base.discovered=true
G.P_TAGS.tag_skip.alerted=true
Snapshot.end_readonly_session(session)
assert(G.PROFILES[1].career_stats.played==4 and G.P_CENTERS.c_base.discovered==false)
assert(G.P_TAGS.tag_skip.alerted==false,'Hover alerts must not leak into later profile saves')
assert(not G.F_NO_SAVING and G.FILE_HANDLER.progress and G.ARGS.save_progress.earned)
-- Candidate enumeration survives a generic save/load table reconstruction.
setup('SELECTING_HAND')
G.GAME.hands={Pair={level=7},['High Card']={level=2}}
Snapshot.install_hand_order()
good=assert(Snapshot.capture())
assert(Snapshot.restore(good));assert(Snapshot.update())
local restored={};for key in pairs(G.GAME.hands)do restored[#restored+1]=key end
for i,key in ipairs(good.extra.poker_hand_order)do assert(restored[i]==key)end
assert(G.GAME.hands.Pair.level==7 and good.save.GAME.hands.Pair.level==7)
assert(good.save.GAME.selected_back_key == '"MANUAL_REPLACE"')
assert(G.GAME.selected_back_key == G.P_CENTERS.b_red and G.GAME.selected_back_key.key == 'b_red',
    'Restore retains the native reconstructed deck reference instead of its object-culling marker')
print("PASS snapshot: stable states, all five SMODS packs, selection/order, RNG restore, no save/open side effects, import rejection")

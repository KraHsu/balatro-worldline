local Tree = dofile("src/domain/tree.lua")
local Codec = dofile("src/storage/codec.lua")
local Storage = dofile("src/storage/repository.lua")
local function clone(t)
    if type(t) ~= "table" then return t end
    local result = {}
    for k, v in pairs(t) do result[k] = clone(v) end
    return result
end
local files, writes, starts, fail_writes = {}, 0, 0, false
local captures = 0
local fs = {}
function fs.createDirectory() return true end
function fs.getInfo(path)
    if files[path] then return {type = "file", size = #files[path], modtime = 1} end
end
function fs.read(path) return files[path] end
function fs.write(path, data)
    if fail_writes then return nil, "disk full" end
    files[path] = data; writes = writes + 1; return true
end
function fs.remove(path)
    if not files[path] then return nil, 'not found' end
    files[path] = nil
    return true
end
function fs.getDirectoryItems(path)
    local result = {}
    for name in pairs(files) do
        if name:sub(1, #path + 1) == path .. "/" then result[#result + 1] = name:sub(#path + 2) end
    end
    return result
end
function fs.getSaveDirectory() return "C:/test/save" end
love = {filesystem = fs, timer = {getTime = function() return 0.25 end},
    system = {openURL = function() return true end}}
local cancel_native_quit, native_quit_calls = false, 0
love.quit = function()
    native_quit_calls = native_quit_calls + 1
    if cancel_native_quit then return true end
end
local function joker(key)
    return {config = {center = {key = key, name = key, atlas = "Joker", pos = {x = 1, y = 2}}}}
end
G = {VERSION = "1.0.1o-FULL", STATES = {SELECTING_HAND = 1, BLIND_SELECT = 2, SHOP = 3, GAME_OVER = 4},
    STAGE = 1, STAGES = {RUN = 1, MENU = 2}, STATE = 2, ID = 10,
    SETTINGS = {profile = 1, language = "en-us"}, FUNCS = {},
    jokers = {cards = {joker("j_joker")}}, hand = {cards = {1, 2}}, deck = {cards = {3, 4, 5}}}
G.UIT, G.C = {ROOT = 'root', R = 'row', T = 'text'}, {CLEAR = {}, UI = {TEXT_LIGHT = {}}}
local toggle_args, config_saves
config_saves = 0
function create_toggle(args) toggle_args = args; return {toggle = args} end
function UIBox_button(args) return args end
local initial = {pseudorandom = {seed = "TREESEED", lucky_mult = 0.375}, dollars = 4,
    current_round = {hands_left = 4, discards_left = 3}, round_resets = {ante = 1},
    round = 1, selected_back_key = "b_red", selected_back = {name = "Red Deck"}, stake = 1,
    blind = {name = "Small Blind", config = {blind = {key = "bl_small"}}}}
G.GAME = clone(initial)
function G.FUNCS.exit_overlay_menu() G.OVERLAY_MENU = nil; G.SETTINGS.paused = false end
Game = {}
setmetatable(G, {__index = Game})
function Game:update() end
function Game:start_run(args)
    starts = starts + 1
    G.GAME = clone(args.savetext and args.savetext.GAME or initial)
    G.STATE = args.savetext and args.savetext.STATE or G.STATES.BLIND_SELECT
    G.jokers.cards = clone(args.savetext and args.savetext.inventory or {joker("j_joker")})
    G.STAGE = G.STAGES.RUN
end
local Snapshot = {restoring = false}
local engine_ready = true
local function state_name()
    for name, value in pairs(G.STATES) do if value == G.STATE then return name end end
end
function Snapshot.is_stable(allow_overlay)
    return engine_ready and (allow_overlay or not G.SETTINGS.paused or G.STATE == G.STATES.GAME_OVER)
end
function Snapshot.capture(allow_overlay)
    captures = captures + 1
    if not Snapshot.is_stable(allow_overlay) then return nil, "transition" end
    return {schema = 1, seed = G.GAME.pseudorandom.seed,
        save = {GAME = clone(G.GAME), STATE = G.STATE, inventory = clone(G.jokers.cards)},
        extra = {state = state_name(), counters = {ID = G.ID}}}
end
function Snapshot.validate(value)
    if type(value) ~= "table" or value.schema ~= 1 or value.seed ~= value.save.GAME.pseudorandom.seed then
        return nil, "invalid snapshot"
    end
    return true
end
function Snapshot.restore(value)
    Snapshot.restoring = true
    G:start_run({savetext = clone(value.save)})
    G.SETTINGS.paused = G.STATE == G.STATES.GAME_OVER
    return true
end
function Snapshot.update() Snapshot.restoring = false; return true end
G.FUNCS.select_blind = function() G.STATE = G.STATES.SELECTING_HAND; return true end
G.FUNCS.skip_blind = function() G.GAME.skips = (G.GAME.skips or 0) + 1; return true end
G.FUNCS.cash_out = function() G.STATE = G.STATES.SHOP; G.GAME.dollars = G.GAME.dollars + 5; return true end
G.FUNCS.toggle_shop = function() G.STATE = G.STATES.BLIND_SELECT; return true end
G.FUNCS.buy_from_shop = function(key)
    if key == 'blocked' then return false end
    if type(key) == 'table' then key = key.config.ref_table.config.center.key end
    G.GAME.dollars = G.GAME.dollars - 4
    G.jokers.cards[#G.jokers.cards + 1] = joker(key)
    return true
end
local function shop_event(key)
    local card = joker(key)
    card.cost, card.sell_cost = 4, 2
    return {config = {ref_table = card}}
end
G.FUNCS.play_cards_from_highlighted = function()
    G.GAME.current_round.hands_left = G.GAME.current_round.hands_left - 1
    G.GAME.pseudorandom.lucky_mult = 0.8125
end
G.FUNCS.discard_cards_from_highlighted = function()
    G.GAME.current_round.discards_left = G.GAME.current_round.discards_left - 1
end
G.FUNCS.use_card = function() G.GAME.dollars = G.GAME.dollars + 1 end
G.FUNCS.go_to_menu = function()
    G.STAGE = G.STAGES.MENU
    G.jokers.cards = {}
end
G.FUNCS.start_run = function(args)
    -- Vanilla callbacks tear down the old scene before rebuilding a run.
    engine_ready = false
    G.jokers.cards = {}
    G:start_run(args or {})
    engine_ready = true
end
local Hooks = dofile("src/runtime/hooks.lua")
local closed_graphs, prepared_opens = 0, 0
local UI = {install = function() end, open = function(ctx, prepared)
    assert(prepared, "the API has already prepared a stable snapshot")
    prepared_opens = prepared_opens + 1
    ctx.ui_view = "tree"; G.SETTINGS.paused = true
    return true
end, close = function(ctx)
    if ctx.ui_view == "tree" then
        closed_graphs = closed_graphs + 1
        ctx.ui_view = nil
        G.SETTINGS.paused = false
    end
end}
local Undo = dofile('src/runtime/undo.lua')
local Progress = dofile('src/domain/progress.lua')
local I18n = dofile('src/ui/i18n.lua')
local Choices = dofile('src/domain/choices.lua')
local Details = dofile('src/ui/details.lua')
local Replay = dofile('src/domain/replay.lua')
local Diff = dofile('src/ui/diff.lua')
local PoolEnvironment = dofile('src/domain/pool_environment.lua')
local CardRuntime = dofile('src/runtime/card_runtime.lua')
local modules = {tree = Tree, codec = Codec, storage = Storage, snapshot = Snapshot, hooks = Hooks, ui = UI,
    undo = Undo, progress = Progress, i18n = I18n, choices = Choices, details = Details, replay = Replay, diff = Diff,
    card_visuals = {install=function()end},
    input_queue = dofile('src/runtime/input_queue.lua'),
    pool_environment = PoolEnvironment, card_runtime = CardRuntime,
    film=dofile('src/video/plan.lua'),film_runtime=dofile('src/video/playback.lua'),film_host=dofile('src/video/host.lua')}
SMODS = {version = "26.1002.0", current_mod = {id = "WorldLine"}}
function SMODS.save_mod_config(mod)
    assert(mod == SMODS.current_mod)
    config_saves = config_saves + 1
    return true
end
function SMODS.load_file(path)
    if path == 'loader.lua' or path == 'runtime/app.lua' then return assert(loadfile('src/' .. path)) end
    local name = path:match('([^/]+)%.lua$')
    if name == 'repository' then name = 'storage' elseif name == 'controller' then name = 'ui' elseif name == 'plan' then name = 'film' elseif name == 'playback' then name = 'film_runtime' elseif name == 'host' then name = 'film_host' end
    return function() return assert(modules[name]) end
end
JSON = TEST_JSON
sendInfoMessage = function() end
sendWarnMessage = function() end
function get_current_pool()
    return G.P_CENTERS and G.P_CENTERS.j_pool_reference and G.P_CENTERS.j_pool_reference.unlocked
end
Snapshot.install_hand_order=function()end
local app = dofile("src/main.lua")
local function persisted(id)
    -- An accepted async save becomes durable only after the write ACK. Tests
    -- inspecting on-disk state explicitly wait at this boundary.
    assert(app.flush_saves())
    return app.storage:load(id)
end
local function close_menu() G.FUNCS.exit_overlay_menu(); app.ui_view = nil end
local function rewind(id)
    local count = starts
    assert(app.request_restore(id))
    assert(starts == count, "restoring waits until a frame boundary")
    G:update(0.1)
    assert(not app.busy and not app.restoring)
end
G:update(0.1)
assert(app.VERSION == "0.2.0")
assert(app.tree and app.tree.current == 1 and app.tree.metadata.seed == "TREESEED")
assert(app.has_public_worldline() and app.auto_create_enabled() and SMODS.current_mod.config.auto_create == true)
SMODS.current_mod.config_tab()
assert(toggle_args.ref_table == SMODS.current_mod.config and toggle_args.ref_value == 'auto_create')
assert(toggle_args.callback(false) and not app.auto_create_enabled() and app.has_public_worldline())
assert(toggle_args.callback(true) and app.auto_create_enabled() and config_saves == 2)
assert(not G.GAME.seeded, 'creating a worldline or changing automatic settings keeps native eligibility')
G.SETTINGS.language = 'zh_CN'; G:update(0.01)
assert(SMODS.current_mod.name == 'WorldLine')
G.SETTINGS.language = 'ja'; G:update(0.01)
assert(SMODS.current_mod.name == 'WorldLine')
G.SETTINGS.language = 'en-us'; G:update(0.01)
assert(SMODS.current_mod.name == 'WorldLine')
assert(app.at_current_node())
local run_id = app.tree.metadata.run_id
-- Undo restores the operation/cursor but retains visited futures. Identical
-- subsequent actions reuse the old child instead of creating a duplicate.
assert(not G.GAME.seeded and not app.tree.metadata.progress_locked)
local capture_before = captures
G.FUNCS.select_blind()
G:update(0.6)
assert(captures - capture_before <= 3,
    'phase recording, Undo validation and autosave share the completed-frame snapshot')
assert(app.can_undo() and app.tree.current == 2 and app.tree.next_id == 3)
local real_restore = Snapshot.restore
Snapshot.restore = function() return nil, 'simulated restore failure' end
assert(app.undo()); G:update(0.1)
assert(app.tree.current == 2 and app.tree.next_id == 3 and #app.tree:get(1).children == 1
    and app.can_undo(), 'failed Undo preserves both the stage history and retry point')
Snapshot.restore = real_restore
assert(app.undo())
G:update(0.1)
assert(G.STATE == G.STATES.BLIND_SELECT and app.tree.current == 1 and app.tree.next_id == 3)
assert(#app.tree:get(1).children == 1 and app.tree:get(2), 'single Undo retains its visited stage node')
assert(not G.GAME.seeded and not app.tree.metadata.progress_locked and not app.can_undo(),
    'Undo-only does not mark an unseeded run; a one-action history is now empty')
G.FUNCS.select_blind()
G:update(0.6)
assert(app.flush_saves())
assert(app.tree.current == 2 and app.tree:get(2).action.kind == "select_blind" and writes > 0)
assert(app.tree.next_id == 3 and #app.tree:get(1).children == 1 and app.status == 'Worldline converged',
    'identical action order and state reuse the old child')
assert(app.tree:get(2).summary.deck == "b_red" and app.tree:get(2).summary.blind_key == "bl_small")
assert(app.tree:get(2).summary.jokers[1].key == "j_joker" and app.tree:get(2).summary.deck_count == 3)
-- Play and discard each undo only their own mutation and never add tree nodes.
capture_before = captures
G.FUNCS.play_cards_from_highlighted()
G:update(0.6)
assert(captures - capture_before == 2, 'play captures one before-state and one completed after-state')
assert(app.can_undo() and app.tree.next_id == 3 and G.GAME.current_round.hands_left == 3)
assert(app.undo()); G:update(0.1)
assert(G.GAME.current_round.hands_left == 4 and G.GAME.pseudorandom.lucky_mult == 0.375)
assert(app.tree.current == 2 and app.tree.next_id == 3 and not G.GAME.seeded)
G.FUNCS.play_cards_from_highlighted()
G.FUNCS.discard_cards_from_highlighted()
app.record_action({kind = "buy", label = "should be ignored"})
G:update(0.6)
assert(app.tree.current == 2 and app.tree.next_id == 3, "battle inputs create no public nodes")
assert(app.tree.resume and app.tree.resume.parent == 2 and app.tree.resume.snapshot.save.GAME.current_round.hands_left == 3)
assert(not app.at_current_node(), "a phase can change even with no pending milestone")
assert(persisted(run_id).resume.snapshot.save.GAME.pseudorandom.lucky_mult == 0.8125)
assert(app.undo()); G:update(0.1)
assert(G.GAME.current_round.hands_left == 3 and G.GAME.current_round.discards_left == 3,
    'back-to-back inputs undo only discard, retaining the preceding play')
assert(app.tree.current == 2 and app.tree.next_id == 3 and not G.GAME.seeded)
G.FUNCS.discard_cards_from_highlighted(); G:update(0.6)
G.FUNCS.cash_out()
G:update(0.6)
assert(app.tree.current == 3 and app.tree:get(3).action.kind == "enter_shop" and app.tree.resume == nil)
assert(app.at_current_node())
G.ID = 99999
app.before_open()
assert(app.at_current_node(), "UI entity counters do not count as a changed gameplay phase")
G.FUNCS.buy_from_shop("j_branch_a")
G:update(0.6)
assert(app.tree.current == 3 and app.tree.resume.summary.jokers[2].key == "j_branch_a")
assert(not app.at_current_node())
assert(app.can_undo())
assert(app.undo()); G:update(0.1)
assert(G.GAME.dollars == 9 and #G.jokers.cards == 1 and app.tree.current == 3 and app.tree.next_id == 4)
G.FUNCS.buy_from_shop('j_branch_a'); G:update(0.6)
assert(app.save_manual())
assert(G.GAME.seeded and app.tree.metadata.progress_locked)
assert(app.undo()); G:update(0.1)
assert(G.GAME.dollars == 9 and #G.jokers.cards == 1 and G.GAME.seeded
    and app.tree.metadata.progress_locked, 'Undo cannot restore eligibility after using another Tree feature')
G.FUNCS.buy_from_shop('j_branch_a'); G:update(0.6)
rewind(3)
assert(G.GAME.seeded and app.tree.metadata.progress_locked, 'historical navigation permanently uses seeded rules')
assert(app.status == 'Worldline converged', 'automatic persistence does not overwrite convergence feedback')
assert(G.STATE == G.STATES.SHOP and G.GAME.dollars == 9 and #G.jokers.cards == 1)
assert(app.tree.resume == nil and app.at_current_node())
G.FUNCS.buy_from_shop(shop_event("j_branch_a"))
G.FUNCS.toggle_shop()
G:update(0.6)
assert(app.tree.current == 4 and app.tree:get(4).summary.jokers[2].key == "j_branch_a")
local branch_a_choices = app.tree:get(4).action.choices
assert(#branch_a_choices == 2 and branch_a_choices[1].kind == 'buy'
    and branch_a_choices[1].card_key == 'j_branch_a' and branch_a_choices[1].cost == 4
    and branch_a_choices[1].money_delta == -4 and branch_a_choices[2].kind == 'leave_shop'
    and #app.phase_choices == 0, 'shopping decisions belong to the outgoing edge; destination starts a new phase')
rewind(3)
G.FUNCS.buy_from_shop(shop_event("j_branch_b"))
G.FUNCS.toggle_shop()
G:update(0.6)
assert(app.tree.current == 5 and #app.tree:get(3).children == 2)
assert(app.status == 'Worldline perturbed', 'only a real sibling branch announces a perturbation')
assert(app.tree:get(4).summary.jokers[2].key == "j_branch_a")
assert(app.tree:get(5).summary.jokers[2].key == "j_branch_b", "shopping results form sibling phase branches")
assert(app.tree:get(5).action.choices[1].card_key == 'j_branch_b'
    and app.tree:get(4).action.choices[1].card_key == 'j_branch_a', 'parallel choices retain their own item identities')
local replay_next, replay_node = app.tree.next_id, app.tree:get(4)
assert(app.set_bookmark(4, 'A route'))
rewind(3)
G.FUNCS.buy_from_shop(shop_event('j_branch_a')); G.FUNCS.toggle_shop(); G:update(0.6)
assert(app.tree.current == 4 and app.tree:get(4) == replay_node and app.tree.next_id == replay_next
    and #app.tree:get(3).children == 2 and app.status == 'Worldline converged',
    'manual rewind plus the exact same shopping route reuses immutable history')
local comparison_captures = captures
local comparison = app.compare_nodes(4, 5)
assert(comparison and not comparison.same and comparison.before_id == 4 and comparison.after_id == 5
    and app.compare_nodes(4, 5) == comparison and captures == comparison_captures,
    'two-node comparison is cached and uses only existing snapshots')
assert(app.undo()); G:update(0.1)
assert(app.tree.current == 3 and app.tree:get(4) == replay_node and app.tree.next_id == replay_next
    and app.bookmark_rows('A route')[1].id == 4 and #app.phase_choices == 1,
    'one-action Undo from a reused stage retains future annotations and restores unfinished choices')
G.FUNCS.toggle_shop(); G:update(0.6)
assert(app.tree.current == 4 and app.tree.next_id == replay_next)
rewind(3)
G.FUNCS.buy_from_shop(shop_event('j_branch_b')); G.FUNCS.toggle_shop(); G:update(0.6)
assert(app.tree.current == 5 and app.tree.next_id == replay_next)
G.FUNCS.select_blind()
G:update(0.6)
assert(app.tree.current == 6)
G.STATE, G.SETTINGS.paused = G.STATES.GAME_OVER, true
G:update(0.6)
assert(app.tree.current == 7 and app.tree:get(7).action.kind == "run_failed")
G:update(0.6)
assert(app.tree.current == 7, "stable failure creates only one terminal milestone")
rewind(3)
G.FUNCS.buy_from_shop("j_branch_b")
G:update(0.6)
assert(app.tree.current == 3 and app.tree.resume)
app.open()
local share_path = assert(app.export_share())
local share_text = files[share_path]
local file = {
    getFilename = function() return "shared.worldline.json" end,
    getSize = function() return #share_text end,
    open = function() return true end,
    read = function() return share_text end,
    close = function() end
}
love.filedropped(file)
assert(app.busy and app.ui_view == "tree")
G:update(0.1)
assert(closed_graphs == 1 and app.ui_view == nil and not G.SETTINGS.paused,
    "file-drop restores close a native graph before the snapshot pause guard is captured")
assert(app.tree.metadata.run_id ~= run_id and app.tree.metadata.source_run_id == run_id)
assert(app.tree.current == 3 and app.tree.next_id == 8 and app.tree.resume)
assert(G.jokers.cards[2].config.center.key == "j_branch_b" and G.GAME.dollars == 5)
assert(not app.at_current_node(), "import restores unfinished shopping, not only the entry node")
assert(persisted(run_id):get(7), "import preserves the original local tree")
local imported_id = app.tree.metadata.run_id
local bad = app.tree:export()
bad.metadata.tree_version = "0.1.0"
local old_text = Codec.encode({format = "worldline", schema = 1, kind = "share", tree = bad}, TEST_JSON)
assert(not app.import_text(old_text) and app.last_error:find("0.1.0", 1, true))
assert(not app.busy and app.tree.metadata.run_id == imported_id)
close_menu()
local continue_data = assert(Snapshot.capture(true)).save
G:start_run({savetext = continue_data})
G:update(0.1)
assert(app.busy)
G:update(0.1)
assert(app.tree.metadata.run_id == imported_id and app.tree.current == 3 and app.tree.resume)
assert(G.jokers.cards[2].config.center.key == "j_branch_b" and not app.at_current_node())
-- Loading the active archive must use its newest in-memory history/resume.
G.FUNCS.buy_from_shop("j_branch_c")
assert(app.load_archive(imported_id))
G:update(0.1)
assert(app.tree.current == 3 and #G.jokers.cards == 3 and app.tree.resume)
assert(app.tree.resume.summary.jokers[3].key == "j_branch_c")
-- F6 during a fine-grained animation waits, then saves only a private resume.
G.FUNCS.use_card()
engine_ready = false
assert(app.open() == false and not G.SETTINGS.paused)
assert(not app.request_restore(3) and not app.busy)
engine_ready = true
G:update(0.3)
assert(app.tree.current == 3 and app.tree.next_id == 8 and G.SETTINGS.paused)
assert(app.tree.resume and app.ui_view == "tree")
assert(prepared_opens == 2, "each graph opening uses a single prepared API entry")
close_menu()
G.FUNCS.go_to_menu()
assert(persisted(imported_id).resume.summary.jokers[3].key == "j_branch_c",
    "the native menu callback saves before deleting old card objects")
G:update(0.1)
assert(app.detached)
rewind(3)
assert(not app.detached and G.STAGE == G.STAGES.RUN and app.tree.resume == nil)
-- Disk failure while switching runs retains the private phase in RAM for retry.
local unsaved_id = app.tree.metadata.run_id
G.FUNCS.buy_from_shop("j_unsaved")
fail_writes = true
G.FUNCS.start_run({})
assert(app.unsaved[unsaved_id] and app.unsaved[unsaved_id].resume)
assert(app.unsaved[unsaved_id].resume.summary.jokers[2].key == "j_unsaved")
G:update(0.1)
assert(app.tree.metadata.run_id ~= unsaved_id)
fail_writes = false
app.retry_clock = 0
G:update(0.6)
assert(persisted(unsaved_id).resume.summary.jokers[2].key == "j_unsaved")
assert(app.unsaved[unsaved_id] == nil)
-- Simulate a fresh process where native save.jkr contains seeded=true, but a
-- failed Tree write left the older unlocked archive on disk.
assert(not G.GAME.seeded)
assert(app.save_now())
local stale_id = app.tree.metadata.run_id
assert(not persisted(stale_id).metadata.progress_locked)
app.use_feature()
local native_locked_continue = assert(Snapshot.capture(true)).save
fail_writes = true
G:start_run({savetext = native_locked_continue})
assert(not app.flush_saves(), 'failed async final write retains the prior valid generation')
fail_writes = false
app.unsaved, app.retry_clock = {}, 100
local reloaded_progress = dofile('src/domain/progress.lua')
for key, value in pairs(reloaded_progress) do Progress[key] = value end
assert(not app.storage:load(stale_id).metadata.progress_locked)
G:update(0.1); assert(app.busy)
G:update(0.1)
assert(G.GAME.seeded and app.tree.metadata.progress_locked and app.tree.metadata.run_id == stale_id,
    'a stale unlocked Tree archive cannot downgrade a newer native seeded save after restart')
app.retry_clock = 0
assert(app.flush_saves())

-- Disabling automatic creation never hides or deletes an existing worldline,
-- including an ordinary Continue attach after the preference has changed.
assert(app.set_auto_create(false) and not app.auto_create_enabled() and app.has_public_worldline())
local existing_public_id = app.tree.metadata.run_id
local existing_continue = assert(Snapshot.capture(true)).save
G:start_run({savetext = existing_continue})
G:update(0.1); assert(app.busy)
G:update(0.1)
assert(app.has_public_worldline() and app.tree.metadata.run_id == existing_public_id)

-- A new run with automatic creation off uses a private in-memory working root
-- only. It creates no archive/attachment IDs but keeps all native Undo features.
G:start_run({})
assert(app.flush_saves(), 'finish the preceding public run before counting private-root writes')
local private_writes = writes
G:update(0.6)
assert(not app.has_public_worldline() and app.private_worldline and app.should_record())
assert(not G.GAME.seeded and not G.GAME.worldline_run_id and not G.GAME.worldline_node_id)
local private_id = app.tree.metadata.run_id
assert(not app.storage:load(private_id))
G.FUNCS.select_blind(); G:update(0.6)
assert(app.tree.current == 1 and app.tree.next_id == 2 and app.can_undo(), 'private stage input adds no public history')
G.FUNCS.play_cards_from_highlighted()
G.FUNCS.discard_cards_from_highlighted()
G:update(0.6)
assert(app.can_undo() and G.GAME.current_round.hands_left == 3 and G.GAME.current_round.discards_left == 2)
local private_restore = Snapshot.restore
Snapshot.restore = function() return nil, 'private Undo restore failed' end
assert(app.undo()); G:update(0.1)
assert(app.private_worldline and not app.has_public_worldline() and app.can_undo(), 'failed private Undo can retry')
Snapshot.restore = private_restore
assert(app.undo()); G:update(0.1)
assert(G.GAME.current_round.hands_left == 3 and G.GAME.current_round.discards_left == 3)
assert(app.private_worldline and app.tree.next_id == 2 and app.can_undo() and app.requires_undo_confirmation())
assert(not G.GAME.seeded and not G.GAME.worldline_run_id and writes == private_writes,
    'private recording and Undo never write worldline files or change native eligibility')
assert(app.save_now() and writes == private_writes and not app.storage:load(private_id))

-- Enabling creation is passive and waits for a stable unpaused scene. The
-- currently unrecorded run then gets a fresh public origin, without seed changes.
G.FUNCS.use_card(); G:update(0.6)
assert(app.can_undo())
local retained_money = G.GAME.dollars
G.SETTINGS.paused = true
assert(app.set_auto_create(true))
G:update(0.6)
assert(not app.has_public_worldline(), 'settings do not interrupt an existing pause/animation to create history')
G.SETTINGS.paused = false
G:update(0.1)
assert(app.has_public_worldline() and not app.private_worldline and app.tree.metadata.run_id ~= private_id)
assert(app.tree.current == 1 and app.tree.next_id == 2 and not app.can_undo())
assert(G.GAME.dollars == retained_money and not G.GAME.seeded and not app.tree.metadata.progress_locked)
G:update(0.6)
assert(persisted(app.tree.metadata.run_id) and writes > private_writes)
assert(app.set_auto_create(false) and app.has_public_worldline())

-- Entity names come from native localization APIs, independently of the mod
-- UI language. Metatable methods are not serialized by the snapshot mock.
setmetatable(G.GAME.selected_back, {__index = {get_name = function() return 'Native localized deck' end}})
localize = function(args)
    if args.set == 'Blind' then return 'Native localized blind' end
    return args.key
end
G.FUNCS.cash_out(); G:update(0.6)
assert(app.tree.current == 2 and app.tree:get(2).summary.deck_name == 'Native localized deck')
assert(app.tree:get(2).summary.blind_name == 'Native localized blind')
assert(app.status == 'Recording worldline', 'following a new frontier does not announce a new branch')
localize = nil

-- The setting itself remains passive in a paused menu, but immediately opening
-- Worldline after enabling it must not trap an already-running game in empty UI.
G:start_run({}); G:update(0.1)
assert(not app.has_public_worldline() and not app.auto_create_enabled())
G.SETTINGS.paused = true
assert(app.set_auto_create(true))
G:update(0.1)
assert(not app.has_public_worldline() and not G.GAME.seeded)
assert(app.open())
assert(app.has_public_worldline() and app.ui_view == 'tree' and G.SETTINGS.paused)
assert(app.tree.current == 1 and app.tree.next_id == 2 and app.tree:get(1).snapshot.save.GAME.dollars == G.GAME.dollars)
assert(G.GAME.seeded and app.tree.metadata.progress_locked, 'explicit viewing follows the active-feature policy')
close_menu()

-- Opening with automatic creation still disabled shows the empty guide and
-- does not implicitly turn a private Undo root into public history.
assert(app.set_auto_create(false))
G:start_run({}); G:update(0.1)
local empty_private = app.tree
assert(app.open())
assert(not app.has_public_worldline() and app.tree == empty_private and app.private_worldline)
close_menu()

-- A second consecutive Undo requires explicit confirmation. Waiting/cancelling
-- is side-effect free; a new irreversible action resets the streak and makes an
-- old opaque confirmation token unusable, even when the same entry resurfaces.
assert(app.set_auto_create(true))
G:start_run({}); G:update(0.1)
G.FUNCS.select_blind(); G:update(0.1)
G.FUNCS.play_cards_from_highlighted(); G:update(0.1)
G.FUNCS.discard_cards_from_highlighted(); G:update(0.1)
assert(app.undo_history_info().count == 3 and app.undo_history_info().limit == 200)
assert(app.undo()); G:update(0.1)
local needed, stale_token = app.requires_undo_confirmation()
assert(needed and stale_token and next(stale_token) == nil, 'confirmation token exposes no snapshot or mutable history')
local confirmation_starts, confirmation_count, confirmation_game = starts, app.undo_history_info().count, G.GAME
local second_ok, second_reason = app.undo()
assert(not second_ok and second_reason == 'confirm_required' and starts == confirmation_starts
    and G.GAME == confirmation_game and app.undo_history_info().count == confirmation_count
    and not G.GAME.seeded and not app.tree.metadata.continuous_undo,
    'unconfirmed second Undo neither restores, consumes, promotes nor locks')
G:update(0.1)
assert(app.undo_confirmation_token() == stale_token and not G.GAME.seeded,
    'cancelling or allowing a prompt to expire does not silently approve or reset the streak')
engine_ready = false
assert(app.undo_confirmation_token() == stale_token and not app.requires_undo_confirmation(),
    'temporary native overlay locks retain identity without allowing a restore')
engine_ready = true
G.FUNCS.use_card(); G:update(0.1)
assert(app.undo_history_info().consecutive == 0 and not app.requires_undo_confirmation())
local confirmed, confirm_reason = app.confirm_continuous_undo(stale_token)
assert(not confirmed and confirm_reason == 'stale_confirmation' and not G.GAME.seeded,
    'a confirmation from a previous action cannot lock or authorize a different Undo')
assert(app.undo()); G:update(0.1)
assert(app.requires_undo_confirmation() and app.undo_confirmation_token() ~= stale_token and not G.GAME.seeded,
    'new input permits one ordinary Undo again but does not approve subsequent repeated Undo')

-- All Undo operations retain history. Confirmation only enables repeated Undo
-- and the seeded eligibility rule; no phase tail needs to be reattached.
G:start_run({}); G:update(0.1)
G.FUNCS.select_blind(); G:update(0.1)
G.FUNCS.cash_out(); G:update(0.1)
G.FUNCS.toggle_shop(); G:update(0.1)
local continuous_tree, phase_tail, continuous_id = app.tree, app.tree:get(4), app.tree.metadata.run_id
assert(app.tree.next_id == 5 and app.undo_history_info().count == 3)
assert(app.undo()); G:update(0.1)
assert(app.tree.current == 3 and app.tree:get(4) == phase_tail and app.tree.next_id == 5 and not G.GAME.seeded)
local token = app.undo_confirmation_token()
assert(app.confirm_continuous_undo(token))
assert(app.tree == continuous_tree and app.tree:get(4) == phase_tail and app.tree.next_id == 5
    and app.tree.current == 3 and app.tree.metadata.continuous_undo and app.tree.metadata.progress_locked
    and G.GAME.seeded and app.has_public_worldline(),
    'confirmation keeps the immutable future and permanently applies native seeded rules')
assert(not app.requires_undo_confirmation() and not app.confirm_continuous_undo(token), 'a consumed prompt cannot confirm twice')
local confirmed_count, confirmed_restore = app.undo_history_info().count, Snapshot.restore
Snapshot.restore = function() return nil, 'restore failed immediately after confirmation' end
assert(app.undo()); G:update(0.1)
assert(app.undo_history_info().count == confirmed_count and app.tree.current == 3
    and app.tree:get(4) == phase_tail and app.tree.next_id == 5
    and app.tree.metadata.continuous_undo and app.tree.metadata.progress_locked and G.GAME.seeded,
    'a failed first continuous restore retains all actions/branches and the already-confirmed sticky lock')
Snapshot.restore = confirmed_restore
assert(app.undo()); G:update(0.1)
assert(G.STATE == G.STATES.SELECTING_HAND and app.tree.current == 2 and app.tree.next_id == 5
    and app.tree:get(3) and app.tree:get(4) == phase_tail and app.undo_history_info().count == 1)
assert(app.undo()); G:update(0.1)
assert(G.STATE == G.STATES.BLIND_SELECT and app.tree.current == 1 and app.tree.next_id == 5
    and not app.can_undo() and not app.requires_undo_confirmation() and G.GAME.seeded)
G.FUNCS.skip_blind(); G:update(0.1)
assert(app.tree.current == 5 and app.tree:get(5).parent == 1 and #app.tree:get(1).children == 2
    and app.tree:get(4) == phase_tail and app.tree.metadata.continuous_undo,
    'a different choice appends a parallel coarse phase branch without deleting the retained future')
local failed_count, failed_next, continuous_restore = app.undo_history_info().count, app.tree.next_id, Snapshot.restore
Snapshot.restore = function() return nil, 'continuous Undo restore failed' end
assert(app.undo()); G:update(0.1)
assert(app.undo_history_info().count == failed_count and app.tree.next_id == failed_next
    and app.tree.current == 5 and app.tree.metadata.progress_locked,
    'failed continuous restore neither pops history nor removes branches')
Snapshot.restore = continuous_restore
assert(app.undo()); G:update(0.1)
assert(app.tree.current == 1 and app.tree.next_id == failed_next and app.tree:get(5) and G.GAME.seeded)
assert(app.save_now())
local continuous_saved = assert(persisted(continuous_id))
assert(continuous_saved.metadata.continuous_undo and continuous_saved.metadata.progress_locked,
    'continuous mode and eligibility lock persist with the worldline')

-- Automatic creation off still permits ordinary Undo. Confirmation promotes
-- that exact working root and remaining session history instead of rebuilding it.
assert(app.set_auto_create(false))
G:start_run({}); G:update(0.1)
assert(app.undo_history_info().count == 0 and not app.undo_history_info().continuous)
local promoted_tree, promoted_root = app.tree, app.tree:get(1)
G.FUNCS.select_blind(); G:update(0.1)
G.FUNCS.play_cards_from_highlighted(); G:update(0.1)
G.FUNCS.discard_cards_from_highlighted(); G:update(0.1)
assert(app.undo()); G:update(0.1)
assert(app.private_worldline and not app.has_public_worldline() and not G.GAME.seeded)
assert(app.confirm_continuous_undo(app.undo_confirmation_token()))
assert(app.tree == promoted_tree and app.tree:get(1) == promoted_root and not app.private_worldline
    and app.has_public_worldline() and app.tree.next_id == 2 and app.undo_history_info().count == 2
    and G.GAME.seeded and G.GAME.worldline_run_id == app.tree.metadata.run_id)
assert(app.undo()); G:update(0.1)
assert(G.GAME.current_round.hands_left == 4 and app.has_public_worldline() and app.tree == promoted_tree
    and app.tree.next_id == 2 and app.undo_history_info().count == 1 and G.GAME.seeded,
    'private-root action snapshots remain usable after public promotion, without creating per-hand nodes')
assert(app.save_now() and persisted(app.tree.metadata.run_id).metadata.continuous_undo)

-- Native seeded runs can repeatedly Undo without a pointless eligibility
-- confirmation. Both Undo operations keep every visited phase.
assert(app.set_auto_create(true))
G:start_run({}); G.GAME.seeded = true; G:update(0.1)
G.FUNCS.select_blind(); G:update(0.1)
G.FUNCS.cash_out(); G:update(0.1)
G.FUNCS.toggle_shop(); G:update(0.1)
local seeded_tail = app.tree:get(4)
assert(app.undo()); G:update(0.1)
assert(app.tree:get(4) == seeded_tail and not app.requires_undo_confirmation()
    and app.undo_confirmation_token() == nil and not app.tree.metadata.continuous_undo)
assert(app.undo()); G:update(0.1)
assert(app.tree:get(4) == seeded_tail and app.tree.current == 2
    and app.tree.metadata.continuous_undo and G.GAME.seeded,
    'seeded second Undo enters branch-preserving mode automatically')

-- Annotation APIs persist UTF-8 names/folds without changing gameplay or
-- recording nodes. Revealing a bookmark expands only its covering folds.
local annotated_tree, annotated_game = app.tree, G.GAME
local annotated_count, annotation_captures = app.tree.next_id, captures
assert(app.set_bookmark(3, '购物路线甲'))
assert(app.bookmark_rows('路线')[1].id == 3)
local region = assert(app.fold_range(1, 4, '前期准备'))
assert(#app.presentation_rows() == 2 and app.presentation_rows()[2].id == 4)
assert(app.reveal_node(3) and #app.presentation_rows() == 4)
assert(app.toggle_fold(region) and #app.presentation_rows() == 2)
assert(app.tree == annotated_tree and G.GAME == annotated_game
    and app.tree.next_id == annotated_count and captures == annotation_captures,
    'navigation annotations never capture or alter the live game')
assert(app.save_now(true, true, true))
local annotated_disk = assert(persisted(app.tree.metadata.run_id))
assert(annotated_disk:bookmark_rows()[1].label == '购物路线甲'
    and annotated_disk:fold_rows()[1].label == '前期准备')
assert(app.remove_fold(region) and #app.presentation_rows() == 4)
assert(app.remove_bookmark(3) and #app.bookmark_rows() == 0)
assert(app.save_now(true, true, true) and app.flush_saves())

-- A rejected transaction adds no choices. A buy's choices survive saving and
-- disappear together with its gameplay effect when that one action is undone.
G.FUNCS.cash_out(); G:update(0.1)
local entry_shop = app.tree.current
assert(G.FUNCS.buy_from_shop('blocked') == false and #app.phase_choices == 0)
G.FUNCS.buy_from_shop(shop_event('j_saved_choice')); G:update(0.6)
assert(app.tree.current == entry_shop and #app.phase_choices == 1)
local choice_disk = assert(persisted(app.tree.metadata.run_id))
assert(choice_disk.resume.choices[1].card_key == 'j_saved_choice')
assert(app.undo()); G:update(0.1)
assert(app.tree.current == entry_shop and #app.phase_choices == 0
    and (not app.tree.resume or #app.tree.resume.choices == 0))
assert(app.flush_saves())

-- Idle shaders/UI updates must not serialize full cards or write an unchanged
-- archive. Real irreversible actions still get one before/after checkpoint.
local detail_calls, original_details = 0, Details.from_snapshot
Details.from_snapshot = function(...)
    detail_calls = detail_calls + 1
    return original_details(...)
end
local idle_captures, idle_writes = captures, writes
for _ = 1, 1000 do G:update(1 / 240) end
assert(captures == idle_captures and writes == idle_writes,
    'an unchanged run performs zero periodic full captures and zero repeated saves')
assert(detail_calls == 0, 'background recording never expands full inventory details')
local displayed = app.node_details(app.tree.current)
assert(displayed and app.node_details(app.tree.current) == displayed and detail_calls == 1
    and captures == idle_captures, 'selected-node details use one cached snapshot-only projection')
G.FUNCS.use_card(); G:update(0.1)
assert(detail_calls == 1, 'ordinary gameplay keeps full details lazy')
Details.from_snapshot = original_details
assert(app.flush_saves())

-- A completed older save cannot clear a newer queued mutation. Pause polling
-- to make the race deterministic rather than relying on fixture encoding time.
local async_id = app.tree.metadata.run_id
assert(app.save_now(true, true, true))
local native_poll = app.storage.poll_save
app.storage.poll_save = function() return nil end
local before_async_writes = writes
G.FUNCS.use_card(); G:update(0.6)
local expected_dollars = G.GAME.dollars
assert(writes == before_async_writes and app.unsaved[async_id] == app.tree,
    'pending serialization retains the newest live worldline until ACK')
app.storage.poll_save = native_poll
for _ = 1, 1000 do
    app.poll_saves()
    if writes > before_async_writes then break end
end
assert(writes == before_async_writes + 1 and app.save_status(async_id)
    and app.unsaved[async_id] == app.tree,
    'the old ACK leaves the newer request and its strong reference intact')
assert(persisted(async_id).resume.snapshot.save.GAME.dollars == expected_dollars)
assert(not app.save_status(async_id) and not app.unsaved[async_id])

-- Respect native quit cancellation, and keep the game open with its newest
-- in-memory state when the final write fails. Retrying commits that same data.
cancel_native_quit = true
assert(love.quit() == true and not app.unsaved[async_id],
    'native cancellation is preserved after completing the passive final save')
cancel_native_quit = false
G.FUNCS.use_card(); G:update(0.1)
expected_dollars = G.GAME.dollars
fail_writes = true
local before_failed_quit = native_quit_calls
assert(love.quit() == true and app.unsaved[async_id] and native_quit_calls == before_failed_quit,
    'failed final write cancels exit before native audio/Steam shutdown')
fail_writes = false
assert(love.quit() == nil)
assert(not app.unsaved[async_id]
    and app.storage:load(async_id).resume.snapshot.save.GAME.dollars == expected_dollars)
for file in pairs(files) do assert(file:sub(1, #"WorldLine/") == "WorldLine/") end

-- Independent purchases may arrive while native events are still pending.
-- Queue fast player inputs until a stable boundary, retaining independent
-- before-states, complete replay inputs and each operation's real money delta.
G.FUNCS.start_run({}); G:update(0.1)
G.FUNCS.cash_out(); G:update(0.1)
local overlapping_shop = app.tree.current
G.FUNCS.buy_from_shop(shop_event('j_overlap_a'))
engine_ready = false
local before_overlapping_captures = captures
G.FUNCS.buy_from_shop(shop_event('j_overlap_b'))
G.FUNCS.buy_from_shop(shop_event('j_overlap_c'))
assert(captures == before_overlapping_captures, 'overlapping inputs never attempt unsafe intermediate snapshots')
engine_ready = true
G:update(0.1)
G:update(0.1);G:update(0.1)
assert(#app.phase_choices == 3 and Undo.count() >= 3 and app.can_undo())
for index, key in ipairs({'j_overlap_a','j_overlap_b','j_overlap_c'}) do
    local choice = app.phase_choices[index]
    assert(choice.card_key == key and not choice.replay_incomplete and choice.money_delta ~= nil,
        'each queued purchase retains its own validated state and money delta')
end
assert(app.save_now())
local overlapping_disk = persisted(app.tree.metadata.run_id)
assert(#overlapping_disk.resume.choices == 3 and Choices.replay_complete(overlapping_disk.resume.choices))
G.FUNCS.toggle_shop(); G:update(0.1)
local overlapping_future, overlapping_next = app.tree.current, app.tree.next_id
assert(app.tree:get(overlapping_future).action.replay_schema == 1)
assert(app.undo()); G:update(0.1)
assert(app.tree.current == overlapping_shop and #app.phase_choices == 3
    and Choices.replay_complete(app.phase_choices)
    and app.tree:get(overlapping_future), 'Undo restores complete private choices and retains the visited future')
G.FUNCS.toggle_shop(); G:update(0.1)
assert(app.tree.current == overlapping_future and app.tree.next_id == overlapping_next,
    'complete queued inputs can reuse an identical historical route')

-- An input before the first stable frame also waits for its own before-state.
G.FUNCS.cash_out(); G:update(0.1)
engine_ready = false
local before_queued_history=Undo.count()
G.FUNCS.buy_from_shop(shop_event('j_missing_before'))
engine_ready = true
G:update(0.1)
G:update(0.1)
assert(#app.phase_choices == 1 and not app.phase_choices[1].replay_incomplete and Undo.count()==before_queued_history+1)

-- Failure after a normal choice append rolls back the tentative log/resume;
-- the observer fallback records the input once and marks it incomplete.
local before_failed_refresh_choices = #app.phase_choices
G.FUNCS.use_card()
local acknowledge_before_failure, acknowledge_failures = Hooks.acknowledge, 0
Hooks.acknowledge = function(...)
    if acknowledge_failures == 0 then
        acknowledge_failures = acknowledge_failures + 1
        error('intentional refresh failure after phase choice append')
    end
    return acknowledge_before_failure(...)
end
G:update(0.1)
Hooks.acknowledge = acknowledge_before_failure
assert(acknowledge_failures == 1 and #app.phase_choices == before_failed_refresh_choices + 1
    and app.phase_choices[#app.phase_choices].kind == 'use'
    and app.phase_choices[#app.phase_choices].replay_incomplete and Undo.count() == 0,
    'failed refresh followed by untracked fallback does not double-record the same input')
assert(app.save_now())
local failed_refresh_disk = persisted(app.tree.metadata.run_id)
assert(#failed_refresh_disk.resume.choices == #app.phase_choices
    and not Choices.replay_complete(failed_refresh_disk.resume.choices))
-- Root eligibility is captured once, travels with the archive, and is used
-- only within candidate calculation. Live discoveries/progress stay intact.
G.P_CENTERS = {j_pool_reference={unlocked=false,discovered=false},e_foil={discovered=false}}
G.FUNCS.start_run({}); G:update(0.1)
local pool_environment = app.tree.metadata.pool_environment
assert(pool_environment.centers.j_pool_reference == 4 and not G.GAME.seeded)
G.P_CENTERS.j_pool_reference.unlocked = true
G.P_CENTERS.e_foil.discovered = true
assert(get_current_pool() == false and G.P_CENTERS.j_pool_reference.unlocked == true)
assert(not G.GAME.seeded, 'root eligibility alone does not disable native achievements')
assert(app.save_now())
local pool_disk = persisted(app.tree.metadata.run_id)
assert(pool_disk.metadata.pool_environment.centers.j_pool_reference == 4)
assert(app.request_restore(app.tree.root)); G:update(0.1)
assert(get_current_pool() == false and G.P_CENTERS.j_pool_reference.unlocked == true
    and G.P_CENTERS.e_foil.discovered == true)
G.FUNCS.go_to_menu()
assert(get_current_pool() == true, 'worldline conditions never leak into the main menu')
-- Archive editing uses verified backups and only publishes after persistence.
G.FUNCS.start_run({}); G:update(0.1)
G.FUNCS.select_blind(); G:update(0.1)
G.FUNCS.cash_out(); G:update(0.1)
local editing_shop = app.tree.current
G.FUNCS.buy_from_shop(shop_event('j_edit_a')); G:update(0.1)
G.FUNCS.toggle_shop(); G:update(0.1)
local editing_a = app.tree.current
assert(app.request_restore(editing_shop)); G:update(0.1)
G.FUNCS.buy_from_shop(shop_event('j_edit_b')); G:update(0.1)
G.FUNCS.toggle_shop(); G:update(0.1)
local editing_b, editing_id, editing_next = app.tree.current, app.tree.metadata.run_id, app.tree.next_id
assert(app.set_bookmark(editing_a, '路线 A'))
assert(app.rename_archive(editing_id, '试验世界线'))
assert(persisted(editing_id).metadata.name == '试验世界线')
assert(not app.branch_delete_preview(app.tree.root).allowed)
assert(not app.branch_delete_preview(editing_b).allowed)
assert(not app.branch_delete_preview(editing_shop).allowed)
local original_snapshot_id = app.tree:get(editing_a).snapshot.save.GAME.worldline_run_id
local exported_path = assert(app.export_branch(editing_a))
local exported_branch = assert(app.storage:decode_share(files[exported_path]))
assert(exported_branch:get(editing_a) and not exported_branch:get(editing_b)
    and exported_branch:get(app.tree.root) and exported_branch:get(editing_shop))
assert(exported_branch.current == editing_a and not exported_branch.resume
    and exported_branch.metadata.run_id ~= editing_id and exported_branch.metadata.source_run_id == editing_id)
assert(app.tree.current == editing_b and app.tree:get(editing_a).snapshot.save.GAME.worldline_run_id == original_snapshot_id)
local stale_preview = assert(app.branch_delete_preview(editing_a))
assert(app.rename_archive(editing_id, '试验世界线二'))
assert(not app.delete_branch(editing_a, stale_preview.token) and app.tree:get(editing_a))
local real_write = fs.write
fs.write = function(path, data)
    if path:find('/backups/', 1, true) then return nil, 'backup disk failure' end
    return real_write(path, data)
end
local failed_preview = assert(app.branch_delete_preview(editing_a))
assert(not app.delete_branch(editing_a, failed_preview.token) and app.tree:get(editing_a))
fs.write = real_write
local deletion_preview = assert(app.branch_delete_preview(editing_a))
local game_before_branch_delete = G.GAME
local deleted_branch, branch_backup = app.delete_branch(editing_a, deletion_preview.token)
assert(deleted_branch and branch_backup.reason == 'branch' and G.GAME == game_before_branch_delete)
assert(not app.tree:get(editing_a) and app.tree:get(editing_b) and app.tree.next_id == editing_next
    and app.tree:node_count() == 4 and Undo.count() == 0)
assert(not persisted(editing_id):get(editing_a))
local restored_copy_id = assert(app.restore_backup(branch_backup.id))
assert(restored_copy_id ~= editing_id and app.storage:load(restored_copy_id):get(editing_a))
assert(app.tree.metadata.run_id == editing_id and G.GAME == game_before_branch_delete,
    'restoring a backup adds an archive without loading it or replacing the current game')

local before_delete_native = {GAME=clone(G.GAME),STATE=G.STATE,inventory=clone(G.jokers.cards)}
local whole_preview = assert(app.archive_delete_preview(editing_id))
fs.write = function(path, data)
    if path:match('%.deleted%.json$') then return nil, 'marker disk failure' end
    return real_write(path, data)
end
assert(not app.delete_archive(editing_id, whole_preview.token))
assert(app.tree.metadata.run_id == editing_id and app.storage:load(editing_id))
fs.write = real_write
whole_preview = assert(app.archive_delete_preview(editing_id))
local native_game = G.GAME
local native_money, native_rng = G.GAME.dollars, G.GAME.pseudorandom.lucky_mult
local deleted_archive, archive_backup = app.delete_archive(editing_id, whole_preview.token)
assert(deleted_archive and archive_backup.reason == 'archive')
assert(G.GAME == native_game and G.GAME.dollars == native_money and G.GAME.pseudorandom.lucky_mult == native_rng)
assert(app.recording_suspended() and app.private_worldline and not app.has_public_worldline()
    and not G.GAME.worldline_run_id and app.storage:is_deleted(editing_id) and not app.storage:load(editing_id))
for _=1,10 do G:update(0.1) end
assert(app.recording_suspended() and app.private_worldline)
for _, row in ipairs(app.archive_rows()) do assert(row.id ~= editing_id) end
local archives_after_delete = #app.archive_rows()
G.FUNCS.use_card(); G:update(0.1)
G.FUNCS.use_card(); G:update(0.1)
assert(app.undo()); G:update(0.1)
assert(app.undo()); G:update(0.1)
for _=1,10 do G:update(0.1) end
assert(app.recording_suspended() and app.private_worldline and not app.has_public_worldline()
    and #app.archive_rows() == archives_after_delete and G.GAME.dollars == native_money,
    'continuous Undo never republishes a recording explicitly suspended by deletion')
-- A native continue saved before deletion must not resurrect the old archive.
G:start_run({savetext=before_delete_native}); G:update(0.1)
assert(app.recording_suspended() and app.private_worldline and G.GAME.seeded == true)
assert(app.resume_recording())
assert(app.has_public_worldline() and not app.recording_suspended() and app.tree.metadata.run_id ~= editing_id)
assert(G.GAME.dollars == native_money and G.GAME.pseudorandom.lucky_mult == native_rng)
assert(persisted(app.tree.metadata.run_id):node_count() == 1)
assert(app.storage:is_deleted(editing_id) and app.storage:load(restored_copy_id))
-- Settings changes are passive, persistent, and revert on save failure.
G.FUNCS.start_run({}); G:update(0.1)
local save_config = SMODS.save_mod_config
SMODS.save_mod_config = function() return false end
assert(not app.set_auto_create(false) and app.auto_create_enabled() and not G.GAME.seeded)
SMODS.save_mod_config = save_config
assert(app.set_auto_create(false) and not app.auto_create_enabled() and not G.GAME.seeded)
assert(app.set_auto_create(true) and app.auto_create_enabled() and not G.GAME.seeded)
-- If creating the private Undo root fails after deletion has committed, the
-- suspended run still uses the saved pool until a later boundary can retry.
G.P_CENTERS.j_pool_reference.unlocked = false
G.FUNCS.start_run({}); G:update(0.1)
local pool_delete_id = app.tree.metadata.run_id
G.P_CENTERS.j_pool_reference.unlocked = true
assert(get_current_pool() == false)
local pool_delete_preview = assert(app.archive_delete_preview(pool_delete_id))
local capture_before_failure = Snapshot.capture
Snapshot.capture = function(...)
    if not app.tree then return nil, 'private root capture failure' end
    return capture_before_failure(...)
end
assert(app.delete_archive(pool_delete_id, pool_delete_preview.token))
Snapshot.capture = capture_before_failure
assert(app.tree == nil and app.recording_suspended() and get_current_pool() == false)
G:update(0.1)
assert(app.private_worldline and app.recording_suspended() and get_current_pool() == false)
-- Real builds use a read-only metadata worker; a loading result remains
-- distinct from an empty list or an error, and update polling avoids rescans.
do
    local requests,polls=0,0
    local browser_error,ready=false,false
    app.archive_browser={
        request=function(_,kind) requests=requests+1;return nil,'loading' end,
        poll=function(_,kind)
            polls=polls+1
            if browser_error then return nil,'reader failure' end
            if not ready then return nil,'loading' end
            return {{id='async_fixture',seed='FIXED',created_at=1,node_count=1}}
        end}
    local rows,err=app.archive_rows();assert(rows==nil and err=='loading' and requests==1)
    rows,err=app.archive_rows(true);assert(rows==nil and err=='loading' and polls==1 and requests==1)
    rows,err=app.backup_rows(true);assert(rows==nil and err=='loading' and polls==2 and requests==1)
    ready=true;rows=app.archive_rows(true);assert(rows[1].id=='async_fixture')
    browser_error=true;rows,err=app.backup_rows(true);assert(rows==nil and err=='reader failure')
    app.archive_browser=nil
end
-- Reproduce the native object-shaped selected_back_key with its inject method.
-- The real snapshot adapter culls native Objects; the root metadata and summary
-- must independently keep just the deck ID instead of traversing that object.
do
    local native_capture = Snapshot.capture
    local injected = false
    local center = {key = 'b_red', inject = function() injected = true end}
    Snapshot.capture = function(...)
        local value, err = native_capture(...)
        if value and type(value.save.GAME.selected_back_key) == 'table' then
            value.save.GAME.selected_back_key = '"MANUAL_REPLACE"'
        end
        return value, err
    end
    G.FUNCS.start_run({})
    G.GAME.selected_back_key = center
    G:update(0.6)
    assert(app.has_public_worldline() and app.tree.metadata.deck == 'b_red' and not app.last_error)
    assert(app.tree:get(1).summary.deck == 'b_red' and not G.GAME.seeded)
    G.FUNCS.select_blind(); G:update(0.6)
    G.FUNCS.play_cards_from_highlighted(); G:update(0.6)
    assert(not app.last_error and app.tree:get(2).summary.deck == 'b_red' and app.can_undo())
    assert(persisted(app.tree.metadata.run_id).metadata.deck == 'b_red')
    assert(G.GAME.selected_back_key == center and not injected,
        'Recording deck identity never replaces the live deck or invokes its methods')
    Snapshot.capture = native_capture
end
print("PASS runtime: worldline phases/resume, passive auto creation/config, private Undo, sharing/restart, native eligibility, recovery, archive editing")

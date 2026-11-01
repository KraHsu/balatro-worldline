local mod = SMODS.current_mod
local Loader
if SMODS and SMODS.load_file then
    Loader = assert(SMODS.load_file('loader.lua', 'WorldLine'))()
else
    Loader = dofile('src/loader.lua')
end
local module = Loader.load
local Tree, Codec = module("tree"), module("codec")
local Snapshot, Storage = module("snapshot"), module("storage")
local Hooks, UI = module("hooks"), module("ui")
local Undo, Progress = module("undo"), module("progress")
local Choices = module("choices")
local Details = module("details")
local Diff, Replay = module("diff"), module("replay")
local PoolEnvironment = module("pool_environment")
local I18n = module("i18n")
local Film = module('film')
local FilmHost=module('film_host')
Snapshot.install_hand_order()
module('card_visuals').install()
mod.config = mod.config or {}
if mod.config.auto_create == nil then mod.config.auto_create = true end
mod.config.film=mod.config.film or {}

local API = {
    -- Archive compatibility is independent of the installed patch version.
    VERSION = "0.2.0", CODE_VERSION = "0.6.6", tree = nil, busy = false, restoring = false,
    detached = false, pending_actions = {}, dirty = false, unsaved = {},
    save_clock = 0, retry_clock = 0, status = "", last_error = nil,
    frame_serial = 0, observe_clock = 0, phase_diverged = false,
    snapshot = Snapshot, core = Tree, private_worldline = false, phase_choices = {}
}
WORLDLINE = API
API.input_queue=module('input_queue').new(API)
API.storage = Storage.new(Codec, Tree, JSON, love.filesystem)
local new_tree
local undo_confirmation
local save_requests, save_ticket = {}, 0

function API.text(zh, en)
    return I18n.text(G and G.SETTINGS and G.SETTINGS.language or 'en-us', zh, en)
end

function API.undo_input_notice(key)
    local value=API.text(nil,key)
    API.status=value
    API.undo_notice={text=value,until_time=love.timer.getTime()+2}
end
if API.storage.set_text then API.storage:set_text(API.text) end

function API.auto_create_enabled() return mod.config.auto_create ~= false end
function API.film_options() return Film.options(mod.config.film) end
function API.choose_film_path(key,finished)
    if API.file_picker and API.file_picker.active then return nil,'A file picker is already open' end
    local owner=API.tree
    local Dialog=module('file_dialog')
    local picker=Dialog.new(Loader.source,
        function(path,err,cancelled)
            if path and API.tree==owner then
                local ok,why=API.set_film_option(key,path)
                if not ok then err=why end
            elseif path then err=API.text(nil,'Worldline changed; reopen this editor') end
            finished(path,err,cancelled)
        end)
    local options=API.film_options()
    local initial=key=='ffmpeg' and options.ffmpeg or (options.output_dir~='' and options.output_dir
        or love.filesystem.getSaveDirectory()..'/WorldLine/recordings')
    local title=API.text(nil,key=='ffmpeg' and 'Choose FFmpeg executable' or 'Choose video output folder')
    local ok,value=pcall(picker.start,picker,key=='ffmpeg' and 'file' or 'folder',title,initial)
    if not ok then return nil,tostring(value) end
    API.file_picker=picker;return value
end
function API.set_film_option(key,value)
    local next_options={}
    for k,v in pairs(mod.config.film) do next_options[k]=v end
    next_options[key]=value
    local ok,validated=pcall(Film.options,next_options)
    if not ok then return nil,validated end
    local previous=mod.config.film;mod.config.film=validated
    if SMODS.save_mod_config then
        local saved,err=pcall(SMODS.save_mod_config,mod)
        if not saved or err==false then mod.config.film=previous;return nil,'Cannot save mod settings' end
    end
    return true
end
function API.has_public_worldline() return API.tree ~= nil and not API.private_worldline end

local function update_brand()
    local locale = G and G.SETTINGS and G.SETTINGS.language or 'en-us'
    if API.brand_locale == locale then return end
    API.brand_locale = locale
    mod.name = 'WorldLine'
    mod.description = API.text('记录世界线，探索其他选择，或撤回上一步。',
        'Record worldlines, explore choices, or undo the last action.')
end
update_brand()

local function report(message)
    if I18n.error then message = I18n.error(G and G.SETTINGS and G.SETTINGS.language or 'en-us', message) end
    local repeated = API.last_error == tostring(message)
    API.last_error = tostring(message)
    API.status = API.last_error
    API.undo_input_notice(API.last_error)
    if sendWarnMessage and not repeated then sendWarnMessage(API.last_error, "WorldLine") end
    return nil, API.last_error
end

-- Encode archives in small cooperative slices and write them off the game
-- thread. The writer source is outside LÖVE's virtual filesystem in Steam.
if love.thread then
    local ok, err = pcall(function()
        API.storage:configure_async({thread = love.thread, clock = love.timer.getTime, sleep = love.timer.sleep,
            source = Loader.source('save_worker')})
    end)
    if not ok then
        -- Missing/unreadable worker code is a visible retryable save failure,
        -- never permission to silently write synchronously on the game thread.
        API.storage:configure_async({thread = love.thread, clock = love.timer.getTime,
            sleep = love.timer.sleep})
        report(err)
    end
end

-- Archive browsing has a separate read-only worker. Even an old archive's
-- first metadata scan must not deserialize its entire history on a UI frame.
if love.thread then
    local ok, value = pcall(function()
        local modules = {}
        for _, name in ipairs({'codec','tree','storage'}) do
            modules[name]=Loader.source(name)
        end
        return module('archive_browser').new{thread=love.thread,fs=love.filesystem,
            source=Loader.source('archive_browser_worker'),modules=modules,
            protocol_source=Loader.source('archive_browser'),
            json_source=assert(SMODS.NFS.read(SMODS.path..'libs/json/json.lua'))}
    end)
    if ok then
        API.archive_browser=value
        API.storage.on_browser_change=function(kind) value:invalidate(kind) end
    else API.archive_browser_error=tostring(value) end
end

local function complete_save(result)
    if not result then return end
    local request = save_requests[result.id]
    if not result.ok then
        API.retry_clock = 5
        if request then request.error = result.error end
        report(result.error or 'Cannot write worldline archive')
        return
    end
    -- A completed older generation must never acknowledge changes queued while
    -- its encoder/writer was running. Keep that latest tree strongly referenced.
    if request and request.ticket == result.ticket then
        save_requests[result.id], API.unsaved[result.id] = nil, nil
        if not next(API.unsaved) then API.last_error = nil end
        if request.manual and result.tree == API.tree and not API.dirty then
            API.status = API.text('世界线已保存', 'Worldline saved')
        end
    end
end

local function start_next_save()
    if API.storage:busy_save() or API.retry_clock > 0 then return end
    -- Preserve request order across runs; repeated requests for one run coalesce
    -- to its newest state without discarding an older run when a new one starts.
    local request
    for _, item in pairs(save_requests) do
        if not request or item.ticket < request.ticket then request = item end
    end
    if not request then return end
    local ok, started, err = pcall(API.storage.start_save, API.storage, request.tree, request.ticket)
    if not ok or not started then
        API.retry_clock = 5
        report(ok and err or started)
    end
end

local function queue_save(tree, manual)
    local id = tree.metadata.run_id
    save_ticket = save_ticket + 1
    local previous = save_requests[id]
    save_requests[id] = {tree = tree, ticket = save_ticket,
        manual = manual or previous and previous.manual or false}
    API.unsaved[id] = tree
    start_next_save()
    return true
end

function API.poll_saves()
    start_next_save()
    complete_save(API.storage:poll_save(0.00075))
end

function API.save_status(id)
    local request = save_requests[id]
    return request ~= nil, request and request.error
end

function API.flush_saves()
    -- Shutdown/export barrier only: ordinary gameplay and Undo never drain an
    -- archive on the calling frame. A failed write retains its tree for retry.
    API.retry_clock = 0
    while next(save_requests) or API.storage:busy_save() do
        start_next_save()
        if API.retry_clock > 0 then return nil, API.last_error end
        local result = API.storage:finish_save()
        if not result then return report('Worldline save did not complete') end
        complete_save(result)
        if not result.ok then return nil, API.last_error end
    end
    return true
end

function API.invalidate_snapshot()
    if Hooks.invalidate then Hooks.invalidate() end
end

function API.set_auto_create(value)
    local previous = mod.config.auto_create
    mod.config.auto_create = value == true
    if type(SMODS.save_mod_config) == 'function' then
        local ok, saved = pcall(SMODS.save_mod_config, mod)
        if not ok or saved == false then
            mod.config.auto_create = previous
            return report(API.text('无法保存模组设置', 'Cannot save mod settings'))
        end
    end
    return true
end

function API.recording_suspended()
    return G and G.STAGE == G.STAGES.RUN and G.GAME and G.GAME.worldline_recording_suspended == true or false
end

function API.use_feature(tree)
    tree = tree or API.tree
    local game = G and G.STAGE == G.STAGES.RUN and G.GAME
        and (not tree or tree == API.tree and API.game_ref == G.GAME) and G.GAME or nil
    local changed = Progress.lock(tree or game, game)
    if changed and tree == API.tree then API.dirty = true end
    return changed
end

local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, item in pairs(value) do result[key] = copy(item) end
    return result
end

local function equal(a, b, path, ignore_selection)
    path = path or ""
    if type(a) ~= type(b) then return false end
    if type(a) ~= "table" then return a == b end
    for key, value in pairs(a) do
        -- These identify the checkpoint, not a gameplay decision.
        local child_path = path .. tostring(key)
        if key ~= "worldline_run_id" and key ~= "worldline_node_id" and child_path ~= "extra.counters.ID"
            and child_path ~= "save.GAME.seeded" and not (ignore_selection and child_path == 'extra.selected') then
            if not equal(value, b[key], child_path .. ".", ignore_selection) then return false end
        end
    end
    for key in pairs(b) do
        if key ~= "worldline_run_id" and key ~= "worldline_node_id"
            and path .. tostring(key) ~= "extra.counters.ID" and path .. tostring(key) ~= "save.GAME.seeded"
            and not (ignore_selection and path .. tostring(key) == 'extra.selected')
            and a[key] == nil then return false end
    end
    return true
end

local id_counter = 0
local function new_id()
    while true do
        id_counter = id_counter + 1
        local micro = math.floor((love.timer.getTime() % 1) * 1000000)
        local id = os.date("!%Y%m%dT%H%M%SZ") .. "_" .. micro .. "_" .. id_counter
        local base = Storage.ROOT .. "/trees/" .. id
        if not love.filesystem.getInfo(base .. ".a.json") and not love.filesystem.getInfo(base .. ".b.json")
            and not love.filesystem.getInfo(base .. ".deleted.json")
            and not love.filesystem.getInfo(Storage.ROOT .. '/exports/' .. id .. '.worldline.json') then
            return id
        end
    end
end

local function state_name()
    for _, name in ipairs({"BLIND_SELECT", "SELECTING_HAND", "SHOP", "ROUND_EVAL",
        "SMODS_BOOSTER_OPENED", "TAROT_PACK", "PLANET_PACK", "SPECTRAL_PACK",
        "STANDARD_PACK", "BUFFOON_PACK", "GAME_OVER"}) do
        if G.STATE == G.STATES[name] then return name end
    end
    return tostring(G.STATE)
end

local function summary()
    local game, round = G.GAME, G.GAME.current_round or {}
    local jokers = {}
    for _, card in ipairs(G.jokers and G.jokers.cards or {}) do
        local center = card.config and card.config.center or {}
        local key = center.key or card.config and card.config.center_key or "j_joker"
        local name = center.name or card.label or key
        if type(localize) == "function" then
            local ok, localized = pcall(localize, {type = "name_text", set = "Joker", key = key})
            if ok and type(localized) == "string" then name = localized end
        end
        jokers[#jokers + 1] = {key = key, name = name, atlas = center.atlas or "Joker",
            pos = copy(center.pos or {x = 0, y = 0})}
    end
    local blind = game.blind or {}
    local blind_config = blind.config and blind.config.blind or {}
    local deck = game.selected_back or {}
    local deck_key = Tree.deck_key(game.selected_back_key) or Tree.deck_key(deck.effect and deck.effect.center)
    local deck_name, blind_name = deck.name or deck_key, blind.name or blind_config.name
    if type(deck.get_name) == 'function' then
        local ok, name = pcall(deck.get_name, deck)
        if ok and type(name) == 'string' then deck_name = name end
    elseif type(localize) == 'function' and deck_key then
        local ok, name = pcall(localize, {type = 'name_text', set = 'Back', key = deck_key})
        if ok and type(name) == 'string' then deck_name = name end
    end
    if type(localize) == 'function' and (blind_config.key or blind.key) then
        local ok, name = pcall(localize, {type = 'name_text', set = 'Blind', key = blind_config.key or blind.key})
        if ok and type(name) == 'string' then blind_name = name end
    end
    local result = {
        state = state_name(), ante = game.round_resets and game.round_resets.ante or 0,
        round = game.round or 0, dollars = game.dollars or 0, money = game.dollars or 0,
        hands_left = round.hands_left or 0, discards_left = round.discards_left or 0,
        joker_count = #jokers, jokers = jokers,
        deck = deck_key, deck_name = deck_name,
        stake = game.stake or 1, blind_key = blind_config.key or blind.key,
        blind_name = blind_name,
        hand_count = G.hand and #G.hand.cards or 0,
        deck_count = G.deck and #G.deck.cards or 0
    }
    -- Full inventories and deck statistics are already in the snapshot. Build
    -- them lazily for the selected node instead of on every gameplay action.
    return result
end

local detail_cache
function API.node_details(id)
    local node = API.tree and API.tree:get(tonumber(id))
    if not node then return nil end
    local locale = G and G.SETTINGS and G.SETTINGS.language
    if not detail_cache or detail_cache.node ~= node or detail_cache.locale ~= locale then
        detail_cache = {node = node, locale = locale,
            value = Details.from_snapshot(node.snapshot, node.summary)}
    end
    return detail_cache.value
end

function API.current_choices()
    return API.phase_choices
end

local comparison_cache
function API.compare_nodes(before_id, after_id)
    local before = API.tree and API.tree:get(tonumber(before_id))
    local after = API.tree and API.tree:get(tonumber(after_id))
    if not before or not after then return nil, API.text(nil, 'Choose two valid nodes') end
    local locale = G and G.SETTINGS and G.SETTINGS.language
    if not comparison_cache or comparison_cache.before ~= before or comparison_cache.after ~= after
        or comparison_cache.locale ~= locale or comparison_cache.a_snapshot ~= before.snapshot
        or comparison_cache.b_snapshot ~= after.snapshot then
        comparison_cache = {before = before, after = after, locale = locale,
            a_snapshot = before.snapshot, b_snapshot = after.snapshot, value = Diff.compare(before, after)}
    end
    return comparison_cache.value
end

local function mark(snapshot, tree, id)
    if snapshot and snapshot.save and snapshot.save.GAME then
        if tree == API.tree and API.private_worldline then
            snapshot.save.GAME.worldline_run_id, snapshot.save.GAME.worldline_node_id = nil, nil
        else
            snapshot.save.GAME.worldline_run_id = tree.metadata.run_id
            snapshot.save.GAME.worldline_node_id = id
        end
    end
end

local function mark_live()
    if API.tree and G.GAME then
        if API.private_worldline then
            G.GAME.worldline_run_id, G.GAME.worldline_node_id = nil, nil
        else
            G.GAME.worldline_run_id = API.tree.metadata.run_id
            G.GAME.worldline_node_id = API.tree.current
        end
    end
end

local capture_scope
function API.invalidate_input_boundary()
    if capture_scope then capture_scope={}end
end
local function capture(allow_overlay)
    if API.tree and API.game_ref == G.GAME then
        if Progress.apply_live(API, G.GAME) then API.dirty = true end
    end
    if capture_scope and capture_scope.game == G.GAME and capture_scope.snapshot
        and Snapshot.is_stable(allow_overlay) then return capture_scope.snapshot end
    local ok, snapshot, err = pcall(Snapshot.capture, allow_overlay)
    if not ok then return nil, tostring(snapshot) end
    if snapshot then
        if capture_scope then capture_scope.game, capture_scope.snapshot = G.GAME, snapshot end
    end
    return snapshot, err
end

function API.should_record()
    return API.tree ~= nil and not API.detached and not API.busy and not API.restoring
        and not Snapshot.restoring and G.STAGE == G.STAGES.RUN
        and API.game_ref == G.GAME
end

function API.is_input_boundary()
    return Snapshot.is_stable(false)
end

local function flush_pending(allow_overlay, supplied_snapshot)
    if not API.should_record() or not API.has_public_worldline() or #API.pending_actions == 0 then return false end
    if not Snapshot.is_stable(allow_overlay) then return false end
    local snapshot, err = supplied_snapshot, nil
    if not snapshot then snapshot, err = capture(allow_overlay) end
    if not snapshot then report("Checkpoint capture failed: " .. tostring(err)); return false, err end
    local current = API.tree:get(API.tree.current)
    if current and equal(current.snapshot, snapshot) then
        API.pending_actions = {}
        return false
    end
    local action
    if #API.pending_actions == 1 then action = API.pending_actions[1]
    else action = {kind = "sequence", label = API.text("连续操作", "Actions"),
        actions = API.pending_actions} end
    action.choices = API.phase_choices
    action.replay_schema = Choices.replay_complete(API.phase_choices) and 1 or nil
    mark(snapshot, API.tree, API.tree.next_id)
    local branched = current and #current.children > 0
    local ok, node, reused = pcall(API.tree.commit, API.tree, action, snapshot, summary(), Replay.matches)
    if not ok then return report(node) end
    API.pending_actions = {}
    API.phase_choices = {}
    API.tree.resume = nil
    API.phase_diverged, API.current_check_frame = false, nil
    API.live_summary = node.summary
    API.dirty = true
    API.status = reused and API.text('世界线收束', 'Worldline converged')
        or branched and API.text('世界线扰动', 'Worldline perturbed')
        or API.text('正在记录世界线', 'Recording worldline')
    mark_live()
    if Hooks.acknowledge then Hooks.acknowledge() end
    return true
end

local function refresh_session(allow_overlay, force, supplied_snapshot)
    if not API.should_record() or #API.pending_actions > 0 then return false end
    if not force and API.current_check_frame == API.frame_serial then return API.phase_diverged end
    if not Snapshot.is_stable(allow_overlay) then return nil, "transition" end
    local snapshot, err = supplied_snapshot, nil
    if not snapshot then snapshot, err = capture(allow_overlay) end
    if not snapshot then return nil, err end
    local node = API.tree:get(API.tree.current)
    local changed = node and (not equal(node.snapshot, snapshot) or #API.phase_choices > 0) or false
    API.phase_diverged, API.current_check_frame = changed, API.frame_serial
    API.live_summary = summary(snapshot)
    if changed then
        mark(snapshot, API.tree, API.tree.current)
        local old = API.tree.resume
        if not old or old.parent ~= API.tree.current or old.choices ~= API.phase_choices
            or not equal(old.snapshot, snapshot) then
            API.tree.resume = {parent = API.tree.current, snapshot = snapshot,
                summary = API.live_summary, choices = API.phase_choices}
            API.dirty = true
        end
    elseif API.tree.resume then
        API.tree.resume = nil
        API.dirty = true
    end
    if Hooks.acknowledge then Hooks.acknowledge() end
    return changed
end

function API.at_current_node()
    if not API.has_public_worldline() or not API.should_record() or #API.pending_actions > 0 then return false end
    local changed = refresh_session(true)
    return changed == false
end

function API.before_action()
    -- A milestone captures the completed phase, not its individual card inputs.
    if not API.should_record() or not Snapshot.is_stable(false) then return nil end
    local snapshot, err = capture(false)
    if not snapshot then report('Checkpoint capture failed: ' .. tostring(err)); return nil end
    flush_pending(false, snapshot)
    refresh_session(false, true, snapshot)
    return snapshot
end

function API.undo_prepare(action)
    if not API.should_record() then return nil end
    if not Snapshot.is_stable(false) then return nil end
    local snapshot = API.before_action()
    if not snapshot then return nil end
    return {tree = API.tree, checkpoint = API.tree:undo_checkpoint_view(), snapshot = snapshot,
        summary = API.live_summary or summary(snapshot), action = copy(action), private_worldline = API.private_worldline}
end

function API.describe_choice(action, event)
    return Choices.describe(action, event, API.text)
end

function API.undo_record_untracked(actions)
    for _, description in ipairs(actions or {}) do
        API.phase_choices = Choices.append(API.phase_choices, Choices.finish_untracked(description))
    end
end

local function finish_choice_log(choices, allow_overlay, after)
    local old_choices, old_resume = API.phase_choices, API.tree.resume
    local old_diverged, old_check, old_summary, old_dirty = API.phase_diverged,
        API.current_check_frame, API.live_summary, API.dirty
    API.phase_choices = choices
    local ok, err = pcall(refresh_session, allow_overlay, true, after)
    if not ok then
        -- Undo's error fallback records the inputs as incomplete. Roll back the
        -- in-memory append first so a failed refresh cannot duplicate them.
        API.phase_choices, API.tree.resume = old_choices, old_resume
        API.phase_diverged, API.current_check_frame = old_diverged, old_check
        API.live_summary, API.dirty = old_summary, old_dirty
        error(err, 0)
    end
end

function API.undo_finalize(entry, action, allow_overlay, observation)
    if entry and (entry.tree ~= API.tree or entry.checkpoint.run_id ~= API.tree.metadata.run_id) then return false end
    if not Snapshot.is_stable(allow_overlay) then return nil end
    local after, err = capture(allow_overlay)
    if not after then error('Cannot validate Undo: ' .. tostring(err)) end
    if not entry or observation and observation.incomplete then
        local choices = API.phase_choices
        for _, description in ipairs(observation and observation.actions or {action}) do
            choices = Choices.append(choices, Choices.finish_untracked(description))
        end
        finish_choice_log(choices, allow_overlay, after)
        return true
    end
    local changed = not equal(entry.snapshot, after, nil, true)
    local choices = API.phase_choices
    if changed then
        choices = Choices.append(choices,
            Choices.finish(action or entry.action, entry.snapshot, after))
    end
    -- Reuse the completed action snapshot as the in-phase resume checkpoint.
    -- The next idle observation/autosave should not serialize it again.
    finish_choice_log(choices, allow_overlay, after)
    -- Selection alone is not an irreversible operation. The full selection is
    -- still kept in the actual restore snapshot for a real play/discard.
    return changed
end

API.undo_error = report

local milestone_kinds = {select_blind = true, skip_blind = true, enter_shop = true,
    leave_shop = true, run_failed = true}
function API.record_action(action)
    if API.should_record() and API.has_public_worldline() and type(action) == "table" and milestone_kinds[action.kind] then
        API.pending_actions[#API.pending_actions + 1] = copy(action)
        API.current_check_frame = nil
    end
end

function API.save_now(allow_pending, preserve_status, observed)
    local allow_overlay = API.ui_view ~= nil or G.OVERLAY_MENU ~= nil
    Undo.update(API, allow_overlay)
    flush_pending(allow_overlay)
    if #API.pending_actions > 0 and not allow_pending then
        return report(API.text("请等待当前操作完成后保存", "Wait for the current action before saving"))
    end
    if not observed and API.should_record() and #API.pending_actions == 0 then
        local changed, reason = refresh_session(allow_overlay, true)
        if changed == nil and not allow_pending then
            return report(API.text("请等待当前操作完成后保存：", "Wait for the current action before saving: ") .. tostring(reason))
        end
    end
    if not API.tree then return report(API.text("当前没有世界线", "No worldline yet")) end
    -- An unpublished working root supports Undo only. It never enters local
    -- archives, export files or the native save's worldline attachment tags.
    if API.private_worldline then API.dirty, API.save_clock = false, 0; return true end
    queue_save(API.tree, not preserve_status)
    API.dirty, API.save_clock = false, 0
    return true
end

function API.before_open()
    if API.busy or Snapshot.restoring then API.open_when_ready = true; return false end
    if API.input_queue:count()>0 then
        API.open_when_ready=true
        API.undo_input_notice('Input queued; waiting for animation')
        if G.OVERLAY_MENU and G.FUNCS.exit_overlay_menu then G.FUNCS.exit_overlay_menu()end
        return false
    end
    if API.should_record() then
        if Snapshot.is_stable(true) then Undo.update(API, true); Hooks.poll(API); flush_pending(true) end
        if #API.pending_actions > 0 or not Snapshot.is_stable(true) then
            API.open_when_ready = true
            API.status = API.text("当前操作完成后打开世界线", "The worldline will open when this action finishes")
            -- Options may already have paused an in-flight animation. Let it
            -- settle, capture its result, then reopen the tree automatically.
            if G.OVERLAY_MENU and G.FUNCS.exit_overlay_menu then G.FUNCS.exit_overlay_menu() end
            return false
        end
        if API.private_worldline and API.auto_create_enabled() and not API.recording_suspended() then
            -- An explicit open after enabling the setting may still be inside
            -- the paused Mods/options menu. Capture that stable scene now,
            -- rather than waiting for an unpause behind the new viewer.
            if not new_tree(false, true) then return false end
        end
        refresh_session(true, true)
    end
    return true
end

function API.open()
    API.use_feature()
    if API.before_open() == false then return false end
    API.open_when_ready = nil
    return UI.open(API, true)
end

local function compatible(tree)
    local metadata = tree.metadata
    if metadata.pool_environment ~= nil and not PoolEnvironment.validate(metadata.pool_environment) then
        return nil, "Invalid worldline pool environment"
    end
    if metadata.game_version ~= G.VERSION then
        return nil, API.text("游戏版本不同，无法载入：", "Game version mismatch: ")
            .. tostring(metadata.game_version)
    end
    if metadata.tree_version ~= API.VERSION then
        return nil, API.text("世界线存档版本不兼容：", "Incompatible worldline archive version: ")
            .. tostring(metadata.tree_version) .. " → " .. API.VERSION
    end
    if metadata.smods_version ~= SMODS.version then
        return nil, API.text("Steamodded 版本不同", "Steamodded version mismatch")
    end
    return true
end

local function validate_tree(tree)
    local valid, err = compatible(tree)
    if not valid then return nil, err end
    for _, node in pairs(tree.nodes) do
        local ok, reason = Snapshot.validate(node.snapshot)
        if not ok then return nil, "Node " .. tostring(node.id) .. ": " .. tostring(reason) end
        if node.snapshot.seed ~= tree.metadata.seed then return nil, "Node seed mismatch" end
    end
    if tree.resume then
        if tree.resume.parent ~= tree.current or type(tree.resume.summary) ~= "table" then
            return nil, "Invalid unfinished phase"
        end
        local ok, reason = Snapshot.validate(tree.resume.snapshot)
        if not ok then return nil, "Unfinished phase: " .. tostring(reason) end
        if tree.resume.snapshot.seed ~= tree.metadata.seed then return nil, "Resume seed mismatch" end
    end
    return true
end

local function queue_restore(tree, id, use_resume, undo_entry)
    if API.busy or Snapshot.restoring then return report(API.text("正在恢复，请稍候", "Restoring; please wait")) end
    if API.should_record() then
        flush_pending(true)
        if #API.pending_actions > 0 or not Snapshot.is_stable(true) then
            return report(API.text("请等待当前操作完成后回退", "Wait for the current action before rewinding"))
        end
    end
    local valid, err = compatible(tree)
    if not valid then return report(err) end
    local node = tree:get(id)
    if not node then return report("Checkpoint not found") end
    local resume = use_resume and tree.resume and copy(tree.resume) or nil
    if resume and resume.parent ~= id then return report("Resume parent mismatch") end
    local target = undo_entry and copy(undo_entry.snapshot) or resume and copy(resume.snapshot) or tree:peek(id)
    Progress.apply_to_snapshot(target, tree)
    if resume then Progress.apply_to_snapshot(resume.snapshot, tree) end
    valid, err = Snapshot.validate(target)
    if not valid then return report(err) end
    if API.tree and API.dirty then
        local saved = API.save_now()
        if not saved then return nil, API.last_error end
    end
    API.pending_restore = {tree = tree, id = id, snapshot = target,
        resume = resume and copy(resume) or nil, undo = undo_entry,
        private_worldline = undo_entry and API.private_worldline == true or false,
        keep_branches = undo_entry ~= nil}
    API.busy, API.restoring = true, true
    API.status = undo_entry and API.text('正在撤回上一步…', 'Undoing last action…')
        or API.text("正在收束世界线…", "Converging worldline…")
    return true
end

function API.can_undo()
    if API.input_queue:count()>0 then return false,API.text(nil,'Input queued; waiting for animation')end
    local entry, action = Undo.peek()
    if not entry or entry.tree ~= API.tree then
        local boundary=Undo.boundary_reason()
        if boundary then return false,API.text(nil,boundary=='history_limit' and 'Undo history limit reached'
            or 'Undo history ends at an unrecorded action')end
        return false, API.text('没有可撤回的操作', 'No action to undo')
    end
    if API.busy or API.restoring or Snapshot.restoring or Undo.has_pending()
        or #API.pending_actions > 0 or not API.should_record() or not Snapshot.is_stable(true) then
        return false, API.text('请等待当前操作完成', 'Wait for the current action')
    end
    return true, nil, action and action.label
end

function API.undo_history_info()
    return {count = Undo.count(), limit = Undo.MAX_HISTORY, consecutive = Undo.consecutive_count(),
        continuous = API.tree and API.tree.metadata.continuous_undo == true or false}
end

local function confirmation_request()
    local entry = Undo.peek()
    if not entry or not API.tree or entry.tree ~= API.tree or API.tree.metadata.continuous_undo == true
        or Undo.consecutive_count() < 1 or G.GAME and G.GAME.seeded == true then
        undo_confirmation = nil
        return nil
    end
    local request = undo_confirmation
    if not request or request.entry ~= entry or request.tree ~= API.tree or request.game ~= G.GAME
        or request.revision ~= Undo.revision() then
        request = {token = {}, entry = entry, tree = API.tree, game = G.GAME, revision = Undo.revision()}
        undo_confirmation = request
    end
    return request
end

function API.requires_undo_confirmation()
    local request = confirmation_request()
    if not request or not API.can_undo() then return false end
    return true, request.token
end

function API.undo_confirmation_token()
    -- Native overlays temporarily lock input. Such a lock does not invalidate
    -- an unchanged request; only run/game/history identity changes do.
    local request = confirmation_request()
    return request and request.token or nil
end

local function enable_continuous_undo()
    API.tree.metadata.continuous_undo = true
    -- Deleting the active recording explicitly suspends public recording for
    -- this run. Undo remains usable but must not silently recreate an archive.
    if not API.recording_suspended() then API.private_worldline = false end
    API.use_feature(API.tree)
    -- Promote the existing working root. Never replace it with a snapshot taken
    -- after the first Undo or discard the session's remaining action history.
    local root = API.tree:get(API.tree.root)
    root.snapshot = copy(root.snapshot)
    mark(root.snapshot, API.tree, API.tree.root)
    if API.tree.resume then
        API.tree.resume = copy(API.tree.resume)
        mark(API.tree.resume.snapshot, API.tree, API.tree.current)
    end
    API.dirty = true
    undo_confirmation = nil
    mark_live()
    return true
end

function API.confirm_continuous_undo(token)
    local required, current_token = API.requires_undo_confirmation()
    if not token or not required or token ~= current_token then return nil, 'stale_confirmation' end
    return enable_continuous_undo()
end

function API.undo()
    local ready, reason = API.can_undo()
    if not ready then return report(reason) end
    if Undo.consecutive_count() >= 1 and not API.tree.metadata.continuous_undo
        and G.GAME and G.GAME.seeded == true then
        if not enable_continuous_undo() then return nil, API.last_error end
    end
    if API.requires_undo_confirmation() then return nil, 'confirm_required' end
    local entry = Undo.peek()
    return queue_restore(entry.tree, entry.checkpoint.current, false, entry)
end

function API.save_manual()
    API.use_feature()
    if not API.has_public_worldline() then
        return report(API.text('自动创建已关闭，当前没有世界线', 'Automatic creation is off; no current worldline'))
    end
    return API.save_now()
end

function API.request_restore(id)
    if not API.has_public_worldline() then return report(API.text('当前没有世界线', 'No worldline yet')) end
    API.use_feature()
    API.before_open()
    local ok, err = queue_restore(API.tree, tonumber(id))
    return ok, err
end

function API.presentation_rows()
    if not API.has_public_worldline() then return {} end
    return API.tree:visible_rows()
end

local function annotate(method, ...)
    if not API.has_public_worldline() then return report(API.text('当前没有世界线', 'No worldline yet')) end
    API.use_feature()
    local ok, value = pcall(API.tree[method], API.tree, ...)
    if not ok then return report(value) end
    if value ~= false then API.dirty = true end
    return value == false and true or value
end

function API.bookmark_rows(query)
    if not API.has_public_worldline() then return {} end
    local rows = API.tree:bookmark_rows()
    if type(query) ~= 'string' or query == '' then return rows end
    local matched = {}
    query = query:lower()
    for _, row in ipairs(rows) do
        if row.label:lower():find(query, 1, true) or tostring(row.id):find(query, 1, true) then
            matched[#matched + 1] = row
        end
    end
    return matched
end

function API.set_bookmark(id, name) return annotate('set_bookmark', tonumber(id), name) end
function API.remove_bookmark(id) return annotate('set_bookmark', tonumber(id), nil) end
function API.fold_rows() return API.has_public_worldline() and API.tree:fold_rows() or {} end
function API.fold_suworldline(id, name)
    return annotate('add_fold', tonumber(id), nil, name or API.text('折叠区域', 'Folded region'))
end
function API.fold_range(start_id, end_id, name)
    return annotate('add_fold', tonumber(start_id), tonumber(end_id), name or API.text('折叠区域', 'Folded region'))
end
function API.toggle_fold(id)
    id = tonumber(id)
    for _, fold in ipairs(API.fold_rows()) do
        if fold.id == id then return annotate('set_fold_collapsed', id, not fold.collapsed) end
    end
    return report(API.text('找不到折叠区域', 'Folded region not found'))
end
function API.remove_fold(id) return annotate('remove_fold', tonumber(id)) end
function API.reveal_node(id)
    if not API.has_public_worldline() then return false end
    API.use_feature()
    local ok, changed = pcall(API.tree.reveal_node, API.tree, tonumber(id))
    if not ok then return report(changed) end
    if changed then API.dirty = true end
    return changed
end

local function browser_rows(kind, poll_only, live)
    if API.archive_browser then
        if poll_only then return API.archive_browser:poll(kind) end
        return API.archive_browser:request(kind)
    end
    if API.archive_browser_error then return nil,API.archive_browser_error end
    -- Offline/custom filesystems have no thread runtime; retain their explicit
    -- synchronous implementation without introducing a game-side fallback.
    return API.storage[kind](API.storage,live)
end

function API.archive_rows(poll_only)
    API.use_feature()
    local live = {}
    for id, tree in pairs(API.unsaved) do live[id]=tree end
    if API.has_public_worldline() then live[API.tree.metadata.run_id]=API.tree end
    local ok, rows, err = pcall(browser_rows,'archives',poll_only,live)
    if not ok then return report(rows) end
    if not rows then if err=='loading' then return nil,err end; return report(err) end
    local found = {}
    for _, row in ipairs(rows) do found[row.id] = row end
    for id, tree in pairs(live) do
        local row = found[id]
        if not row then row = {id = id}; rows[#rows + 1] = row end
        row.seed, row.name, row.node_count = tree.metadata.seed, tree.metadata.name, tree:node_count()
        row.has_resume = tree.resume ~= nil
        row.created_at = tree.metadata.created_at or 0
        row.summary = tree.resume and tree.resume.summary or tree:get(tree.current).summary
        row.label = (API.unsaved[id] and '! ' or '') .. tostring(tree.metadata.name or tree.metadata.seed)
            .. ' / ' .. tree:node_count() .. ' / ' .. id:sub(-12)
            .. (API.unsaved[id] and API.text('（未写入）',' (unsaved)') or '')
    end
    table.sort(rows,function(a,b)
        local at,bt=a.created_at or 0,b.created_at or 0
        return at==bt and a.id>b.id or at>bt
    end)
    return rows
end

local management_serial, management_request = 0, nil
local function management_ready()
    if API.busy or Snapshot.restoring then return report(API.text('正在恢复，请稍候', 'Restoring; please wait')) end
    if API.should_record() and not Snapshot.is_stable(true) then
        return report(API.text('请等待当前操作完成', 'Wait for the current action'))
    end
    if API.has_public_worldline() and not API.save_now(true, true) then return nil, API.last_error end
    return API.flush_saves()
end

local function managed_archive(id)
    if API.has_public_worldline() and API.tree.metadata.run_id == id then return API.tree end
    if API.unsaved[id] then return API.unsaved[id] end
    return API.storage:load(id)
end

local function preview_token(kind, id, tree)
    management_serial = management_serial + 1
    management_request = {token = management_serial, kind = kind, id = id, tree = tree,
        live = tree == API.tree, generation = API.storage.generations[tree.metadata.run_id],
        current = tree.current, next_id = tree.next_id, resume = tree.resume,
        metadata = tree.metadata, structure = tree.structure_revision, annotations = tree.annotation_revision}
    return management_serial
end

local function confirm_management(kind, id, token)
    local request = management_request
    local function stale() return report(API.text(nil, 'Worldline changed; reopen this editor')) end
    if not request or request.kind ~= kind or request.id ~= id or request.token ~= token then return stale() end
    if not management_ready() then return nil, API.last_error end
    local tree = request.tree
    if request.live and API.tree ~= tree or tree.current ~= request.current or tree.next_id ~= request.next_id
        or tree.resume ~= request.resume or tree.metadata ~= request.metadata
        or tree.structure_revision ~= request.structure or tree.annotation_revision ~= request.annotations then return stale() end
    if not request.live then
        local disk = API.storage:load(tree.metadata.run_id)
        if not disk or API.storage.generations[tree.metadata.run_id] ~= request.generation then return stale() end
    end
    return tree
end

function API.rename_archive(id, name)
    API.use_feature()
    if not management_ready() then return nil, API.last_error end
    local tree, err = managed_archive(id)
    if not tree then return report(err) end
    API.use_feature(tree)
    local previous = tree.metadata
    local ok, changed = pcall(tree.set_name, tree, name)
    if not ok then return report(changed) end
    if changed == false then return true end
    local saved, save_err = API.storage:save(tree)
    if not saved then tree.metadata = previous; return report(save_err) end
    if tree == API.tree then API.dirty = false end
    management_request = nil
    API.status = API.text(nil, 'Worldline renamed')
    return true
end

function API.branch_delete_preview(id)
    API.use_feature()
    if not API.has_public_worldline() then return report(API.text('当前没有世界线', 'No worldline yet')) end
    if not management_ready() then return nil, API.last_error end
    id = tonumber(id)
    local ok, preview = pcall(API.tree.prune_preview, API.tree, id)
    if not ok then return report(preview) end
    if preview.allowed then preview.token = preview_token('branch', id, API.tree) end
    return preview
end

function API.delete_branch(id, token)
    id = tonumber(id)
    local tree, err = confirm_management('branch', id, token)
    if not tree then return nil, err end
    local preview = tree:prune_preview(id)
    if not preview.allowed then return report(preview.reason) end
    local backup, backup_err = API.storage:backup(tree, 'branch')
    if not backup then return report(backup_err) end
    -- Publish an edited tree only after it is durable. Failed encoding/writes
    -- leave both the live history and its existing generations recoverable.
    local edited, copy_err = Tree.import(tree:export())
    if not edited then return report(copy_err) end
    local ok, result = pcall(edited.prune_branch, edited, id)
    if not ok then return report(result) end
    local saved, save_err = API.storage:save(edited)
    if not saved then return report(save_err) end
    API.tree, API.dirty = edited, false
    API.phase_choices = edited.resume and edited.resume.choices or API.phase_choices
    API.current_check_frame = nil
    Undo.clear()
    management_request = nil
    mark_live()
    API.status = API.text(nil, 'Branch deleted; backup saved')
    return true, backup
end

function API.archive_delete_preview(id)
    API.use_feature()
    if not management_ready() then return nil, API.last_error end
    local tree, err = managed_archive(id)
    if not tree then return report(err) end
    return {count = tree:node_count(), label = tree.metadata.name or tree.metadata.seed,
        token = preview_token('archive', id, tree), current = tree == API.tree}
end

function API.delete_archive(id, token)
    local tree, err = confirm_management('archive', id, token)
    if not tree then return nil, err end
    local receipt, delete_err = API.storage:delete_archive(tree)
    if not receipt then return report(delete_err) end
    save_requests[id], API.unsaved[id] = nil, nil
    management_request = nil
    if API.tree == tree then
        local active = API.game_ref == G.GAME and G.STAGE == G.STAGES.RUN
        local pool = tree.metadata.pool_environment
        API.tree, API.game_ref, API.dirty = nil, nil, false
        API.phase_choices, API.pending_actions = {}, {}
        API.bootstrap_pending, API.attach_attempted = nil, nil
        Undo.clear()
        if active then
            -- Deleting a recording does not end the game or immediately create
            -- another public archive. Keep its gameplay pool and private Undo.
            G.GAME.worldline_recording_suspended = true
            G.GAME.worldline_suspended_pool = copy(pool)
            G.GAME.worldline_run_id, G.GAME.worldline_node_id = nil, nil
            Progress.lock(G.GAME)
            new_tree(true, true, pool)
        end
    end
    API.status = receipt.cleanup_warning or API.text(nil, 'Worldline deleted; backup saved')
    return true, receipt
end

function API.backup_rows(poll_only)
    API.use_feature()
    local ok, rows, err = pcall(browser_rows,'backups',poll_only)
    if not ok then return report(rows) end
    if not rows then if err=='loading' then return nil,err end; return report(err) end
    return rows
end

function API.restore_backup(id)
    API.use_feature()
    if not management_ready() then return nil, API.last_error end
    local tree, receipt = API.storage:load_backup(id)
    if not tree then return report(receipt) end
    local valid, reason = validate_tree(tree)
    if not valid then return report(reason) end
    tree.metadata.source_run_id = tree.metadata.run_id
    tree.metadata.restored_from_backup = id
    tree.metadata.run_id, tree.metadata.created_at = new_id(), os.time()
    API.use_feature(tree)
    for _, node in pairs(tree.nodes) do mark(node.snapshot, tree, node.id) end
    if tree.resume then mark(tree.resume.snapshot, tree, tree.current) end
    API.storage.generations[tree.metadata.run_id] = 0
    local saved, save_err = API.storage:save(tree)
    if not saved then return report(save_err) end
    API.status = API.text(nil, 'Backup restored as a new worldline')
    return tree.metadata.run_id
end

function API.export_branch(id)
    API.use_feature()
    if not API.has_public_worldline() then return report(API.text('当前没有世界线', 'No worldline yet')) end
    if not management_ready() then return nil, API.last_error end
    id = tonumber(id)
    local ok, payload = pcall(API.tree.export_branch, API.tree, id)
    if not ok then return report(payload) end
    local tree, err = Tree.import(payload)
    if not tree then return report(err) end
    tree.metadata.source_run_id, tree.metadata.source_node_id = API.tree.metadata.run_id, id
    tree.metadata.run_id, tree.metadata.created_at = new_id(), os.time()
    API.use_feature(tree)
    for _, node in pairs(tree.nodes) do mark(node.snapshot, tree, node.id) end
    if tree.resume then mark(tree.resume.snapshot, tree, tree.current) end
    local path, export_err = API.storage:export(tree)
    if not path then return report(export_err) end
    API.status = API.text('已导出到：', 'Exported to: ') .. path
    return path
end

function API.resume_recording()
    if not API.recording_suspended() or not Snapshot.is_stable(true) then
        return report(API.text('请等待当前操作完成', 'Wait for the current action'))
    end
    API.use_feature()
    local pool = G.GAME.worldline_suspended_pool
    G.GAME.worldline_recording_suspended, G.GAME.worldline_suspended_pool = nil, nil
    if not new_tree(false, true, pool) then
        G.GAME.worldline_recording_suspended, G.GAME.worldline_suspended_pool = true, pool
        return nil, API.last_error
    end
    return API.save_now(true, true)
end

function API.load_archive(id)
    API.use_feature()
    API.before_open()
    local tree = API.has_public_worldline() and API.tree.metadata.run_id == id and API.tree or API.unsaved[id]
    local err
    if not tree then tree, err = API.storage:load(id) end
    if not tree then return report(err) end
    local valid, reason = validate_tree(tree)
    if not valid then return report(reason) end
    API.use_feature(tree)
    local ok, reason = queue_restore(tree, tree.current, true)
    return ok, reason
end

function API.export_share()
    API.use_feature()
    if not API.has_public_worldline() then
        return report(API.text('自动创建已关闭，当前没有世界线', 'Automatic creation is off; no current worldline'))
    end
    if not API.save_now() then return nil, API.last_error end
    if not API.flush_saves() then return nil, API.last_error end
    local path, err = API.storage:export(API.tree)
    if not path then return report(err) end
    API.status = API.text("已导出到：", "Exported to: ") .. path
    return path
end

local function accept_import(tree)
    local valid, err = validate_tree(tree)
    if not valid then return report(err) end
    -- Import into a fresh namespace, so a shared branch cannot overwrite local history.
    tree.metadata.source_run_id = tree.metadata.run_id
    tree.metadata.run_id = new_id()
    API.storage.generations[tree.metadata.run_id] = 0
    tree.metadata.created_at = os.time()
    API.use_feature(tree)
    for _, node in pairs(tree.nodes) do mark(node.snapshot, tree, node.id) end
    if tree.resume then mark(tree.resume.snapshot, tree, tree.current) end
    local ok, reason = queue_restore(tree, tree.current, true)
    return ok, reason
end

function API.import_latest()
    API.use_feature()
    API.before_open()
    local tree, err = API.storage:import_latest()
    if not tree then return report(err) end
    return accept_import(tree)
end

function API.import_text(text)
    API.use_feature()
    API.before_open()
    local tree, err = API.storage:decode_share(text)
    if not tree then return report(err) end
    return accept_import(tree)
end

function API.open_data_folder()
    API.use_feature()
    local ok, err = API.storage:prepare()
    if not ok then return report(err) end
    local path = love.filesystem.getSaveDirectory():gsub("\\", "/") .. "/WorldLine"
    local uri_path = path:gsub("%%", "%%25"):gsub(" ", "%%20"):gsub("#", "%%23")
    return love.system.openURL("file:///" .. uri_path:gsub("^/+", ""))
end

new_tree = function(private_worldline, allow_overlay, pool_environment)
    local snapshot, err = capture(allow_overlay)
    if not snapshot then return report("Cannot start recording: " .. tostring(err)) end
    local metadata = {
        run_id = new_id(), seed = snapshot.seed, created_at = os.time(),
        game_version = G.VERSION, smods_version = SMODS.version,
        tree_version = API.VERSION, profile = tostring(G.SETTINGS.profile),
        deck = Tree.deck_key(G.GAME.selected_back_key)
            or Tree.deck_key(G.GAME.selected_back and G.GAME.selected_back.effect and G.GAME.selected_back.effect.center),
        stake = G.GAME.stake,
        pool_environment = copy(pool_environment or PoolEnvironment.capture(G.P_CENTERS))
    }
    API.tree = Tree.new(snapshot, metadata)
    API.phase_choices = {}
    API.storage.generations[metadata.run_id] = 0
    API.private_worldline = private_worldline == true
    Undo.clear()
    Progress.apply_live(API.tree, G.GAME)
    local root = API.tree:get(API.tree.root)
    root.action = {kind = "start", label = API.text("起点", "Start")}
    root.summary = summary(snapshot)
    mark(root.snapshot, API.tree, root.id)
    API.game_ref, API.detached = G.GAME, false
    API.pending_actions, API.dirty = {}, true
    API.phase_diverged, API.current_check_frame = false, nil
    API.live_summary = root.summary
    API.bootstrap_pending = nil
    API.last_error = nil
    API.status = API.private_worldline
        and API.text('世界线未创建；撤回仍可使用', 'No worldline created; Undo remains available')
        or API.text('正在记录世界线', 'Recording worldline')
    mark_live()
    Hooks.reset()
    if Hooks.acknowledge then Hooks.acknowledge() end
    return true
end

local function bootstrap()
    if G.STAGE ~= G.STAGES.RUN or not Snapshot.is_stable(false) then return end
    local id = G.GAME and G.GAME.worldline_run_id
    local deleted, marker
    if id then deleted, marker = API.storage:is_deleted(id) end
    if deleted then
        local archived = marker and API.storage:load_backup(marker.backup_id)
        G.GAME.worldline_recording_suspended = true
        G.GAME.worldline_suspended_pool = copy(archived and archived.metadata.pool_environment)
        G.GAME.worldline_run_id, G.GAME.worldline_node_id = nil, nil
        Progress.lock(G.GAME)
        id = nil
    end
    if id and not API.attach_attempted then
        API.attach_attempted = true
        local tree = API.unsaved[id] or API.storage:load(id)
        if tree and tree.metadata.seed == G.GAME.pseudorandom.seed and compatible(tree) then
            -- A native continue save may be newer than the Tree file (for
            -- example after a failed tree write). Never downgrade seeded=true.
            if G.GAME.seeded == true then Progress.lock(tree, G.GAME) end
            API.bootstrap_pending = nil
            queue_restore(tree, tree.current, true)
            return
        end
    end
    new_tree(API.recording_suspended() or not API.auto_create_enabled(), nil, G.GAME.worldline_suspended_pool)
end

local function begin_restore()
    local job = API.pending_restore
    if not job then return end
    API.pending_restore = nil
    API.restore_job = job
    API.pending_actions = {}
    if UI.close then UI.close(API, true) end
    if G.OVERLAY_MENU and G.FUNCS.exit_overlay_menu then G.FUNCS.exit_overlay_menu() end
    local ok, started, err = pcall(Snapshot.restore, job.snapshot)
    if not ok or not started then
        API.busy, API.restoring, API.restore_job = false, false, nil
        return report(ok and err or started)
    end
end

local function update(dt)
    if API.file_picker then API.file_picker:update() end
    if API.film_runtime and API.film_runtime.active then
        if API.film_runtime.background and UI.update then UI.update(API,dt) end
        local ok,err=pcall(API.film_runtime.update,API.film_runtime)
        if not ok then API.film_runtime:fail(err) end
        return
    end
    update_brand()
    if UI.update then UI.update(API, dt) end
    API.frame_serial = API.frame_serial + 1
    API.retry_clock = math.max(0, API.retry_clock - dt)
    if Snapshot.restoring then
        local ok, finished, err = pcall(Snapshot.update)
        if not ok and Snapshot.abort then
            local recovered, _, recovery_error = pcall(Snapshot.abort, finished)
            if recovered and Snapshot.restoring then return end
            err = recovery_error or finished
        end
        if not ok or err then
            API.busy, API.restoring = false, false
            API.restore_job = nil
            -- The adapter may have rebuilt the previous scene as a rollback.
            -- Reattach it without silently starting another restore loop.
            if API.tree and G.STAGE == G.STAGES.RUN and G.GAME
                and (API.private_worldline and G.GAME.worldline_run_id == nil
                    or G.GAME.worldline_run_id == API.tree.metadata.run_id and G.GAME.worldline_node_id == API.tree.current)
                and G.GAME.pseudorandom and G.GAME.pseudorandom.seed == API.tree.metadata.seed then
                API.game_ref = G.GAME
                mark_live()
            else
                API.tree, API.game_ref = nil, nil
            end
            API.pending_actions = {}
            API.current_check_frame = nil
            Hooks.reset()
            return report(ok and err or finished)
        end
        if finished then
            local job = API.restore_job
            if not job then return report("Missing restore job") end
            API.tree = job.tree
            API.private_worldline = job.private_worldline == true
            if job.undo then
                -- Undo restores one gameplay action and its phase cursor. All
                -- visited futures and their annotations remain navigable.
                API.tree:restore_cursor(job.undo.checkpoint)
                Undo.consume(job.undo)
            else
                API.tree:checkout(job.id)
                API.tree.resume = job.resume
                Undo.clear()
            end
            API.phase_choices = API.tree.resume and API.tree.resume.choices or {}
            Progress.apply_live(API, G.GAME)
            API.phase_diverged = API.tree.resume ~= nil
            API.current_check_frame = nil
            API.live_summary = job.undo and job.undo.summary or job.resume and job.resume.summary or API.tree:get(job.id).summary
            API.game_ref, API.detached = G.GAME, false
            API.busy, API.restoring, API.restore_job = false, false, nil
            API.bootstrap_pending, API.attach_attempted = nil, nil
            API.pending_actions, API.dirty = {}, true
            API.last_error = nil
            API.status = job.undo and API.text('已撤回刚才的操作', 'Last action undone')
                or API.text('世界线收束', 'Worldline converged')
            mark_live()
            Hooks.reset()
            if Hooks.acknowledge then Hooks.acknowledge() end
            API.save_now(false, true, true)
            if API.open_when_ready then API.open() end
        end
        return
    end
    if API.busy then return end
    if API.tree and API.game_ref == G.GAME and Progress.apply_live(API, G.GAME) then API.dirty = true end
    API.detached = API.tree ~= nil and (G.STAGE ~= G.STAGES.RUN or API.game_ref ~= G.GAME)
    if G.STAGE == G.STAGES.RUN and API.game_ref ~= G.GAME then
        API.bootstrap_pending = true
    end
    if API.bootstrap_pending then bootstrap(); return end
    if API.should_record() and API.private_worldline and API.auto_create_enabled()
        and not API.recording_suspended() and Snapshot.is_stable(false) then
        -- Enabling automatic creation can start this currently unrecorded run.
        -- Existing public worldlines are never deleted by the opposite toggle.
        new_tree(false)
        return
    end
    -- Settle the action log before committing its destination phase, so choices
    -- describe the incoming edge rather than leaking into the following phase.
    Undo.update(API, API.ui_view ~= nil or G.OVERLAY_MENU ~= nil)
    if API.should_record() and Snapshot.is_stable(false) then
        local observation_needed = Hooks.poll(API)
        if API.has_public_worldline() and G.STATE == G.STATES.GAME_OVER
            and (API.tree:get(API.tree.current).snapshot.extra or {}).state ~= "GAME_OVER"
            and #API.pending_actions == 0 then
            API.record_action({kind = "run_failed", label = API.text("本分支失败", "Branch ended")})
        end
        flush_pending()
        API.observe_clock = API.observe_clock + dt
        if API.has_public_worldline() and #API.pending_actions == 0 and API.observe_clock >= 0.25 then
            if observation_needed then refresh_session(false, true) end
            API.observe_clock = 0
        end
    end
    if API.dirty and API.has_public_worldline() then
        API.save_clock = API.save_clock + dt
        if API.save_clock >= 0.5 and API.retry_clock == 0 then
            -- Normal observation/Undo already captured the completed state. Do
            -- not create another full snapshot just because a save is due.
            if not API.save_now(true, true, true) then API.retry_clock = 5 end
        end
    end
    if API.input_queue:count()>0 and not Undo.has_pending() and API.input_queue:update()then return end
    if API.open_when_ready and API.input_queue:count()==0
        and (G.STAGE ~= G.STAGES.RUN or Snapshot.is_stable(false)) then API.open() end
end

function API.film_active() return API.film_runtime and API.film_runtime.active or false end
function API.film_plan(first,last)
    local ok,value=pcall(Film.plan,API.tree,first,last,API.film_options())
    if not ok then
        local message=tostring(value):gsub('^.-:%d+: ','')
        if message:find('legacy',1,true) or message:find('incomplete',1,true) then
            message=API.text(nil,'This route has incomplete action records')
        elseif message=='Recording end must descend from its start' then message=API.text(nil,message) end
        return nil,message
    end
    return value
end
function API.start_film(first,last)
    if API.busy or API.restoring or API.film_active() then return nil,'Worldline is busy' end
    local plan,err=API.film_plan(first,last);if not plan then return nil,err end
    if API.game_ref~=G.GAME or not Snapshot.is_stable(true) then return nil,API.text(nil,'Start or load a run before recording') end
    API.use_feature()
    local runtime=FilmHost.new(API,function(success,reason,path,cancelled)
        Hooks.reset();API.current_check_frame=nil;API.invalidate_snapshot()
        API.status=success and (API.text(nil,'Video saved')..': '..path)
            or cancelled and API.text(nil,'Recording cancelled') or tostring(reason)
        API.last_error=not success and not cancelled and tostring(reason) or nil
        UI.open(API,true)
    end)
    local started,path=pcall(runtime.start,runtime,plan,mod)
    if not started then return nil,path end
    API.film_runtime=runtime
    UI.film_progress(API)
    return path
end

function API.update(dt)
    -- Native Game.update has already finished. All observations in this pass
    -- describe the same boundary: share its snapshot between phase recording,
    -- Undo validation and autosave, then discard the cache before more input.
    local previous = capture_scope
    capture_scope = {}
    local ok, err = pcall(update, dt)
    if ok then ok, err = pcall(API.poll_saves) end
    capture_scope = previous
    if not ok then error(err, 0) end
end

Hooks.install(API)
if Snapshot.install_cashout_capture then Snapshot.install_cashout_capture(API.text) end
Undo.install(API)
UI.install(API)
PoolEnvironment.install(function()
    if API.film_active() and API.tree then return API.tree.metadata.pool_environment end
    -- Reconstruction must use the destination's root conditions too. A failed
    -- restoration keeps the previous tree active; no global profile is changed.
    local job = API.restore_job
    if job and Snapshot.restoring then return job.tree.metadata.pool_environment end
    if API.tree and API.game_ref == G.GAME and G.STAGE == G.STAGES.RUN then
        return API.tree.metadata.pool_environment
    end
    if API.recording_suspended() and PoolEnvironment.validate(G.GAME.worldline_suspended_pool) then
        return G.GAME.worldline_suspended_pool
    end
end)

local native_draw=love.draw
love.draw=function(...)
    if native_draw then native_draw(...) end
    if API.film_active() then
        local ok,err=pcall(API.film_runtime.capture,API.film_runtime)
        if not ok then API.film_runtime:fail(err) end
    end
end
local native_key=love.keypressed
love.keypressed=function(key,...)
    if API.film_active() then if key=='escape' then API.film_runtime:cancel() end;return end
    if native_key then return native_key(key,...) end
end
for _,name in ipairs({'mousepressed','mousereleased','mousemoved','wheelmoved','gamepadpressed',
    'gamepadreleased','joystickpressed','textinput','textedited'}) do
    local native=love[name]
    love[name]=function(...)
        if native and (not API.film_active() or API.film_runtime.background) then return native(...) end
    end
end

-- Lovely calls this while the game's scene Canvas is active, before the cursor
-- and native screen shaders. Keep one path for all tree drawing.
function API.draw_native(game)
    if API.film_runtime and API.film_runtime.active and not API.film_runtime.background then return false end
    return UI.draw_native(API, game)
end

function API.draw_before_overlay(game)
    return UI.draw_before_overlay(API, game)
end

local original_update = Game.update
function Game:update(dt, ...)
    local film=API.film_runtime
    if film and film.active then
        local ok,advance,fixed=pcall(film.before_update,film)
        if not ok then film:fail(advance);return end
        if not advance then return end
        dt=fixed or dt
    end
    -- Perform destructive state replacement before entering the old frame's event queue.
    if API.pending_restore then begin_restore() end
    local result
    if film and film.active then
        local ok,err=pcall(original_update,self,dt,...)
        if not ok then film:fail(err);return end
    else result=original_update(self, dt, ...) end
    local ok, err = pcall(API.update, dt)
    if not ok then report(err) end
    return result
end

local original_start = Game.start_run
function Game:start_run(args, ...)
    if not API.restoring then
        if API.tree then API.save_now(true) end
        Undo.clear()
        API.tree, API.game_ref = nil, nil
        API.phase_choices = {}
        API.private_worldline = false
        API.pending_actions = {}
        API.phase_diverged, API.current_check_frame = false, nil
        API.bootstrap_pending, API.attach_attempted = true, nil
        Hooks.reset()
    end
    return original_start(self, args, ...)
end

-- The UI callbacks delete the old scene before invoking Game:start_run.
-- Save the unfinished phase while its live objects still exist.
for _, name in ipairs({"start_run", "go_to_menu"}) do
    local original = G.FUNCS[name]
    if type(original) == "function" then
        G.FUNCS[name] = function(...)
            if API.tree and not API.busy then API.save_now(true) end
            return original(...)
        end
    end
end

local original_quit = love.quit
function love.quit(...)
    if API.film_runtime and API.film_runtime.active then API.film_runtime:cancel();return true end
    if API.tree and not API.busy then API.save_now(true) end
    -- Refuse a normal exit on a failed final write; the last good alternating
    -- generation and the newest in-memory history both remain available.
    if not API.flush_saves() then return true end
    -- Native quit shuts down audio/Steam immediately. Never invoke it before a
    -- write failure can still cancel exit and leave the game usable.
    local result
    if original_quit then result = original_quit(...) end
    if result then return result end
    if API.storage.stop_writer then API.storage:stop_writer() end
    if API.archive_browser then API.archive_browser:stop() end
    return result
end

local original_drop = love.filedropped
function love.filedropped(file)
    local filename = file:getFilename()
    if not filename:lower():match("%.worldline%.json$") then
        if original_drop then return original_drop(file) end
        return
    end
    if file:getSize() > Storage.MAX_BYTES then report("Tree file exceeds 128 MiB"); return end
    local opened, err = file:open("r")
    if not opened then report(err); return end
    local text = file:read(Storage.MAX_BYTES + 1)
    file:close()
    if text then API.import_text(text) else report("Cannot read shared worldline") end
end

mod.config_tab = function()
    return {n = G.UIT.ROOT, config = {align = "cm", colour = G.C.CLEAR, padding = 0.2}, nodes = {
        create_toggle({label = API.text('自动创建世界线', 'Automatically create worldlines'),
            ref_table = mod.config, ref_value = 'auto_create', callback = API.set_auto_create,
            label_scale = 0.35, w = 4.5,
            info = {API.text('仅影响尚未创建世界线的游戏', 'Affects runs without an existing worldline')}}),
        UIBox_button({label = {API.text("世界线（F6）", "Worldline (F6)")},
            button = "worldline_open", minw = 4, minh = 0.7}),
        {n = G.UIT.R, config = {align = "cm"}, nodes = {
            {n = G.UIT.T, config = {text = API.text("原版非种子随机沿用原行为", "Unseeded events retain vanilla behavior"),
                scale = 0.3, colour = G.C.UI.TEXT_LIGHT}}
        }}
    }}
end

sendInfoMessage((API.text('世界线 0.2.0 已加载；F6 打开世界线', 'Worldline 0.2.0 loaded; F6 opens the worldline')
    :gsub('0%.2%.0', API.CODE_VERSION)), 'WorldLine')
return API

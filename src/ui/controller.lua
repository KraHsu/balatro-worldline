-- Native LÖVE graph overlay. Archive selection retains the game's menu widgets.
local Loader
if SMODS and SMODS.load_file then
    Loader = assert(SMODS.load_file('loader.lua', 'WorldLine'))()
else
    Loader = dofile('src/loader.lua')
end
local module = Loader.load
local Graph, Renderer, Selection = module('graph'), module('renderer'), module('selection')
local UI = {PAGE_SIZE = 4}
local state = {active = false, selected = nil, hover = nil, notice = nil, archive_page = 1,
    selections = {}, selection_order = {}, selection_revision = 0,
    detail_tab = 'overview', detail_scroll = 0,
    transition = 0, transition_target = 0, consumed_buttons = {}}
UI.state = state
local installed = false
local fallback_clock = 0
local end_editor

local function now()
    if love.timer and type(love.timer.getTime) == 'function' then return love.timer.getTime() end
    return fallback_clock
end

local function text(ctx, zh, en) return ctx.text and ctx.text(zh, en) or en end
local function public_tree(ctx)
    if type(ctx.has_public_worldline) == 'function' then
        if not ctx.has_public_worldline() then return nil end
    elseif ctx.has_public_worldline == false then return nil end
    return ctx.tree
end

local function clipped(value, limit)
    local result, count = {}, 0
    for char in tostring(value or ''):gsub('[\r\n\t]', ' '):gmatch('[%z\1-\127\194-\244][\128-\191]*') do
        count = count + 1
        if count > limit then return table.concat(result) .. '...' end
        result[#result + 1] = char
    end
    return table.concat(result)
end

local function line(value, size, colour)
    return {n = G.UIT.R, config = {align = 'cm', padding = 0.04}, nodes = {
        {n = G.UIT.T, config = {text = tostring(value), scale = size or 0.34, colour = colour or G.C.UI.TEXT_LIGHT}}
    }}
end

local function button(label, name, data, width, check, colour)
    return UIBox_button {label = {label}, button = name, ref_table = data,
        minw = width or 8, minh = 0.6, scale = 0.34, colour = colour or G.C.BLUE, func = check}
end

local function side_button(...)
    local node = button(...)
    -- Native layout uses each child's node type, not its parent's, to choose
    -- horizontal versus vertical flow. UIBox_button defaults to a row.
    node.n = G.UIT.C
    return node
end

local function report(ctx, value, err, success)
    if value == nil or value == false then
        state.notice = tostring(err or ctx.last_error or text(ctx, '操作未完成', 'Operation could not complete'))
    else
        state.notice = success or text(ctx, '已完成', 'Done')
        if type(value) == 'string' then state.notice = state.notice .. ': ' .. value end
    end
end

local function same_run(ctx, pending)
    if pending.game ~= G.GAME or pending.tree ~= ctx.tree
        or pending.run_id ~= (ctx.tree and ctx.tree.metadata and ctx.tree.metadata.run_id) then return false end
    return true
end

local function same_confirmation(ctx, pending)
    if not same_run(ctx, pending) then return false end
    if type(ctx.undo_confirmation_token) == 'function' then
        local ok, token = pcall(ctx.undo_confirmation_token)
        if not ok or token ~= pending.token then return false end
    end
    return true
end

local function attach_previous_overlay(pending)
    local overlay = pending.previous_overlay
    if not overlay or overlay.REMOVED then return nil end
    if overlay.states then overlay.states.visible = pending.previous_visible end
    local boxes = G.I and G.I.UIBOX
    if boxes and pending.previous_index then
        table.insert(boxes, math.min(pending.previous_index, #boxes + 1), overlay)
    end
    return overlay
end

-- Native overlay_menu normally destroys its predecessor. Temporarily detach
-- Options instead, so cancellation restores its exact tab, widgets and pause.
local function dismiss_confirmation(ctx, restore_origin)
    local pending = state.undo_confirmation
    if not pending then return false end
    state.undo_confirmation = nil
    local owns_overlay = G.OVERLAY_MENU == pending.overlay
    if pending.overlay and not pending.overlay.REMOVED and pending.overlay.remove then pending.overlay:remove() end
    if owns_overlay then G.OVERLAY_MENU = nil end
    if restore_origin and owns_overlay then
        G.OVERLAY_MENU = attach_previous_overlay(pending)
        G.SETTINGS.paused = pending.previous_pause
        ctx.ui_view = pending.previous_view
    else
        local previous = pending.previous_overlay
        if previous and not previous.REMOVED and previous.remove then previous:remove() end
        if owns_overlay then G.SETTINGS.paused = false end
        state.active, state.drag, state.hover, state.selection_box = false, nil, nil, nil
        state.transition, state.transition_target = 0, 0
        if ctx.ui_view == 'tree' or ctx.ui_view == 'undo_confirmation' then ctx.ui_view = nil end
    end
    local controller = G.CONTROLLER
    if controller and controller.mod_cursor_context_layer and controller.cursor_context
        and pending.cursor_layer and controller.cursor_context.layer > pending.cursor_layer then
        controller:mod_cursor_context_layer(-1)
    end
    return true
end

function UI.cancel_undo_confirmation(ctx)
    local pending = state.undo_confirmation
    return pending and dismiss_confirmation(ctx, same_run(ctx, pending)) or false
end

local function confirmation_live(ctx)
    local pending = state.undo_confirmation
    if not pending then return false end
    local same = same_confirmation(ctx, pending)
    if not same or now() >= pending.deadline or ctx.busy or ctx.restoring
        or (G.CONTROLLER and G.CONTROLLER.text_input_hook) or G.OVERLAY_MENU ~= pending.overlay then
        dismiss_confirmation(ctx, same_run(ctx, pending) and not ctx.busy and not ctx.restoring)
        return false
    end
    return true
end

local function paragraph(contents, value)
    -- Native UI text does not wrap. Keep whole words where possible and count
    -- CJK glyphs as two columns, so every native locale fits the same dialog.
    local chars, width, space = {}, 0, nil
    local function flush(last)
        contents[#contents + 1] = line(table.concat(chars, '', 1, last or #chars):gsub('%s+$', ''), 0.3)
        local rest = {}
        for i = (last or #chars) + 1, #chars do rest[#rest + 1] = chars[i] end
        chars, width, space = rest, 0, nil
        for i, char in ipairs(chars) do width = width + (#char >= 3 and 2 or 1); if char == ' ' then space = i end end
    end
    for char in value:gmatch('[%z\1-\127\194-\244][\128-\191]*') do
        local size = #char >= 3 and 2 or 1
        if width + size > 64 then flush(space or #chars) end
        if #chars > 0 or char ~= ' ' then
            chars[#chars + 1], width = char, width + size
            if char == ' ' then space = #chars end
        end
    end
    if #chars > 0 then flush() end
end

local function show_confirmation(ctx, token, source)
    local contents = {line(text(ctx, '继续撤回？', 'Continue undoing?'), 0.45)}
    paragraph(contents, text(ctx, '如果继续撤回，本局将按固定种子局处理，后续无法获得成就或新发现。',
        'Continuing Undo makes this a seeded run. Achievements and new discoveries will be disabled.'))
    paragraph(contents, text(ctx, '已有世界线会保留，改变选择可产生新的扰动。',
        'Existing worldlines stay intact. Different choices can create new perturbations.'))
    paragraph(contents, text(ctx, '2秒内再次按 Ctrl+Z 确认，Esc 取消。',
        'Press Ctrl+Z again within 2 seconds to confirm, or Esc to cancel.'))
    contents[#contents + 1] = button(text(ctx, '继续撤回', 'Continue Undo'), 'worldline_confirm_continuous_undo', nil, 8)
    local pending = {token = token, deadline = now() + 2, source = source,
        game = G.GAME, tree = ctx.tree, run_id = ctx.tree and ctx.tree.metadata and ctx.tree.metadata.run_id,
        previous_pause = G.SETTINGS.paused == true, previous_view = ctx.ui_view,
        previous_overlay = G.OVERLAY_MENU,
        cursor_layer = G.CONTROLLER and G.CONTROLLER.cursor_context and G.CONTROLLER.cursor_context.layer}
    local previous, boxes = pending.previous_overlay, G.I and G.I.UIBOX
    if previous then
        if previous.states then pending.previous_visible = previous.states.visible; previous.states.visible = false end
        if boxes then
            for index, overlay in ipairs(boxes) do
                if overlay == previous then pending.previous_index = index; table.remove(boxes, index); break end
            end
        end
    end
    G.OVERLAY_MENU = nil
    state.drag, state.hover, state.selection_box, state.undo_confirmation = nil, nil, nil, pending
    ctx.ui_view, G.SETTINGS.paused = 'undo_confirmation', true
    local ok, err = pcall(G.FUNCS.overlay_menu, {config = {no_esc = true}, definition = create_UIBox_generic_options {
        contents = {{n = G.UIT.C, config = {align = 'cm', padding = 0.08}, nodes = contents}},
        back_func = 'worldline_cancel_continuous_undo', back_label = text(ctx, '取消', 'Cancel'), minw = 10.5
    }})
    pending.overlay = G.OVERLAY_MENU
    if not ok then dismiss_confirmation(ctx, true); report(ctx, nil, err); return nil, err end
    return nil, 'confirm_required'
end

function UI.can_undo(ctx)
    if ctx.busy or ctx.restoring then
        return false, text(ctx, '请等待当前操作完成', 'Wait for the current action to finish')
    end
    if G.CONTROLLER and G.CONTROLLER.text_input_hook then
        return false, text(ctx, '请先结束文本输入', 'Finish text input first')
    end
    if type(ctx.can_undo) ~= 'function' or type(ctx.undo) ~= 'function' then
        return false, text(ctx, '还没有可以撤回的操作', 'There is no action to undo yet')
    end
    local ok, allowed, reason, label = pcall(ctx.can_undo)
    if not ok then return false, tostring(allowed) end
    return allowed == true, reason, label
end

-- Undo deliberately goes straight to the runtime API. Opening the tree has a
-- separate progress-lock policy and must never become a prerequisite for undo.
function UI.undo(ctx, source)
    ctx.last_undo_source = source
    if confirmation_live(ctx) then return UI.confirm_continuous_undo(ctx) end
    local available, reason, label = UI.can_undo(ctx)
    if not available then
        reason = reason or text(ctx, '还没有可以撤回的操作', 'There is no action to undo yet')
        state.notice, ctx.status = reason, reason
        if ctx.undo_input_notice then ctx.undo_input_notice(reason)end
        return nil, reason
    end
    if type(ctx.requires_undo_confirmation) == 'function' then
        local ok, required, token = pcall(ctx.requires_undo_confirmation)
        if not ok then report(ctx, nil, required); return nil, required end
        if required then return show_confirmation(ctx, token, source) end
    end
    local ok, value, err = pcall(ctx.undo)
    if not ok then err, value = value, nil end
    report(ctx, value, err, label and text(ctx, '正在撤回：', 'Undoing: ') .. label
        or text(ctx, '正在撤回上一步', 'Undoing the last action'))
    ctx.status = state.notice
    if value then
        UI.close(ctx, true)
        if G.OVERLAY_MENU and G.FUNCS.exit_overlay_menu then G.FUNCS.exit_overlay_menu() end
    end
    return value, err
end

function UI.confirm_continuous_undo(ctx)
    if not confirmation_live(ctx) then return nil, 'stale_confirmation' end
    local pending = state.undo_confirmation
    local available, reason = UI.can_undo(ctx)
    if not available then report(ctx, nil, reason); return nil, reason end
    if type(ctx.confirm_continuous_undo) ~= 'function' then return nil, 'stale_confirmation' end
    dismiss_confirmation(ctx, true)
    local ok, confirmed, err = pcall(ctx.confirm_continuous_undo, pending.token)
    if not ok then err, confirmed = confirmed, nil end
    if not confirmed then
        if err ~= 'stale_confirmation' then report(ctx, nil, err) end
        return nil, err
    end
    return UI.undo(ctx, pending.source)
end

local function finish_close(ctx)
    if state.active then G.SETTINGS.paused = state.previous_pause == true end
    state.active, state.drag, state.hover, state.selection_box = false, nil, nil, nil
    state.transition, state.transition_target = 0, 0
    if ctx.ui_view == 'tree' then ctx.ui_view = nil end
end

local function finish_modal(ctx)
    local modal = state.modal
    if not modal then return false end
    state.modal, state.native_overlay = nil, false
    state.archive_wait = nil
    state.management_confirm, state.manage_return, state.settings_form = nil, nil, nil
    if end_editor then end_editor() end
    local overlay = modal.overlay
    if G.OVERLAY_MENU == overlay then G.OVERLAY_MENU = nil end
    if overlay and not overlay.REMOVED and overlay.remove then overlay:remove() end
    local controller = G.CONTROLLER
    if controller then
        if controller.cursor_down then controller.cursor_down.target = nil end
        if controller.clicked then controller.clicked.target = nil end
        if controller.locks then controller.locks.frame_set, controller.locks.frame = true, true end
        if controller.cursor_context and controller.mod_cursor_context_layer and modal.cursor_layer then
            while controller.cursor_context.layer > modal.cursor_layer do controller:mod_cursor_context_layer(-1) end
        end
    end
    ctx.ui_view = state.active and 'tree' or nil
    if state.active then G.SETTINGS.paused = true end
    return true
end

function UI.close_modal(ctx, immediate)
    local modal = state.modal
    if not modal then return false end
    if immediate then return finish_modal(ctx) end
    if modal.closing then return true end
    modal.closing, modal.elapsed = true, 0
    state.archive_wait = nil
    state.management_confirm, state.manage_return = nil, nil
    if end_editor then end_editor() end
    local overlay = modal.overlay
    if overlay and overlay.alignment and overlay.alignment.offset then
        overlay.alignment.offset.y = 10 -- Reverse the native overlay_menu entrance.
        if overlay.align_to_major then overlay:align_to_major() end
    end
    return true
end

function UI.close(ctx, immediate)
    UI.cancel_undo_confirmation(ctx)
    if state.modal then finish_modal(ctx) end
    state.archive_wait = nil
    state.drag, state.hover, state.selection_box = nil, nil, nil
    if immediate or not state.active then finish_close(ctx); return end
    state.transition_target = 0
end

function UI.update(ctx, dt)
    if state.film_progress and ctx.film_runtime and ctx.film_runtime.active then
        local runtime,info=ctx.film_runtime,state.film_progress
        local phases={preparing='Preparing video renderer',starting='Starting video renderer',rendering='Rendering video',
            encoding='Encoding video',cancelling='Cancelling export'}
        info.phase=text(ctx,nil,phases[runtime.phase] or 'Preparing video renderer')
        info.percent=tostring(math.floor(math.min(0.99,runtime.progress or 0)*100))..'%'
        info.counts=string.format('%d / %d',runtime.completed or 0,runtime.total or 0)..' '..text(ctx,nil,'Recorded actions')
            ..'  |  '..text(ctx,nil,'Video time')..' '..string.format('%02d:%02d',
                math.floor((runtime.video_seconds or 0)/60),math.floor((runtime.video_seconds or 0)%60))
    end
    if state.waiting_save and type(ctx.save_status) == 'function' then
        local pending, err = ctx.save_status(state.waiting_save)
        if err then state.notice = tostring(err)
        elseif not pending then
            state.notice = text(ctx, '世界线已保存', 'Worldline saved')
            state.waiting_save = nil
        end
    end
    if not (love.timer and type(love.timer.getTime) == 'function') then fallback_clock = fallback_clock + math.max(0, tonumber(dt) or 0) end
    local modal = state.modal
    if modal then
        modal.elapsed = (modal.elapsed or 0) + math.max(0, tonumber(dt) or 0)
        if modal.closing then
            local duration = G.SETTINGS.reduced_motion and 0.18 or 0.28
            if modal.elapsed >= duration then finish_modal(ctx) end
        end
    end
    local waiting = state.archive_wait
    if waiting then
        if G.OVERLAY_MENU ~= waiting.overlay or ctx.ui_view ~= waiting.kind then state.archive_wait = nil
        elseif now() >= waiting.next_poll then
            waiting.next_poll = now() + 0.08
            if state.modal then state.modal.replace_in_place = true end
            UI.archive_browser(ctx,waiting.kind,waiting.page,waiting.selected,true)
        end
    end
    if state.undo_confirmation then confirmation_live(ctx); if state.undo_confirmation then return state.active end end
    if not state.active then return false end
    local target = state.transition_target
    local current = math.max(0, math.min(1, state.transition or 0))
    local reduced = G and G.SETTINGS and G.SETTINGS.reduced_motion
    local delta = math.max(0, tonumber(dt) or 0) / (reduced and 0.18 or target == 1 and 0.28 or 0.24)
    state.transition = target == 1 and math.min(1, current + delta) or math.max(0, current - delta)
    if target == 0 and state.transition == 0 then finish_close(ctx) end
    return state.active
end

function UI.rebuild(ctx, preserve)
    local tree = public_tree(ctx)
    local rows = tree and (type(ctx.presentation_rows) == 'function' and ctx.presentation_rows()
        or tree.visible_rows and tree:visible_rows() or tree:rows()) or {}
    state.layout = Graph.layout(rows, {gap_x = 200})
    state.tree, state.node_count, state.tree_revision = tree, tree and tree.next_id or 0, tree and tree.structure_revision
    state.annotation_revision = tree and tree.annotation_revision
    Selection.prune(state, state.layout)
    local geometry = Renderer.geometry(state)
    if not preserve or not state.view then
        state.view = Graph.new_view(geometry.canvas.w, geometry.canvas.h, state.layout)
        if state.view.scale < 0.65 and tree and state.layout.by_id[tree.current] then
            state.view.scale = 0.8
            Graph.focus_node(state.view, state.layout.by_id[tree.current], geometry.canvas)
        end
    end
    state.drag, state.hover, state.selection_box = nil, nil, nil
end

function UI.open(ctx, prepared)
    UI.cancel_undo_confirmation(ctx)
    if state.modal then return UI.close_modal(ctx) end
    if not prepared and not state.active and type(ctx.before_open) == 'function' and ctx.before_open() == false then return false end
    if state.native_overlay then
        G.FUNCS.exit_overlay_menu()
        state.native_overlay = false
    end
    if not state.active then
        state.previous_pause = G.SETTINGS.paused == true
        state.transition = 0
    end
    state.transition_target = 1
    local tree = public_tree(ctx)
    state.at_current_node = type(ctx.at_current_node) == 'function' and ctx.at_current_node()
        or ctx.at_current_node == true
    if state.tree ~= tree or not state.layout or state.node_count ~= (tree and tree.next_id or 0)
        or state.tree_revision ~= (tree and tree.structure_revision)
        or state.annotation_revision ~= (tree and tree.annotation_revision) then
        local same_tree = state.tree == tree
        if not same_tree then Selection.set(state, {}, nil, nil); state.fold_start = nil end
        UI.rebuild(ctx, same_tree)
    end
    state.active, ctx.ui_view = true, 'tree'
    G.SETTINGS.paused = true
    return true
end

function UI.detail(ctx, id)
    local tree = public_tree(ctx)
    if not tree or not tree:get(id) then return false end
    if not state.active and UI.open(ctx) == false then return false end
    if type(ctx.reveal_node) == 'function' and ctx.reveal_node(id) then UI.rebuild(ctx, true) end
    Selection.set(state, {id}, id, id)
    state.at_current_node = type(ctx.at_current_node) == 'function' and ctx.at_current_node()
        or ctx.at_current_node == true
    local geometry = Renderer.geometry(state)
    if state.layout.by_id[id] then Graph.reveal_node(state.view, state.layout.by_id[id], geometry.canvas) end
    return true
end

function UI.archives(ctx, page, selected)
    return UI.archive_browser(ctx, 'archives', page, selected)
end

local function native_panel(ctx, title, contents, kind, back_func, width)
    local embedded = state.active == true
    local modal, replacing = state.modal, state.modal ~= nil
    if embedded then
        if not modal then
            modal = {cursor_layer=G.CONTROLLER and G.CONTROLLER.cursor_context and G.CONTROLLER.cursor_context.layer,
                elapsed=0, closing=false}
            state.modal = modal
        end
        modal.closing = false
        state.drag, state.hover, state.selection_box = nil, nil, nil
    else UI.close(ctx, true) end
    state.archive_wait = nil
    table.insert(contents, 1, line(title, 0.45))
    ctx.ui_view, state.native_overlay = kind, true
    G.SETTINGS.paused = true
    -- Definitions create their Sprite objects before the overlay pauses the
    -- game. Moveable otherwise refuses to move those objects while paused,
    -- leaving the first page's card backs/chips/toggle check at their origin.
    -- Transfer only objects owned by this new native panel to its pause clock.
    local function pause_objects(node)
        if type(node) ~= 'table' then return end
        local object = node.config and node.config.object
        if object and object.created_on_pause ~= nil then object.created_on_pause = true end
        for _, child in ipairs(node.nodes or {}) do pause_objects(child) end
    end
    for _, node in ipairs(contents) do pause_objects(node) end
    local definition = create_UIBox_generic_options {
        contents = {{n = G.UIT.C, config = {align = 'cm', padding = 0.07}, nodes = contents}},
        back_func = back_func or 'worldline_back', minw = width or 8.5,
        back_label = kind=='film_progress' and text(ctx,nil,'Cancel export') or nil,
        back_colour = kind=='film_progress' and G.C.RED or nil,
        bg_colour = embedded and {0,0,0,0.4} or nil}
    local no_cursor_stack = G.NO_MOD_CURSOR_STACK
    if embedded and replacing then G.NO_MOD_CURSOR_STACK = true end
    local ok, err = pcall(G.FUNCS.overlay_menu, {definition=definition,
        config=embedded and {no_esc=true,offset=modal.replace_in_place and {x=0,y=0} or nil} or nil})
    G.NO_MOD_CURSOR_STACK = no_cursor_stack
    if not ok then error(err, 0) end
    if embedded then
        modal.overlay, modal.back_func = G.OVERLAY_MENU, back_func or 'worldline_back'
        modal.elapsed, modal.replace_in_place = 0, nil
    end
end
end_editor = function()
    local edit = state.editor
    state.editor = nil
    if edit and love.keyboard and love.keyboard.setTextInput then
        love.keyboard.setTextInput(edit.previous_text_input == true)
    end
    if edit and edit.previous_key_repeat~=nil and love.keyboard.setKeyRepeat then
        love.keyboard.setKeyRepeat(edit.previous_key_repeat)
    end
end
local function edit_display(edit)
    local value = edit.value
    local chars = {}
    for char in value:gmatch('[%z\1-\127\194-\244][\128-\191]*') do chars[#chars + 1] = char end
    local result = {}
    for n = math.max(1, #chars - 17), #chars do result[#result + 1] = chars[n] end
    edit.display = (#chars > 18 and '...' or '') .. table.concat(result) .. (edit.composition or '') .. '|'
end
local function edit_insert(edit, value)
    if edit.select_all then edit.value = ''; edit.select_all = nil end
    value = tostring(value or ''):gsub('[%z\1-\31\127]', '')
    local chars = {}
    for char in (edit.value .. value):gmatch('[%z\1-\127\194-\244][\128-\191]*') do
        if #chars == (edit.limit or 64) then break end
        chars[#chars + 1] = char
    end
    edit.value = table.concat(chars)
    edit.composition = nil
    edit_display(edit)
end
function UI.edit_name(ctx, title, value, save, options)
    end_editor()
    options=options or {}
    local edit = {value = tostring(value or ''), error = '', composition = '', save = save,limit=options.limit,
        owner = ctx.tree, previous_text_input = love.keyboard and love.keyboard.isTextInputActive
            and love.keyboard.isTextInputActive() or false}
    if love.keyboard and love.keyboard.hasKeyRepeat and love.keyboard.setKeyRepeat then
        edit.previous_key_repeat=love.keyboard.hasKeyRepeat()
        love.keyboard.setKeyRepeat(true)
    end
    edit_display(edit)
    native_panel(ctx, title, {
        {n = G.UIT.R, config = {align = 'cm', padding = 0.14, r = 0.1, colour = G.C.BLUE,
            minw = 8, maxw = 8, minh = 0.7}, nodes = {{n = G.UIT.T, config = {
                ref_table = edit, ref_value = 'display', scale = 0.43, colour = G.C.UI.TEXT_LIGHT}}}},
        line(options.prompt or text(ctx, nil, 'Type a name. Enter saves; Esc cancels.'), 0.28),
        {n = G.UIT.R, config = {align = 'cm'}, nodes = {{n = G.UIT.T,
            config = {ref_table = edit, ref_value = 'error', scale = 0.28, colour = G.C.UI.TEXT_LIGHT}}}},
        button(text(ctx, nil, 'SAVE'), 'worldline_name_save'),
        button(text(ctx, nil, 'Cancel'), 'worldline_name_cancel'),
    }, 'name_editor', 'worldline_name_cancel')
    state.editor = edit
    if love.keyboard and love.keyboard.setTextInput then love.keyboard.setTextInput(true) end
end
function UI.cancel_name(ctx)
    local back = state.editor and state.editor.after_cancel
    end_editor()
    if back then return back() end
    return UI.open(ctx, true)
end
function UI.submit_name(ctx)
    local edit = state.editor
    if not edit then return false end
    if edit.owner ~= ctx.tree then edit.error = text(ctx, nil, 'Worldline changed; reopen this editor'); return false end
    local ok, value, err = pcall(edit.save, edit.value)
    if not ok or value == false or value == nil then
        edit.error = tostring(ok and err or value or text(ctx, nil, 'Operation could not complete'))
        return false
    end
    local after_save = edit.after_save
    end_editor()
    if after_save then after_save(); return true end
    UI.open(ctx, true)
    UI.rebuild(ctx, true)
    return true
end
function UI.navigation(ctx, kind, page)
    end_editor()
    local query = state.bookmark_query or ''
    local list = kind == 'bookmarks' and (ctx.bookmark_rows and ctx.bookmark_rows(query) or {})
        or (ctx.fold_rows and ctx.fold_rows() or {})
    local pages = math.max(1, math.ceil(#list / 5))
    page = math.max(1, math.min(pages, math.floor(tonumber(page) or 1)))
    local contents = {}
    if kind == 'bookmarks' then
        contents[#contents + 1] = button(text(ctx, nil, 'Search') .. (query ~= '' and ': ' .. clipped(query, 24) or ''),
            'worldline_bookmark_search')
    end
    if #list == 0 then contents[#contents + 1] = line(text(ctx, nil,
        kind == 'bookmarks' and 'No bookmarks yet' or 'No folded regions yet'), 0.33) end
    for index = (page - 1) * 5 + 1, math.min(#list, page * 5) do
        local item = list[index]
        local node_id = item.node_id or item.id or item.start_id
        local label = tostring(item.label or item.name or ('#' .. tostring(node_id)))
        local row = {button(clipped(label, 28), 'worldline_navigation_goto', {id = kind == 'folds' and item.start_id or node_id}, 4.6)}
        if kind == 'bookmarks' then
            row[#row + 1] = button(text(ctx, nil, 'Rename'), 'worldline_bookmark_edit', {id = node_id, label = label}, 1.7)
            row[#row + 1] = button('X', 'worldline_bookmark_remove', {id = node_id}, 0.7)
        else
            row[#row + 1] = button(text(ctx, nil, item.collapsed and 'Expand' or 'Collapse'),
                'worldline_fold_toggle', {id = item.id}, 1.7)
            row[#row + 1] = button('X', 'worldline_fold_remove', {id = item.id}, 0.7)
        end
        contents[#contents + 1] = {n = G.UIT.R, config = {align = 'cm', padding = 0.04}, nodes = row}
    end
    contents[#contents + 1] = button('<  ' .. page .. ' / ' .. pages .. '  >', 'worldline_navigation_page',
        {kind = kind, page = page % pages + 1})
    if state.notice then contents[#contents + 1] = line(clipped(state.notice, 60), 0.28) end
    native_panel(ctx, text(ctx, nil, kind == 'bookmarks' and 'BOOKMARKS' or 'FOLDS'), contents, kind)
    state.navigation_kind, state.navigation_page = kind, page
end

local function invoke(ctx, key, ...)
    if type(ctx[key]) ~= 'function' then return nil, text(ctx, nil, 'Operation could not complete') end
    local ok, value, err = pcall(ctx[key], ...)
    if not ok then return nil, tostring(value) end
    return value, err
end

local function manage_panel(ctx, title, contents, kind, back)
    state.management_confirm = nil
    native_panel(ctx, title, contents, kind, 'worldline_manage_back')
    state.manage_return = back
end

local function wrapped(value, columns)
    local rows, chars, size, space = {}, {}, 0, nil
    local function flush(at)
        rows[#rows + 1] = table.concat(chars, '', 1, at or #chars):gsub('%s+$', '')
        local rest = {}
        for i = (at or #chars) + 1, #chars do rest[#rest + 1] = chars[i] end
        chars, size, space = rest, 0, nil
        for i, char in ipairs(chars) do size = size + (#char >= 3 and 2 or 1); if char == ' ' then space = i end end
    end
    for char in tostring(value or ''):gsub('[\r\n\t]', ' '):gmatch('[%z\1-\127\194-\244][\128-\191]*') do
        local width = #char >= 3 and 2 or 1
        if size + width > columns then flush(space or #chars) end
        if #chars > 0 or char ~= ' ' then chars[#chars + 1], size = char, size + width; if char == ' ' then space = #chars end end
    end
    if #chars > 0 then flush() end
    return rows
end

local function short_label(value, columns)
    local rows = wrapped(value, columns)
    return (rows[1] or '') .. (#rows > 1 and '...' or '')
end

local function panel(nodes, width, height)
    return {n=G.UIT.C, config={align='tm', padding=0.16, r=0.12,
        minw=width, minh=height, colour=G.C.BLACK or G.C.L_BLACK}, nodes=nodes}
end

local function native_deck(item, width)
    local summary = item.summary or {}
    local center = G.P_CENTERS and G.P_CENTERS[summary.deck or 'b_red']
    local atlas = center and G.ASSET_ATLAS and G.ASSET_ATLAS[center.atlas or 'centers']
    if not (Sprite and G.UIT.O and center and center.pos and atlas) then return nil end
    local sprite = Sprite(0, 0, width, width * 95 / 71, atlas, center.pos)
    sprite.states.drag.can, sprite.states.hover.can, sprite.states.collide.can = false, false, false
    -- Vanilla stake badges are full-card transparent stickers: their upper
    -- right placement is baked into the native atlas, not a separate chip's
    -- offset. Own a copy so this preview never moves a shared gameplay sprite.
    local sticker_key = G.sticker_map and G.sticker_map[summary.stake]
    local original = sticker_key and G.shared_stickers and G.shared_stickers[sticker_key]
    if original and original.atlas and original.sprite_pos then
        local sticker = Sprite(0, 0, width, width * 95 / 71, original.atlas,
            {x=original.sprite_pos.x,y=original.sprite_pos.y})
        sticker.states.drag.can, sticker.states.hover.can, sticker.states.collide.can = false, false, false
        sticker.created_on_pause = true
        sticker:set_role({role_type='Minor',major=sprite,draw_major=sprite,
            xy_bond='Strong',wh_bond='Strong',scale_bond='Strong'})
        sprite.children.stake = sticker
    end
    return {n=G.UIT.O, config={object=sprite}}
end

local function archive_name(ctx, item)
    return item.name or (item.reason and item.label) or item.seed or item.label or text(ctx,nil,'Worldline')
end

local function date_label(item)
    if type(item.created_at) ~= 'number' then return nil end
    local ok, value = pcall(os.date, '%Y-%m-%d  %H:%M', item.created_at)
    return ok and value or nil
end

local function status_line(value, width)
    local rows = wrapped(value, width or 74)
    local node = line((rows[1] or '') .. (#rows > 1 and '...' or ''), 0.28)
    node.config.hover, node.config.force_focus = true, true
    node.config.on_demand_tooltip = {text=wrapped(value, 58)}
    return node
end

function UI.archive_browser(ctx, kind, page, selected, poll_only)
    end_editor()
    local backup = kind == 'backups'
    local rows, err = invoke(ctx, backup and 'backup_rows' or 'archive_rows',poll_only==true)
    if rows == nil and err == 'loading' then
        -- The reader owns decoding in its worker. Poll only its explicit loading
        -- state, and only while this particular browser overlay still owns UI.
        if state.archive_wait and state.archive_wait.kind==kind and G.OVERLAY_MENU == state.archive_wait.overlay then
            state.archive_wait.next_poll = now() + 0.08
            return true
        end
        native_panel(ctx,text(ctx,nil,backup and 'Backups' or 'Local worldlines'),{
            {n=G.UIT.R,config={align='cm',minh=4.8,minw=11.6},nodes={
                line(text(ctx,nil,'Loading worldline')..'...',0.34)}}},kind,'worldline_back',12.1)
        state.archive_wait = {kind=kind,page=page,selected=selected,
            overlay=G.OVERLAY_MENU,next_poll=now()+0.08}
        return true
    end
    rows = rows or {}
    if err then state.notice = err end
    local page_key, selection_key = backup and 'backup_page' or 'archive_page', backup and 'backup_selected' or 'archive_selected'
    local pages = math.max(1, math.ceil(#rows / UI.PAGE_SIZE))
    page = math.max(1, math.min(pages, math.floor(tonumber(page) or state[page_key] or 1)))
    if selected then
        for index, item in ipairs(rows) do if item.id == selected then page = math.ceil(index / UI.PAGE_SIZE); break end end
    end
    selected = selected or state[selection_key]
    local first, last, current = (page - 1) * UI.PAGE_SIZE + 1, math.min(#rows, page * UI.PAGE_SIZE), nil
    for index = first, last do if rows[index].id == selected then current = rows[index]; break end end
    current = current or rows[first]
    state[page_key], state[selection_key] = page, current and current.id
    local listing = {}
    for index = first, last do
        local item = rows[index]
        local title = archive_name(ctx,item)
        local detail = backup and date_label(item) or item.seed
        local label = {line(short_label(title, 25), 0.34), line(short_label(detail or '', 34), 0.27)}
        local card = native_deck(item, 0.46)
        local cells = {}
        if card then cells[#cells + 1] = {n=G.UIT.C,config={align='cm',padding=0.07},nodes={card}} end
        cells[#cells + 1] = {n=G.UIT.C,config={align='cl',minw=4.15},nodes=label}
        listing[#listing + 1] = {n=G.UIT.R,config={align='cm',minw=5.25,minh=0.87,padding=0.05,r=0.1,
            colour=current.id==item.id and G.C.BLUE or (G.C.L_BLACK or G.C.GREY),
            shadow=true,hover=true,button='worldline_archive_select',ref_table={id=item.id,kind=kind},
            focus_args={nav='wide'},on_demand_tooltip={text=wrapped(title,48)}},nodes=cells}
    end
    if #rows == 0 then
        local message = text(ctx,nil,backup and 'No backups yet' or 'No saved worldlines yet')
        for _, value in ipairs(wrapped(message, 32)) do listing[#listing+1]=line(value,0.34) end
    end
    local list_body = {n=G.UIT.R,config={align='tm',minh=3.85},nodes={{n=G.UIT.C,config={align='tm',padding=0.06},nodes=listing}}}
    local page_callback = backup and 'worldline_backup_page' or 'worldline_archive_page'
    local pager = {n=G.UIT.R,config={align='cm',padding=0.08},nodes={
        side_button('<',page_callback,{page=math.max(1,page-1),disabled=page==1},0.8,'worldline_management_enabled'),
        {n=G.UIT.C,config={align='cm',minw=2.8},nodes={line(page..' / '..pages,0.32)}},
        side_button('>',page_callback,{page=math.min(pages,page+1),disabled=page==pages},0.8,'worldline_management_enabled')}}
    local details = {}
    if current then
        local title = archive_name(ctx,current)
        local title_rows = wrapped(title, 30)
        local names = {}
        for index=1,math.min(3,#title_rows) do names[#names+1]=line(title_rows[index]..(index==3 and #title_rows>3 and '...' or ''),0.36) end
        details[#details+1] = {n=G.UIT.R,config={align='cm',minh=0.85,hover=true,force_focus=true,
            on_demand_tooltip={text=wrapped(title,48)}},nodes={{n=G.UIT.C,config={align='cm'},nodes=names}}}
        if current.seed then details[#details+1]=line(text(ctx,nil,'SEED')..'  '..current.seed,0.29) end
        local summary = current.summary or {}
        local info = {line(tostring(current.node_count or 0)..text(ctx,nil,' points'),0.3)}
        if summary.ante then info[#info+1]=line(text(ctx,nil,'ANTE ')..summary.ante..'  /  '..text(ctx,nil,'ROUND ')..tostring(summary.round or 0),0.28) end
        if summary.dollars or summary.money then info[#info+1]=line('$'..tostring(summary.dollars or summary.money),0.36) end
        local preview, card = {}, native_deck(current,1.05)
        if card then preview[#preview+1]={n=G.UIT.C,config={align='cm',padding=0.12},nodes={card}} end
        preview[#preview+1]={n=G.UIT.C,config={align='cm',minw=3.5},nodes=info}
        details[#details+1]={n=G.UIT.R,config={align='cm',minh=1.65},nodes=preview}
        local date = date_label(current)
        if date then details[#details+1]=line(date,0.25) end
        details[#details+1]=button(text(ctx,nil,backup and 'Restore backup' or 'Load'),
            backup and 'worldline_backup_restore' or 'worldline_load_archive',{id=current.id},5.2,'worldline_management_enabled',G.C.GREEN or G.C.BLUE)
        if backup then
            for _,value in ipairs(wrapped(text(ctx,nil,'Restores a separate worldline.'),34)) do details[#details+1]=line(value,0.28) end
        else
            details[#details+1]={n=G.UIT.R,config={align='cm',padding=0.08},nodes={
                side_button(text(ctx,nil,'Rename'),'worldline_archive_rename',current,2.48,'worldline_management_enabled'),
                side_button(text(ctx,nil,'Delete archive'),'worldline_archive_delete',{id=current.id},2.48,'worldline_management_enabled',G.C.RED)}}
        end
    else
        for _, value in ipairs(wrapped(text(ctx,nil,'Select a worldline'),32)) do details[#details+1]=line(value,0.34) end
    end
    local contents = {
        {n=G.UIT.R,config={align='cm',padding=0.08},nodes={
            side_button(text(ctx,nil,'ARCHIVES'),'worldline_archives',nil,2.5,nil,not backup and G.C.BLUE or G.C.GREY),
            side_button(text(ctx,nil,'Backups'),'worldline_backups',nil,2.5,nil,backup and G.C.BLUE or G.C.GREY),
            {n=G.UIT.C,config={align='cm',minw=2.1},nodes={}},
            side_button(text(ctx,nil,'Worldline settings'),'worldline_settings',nil,4.1)}},
        {n=G.UIT.R,config={align='tm',padding=0.12},nodes={panel({list_body,pager},5.7,4.8),panel(details,5.7,4.8)}},
        status_line(state.notice or '',88)}
    state.management_confirm,state.manage_return=nil,nil
    native_panel(ctx,text(ctx,nil,'Local worldlines'),contents,kind,'worldline_back',12.1)
end

function UI.manage_archive(ctx, id)
    end_editor()
    return UI.archives(ctx,nil,id)
end

function UI.manage_node(ctx, id)
    end_editor()
    local tree = public_tree(ctx)
    if not tree or not tree:get(id) then return UI.open(ctx, true) end
    local preview, err = invoke(ctx, 'branch_delete_preview', id)
    local allowed = preview and preview.allowed == true
    local contents = {line(clipped(tree.metadata.name or tree.metadata.seed, 48), 0.34),
        line(text(ctx, nil, 'POINT #') .. tostring(id), 0.3),
        button(text(ctx, nil, 'Rename'), 'worldline_archive_rename', {
            id=tree.metadata.run_id, name=tree.metadata.name, seed=tree.metadata.seed, node_id=id}),
        button(text(ctx, nil, 'Export branch'), 'worldline_branch_export', {id=id}),
        button(text(ctx, nil, 'Delete branch'), 'worldline_branch_delete', {id=id,disabled=not allowed}, 8,
            'worldline_management_enabled', G.C.RED),
        button(text(ctx, nil, 'Worldline settings'), 'worldline_settings', {node_id=id})}
    paragraph(contents,text(ctx,nil,'Branch exports include its route from the start and all following branches.'))
    if not allowed then paragraph(contents, preview and preview.reason and text(ctx,nil,preview.reason)
        or err or text(ctx, nil, 'Cannot delete this branch')) end
    if state.notice then paragraph(contents, state.notice) end
    manage_panel(ctx, text(ctx, nil, 'Manage'), contents, 'node_manage', function()
        UI.open(ctx, true); UI.rebuild(ctx, true)
        if public_tree(ctx) and public_tree(ctx):get(id) then UI.detail(ctx, id) end
    end)
    state.managed_node = id
end

function UI.backups(ctx, page)
    return UI.archive_browser(ctx,'backups',page)
end

function UI.record_video(ctx, first, last, notice)
    end_editor()
    local tree=public_tree(ctx)
    if not tree then return UI.open(ctx,true) end
    local ids=state.compare_ids
    local previous=state.film_form
    first=first or previous and previous.first or ids and ids[1]
    last=last or previous and previous.last or ids and ids[2]
    if not first or not last then first,last=tree.root,state.selected or tree.current end
    local function ancestor(a,b)
        local node=tree:get(b)
        while node do if node.id==a then return true end;node=node.parent and tree:get(node.parent) end
    end
    if not ancestor(first,last) and ancestor(last,first) then first,last=last,first end
    local form={first=first,last=last,options=ctx.film_options and ctx.film_options() or {},message=notice or ''}
    local o=form.options
    local function cycle(label,key,values,labels)
        local index=1 for i,v in ipairs(values) do if o[key]==v then index=i end end
        return create_option_cycle{label=text(ctx,nil,label),options=labels,current_option=index,
            opt_callback='worldline_film_'..key,w=5.2,h=0.6,scale=0.6,no_pips=true}
    end
    local route={line(text(ctx,nil,'Recording endpoints'),0.36),
        {n=G.UIT.R,config={align='cm',padding=0.05},nodes={
            side_button(text(ctx,nil,'Start point')..' #'..first,'worldline_film_endpoint',{key='first'},2.3),
            side_button(text(ctx,nil,'End point')..' #'..last,'worldline_film_endpoint',{key='last'},2.3)}},
        cycle('Game speed','speed',{0.25,0.5,1,2,4,8},{'0.25x','0.5x','1x','2x','4x','8x'}),
        cycle('Frame rate','fps',{30,60},{'30 FPS','60 FPS'}),
        cycle('Video resolution','height',{720,1080,1440},{'1280 x 720','1920 x 1080','2K: 2560 x 1440'})}
    local details={line(text(ctx,nil,'Card information'),0.36)}
    for _,spec in ipairs({{'pause_consumables','Pause before consumables'},{'show_pack','Show every pack card'}}) do
        details[#details+1]=create_toggle{label=text(ctx,nil,spec[2]),ref_table=o,ref_value=spec[1],w=0,
            label_scale=0.30,callback=function(v) invoke(ctx,'set_film_option',spec[1],v==true) end}
    end
    details[#details+1]=cycle('Information pause','pause_seconds',{0.5,1,1.5,2,3,5},{'0.5 s','1 s','1.5 s','2 s','3 s','5 s'})
    details[#details+1]=cycle('Action delay','action_delay',{0,0.35,0.75,1,2},{'0 s','0.35 s','0.75 s','1 s','2 s'})
    details[#details+1]=button(text(ctx,nil,'Use selected points'),'worldline_film_selected',nil,4.8)
    local plan,err=invoke(ctx,'film_plan',first,last)
    local summary=plan and ('#'..first..' > #'..last..' / '..plan.total..' '..text(ctx,nil,'Recorded actions')) or tostring(err)
    local contents={
        {n=G.UIT.R,config={align='tm',padding=0.10},nodes={panel(route,5.2,4.1),panel(details,5.2,4.1)}},
        {n=G.UIT.R,config={align='tm',padding=0.10},nodes={
            panel({{n=G.UIT.R,config={align='cm',padding=0.04},nodes={
                side_button(text(ctx,nil,'FFmpeg path'),'worldline_film_browse_ffmpeg',nil,3.4),
                side_button(text(ctx,nil,'Enter path'),'worldline_film_path',nil,1.3)}},line(clipped(o.ffmpeg,36),0.25)},5.2),
            panel({{n=G.UIT.R,config={align='cm',padding=0.04},nodes={
                side_button(text(ctx,nil,'Video output directory'),'worldline_film_browse_output',nil,3.4),
                side_button(text(ctx,nil,'Enter path'),'worldline_film_output',nil,1.3)}},
                line(clipped(o.output_dir~='' and o.output_dir or text(ctx,nil,'Default recording directory'),36),0.25)},5.2)}},
    }
    if o.height==1440 then contents[#contents+1]=line(text(ctx,nil,'2K uses more GPU memory, encoding time and output disk space.'),0.25,G.C.ORANGE) end
    local warnings=plan and plan.warnings or {}
    if warnings.incomplete_records or warnings.legacy_order or warnings.legacy_poker_order or warnings.legacy_playing_order or warnings.legacy_identity then
        contents[#contents+1]=line(text(ctx,nil,'Some action records are incomplete; playback order may differ from actual play.'),0.25,G.C.ORANGE)
    end
    contents[#contents+1]=line(clipped(summary,84),0.28)
    contents[#contents+1]=line(text(ctx,nil,'Background export; your current run stays paused.'),0.28)
    if form.message~='' then contents[#contents+1]=line(clipped(form.message,84),0.28) end
    contents[#contents+1]=button(text(ctx,nil,'Export video'),'worldline_film_start',{disabled=not plan},8,'worldline_management_enabled',G.C.GREEN)
    manage_panel(ctx,text(ctx,nil,'Record video'),contents,'record_video',function() UI.open(ctx,true) end)
    state.film_form=form
    return form
end

function UI.film_progress(ctx)
    local runtime=ctx.film_runtime
    local info={phase='',percent='',counts=''}
    state.film_progress=info
    local function dynamic(key,size)
        return {n=G.UIT.R,config={align='cm',padding=0.08},nodes={
            {n=G.UIT.T,config={ref_table=info,ref_value=key,scale=size or 0.35,colour=G.C.UI.TEXT_LIGHT,shadow=true}}}}
    end
    local contents={line(text(ctx,nil,'Background export; your current run stays paused.'),0.32),
        dynamic('phase'),
        {n=G.UIT.R,config={align='cm',minw=8,minh=0.55,r=0.1,colour=G.C.BLACK,
            progress_bar={max=1,ref_table=runtime,ref_value='progress',empty_col=G.C.BLACK,filled_col=G.C.GREEN}},
            nodes={dynamic('percent',0.42)}},dynamic('counts',0.30),
        line(clipped(runtime.output,78),0.27)}
    native_panel(ctx,text(ctx,nil,'Export video'),contents,'film_progress','worldline_film_cancel')
end

function UI.settings(ctx, notice)
    end_editor()
    local origin, node_id = ctx.ui_view, state.managed_node
    local back
    if origin == 'archives' then back=function() UI.archives(ctx) end
    elseif origin == 'backups' then back=function() UI.backups(ctx) end
    elseif origin == 'node_manage' then back=function() UI.manage_node(ctx,node_id) end
    elseif origin == 'tree' then back=function() UI.open(ctx,true) end
    elseif origin == 'worldline_settings' and state.manage_return then back=state.manage_return
    else back=function()
        state.native_overlay, state.manage_return, ctx.ui_view = false, nil, nil
        if G.FUNCS.options then return G.FUNCS.options() end
        G.SETTINGS.paused = true
        G.FUNCS.overlay_menu{definition=create_UIBox_options()}
    end end
    local form = {auto_create=type(ctx.auto_create_enabled)=='function' and ctx.auto_create_enabled() or false,
        message=tostring(notice or '')}
    local creation = {create_toggle({label=text(ctx,nil,'Automatic creation'),
        -- Zero removes create_toggle's asymmetric label/checkbox minimum
        -- widths; its native centered row then centers their combined content.
        ref_table=form,ref_value='auto_create',w=0,label_scale=0.36,active_colour=G.C.GREEN or G.C.BLUE,
        callback=function(value)
            local result, err = invoke(ctx,'set_auto_create',value==true)
            if not result then
                if type(ctx.auto_create_enabled)=='function' then form.auto_create=ctx.auto_create_enabled()
                else form.auto_create=not value end
                form.message=tostring(err or text(ctx,nil,'Cannot save mod settings'))
            else form.message=text(ctx,nil,'Settings saved') end
            return result
        end})}
    for _,value in ipairs(wrapped(text(ctx,nil,'Affects runs without an existing worldline'),52)) do creation[#creation+1]=line(value,0.29) end
    for _,value in ipairs(wrapped(text(ctx,nil,'Recording alone does not disable achievements.'),52)) do creation[#creation+1]=line(value,0.29) end
    local suspended = type(ctx.recording_suspended)=='function' and ctx.recording_suspended()
    local current = {line(text(ctx,nil,'Current run'),0.29),
        line(text(ctx,nil,suspended and 'Recording paused' or public_tree(ctx) and 'Recording worldline' or 'No worldline yet'),0.36)}
    if suspended then
        current[#current+1]=button(text(ctx,nil,'Start recording again'),'worldline_resume_recording',nil,6.8,'worldline_management_enabled')
    end
    local contents = {
        {n=G.UIT.R,config={align='cm',padding=0.08},nodes={panel(creation,7.6,1.8)}},
        {n=G.UIT.R,config={align='cm',padding=0.08},nodes={panel(current,7.6,suspended and 1.8 or 1.35)}},
        {n=G.UIT.R,config={align='cm',minh=0.5},nodes={{n=G.UIT.T,config={
            ref_table=form,ref_value='message',scale=0.28,colour=G.C.UI.TEXT_LIGHT}}}}}
    manage_panel(ctx,text(ctx,nil,'Worldline settings'),contents,'worldline_settings',back)
    state.settings_form=form
end

function UI.confirm_delete(ctx, kind, id)
    local branch = kind == 'branch'
    local preview, err = invoke(ctx, branch and 'branch_delete_preview' or 'archive_delete_preview', id)
    if not preview or branch and preview.allowed ~= true then
        report(ctx,nil,preview and preview.reason and text(ctx,nil,preview.reason) or err)
        if branch then return UI.manage_node(ctx,id) end
        return UI.manage_archive(ctx,id)
    end
    local title = text(ctx,nil,branch and 'Delete branch?' or 'Delete archive?')
    local back=function() if branch then UI.manage_node(ctx,id) else UI.manage_archive(ctx,id) end end
    local pending={kind=kind,id=id,token=preview.token,tree=ctx.tree,back=back}
    local contents = {line(short_label(preview.label or (branch and text(ctx,nil,'POINT #')..id or text(ctx,nil,'Worldline')),46),0.36),
        line(tostring(preview.count or 0)..text(ctx,nil,' points'),0.3)}
    paragraph(contents,text(ctx,nil,branch and 'This removes the selected point and its descendants.'
        or 'This worldline will leave the archive list. Its backup can be restored.'))
    if not branch and ctx.tree and ctx.tree.metadata.run_id==id then
        paragraph(contents,text(ctx,nil,'The game in progress will continue. Recording stops for this run.'))
    end
    paragraph(contents,text(ctx,nil,'A backup is kept before deletion.'))
    if branch then paragraph(contents,text(ctx,nil,'The current Undo history will be cleared.')) end
    contents[#contents+1]={n=G.UIT.R,config={align='cm',padding=0.12},nodes={
        side_button(text(ctx,nil,'Cancel'),'worldline_manage_back',nil,3.8),
        side_button(text(ctx,nil,branch and 'Delete branch' or 'Delete archive'),
            'worldline_confirm_delete',pending,3.8,nil,G.C.RED)}}
    manage_panel(ctx,title,contents,'delete_confirmation',back)
    pending.overlay=G.OVERLAY_MENU
    state.management_confirm=pending
end

local function action(ctx, key)
    if key == 'undo' then return UI.undo(ctx, 'tree') end
    if key == 'close' then UI.close(ctx); return end
    if key == 'archives' then UI.archives(ctx); return end
    if key == 'record_video' then
        local ids=state.compare_ids
        return UI.record_video(ctx,ids and ids[1],ids and ids[2])
    end
    if key == 'manage' and state.selected then UI.manage_node(ctx,state.selected); return end
    if key == 'bookmarks' or key == 'folds' then UI.navigation(ctx, key); return end
    if key:sub(1, 4) == 'tab_' then state.detail_tab, state.detail_scroll = key:sub(5), 0; return end
    if key == 'swap_compare' and state.compare_ids then
        local first, second = state.compare_ids[1], state.compare_ids[2]
        Selection.set(state, {second, first}, state.selected, state.selection_anchor)
        return
    end
    if key == 'cancel_region' then state.fold_start = nil; return end
    if key == 'detail_up' or key == 'detail_down' then
        local maximum
        if Renderer.detail_scroll_max then maximum = Renderer.detail_scroll_max(ctx, state)
        else
            local node = state.layout and state.layout.by_id[state.selected]
            local rows = node and Renderer.detail_rows and Renderer.detail_rows(ctx, node.row, state.detail_tab or 'overview') or {}
            maximum = math.max(0, #rows - 6)
        end
        state.detail_scroll = math.max(0, math.min(maximum,
            (state.detail_scroll or 0) + (key == 'detail_up' and -1 or 1)))
        return
    end
    local geometry = Renderer.geometry(state)
    if key == 'fit' then Graph.fit(state.view, state.layout, geometry.canvas); return end
    if key == 'zoom_in' or key == 'zoom_out' then
        Graph.zoom(state.view, key == 'zoom_in' and 1.2 or 1 / 1.2, nil, nil, geometry.canvas); return
    end
    local tree = public_tree(ctx)
    if key == 'save' or key == 'export' or key == 'restore' or key == 'focus' then
        if not tree then
            state.notice = text(ctx, '当前没有世界线', 'No worldline yet')
            return false
        end
    end
    if key == 'focus' and tree then
        if ctx.reveal_node and ctx.reveal_node(tree.current) then UI.rebuild(ctx, true) end
        Graph.focus_node(state.view, state.layout.by_id[tree.current], geometry.canvas); return
    end
    if key == 'bookmark' and state.selected and tree and ctx.set_bookmark then
        local id, node = state.selected, state.layout.by_id[state.selected]
        UI.edit_name(ctx, text(ctx, nil, 'Edit bookmark'), node and node.row.bookmark or ('#' .. id),
            function(value) return ctx.set_bookmark(id, value) end)
        return
    end
    if key == 'fold_suworldline' and state.selected and tree and ctx.fold_suworldline then
        local id = state.selected
        UI.edit_name(ctx, text(ctx, nil, 'Name this region'), '#' .. id,
            function(value) return ctx.fold_suworldline(id, value) end)
        return
    end
    if key == 'fold_range' and state.selected and tree and ctx.fold_range then
        local ids = Selection.ids(state)
        if #ids > 2 then
            state.notice = text(ctx, '请选择恰好两个节点作为折叠区域的端点', 'Select exactly two nodes as the region endpoints')
            return false
        end
        if #ids < 2 and not state.fold_start then state.fold_start = state.selected; return end
        local first, last = #ids == 2 and ids[1] or state.fold_start, #ids == 2 and ids[2] or state.selected
        UI.edit_name(ctx, text(ctx, nil, 'Name this region'), '#' .. first .. ' - #' .. last,
            function(value)
                local ok, err = ctx.fold_range(first, last, value)
                if ok then state.fold_start = nil end
                return ok, err
            end)
        return
    end
    if key == 'expand' and state.selected and ctx.fold_rows and ctx.toggle_fold then
        for _, fold in ipairs(ctx.fold_rows()) do
            if fold.start_id == state.selected and fold.collapsed then ctx.toggle_fold(fold.id) end
        end
        UI.rebuild(ctx, true)
        return
    end
    local method, message
    if key == 'save' then method, message = ctx.save_manual or ctx.save_now, text(ctx, '世界线已保存', 'Worldline saved')
    elseif key == 'export' then method, message = ctx.export_share, text(ctx, '分享文件已导出', 'Share exported')
    elseif key == 'import' then method, message = ctx.import_latest, text(ctx, '正在载入世界线', 'Loading worldline')
    elseif key == 'folder' then method, message = ctx.open_data_folder, text(ctx, '已打开数据目录', 'Data folder opened')
    elseif key == 'restore' and state.selected then
        method = function() return ctx.request_restore(state.selected) end
        message = text(ctx, '正在收束世界线', 'Converging worldline')
    end
    if method then
        local ok, value, err = pcall(method)
        if not ok then err, value = value, nil end
        if key == 'save' and value and type(ctx.save_status) == 'function'
            and ctx.save_status(tree.metadata.run_id) then
            state.waiting_save = tree.metadata.run_id
            message = text(ctx, '正在保存世界线…', 'Saving worldline...')
        end
        report(ctx, value, err, message)
        if value and (ctx.busy or ctx.restoring) then UI.close(ctx, true) end
    end
end
UI.action = action

local function shortcut(ctx, source)
    if state.modal or state.undo_confirmation or state.editor or state.management_confirm then return false end
    ctx.last_hotkey_source = source
    if state.active then
        if state.transition_target == 0 then UI.open(ctx, true) else UI.close(ctx) end
        return true
    end
    if G.CONTROLLER and G.CONTROLLER.text_input_hook then
        ctx.last_hotkey_message = 'F6 ignored while a text input is active'
        ctx.status = text(ctx, '请先结束文本输入，再按 F6', 'Finish text input, then press F6')
        if sendInfoMessage then sendInfoMessage(ctx.last_hotkey_message, 'WorldLine') end
        return false
    end
    state.notice = nil
    ctx.last_hotkey_message = 'F6 received via ' .. source
    if sendInfoMessage then sendInfoMessage(ctx.last_hotkey_message, 'WorldLine') end
    if type(ctx.open) == 'function' then return ctx.open() end
    return UI.open(ctx)
end

local function hit(rect, x, y)
    return x >= rect.x and x <= rect.x + rect.w and y >= rect.y and y <= rect.y + rect.h
end

local function closing() return state.active and state.transition_target == 0 end

local function control_at(ctx, geometry, x, y)
    local controls = Renderer.controls(ctx, state, geometry)
    for index = #controls, 1, -1 do
        if hit(controls[index], x, y) then return controls[index] end
    end
end

local function minimap_mapping(geometry, map)
    -- Resizing, sidebar changes or the opening animation can change the input
    -- transform mid-gesture. Rebase that gesture instead of moving the camera.
    return table.concat({geometry.screen_w or 0, geometry.screen_h or 0,
        geometry.ui_scale or 1, geometry.offset_x or 0, geometry.offset_y or 0,
        geometry.transition_scale or 1, map.x, map.y, map.w, map.h,
        geometry.canvas.w, geometry.canvas.h, state.layout.width, state.layout.height,
        state.view.scale}, ':')
end

local function begin_minimap_drag(geometry, map, x, y)
    local viewport = Renderer.minimap_viewport and Renderer.minimap_viewport(state, geometry, Graph)
    if not viewport or not hit(viewport, x, y) then
        local wx = (x - map.x) / map.w * state.layout.width
        local wy = (y - map.y) / map.h * state.layout.height
        state.view.pan_x = geometry.canvas.w / 2 - wx * state.view.scale
        state.view.pan_y = geometry.canvas.h / 2 - wy * state.view.scale
    end
    state.drag = {kind = 'minimap', button = 1, x = x, y = y,
        pan_x = state.view.pan_x, pan_y = state.view.pan_y,
        map = {x = map.x, y = map.y, w = map.w, h = map.h},
        mapping = minimap_mapping(geometry, map)}
end

local function canvas_mapping(geometry)
    return table.concat({geometry.ui_scale or 1, geometry.offset_x or 0, geometry.offset_y or 0,
        geometry.transition_scale or 1, geometry.canvas.x, geometry.canvas.y,
        geometry.canvas.w, geometry.canvas.h, state.view.scale}, ':')
end

local function move_canvas_gesture(geometry, x, y)
    local drag = state.drag
    if not drag or drag.kind == 'minimap' then return end
    local mapping = canvas_mapping(geometry)
    if drag.mapping ~= mapping then
        -- Resizing or the native opening animation changes logical coordinates.
        -- Rebase rather than interpreting that transform as a mouse movement.
        drag.start_x, drag.start_y, drag.x, drag.y = x, y, x, y
        drag.pan_x, drag.pan_y, drag.mapping = state.view.pan_x, state.view.pan_y, mapping
        state.selection_box = nil
        return
    end
    drag.x, drag.y = x, y
    local dx, dy = x - drag.start_x, y - drag.start_y
    if math.abs(dx) + math.abs(dy) > 4 then drag.moved = true end
    if not drag.moved then return end
    if drag.kind == 'pan' then
        state.view.pan_x, state.view.pan_y = drag.pan_x + dx, drag.pan_y + dy
    else
        local canvas = geometry.canvas
        local left = math.max(canvas.x, math.min(drag.start_x, x))
        local top = math.max(canvas.y, math.min(drag.start_y, y))
        local right = math.min(canvas.x + canvas.w, math.max(drag.start_x, x))
        local bottom = math.min(canvas.y + canvas.h, math.max(drag.start_y, y))
        local box = {x = left, y = top, w = math.max(0, right - left), h = math.max(0, bottom - top)}
        state.selection_box = box
        local wx, wy = Graph.screen_to_world(state.view, box.x, box.y, canvas)
        local ex, ey = Graph.screen_to_world(state.view, box.x + box.w, box.y + box.h, canvas)
        Selection.box(state, Selection.in_rect(state.layout, {x = wx, y = wy, w = ex - wx, h = ey - wy}),
            drag.base_selection, drag.ctrl)
    end
    state.hover = nil
end

function UI.draw_native(ctx, game, before_overlay)
    if state.undo_confirmation then return false end -- Native modal has visual/input priority over both graph and HUD.
    if state.modal and not before_overlay then return false end
    if not state.active and type(Renderer.draw_undo) ~= 'function' then return false end
    game = game or G
    local target = love.graphics.getCanvas()
    local status = ctx.native_render or {}
    ctx.native_render = status
    status.frame = game.FRAMES and game.FRAMES.DRAW
    status.target_type, status.drawn = type(target), false
    -- LÖVE returns nested render-target descriptors when a stencil attachment is
    -- active. SMODS can unwrap only the outer table. Follow the first colour
    -- attachment, never the depth/stencil attachment.
    for _ = 1, 4 do
        if target == game.CANVAS or type(target) ~= 'table' then break end
        target = target[1]
    end
    status.scene_canvas = game.CANVAS ~= nil and target == game.CANVAS
    if not status.scene_canvas then return false end
    local options = {render_scale = game.CANV_SCALE or 1, native_background = true}
    local ok, result
    if state.active then
        ok, result = pcall(Renderer.draw, ctx, state, Graph, options)
    else
        ok, result = pcall(Renderer.draw_undo, ctx, options)
    end
    if not ok then
        ctx.last_error = text(ctx, '世界线绘制失败：', 'Worldline drawing failed: ') .. tostring(result)
        if sendWarnMessage then sendWarnMessage(ctx.last_error, 'WorldLine') end
        UI.close(ctx, true)
        return false
    end
    if result == false then return false end
    status.drawn = true
    return true
end

function UI.draw_before_overlay(ctx, game)
    if not state.modal then return false end
    local painted = UI.draw_native(ctx,game,true)
    if painted and state.modal then state.modal.presented = true end
    return painted
end

function UI.install(ctx)
    if installed then return end
    installed = true
    G.FUNCS.worldline_open = function()
        state.notice = nil
        if type(ctx.open) == 'function' then return ctx.open() end
        return UI.open(ctx)
    end
    G.FUNCS.worldline_undo = function() return UI.undo(ctx, 'native button') end
    G.FUNCS.worldline_confirm_continuous_undo = function() return UI.confirm_continuous_undo(ctx) end
    G.FUNCS.worldline_cancel_continuous_undo = function() return UI.cancel_undo_confirmation(ctx) end
    G.FUNCS.worldline_can_undo = function(e)
        local available, reason = UI.can_undo(ctx)
        e.config.button = available and 'worldline_undo' or nil
        e.config.colour = available and G.C.BLUE
            or G.C.UI.BACKGROUND_INACTIVE or G.C.GREY or G.C.BLUE
        e.config.worldline_disabled_reason = reason
    end
    G.FUNCS.worldline_close = function(_, immediate)
        UI.close(ctx, immediate == true or state.native_overlay)
        if state.native_overlay then G.FUNCS.exit_overlay_menu() end
    end
    G.FUNCS.worldline_back = function() return UI.open(ctx) end
    G.FUNCS.worldline_name_save = function() return UI.submit_name(ctx) end
    G.FUNCS.worldline_name_cancel = function() return UI.cancel_name(ctx) end
    G.FUNCS.worldline_manage_back = function()
        local back=state.manage_return
        state.management_confirm,state.manage_return=nil,nil
        if back then return back() end
        return UI.open(ctx,true)
    end
    G.FUNCS.worldline_management_enabled = function(e)
        local data=e.config.ref_table or {}
        if data.disabled or ctx.busy or ctx.restoring then
            e.config.button=nil
            e.config.colour=G.C.UI.BACKGROUND_INACTIVE or G.C.GREY or G.C.BLUE
        end
    end
    G.FUNCS.worldline_settings = function() return UI.settings(ctx) end
    G.FUNCS.worldline_record_video=function() return UI.record_video(ctx) end
    G.FUNCS.worldline_film_cancel=function() if ctx.film_runtime then ctx.film_runtime:cancel() end end
    local cycles={speed={0.25,0.5,1,2,4,8},fps={30,60},height={720,1080,1440},pause_seconds={0.5,1,1.5,2,3,5},action_delay={0,0.35,0.75,1,2}}
    for key,values in pairs(cycles) do
        G.FUNCS['worldline_film_'..key]=function(args)
            local ok,err=invoke(ctx,'set_film_option',key,values[args.to_key])
            if key=='height' then local f=state.film_form;UI.record_video(ctx,f.first,f.last,err) end
            return ok,err
        end
    end
    G.FUNCS.worldline_film_selected=function()
        local ids=state.compare_ids
        if ids and #ids==2 then return UI.record_video(ctx,ids[1],ids[2]) end
        return UI.record_video(ctx,nil,nil,text(ctx,nil,'Select two points on one route'))
    end
    G.FUNCS.worldline_film_endpoint=function(e)
        local form,key=state.film_form,e.config.ref_table.key
        UI.edit_name(ctx,text(ctx,nil,key=='first' and 'Start point' or 'End point'),tostring(form[key]),function(value)
            local id=tonumber(value)
            if not id or id%1~=0 or not ctx.tree or not ctx.tree:get(id) then return nil,'Unknown branch' end
            form[key]=id;return true
        end)
        local back=function() UI.record_video(ctx,form.first,form.last) end
        state.editor.after_save,state.editor.after_cancel=back,back
    end
    G.FUNCS.worldline_film_path=function()
        local form=state.film_form
        UI.edit_name(ctx,text(ctx,nil,'FFmpeg path'),ctx.film_options().ffmpeg,
            function(value) return invoke(ctx,'set_film_option','ffmpeg',value) end,
            {limit=2048,prompt=text(ctx,nil,'FFmpeg path')})
        local back=function() UI.record_video(ctx,form.first,form.last) end
        state.editor.after_save,state.editor.after_cancel=back,back
    end
    G.FUNCS.worldline_film_output=function()
        local form=state.film_form
        local current=ctx.film_options().output_dir
        if current=='' then current=love.filesystem.getSaveDirectory()..'/WorldLine/recordings' end
        UI.edit_name(ctx,text(ctx,nil,'Video output directory'),current,
            function(value) return invoke(ctx,'set_film_option','output_dir',value) end,
            {limit=2048,prompt=text(ctx,nil,'Video output directory')})
        local back=function() UI.record_video(ctx,form.first,form.last) end
        state.editor.after_save,state.editor.after_cancel=back,back
    end
    local function browse_path(key)
        local form=state.film_form
        local selected,err=invoke(ctx,'choose_film_path',key,function(_,why,cancelled)
            if not cancelled then UI.record_video(ctx,form.first,form.last,why) end
        end)
        if not selected then UI.record_video(ctx,form.first,form.last,err) end
    end
    G.FUNCS.worldline_film_browse_ffmpeg=function()return browse_path('ffmpeg')end
    G.FUNCS.worldline_film_browse_output=function()return browse_path('output_dir')end
    G.FUNCS.worldline_film_start=function()
        local form=state.film_form
        local value,err=invoke(ctx,'start_film',form.first,form.last)
        if not value then return UI.record_video(ctx,form.first,form.last,err) end
        return value
    end
    G.FUNCS.worldline_resume_recording = function()
        local value,err=invoke(ctx,'resume_recording')
        report(ctx,value,err,text(ctx,nil,'Recording worldline'))
        if value then UI.open(ctx,true); UI.rebuild(ctx,true) else UI.settings(ctx,state.notice) end
    end
    G.FUNCS.worldline_archive_manage = function(e) return UI.manage_archive(ctx,e.config.ref_table.id) end
    G.FUNCS.worldline_archive_select = function(e)
        local item=e.config.ref_table
        return UI.archive_browser(ctx,item.kind,nil,item.id)
    end
    G.FUNCS.worldline_archive_rename = function(e)
        local item=e.config.ref_table
        local back=function()
            if item.node_id then UI.manage_node(ctx,item.node_id) else UI.manage_archive(ctx,item.id) end
        end
        UI.edit_name(ctx,text(ctx,nil,'Rename'),item.name or item.seed or '',
            function(value) return invoke(ctx,'rename_archive',item.id,value) end)
        state.editor.after_save,state.editor.after_cancel=back,back
    end
    G.FUNCS.worldline_branch_export = function(e)
        local id=e.config.ref_table.id
        local value,err=invoke(ctx,'export_branch',id)
        report(ctx,value,err,text(ctx,nil,'Share exported'))
        UI.manage_node(ctx,id)
    end
    G.FUNCS.worldline_branch_delete = function(e) return UI.confirm_delete(ctx,'branch',e.config.ref_table.id) end
    G.FUNCS.worldline_archive_delete = function(e) return UI.confirm_delete(ctx,'archive',e.config.ref_table.id) end
    G.FUNCS.worldline_confirm_delete = function(e)
        local pending=state.management_confirm
        if not pending or not e or not e.config or e.config.ref_table~=pending
            or G.OVERLAY_MENU~=pending.overlay then return false end
        state.management_confirm,state.manage_return=nil,nil
        if pending.tree~=ctx.tree then
            report(ctx,nil,text(ctx,nil,'Worldline changed; reopen this editor'))
            return pending.back()
        end
        local value,err=invoke(ctx,pending.kind=='branch' and 'delete_branch' or 'delete_archive',pending.id,pending.token)
        report(ctx,value,err,text(ctx,nil,'Deleted'))
        if not value then return pending.back() end
        if pending.kind=='branch' then UI.open(ctx,true); UI.rebuild(ctx,true)
        else UI.archives(ctx) end
        return true
    end
    G.FUNCS.worldline_backups = function() return UI.backups(ctx) end
    G.FUNCS.worldline_backup_page = function(e) return UI.backups(ctx,e.config.ref_table.page) end
    G.FUNCS.worldline_backup_restore = function(e)
        local value,err=invoke(ctx,'restore_backup',e.config.ref_table.id)
        report(ctx,value and true,err,text(ctx,nil,'Backup restored'))
        if value then UI.archives(ctx,nil,type(value)=='string' and value or nil) else UI.backups(ctx) end
    end
    G.FUNCS.worldline_navigation_page = function(e)
        local data = e.config.ref_table; UI.navigation(ctx, data.kind, data.page)
    end
    G.FUNCS.worldline_navigation_goto = function(e)
        local id = e.config.ref_table.id
        if ctx.reveal_node then ctx.reveal_node(id) end
        UI.open(ctx, true); UI.rebuild(ctx, true); UI.detail(ctx, id)
        Graph.focus_node(state.view, state.layout.by_id[id], Renderer.geometry(state).canvas)
    end
    G.FUNCS.worldline_bookmark_search = function()
        UI.edit_name(ctx, text(ctx, nil, 'Search bookmarks'), state.bookmark_query or '', function(value)
            state.bookmark_query = value
            return true
        end)
        state.editor.after_save = function() UI.navigation(ctx, 'bookmarks') end
    end
    G.FUNCS.worldline_bookmark_edit = function(e)
        local item = e.config.ref_table
        UI.edit_name(ctx, text(ctx, nil, 'Edit bookmark'), item.label or ('#' .. item.id),
            function(value) return ctx.set_bookmark(item.id, value) end)
    end
    G.FUNCS.worldline_bookmark_remove = function(e)
        local ok, err = ctx.remove_bookmark(e.config.ref_table.id)
        report(ctx, ok, err); UI.navigation(ctx, 'bookmarks', state.navigation_page)
    end
    G.FUNCS.worldline_fold_toggle = function(e)
        local ok, err = ctx.toggle_fold(e.config.ref_table.id)
        report(ctx, ok, err); UI.navigation(ctx, 'folds', state.navigation_page)
    end
    G.FUNCS.worldline_fold_remove = function(e)
        local ok, err = ctx.remove_fold(e.config.ref_table.id)
        report(ctx, ok, err); UI.navigation(ctx, 'folds', state.navigation_page)
    end
    G.FUNCS.worldline_node = function(e) return UI.detail(ctx, e.config.ref_table.id) end
    G.FUNCS.worldline_restore = function(e)
        local id = e.config.ref_table.id; Selection.set(state, {id}, id, id); action(ctx, 'restore')
    end
    G.FUNCS.worldline_archives = function() UI.archives(ctx) end
    G.FUNCS.worldline_archive_page = function(e) UI.archives(ctx, e.config.ref_table.page) end
    G.FUNCS.worldline_load_archive = function(e)
        local ok, err = ctx.load_archive(e.config.ref_table.id)
        report(ctx, ok, err, text(ctx, '世界线收束', 'Worldline converged'))
        if ok and (ctx.busy or ctx.restoring) then G.FUNCS.worldline_close() else UI.archives(ctx) end
    end
    local native_exit = G.FUNCS.exit_overlay_menu
    G.FUNCS.exit_overlay_menu = function(...)
        if state.modal then return UI.close_modal(ctx) end
        end_editor()
        state.management_confirm,state.manage_return,state.settings_form=nil,nil,nil
        UI.close(ctx, true)
        state.native_overlay = false
        ctx.ui_view = nil
        return native_exit(...)
    end
    if SMODS and SMODS.Keybind then
        SMODS.Keybind {key = 'open_tree', key_pressed = 'f6', event = 'pressed',
            action = function() return shortcut(ctx, 'Steamodded') end}
    end
    local keypressed = love.keypressed
    love.keypressed = function(key, scancode, isrepeat, ...)
        local ctrl = love.keyboard and love.keyboard.isDown
            and love.keyboard.isDown('lctrl', 'rctrl')
        if state.modal and state.modal.closing then return end
        if state.editor then
            local edit = state.editor
            if key == 'escape' then UI.cancel_name(ctx)
            elseif key == 'return' or key == 'kpenter' then if not edit.composition or edit.composition == '' then UI.submit_name(ctx) end
            elseif ctrl and key == 'a' then edit.select_all = true
            elseif ctrl and key == 'v' and love.system and love.system.getClipboardText then
                local ok, value = pcall(love.system.getClipboardText)
                if ok then edit_insert(edit, value) end
            elseif key == 'backspace' and (not edit.composition or edit.composition == '') then
                if edit.select_all then edit.value, edit.select_all = '', nil
                else edit.value = edit.value:gsub('[%z\1-\127\194-\244][\128-\191]*$', '') end
                edit_display(edit)
            end
            return
        end
        if state.management_confirm then
            if key=='escape' then return G.FUNCS.worldline_manage_back() end
            if (key=='z' or scancode=='z') and ctrl or key=='f6' or scancode=='f6' then return end
            if keypressed then return keypressed(key,scancode,isrepeat,...) end
            return
        end
        if state.undo_confirmation then
            local live = confirmation_live(ctx)
            if G.CONTROLLER and G.CONTROLLER.text_input_hook then
                if not state.active and keypressed then return keypressed(key, scancode, isrepeat, ...) end
                return
            end
            if live then
                if key == 'escape' then UI.cancel_undo_confirmation(ctx)
                elseif (key == 'z' or scancode == 'z') and ctrl and not isrepeat then UI.confirm_continuous_undo(ctx) end
                return
            end
            -- An expired Ctrl+Z starts a fresh two-second prompt below. Every
            -- other event is consumed, so dismissal never acts on the underlay.
            if not ((key == 'z' or scancode == 'z') and ctrl) then return end
        end
        if state.modal then
            if key=='escape' then
                local back = G.FUNCS[state.modal.back_func or 'worldline_back']
                if back then return back() end
                return UI.close_modal(ctx)
            end
            if (key=='z' or scancode=='z') and ctrl or key=='f6' or scancode=='f6' then return end
            if keypressed then return keypressed(key,scancode,isrepeat,...) end
            return
        end
        if closing() and key ~= 'f6' and scancode ~= 'f6' then return end
        if (key == 'z' or scancode == 'z') and ctrl then
            if G.CONTROLLER and G.CONTROLLER.text_input_hook then
                if not state.active and keypressed then return keypressed(key, scancode, isrepeat, ...) end
                return
            end
            if not isrepeat then UI.undo(ctx, 'Ctrl+Z') end
            return
        end
        if key == 'f6' or scancode == 'f6' then
            if not isrepeat then shortcut(ctx, 'LÖVE') end
            return
        end
        if state.active then
            if key == 'escape' then UI.close(ctx)
            elseif state.drag then return
            elseif key == '=' or key == '+' or key == 'kp+' then action(ctx, 'zoom_in')
            elseif key == '-' or key == 'kp-' then action(ctx, 'zoom_out')
            elseif key == '0' or key == 'home' then action(ctx, 'fit')
            elseif key == 'c' then action(ctx, 'focus')
            elseif key == 'left' then state.view.pan_x = state.view.pan_x + 55
            elseif key == 'right' then state.view.pan_x = state.view.pan_x - 55
            elseif key == 'up' then state.view.pan_y = state.view.pan_y + 55
            elseif key == 'down' then state.view.pan_y = state.view.pan_y - 55 end
            return
        end
        if keypressed then return keypressed(key, scancode, isrepeat, ...) end
    end
    local native_textinput, native_textedited = love.textinput, love.textedited
    love.textinput = function(value, ...)
        if state.editor then edit_insert(state.editor, value); return end
        if native_textinput then return native_textinput(value, ...) end
    end
    love.textedited = function(value, start, length, ...)
        if state.editor then state.editor.composition = value; edit_display(state.editor); return end
        if native_textedited then return native_textedited(value, start, length, ...) end
    end
    -- The native controller also dispatches gamepad presses into the menu that
    -- remains behind the canvas. Keep those from changing the hidden scene.
    for _, name in ipairs({'gamepadpressed', 'joystickpressed'}) do
        local native = love[name]
        love[name] = function(...)
            if state.undo_confirmation then
                local _, key = ...
                if confirmation_live(ctx) and name == 'gamepadpressed' and key == 'b' then UI.cancel_undo_confirmation(ctx) end
                return
            end
            if state.modal then
                if state.modal.closing then return end
                local _, key = ...
                if name=='gamepadpressed' and key=='b' then
                    local back = G.FUNCS[state.modal.back_func or 'worldline_back']
                    if back then return back() end
                    return UI.close_modal(ctx)
                end
                if native then return native(...) end
                return
            end
            if not state.active and native then return native(...) end
        end
    end
    local mousepressed, mousereleased, mousemoved, wheelmoved =
        love.mousepressed, love.mousereleased, love.mousemoved, love.wheelmoved
    love.mousepressed = function(x, y, which, ...)
        if state.undo_confirmation then
            local pending = state.undo_confirmation
            if confirmation_live(ctx) then
                state.confirmation_presses = state.confirmation_presses or {}
                state.confirmation_presses[which] = pending
                if mousepressed then return mousepressed(x, y, which, ...) end
            else state.consumed_buttons[which] = true end
            return
        end
        if state.modal then
            if state.modal.closing then state.consumed_buttons[which]=true; return end
            state.modal_presses = state.modal_presses or {}
            state.modal_presses[which] = {modal=state.modal,overlay=state.modal.overlay}
            if mousepressed then return mousepressed(x,y,which,...) end
            return
        end
        if not state.active then
            state.consumed_buttons[which] = nil
            if which == 1 and type(Renderer.undo_control) == 'function' then
                local control = Renderer.undo_control(ctx)
                if control then
                    -- The native HUD is not part of a closed Worldline's
                    -- transition transform; match draw_undo's plain geometry.
                    local lx, ly = Renderer.to_logical(x, y, Renderer.geometry())
                    if hit(control, lx, ly) then
                        state.undo_press = which
                        if control.enabled~=false then UI.undo(ctx,'HUD button')
                        else
                            local _,reason=UI.can_undo(ctx)
                            reason=reason or text(ctx,'没有可撤回的操作','No action to undo')
                            state.notice,ctx.status=reason,reason
                            if ctx.undo_input_notice then ctx.undo_input_notice(reason)end
                        end
                        return
                    end
                end
            end
            if mousepressed then return mousepressed(x, y, which, ...) end
            return
        end
        -- A press owned by the overlay must keep its release even if the close
        -- animation finishes before the player lets go of the mouse button.
        state.consumed_buttons[which] = true
        if closing() then return end
        if state.drag then return end
        local geometry = Renderer.geometry(state)
        local lx, ly = Renderer.to_logical(x, y, geometry)
        local control = control_at(ctx, geometry, lx, ly)
        if control then
            state.hover = nil
            if which == 1 and control.enabled ~= false then
                if control.key == 'minimap' then
                    begin_minimap_drag(geometry, control, lx, ly)
                else action(ctx, control.key) end
            end
            return
        end
        if geometry.sidebar and hit(geometry.sidebar, lx, ly) then return end
        if hit(geometry.canvas, lx, ly) and (which == 1 or which == 2) then
            local node = Graph.hit_test(state.layout, state.view, lx, ly, geometry.canvas)
            local keyboard = love.keyboard
            state.drag = {kind = which == 1 and 'select' or 'pan',
                start_x = lx, start_y = ly, x = lx, y = ly,
                sidebar_before = geometry.sidebar ~= nil,
                pan_x = state.view.pan_x, pan_y = state.view.pan_y, mapping = canvas_mapping(geometry),
                node = node and node.id, moved = false, button = which,
                ctrl = keyboard and keyboard.isDown and keyboard.isDown('lctrl', 'rctrl') or false,
                shift = keyboard and keyboard.isDown and keyboard.isDown('lshift', 'rshift') or false,
                base_selection = Selection.ids(state)}
            state.hover, state.selection_box = nil, nil
        end
    end
    love.mousemoved = function(x, y, dx, dy, ...)
        if state.undo_confirmation then
            if confirmation_live(ctx) and mousemoved then return mousemoved(x, y, dx, dy, ...) end
            return
        end
        if state.modal then
            if not state.modal.closing and mousemoved then return mousemoved(x,y,dx,dy,...) end
            return
        end
        if not state.active then if mousemoved then return mousemoved(x, y, dx, dy, ...) end; return end
        if closing() then return end
        local geometry = Renderer.geometry(state)
        local lx, ly = Renderer.to_logical(x, y, geometry)
        if state.drag then
            if state.drag.kind == 'minimap' then
                local drag = state.drag
                local map = geometry.minimap or drag.map
                local mapping = minimap_mapping(geometry, map)
                if mapping ~= drag.mapping then
                    drag.x, drag.y, drag.pan_x, drag.pan_y = lx, ly, state.view.pan_x, state.view.pan_y
                    drag.mapping, drag.map = mapping, {x = map.x, y = map.y, w = map.w, h = map.h}
                else
                    state.view.pan_x = drag.pan_x - (lx - drag.x) / map.w * state.layout.width * state.view.scale
                    state.view.pan_y = drag.pan_y - (ly - drag.y) / map.h * state.layout.height * state.view.scale
                end
                state.hover = nil
                return
            end
            move_canvas_gesture(geometry, lx, ly)
            state.hover = nil
            return
        end
        if control_at(ctx, geometry, lx, ly) or geometry.sidebar and hit(geometry.sidebar, lx, ly) then state.hover = nil; return end
        local node = Graph.hit_test(state.layout, state.view, lx, ly, geometry.canvas)
        state.hover = node and node.id
    end
    love.mousereleased = function(x, y, which, ...)
        if state.undo_press == which then state.undo_press = nil; return end
        local pending = state.confirmation_presses and state.confirmation_presses[which]
        if pending then
            state.confirmation_presses[which] = nil
            if pending == state.undo_confirmation and confirmation_live(ctx) and mousereleased then
                return mousereleased(x, y, which, ...)
            end
            return
        end
        if state.undo_confirmation then confirmation_live(ctx); return end
        local owned = state.consumed_buttons[which]
        state.consumed_buttons[which] = nil
        local modal_press = state.modal_presses and state.modal_presses[which]
        if modal_press then
            state.modal_presses[which] = nil
            if not owned and state.modal==modal_press.modal and not state.modal.closing
                and state.modal.overlay==modal_press.overlay and mousereleased then
                return mousereleased(x,y,which,...)
            end
            return
        end
        if state.modal then return end -- Includes the release that opened this dialog.
        if not state.active then
            if not owned and mousereleased then return mousereleased(x, y, which, ...) end
            return
        end
        if closing() then return end
        local drag = state.drag
        if drag and drag.button == which then
            if drag.kind == 'minimap' then state.drag = nil; return end
            local geometry = Renderer.geometry(state)
            local lx, ly = Renderer.to_logical(x, y, geometry)
            move_canvas_gesture(geometry, lx, ly)
            state.drag, state.selection_box = nil, nil
            if not drag.moved and which == 1 then
                if not control_at(ctx, geometry, lx, ly) and hit(geometry.canvas, lx, ly)
                    and not (geometry.sidebar and hit(geometry.sidebar, lx, ly)) then
                    Selection.click(state, drag.node, drag.ctrl, drag.shift, public_tree(ctx), state.layout)
                end
            end
        end
    end
    love.wheelmoved = function(x, y, ...)
        if state.undo_confirmation then confirmation_live(ctx); return end
        if state.modal then
            if not state.modal.closing and wheelmoved then return wheelmoved(x,y,...) end
            return
        end
        if not state.active then if wheelmoved then return wheelmoved(x, y, ...) end; return end
        if closing() then return end
        if state.drag then return end
        if y == 0 then return end
        local layout = state.layout
        if not layout or type(layout.width) ~= 'number' or type(layout.height) ~= 'number'
            or layout.width <= 0 or layout.height <= 0 then return end
        local geometry = Renderer.geometry(state)
        local mx, my = love.mouse.getPosition()
        local lx, ly = Renderer.to_logical(mx, my, geometry)
        if geometry.sidebar and hit(geometry.sidebar, lx, ly) then
            local maximum
            if Renderer.detail_scroll_max then maximum = Renderer.detail_scroll_max(ctx, state)
            else
                local node = state.layout and state.layout.by_id[state.selected]
                local rows = node and Renderer.detail_rows and Renderer.detail_rows(ctx, node.row, state.detail_tab or 'overview')
                maximum = rows and math.max(0, #rows - 6) or state.detail_scroll_max or 0
            end
            state.detail_scroll = math.max(0, math.min(maximum,
                (state.detail_scroll or 0) - (y > 0 and 1 or -1)))
            return
        end
        local control = control_at(ctx, geometry, lx, ly)
        if control then
            if control.key == 'minimap' and control.enabled ~= false and control.w > 0 and control.h > 0 then
                local world_x = (lx - control.x) / control.w * layout.width
                local world_y = (ly - control.y) / control.h * layout.height
                Graph.zoom_world(state.view, 1.15 ^ y, world_x, world_y, geometry.canvas)
            end
            return -- The map/control owns its overlap with the main canvas.
        end
        if hit(geometry.canvas, lx, ly) then
            Graph.zoom(state.view, 1.15 ^ y, lx, ly, geometry.canvas)
        end
    end
    if sendInfoMessage then sendInfoMessage('F6 shortcut installed (LÖVE input with Steamodded fallback)', 'WorldLine') end
    local options = create_UIBox_options
    create_UIBox_options = function(...)
        local definition = options(...)
        local shell = definition and definition.nodes and definition.nodes[1]
        local panel = shell and shell.nodes and shell.nodes[1]
        local content = panel and panel.nodes and panel.nodes[1]
        if content and content.nodes then
            content.nodes[#content.nodes + 1] = button(text(ctx, '世界线 / F6', 'Worldline / F6'), 'worldline_open', nil, 5)
            content.nodes[#content.nodes + 1] = button(text(ctx, '撤回 / Ctrl+Z', 'Undo / Ctrl+Z'),
                'worldline_undo', nil, 5, 'worldline_can_undo')
            content.nodes[#content.nodes + 1] = button(text(ctx,nil,'Worldline settings'),'worldline_settings',nil,5)
        end
        return definition
    end
end

return UI

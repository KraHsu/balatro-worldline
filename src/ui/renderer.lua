-- Balatro assets are borrowed from the running game, never copied into the mod.
-- Drawing creates no Card/UIBox/Sprite and consumes no gameplay or global RNG.
local Renderer = {}
local Loader
if SMODS and SMODS.load_file then
    Loader = assert(SMODS.load_file('loader.lua', 'WorldLine'))()
else
    Loader = dofile('src/loader.lua')
end
local module = Loader.load
local Native, Compositor, Presentation = module('native_visuals'), module('compositor'), module('card_presentation')
local unpack_values = unpack or table.unpack
local C = {
    felt = {0.025, 0.25, 0.205}, felt_dark = {0.018, 0.13, 0.12},
    ink = {0.025, 0.045, 0.055}, cream = {1, 0.96, 0.81},
    paper = {0.93, 0.90, 0.77}, white = {1, 1, 0.94},
    gold = {1, 0.82, 0.24}, selected = {0.38, 0.75, 1}, muted = {0.50, 0.64, 0.60},
    green = {0.025, 0.36, 0.26}, blue = {0.045, 0.30, 0.62},
    red = {0.66, 0.08, 0.13}, grey = {0.22, 0.28, 0.28},
    panel = {0.045, 0.105, 0.125}, border = {0.43, 0.53, 0.55},
}
local quad_cache = setmetatable({}, {__mode = 'k'})
-- Layouts are immutable presentation snapshots. Values contain only IDs and
-- coordinates, never the layout key, rows, tree or game objects; weak keys let
-- replaced layouts be collected even on Lua 5.1.
local path_cache = setmetatable({}, {__mode = 'k'})
local minimap_cache = setmetatable({}, {__mode = 'k'})
local background_shader, background_attempted
local background_palette = {
    {0.025, 0.25, 0.205, 1},
    {0.055, 0.34, 0.27, 1},
    {0.012, 0.09, 0.075, 1},
}
local function tr(ctx, zh, en) return ctx.text and ctx.text(zh, en) or en end
local function public_tree(ctx)
    if type(ctx.has_public_worldline) == 'function' then
        if not ctx.has_public_worldline() then return nil end
    elseif ctx.has_public_worldline == false then return nil end
    return ctx.tree
end
local function native_name(set, key, fallback)
    if key and type(localize) == 'function' then
        local ok, name = pcall(localize, {type = 'name_text', set = set, key = key})
        if ok and type(name) == 'string' and name ~= '' and name ~= 'ERROR' then return name end
    end
    return fallback
end
local function color(g, c, alpha) g.setColor(c[1], c[2], c[3], alpha or 1) end
local function drawing(g, all, fn, ...)
    if all then g.push('all') else g.push() end
    local ok, err = pcall(fn, ...)
    g.pop()
    if not ok then error(err, 0) end
end
local function font_for(g, pixel)
    local font = pixel and G and G.FONTS and G.FONTS[1] and G.FONTS[1].FONT
        or G and G.LANG and G.LANG.font and G.LANG.font.FONT
    return font and font.getHeight and font.getWidth and font or g.getFont()
end
local function text(g, font, value, x, y, size, width, tint, align, shadow)
    value = tostring(value or ''):gsub('[\r\n\t]', ' ')
    local info = G and G.LANG and G.LANG.font
    if G and G.FONTS and G.FONTS[1] and font == G.FONTS[1].FONT then info = G.FONTS[1] end
    local native = info and info.FONT == font and info or nil
    local scale = size / math.max(1, font:getHeight() * (native and native.TEXT_HEIGHT_SCALE or 1))
    local fw = font:getWidth(value)
    if width and fw * scale > width then scale = width / math.max(1, fw) end
    if align == 'center' then x = x + ((width or fw * scale) - fw * scale) / 2 end
    if native and native.TEXT_OFFSET then y = y + (native.TEXT_OFFSET.y or 0) * scale end
    g.setFont(font)
    if shadow then color(g, C.ink, 0.9); g.print(value, x + 2, y + 2, 0, scale, scale) end
    color(g, tint or C.cream); g.print(value, x, y, 0, scale, scale)
end
local function pixel_box(g, mode, x, y, w, h, step)
    step = step or 4
    g.polygon(mode, x + step, y, x + w - step, y, x + w - step, y + step,
        x + w, y + step, x + w, y + h - step, x + w - step, y + h - step,
        x + w - step, y + h, x + step, y + h, x + step, y + h - step,
        x, y + h - step, x, y + step, x + step, y + step)
end
local function bevel(g, x, y, w, h, tint, metal)
    color(g, C.ink); pixel_box(g, 'fill', x + 3, y + 4, w, h, 5)
    color(g, metal and C.border or C.ink); pixel_box(g, 'fill', x, y, w, h, 4)
    color(g, tint); pixel_box(g, 'fill', x + 3, y + 3, w - 6, h - 6, 3)
    color(g, C.white, metal and 0.20 or 0.16)
    g.rectangle('fill', x + 7, y + 3, w - 14, 2)
    color(g, C.ink, 0.45); g.rectangle('fill', x + 6, y + h - 6, w - 12, 3)
end
local function atlas(g, data, pos, x, y, w, h, tint, rotation)
    if not (data and data.image and pos and g.newQuad) then return false end
    local image, px, py = data.image, data.px or 71, data.py or 95
    local iw, ih = image:getDimensions()
    -- Balatro loads 2x images with dpiscale=2: dimensions and quads stay logical.
    local key = tostring(pos.x) .. ':' .. tostring(pos.y) .. ':' .. px .. ':' .. py
    local cache = quad_cache[image]
    if not cache then cache = {}; quad_cache[image] = cache end
    if not cache[key] then cache[key] = g.newQuad(pos.x * px, pos.y * py, px, py, iw, ih) end
    color(g, tint or {1, 1, 1})
    g.draw(image, cache[key], x, y, rotation or 0, w / px, h / py)
    return true
end
local function assets(key) return G and G.ASSET_ATLAS and G.ASSET_ATLAS[key] end
local function animation(key) return G and G.ANIMATION_ATLAS and G.ANIMATION_ATLAS[key] end

function Renderer.geometry(state)
    state = state or {}
    local w, h = state.screen_w, state.screen_h
    if not w then w, h = love.graphics.getDimensions() end
    local scale = math.min(w / 1600, h / 900)
    local progress = state.active ~= false and tonumber(state.transition) or 1
    progress = math.max(0, math.min(1, progress or 1))
    local ease = progress * progress * (3 - 2 * progress)
    local sidebar = state.selected ~= nil
    if state.drag and state.drag.kind=='select' then sidebar=state.drag.sidebar_before==true end
    return {screen_w = w, screen_h = h, ui_scale = scale,
        transition_alpha = ease, transition_scale = G and G.SETTINGS and G.SETTINGS.reduced_motion
            and 1 or 0.97 + 0.03 * ease,
        offset_x = (w - 1600 * scale) / 2, offset_y = (h - 900 * scale) / 2,
        canvas = {x = 70, y = 78, w = sidebar and 1120 or 1460, h = 740},
        sidebar = sidebar and {x = 1230, y = 100, w = 320, h = 680} or nil,
        minimap = {x = 1348, y = 806, w = 220, h = 74}}
end
function Renderer.to_logical(x, y, geometry)
    local scale = geometry.transition_scale or 1
    x = (x - geometry.screen_w / 2) / scale + geometry.screen_w / 2
    y = (y - geometry.screen_h / 2) / scale + geometry.screen_h / 2
    return (x - geometry.offset_x) / geometry.ui_scale, (y - geometry.offset_y) / geometry.ui_scale
end
function Renderer.minimap_viewport(state, geometry, Graph)
    return Native.viewport(state.layout, state.view, geometry.canvas, geometry.minimap, Graph)
end
local function undo_available(ctx)
    if ctx.busy or ctx.restoring or type(ctx.can_undo) ~= 'function' then return false end
    if G and G.CONTROLLER and G.CONTROLLER.text_input_hook then return false end
    local ok, available = pcall(ctx.can_undo)
    return ok and available == true
end
-- Only presentation state lives here: pointer feedback never enters a snapshot,
-- worldline node, game controller, or random stream.
local hover_groups = {}
local function control_feedback(controls, state, geometry, group)
    local hovered, pressed
    local focused = not (love.window and love.window.hasMouseFocus) or love.window.hasMouseFocus()
    if focused and not (state and (state.drag or state.transition_target == 0))
        and love.mouse and love.mouse.getPosition then
        local x, y = love.mouse.getPosition()
        x, y = Renderer.to_logical(x, y, geometry)
        for i = #controls, 1, -1 do
            local c = controls[i]
            if x >= c.x and x <= c.x + c.w and y >= c.y and y <= c.y + c.h then
                if c.enabled then hovered = c.key end
                break -- A disabled top control still occludes the controls below it.
            end
        end
        pressed = hovered and love.mouse.isDown and love.mouse.isDown(1)
    end
    local dt = love.timer and love.timer.getDelta and love.timer.getDelta() or 1 / 60
    local step = math.max(0, math.min(1, (tonumber(dt) or 0) / 0.08))
    local memory = hover_groups[group] or {}
    hover_groups[group] = memory
    local result = {}
    for _, c in ipairs(controls) do
        local value = c.enabled and ((memory[c.key] or 0) + ((hovered == c.key and 1 or 0) - (memory[c.key] or 0)) * step) or 0
        memory[c.key] = value
        result[c.key] = {amount = value, pressed = pressed and hovered == c.key}
    end
    return result
end
function Renderer.undo_control(ctx)
    if not (G and G.STAGES and G.STAGES.RUN and G.STAGE == G.STAGES.RUN) then return nil end
    ctx = ctx or {}
    return {key = 'undo', x = 1484, y = 2, w = 110, h = 27,
        label = 'Ctrl+Z', font_size = 20, enabled = undo_available(ctx)}
end
function Renderer.controls(ctx, state, geometry)
    geometry = geometry or Renderer.geometry(state)
    local live_tree = public_tree(ctx)
    local tree, available = live_tree ~= nil, not ctx.busy and not ctx.restoring
    local nodes = tree and state.layout and #state.layout.nodes > 0
    local result = {}
    local function add(key, x, y, w, h, label, enabled)
        result[#result + 1] = {key = key, x = x, y = y, w = w, h = h, label = label,
            enabled = enabled ~= false, selected = key == 'tab_' .. (state.detail_tab or 'overview')}
    end
    add('save', 350, 840, 85, 38, tr(ctx, '保存', 'SAVE'), tree and available)
    add('export', 443, 840, 85, 38, tr(ctx, '导出', 'EXPORT'), tree and available)
    add('import', 536, 840, 85, 38, tr(ctx, '导入', 'IMPORT'), available)
    add('archives', 629, 840, 110, 38, tr(ctx, '存档', 'ARCHIVES'), available)
    add('folder', 747, 840, 115, 38, tr(ctx, '文件夹', 'FOLDER'), available)
    add('undo', 885, 840, 115, 38, tr(ctx, '撤回', 'UNDO'), available and undo_available(ctx))
    add('record_video',1010,840,130,38,tr(ctx,nil,'Record video'),tree and available)
    add('bookmarks', 620, 20, 170, 40, tr(ctx, '书签', 'BOOKMARKS'), tree and available)
    add('folds', 800, 20, 170, 40, tr(ctx, '折叠区域', 'FOLDS'), tree and available)
    add('fit', 990, 20, 115, 40, tr(ctx, '全图', 'FIT'), nodes)
    add('focus', 1115, 20, 115, 40, tr(ctx, '当前', 'CURRENT'), nodes and tree)
    add('zoom_out', 1244, 20, 40, 40, '-', nodes)
    add('zoom_in', 1404, 20, 40, 40, '+', nodes)
    add('close', 1518, 18, 50, 45, 'X', true)
    if geometry.sidebar and tree then
        local tabs={{'overview',tr(ctx,nil,'Overview')},{'choices',tr(ctx,nil,'Choices')},{'cards',tr(ctx,nil,'Inventory')}}
        if state.compare_ids and #state.compare_ids==2 then tabs[#tabs+1]={'diff',tr(ctx,nil,'Comparison')} end
        local width=#tabs==4 and 67 or 90
        for index,tab in ipairs(tabs) do add('tab_'..tab[1],1246+(index-1)*(width+6),190,width,32,tab[2],true) end
        local selected = state.layout and state.layout.by_id[state.selected]
        local maximum = Renderer.detail_scroll_max(ctx,state)
        if maximum > 0 then
            local first = math.max(0, math.min(maximum, state.detail_scroll or 0))
            add('detail_up', 1254, 534, 30, 25, '^', first > 0)
            add('detail_down', 1496, 534, 30, 25, 'v', first < maximum)
        end
        if state.compare_ids and #state.compare_ids==2 then add('swap_compare',1480,164,48,24,'<>',true) end
        add('bookmark', 1254, 578, 130, 34, tr(ctx, nil, 'BOOKMARKS'), available)
        add('manage', 1394, 578, 132, 34, tr(ctx, nil, 'Manage'), available)
        add('fold_suworldline', 1254, 620, 130, 34, tr(ctx, '折叠后续', 'Fold future'), available)
        add('fold_range', 1394, 620, 132, 34,
            state.compare_ids and #state.compare_ids==2 and tr(ctx, nil, 'Folded region')
                or state.fold_start and tr(ctx, '完成区域', 'Finish region') or tr(ctx, '区域起点', 'Start region'), available)
        if state.fold_start then add('cancel_region', 1254, 662, 272, 30, tr(ctx, '取消区域选择', 'Cancel region'), true)
        else add('expand', 1254, 662, 272, 30, tr(ctx, '展开此处', 'Expand here'), available) end
        local at_current = state.at_current_node
        if at_current == nil and type(ctx.at_current_node) == 'boolean' then at_current = ctx.at_current_node end
        local same = state.selected == live_tree.current and not ctx.detached and at_current == true
        add('restore', 1254, 704, 272, 50,
            same and tr(ctx, '已在此收束点', 'YOU ARE HERE') or tr(ctx, '收束到此', 'CONVERGE HERE'),
            tree and state.selected ~= nil and available and not same)
    end
    local m = geometry.minimap
    add('minimap', m.x, m.y, m.w, m.h, '', nodes)
    return result
end
local function phase(ctx, node)
    local a, s = node.row.action or {}, node.row.summary or {}
    if a.kind == 'start' or node.parent == 0 then return tr(ctx, '起点', 'START'), C.ink, 'start' end
    if s.state == 'SHOP' or not s.state and a.kind == 'enter_shop' then return tr(ctx, '商店', 'SHOP'), C.green, 'shop' end
    if s.state == 'BLIND_SELECT' or not s.state and (a.kind == 'leave_shop' or a.kind == 'skip_blind') then
        return tr(ctx, '盲注选择', 'Blind selection'), C.grey, 'choose'
    end
    if s.state == 'ROUND_EVAL' then return tr(ctx, '结算', 'Round result'), C.green, 'shop' end
    if s.state == 'GAME_OVER' or a.kind == 'run_failed' then return tr(ctx, '世界线终止', 'WORLDLINE ENDED'), C.red, 'failed' end
    if s.state and s.state:find('PACK', 1, true) or s.state == 'SMODS_BOOSTER_OPENED' then
        return tr(ctx, '卡包', 'Booster pack'), C.blue, 'choose'
    end
    local blind = a.blind or {}
    local key = tostring(blind.key or s.blind_key or '')
    if key:find('small', 1, true) then return tr(ctx, '小盲注', 'SMALL BLIND'), C.blue, 'small' end
    if key:find('big', 1, true) then return tr(ctx, '大盲注', 'BIG BLIND'), C.red, 'big' end
    return native_name('Blind', key, blind.name or s.blind_name or tr(ctx, '挑战盲注', 'BLIND')), C.red, 'boss'
end
local function spade(g, x, y, size)
    g.polygon('fill', x, y - size, x + size, y, x + size, y + size * 0.4,
        x + size * 0.3, y + size * 0.65, x, y + size * 0.2,
        x - size * 0.3, y + size * 0.65, x - size, y + size * 0.4, x - size, y)
    g.rectangle('fill', x - size * 0.2, y + size * 0.25, size * 0.4, size * 0.75)
    g.rectangle('fill', x - size * 0.45, y + size * 0.85, size * 0.9, size * 0.2)
end
local function chip_icon(g, font, ctx, node, kind, tint, x, y, size)
    local action, summary = node.row.action or {}, node.row.summary or {}
    Native.chip(g, kind, x, y, size, {blind_key = action.blind and action.blind.key or summary.blind_key})
end
local function joker(g, item, x, y, w, h)
    local center = G and G.P_CENTERS and G.P_CENTERS[item.key]
    local data = assets(item.atlas or center and center.atlas or 'Joker')
    local pos = item.pos or center and center.pos
    if atlas(g, data, pos, x, y, w, h) then return end
    -- A missing object uses the game's undiscovered Joker, not invented artwork.
    if atlas(g, assets('centers'), {x = 5, y = 3}, x, y, w, h) then return end
    color(g, C.border); pixel_box(g, 'line', x, y, w, h, 2)
end
local CARD_H = 190 * 95 / 71
local function draw_node(g, font, ctx, state, node, path)
    local s = node.row.summary or {}
    local title, tint, kind = phase(ctx, node)
    g.translate(node.x, node.y); g.scale(node.w / 190, node.h / CARD_H)
    local tree = public_tree(ctx)
    local current = tree and tree.current == node.id
    local selected, hovered = (state.selections and state.selections[node.id]) or state.selected == node.id, state.hover == node.id
    if not Native.card_shell(g, 0, 0, 190, CARD_H, {selected = selected, current = current,
        hover = hovered, highlight = current and C.gold or selected and C.selected or C.white}) then
        color(g, C.white); pixel_box(g, 'fill', 0, 0, 190, CARD_H, 5)
    end
    bevel(g, 15, 14, 160, 32, tint)
    text(g, font, title, 21, 15, 25, 148, C.white, 'center', true)
    chip_icon(g, font, ctx, node, kind, tint, 95, 85, 62)
    text(g, font, tr(ctx, '底注 ', 'ANTE ') .. tostring(s.ante or '-'), 14, 118, 22, 162, C.ink, 'center')
    if node.row.bookmark then
        color(g, C.red); g.polygon('fill', 158, 0, 176, 0, 176, 17, 167, 12, 158, 17)
    end
    bevel(g, 15, 149, 160, 32, C.panel)
    text(g, font_for(g, true), '$' .. tostring(s.dollars or s.money or '-'), 22, 148, 28, 146, C.gold, 'center', true)
    local jokers = s.jokers or {}
    if kind == 'start' then
        bevel(g, 15, 199, 160, 32, C.red)
        text(g, font_for(g, true), tree and tree.metadata.seed or '-', 20, 199, 28, 150, C.white, 'center', true)
    elseif #jokers > 0 then
        local count, gap = math.min(5, #jokers), 4
        local w = math.min(44, (160 - (count - 1) * gap) / count)
        local h, x = w * 95 / 71, (190 - count * w - (count - 1) * gap) / 2
        for i = 1, count do joker(g, jokers[i], x + (i - 1) * (w + gap), 245 - h, w, h) end
    else
        color(g, C.ink, 0.11); pixel_box(g, 'fill', 15, 202, 160, 30, 3)
        text(g, font_for(g, true), '0', 20, 201, 28, 150, C.grey, 'center')
    end
    if not path[node.id] and not selected and not hovered then
        color(g, C.ink, 0.20); pixel_box(g, 'fill', 1, 1, 188, CARD_H - 2, 5)
    end
end
local function current_path(ctx, layout)
    local tree = public_tree(ctx)
    local current = tree and tree.current
    local cached = path_cache[layout]
    if cached and cached.current == current then return cached.path end
    local result, id = {}, current
    while id and id ~= 0 and not result[id] do
        result[id] = true
        local node = layout.by_id[id]
        local hidden = not node and tree and tree.get and tree:get(id)
        id = node and node.parent or hidden and hidden.parent
    end
    path_cache[layout] = {current = current, path = result}
    return result
end
local function draw_button(g, font, c, feedback)
    if c.key == 'minimap' then return end
    feedback = feedback or {}
    local amount = c.enabled and feedback.amount or 0
    local base = c.key == 'restore' and C.red or c.selected and C.green or C.panel
    local tint = {}
    for i = 1, 3 do tint[i] = base[i] + (1 - base[i]) * amount * 0.18 end
    local y = c.y - amount * (feedback.pressed and 0.5 or 3)
    bevel(g, c.x, y, c.w, c.h, c.enabled and tint or C.felt_dark, c.key ~= 'restore')
    if amount > 0.01 then
        color(g, C.cream, amount * 0.8); g.setLineWidth(1)
        pixel_box(g, 'line', c.x + 1, y + 1, c.w - 2, c.h - 2, 4)
    end
    if c.key == 'detail_up' or c.key == 'detail_down' then
        Native.arrow(g,c.x+c.w/2,y+c.h/2,12,7,c.key=='detail_up' and 'up' or 'down',c.enabled and C.cream or C.muted)
        return
    end
    if c.key=='swap_compare' then
        color(g,C.cream);g.setLineWidth(2)
        local x,y=c.x+c.w/2,y+c.h/2
        g.line(x-10,y-4,x+9,y-4);g.polygon('fill',x+10,y-4,x+5,y-8,x+5,y)
        g.line(x+10,y+4,x-9,y+4);g.polygon('fill',x-10,y+4,x-5,y,x-5,y+8)
        return
    end
    local face = c.label:find('[\128-\255]') and font or font_for(g, true)
    text(g, face, c.label, c.x + 7, y + 4, c.font_size or 25, c.w - 14,
        c.enabled and (amount > 0.1 and C.white or C.cream) or C.muted, 'center', true)
end
function Renderer.draw_undo(ctx, options)
    local control = Renderer.undo_control(ctx)
    if not control then return false end
    local g, geometry = love.graphics, Renderer.geometry()
    local render_scale = options and options.render_scale or 1
    local feedback = control_feedback({control}, nil, geometry, 'hud')
    drawing(g, true, function()
        g.origin(); g.setShader(); g.setScissor()
        if g.setStencilTest then g.setStencilTest() end
        g.scale(render_scale)
        g.translate(geometry.offset_x, geometry.offset_y); g.scale(geometry.ui_scale)
        draw_button(g, font_for(g), control, feedback[control.key])
        local notice=ctx.undo_notice
        if notice and love.timer and love.timer.getTime()<notice.until_time then
            local width=720
            bevel(g,control.x-width-12,control.y,width,32,C.panel)
            text(g,font_for(g),notice.text,control.x-width-5,control.y+5,18,width-14,C.cream,'center')
        end
    end)
    return true
end
local detail_cache
local choice_labels = {buy = 'Buy', sell = 'Sell', reroll_shop = 'Reroll shop',
    use = 'Use / open / take', skip_booster = 'Skip pack', play = 'Play hand', discard = 'Discard',
    select_blind = 'Select blind', skip_blind = 'Skip blind', enter_shop = 'Cash out',
    leave_shop = 'Leave shop', reroll_boss = 'Reroll boss'}
local function item_name(item)
    return native_name(item.set or 'Joker', item.card_key or item.key, item.name or item.card_key or item.key or '-')
end
local function choice_name(ctx, item)
    local label = tr(ctx, nil, choice_labels[item.kind] or item.label or item.kind or 'Choices')
    local name = item.card_key and item_name(item)
    if name then label = label .. ' / ' .. name end
    if (item.count or 1) > 1 then label = label .. ' x' .. item.count end
    return label
end
function Renderer.detail_rows(ctx, row, tab)
    local locale = G and G.SETTINGS and G.SETTINGS.language or 'en-us'
    local cached = detail_cache
    if not cached or cached.row ~= row or cached.locale ~= locale or cached.translate ~= ctx.text or cached.localize ~= localize then
        cached = {row = row, locale = locale, translate = ctx.text, localize = localize}; detail_cache = cached
    end
    if cached[tab] then return cached[tab] end
    local s, result = (type(ctx.node_details) == 'function' and ctx.node_details(row.id)) or row.summary or {}, {}
    local font = love and love.graphics and font_for(love.graphics)
    local function wrap(value, size, width)
        value = tostring(value or '')
        if not font then return {value} end
        local info = G and G.LANG and G.LANG.font
        local height = font:getHeight() * (info and info.FONT == font and info.TEXT_HEIGHT_SCALE or 1)
        local lines, line = {}, ''
        for char in value:gmatch('[%z\1-\127\194-\244][\128-\191]*') do
            if line ~= '' and font:getWidth(line .. char) * size / math.max(1, height) > width then
                lines[#lines + 1], line = line, ''
            end
            line = line .. char
        end
        lines[#lines + 1] = line
        return lines
    end
    local function add(label, value, card)
        value = tostring(value == nil and '-' or value)
        local width = card and 233 or 274
        local labels, values = wrap(label, 18, width), wrap(value, 22, width)
        if #labels == 1 and #values == 1 then
            result[#result + 1] = {label = label, value = value, card = card}
            return
        end
        local lines = {}
        for _, line in ipairs(labels) do lines[#lines + 1] = {text=line, size=18, tint=C.muted} end
        for _, line in ipairs(values) do lines[#lines + 1] = {text=line, size=22, tint=C.cream} end
        for i = 1, #lines, 2 do
            result[#result + 1] = {lines={lines[i], lines[i + 1]}, card=i==1 and card or nil}
        end
    end
    if tab == 'choices' then
        local choices = row.action and row.action.choices
        if choices and #choices > 0 then
            for i, item in ipairs(choices) do
                local extra = {}
                if item.cost ~= nil then extra[#extra + 1] = tr(ctx, nil, 'Price') .. ' $' .. tostring(item.cost) end
                if item.money_delta ~= nil then extra[#extra + 1] = tr(ctx, nil, 'Money change') .. ' '
                    .. (item.money_delta >= 0 and '+' or '') .. tostring(item.money_delta) end
                if item.cards_count then extra[#extra + 1] = tr(ctx, nil, 'Cards') .. ' ' .. item.cards_count end
                add(tostring(i) .. '. ' .. choice_name(ctx, item), table.concat(extra, ' / '))
            end
        else
            add(tr(ctx, nil, 'Choices'), tr(ctx, nil, 'No recorded choices'))
            if row.action and row.action.label then add(tr(ctx, nil, 'Stage transition'), row.action.label) end
        end
    elseif tab == 'cards' then
        local function inventory(name, list, card_art)
            add(tr(ctx, nil, name), list and tostring(#list) or '-')
            for _, item in ipairs(list or {}) do
                local extra = {}
                if item.edition then
                    if type(item.edition) == 'table' then
                        for _, key in ipairs({'negative','polychrome','holo','foil'}) do
                            if item.edition[key] then extra[#extra + 1] = native_name('Edition', 'e_' .. key, key) end
                        end
                    elseif type(item.edition) == 'string' then extra[#extra + 1] = native_name('Edition', item.edition, item.edition) end
                end
                if item.sell_cost ~= nil then extra[#extra + 1] = tr(ctx, nil, 'Sell value') .. ' $' .. item.sell_cost end
                if item.seal then extra[#extra + 1] = tostring(item.seal) end
                add(item_name(item), table.concat(extra, ' / '), card_art and item or nil)
            end
        end
        inventory('JOKERS ', s.jokers, true)
        inventory('Consumables', s.consumables or s.consumeables, true)
        inventory('Vouchers', s.vouchers, true)
        inventory('Tags', s.tags, false)
        if s.deck_stats then
            local d = s.deck_stats
            add(tr(ctx, nil, 'Deck composition'), d.total or s.total_cards)
            for _, suit in ipairs({'Spades', 'Hearts', 'Clubs', 'Diamonds'}) do
                local label = suit
                if type(localize) == 'function' then
                    local ok, value = pcall(localize, suit, 'suits_plural')
                    if ok and type(value) == 'string' then label = value end
                end
                add(label, d.suits and d.suits[suit])
            end
            add(tr(ctx, nil, 'Enhanced / editions / seals'), tostring(d.enhanced or '-') .. ' / '
                .. tostring(d.editions or '-') .. ' / ' .. tostring(d.seals or '-'))
        end
        if s.hand_levels then
            add(tr(ctx, nil, 'Poker hands'), tr(ctx, nil, 'Level / chips / mult'))
            for _, hand in ipairs(s.hand_levels) do
                local label = hand.name or hand.key or '-'
                if type(localize) == 'function' then
                    local ok, value = pcall(localize, hand.key, 'poker_hands')
                    if ok and type(value) == 'string' then label = value end
                end
                add(label, tostring(hand.level or '-') .. ' / ' .. tostring(hand.chips or '-')
                    .. ' / ' .. tostring(hand.mult or '-'))
            end
        end
    else
        add(tr(ctx, nil, 'ANTE / ROUND'), tostring(s.ante or '-') .. ' / ' .. tostring(s.round or '-'))
        add(tr(ctx, nil, 'MONEY'), '$' .. tostring(s.dollars or s.money or '-'))
        add(tr(ctx, nil, 'Hands / discards left'), tostring(s.hands_left or '-') .. ' / ' .. tostring(s.discards_left or '-'))
        add(tr(ctx, nil, 'Hand / deck / discard'), tostring(s.hand_count or '-') .. ' / ' .. tostring(s.deck_count or '-') .. ' / ' .. tostring(s.discard_count or '-'))
        add(tr(ctx, nil, 'Score / target'), tostring(s.chips or s.score or '-') .. ' / ' .. tostring(s.target_score or s.blind_chips or s.blind_target or '-'))
        add(tr(ctx, nil, 'DECK'), native_name('Back', s.deck, s.deck_name or s.deck or '-'))
        add(tr(ctx, nil, 'STAKE'), s.stake_name or s.stake or '-')
        add(tr(ctx, nil, 'BLIND'), native_name('Blind', s.blind_key, s.blind_name or '-'))
        add(tr(ctx, nil, 'JOKERS '), tostring(s.joker_count or (s.jokers and #s.jokers) or '-') .. ' / ' .. tostring(s.joker_limit or '-'))
        add(tr(ctx, nil, 'Consumables'), tostring((s.consumables and #s.consumables) or (s.consumeables and #s.consumeables) or '-') .. ' / ' .. tostring(s.consumable_limit or '-'))
        add(tr(ctx, nil, 'Reroll price'), s.reroll_cost ~= nil and '$' .. tostring(s.reroll_cost) or '-')
        if row.bookmark then add(tr(ctx, nil, 'BOOKMARKS'), row.bookmark) end
        if (row.collapsed_count or 0) > 0 then add(tr(ctx, nil, 'Hidden points'), row.collapsed_count) end
    end
    cached[tab] = result
    return result
end
local panel_cache, compare_cache
local metric_labels={dollars='MONEY',ante='ANTE ',round='ROUND ',hands_left='Hands left',discards_left='Discards left',
 hand_count='HAND',deck_count='DECK',discard_count='DISCARD',score='Score',target_score='Target',joker_limit='JOKERS ',
 consumable_limit='Consumables',reroll_cost='Reroll price',stake='STAKE',total_cards='Playing cards'}
local group_labels={jokers='JOKERS ',consumables='Consumables',vouchers='Vouchers',tags='Tags',playing_cards='Playing cards',
 shop_jokers='Shop offers',shop_vouchers='Shop offers',shop_booster='Shop offers',pack_cards='Booster pack'}
local function comparison(ctx,state)
    local ids=state.compare_ids
    if not(ids and #ids==2 and ctx.compare_nodes) then return nil end
    local locale=G and G.SETTINGS and G.SETTINGS.language
    local tree=public_tree(ctx)
    if not compare_cache or compare_cache.tree~=tree or compare_cache.a~=ids[1] or compare_cache.b~=ids[2]
        or compare_cache.locale~=locale or compare_cache.revision~=(tree and tree.structure_revision) then
        compare_cache={tree=tree,a=ids[1],b=ids[2],locale=locale,revision=tree and tree.structure_revision,
            data=ctx.compare_nodes(ids[1],ids[2])}
    end
    return compare_cache.data
end
local function panel_model(ctx,state)
    local node=state.layout and state.layout.by_id[state.selected]
    if not node then return nil end
    local locale=G and G.SETTINGS and G.SETTINGS.language
    local tab=state.detail_tab or 'overview'
    local compare=tab=='diff' and comparison(ctx,state)
    if panel_cache and panel_cache.row==node.row and panel_cache.locale==locale and panel_cache.tab==tab
        and panel_cache.compare==compare and panel_cache.provider==ctx.node_details then return panel_cache end
    local summary=(ctx.node_details and ctx.node_details(node.id)) or node.row.summary or {}
    local model={row=node.row,node_id=node.id,summary=summary,locale=locale,tab=tab,compare=compare,provider=ctx.node_details,
        items={},metrics={}}
    if tab=='diff' and compare then
        for _,group in ipairs(compare.groups or {}) do for _,change in ipairs(group.changes or {}) do
            model.items[#model.items+1]={group=group.key,change=change}
        end end
        for _,entry in ipairs(compare.metrics or {}) do model.metrics[#model.metrics+1]=entry end
        for _,pair in ipairs(compare.hand_levels or {}) do
            for _,field in ipairs({'level','chips','mult'}) do
                local before,after=pair.before and pair.before[field],pair.after and pair.after[field]
                if before~=after then
                    local label=pair.after and pair.after.name or pair.before and pair.before.name or pair.key
                    local term=field
                    if type(localize)=='function' then
                        local ok,value=pcall(localize,field=='level' and 'k_level_prefix' or 'k_'..field)
                        if ok and type(value)=='string' and value~='ERROR' then term=value end
                    end
                    model.metrics[#model.metrics+1]={label=label..' / '..term,before=before,after=after}
                end
            end
        end
        if compare.choices and not compare.choices.same then model.metrics[#model.metrics+1]={label=tr(ctx,nil,'Choices'),
            before=#(compare.choices.before or {}),after=#(compare.choices.after or {})} end
        model.pages=math.max(1,math.ceil(#model.items/2),math.ceil(#model.metrics/4))
    elseif tab=='cards' then
        for _,group in ipairs({'jokers','consumables','vouchers','tags','playing_cards','shop_jokers','shop_vouchers','shop_booster','pack_cards'}) do
            for _,item in ipairs(summary[group] or {}) do model.items[#model.items+1]={group=group,item=item} end
        end
        model.pages=math.max(1,math.ceil(#model.items/6))
    elseif tab=='choices' then
        for _,item in ipairs(node.row.action and node.row.action.choices or {}) do model.items[#model.items+1]={group='choices',item=item} end
        model.pages=math.max(1,math.ceil(#model.items/6))
    else
        for _,key in ipairs({'dollars','hands_left','discards_left','score','target_score','reroll_cost','ante','round','stake',
            'hand_count','deck_count','discard_count','joker_limit','consumable_limit','total_cards'}) do
            model.metrics[#model.metrics+1]={key=key,value=summary[key]}
        end
        if summary.deck then model.items[#model.items+1]={group='deck',item={key=summary.deck,set='Back',name=summary.deck_name}} end
        for _,hand in ipairs(summary.hand_levels or {}) do model.metrics[#model.metrics+1]={key='hand_level',hand=hand} end
        for _,item in ipairs(summary.jokers or {}) do model.items[#model.items+1]={group='jokers',item=item} end
        for _,item in ipairs(summary.consumables or {}) do model.items[#model.items+1]={group='consumables',item=item} end
        model.pages=math.max(1,math.ceil(#model.metrics/6))
    end
    panel_cache=model
    return model
end
function Renderer.detail_scroll_max(ctx,state)
    local model=panel_model(ctx,state)
    return model and model.pages-1 or 0
end
function Renderer.card_targets(ctx,state,geometry)
    local model=panel_model(ctx,state)
    if not model or not geometry.sidebar then return {} end
    local page=math.max(0,math.min(model.pages-1,state.detail_scroll or 0))
    if model.targets and model.target_page==page then return model.targets end
    local targets={};local p=geometry.sidebar
    local function add(item,x,y,w,h,group,side,status,summary,index)
        if not item then return end
        targets[#targets+1]={item=item,x=x,y=y,w=w,h=h,group=group,side=side,status=status,
            details=summary or model.summary,key=tostring(side or '')..':'..tostring(index or #targets+1),
            node_id=side and model.compare and (side=='before' and model.compare.before_id or model.compare.after_id) or model.node_id}
    end
    if model.tab=='diff' and model.compare then
        for i=page*2+1,math.min(#model.items,page*2+2) do
            local entry=model.items[i];local y=337+(i-page*2-1)*99
            add(entry.change.before,p.x+44,y,65,87,entry.group,'before',entry.change.kind,model.compare.before,i)
            add(entry.change.after,p.x+208,y,65,87,entry.group,'after',entry.change.kind,model.compare.after,i)
        end
    elseif model.tab=='cards' or model.tab=='choices' then
        for i=page*6+1,math.min(#model.items,page*6+6) do
            local offset=i-page*6-1;local entry=model.items[i]
            add(entry.item,p.x+24+(offset%3)*93,251+math.floor(offset/3)*135,71,95,entry.group,nil,nil,model.summary,i)
        end
    else
        for i=1,math.min(4,#model.items) do
            local entry=model.items[i];add(entry.item,p.x+22+(i-1)*72,445,57,76,entry.group,nil,nil,model.summary,i)
        end
    end
    model.targets,model.target_page=targets,page
    return targets
end
local function hover_target(ctx,state,geometry)
    if state.drag or state.selection_box or state.transition_target==0 or not(love.mouse and love.mouse.getPosition) then return nil end
    local x,y=love.mouse.getPosition();x,y=Renderer.to_logical(x,y,geometry)
    for _,target in ipairs(Renderer.card_targets(ctx,state,geometry)) do
        if x>=target.x and x<=target.x+target.w and y>=target.y and y<=target.y+target.h then return target end
    end
end
local function metric(g,font,ctx,key,value,x,y,w,h)
    bevel(g,x,y,w,h,C.felt_dark,true)
    text(g,font,tr(ctx,nil,metric_labels[key] or key),x+7,y+4,16,w-14,C.muted,'center')
    local display=value==nil and '-' or tostring(value)
    if key=='dollars' or key=='reroll_cost' then display=value==nil and '-' or '$'..display end
    text(g,font_for(g,true),display,x+8,y+24,28,w-16,key=='dollars' and C.gold or C.cream,'center')
end
local function detail(g,font,ctx,state,geometry)
    local p=geometry.sidebar;local node=p and state.layout and state.layout.by_id[state.selected]
    if not node then return end
    local model=panel_model(ctx,state);local page=math.max(0,math.min(model.pages-1,state.detail_scroll or 0))
    local title,tint,kind=phase(ctx,node)
    if model.tab=='diff' and model.compare then title,tint=tr(ctx,nil,'Comparison'),C.blue end
    bevel(g,p.x,p.y,p.w,p.h,C.panel,true)
    bevel(g,p.x+16,p.y+16,p.w-32,47,tint)
    text(g,font,title,p.x+26,p.y+21,28,p.w-52,C.white,'center',true)
    if model.tab=='diff' and model.compare then
        text(g,font_for(g,true),'#'..model.compare.before_id..' > #'..model.compare.after_id,p.x+18,p.y+66,21,p.w-36,C.gold,'center')
    else
        chip_icon(g,font,ctx,node,kind,tint,p.x+75,p.y+64,28)
        text(g,font,tr(ctx,'收束点 #','POINT #')..node.id,p.x+111,p.y+66,20,p.w-143,C.gold,nil,true)
    end
    local hovered=hover_target(ctx,state,geometry)
    if model.tab=='diff' and model.compare then
        for i=page*4+1,math.min(#model.metrics,page*4+4) do
            local m=model.metrics[i];local col=(i-page*4-1)%2;local row=math.floor((i-page*4-1)/2)
            local x,y=p.x+20+col*145,232+row*43
            text(g,font,m.label or tr(ctx,nil,metric_labels[m.key] or m.key),x,y,15,138,C.muted,'center')
            text(g,font_for(g,true),tostring(m.before or '-')..' > '..tostring(m.after or '-'),x,y+17,22,138,C.gold,'center')
        end
        text(g,font,tr(ctx,nil,'Before'),p.x+24,316,16,106,C.muted,'center')
        text(g,font,tr(ctx,nil,'After'),p.x+188,316,16,106,C.muted,'center')
        if #model.items==0 then text(g,font,tr(ctx,nil,model.compare.same and 'No changes' or 'No card changes'),p.x+22,391,22,p.w-44,C.cream,'center') end
        if #model.items==0 and not model.compare.same then
            local label=model.compare.rng_changed and 'Random state changed' or model.compare.other_state_changed and 'Other state changed' or 'Choices changed'
            text(g,font,tr(ctx,nil,label),p.x+22,428,18,p.w-44,C.gold,'center')
        end
        for i=page*2+1,math.min(#model.items,page*2+2) do
            local change=model.items[i].change;local y=337+(i-page*2-1)*99
            local colour=change.kind=='added' and C.green or change.kind=='removed' and C.red or C.gold
            text(g,font_for(g,true),change.kind=='added' and '+' or change.kind=='removed' and '-' or '>',p.x+136,y+30,30,48,colour,'center')
        end
    elseif model.tab~='cards' and model.tab~='choices' then
        for i=page*6+1,math.min(#model.metrics,page*6+6) do
            local offset=i-page*6-1;local m=model.metrics[i]
            local x,y=p.x+20+(offset%2)*145,239+math.floor(offset/2)*64
            if m.hand then
                bevel(g,x,y,136,57,C.felt_dark,true)
                text(g,font,(m.hand.name or m.hand.key)..' '..tostring(m.hand.level),x+5,y+4,16,126,C.muted,'center')
                text(g,font_for(g,true),tostring(m.hand.chips),x+6,y+26,25,50,C.selected,'center')
                text(g,font_for(g,true),'x',x+57,y+26,25,22,C.cream,'center')
                text(g,font_for(g,true),tostring(m.hand.mult),x+80,y+26,25,50,C.red,'center')
            else metric(g,font,ctx,m.key,m.value,x,y,136,57) end
        end
    elseif #model.items==0 then
        text(g,font,tr(ctx,nil,model.tab=='choices' and 'No recorded choices' or 'No cards'),p.x+22,350,23,p.w-44,C.muted,'center')
    end
    local targets=Renderer.card_targets(ctx,state,geometry)
    if model.tab=='cards' then
        local regions={}
        for _,target in ipairs(targets) do
            local last=regions[#regions]
            if last and last.group==target.group and last.y==target.y then last.right=target.x+target.w
            else regions[#regions+1]={group=target.group,x=target.x,y=target.y,right=target.x+target.w,h=target.h} end
        end
        for _,region in ipairs(regions) do
            bevel(g,region.x-6,region.y-9,region.right-region.x+12,region.h+18,C.felt_dark,true)
        end
    end
    for _,target in ipairs(targets) do
        local item=target.item;local raised=hovered==target and -5 or 0
        if target.status then
            local colour=target.status=='removed' and C.red or target.status=='added' and C.green or C.gold
            color(g,colour);pixel_box(g,'fill',target.x-4,target.y-4,target.w+8,target.h+8,3)
        end
        if item.card_key or item.key or item.suit then
            Native.card(g,item,target.x,target.y+raised,target.w,target.h,{hover=hovered==target})
        else Native.chip(g,'choose',target.x+target.w/2,target.y+target.h/2+raised,48) end
        if model.tab=='choices' then
            local label=tr(ctx,nil,choice_labels[item.kind] or item.label or item.kind)
            text(g,font,label,target.x-7,target.y-20,16,target.w+14,C.muted,'center')
            if item.count and item.count>1 then text(g,font_for(g,true),'x'..item.count,target.x,target.y+target.h+3,21,target.w,C.gold,'center') end
        end
    end
    if model.pages>1 then
        text(g,font_for(g,true),tostring(page+1)..' / '..model.pages,p.x+65,540,19,p.w-130,C.muted,'center')
        color(g,C.felt_dark);g.rectangle('fill',p.x+p.w-13,239,3,282)
        local h=math.max(16,282/model.pages);color(g,C.muted);g.rectangle('fill',p.x+p.w-13,239+(282-h)*page/(model.pages-1),3,h)
    end
    if state.fold_start then text(g,font,tr(ctx,nil,'Region starts at #')..state.fold_start,p.x+20,560,15,p.w-40,C.gold,'center') end
end
local tooltip_cache
local function draw_tooltip(g,font,ctx,state,geometry)
    local target=hover_target(ctx,state,geometry)
    if not target then return end
    local locale=G and G.SETTINGS and G.SETTINGS.language
    local cached=tooltip_cache
    if not cached or cached.item~=target.item or cached.locale~=locale or cached.summary~=target.details then
        cached={item=target.item,locale=locale,summary=target.details,data=Presentation.tooltip(target.item,target.details,function(key)return tr(ctx,nil,key) end)}
        tooltip_cache=cached
    end
    local data=cached.data;local lines=cached.lines or {}
    local function wrap(value)
        local line=''
        for char in tostring(value):gmatch('[%z\1-\127\194-\244][\128-\191]*') do
            if #line>0 and font:getWidth(line..char)*20/font:getHeight()>300 then lines[#lines+1]=line;line='' end
            line=line..char
        end
        lines[#lines+1]=line
    end
    if not cached.lines then
        for _,line in ipairs(data.lines) do wrap(line) end
        if #data.badges>0 then wrap(table.concat(data.badges,' / ')) end
        cached.lines=lines
    end
    local h=math.min(650,92+#lines*26);local x=geometry.sidebar.x-354;local y=math.max(85,math.min(790-h,target.y-20))
    bevel(g,x,y,336,h,C.grey,true);bevel(g,x+6,y+6,324,h-12,C.paper)
    text(g,font,data.name,x+18,y+15,25,300,C.ink,'center')
    local source=(target.side and tr(ctx,nil,target.side=='before' and 'Before' or 'After')..' / ' or '')..tr(ctx,nil,'POINT #')..target.node_id
    text(g,font,source,x+18,y+44,16,300,C.grey,'center')
    for i,line in ipairs(lines) do if y+70+i*26<y+h then text(g,font,line,x+18,y+69+(i-1)*26,20,300,C.ink,'center') end end
end

local edge_labels = setmetatable({}, {__mode = 'k'})
local function edge_label(ctx, child)
    if not child then return '' end
    local row = child.row
    local locale = G and G.SETTINGS and G.SETTINGS.language or 'en-us'
    local previous = edge_labels[row]
    if previous and previous.locale == locale then return previous.text end
    local choices = row.action and row.action.choices
    local value
    if choices and #choices > 0 then
        value = choice_name(ctx, choices[1])
        if #choices > 1 then value = value .. ' +' .. (#choices - 1) end
    else value = tr(ctx, nil, row.action and (choice_labels[row.action.kind] or row.action.label) or 'Stage transition') end
    edge_labels[row] = {locale = locale, text = value or ''}
    return value or ''
end
local function minimap_data(layout, m, path, selected)
    local cached = minimap_cache[layout]
    if not cached or cached.x ~= m.x or cached.y ~= m.y or cached.w ~= m.w or cached.h ~= m.h
        or cached.layout_w ~= layout.width or cached.layout_h ~= layout.height then
        cached = {x = m.x, y = m.y, w = m.w, h = m.h,
            layout_w = layout.width, layout_h = layout.height, edges = {}}
        local sx, sy = m.w / layout.width, m.h / layout.height
        if #layout.edges < 300 then
            for _, edge in ipairs(layout.edges) do
                local points = {}
                for i = 1, #edge.points, 2 do
                    points[i], points[i + 1] = m.x + edge.points[i] * sx, m.y + edge.points[i + 1] * sy
                end
                cached.edges[#cached.edges + 1] = {child = edge.child, points = points}
            end
        end
        minimap_cache[layout] = cached
    end
    if cached.path ~= path or cached.selected ~= selected then
        local sx, sy = m.w / layout.width, m.h / layout.height
        local buckets = {{}, {}, {}}
        for _, node in ipairs(layout.nodes) do
            local x, y = math.floor((node.x + node.w / 2) * sx / 2) * 2,
                math.floor((node.y + node.h / 2) * sy / 2) * 2
            local priority = selected == node.id and 3 or path[node.id] and 2 or 1
            buckets[priority][x .. ':' .. y] = {x, y, 3, 3}
        end
        cached.path, cached.selected, cached.buckets = path, selected, buckets
    end
    return cached
end
local function minimap(g, state, geometry, path, Graph, feedback)
    local m, layout = geometry.minimap, state.layout
    bevel(g, m.x - 7, m.y - 7, m.w + 14, m.h + 14, C.panel, true)
    if not layout or layout.width == 0 or layout.height == 0 then return end
    local cached = minimap_data(layout, m, path, state.selected)
    g.setLineWidth(2)
    for _, edge in ipairs(cached.edges) do
        color(g, path[edge.child] and C.gold or C.muted, 0.8); g.line(unpack_values(edge.points))
    end
    local colours = {C.muted, C.gold, C.selected}
    for priority, bucket in ipairs(cached.buckets) do
        color(g, colours[priority])
        for _, b in pairs(bucket) do g.rectangle('fill', m.x + b[1] - 1, m.y + b[2] - 1, 3, 3) end
    end
    Native.minimap_viewport(g, layout, state.view, geometry.canvas, m, Graph,
        {tint = state.drag and state.drag.kind == 'minimap' and C.gold or C.cream})
    if feedback and feedback.amount > 0.01 then
        color(g, C.cream, feedback.amount * 0.8); g.setLineWidth(1)
        pixel_box(g, 'line', m.x - 5, m.y - 5, m.w + 10, m.h + 10, 4)
    end
end
local function decorative_cards(g)
    -- Fixed positions/angles, so opening the tree never advances random streams.
    local centers = assets('centers')
    for _, p in ipairs({{-80, 95, -0.34}, {-62, 119, -0.34}, {-45, 143, -0.34},
        {8, 685, 0.28}, {29, 705, 0.28}, {1490, 629, 0.30}, {1463, 655, 0.30}}) do
        atlas(g, centers, {x = 0, y = 2}, p[1], p[2], 124, 166, {0.68, 0.77, 0.70}, p[3])
    end
    atlas(g, assets('Joker'), {x = 0, y = 0}, 1477, 78, 145, 194, {0.70, 0.78, 0.71}, 0.22)
    atlas(g, assets('Joker'), {x = 0, y = 0}, 45, 689, 139, 186, {0.72, 0.80, 0.72}, -0.27)
end
local function private_background(g)
    if not background_attempted then
        background_attempted = true
        if love.filesystem and type(love.filesystem.read) == 'function' and type(g.newShader) == 'function' then
            local read_ok, source = pcall(love.filesystem.read, 'resources/shaders/background.fs')
            if read_ok and type(source) == 'string' and #source > 0 then
                local compiled, shader = pcall(g.newShader, source)
                if compiled then background_shader = shader end
            end
        end
    end
    if not background_shader then return nil end
    local timers = G and G.TIMERS or {}
    local spin = G and G.ARGS and G.ARGS.spin or {}
    -- Reuse only the game's background program, with independent uniforms.
    -- The shared background/splash shaders and palette remain untouched.
    local ok = pcall(function()
        background_shader:send('time', timers.REAL_SHADER or 0)
        background_shader:send('spin_time', timers.BACKGROUND or 0)
        background_shader:send('spin_amount', spin.amount or 0)
        background_shader:send('colour_1', background_palette[1])
        background_shader:send('colour_2', background_palette[2])
        background_shader:send('colour_3', background_palette[3])
        background_shader:send('contrast', 1.5)
    end)
    if not ok then background_shader = nil end
    return background_shader
end
local function background(g, options)
    local shader = options.native_background and private_background(g)
    if shader then
        g.setShader(shader)
        color(g, {1, 1, 1}); g.rectangle('fill', 0, 0, 1600, 900)
        g.setShader()
    else
        -- A compile failure and standalone previews keep the green felt palette.
        color(g, C.felt); g.rectangle('fill', 0, 0, 1600, 900)
        color(g, C.ink, 0.07)
        for x = -100, 1700, 210 do for y = 110, 900, 230 do spade(g, x + y % 3 * 30, y, 53) end end
    end
    decorative_cards(g)
end
local function draw_all(ctx, state, Graph, g, geometry, options)
    local font, pixel = font_for(g), font_for(g, true)
    local tree = public_tree(ctx)
    g.origin(); g.setShader(); g.setScissor()
    if g.setStencilTest then g.setStencilTest() end
    g.scale(options.render_scale)
    color(g, C.ink); g.rectangle('fill', 0, 0, geometry.screen_w, geometry.screen_h)
    g.translate(geometry.offset_x, geometry.offset_y); g.scale(geometry.ui_scale)
    background(g, options)
    color(g, C.red); spade(g, 43, 39, 18)
    local title = tr(ctx, '世界线', 'WORLDLINE')
    local name = tree and tree.metadata and tree.metadata.name
    if name then
        local label,count='',0
        for char in tostring(name):gmatch('[%z\1-\127\194-\244][\128-\191]*') do
            count=count+1
            if count>28 then label=label..'...';break end
            label=label..char
        end
        name=label
    end
    text(g, title:find('[\128-\255]') and font or pixel, title, 77, name and 8 or 17, name and 32 or 42, 500, C.cream, nil, true)
    if name then text(g, font, name, 79, 47, 20, 500, C.muted, nil, true) end
    bevel(g, 1295, 20, 98, 40, C.panel, true)
    text(g, pixel, string.format('%d%%', math.floor((state.view and state.view.scale or 1) * 100 + 0.5)),
        1301, 22, 31, 86, C.cream, 'center', true)
    local canvas = geometry.canvas
    -- The graph is a visible table inset: its edge matches the actual clipping
    -- rectangle, so cards never vanish at an unmarked boundary.
    color(g, C.felt_dark, 0.20)
    pixel_box(g, 'fill', canvas.x, canvas.y, canvas.w, canvas.h, 5)
    local path = state.layout and current_path(ctx, state.layout) or {}
    local scale = options.render_scale
    g.setScissor(math.floor((geometry.offset_x + canvas.x * geometry.ui_scale) * scale),
        math.floor((geometry.offset_y + canvas.y * geometry.ui_scale) * scale),
        math.ceil(canvas.w * geometry.ui_scale * scale), math.ceil(canvas.h * geometry.ui_scale * scale))
    if state.layout and state.view then
        drawing(g, false, function()
            g.translate(canvas.x + state.view.pan_x, canvas.y + state.view.pan_y); g.scale(state.view.scale)
            g.setLineJoin('miter')
            for _,region in ipairs(state.layout.fold_regions or {}) do
                if Graph.node_visible(region,state.view,canvas,30) then
                    Native.dashed_region(g,region)
                    local label,count='',0
                    for char in tostring(region.label or tr(ctx,nil,'Folded region')):gmatch('[%z\1-\127\194-\244][\128-\191]*') do
                        count=count+1;if count>10 then label=label..'...';break end;label=label..char
                    end
                    local width=math.min(270,region.w-4);local x=region.x+(region.w-width)/2
                    bevel(g,x,region.y-27,width,28,C.blue)
                    text(g,font,label,x+9,region.y-24,19,width-75,C.cream,'center')
                    text(g,pixel,'+'..tostring(region.hidden_count or 0),x+width-64,region.y-26,24,56,C.gold,'center')
                end
            end
            local visible = Graph.query_visible and Graph.query_visible(state.layout, state.view, canvas, 25)
            for _, e in ipairs(visible and visible.edges or state.layout.edges) do
                if Graph.edge_visible(e, state.view, canvas, 18) then
                    local active = path[e.parent] and path[e.child]
                    color(g, active and C.gold or C.muted, active and 1 or 0.65)
                    g.setLineWidth(active and 8 or 6); g.line(unpack_values(e.points))
                    local n, p = #e.points, e.points
                    g.polygon('fill', p[n - 1], p[n], p[n - 1] - 11, p[n] - 8, p[n - 1] - 11, p[n] + 8)
                    if state.view.scale >= 0.55 then
                        local label = edge_label(ctx, state.layout.by_id[e.child])
                        local label_w = math.max(60, math.min(180, state.layout.gap_x - 12))
                        local x, y = p[n - 1] - label_w - 8, p[n] - 27
                        color(g, C.felt_dark, 0.95); pixel_box(g, 'fill', x - 3, y - 2, label_w + 6, 24, 2)
                        text(g, font, label, x, y, 20, label_w, active and C.gold or C.cream, 'center')
                    end
                end
            end
            g.setLineWidth(1)
            for _, n in ipairs(visible and visible.nodes or state.layout.nodes) do
                if Graph.node_visible(n, state.view, canvas, 25) then drawing(g, false, draw_node, g, font, ctx, state, n, path) end
            end
        end)
    end
    g.setScissor()
    if state.selection_box then
        local b=state.selection_box;color(g,C.selected,0.10);g.rectangle('fill',b.x,b.y,b.w,b.h)
        color(g,C.selected,0.9);g.setLineWidth(2);g.rectangle('line',b.x,b.y,b.w,b.h)
    end
    Native.canvas_frame(g, canvas)
    if not state.layout or #state.layout.nodes == 0 then
        local automatic = true
        if type(ctx.auto_create_enabled) == 'function' then automatic = ctx.auto_create_enabled()
        elseif ctx.auto_create_enabled == false then automatic = false end
        local message = automatic and tr(ctx, '开始一局游戏，世界线将自动记录', 'Start a run to record its worldline')
            or tr(ctx, '自动创建已关闭，可在模组设置中开启', 'Automatic worldline recording is off; enable it in mod settings')
        text(g, font, message,
            canvas.x + 80, canvas.y + 277, 30, canvas.w - 160, C.cream, 'center', true)
    end
    local hint_width = math.min(460, canvas.w - 20)
    color(g, C.felt_dark, 0.92)
    pixel_box(g, 'fill', canvas.x + 10, canvas.y + 10, hint_width, 52, 3)
    text(g, font, tr(ctx, nil, 'Right drag / Left select'),
        canvas.x + 20, canvas.y + 15, 17, hint_width - 20, C.cream, nil, true)
    text(g, font, tr(ctx, nil, 'Ctrl/Shift select / Scroll zoom / F6'),
        canvas.x + 20, canvas.y + 37, 17, hint_width - 20, C.cream, nil, true)
    detail(g, font, ctx, state, geometry)
    local controls = Renderer.controls(ctx, state, geometry)
    local feedback = control_feedback(controls, state, geometry, 'tree')
    for _, control in ipairs(controls) do draw_button(g, font, control, feedback[control.key]) end
    local seed = tree and tree.metadata and tree.metadata.seed or '-'
    bevel(g, 24, 836, 300, 44, C.panel, true)
    text(g, font, tr(ctx, '种子', 'SEED'), 38, 841, 26, 68, C.muted, nil, true)
    text(g, pixel, seed, 116, 839, 34, 190, C.gold, nil, true)
    local notice = state.notice or ctx.status
    if notice then text(g, font, notice, 350, 804, 21, 960, C.gold, nil, true) end
    if state.view then minimap(g, state, geometry, path, Graph, feedback.minimap) end
    draw_tooltip(g,font,ctx,state,geometry)
end
function Renderer.draw(ctx, state, Graph, options)
    if not public_tree(ctx) then
        -- An internal undo root is not a public worldline. Do not expose its
        -- cached layout/sidebar or treat it as a saved/exportable history.
        state = {screen_w = state.screen_w, screen_h = state.screen_h, notice = state.notice,
            active = state.active, transition = state.transition, transition_target = state.transition_target,
            layout = {nodes = {}, edges = {}, by_id = {}, width = 0, height = 0}}
    end
    local g, geometry = love.graphics, Renderer.geometry(state)
    options = options or {}
    local draw_options = {render_scale = options.render_scale or 1, native_background = options.native_background == true}
    if geometry.transition_alpha == 1 and geometry.transition_scale == 1 then
        drawing(g, true, draw_all, ctx, state, Graph, g, geometry, draw_options)
    else
        local w, h = geometry.screen_w * draw_options.render_scale, geometry.screen_h * draw_options.render_scale
        if G and G.CANVAS and G.CANVAS.getDimensions then w, h = G.CANVAS:getDimensions() end
        local ok, err = Compositor.draw(g, math.floor(w + 0.5), math.floor(h + 0.5),
            geometry.transition_alpha, geometry.transition_scale, function()
                drawing(g, true, draw_all, ctx, state, Graph, g, geometry, draw_options)
                return true
            end, {native_dissolve = options.native_background == true,
                time = G and G.TIMERS and G.TIMERS.REAL_SHADER or 0})
        if ok == nil then error(err, 0) end
    end
    return geometry
end
return Renderer

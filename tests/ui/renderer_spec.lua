local Graph = dofile('src/ui/graph.lua')
local Renderer = dofile('src/ui/renderer.lua')
local previous = {love = love, G = G, random = math.random, randomseed = math.randomseed,
    pseudorandom = pseudorandom, pseudorandom_element = pseudorandom_element,
    save_run = save_run, Card = Card, UIBox = UIBox, Sprite = Sprite, AnimatedSprite = AnimatedSprite,
    localize = localize}
local calls, depth, screen_w, screen_h, current_font, current_shader = {}, 0, 1600, 900, nil, nil
local graphics_stack, current_scissor = {}, nil
local inherited_stencil = {mode = 'equal', value = 3}
local current_stencil = inherited_stencil
local font = {getHeight = function() return 16 end, getWidth = function(_, value) return #value * 8 end}
local pixel_font = {getHeight = function() return 11 end, getWidth = function(_, value) return #value * 6 end}
local function native_image(w, h)
    -- Image dimensions are logical even when texture_scaling/DPIScale is 2.
    return {getDimensions = function() return w, h end, getDPIScale = function() return 2 end,
        getPixelDimensions = function() return w * 2, h * 2 end}
end
local images = {Joker = native_image(710, 1520), centers = native_image(497, 475), chips = native_image(145, 58),
    blind_chips = native_image(714, 1054), ui_1 = native_image(72, 36), shop_sign = native_image(452, 57)}
local function record(name, ...)
    calls[#calls + 1] = {name = name, args = {...}, font = current_font, shader = current_shader,
        stencil = current_stencil}
end
local graphics = {
    getDimensions = function() return screen_w, screen_h end,
    getDPIScale = function() return 2 end, -- This must never multiply logical quad/scissor coordinates.
    getFont = function() return font end,
    setFont = function(value) current_font = value; record('setFont', value) end,
    push = function(mode)
        depth = depth + 1
        graphics_stack[depth] = {all = mode == 'all', font = current_font, shader = current_shader,
            stencil = current_stencil, scissor = current_scissor}
        record('push', mode)
    end,
    pop = function(...)
        local saved = assert(graphics_stack[depth], 'unbalanced graphics pop')
        graphics_stack[depth] = nil
        depth = depth - 1
        if saved.all then
            current_font, current_shader, current_stencil, current_scissor = saved.font, saved.shader, saved.stencil, saved.scissor
        end
        record('pop', ...)
    end,
    setShader = function(shader) current_shader = shader; record('setShader', shader) end,
    setStencilTest = function(mode, value)
        current_stencil = mode and {mode = mode, value = value} or nil
        record('setStencilTest', mode, value)
    end,
    newQuad = function(x, y, w, h, iw, ih)
        assert(x >= 0 and y >= 0 and w > 0 and h > 0 and x + w <= iw and y + h <= ih,
            'quad must address the native logical atlas dimensions')
        record('newQuad', x, y, w, h, iw, ih)
        return {x = x, y = y, w = w, h = h, iw = iw, ih = ih}
    end,
}
graphics.getScissor = function() if current_scissor then return unpack(current_scissor) end end
for _, name in ipairs({'setColor', 'polygon', 'rectangle', 'circle', 'line', 'setLineWidth',
    'setLineJoin', 'print', 'draw', 'translate', 'scale', 'origin', 'setScissor'}) do
    local method = name
    graphics[method] = function(...) record(method, ...) end
end
graphics.setScissor = function(x, y, w, h)
    current_scissor = x and {x, y, w, h} or nil
    record('setScissor', x, y, w, h)
end
local forbidden = function() error('Rendering may not mutate game state or consume RNG') end
graphics.newCanvas, graphics.setCanvas = forbidden, forbidden
local background_source, source_reads, private_shaders = '-- native background source fixture', 0, {}
local shader_uniforms = {time = true, spin_time = true, spin_amount = true,
    colour_1 = true, colour_2 = true, colour_3 = true, contrast = true}
graphics.newShader = function(source)
    assert(source == background_source, 'only the game background shader source may be compiled')
    record('newShader', source)
    local shader = {uniforms = {}}
    shader.send = function(self, name, value)
        assert(shader_uniforms[name], 'the private background has exactly the native seven uniforms')
        if type(value) == 'table' then value = {unpack(value)} end
        self.uniforms[name] = value
        record('shader_send', self, name, value)
    end
    private_shaders[#private_shaders + 1] = shader
    return shader
end
local background_shader = {send = forbidden, uniforms = {time = 123, spin_time = 456, contrast = 2}}
local splash_shader = {send = forbidden, uniforms = {time = 789, vort_speed = 0.4, mid_flash = 0}}
love = {graphics = graphics, math = {random = forbidden, setRandomSeed = forbidden},
    filesystem = {read = function(path)
        assert(path == 'resources/shaders/background.fs', 'no other resources or saves may be read')
        source_reads = source_reads + 1
        return background_source
    end}}
local function native_atlases()
    return {Joker = {px = 71, py = 95, image = images.Joker},
        centers = {px = 71, py = 95, image = images.centers}, chips = {px = 29, py = 29, image = images.chips},
        ui_1 = {px = 18, py = 18, image = images.ui_1}}
end
G = {LANG = {font = {FONT = font}}, FONTS = {{FONT = pixel_font}},
    SETTINGS = {GRAPHICS = {crt = 70, bloom = 2}}, TIMERS = {REAL_SHADER = 123, BACKGROUND = 456},
    ARGS = {spin = {amount = 0.35}}, STAGES = {RUN = 1}, STAGE = 0,
    C = {BACKGROUND = {C = {0.8, 0.1, 0.1, 1}, L = {1, 0.2, 0.2, 1}, D = {0.1, 0, 0, 1}, contrast = 99}},
    SHADERS = {background = background_shader, splash = splash_shader},
    SPLASH_BACK = {draw_steps = {{shader = 'background'}}, draw = forbidden, draw_shader = forbidden},
    ASSET_ATLAS = native_atlases(), ANIMATION_ATLAS = {
        blind_chips = {px = 34, py = 34, frames = 21, image = images.blind_chips},
        shop_sign = {px = 113, py = 57, frames = 4, image = images.shop_sign}},
    P_BLINDS = {bl_small = {pos = {x = 0, y = 0}}, bl_big = {pos = {x = 0, y = 1}},
        bl_hook = {pos = {x = 0, y = 7}}},
    P_CENTERS = {j_test = {atlas = 'Joker', pos = {x = 2, y = 1}},
        undiscovered_joker = {pos = {x = 5, y = 3}}}}
math.random, math.randomseed, pseudorandom, pseudorandom_element, save_run = forbidden, forbidden, forbidden, forbidden, forbidden
Card, UIBox, Sprite, AnimatedSprite = forbidden, forbidden, forbidden, forbidden

local function matching(name)
    local result = {}
    for _, call in ipairs(calls) do if call.name == name then result[#result + 1] = call end end
    return result
end
local function printed(value, expected_font)
    for _, call in ipairs(matching('print')) do
        if call.args[1] == value and (not expected_font or call.font == expected_font) then return true end
    end
    return false
end
local function drawn(image, x, y, w, h)
    for _, call in ipairs(matching('draw')) do
        local quad = call.args[2]
        if call.args[1] == image and type(quad) == 'table'
            and quad.x == x and quad.y == y and quad.w == w and quad.h == h then return true end
    end
    return false
end
local function near(a, b) assert(math.abs(a - b) < 0.000001, tostring(a) .. ' ~= ' .. tostring(b)) end
local function control(controls, key)
    for _, item in ipairs(controls) do if item.key == key then return item end end
    error('Missing control ' .. key)
end
local function signature(value)
    if type(value) ~= 'table' then return tostring(value) end
    local keys, result = {}, {}
    for key in pairs(value) do keys[#keys + 1] = key end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    for _, key in ipairs(keys) do result[#result + 1] = tostring(key) .. '=' .. signature(value[key]) end
    return '{' .. table.concat(result, ',') .. '}'
end
local rows = {
    {id = 1, parent = 0, action = {kind = 'start'}, summary = {ante = 1, round = 0, dollars = 10}},
    {id = 2, parent = 1, action = {kind = 'select_blind', blind = {key = 'bl_small'}},
        summary = {ante = 1, round = 1, dollars = 7, deck = 'b_red', stake = 1,
            blind_key = 'bl_small', hand_count = 8, deck_count = 44,
            jokers = {{key = 'j_test', name = 'Test Joker'}}}},
    {id = 3, parent = 2, action = {kind = 'enter_shop'}, summary = {ante = 1, dollars = 12}},
    {id = 4, parent = 2, action = {kind = 'select_blind', blind = {key = 'bl_big'}},
        summary = {ante = 1, blind_key = 'bl_big', dollars = 999,
            jokers = {{key = 'missing', name = 'Fallback'}}}},
    {id = 5, parent = 4, action = {kind = 'select_blind', blind = {key = 'bl_hook'}},
        summary = {ante = 2, blind_key = 'bl_hook', blind_name = 'The Hook', dollars = 27}},
}
local tree = {current = 3, metadata = {seed = 'TREE1234'}}
local ctx = {tree = tree, text = function(_, en) return en end, at_current_node = forbidden,
    can_undo = function() return true end}
local state = {layout = Graph.layout(rows), selected = 2, hover = 3, notice = 'Checkpoint saved'}
local geometry = Renderer.geometry(state)
assert(geometry.ui_scale == 1 and geometry.offset_x == 0 and geometry.offset_y == 0)
assert(geometry.canvas.x == 70 and geometry.canvas.y == 78 and geometry.canvas.w == 1120 and geometry.canvas.h == 740)
assert(geometry.sidebar and geometry.sidebar.x == 1230 and geometry.sidebar.w == 320)
state.view = {pan_x = 0, pan_y = 0, scale = 1, width = geometry.canvas.w, height = geometry.canvas.h}
state.layout.by_id[4].x = 10000
state.layout.width = 10222 -- Offscreen cards still have a valid place in the minimap.
local before = signature({state = state, tree = tree, game = G})
Renderer.draw(ctx, state, Graph)
assert(signature({state = state, tree = tree, game = G}) == before, 'draw must not mutate game, history or viewport')
assert(depth == 0 and calls[1].name == 'push' and calls[1].args[1] == 'all')
assert(calls[#calls].name == 'pop' and #matching('origin') == 1)
assert(current_stencil == inherited_stencil, 'caller overflow clipping is restored after drawing')
for _, call in ipairs(calls) do
    if ({rectangle=true,polygon=true,circle=true,line=true,print=true,draw=true})[call.name] then
        assert(call.stencil == nil, 'Tree draws outside the native settings/overflow stencil clip')
    end
end
assert(printed('WORLDLINE', pixel_font), 'English title uses the existing Balatro pixel font')
assert(printed('$7', pixel_font) and printed('TREE1234', pixel_font), 'numbers and seed use the pixel font')
assert(printed('SMALL BLIND') and printed('SHOP') and printed('Checkpoint saved') and printed('CONVERGE HERE'))
assert(not printed('$999'), 'offscreen cards are culled')
assert(drawn(images.centers, 71, 0, 71, 95), 'card shells use the game blank-card texture')
assert(drawn(images.Joker, 142, 95, 71, 95), 'Joker artwork uses its center position')
assert(drawn(images.blind_chips, 0, 0, 34, 34), 'blind chips come from the animation atlas')
assert(#matching('line') > 0, 'draw graph connections')
for _, call in ipairs(matching('line')) do
    local points = call.args
    for i = 1, #points - 2, 2 do
        assert(points[i] == points[i + 2] or points[i + 1] == points[i + 3], 'tree edges use right angles')
    end
end
local scissors = matching('setScissor')
assert(scissors[2].args[1] == geometry.canvas.x and scissors[2].args[2] == geometry.canvas.y)
assert(scissors[2].args[3] == geometry.canvas.w and scissors[2].args[4] == geometry.canvas.h)
assert(current_scissor == nil, 'canvas and minimap clipping never leak to the native cursor')
calls = {}
Renderer.draw(ctx, state, Graph)
assert(#matching('newQuad') == 0, 'native texture quads are cached across frames')

-- Boss sprites respect the blind prototype position, not a fabricated label/icon.
state.selected = 5
calls = {}
Renderer.draw(ctx, state, Graph)
assert(drawn(images.blind_chips, 0, 238, 34, 34), 'boss chip uses G.P_BLINDS[blind_key].pos')
state.selected, state.detail_tab = 4, 'cards'
calls = {}
Renderer.draw(ctx, state, Graph)
assert(drawn(images.blind_chips, 0, 34, 34, 34), 'big blind uses its own row')
assert(drawn(images.centers, 355, 285, 71, 95), 'unknown Joker uses the native undiscovered Joker artwork')

state.detail_tab = 'overview'
local controls = Renderer.controls(ctx, state, geometry)
for _, key in ipairs({'save', 'export', 'import', 'archives', 'folder', 'undo', 'fit', 'focus', 'zoom_in', 'zoom_out', 'close', 'restore', 'minimap'}) do
    assert(control(controls, key).enabled, key .. ' is available')
end
for i, a in ipairs(controls) do
    for j = i + 1, #controls do
        local b = controls[j]
        assert(a.x + a.w <= b.x or b.x + b.w <= a.x or a.y + a.h <= b.y or b.y + b.h <= a.y,
            a.key .. ' and ' .. b.key .. ' hit regions overlap')
    end
end
state.selected, state.at_current_node = 3, true
assert(not control(Renderer.controls(ctx, state), 'restore').enabled, 'current checkpoint is already active')
ctx.detached = true
assert(control(Renderer.controls(ctx, state), 'restore').enabled, 'archive previews may restore their current checkpoint')
ctx.busy = true
controls = Renderer.controls(ctx, state)
for _, key in ipairs({'save', 'export', 'import', 'archives', 'folder', 'undo', 'restore'}) do
    assert(not control(controls, key).enabled, key .. ' is disabled during restore')
end
assert(control(controls, 'close').enabled)
ctx.busy, ctx.detached = false, false

-- LÖVE mouse coordinates and scissor rectangles are logical, including HiDPI windows.
screen_w, screen_h = 1920, 1200
geometry = Renderer.geometry(state)
near(geometry.ui_scale, 1.2); near(geometry.offset_y, 60)
local x, y = Renderer.to_logical(geometry.offset_x + 200 * geometry.ui_scale,
    geometry.offset_y + 300 * geometry.ui_scale, geometry)
near(x, 200); near(y, 300)
calls = {}
Renderer.draw(ctx, state, Graph)
scissors = matching('setScissor')
assert(scissors[2].args[1] == math.floor(geometry.canvas.x * 1.2))
assert(scissors[2].args[2] == math.floor(60 + geometry.canvas.y * 1.2))
assert(scissors[2].args[3] == math.ceil(geometry.canvas.w * 1.2), 'DPIScale must not be applied twice')
assert(depth == 0)

-- Production compiles a private copy of the game's background shader. It uses
-- native time/spin values, but the table always has its own green palette.
local function shader_rectangle(shader)
    for _, call in ipairs(matching('rectangle')) do
        if call.shader == shader and call.args[1] == 'fill' then return true end
    end
    return false
end
local entry_shader = {name = 'native entry shader'}
current_shader = entry_shader
calls = {}
before = signature({state = state, tree = tree, game = G})
Renderer.draw(ctx, state, Graph, {render_scale = 2, native_background = true})
local private_background = assert(private_shaders[1])
assert(signature({state = state, tree = tree, game = G}) == before,
    'shared uniforms, palette, timers, graphics settings and gameplay remain unchanged')
assert(shader_rectangle(private_background), 'the green table uses a private native background program')
assert(not shader_rectangle(background_shader) and not shader_rectangle(splash_shader),
    'the table never borrows the shared run or menu shader')
assert(source_reads == 1 and #private_shaders == 1 and #matching('newShader') == 1)
assert(private_background.uniforms.time == G.TIMERS.REAL_SHADER
    and private_background.uniforms.spin_time == G.TIMERS.BACKGROUND
    and private_background.uniforms.spin_amount == G.ARGS.spin.amount)
assert(private_background.uniforms.contrast == 1.5, 'contrast is independent of the menu background')
assert(#matching('shader_send') == 7, 'all seven native uniforms are set only on the private shader')
for _, key in ipairs({'colour_1', 'colour_2', 'colour_3'}) do
    local tint = private_background.uniforms[key]
    assert(#tint == 4 and tint[4] == 1 and tint[2] > tint[1] and tint[2] > tint[3],
        'every private palette uniform is opaque green')
    assert(tint ~= G.C.BACKGROUND.C and tint ~= G.C.BACKGROUND.L and tint ~= G.C.BACKGROUND.D)
end
assert(current_shader == entry_shader and depth == 0, 'the caller shader is restored after native rendering')
assert(current_stencil == inherited_stencil, 'native-canvas drawing restores the prior stencil test')
local first_scale = matching('scale')[1].args
assert(first_scale[1] == 2 and (first_scale[2] or first_scale[1]) == 2,
    'origin reset is followed by exactly the caller canvas scale')
scissors = matching('setScissor')
assert(scissors[2].args[1] == math.floor(geometry.canvas.x * 1.2 * 2))
assert(scissors[2].args[2] == math.floor((60 + geometry.canvas.y * 1.2) * 2))
assert(scissors[2].args[3] == math.ceil(geometry.canvas.w * 1.2 * 2))
assert(scissors[2].args[4] == math.ceil(geometry.canvas.h * 1.2 * 2),
    'clip coordinates apply canvas scaling once and never multiply asset DPIScale')
assert(drawn(images.blind_chips, 0, 0, 34, 34), 'canvas scale does not alter logical texture quads')

-- Main-menu and in-run backgrounds cannot change the tree palette. Private
-- program compilation is cached while time/spin uniforms refresh each frame.
G.SPLASH_BACK.draw_steps[1].shader = 'splash'
calls = {}
before = signature(G)
Renderer.draw(ctx, state, Graph, {render_scale = 1, native_background = true})
assert(shader_rectangle(private_background) and not shader_rectangle(splash_shader)
    and not shader_rectangle(background_shader))
assert(source_reads == 1 and #private_shaders == 1 and #matching('newShader') == 0,
    'reopening or drawing another frame reuses the private compiled program')
assert(signature(G) == before and current_shader == entry_shader and depth == 0)
G.SPLASH_BACK.draw_steps[1].shader = 'background'
calls = {}
Renderer.draw(ctx, state, Graph, {native_background = false})
assert(not shader_rectangle(background_shader) and not shader_rectangle(splash_shader),
    'offline fallback drawing does not pretend to execute native shaders')
assert(not shader_rectangle(private_background) and #matching('shader_send') == 0,
    'offline previews stay flat green even after a native program was cached')
local shaders = G.SHADERS
G.SHADERS = {}
calls = {}
Renderer.draw(ctx, state, Graph, {native_background = true})
assert(shader_rectangle(private_background) and depth == 0 and current_shader == entry_shader,
    'the private program does not depend on the shared shader registry')
G.SHADERS = shaders

-- A compilation failure falls back to felt green and is attempted only once.
local new_shader = graphics.newShader
local failed_compiles = 0
graphics.newShader = function(source)
    failed_compiles = failed_compiles + 1
    assert(source == background_source)
    error('simulated background compile failure')
end
local fallback_renderer = dofile('src/ui/renderer.lua')
calls = {}
fallback_renderer.draw(ctx, state, Graph, {native_background = true})
fallback_renderer.draw(ctx, state, Graph, {native_background = true})
assert(failed_compiles == 1 and not shader_rectangle(background_shader)
    and not shader_rectangle(splash_shader) and not shader_rectangle(private_background),
    'shader failure never inherits the menu background or retries each frame')
local felt_green = false
for _, call in ipairs(matching('setColor')) do
    if call.args[1] == 0.025 and call.args[2] == 0.25 and call.args[3] == 0.205 then felt_green = true end
end
assert(felt_green and depth == 0 and current_shader == entry_shader)
graphics.newShader = new_shader

-- An exception while the private shader is bound also unwinds the entire state.
local native_rectangle = graphics.rectangle
graphics.rectangle = function(...)
    if current_shader == private_background then error('simulated native shader draw failure') end
    return native_rectangle(...)
end
assert(not pcall(Renderer.draw, ctx, state, Graph, {native_background = true}))
assert(depth == 0 and current_shader == entry_shader, 'failed background draw restores the caller shader')
assert(current_stencil == inherited_stencil, 'failed native background also restores inherited clipping')
graphics.rectangle = native_rectangle
current_shader = nil

-- The compact undo control is run-only, independent of Tree, and can remain
-- visible over a native Options overlay. Drawing changes no shared state.
assert(Renderer.undo_control(ctx) == nil, 'the main menu has no live-run undo control')
G.STAGE = G.STAGES.RUN
local undo = Renderer.undo_control(ctx)
assert(undo.key == 'undo' and undo.x == 1484 and undo.y == 2 and undo.w == 110 and undo.h == 27
    and undo.enabled and undo.label == 'Ctrl+Z' and undo.font_size == 20,
    'the compact HUD stays six logical pixels from the right and two from the top')
assert(control(Renderer.controls(ctx, state), 'undo').label == 'UNDO', 'the full tree keeps its descriptive undo label')
G.OVERLAY_MENU = {}
assert(Renderer.undo_control(ctx), 'a native overlay does not hide the live-run undo control')
G.OVERLAY_MENU = nil
ctx.busy = true
assert(not Renderer.undo_control(ctx).enabled, 'restore in progress disables HUD undo')
ctx.busy = false
local can_undo = ctx.can_undo
ctx.can_undo = nil
assert(not Renderer.undo_control(ctx).enabled
    and not control(Renderer.controls(ctx, state), 'undo').enabled, 'missing runtime APIs are safely disabled')
ctx.can_undo = function() error('undo status unavailable') end
assert(not Renderer.undo_control(ctx).enabled, 'a failing status callback cannot break native drawing')
ctx.can_undo = can_undo
calls = {}
current_shader = entry_shader
before = signature(G)
assert(Renderer.draw_undo(ctx, {render_scale = 2}))
assert(signature(G) == before and depth == 0 and current_shader == entry_shader
    and current_stencil == inherited_stencil, 'HUD rendering restores all caller graphics state')
assert(#matching('newShader') == 0 and #matching('shader_send') == 0 and #matching('draw') == 0,
    'the HUD only draws its compact button and never paints a background or creates an asset')
assert(printed('Ctrl+Z', pixel_font))
for _, call in ipairs(calls) do
    if call.name == 'rectangle' then
        assert(call.args[2] >= 1484 and call.args[2] <= 1594,
            'the undo HUD never draws a fullscreen rectangle')
    end
end
local scales = matching('scale')
assert(scales[1].args[1] == 2 and scales[2].args[1] == geometry.ui_scale)
G.STAGE = 0
calls = {}
assert(Renderer.draw_undo(ctx, {render_scale = 2}) == false and #calls == 0)
current_shader = nil

-- Both art and fonts have graceful read-only fallbacks.
G.ASSET_ATLAS, G.ANIMATION_ATLAS, G.FONTS = {}, {}, {}
state.selected, state.at_current_node = 4, false
calls = {}
Renderer.draw(ctx, state, Graph)
assert(#matching('draw') == 0 and #matching('polygon') > 0 and depth == 0)
G.ASSET_ATLAS, G.FONTS = native_atlases(), {{FONT = pixel_font}}
G.ANIMATION_ATLAS = {blind_chips = {px = 34, py = 34, frames = 21, image = images.blind_chips}}
ctx.text = function(zh) return zh end
calls = {}
Renderer.draw(ctx, state, Graph)
assert(printed('大盲注', font), 'localized labels retain the game language font')
assert(printed('世界线', font) and not printed('WORLDLINE'), 'the Chinese brand title uses the current language font')
localize = function(args)
    if args.set == 'Blind' and args.key == 'bl_hook' then return '钩子' end
    if args.set == 'Back' and args.key == 'b_red' then return '红色牌组' end
    return 'ERROR'
end
state.selected = 5
calls = {}
Renderer.draw(ctx, state, Graph)
assert(printed('钩子', font), 'named bosses use the game localization rather than raw English prototype names')
state.selected, state.detail_scroll = 2, 3
calls = {}
Renderer.draw(ctx, state, Graph)
local deck_target=Renderer.card_targets(ctx,state,Renderer.geometry(state))[1]
assert(deck_target.item.key=='b_red' and dofile('src/ui/card_presentation.lua').name(deck_target.item)=='红色牌组',
    'deck card hover uses native game localization')
state.detail_scroll = 0
localize = previous.localize
ctx.text = function(_, en) return en end

-- Empty history keeps import/close available and gives a useful instruction.
state = {layout = Graph.layout({}), view = {pan_x = 0, pan_y = 0, scale = 1}}
ctx.tree = nil
calls = {}
Renderer.draw(ctx, state, Graph)
assert(printed('Start a run to record its worldline'))
controls = Renderer.controls(ctx, state)
assert(not control(controls, 'save').enabled and not control(controls, 'fit').enabled)
assert(control(controls, 'import').enabled and control(controls, 'close').enabled)
assert(Renderer.geometry(state).canvas.w == 1460 and not Renderer.geometry(state).sidebar)

-- Auto-create off may leave a private working root for ordinary undo. It must
-- not appear as a public worldline or enable save/export/history navigation.
ctx.tree = tree
ctx.has_public_worldline = function() return false end
ctx.auto_create_enabled = function() return false end
state = {layout = Graph.layout(rows), selected = 2, view = {pan_x = 0, pan_y = 0, scale = 1}}
before = signature({state = state, tree = tree, game = G})
calls = {}
Renderer.draw(ctx, state, Graph)
assert(printed('Automatic worldline recording is off; enable it in mod settings'))
assert(not printed('TREE1234') and not printed('$7') and not printed('SMALL BLIND')
    and not printed('CONVERGE HERE'), 'a cached private layout is never drawn as public history')
assert(signature({state = state, tree = tree, game = G}) == before,
    'hiding a private layout does not mutate the private undo state')
controls = Renderer.controls(ctx, state)
for _, key in ipairs({'save', 'export', 'fit', 'focus'}) do
    assert(not control(controls, key).enabled, key .. ' is unavailable for private undo roots')
end
for _, item in ipairs(controls) do assert(item.key ~= 'restore', 'private roots have no convergence sidebar action') end
assert(control(controls, 'undo').enabled, 'ordinary undo remains independent of public worldline recording')
ctx.has_public_worldline = function() return true end
calls = {}
Renderer.draw(ctx, state, Graph)
assert(printed('SMALL BLIND') and not printed('Automatic worldline recording is off; enable it in mod settings'),
    'an existing public worldline stays visible when automatic creation is disabled')
ctx.has_public_worldline, ctx.auto_create_enabled = nil, nil

-- Pointer feedback uses live window coordinates, including letterboxing, and
-- never changes hit boxes or history. A pressed face settles back toward its
-- shadow; disabled controls, drags, closing and an unfocused mouse stay still.
state = {active = true, layout = Graph.layout(rows), selected = 2,
    view = {pan_x = 0, pan_y = 0, scale = 1}}
ctx.tree, ctx.busy = tree, false
geometry = Renderer.geometry(state)
local pointer_x, pointer_y, pointer_down, pointer_focus = 0, 0, false, true
love.mouse = {getPosition = function() return pointer_x, pointer_y end,
    isDown = function() return pointer_down end}
love.window = {hasMouseFocus = function() return pointer_focus end}
love.timer = {getDelta = function() return 0.1 end}
local function pointer_at(c)
    pointer_x = geometry.offset_x + (c.x + c.w / 2) * geometry.ui_scale
    pointer_y = geometry.offset_y + (c.y + c.h / 2) * geometry.ui_scale
end
local function label_y(label)
    local y
    for _, call in ipairs(matching('print')) do if call.args[1] == label then y = call.args[3] end end
    return assert(y, 'Missing label ' .. label)
end
controls = Renderer.controls(ctx, state, geometry)
for _, key in ipairs({'save', 'export', 'import', 'archives', 'folder', 'undo', 'fit', 'focus', 'zoom_in', 'zoom_out', 'close', 'restore'}) do
    local c = control(controls, key)
    pointer_at(c); calls = {}; Renderer.draw(ctx, state, Graph)
    near(label_y(c.label), c.y + 1)
end
local save = control(controls, 'save')
pointer_at(save); pointer_down = true
calls = {}; Renderer.draw(ctx, state, Graph); near(label_y('SAVE'), save.y + 3.5)
pointer_down = false
for _, condition in ipairs({'disabled', 'drag', 'closing', 'unfocused'}) do
    ctx.busy, state.drag = condition == 'disabled', condition == 'drag' and {} or nil
    state.transition_target = condition == 'closing' and 0 or 1
    pointer_focus = condition ~= 'unfocused'
    calls = {}; Renderer.draw(ctx, state, Graph); near(label_y('SAVE'), save.y + 4)
end
ctx.busy, state.drag, state.transition_target, pointer_focus = false, nil, 1, true
G.CONTROLLER = {text_input_hook = {}}
assert(not control(Renderer.controls(ctx, state), 'undo').enabled, 'text input disables HUD and tree Undo consistently')
G.CONTROLLER = nil
local before_hover = signature({state = state, tree = tree, game = G})
pointer_at(save); calls = {}; Renderer.draw(ctx, state, Graph)
assert(signature({state = state, tree = tree, game = G}) == before_hover)

-- The animation scales the whole native canvas. Input inverts that transform
-- around the window centre before applying letterboxing; HUD stays unscaled.
state.transition = 0.5
local moving = Renderer.geometry(state)
near(moving.transition_alpha, 0.5); near(moving.transition_scale, 0.985)
local px = geometry.offset_x + 777 * geometry.ui_scale
local py = geometry.offset_y + 333 * geometry.ui_scale
px = geometry.screen_w / 2 + (px - geometry.screen_w / 2) * moving.transition_scale
py = geometry.screen_h / 2 + (py - geometry.screen_h / 2) * moving.transition_scale
x, y = Renderer.to_logical(px, py, moving); near(x, 777); near(y, 333)
state.active = false
near(Renderer.geometry(state).transition_scale, 1)
state.active = true
local previous_smods, previous_canvas = SMODS, G.CANVAS
local composited, canvas_calls = nil, 0
G.CANVAS = {getDimensions = function() return 3840, 2400 end}
SMODS = {load_file = function(name, id)
    assert(id == 'WorldLine', 'runtime helper loading works after SMODS.current_mod is cleared')
    if name == 'ui/compositor.lua' then
        return function() return {draw = function(g, w, h, alpha, scale, callback)
            composited, canvas_calls = {w, h, alpha, scale}, canvas_calls + 1
            callback(); return true
        end} end
    end
    return assert(loadfile('src/' .. name))
end}
local moving_renderer = dofile('src/ui/renderer.lua')
calls = {}; moving_renderer.draw(ctx, state, Graph, {render_scale = 2})
assert(canvas_calls == 1 and composited[1] == 3840 and composited[2] == 2400,
    'transition uses the scene target dimensions rather than window DPI')
near(composited[3], 0.5); near(composited[4], 0.985)
assert(printed('SMALL BLIND') and depth == 0)
SMODS, G.CANVAS = previous_smods, previous_canvas
state.transition, state.transition_target = nil, nil
love.mouse, love.window, love.timer = nil, nil, nil

-- A font failure and an image failure inside nested transforms both unwind all graphics state.
local old_print = graphics.print
graphics.print = function() error('simulated font failure') end
assert(not pcall(Renderer.draw, ctx, state, Graph) and depth == 0)
graphics.print = old_print
ctx.tree = tree
state = {layout = Graph.layout(rows), selected = 2, view = {pan_x = 0, pan_y = 0, scale = 1}}
local old_draw = graphics.draw
graphics.draw = function(image, ...)
    if image == images.blind_chips then error('simulated nested image failure') end
    return old_draw(image, ...)
end
assert(not pcall(Renderer.draw, ctx, state, Graph))
assert(depth == 0, 'failed card drawing unwinds the card, canvas and outer graphics transforms')
assert(current_stencil == inherited_stencil, 'nested failure does not leak stencil state to the native cursor')
graphics.draw = old_draw

-- Cached presentation data never enters the caller's immutable layout. Camera
-- movement reuses it; current/selection/new layout refresh the right colours.
local cache_rows = {
    {id = 1, parent = 0, action = {kind = 'start'}, summary = {ante = 1}},
    {id = 2, parent = 1, action = {kind = 'enter_shop'}, summary = {ante = 1}},
    {id = 3, parent = 1, action = {kind = 'enter_shop'}, summary = {ante = 1}},
}
local cache_tree = {current = 2, metadata = {seed = 'CACHE'}}
local cache_ctx = {tree = cache_tree, text = function(_, en) return en end}
local cache_state = {layout = Graph.layout(cache_rows), screen_w = 1600, screen_h = 900,
    view = {pan_x = 0, pan_y = 0, scale = 1}}
local id_reads, floor_calls, original_floor = 0, 0, math.floor
local function observe_ids(layout)
    local by_id = layout.by_id
    layout.by_id = setmetatable({}, {__index = function(_, id)
        id_reads = id_reads + 1; return by_id[id]
    end})
end
observe_ids(cache_state.layout)
math.floor = function(value) floor_calls = floor_calls + 1; return original_floor(value) end
local function cache_draw()
    id_reads, floor_calls, calls = 0, 0, {}
    Renderer.draw(cache_ctx, cache_state, Graph)
    assert(depth == 0 and current_stencil == inherited_stencil)
    return id_reads, floor_calls
end
local function minimap_colour(id)
    local map, node = Renderer.geometry(cache_state).minimap
    for _, candidate in ipairs(cache_state.layout.nodes) do if candidate.id == id then node = candidate end end
    local x = map.x + original_floor((node.x + node.w / 2) * map.w / cache_state.layout.width / 2) * 2 - 1
    local y = map.y + original_floor((node.y + node.h / 2) * map.h / cache_state.layout.height / 2) * 2 - 1
    local shade
    for _, call in ipairs(calls) do
        if call.name == 'setColor' then shade = call.args end
        if call.name == 'rectangle' and call.args[1] == 'fill' and call.args[2] == x and call.args[3] == y and call.args[4] == 3 and call.args[5] == 3 then
            return shade
        end
    end
    error('Missing minimap cell ' .. id)
end
local function gold(id) local c = minimap_colour(id); return c[1] == 1 and c[2] == 0.82 and c[3] == 0.24 end
local cache_signature = signature({rows = cache_rows, tree = cache_tree, game = G})
local first_reads, first_floors = cache_draw()
assert(first_reads == 4 and gold(2) and not gold(3))
local cached_reads, cached_floors = cache_draw()
assert(cached_reads == 2 and first_floors >= cached_floors + #cache_rows * 2,
    'unchanged frames reuse the current path and minimap buckets')
cache_state.view.pan_x, cache_state.view.scale = -70, 0.7
local moved_reads, moved_floors = cache_draw()
assert(moved_reads == 2 and moved_floors < first_floors,
    'pan and zoom only move the viewport; static graph projections stay cached')
cache_state.selected = 3
local selected_reads, selected_floors = cache_draw()
local selected_colour = minimap_colour(3)
assert(selected_reads == 7 and selected_floors >= cached_floors + #cache_rows * 2
    and selected_colour[1] == 0.38 and selected_colour[2] == 0.75 and selected_colour[3] == 1,
    'selection refreshes minimap priority without walking the current path')
cache_state.selected, cache_tree.current = nil, 3
local changed_reads, changed_floors = cache_draw()
assert(changed_reads == 4 and changed_floors >= cached_floors + #cache_rows * 2 and gold(3) and not gold(2),
    'current-node changes invalidate both the path and minimap colours')
cache_tree.current = 2
cache_draw()
assert(signature({rows = cache_rows, tree = cache_tree, game = G}) == cache_signature,
    'cache construction leaves rows, tree metadata and game state untouched')
local replacement_rows = {cache_rows[1], cache_rows[2],
    {id = 3, parent = 2, action = {kind = 'enter_shop'}, summary = {ante = 1}}}
cache_state.layout, cache_tree.current = Graph.layout(replacement_rows), 3
observe_ids(cache_state.layout)
local replaced_reads, replaced_floors = cache_draw()
assert(replaced_reads == 5 and replaced_floors >= cached_floors + #cache_rows * 2 and gold(2) and gold(3),
    'a replacement layout with matching IDs never reuses the old path or coordinates')
math.floor = original_floor

-- Weak caches must not retain an obsolete layout through their own values.
local discarded_layouts = setmetatable({}, {__mode = 'k'})
local function draw_temporary_layout()
    local temporary = {layout = Graph.layout(cache_rows), screen_w = 1600, screen_h = 900,
        view = {pan_x = 0, pan_y = 0, scale = 1}}
    discarded_layouts[temporary.layout] = true
    Renderer.draw(cache_ctx, temporary, Graph)
end
draw_temporary_layout()
collectgarbage('collect'); collectgarbage('collect')
assert(next(discarded_layouts) == nil, 'cached path/minimap values never strongly retain their weak layout key')


-- Rich details are lazy, cached and read-only, including old archives without fields.
do
    local reads = 0
    local row = {id=77, parent=1, summary={state='SHOP'}, action={kind='leave_shop',
        choices={{kind='buy',card_key='j_test',name='Test Joker',cost=6,money_delta=-4}}}}
    local source = {ante=3,round=7,dollars=12,hands_left=2,discards_left=1,
        jokers={{key='j_test',name='Test Joker',sell_cost=3}},consumables={},vouchers={},tags={},
        deck_stats={total=52,suits={Spades=13,Hearts=13,Clubs=13,Diamonds=13},enhanced=2,editions=1,seals=3},
        hand_levels={{key='Pair',name='Pair',level=2,chips=25,mult=3}}}
    local context = {text=function(_, en) return en end,node_details=function(id)
        assert(id==77); reads=reads+1; return source end}
    local signature_before = signature({row=row,source=source})
    local first = Renderer.detail_rows(context,row,'overview')
    assert(Renderer.detail_rows(context,row,'overview') == first and reads==1)
    local choices = Renderer.detail_rows(context,row,'choices')
    local choice_text = ''
    for _, entry in ipairs(choices) do
        choice_text = choice_text .. (entry.value or '')
        for _, line in ipairs(entry.lines or {}) do choice_text = choice_text .. line.text end
    end
    assert(choice_text:find('Price $6',1,true) and choice_text:find('Money change -4',1,true),
        'quoted cost and authoritative wallet change remain distinct')
    local inventory = Renderer.detail_rows(context,row,'cards')
    local deck, hands = false,false
    for _, entry in ipairs(inventory) do
        deck = deck or entry.label=='Deck composition'
        hands = hands or entry.label=='Pair'
    end
    assert(deck and hands and signature({row=row,source=source})==signature_before)
    local legacy = Renderer.detail_rows({text=context.text},{id=78,summary={}},'overview')
    assert(legacy[1].value=='- / -' and legacy[3].value=='- / -', 'missing legacy values are unknown, not invented zeros')
    local long = string.rep('世界线收藏', 12)
    local named = Renderer.detail_rows({text=context.text},{id=79,summary={},bookmark=long},'overview')
    local reconstructed = ''
    for _, entry in ipairs(named) do for _, line in ipairs(entry.lines or {}) do
        if line.tint and line.size==22 then reconstructed=reconstructed..line.text end
    end end
    assert(reconstructed==long, 'long Chinese names wrap at readable size without losing characters')
    local saved_ctx, saved_state = ctx,state
    ctx = {tree={current=77,metadata={seed='DETAIL'}},text=context.text}
    state = {layout=Graph.layout({{id=1,parent=0,summary={}},row}),selected=77,
        view={pan_x=0,pan_y=0,scale=1}}
    calls={}; Renderer.draw(ctx,state,Graph)
    assert(printed('SHOP') and not printed('Blind selection'), 'entry state determines node title, not incoming choice verb')
    ctx,state=saved_ctx,saved_state
end


-- Snapshot card grids and comparison are bounded, lazy presentation views.
do
    local detail_reads,compare_reads=0,0
    local old={jokers={{key='j_test',set='Joker',name='Before',ability={mult=4}}}}
    local new={jokers={{key='j_test',set='Joker',name='After',ability={mult=8}}}}
    local context={tree={current=2,metadata={seed='CARDS'}},text=function(_,en)return en end,
        node_details=function()detail_reads=detail_reads+1;return new end,
        compare_nodes=function(a,b)
            compare_reads=compare_reads+1;assert(a==1 and b==2)
            return {before_id=a,after_id=b,before=old,after=new,same=false,metrics={},groups={
                {key='jokers',changes={{kind='changed',before=old.jokers[1],after=new.jokers[1]}}}}}
        end}
    local view={layout=Graph.layout({{id=1,parent=0,summary={}},{id=2,parent=1,summary={}}}),selected=2,
        compare_ids={1,2},selections={[1]=true,[2]=true},detail_tab='diff',view={pan_x=0,pan_y=0,scale=1}}
    local geometry=Renderer.geometry(view)
    local targets=Renderer.card_targets(context,view,geometry)
    assert(#targets==2 and targets[1].side=='before' and targets[1].node_id==1 and targets[2].node_id==2)
    assert(targets[1].item.ability.mult==4 and targets[2].item.ability.mult==8)
    assert(Renderer.card_targets(context,view,geometry)==targets and compare_reads==1 and detail_reads==1)
    Renderer.detail_scroll_max(context,view);assert(compare_reads==1)
    local controls=Renderer.controls(context,view,geometry)
    assert(control(controls,'tab_diff').selected and control(controls,'swap_compare'))
    view.drag={kind='select',sidebar_before=false}
    assert(not Renderer.geometry(view).sidebar and Renderer.geometry(view).canvas.w==1460,
        'selecting the first card never shrinks the canvas halfway through a marquee drag')
    view.selected=nil;view.drag.sidebar_before=true
    assert(Renderer.geometry(view).sidebar and Renderer.geometry(view).canvas.w==1120,
        'temporarily empty selections keep the starting canvas width during drag')
end


-- Inventory groups are visual card areas, not repeated category text. Hidden
-- counts belong to the enclosing fold region, never to either boundary card.
do
    local r={{id=1,parent=0,collapsed_count=3,summary={}},{id=2,parent=1,summary={}}}
    r.fold_regions={{id=7,start_id=1,end_id=2,label='Folded sequence',hidden_count=3,collapsed=true}}
    local layout=Graph.layout(r)
    local context={tree={current=2,metadata={seed='GROUPED'}},text=function(_,en)return en end,
        node_details=function()return {jokers={{key='j_test',set='Joker'}},consumables={},vouchers={},tags={}} end}
    local view={layout=layout,selected=2,detail_tab='cards',view={pan_x=0,pan_y=0,scale=1}}
    calls={};Renderer.draw(context,view,Graph)
    assert(not printed('JOKERS ') and not printed('Consumables') and not printed('Vouchers'),
        'card groups do not repeat type headings over individual cards')
    local badges=0
    for _,call in ipairs(matching('print')) do if call.args[1]=='+3' then badges=badges+1 end end
    assert(badges==1,'one region-level hidden-count badge; no duplicate on the start card')
    context.tree.metadata.name='My saved route'
    calls={};Renderer.draw(context,view,Graph)
    assert(printed('My saved route'),'a renamed worldline is visible in the header without replacing its seed')
    local controls=Renderer.controls(context,view,Renderer.geometry(view))
    assert(control(controls,'manage') and control(controls,'bookmark')
        and control(controls,'manage').x>control(controls,'bookmark').x,
        'node management shares the existing bookmark row without covering cards or the restore action')
end

love, G, math.random, math.randomseed, pseudorandom, pseudorandom_element, save_run, Card, UIBox, Sprite, AnimatedSprite =
    previous.love, previous.G, previous.random, previous.randomseed, previous.pseudorandom,
    previous.pseudorandom_element, previous.save_run, previous.Card, previous.UIBox, previous.Sprite, previous.AnimatedSprite
localize = previous.localize

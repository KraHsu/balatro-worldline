local Graph = dofile('src/ui/graph.lua')
local Selection = dofile('src/ui/selection.lua')
local Native = dofile('src/ui/native_visuals.lua')
local ActualRenderer = dofile('src/ui/renderer.lua')
local drawn, fail_draw, original_keys, original_mouse, prepared, closes, original_pad = 0, false, 0, 0, 0, 0, 0
local original_release = 0
local shown, keybind, restored, checks, shortcut_calls = nil, nil, nil, 0, 0
local current_canvas, canvas_result, draw_options, native_frames, hook, UI = nil, nil, nil, 0, nil, nil
local canvas, aa_canvas, trace = {}, {}, {}
local bounds = {x = 20, y = 100, w = 1200, h = 600}
local input_scale, input_offset_x, input_offset_y = 2, 0, 0
local geometry_state, minimap_bounds, sidebar_bounds
local pointer_x, pointer_y = 600, 500
local Renderer = {
    geometry = function(value)
        geometry_state = value
        return {canvas = bounds, minimap = minimap_bounds, sidebar = sidebar_bounds, ui_scale = input_scale,
            offset_x = input_offset_x, offset_y = input_offset_y}
    end,
    minimap_viewport = function(value, geometry)
        return Native.viewport(value.layout, value.view, geometry.canvas, geometry.minimap, Graph)
    end,
    to_logical = function(x, y) return (x - input_offset_x) / input_scale, (y - input_offset_y) / input_scale end,
    controls = function() return {{key = 'save', x = 0, y = 0, w = 80, h = 40}} end,
    draw = function(_, _, _, options)
        assert(current_canvas == canvas, 'Tree must be drawn into the native scene canvas')
        draw_options = options
        drawn = drawn + 1
        trace[#trace + 1] = 'tree'
        if fail_draw then error('test renderer failure') end
    end,
}
G = {UIT = {R = 'row', C = 'column', T = 'text'}, SETTINGS = {paused = false},
    C = {UI = {TEXT_LIGHT = {}}, BLUE = {}}, FUNCS = {}, CONTROLLER = {},
    CANVAS = canvas, AA_CANVAS = aa_canvas, CANV_SCALE = 2, I = {UIBOX = {}}}
G.FUNCS.overlay_menu = function(args)
    if G.OVERLAY_MENU then G.OVERLAY_MENU:remove() end
    shown = args.definition
    local overlay = {definition = args.definition, config = args.config or {}, states = {visible = true}}
    function overlay:remove()
        assert(not self.REMOVED, 'An overlay must be removed only once')
        self.REMOVED = true
        for index, box in ipairs(G.I.UIBOX) do
            if box == self then table.remove(G.I.UIBOX, index); break end
        end
    end
    G.OVERLAY_MENU = overlay
    G.I.UIBOX[#G.I.UIBOX + 1] = overlay
end
G.FUNCS.exit_overlay_menu = function()
    if G.OVERLAY_MENU then G.OVERLAY_MENU:remove() end
    closes = closes + 1; G.OVERLAY_MENU = nil; G.SETTINGS.paused = false
end
UIBox_button = function(args) return args end
create_UIBox_generic_options = function(args) return args end
create_UIBox_options = function()
    return {nodes = {{nodes = {{nodes = {{nodes = {{original = true}}}}}}}}}
end
SMODS = {current_mod = {id = 'WorldLine'}, Keybind = function(args) keybind = args end,
    load_file = function(path)
        if path == 'loader.lua' then return assert(loadfile('src/loader.lua')) end
        return function() return path == 'ui/graph.lua' and Graph or path == 'ui/selection.lua' and Selection or Renderer end
    end}
love = {mouse = {getPosition = function() return pointer_x, pointer_y end},
    graphics = {getCanvas = function() return canvas_result or current_canvas end},
    keypressed = function() original_keys = original_keys + 1; return 'native' end,
    mousepressed = function() original_mouse = original_mouse + 1 end,
    mousereleased = function() original_release = original_release + 1 end,
    gamepadpressed = function() original_pad = original_pad + 1 end,
    draw = function()
        native_frames = native_frames + 1
        current_canvas = canvas
        trace[#trace + 1] = 'native_scene'
        if hook then hook() end
        trace[#trace + 1] = 'native_cursor'
        current_canvas = aa_canvas
        trace[#trace + 1] = 'native_CRT_from_scene_canvas'
        current_canvas = nil
        trace[#trace + 1] = 'native_AA_to_screen'
    end}
local original_love_draw = love.draw
local rows = {
    {id = 1, parent = 0, children = {2}, summary = {}},
    {id = 2, parent = 1, children = {3, 4}, summary = {}},
    {id = 3, parent = 2, children = {}, summary = {}},
    {id = 4, parent = 2, children = {}, summary = {}},
}
local ctx = {tree = {current = 4, next_id = 5, metadata = {seed = 'TREEDEMO', run_id = 'ui-test'},
    rows = function() return rows end, get = function(_, id) return rows[id] end},
    text = function(_, en) return en end,
    before_open = function() prepared = prepared + 1; return true end,
    at_current_node = function() checks = checks + 1; return false end,
    save_now = function() return true end,
    export_share = function() return 'exports/test.worldline.json' end,
    import_latest = function() return nil, 'No import file' end,
    open_data_folder = function() return true end,
    archive_rows = function() return {{id = 'one', label = 'Test tree'}} end,
    load_archive = function() return true end,
}
ctx.request_restore = function(id) restored = id; ctx.busy = true; return true end
UI = dofile('src/ui/controller.lua')
UI.install(ctx)
assert(love.draw == original_love_draw, 'Tree never appends raw graphics after the native CRT pass')
hook = function()
    UI.draw_before_overlay(ctx,G)
    if UI.state.modal then trace[#trace+1]='native_modal' end
    UI.draw_native(ctx, G)
end
love.draw()
assert(drawn == 0 and native_frames == 1, 'inactive native hook leaves the ordinary render pipeline alone')
assert(keybind.key_pressed == 'f6')
ctx.before_open = function() return false end
assert(UI.open(ctx) == false and not UI.state.active and not G.SETTINGS.paused)
ctx.open = function() shortcut_calls = shortcut_calls + 1; return false end
G.FUNCS.worldline_open()
assert(shortcut_calls == 1 and not UI.state.active, 'deferred native button invokes one opening path')
G.CONTROLLER.locked, G.CONTROLLER.locks = true, {frame = true}
love.keypressed('f6', 'f6', false)
assert(shortcut_calls == 2 and original_keys == 0 and ctx.last_hotkey_source == 'LÖVE')
love.keypressed('f6', 'f6', true)
assert(shortcut_calls == 2, 'held F6 does not reopen repeatedly')
assert(love.keypressed('a', 'a', false) == 'native')
G.CONTROLLER.text_input_hook = {}
love.keypressed('f6', 'f6', false)
assert(shortcut_calls == 2 and ctx.last_hotkey_message:find('text input'))
G.CONTROLLER.text_input_hook = nil
ctx.open = nil
ctx.before_open = function() prepared = prepared + 1; return true end
keybind.action()
assert(prepared == 1 and ctx.ui_view == 'tree' and G.SETTINGS.paused and UI.state.active)
assert(UI.state.transition == 0 and UI.state.transition_target == 1)
UI.update(ctx, 0.14)
assert(math.abs(UI.state.transition - 0.5) < 0.000001 and G.SETTINGS.paused,
    'opening advances over 0.28 seconds while the scene stays paused')
UI.update(ctx, 0.14)
assert(UI.state.transition == 1 and UI.state.active)
assert(shown == nil, 'graph opens directly without a list menu')
assert(UI.state.layout.by_id[1].x < UI.state.layout.by_id[4].x)
assert(UI.state.at_current_node == false and checks == 1)
love.gamepadpressed({}, 'a')
assert(original_pad == 0, 'hidden native menus cannot be activated by gamepad presses')
trace = {}
love.draw(); love.draw()
assert(drawn == 2 and checks == 1, 'native drawing does not refresh or save the live snapshot')
assert(draw_options.render_scale == 2 and draw_options.native_background == true)
assert(table.concat(trace, ',') == 'native_scene,tree,native_cursor,native_CRT_from_scene_canvas,native_AA_to_screen,'
    .. 'native_scene,tree,native_cursor,native_CRT_from_scene_canvas,native_AA_to_screen',
    'the tree and native cursor enter the original CRT/AA pipeline once, in order')
current_canvas = aa_canvas
assert(UI.draw_native(ctx, G) == false and drawn == 2 and UI.state.active,
    'the hook refuses a postprocess/screen target without closing the UI')
local real_canvas = G.CANVAS
G.CANVAS = nil
assert(UI.draw_native(ctx, G) == false and drawn == 2, 'missing scene canvas never falls back to post-CRT drawing')
G.CANVAS, current_canvas = real_canvas, nil
-- LÖVE 11.5 returns table-of-tables with a custom depth/stencil target.
-- SMODS src/ui.lua strips its outer depthstencil setup, leaving a one-element
-- RenderTarget table. Both still render into exactly the same color Canvas.
local stencil = {}
local native_setup = {{canvas, mipmap = 1}, depthstencil = {stencil, mipmap = 1}}
for _, target in ipairs({canvas, {canvas, mipmap = 1}, native_setup,
    {canvas, depthstencil = stencil}}) do
    local before_drawn = drawn
    current_canvas, canvas_result = canvas, target
    assert(UI.draw_native(ctx, G) == true and drawn == before_drawn + 1 and UI.state.active,
        'direct, SMODS-unwrapped and native nested scene targets all render the tree')
    assert(ctx.native_render.scene_canvas and ctx.native_render.drawn,
        'diagnostics identify accepted scene target representations')
    assert(canvas_result == target, 'draw does not replace the engine render-target setup')
end
assert(native_setup[1][1] == canvas and native_setup.depthstencil[1] == stencil
    and native_setup[1].mipmap == 1, 'the stencil attachment and subresource metadata remain intact')
for _, target in ipairs({{aa_canvas, mipmap = 1},
    {{aa_canvas, mipmap = 1}, depthstencil = {canvas, mipmap = 1}},
    {depthstencil = {canvas, mipmap = 1}}}) do
    local before_drawn = drawn
    current_canvas, canvas_result = aa_canvas, target
    assert(UI.draw_native(ctx, G) == false and drawn == before_drawn and UI.state.active,
        'a scene canvas used only as a depth attachment is not an active scene color target')
    assert(not ctx.native_render.scene_canvas and not ctx.native_render.drawn)
end
current_canvas, canvas_result = nil, nil
local before_screen_drawn = drawn
assert(UI.draw_native(ctx, G) == false and drawn == before_screen_drawn and UI.state.active,
    'the default screen target is not mistaken for the native scene canvas')
UI.action(ctx, 'export')
assert(UI.state.notice:find('exports/test.worldline.json') and UI.state.active)
UI.action(ctx, 'import')
assert(UI.state.notice == 'No import file' and UI.state.active)

-- Accepting a save request is not a durability ACK. Keep the pending label
-- until the background writer succeeds, and expose failures while retrying.
local pending_save, pending_error = true, nil
ctx.save_status = function() return pending_save, pending_error end
UI.action(ctx, 'save')
assert(UI.state.notice == 'Saving worldline...')
UI.update(ctx, 0.01)
assert(UI.state.notice == 'Saving worldline...')
pending_error = 'disk full'
UI.update(ctx, 0.01)
assert(UI.state.notice == 'disk full' and UI.state.waiting_save)
pending_save, pending_error = false, nil
UI.update(ctx, 0.01)
assert(UI.state.notice == 'Worldline saved' and not UI.state.waiting_save)
ctx.save_status = nil

-- Rendering computes button hover from the live pointer; input routing must
-- retain the same topmost hit rule and never turn pointer motion into actions.
local old_controls, old_save, old_export = Renderer.controls, ctx.save_now, ctx.export_share
local saved_pan_x, saved_pan_y = UI.state.view.pan_x, UI.state.view.pan_y
local saves, exports, button_x, top_enabled = 0, 0, 390, false
ctx.save_now = function() saves = saves + 1; return true end
ctx.export_share = function() exports = exports + 1; return 'test export' end
Renderer.controls = function()
    return {{key = 'save', x = button_x, y = 190, w = 100, h = 40, enabled = true},
        {key = 'export', x = button_x, y = 190, w = 100, h = 40, enabled = top_enabled}}
end
UI.state.hover = 1
love.mousemoved(800, 400, 1, 1)
assert(saves == 0 and exports == 0 and UI.state.drag == nil,
    'moving over a button is visual feedback only')
assert(UI.state.hover == nil, 'controls occlude card hover, even when their hit region overlaps the canvas')
love.mousepressed(800, 400, 1); love.mousereleased(800, 400, 1)
assert(saves == 0 and exports == 0 and UI.state.drag == nil and original_mouse == 0,
    'a disabled topmost control consumes the hit instead of activating the enabled control below')

-- A sidebar/resize can move a control without a mousemove event. Clicks use
-- current geometry and window-logical coordinates once, independently of the
-- native scene Canvas render scale and texture DPIScale.
top_enabled, button_x = true, 700
input_scale, input_offset_x, input_offset_y = 1.25, 37, 53
love.mousepressed(37 + 710 * 1.25, 53 + 200 * 1.25, 1)
love.mousereleased(37 + 710 * 1.25, 53 + 200 * 1.25, 1)
assert(exports == 1 and saves == 0 and UI.state.drag == nil,
    'layout changes and letterboxing preserve the same enabled hover/click hit region')
input_scale, input_offset_x, input_offset_y = 2, 0, 0
love.mousepressed(200, 1200, 1)
love.mousemoved(1420, 400, 1220, -800)
assert(UI.state.drag and UI.state.drag.moved, 'renderer can suppress button hover while a canvas drag is active')
assert(UI.state.hover == nil, 'a canvas drag never highlights nodes underneath the grabbed pointer')
love.mousereleased(1420, 400, 1)
assert(exports == 1 and saves == 0 and not UI.state.drag,
    'a canvas drag released over a control never clicks it')

-- Minimap controls overlap the canvas edge in the real layout. They own that
-- pointer region and must never begin a card-selection/canvas-drag gesture.
Renderer.controls = function() return {{key = 'minimap', x = 400, y = 650, w = 100, h = 40}} end
UI.state.hover = 1
love.mousemoved(810, 1320, 1, 1)
assert(UI.state.hover == nil, 'the minimap blocks hover on a node behind its overlapping canvas region')
love.mousepressed(810, 1320, 1); love.mousereleased(810, 1320, 1)
assert(not UI.state.drag and saves == 0 and exports == 1 and original_mouse == 0)

-- Grabbing anywhere inside the visible viewport keeps that point under the
-- pointer, rather than jumping its centre to the press. Only the camera moves.
local layout_w, layout_h = UI.state.layout.width, UI.state.layout.height
local old_view_scale, old_selected = UI.state.view.scale, UI.state.selected
UI.state.layout.width, UI.state.layout.height = 6000, 3000
UI.state.view.scale, UI.state.view.pan_x, UI.state.view.pan_y = 0.8, -900, -480
UI.state.selected = 2
minimap_bounds = {key = 'minimap', x = 400, y = 650, w = 100, h = 40, enabled = true}
Renderer.controls = function() return {minimap_bounds} end
local viewport = Renderer.minimap_viewport(UI.state, Renderer.geometry(UI.state))
local grab_x, grab_y = viewport.x + viewport.w * 0.2, viewport.y + viewport.h * 0.7
local release_count = original_release
love.mousepressed(grab_x * 2, grab_y * 2, 1)
assert(UI.state.drag and UI.state.drag.kind == 'minimap'
    and UI.state.view.pan_x == -900 and UI.state.view.pan_y == -480,
    'pressing the viewport preserves the initial camera even away from its centre')
love.mousemoved((grab_x + 10) * 2, (grab_y + 5) * 2, 20, 10)
assert(math.abs(UI.state.view.pan_x + 1380) < 0.000001 and math.abs(UI.state.view.pan_y + 780) < 0.000001,
    'minimap motion maps both axes to graph world units and moves the viewport with the pointer')
local drag_pan, drag_scale = UI.state.view.pan_x, UI.state.view.scale
love.wheelmoved(0, 1); love.keypressed('home', 'home', false); love.keypressed('right', 'right', false)
assert(UI.state.view.pan_x == drag_pan and UI.state.view.scale == drag_scale,
    'view shortcuts and wheel cannot invalidate the held minimap anchor')
love.mousereleased(grab_x * 2, grab_y * 2, 2)
assert(UI.state.drag, 'releasing another button does not end the left-button gesture')
love.mousemoved(1400, 1440, 0, 0)
assert(UI.state.view.pan_x < drag_pan and UI.state.drag, 'capture continues outside the minimap')
local captured = UI.state.drag
love.mousepressed(200, 1200, 2); love.mousereleased(200, 1200, 2)
assert(UI.state.drag == captured, 'an extra press over the canvas cannot steal the held minimap gesture')
love.mousereleased(40, 40, 1)
assert(not UI.state.drag and UI.state.selected == 2 and original_release == release_count
    and saves == 0 and exports == 1, 'release ends navigation without selecting a card or activating the scene beneath')

-- Clicking outside the rectangle retains the previous jump-to-location action.
UI.state.view.pan_x, UI.state.view.pan_y = -900, -480
love.mousepressed(990, 1370, 1)
assert(UI.state.view.pan_x == bounds.w / 2 - 5700 * 0.8
    and UI.state.view.pan_y == bounds.h / 2 - 2625 * 0.8)
love.mousereleased(990, 1370, 1)
assert(UI.state.selected == 2)
for _, which in ipairs({2, 3}) do
    love.mousepressed(810, 1320, which); love.mousereleased(810, 1320, which)
    assert(not UI.state.drag, 'all minimap buttons occlude overlapping canvas; only left starts dragging')
end
minimap_bounds.enabled = false
drag_pan = UI.state.view.pan_x
love.mousepressed(810, 1320, 1); love.mousereleased(810, 1320, 1)
assert(not UI.state.drag and UI.state.view.pan_x == drag_pan, 'disabled minimap never starts navigation')
minimap_bounds.enabled = true

-- Wheel over the map keeps its graph-world point at the point's existing
-- main-canvas projection, rather than first jumping the camera to the map.
local function near(a, b) assert(math.abs(a - b) < 0.000001, tostring(a) .. ' ~= ' .. tostring(b)) end
local wheel_selection, wheel_cursor, wheel_next = UI.state.selected, ctx.tree.current, ctx.tree.next_id
local history_child = rows[2].children[1]
UI.state.view.scale, UI.state.view.pan_x, UI.state.view.pan_y = 0.8, -900, -480
local map_x, map_y = minimap_bounds.x + minimap_bounds.w * 0.3, minimap_bounds.y + minimap_bounds.h * 0.2
local world_x, world_y = UI.state.layout.width * 0.3, UI.state.layout.height * 0.2
local anchor_x, anchor_y = Graph.world_to_screen(UI.state.view, world_x, world_y, bounds)
assert(math.abs(anchor_y - (bounds.y + bounds.h / 2)) > 100)
pointer_x, pointer_y = map_x * 2, map_y * 2
love.wheelmoved(0, 1)
near(UI.state.view.scale, 0.92)
local point_x, point_y = Graph.world_to_screen(UI.state.view, world_x, world_y, bounds)
near(point_x, anchor_x); near(point_y, anchor_y)
assert(map_y >= bounds.y and map_y <= bounds.y + bounds.h,
    'the test pointer lies in the minimap/canvas overlap so map wheel must take precedence')
love.wheelmoved(0, 100)
near(UI.state.view.scale, Graph.MAX_SCALE)
point_x, point_y = Graph.world_to_screen(UI.state.view, world_x, world_y, bounds)
near(point_x, anchor_x); near(point_y, anchor_y)
love.wheelmoved(0, -200)
near(UI.state.view.scale, Graph.MIN_SCALE)
point_x, point_y = Graph.world_to_screen(UI.state.view, world_x, world_y, bounds)
near(point_x, anchor_x); near(point_y, anchor_y)
local minimum_x, minimum_y = UI.state.view.pan_x, UI.state.view.pan_y
love.wheelmoved(0, -1)
near(UI.state.view.pan_x, minimum_x); near(UI.state.view.pan_y, minimum_y)

-- A disabled map consumes its overlap, and empty graphs/outside pointers/zero
-- vertical deltas do not navigate. Outside the map, ordinary canvas wheel works.
minimap_bounds.enabled = false
love.wheelmoved(0, 1)
near(UI.state.view.scale, Graph.MIN_SCALE); near(UI.state.view.pan_x, minimum_x)
minimap_bounds.enabled = true
local before_width = UI.state.layout.width
UI.state.layout.width = 0
love.wheelmoved(0, 1)
UI.state.layout.width = before_width
near(UI.state.view.scale, Graph.MIN_SCALE); near(UI.state.view.pan_y, minimum_y)
pointer_x, pointer_y = 3000, 1560
love.wheelmoved(0, 1)
near(UI.state.view.scale, Graph.MIN_SCALE); near(UI.state.view.pan_x, minimum_x)
love.wheelmoved(2, 0)
near(UI.state.view.scale, Graph.MIN_SCALE)
pointer_x, pointer_y = map_x * 2, (minimap_bounds.y - 10) * 2
local canvas_world_x, canvas_world_y = Graph.screen_to_world(UI.state.view, map_x, minimap_bounds.y - 10, bounds)
love.wheelmoved(0, 1)
near(UI.state.view.scale, Graph.MIN_SCALE * 1.15)
point_x, point_y = Graph.world_to_screen(UI.state.view, canvas_world_x, canvas_world_y, bounds)
near(point_x, map_x); near(point_y, minimap_bounds.y - 10)

-- Exercise the real renderer's letterbox + animation inverse, not a duplicate
-- UI coordinate formula. The mapped world point is allowed to be offscreen.
local fake_geometry, fake_to_logical = Renderer.geometry, Renderer.to_logical
Renderer.geometry = function()
    local geometry = ActualRenderer.geometry({screen_w = 1920, screen_h = 1200,
        active = true, transition = 0.5})
    geometry.canvas, geometry.minimap = bounds, minimap_bounds
    return geometry
end
Renderer.to_logical = ActualRenderer.to_logical
local animated_geometry = Renderer.geometry()
UI.state.view.scale, UI.state.view.pan_x, UI.state.view.pan_y = 0.8, -10000, 20000
local input_x = animated_geometry.offset_x + map_x * animated_geometry.ui_scale
local input_y = animated_geometry.offset_y + map_y * animated_geometry.ui_scale
pointer_x = animated_geometry.screen_w / 2 + (input_x - animated_geometry.screen_w / 2) * animated_geometry.transition_scale
pointer_y = animated_geometry.screen_h / 2 + (input_y - animated_geometry.screen_h / 2) * animated_geometry.transition_scale
anchor_x, anchor_y = Graph.world_to_screen(UI.state.view, world_x, world_y, bounds)
assert(anchor_x < bounds.x and anchor_y > bounds.y + bounds.h)
love.wheelmoved(0, 1)
near(UI.state.view.scale, 0.92)
point_x, point_y = Graph.world_to_screen(UI.state.view, world_x, world_y, bounds)
near(point_x, anchor_x); near(point_y, anchor_y)
assert(UI.state.selected == wheel_selection and ctx.tree.current == wheel_cursor
    and ctx.tree.next_id == wheel_next and rows[2].children[1] == history_child,
    'minimap wheel changes only the camera, never selection or worldline history')
Renderer.geometry, Renderer.to_logical = fake_geometry, fake_to_logical
pointer_x, pointer_y = 600, 500
UI.state.view.scale = 0.8

-- Letterboxing/resize rebases a held gesture without a camera jump, after
-- which further movement uses the new mapping. Close still owns its release.
UI.state.view.pan_x, UI.state.view.pan_y = -900, -480
viewport = Renderer.minimap_viewport(UI.state, Renderer.geometry(UI.state))
grab_x, grab_y = viewport.x + viewport.w / 2, viewport.y + viewport.h / 2
love.mousepressed(grab_x * 2, grab_y * 2, 1)
input_scale, input_offset_x, input_offset_y = 1.25, 37, 53
love.mousemoved(37 + grab_x * 1.25, 53 + grab_y * 1.25, 0, 0)
assert(UI.state.view.pan_x == -900 and UI.state.view.pan_y == -480)
love.mousemoved(37 + (grab_x + 10) * 1.25, 53 + grab_y * 1.25, 12.5, 0)
assert(math.abs(UI.state.view.pan_x + 1380) < 0.000001)
UI.close(ctx)
assert(not UI.state.drag and UI.state.transition_target == 0)
UI.update(ctx, 0.24); love.mousereleased(10, 10, 1)
assert(original_release == release_count, 'closing during a minimap drag consumes the eventual release')
UI.open(ctx, true); UI.update(ctx, 0.28)
input_scale, input_offset_x, input_offset_y = 2, 0, 0
minimap_bounds = nil
UI.state.layout.width, UI.state.layout.height = layout_w, layout_h
UI.state.view.scale, UI.state.selected = old_view_scale, old_selected
Renderer.controls, ctx.save_now, ctx.export_share = old_controls, old_save, old_export
UI.state.view.pan_x, UI.state.view.pan_y, UI.state.hover = saved_pan_x, saved_pan_y, nil

-- Real graph hit testing, with physical window coordinates converted once.
local node = UI.state.layout.by_id[2]
local nx, ny = Graph.world_to_screen(UI.state.view, node.cx, node.cy, bounds)
love.mousepressed(nx * 2, ny * 2, 1)
love.mousereleased(nx * 2, ny * 2, 1)
assert(UI.state.selected == 2 and original_mouse == 0, 'node click selects its details without gameplay input')
Selection.set(UI.state, {}, nil, nil)
local old_pan = UI.state.view.pan_x
love.mousepressed(100, 1100, 2)
love.mousemoved(180, 1140, 80, 40)
love.mousereleased(180, 1140, 2)
assert(UI.state.view.pan_x == old_pan + 40 and UI.state.selected == nil, 'right drag moves canvas without selecting')

-- Multi-selection belongs solely to the viewer. Left drag boxes, Ctrl toggles
-- or adds, Shift traverses the actual ancestry path through its common ancestor.
do
    local keyboard, ctrl, shift = love.keyboard, false, false
    love.keyboard = {isDown = function(left)
        return left == 'lctrl' and ctrl or left == 'lshift' and shift or false
    end}
    Graph.fit(UI.state.view, UI.state.layout, bounds)
    local function click_node(id, which)
        local item = UI.state.layout.by_id[id]
        local x, y = Graph.world_to_screen(UI.state.view, item.cx, item.cy, bounds)
        love.mousepressed(x * 2, y * 2, which or 1)
        love.mousereleased(x * 2, y * 2, which or 1)
    end
    local function order(expected)
        assert(table.concat(UI.state.selection_order, ',') == expected)
    end
    local cursor, next_id, native_clicks = ctx.tree.current, ctx.tree.next_id, original_mouse
    click_node(2); order('2')
    ctrl = true; click_node(4); ctrl = false
    order('2,4'); assert(UI.state.compare_ids[1] == 2 and UI.state.compare_ids[2] == 4
        and UI.state.detail_tab == 'diff' and UI.state.selected == 4)
    UI.action(ctx, 'swap_compare'); order('4,2')
    assert(UI.state.compare_ids[1] == 4 and UI.state.selected == 4)
    shift = true; click_node(3); shift = false
    order('4,2,3'); assert(not UI.state.compare_ids and UI.state.selected == 3)
    ctrl = true; click_node(2); ctrl = false
    order('4,3'); assert(UI.state.compare_ids and UI.state.detail_tab == 'diff')
    local x, y = (bounds.x + 2) * 2, (bounds.y + 2) * 2
    love.mousepressed(x, y, 1); love.mousereleased(x, y, 1)
    order(''); assert(not UI.state.selected)

    local item = UI.state.layout.by_id[3]
    local left, top = Graph.world_to_screen(UI.state.view, item.x + 1, item.y + 1, bounds)
    local right, bottom = Graph.world_to_screen(UI.state.view, item.x + item.w - 1, item.y + item.h - 1, bounds)
    local pan_x, pan_y = UI.state.view.pan_x, UI.state.view.pan_y
    love.mousepressed(left * 2, top * 2, 1)
    love.mousemoved(right * 2, bottom * 2, (right-left)*2, (bottom-top)*2)
    assert(UI.state.drag.kind == 'select' and UI.state.selection_box
        and UI.state.view.pan_x == pan_x and UI.state.view.pan_y == pan_y)
    order('3')
    love.mousereleased(right * 2, bottom * 2, 1)
    assert(not UI.state.selection_box and not UI.state.drag)
    click_node(2); ctrl = true
    love.mousepressed(left * 2, top * 2, 1)
    love.mousemoved(right * 2, bottom * 2, 10, 10)
    love.mousereleased(right * 2, bottom * 2, 1); ctrl = false
    order('2,3')
    love.mousepressed(left * 2, top * 2, 2)
    love.mousemoved((left + 15) * 2, (top + 10) * 2, 30, 20)
    love.mousereleased((left + 15) * 2, (top + 10) * 2, 2)
    order('2,3'); assert(UI.state.view.pan_x == pan_x + 15 and UI.state.view.pan_y == pan_y + 10)
    sidebar_bounds = {x = left, y = top, w = right-left, h = bottom-top}
    love.mousepressed((left + 5) * 2, (top + 5) * 2, 1)
    assert(not UI.state.drag, 'sidebar card/tooltip areas cannot begin a canvas selection')
    love.mousereleased((left + 5) * 2, (top + 5) * 2, 1)
    sidebar_bounds = nil
    assert(ctx.tree.current == cursor and ctx.tree.next_id == next_id and original_mouse == native_clicks,
        'selection and comparison never restore, save, commit or forward gameplay clicks')

    -- Real renderer layout shrinks the canvas when a selected node opens the
    -- detail panel. Freeze that choice through a marquee, including release.
    local saved_geometry = Renderer.geometry
    local geometry_widths = {}
    Renderer.geometry = function(value)
        local sidebar = value and value.selected ~= nil
        if value and value.drag and value.drag.kind == 'select' then sidebar = value.drag.sidebar_before end
        local width = sidebar and 800 or 1200
        geometry_widths[#geometry_widths + 1] = width
        return {canvas = {x = bounds.x, y = bounds.y, w = width, h = bounds.h},
            sidebar = sidebar and {x = bounds.x + width, y = bounds.y, w = 400, h = bounds.h} or nil,
            ui_scale = input_scale, offset_x = input_offset_x, offset_y = input_offset_y}
    end
    Selection.set(UI.state, {}, nil, nil)
    Graph.fit(UI.state.view, UI.state.layout, bounds)
    item = UI.state.layout.by_id[2]
    left, top = Graph.world_to_screen(UI.state.view, item.x + 1, item.y + 1, bounds)
    right, bottom = Graph.world_to_screen(UI.state.view, item.x + item.w - 1, item.y + item.h - 1, bounds)
    love.mousepressed(left * 2, top * 2, 1)
    love.mousemoved((left + 8) * 2, (top + 8) * 2, 16, 16)
    assert(UI.state.selected == 2 and UI.state.drag.sidebar_before == false)
    local first_x, first_y = UI.state.drag.start_x, UI.state.drag.start_y
    love.mousemoved(right * 2, bottom * 2, 20, 20)
    assert(UI.state.drag.start_x == first_x and UI.state.drag.start_y == first_y
        and UI.state.selection_box.w == right-left and UI.state.selection_box.h == bottom-top,
        'newly selected cards do not change the marquee coordinate system mid-drag')
    love.mousereleased(right * 2, bottom * 2, 1)
    for _, width in ipairs(geometry_widths) do assert(width == 1200) end
    assert(Renderer.geometry(UI.state).canvas.w == 800, 'detail sidebar appears after release')
    Renderer.geometry = saved_geometry
    love.keyboard = keyboard
end
local old_scale = UI.state.view.scale
love.wheelmoved(0, 1)
assert(UI.state.view.scale > old_scale, 'wheel zooms the graph')
old_pan = UI.state.view.pan_x
love.keypressed('right', 'right', false)
assert(UI.state.view.pan_x == old_pan - 55 and original_keys == 1)
UI.detail(ctx, 3)
UI.action(ctx, 'restore')
assert(restored == 3 and not UI.state.active and not G.SETTINGS.paused)
ctx.busy = false
G.SETTINGS.paused = true
UI.open(ctx, true)
UI.update(ctx, 0.28)
love.keypressed('escape', 'escape', false)
assert(UI.state.active and UI.state.transition_target == 0 and G.SETTINGS.paused,
    'Escape starts a close animation without resuming the underlying native menu')
UI.update(ctx, 0.24)
assert(not UI.state.active and G.SETTINGS.paused, 'closing preserves an existing native menu pause')
G.SETTINGS.paused = false
UI.open(ctx)
local archive_view, archive_selection, archive_closes = UI.state.view, UI.state.selected, closes
UI.archives(ctx)
assert(ctx.ui_view == 'archives' and UI.state.active and UI.state.modal and shown and G.OVERLAY_MENU)
local archive_drawn = drawn
trace = {}
love.draw()
assert(drawn == archive_drawn+1 and trace[2]=='tree' and trace[3]=='native_modal',
    'the tree draws exactly once before its native modal, before the original CRT pipeline')
G.FUNCS.worldline_back()
assert(UI.state.modal.closing and G.OVERLAY_MENU and G.SETTINGS.paused,
    'back first animates the native modal away over the retained worldline')
UI.update(ctx,0.28)
assert(UI.state.active and ctx.ui_view == 'tree' and not G.OVERLAY_MENU, 'archive back restores graphical view')
assert(UI.state.view==archive_view and UI.state.selected==archive_selection and closes==archive_closes,
    'modal return retains the same camera/selection and never invokes native settings-saving exit')
UI.archives(ctx)
ctx.load_archive = function() ctx.busy = true; return true end
G.FUNCS.worldline_load_archive({config = {ref_table = {id = 'one'}}})
assert(not UI.state.active and not G.OVERLAY_MENU and ctx.ui_view == nil,
    'an accepted load removes both modal and tree immediately')
ctx.busy = false
UI.open(ctx)
fail_draw = true
love.draw()
assert(not UI.state.active and ctx.last_error:find('test renderer failure'), 'rendering failure releases the pause')
assert(current_canvas == nil and trace[#trace] == 'native_AA_to_screen', 'a failed Tree draw still completes native postprocessing')
local options = create_UIBox_options().nodes[1].nodes[1].nodes[1].nodes
assert(options[1].original and options[2].button == 'worldline_open')
assert(options[2].label[1] == 'Worldline / F6', 'native options use the Worldline brand')
assert(options[3].button == 'worldline_undo' and options[3].func == 'worldline_can_undo',
    'native options provide undo directly, alongside the separate tree entry')
love.mousepressed(10, 10, 1)
assert(original_mouse == 1, 'inactive overlay preserves native mouse callbacks')
love.gamepadpressed({}, 'a')
assert(original_pad == 1, 'inactive overlay preserves native gamepad callbacks')

-- Ordinary undo is independent of opening/exploring the tree and therefore
-- never invokes before_open/open (where the separate seeded-progress lock lives).
local undos, undo_checks, ready, ctrl = 0, 0, true, true
local open_count, prepare_count = shortcut_calls, prepared
ctx.can_undo = function()
    undo_checks = undo_checks + 1
    return ready, ready and nil or 'An animation is running', 'Discard'
end
ctx.undo = function() undos = undos + 1; return true end
love.keyboard = {isDown = function(left, right)
    if left == 'lshift' and right == 'rshift' then return false end
    assert(left == 'lctrl' and right == 'rctrl')
    return ctrl
end}
local native_count = original_keys
love.keypressed('z', 'z', false)
assert(undos == 1 and original_keys == native_count and not UI.state.active,
    'Ctrl+Z undoes directly without forwarding the action into gameplay')
assert(ctx.last_undo_source == 'Ctrl+Z' and shortcut_calls == open_count and prepared == prepare_count,
    'undo does not open a tree or trigger opening-time policy')
love.keypressed('z', 'z', true)
assert(undos == 1, 'holding Ctrl+Z does not repeatedly undo')
ready = false
love.keypressed('z', 'z', false)
assert(undos == 1 and ctx.status == 'An animation is running', 'unstable actions cannot be undone')
ready = true
ctx.busy = true
local checks_before = undo_checks
love.keypressed('z', 'z', false)
assert(undos == 1 and undo_checks == checks_before, 'restore-in-progress bypasses the runtime callback')
ctx.busy = false
G.CONTROLLER.text_input_hook = {}
assert(love.keypressed('z', 'z', false) == 'native')
assert(undos == 1 and original_keys == native_count + 1,
    'Ctrl+Z in a native text input remains native text editing')
G.CONTROLLER.text_input_hook = nil
ctrl = false
assert(love.keypressed('z', 'z', false) == 'native' and undos == 1,
    'plain Z remains available to the native game')
ctrl = true

local native_button = {config = {}}
ready = false
G.FUNCS.worldline_can_undo(native_button)
assert(native_button.config.button == nil and native_button.config.worldline_disabled_reason,
    'the native undo button is visibly disabled while undo is unavailable')
ready = true
G.FUNCS.worldline_can_undo(native_button)
assert(native_button.config.button == 'worldline_undo' and native_button.config.colour == G.C.BLUE)
G.FUNCS.overlay_menu({definition = {}})
G.SETTINGS.paused = true
G.FUNCS.worldline_undo()
assert(undos == 2 and not G.OVERLAY_MENU and not G.SETTINGS.paused,
    'undo in native Options closes that menu so a queued restore can proceed')
assert(shortcut_calls == open_count and prepared == prepare_count,
    'the native undo button never goes through the tree-opening gate')

-- Failure leaves the current screen usable and reports the runtime reason.
UI.open(ctx, true)
ctx.undo = function() return nil, 'Nothing was committed yet' end
local value, error_text = UI.undo(ctx, 'test')
assert(value == nil and error_text == 'Nothing was committed yet' and UI.state.active
    and UI.state.notice == error_text, 'failed undo leaves the overlay in place')
ctx.undo = function() error('undo callback failed') end
assert(UI.undo(ctx, 'test') == nil and UI.state.active and ctx.status:find('undo callback failed'))
ctx.undo = function() undos = undos + 1; return true end
love.keypressed('z', 'z', false)
assert(undos == 3 and not UI.state.active and not G.SETTINGS.paused,
    'Ctrl+Z inside the tree also closes it after scheduling undo')

-- The compact HUD control shares the scene canvas and input coordinate system
-- with the tree, without drawing an invisible fullscreen layer over gameplay.
local undo_draws, hud_enabled, hud_visible = 0, true, true
Renderer.undo_control = function()
    if not hud_visible then return nil end
    return {x = 1400, y = 80, w = 150, h = 40, enabled = hud_enabled}
end
Renderer.draw_undo = function(_, draw_config)
    assert(current_canvas == canvas and draw_config.render_scale == 2)
    undo_draws = undo_draws + 1
    trace[#trace + 1] = 'undo_hud'
end
trace = {}
fail_draw = false
love.draw()
assert(undo_draws == 1 and table.concat(trace, ',') ==
    'native_scene,undo_hud,native_cursor,native_CRT_from_scene_canvas,native_AA_to_screen',
    'the compact control participates in the native CRT pipeline before the cursor')
local mouse_before, release_before = original_mouse, original_release
love.mousepressed(2820, 180, 1)
love.mousereleased(2820, 180, 1)
assert(undos == 4 and original_mouse == mouse_before and original_release == release_before
    and ctx.last_undo_source == 'HUD button', 'HUD click consumes both press and release')
assert(geometry_state == nil, 'native HUD hit testing never inherits a closed worldline transition transform')
hud_enabled = false
love.mousepressed(2820, 180, 1)
love.mousereleased(2820, 180, 1)
assert(undos == 4 and original_mouse == mouse_before and original_release == release_before,
    'disabled HUD control does not click through to the scene')
hud_visible = false
love.mousepressed(2820, 180, 1)
love.mousereleased(2820, 180, 1)
assert(original_mouse == mouse_before + 1 and original_release == release_before + 1,
    'when the HUD control is absent, native mouse callbacks remain untouched')

ctx.has_public_worldline = function() return false end
local save_attempts, export_attempts = 0, 0
ctx.save_now = function() save_attempts = save_attempts + 1; return true end
ctx.export_share = function() export_attempts = export_attempts + 1; return true end
assert(UI.open(ctx, true) and #UI.state.layout.nodes == 0 and UI.state.selected == nil,
    'private undo roots open an empty worldline view')
assert(UI.detail(ctx, 2) == false, 'private undo roots cannot expose point details')
assert(UI.action(ctx, 'save') == false and UI.action(ctx, 'export') == false
    and UI.action(ctx, 'restore') == false and save_attempts == 0 and export_attempts == 0,
    'private undo roots cannot be saved, exported or converged through public UI actions')
assert(UI.state.notice == 'No worldline yet')
local undo_before = undos
UI.action(ctx, 'undo')
assert(undos == undo_before + 1 and not UI.state.active,
    'undo remains available while automatic worldline recording is disabled')
ctx.has_public_worldline = nil
ctx.load_archive = function() return true end
UI.archives(ctx)
G.FUNCS.worldline_load_archive({config = {ref_table = {id = 'one'}}})
assert(UI.state.notice == 'Worldline converged', 'loading an archive reports a worldline convergence')

-- Ordinary dismissal animates, and owns input until the final close frame.
G.FUNCS.worldline_back()
assert(UI.state.active and UI.state.transition == 0 and UI.state.transition_target == 1)
UI.update(ctx, -1)
assert(UI.state.transition == 0, 'negative frame durations do not reverse the animation')
UI.update(ctx, 0.28)
assert(UI.state.transition == 1)
love.mousepressed(100, 1100, 1)
love.mousemoved(160, 1130, 60, 30)
assert(UI.state.drag and UI.state.drag.moved)
love.keypressed('f6', 'f6', false)
assert(UI.state.active and UI.state.transition_target == 0 and UI.state.drag == nil
    and UI.state.hover == nil and G.SETTINGS.paused and ctx.ui_view == 'tree')
UI.update(ctx, 0.12)
assert(math.abs(UI.state.transition - 0.5) < 0.000001)
local paused_pan, paused_scale = UI.state.view.pan_x, UI.state.view.scale
local closing_keys, closing_mouse, closing_release, closing_undos = original_keys, original_mouse, original_release, undos
love.keypressed('right', 'right', false)
love.keypressed('z', 'z', false)
love.mousepressed(10, 10, 2)
love.mousemoved(800, 400, 640, -730)
love.wheelmoved(0, 1)
assert(UI.state.view.pan_x == paused_pan and UI.state.view.scale == paused_scale
    and original_keys == closing_keys and original_mouse == closing_mouse and undos == closing_undos,
    'closing consumes navigation, Undo, pointer input and wheel without changing the hidden scene')
local reversal_progress = UI.state.transition
love.keypressed('f6', 'f6', false)
assert(UI.state.active and UI.state.transition_target == 1 and UI.state.transition == reversal_progress,
    'F6 reverses the closing animation at its current progress')
UI.update(ctx, 0.14)
assert(UI.state.transition == 1 and G.SETTINGS.paused)
UI.action(ctx, 'close')
assert(UI.state.active and UI.state.transition_target == 0 and G.SETTINGS.paused)
UI.update(ctx, 0.24)
assert(not UI.state.active and UI.state.transition == 0 and ctx.ui_view == nil and not G.SETTINGS.paused)
love.mousereleased(160, 1130, 1)
love.mousereleased(10, 10, 2)
assert(original_release == closing_release, 'mouse releases remain owned after the close animation finishes')

-- State replacement, navigation and errors use the explicit immediate path so
-- native snapshot guards never see a fade-out-owned pause after accepting work.
UI.open(ctx, true); UI.update(ctx, 0.04)
UI.close(ctx, true)
assert(not UI.state.active and UI.state.transition == 0 and not G.SETTINGS.paused)
UI.open(ctx, true); UI.update(ctx, 0.04)
G.FUNCS.worldline_close(nil, true)
assert(not UI.state.active and UI.state.transition == 0 and not G.SETTINGS.paused,
    'programmatic native close supports the same explicit immediate handoff')
UI.open(ctx, true); UI.update(ctx, 0.04)
G.FUNCS.exit_overlay_menu()
assert(not UI.state.active and UI.state.transition == 0 and UI.state.transition_target == 0 and ctx.ui_view == nil,
    'native overlay exit cancels even a partially opened animation immediately')

do
    -- Prune + commit may reuse next_id. The in-memory mutation revision must
    -- replace cached rows and invalidate renderer geometry for those same IDs.
    ctx.tree.structure_revision = 1
    UI.open(ctx, true)
    local previous_layout, previous_row = UI.state.layout, rows[2]
    UI.close(ctx, true)
    rows[2] = {id=2, parent=1, children={3,4}, summary={dollars=99}}
    ctx.tree.structure_revision = 2
    UI.open(ctx, true)
    assert(UI.state.layout ~= previous_layout and UI.state.layout.by_id[2].row == rows[2]
        and UI.state.layout.by_id[2].row.summary.dollars == 99 and UI.state.tree_revision == 2,
        'same next_id with a changed structure revision rebuilds node summaries')
    UI.close(ctx, true)
    rows[2], ctx.tree.structure_revision = previous_row, nil
end

do
    local clock, consecutive, continuous, confirmations, requests = 100, 0, false, 0, 0
    local token, saved_tree, saved_game = {}, ctx.tree, G.GAME
    local old_timer, old_undo, old_can = love.timer, ctx.undo, ctx.can_undo
    love.timer = {getTime = function() return clock end}
    G.GAME = {}
    ctx.tree.metadata.run_id = 'confirmation-run'
    ctx.can_undo = function() return ready, 'An animation is running', 'Discard' end
    ctx.requires_undo_confirmation = function() return consecutive >= 1 and not continuous, token end
    ctx.undo_confirmation_token = function() return consecutive >= 1 and not continuous and token or nil end
    ctx.confirm_continuous_undo = function(value)
        assert(value == token and not UI.state.undo_confirmation,
            'confirmation restores the native scene before entering the backend')
        confirmations, continuous = confirmations + 1, true
        return true
    end
    ctx.undo = function()
        assert(not UI.state.undo_confirmation, 'queued restore never sees modal-owned pause')
        requests, consecutive = requests + 1, consecutive + 1
        return true
    end
    ready, ctrl, G.SETTINGS.paused = true, true, false
    local original_current, original_next, original_child = ctx.tree.current, ctx.tree.next_id, rows[2].children[1]
    local function hint()
        love.keypressed('z', 'z', false)
        assert(UI.state.undo_confirmation and G.OVERLAY_MENU and G.SETTINGS.paused)
        assert(shown.back_func == 'worldline_cancel_continuous_undo' and shown.back_label == 'Cancel')
        return UI.state.undo_confirmation
    end
    local function intact()
        assert(ctx.tree.current == original_current and ctx.tree.next_id == original_next
            and rows[2].children[1] == original_child, 'prompt/cancellation leaves worldline history intact')
    end

    love.keypressed('z', 'z', false)
    assert(requests == 1 and confirmations == 0 and not UI.state.undo_confirmation,
        'the first Undo keeps the ordinary behavior')
    local pending = hint()
    assert(requests == 1 and confirmations == 0 and pending.deadline == clock + 2,
        'the second Undo only presents a two-second confirmation')
    local graph_draws, hud_draws = drawn, undo_draws
    love.draw()
    assert(drawn == graph_draws and undo_draws == hud_draws,
        'neither native HUD nor graph can cover the native confirmation')
    love.keypressed('z', 'z', true)
    love.keypressed('f6', 'f6', false)
    love.wheelmoved(0, 1)
    assert(requests == 1 and UI.state.undo_confirmation == pending, 'held keys/F6/wheel do not confirm or navigate')
    love.keypressed('escape', 'escape', false)
    assert(not UI.state.undo_confirmation and not G.OVERLAY_MENU and not G.SETTINGS.paused
        and confirmations == 0 and requests == 1, 'Escape cancels without locking or popping Undo')
    intact()

    pending = hint()
    ready = false
    love.keypressed('z', 'z', false)
    assert(UI.state.undo_confirmation == pending and confirmations == 0 and requests == 1,
        'the native overlay creation lock keeps the prompt available without clearing game locks')
    ready = true
    clock = clock + 0.5
    love.keypressed('z', 'z', false)
    assert(confirmations == 1 and requests == 2 and not UI.state.undo_confirmation
        and not G.OVERLAY_MENU and not G.SETTINGS.paused, 'a fresh third Ctrl+Z confirms and performs exactly one older Undo')
    love.keypressed('z', 'z', false)
    assert(confirmations == 1 and requests == 3 and not UI.state.undo_confirmation,
        'a confirmed continuous session does not prompt again')

    -- Options must survive cancellation as the same live UIBox, not a recreated
    -- definition whose object children may already have been removed.
    continuous = false
    G.FUNCS.overlay_menu({definition={tab='original options'}})
    G.SETTINGS.paused = true
    local options_overlay = G.OVERLAY_MENU
    G.FUNCS.worldline_undo()
    assert(UI.state.undo_confirmation and not options_overlay.REMOVED and not options_overlay.states.visible)
    for _, box in ipairs(G.I.UIBOX) do assert(box ~= options_overlay, 'suspended Options cannot draw or receive draw-hash hits') end
    G.FUNCS.worldline_cancel_continuous_undo()
    assert(G.OVERLAY_MENU == options_overlay and options_overlay.states.visible
        and not options_overlay.REMOVED and G.SETTINGS.paused and requests == 3,
        'native Cancel restores the exact Options overlay and its pause')
    G.FUNCS.worldline_undo()
    G.FUNCS.worldline_confirm_continuous_undo()
    assert(confirmations == 2 and requests == 4 and options_overlay.REMOVED
        and not G.OVERLAY_MENU and not G.SETTINGS.paused, 'native Continue queues one Undo and releases Options')

    -- The clock is consulted by input too: stale confirmation cannot sneak
    -- through between native input dispatch and the next UI.update pass.
    continuous = false
    pending = hint()
    clock = pending.deadline
    love.keypressed('z', 'z', false)
    assert(UI.state.undo_confirmation and UI.state.undo_confirmation ~= pending
        and UI.state.undo_confirmation.deadline == clock + 2 and confirmations == 2 and requests == 4,
        'Ctrl+Z at an expired deadline starts a fresh hint without confirming the old one')
    clock = clock + 2
    UI.update(ctx, 0)
    assert(not UI.state.undo_confirmation and not G.SETTINGS.paused and not G.OVERLAY_MENU,
        'the timeout dismisses even when the graph is inactive')
    pending = hint()
    clock = pending.deadline + 0.01
    local native_clicks, native_releases = original_mouse, original_release
    love.mousepressed(100, 100, 1)
    love.mousereleased(100, 100, 1)
    assert(not UI.state.undo_confirmation and original_mouse == native_clicks and original_release == native_releases
        and confirmations == 2 and requests == 4, 'an expired mouse event never clicks through to gameplay')
    pending = hint()
    clock = pending.deadline
    G.FUNCS.worldline_confirm_continuous_undo()
    assert(confirmations == 2 and requests == 4 and not UI.state.undo_confirmation,
        'native Continue cannot confirm an expired token')

    pending = hint()
    local replacement_game = {}
    G.GAME = replacement_game
    love.keypressed('z', 'z', false)
    assert(confirmations == 2 and requests == 4,
        'a new run never confirms the previous run prompt')
    UI.cancel_undo_confirmation(ctx)
    pending = hint()
    token = {}
    UI.update(ctx, 0)
    assert(not UI.state.undo_confirmation and confirmations == 2 and requests == 4,
        'a new action/history token invalidates the outstanding prompt')
    pending = hint()
    local native_text_keys = original_keys
    G.CONTROLLER.text_input_hook = {}
    assert(love.keypressed('z', 'z', false) == 'native')
    assert(not UI.state.undo_confirmation and confirmations == 2 and requests == 4
        and original_keys == native_text_keys + 1, 'text editing cancels the hint and keeps native Ctrl+Z editing')
    G.CONTROLLER.text_input_hook = nil

    UI.open(ctx, true); UI.update(ctx, 0.28)
    local open_transition, open_view = UI.state.transition, UI.state.view
    pending = hint()
    UI.update(ctx, 0.08)
    assert(UI.state.active and UI.state.transition == open_transition and UI.state.view == open_view,
        'the modal owns inputs while preserving the tree camera and animation state')
    G.FUNCS.worldline_cancel_continuous_undo()
    assert(UI.state.active and ctx.ui_view == 'tree' and G.SETTINGS.paused and UI.state.view == open_view,
        'Cancel returns to an already open tree with the original pause owner')
    pending = hint()
    UI.close(ctx, true)
    assert(not UI.state.active and not UI.state.undo_confirmation and not G.OVERLAY_MENU and not G.SETTINGS.paused,
        'an accepted restore/immediate close removes pending confirmation synchronously')
    pending = hint()
    G.FUNCS.exit_overlay_menu()
    assert(not UI.state.undo_confirmation and not G.OVERLAY_MENU and confirmations == 2 and requests == 4,
        'external native overlay exit cancels the outstanding confirmation')
    intact()
    ctx.tree, G.GAME = saved_tree, saved_game
    ctx.tree.metadata.run_id = nil
    love.timer, ctx.undo, ctx.can_undo = old_timer, old_undo, old_can
    ctx.requires_undo_confirmation, ctx.undo_confirmation_token, ctx.confirm_continuous_undo = nil, nil, nil
end

-- Unicode names and native modal input ownership are independent of gameplay.
do
    local old_keyboard, old_system, active_input, ctrl = love.keyboard, love.system, false, false
    local writes, pasted, names, repeating = {}, 0, {}, false
    love.keyboard = {
        isDown = function() return ctrl end,
        isTextInputActive = function() return active_input end,
        setTextInput = function(value) active_input = value; writes[#writes + 1] = value end,
        hasKeyRepeat=function()return repeating end,
        setKeyRepeat=function(value)repeating=value end,
    }
    love.system = {getClipboardText = function() pasted = pasted + 1; return '收藏...' end}
    ctx.before_open, ctx.busy = function() return true end, false
    UI.edit_name(ctx, 'Bookmark', '路线...', function(value) names[#names + 1] = value; return true end)
    assert(active_input and pasted == 0 and repeating,'Editors enable native key repeat')
    love.textinput('甲')
    assert(UI.state.editor.value == '路线...甲', 'literal trailing dots are not mistaken for truncation')
    love.keypressed('backspace', 'backspace', false)
    assert(UI.state.editor.value == '路线...', 'backspace removes one Unicode codepoint')
    love.keypressed('backspace','backspace',true)
    assert(UI.state.editor.value=='路线..','Held Backspace accepts repeated key events')
    local opens = shortcut_calls
    love.keypressed('f6', 'f6', false); keybind.action()
    love.keypressed('z', 'z', false)
    assert(UI.state.editor and shortcut_calls == opens, 'both F6 routes stay within the name modal')
    ctrl = true; love.keypressed('a', 'a', false); ctrl = false
    love.textedited('中文输入', 0, 4)
    love.keypressed('return', 'return', false)
    assert(#names == 0 and UI.state.editor.display:find('中文输入', 1, true), 'IME composition is visible and Enter does not submit it')
    love.textinput('第一间商店')
    assert(UI.state.editor.value == '第一间商店')
    ctrl = true; love.keypressed('a', 'a', false); love.keypressed('v', 'v', false); ctrl = false
    assert(UI.state.editor.value == '收藏...' and pasted == 1, 'clipboard is read only on explicit paste')
    love.keypressed('return', 'return', false)
    assert(names[1] == '收藏...' and not UI.state.editor and not active_input and UI.state.active and not repeating)
    UI.edit_name(ctx, 'Bookmark', '', function() return false, 'validation error' end)
    love.textinput(string.rep('界', 70))
    assert(UI.state.editor.value == string.rep('界', 64), 'name limit counts characters without cutting UTF-8 bytes')
    assert(not UI.submit_name(ctx) and UI.state.editor.error == 'validation error' and active_input)
    love.keypressed('escape', 'escape', false)
    assert(not UI.state.editor and not active_input and not repeating,'Cancel restores the previous repeat setting')
    active_input = true
    UI.edit_name(ctx, 'Bookmark', '', function() return true end)
    G.FUNCS.exit_overlay_menu()
    assert(active_input and not UI.state.editor, 'closing restores the previous text-input owner')
    love.keyboard, love.system = old_keyboard, old_system
end

-- Native bookmark navigation keeps annotations separate from convergence.
do
    local renamed, removed, revealed, query, fold_toggles, fold_removes = nil, nil, nil, nil, 0, 0
    ctx.bookmark_rows = function(value) query = value; return {{node_id=2,label='商店方案甲'}} end
    ctx.set_bookmark = function(id, name) renamed={id,name}; return true end
    ctx.remove_bookmark = function(id) removed=id; return true end
    ctx.reveal_node = function(id) revealed=id; return false end
    ctx.fold_rows = function() return {{id=9,start_id=2,label='商店之间',collapsed=true}} end
    ctx.toggle_fold = function(id) assert(id==9); fold_toggles=fold_toggles+1; return true end
    ctx.remove_fold = function(id) assert(id==9); fold_removes=fold_removes+1; return true end
    UI.navigation(ctx, 'bookmarks')
    assert(ctx.ui_view == 'bookmarks' and query == '')
    G.FUNCS.worldline_bookmark_edit({config={ref_table={id=2,label='商店方案甲'}}})
    UI.state.editor.value = '另一条路线'; assert(UI.submit_name(ctx))
    assert(renamed[1]==2 and renamed[2]=='另一条路线')
    G.FUNCS.worldline_bookmark_remove({config={ref_table={id=2}}}); assert(removed==2)
    G.FUNCS.worldline_bookmark_search()
    UI.state.editor.value = '商店'; assert(UI.submit_name(ctx))
    assert(query=='商店' and ctx.ui_view=='bookmarks')
    G.FUNCS.worldline_navigation_goto({config={ref_table={id=2}}})
    UI.update(ctx,0.28)
    assert(UI.state.selected==2 and revealed==2 and ctx.ui_view=='tree')
    UI.navigation(ctx, 'folds')
    G.FUNCS.worldline_fold_toggle({config={ref_table={id=9}}})
    G.FUNCS.worldline_fold_remove({config={ref_table={id=9}}})
    assert(fold_toggles==1 and fold_removes==1 and ctx.ui_view=='folds')
    G.FUNCS.worldline_back(); UI.close(ctx, true)
end

-- Two selected endpoints start the native naming dialog directly. More than
-- two is an explicit error, never silently reduced to the first two nodes.
do
    local folded
    ctx.fold_range = function(first, last, name) folded = {first, last, name}; return true end
    UI.open(ctx, true); UI.update(ctx, 0.28)
    Selection.set(UI.state, {2,3,4}, 4, 2)
    assert(UI.action(ctx, 'fold_range') == false and not UI.state.editor and not folded)
    assert(UI.state.notice:find('exactly two', 1, true))
    Selection.set(UI.state, {3,2}, 2, 3)
    UI.action(ctx, 'fold_range')
    assert(UI.state.editor and not folded)
    UI.state.editor.value = 'Named linear region'
    assert(UI.submit_name(ctx))
    assert(folded[1] == 3 and folded[2] == 2 and folded[3] == 'Named linear region')
    Selection.set(UI.state, {1}, 1, 1)
    UI.action(ctx, 'fold_range'); assert(UI.state.fold_start == 1 and not UI.state.editor)
    Selection.set(UI.state, {2}, 2, 2)
    UI.action(ctx, 'fold_range'); assert(UI.state.editor)
    love.keypressed('escape', 'escape', false)
    UI.action(ctx, 'cancel_region')
    UI.update(ctx,0.28)
    assert(not UI.state.fold_start and not UI.state.editor)

    local old_rows, calls = Renderer.detail_rows, 0
    Renderer.detail_rows = function() error('new page controls must not build old text rows') end
    Renderer.detail_scroll_max = function() calls = calls + 1; return 3 end
    UI.state.detail_scroll = 0
    UI.action(ctx, 'detail_down'); assert(UI.state.detail_scroll == 1)
    UI.action(ctx, 'detail_up'); assert(UI.state.detail_scroll == 0)
    sidebar_bounds = {x = 500, y = 200, w = 200, h = 400}
    pointer_x, pointer_y = 1100, 600
    love.wheelmoved(0, -1); assert(UI.state.detail_scroll == 1)
    love.wheelmoved(0, -9); assert(UI.state.detail_scroll == 2, 'wheel moves one complete detail page')
    love.wheelmoved(0, -1); love.wheelmoved(0, -1)
    assert(UI.state.detail_scroll == 3 and calls == 6)
    sidebar_bounds, Renderer.detail_scroll_max, Renderer.detail_rows = nil, nil, old_rows
    UI.close(ctx, true)
end
-- Archive management uses native menus, explicit confirmations and the API's
-- preview token. Neither opening Settings nor a cancelled edit changes a run.
do
    local auto, feature_calls, loads, resumed = true, 0, 0, 0
    local renamed, deleted_branch, deleted_archive, exported, restored_backup
    local token = {}; local stale = false
    ctx.tree.metadata.run_id, ctx.tree.metadata.name = 'ui-test', 'Original name'
    ctx.busy, ctx.restoring = false, false
    ctx.has_public_worldline = function() return ctx.tree ~= nil end
    ctx.use_feature = function() feature_calls=feature_calls+1 end
    ctx.auto_create_enabled = function() return auto end
    ctx.set_auto_create = function(value) auto=value; return true end
    ctx.recording_suspended = function() return false end
    ctx.resume_recording = function() resumed=resumed+1; return true end
    local last_toggle, last_check
    create_toggle = function(args)
        last_toggle=args
        last_check={created_on_pause=G.SETTINGS.paused==true}
        return {toggle=args,n=G.UIT.R,nodes={{config={object=last_check}}}}
    end
    ctx.archive_rows = function() local archives={
        {id='ui-test',name=ctx.tree and ctx.tree.metadata.name or 'Original name',label='Original name / TREEDEMO',seed='TREEDEMO'},
        {id='other',name='Other',label='Other / ANOTHER',seed='ANOTHER'}}
        if restored_backup then archives[#archives+1]={id='restored-id',name='Restored',seed='BACKUP'} end
        return archives
    end
    ctx.rename_archive = function(id,name) renamed={id,name}; ctx.tree.metadata.name=name; return true end
    ctx.load_archive = function() loads=loads+1; return true end
    ctx.branch_delete_preview = function(id)
        return {count=id==3 and 1 or 3,allowed=id==3,reason=id~=3 and 'Cannot delete the current point or its history',token=token}
    end
    ctx.delete_branch = function(id,value)
        if stale then return nil,'Worldline changed; review the deletion again' end
        deleted_branch={id,value};return true
    end
    ctx.export_branch = function(id) exported=id;return 'exports/branch.json' end
    ctx.archive_delete_preview = function(id) return {count=4,label='Original name',token=token} end
    ctx.delete_archive = function(id,value) deleted_archive={id,value};return true end
    ctx.backup_rows = function() return {{id='backup-one',label='Original name',created_at=1,reason='branch'}} end
    ctx.restore_backup = function(id) restored_backup=id;return 'restored-id' end
    local function has_text(value)
        local seen={}
        local function scan(t)
            if type(t)~='table' then return type(t)=='string' and t:find(value,1,true)~=nil end
            if seen[t] then return false end
            seen[t]=true
            for _,v in pairs(t) do if scan(v) then return true end end
            return false
        end
        return scan(shown)
    end
    local options = create_UIBox_options().nodes[1].nodes[1].nodes[1].nodes
    assert(options[4].button=='worldline_settings' and options[4].label[1]=='Worldline settings')
    UI.close(ctx,true);ctx.ui_view=nil
    G.SETTINGS.paused=false
    G.FUNCS.worldline_settings()
    assert(ctx.ui_view=='worldline_settings' and last_toggle.ref_table.auto_create and feature_calls==0)
    assert(last_check.created_on_pause and G.SETTINGS.paused,
        'opening from unpaused gameplay attaches the native toggle sprite to the overlay pause clock')
    assert(last_toggle.label=='Automatic creation' and has_text('Affects runs without an existing worldline'),
        'the setting describes creation, not disabling the current recording')
    last_toggle.ref_table.auto_create=false;last_toggle.callback(false)
    assert(auto==false and feature_calls==0 and UI.state.settings_form.message=='Settings saved')
    ctx.set_auto_create=function()return nil,'cannot save setting' end
    last_toggle.ref_table.auto_create=true;last_toggle.callback(true)
    assert(last_toggle.ref_table.auto_create==false and UI.state.settings_form.message=='cannot save setting')
    G.FUNCS.worldline_manage_back()
    assert(ctx.ui_view==nil and not UI.state.native_overlay and feature_calls==0,
        'Settings returns to native Options without opening/locking the worldline')

    UI.archives(ctx)
    assert(has_text('Load') and has_text('Backups') and has_text('Worldline settings'))
    assert(UI.state.archive_selected=='ui-test' and loads==0, 'the browser selects a preview without converging')
    G.FUNCS.worldline_archive_select({config={ref_table={id='other',kind='archives'}}})
    assert(UI.state.archive_selected=='other' and ctx.ui_view=='archives' and loads==0,
        'selection updates the adjacent preview without loading or nesting a management page')
    G.FUNCS.worldline_archive_manage({config={ref_table={id='ui-test'}}})
    assert(ctx.ui_view=='archives' and UI.state.archive_selected=='ui-test' and has_text('Delete archive'))
    G.FUNCS.worldline_archive_rename({config={ref_table={id='ui-test',name='Original name'}}})
    UI.state.editor.value='Changed name'
    love.keypressed('escape','escape',false)
    assert(not renamed and not UI.state.editor and ctx.ui_view=='archives',
        'cancelled archive names return to the archive manager without convergence')
    G.FUNCS.worldline_archive_rename({config={ref_table={id='ui-test',name='Original name'}}})
    UI.state.editor.value='Changed name';assert(UI.submit_name(ctx))
    assert(renamed[1]=='ui-test' and renamed[2]=='Changed name' and ctx.ui_view=='archives'
        and UI.state.archive_selected=='ui-test' and loads==0)
    UI.manage_node(ctx,2)
    assert(has_text('Cannot delete the current point or its history'))
    local disabled={config={ref_table={disabled=true},button='worldline_branch_delete'}}
    G.FUNCS.worldline_management_enabled(disabled);assert(disabled.config.button==nil)
    UI.manage_node(ctx,3)
    G.FUNCS.worldline_branch_export({config={ref_table={id=3}}})
    assert(exported==3 and not deleted_branch and ctx.ui_view=='node_manage')
    G.FUNCS.worldline_branch_delete({config={ref_table={id=3}}})
    local old_confirmation=UI.state.management_confirm
    assert(old_confirmation and old_confirmation.token==token and not deleted_branch
        and has_text('A backup is kept before deletion.') and has_text('The current Undo history will be cleared.'))
    love.keypressed('escape','escape',false)
    assert(not UI.state.management_confirm and not deleted_branch and ctx.ui_view=='node_manage')
    G.FUNCS.worldline_branch_delete({config={ref_table={id=3}}})
    assert(G.FUNCS.worldline_confirm_delete({config={ref_table=old_confirmation}})==false and not deleted_branch,
        'a stale native button cannot confirm a replacement dialog')
    local pending=UI.state.management_confirm
    G.FUNCS.worldline_confirm_delete({config={ref_table=pending}})
    UI.update(ctx,0.28)
    assert(deleted_branch[1]==3 and deleted_branch[2]==token and ctx.ui_view=='tree')
    stale=true
    UI.confirm_delete(ctx,'branch',3);pending=UI.state.management_confirm
    G.FUNCS.worldline_confirm_delete({config={ref_table=pending}})
    assert(ctx.ui_view=='node_manage' and UI.state.notice:find('review',1,true),
        'changed deletion preview is rejected and kept visible for review')
    stale=false
    UI.confirm_delete(ctx,'archive','ui-test');pending=UI.state.management_confirm
    assert(has_text('The game in progress will continue.') and not deleted_archive)
    G.FUNCS.worldline_confirm_delete({config={ref_table=pending}})
    assert(deleted_archive[1]=='ui-test' and deleted_archive[2]==token and ctx.ui_view=='archives')
    UI.backups(ctx)
    assert(ctx.ui_view=='backups' and has_text('Restore backup'))
    G.FUNCS.worldline_settings()
    assert(ctx.ui_view=='worldline_settings' and has_text('Current run') and feature_calls==0)
    G.FUNCS.worldline_manage_back()
    assert(ctx.ui_view=='backups', 'settings returns to the same browser tab')
    G.FUNCS.worldline_backup_restore({config={ref_table={id='backup-one'}}})
    assert(restored_backup=='backup-one' and loads==0 and ctx.ui_view=='archives'
        and UI.state.archive_selected=='restored-id', 'restoring selects the new independent copy without loading it')
    ctx.recording_suspended=function()return true end
    UI.settings(ctx)
    assert(has_text('Start recording again') and has_text('Recording paused'))
    G.FUNCS.worldline_resume_recording()
    UI.update(ctx,0.28)
    assert(resumed==1 and ctx.ui_view=='tree')
    UI.close(ctx,true)
end
-- Embedded native dialogs retain the worldline underneath them. Input and
-- mouse release ownership must survive both opening and closing transitions.
do
    local old_overlay, old_controls, old_keyboard = G.FUNCS.overlay_menu, Renderer.controls, love.keyboard
    local old_cursor, old_layer = G.CONTROLLER.cursor_context, G.CONTROLLER.mod_cursor_context_layer
    local old_archive, old_undo = ctx.archive_rows, ctx.undo
    local native_exits, modal_undos = closes, 0
    G.CONTROLLER.cursor_context = {layer=7,stack={}}
    G.CONTROLLER.mod_cursor_context_layer = function(self,delta) self.cursor_context.layer=self.cursor_context.layer+delta end
    G.FUNCS.overlay_menu = function(args)
        old_overlay(args)
        if not G.NO_MOD_CURSOR_STACK then G.CONTROLLER:mod_cursor_context_layer(1) end
        G.OVERLAY_MENU.alignment = {offset={x=0,y=0}}
        G.OVERLAY_MENU.align_to_major = function() end
    end
    ctx.archive_rows = function() return {{id='modal-test',name='Modal',seed='MODAL'}} end
    ctx.undo = function() modal_undos=modal_undos+1;return true end
    love.keyboard = {isDown=function() return true end}
    Renderer.controls = function() return {{key='archives',x=0,y=0,w=80,h=40}} end
    UI.open(ctx,true);UI.update(ctx,0.28)
    local view, selected = UI.state.view, UI.state.selected
    local px, py, zoom = view.pan_x, view.pan_y, view.scale
    local releases, buttons = original_release, original_mouse
    love.mousepressed(10,10,1)
    assert(UI.state.modal and UI.state.active and ctx.ui_view=='archives')
    love.mousereleased(10,10,1)
    assert(original_release==releases, 'the graph press opening a dialog cannot release onto its new buttons')
    assert(G.CONTROLLER.cursor_context.layer==8)
    G.FUNCS.worldline_settings()
    assert(G.CONTROLLER.cursor_context.layer==8 and ctx.ui_view=='worldline_settings',
        'replacement subpages share one native cursor layer')
    G.FUNCS.worldline_manage_back()
    assert(G.CONTROLLER.cursor_context.layer==8 and ctx.ui_view=='archives')
    local shortcut_before = shortcut_calls
    love.keypressed('right','right',false);love.keypressed('=','=',false)
    love.keypressed('f6','f6',false);keybind.action();love.keypressed('z','z',false)
    love.wheelmoved(0,2)
    love.mousepressed(500,400,2);love.mousemoved(580,440,80,40);love.mousereleased(580,440,2)
    assert(view.pan_x==px and view.pan_y==py and view.scale==zoom and not UI.state.drag
        and shortcut_calls==shortcut_before and modal_undos==0 and original_mouse==buttons+1,
        'native modal inputs never pan/zoom the graph, invoke F6, or perform Undo')
    local pads=original_pad
    love.gamepadpressed({},'a');assert(original_pad==pads+1, 'the native modal owns controller input')
    local overlay = G.OVERLAY_MENU
    love.mousepressed(500,400,1)
    love.gamepadpressed({},'b')
    assert(UI.state.modal.closing and overlay.alignment.offset.y==10 and not overlay.REMOVED)
    UI.update(ctx,0.14)
    assert(G.OVERLAY_MENU==overlay and UI.state.active and G.SETTINGS.paused,
        'closing keeps the native dialog alive for its reverse entrance animation')
    UI.update(ctx,0.14)
    releases=original_release
    love.mousereleased(500,400,1)
    assert(original_release==releases and not UI.state.modal and not G.OVERLAY_MENU
        and UI.state.active and UI.state.view==view and UI.state.selected==selected
        and G.CONTROLLER.cursor_context.layer==7 and closes==native_exits,
        'closing restores the retained tree and cursor layer without native exit or release leakage')
    ctx.archive_rows,ctx.undo=old_archive,old_undo
    Renderer.controls,love.keyboard=old_controls,old_keyboard
    G.FUNCS.overlay_menu=old_overlay
    G.CONTROLLER.cursor_context,G.CONTROLLER.mod_cursor_context_layer=old_cursor,old_layer
    UI.close(ctx,true)
end

-- Async indexes are only polled while their own dialog remains open. Loading
-- never means an empty archive, never hides a genuine error, and never rebuilds
-- the loading dialog on every channel poll.
do
    local original_rows=ctx.archive_rows
    local reads,polls,ready=0,0,false
    ctx.archive_rows=function(poll_only)
        if poll_only then polls=polls+1 else reads=reads+1 end
        if not ready then return nil,'loading' end
        return {{id='first',seed='FIRST'},{id='second',seed='SECOND'},
            {id='third',seed='THIRD'},{id='fourth',seed='FOURTH'},
            {id='loaded-index',name='Ready',seed='READY'}}
    end
    UI.open(ctx,true);UI.update(ctx,0.28);UI.manage_archive(ctx,'loaded-index')
    local loading=G.OVERLAY_MENU
    assert(UI.state.archive_wait and reads==1 and polls==0 and UI.state.modal)
    UI.update(ctx,0.09);UI.update(ctx,0.09)
    assert(reads==1 and polls==2 and G.OVERLAY_MENU==loading,
        'loading polls request channel results only and retain their existing native box')
    ready=true;UI.update(ctx,0.09)
    assert(not UI.state.archive_wait and UI.state.archive_selected=='loaded-index'
        and UI.state.archive_page==2 and loading.REMOVED and G.OVERLAY_MENU~=loading and UI.state.active,
        'the requested selection survives loading and chooses its eventual page')
    ready=false;UI.archives(ctx)
    assert(UI.state.archive_wait)
    love.keypressed('escape','escape',false)
    local stopped=polls
    UI.update(ctx,0.4)
    assert(polls==stopped and not UI.state.archive_wait and not UI.state.modal and UI.state.active,
        'closing cancels UI polling immediately without closing the worldline')
    ctx.archive_rows=function() return nil,'broken archive index' end
    UI.archives(ctx)
    assert(not UI.state.archive_wait and UI.state.notice=='broken archive index',
        'real reader errors are shown instead of an indefinite loading state')
    UI.close(ctx,true)
    ctx.archive_rows=original_rows
end
return true

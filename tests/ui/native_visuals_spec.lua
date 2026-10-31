local Native = dofile('src/ui/native_visuals.lua')
local Graph = dofile('src/ui/graph.lua')
local previous = {G = G, Card = Card, Sprite = Sprite, UIBox = UIBox,
    random = math.random, randomseed = math.randomseed, pseudorandom = pseudorandom}
local function forbidden() error('Native visuals must not construct game objects or use RNG') end
Card, Sprite, UIBox, math.random, math.randomseed, pseudorandom = forbidden, forbidden, forbidden, forbidden, forbidden, forbidden
local function image(w, h)
    return {getDimensions = function() return w, h end, getDPIScale = forbidden}
end
local centers, chips, blinds, shop = image(497, 475), image(145, 58), image(714, 1054), image(452, 57)
G = {ASSET_ATLAS = {centers = {image = centers, px = 71, py = 95},
    chips = {image = chips, px = 29, py = 29}},
    ANIMATION_ATLAS = {blind_chips = {image = blinds, px = 34, py = 34, frames = 21},
        shop_sign = {image = shop, px = 113, py = 57, frames = 4}},
    P_BLINDS = {bl_small = {pos = {x = 0, y = 0}}, bl_big = {pos = {x = 0, y = 1}},
        bl_hook = {pos = {x = 0, y = 7}}}, b_undiscovered = {pos = {x = 0, y = 30}}}
local calls, stack, colour, clip, line_width = {}, {}, {0.2, 0.3, 0.4, 1}, nil, 3
local function record(name, ...)
    calls[#calls + 1] = {name = name, args = {...}, colour = colour, clip = clip}
end
local g = {
    push = function(mode)
        assert(mode == 'all')
        stack[#stack + 1] = {colour = colour, clip = clip, line_width = line_width}
    end,
    pop = function()
        local state = assert(table.remove(stack))
        colour, clip, line_width = state.colour, state.clip, state.line_width
    end,
    setColor = function(...) colour = {...}; record('colour', ...) end,
    newQuad = function(x, y, w, h, iw, ih)
        assert(x >= 0 and y >= 0 and x + w <= iw and y + h <= ih)
        record('quad', x, y, w, h, iw, ih)
        return {x = x, y = y, w = w, h = h}
    end,
    draw = function(...) record('draw', ...) end,
    rectangle = function(...) record('rectangle', ...) end,
    setLineWidth = function(value) line_width = value; record('width', value) end,
    setScissor = function(...) clip = {...}; record('scissor', ...) end,
    getScissor = function() if clip then return unpack(clip) end end,
    transformPoint = function(x, y) return 60 + x * 2, 80 + y * 2 end,
    polygon = forbidden, circle = forbidden, print = forbidden,
    newCanvas = forbidden, setCanvas = forbidden, newShader = forbidden,
}
local function matching(name)
    local result = {}
    for _, call in ipairs(calls) do if call.name == name then result[#result + 1] = call end end
    return result
end
local function near(a, b) assert(math.abs(a - b) < 0.000001, tostring(a) .. ' ~= ' .. tostring(b)) end

local ok, rect = Native.card_shell(g, 10, 20, 190, 290)
assert(ok and #matching('draw') == 2 and #matching('quad') == 1)
near(rect.w / rect.h, 71 / 95)
near(rect.x, 10); near(rect.y, 20 + (290 - 190 * 95 / 71) / 2)
local blank = matching('draw')[2]
assert(blank.args[1] == centers and blank.args[2].x == 71 and blank.args[2].y == 0)
assert(blank.colour[1] == 1 and blank.colour[2] == 1 and blank.colour[3] == 1,
    'native blank card keeps its original white face and unmodified native edges')
assert(#stack == 0 and colour[1] == 0.2)
calls = {}
assert(Native.card_shell(g, 0, 0, 190, 190 * 95 / 71, {current = true}))
assert(#matching('draw') == 3 and #matching('quad') == 0,
    'shadow, current-state underglow and face reuse one cached native silhouette')
calls = {}
assert(Native.card_shell(g, 0, 0, 71, 95, {hover = true, shadow = false}))
assert(#matching('draw') == 2, 'hover is an underglow, not a fabricated icon or corner frame')

for kind, x in pairs({start = 0, choose = 3, skip = 2, failed = 1}) do
    calls = {}
    local rendered, item = Native.chip(g, kind, 100, 200, 76)
    local call = matching('draw')[1]
    assert(rendered and item.atlas_key == 'chips' and not item.contains_text)
    assert(call.args[1] == chips and call.args[2].x == x * 29 and call.args[2].y == 0)
    near(call.args[6], 76 / 29); near(call.args[7], 76 / 29)
end
calls = {}
local rendered, item = Native.chip(g, 'boss', 95, 107, 76, {blind_key = 'bl_hook', frame = 0})
assert(rendered and item.contains_text and item.blind_key == 'bl_hook')
assert(matching('draw')[1].args[2].y == 7 * 34, 'boss chip uses its native prototype row')
assert(G.P_BLINDS.bl_hook.pos.x == 0 and G.P_BLINDS.bl_hook.pos.y == 7)
assert(Native.chip_descriptor('small').pos.y == 0 and Native.chip_descriptor('big').pos.y == 1)
assert(Native.chip_descriptor('boss', {blind_key = 'unknown'}).pos.y == 30,
    'unknown blinds use the actual native undiscovered chip, not a small blind with extra text')
assert(Native.chip_descriptor('boss', {blind_key = 'bl_hook', frame = 999}).pos.x == 20)
assert(Native.chip_descriptor('boss', {pos = 'invalid'}) == nil)
assert(Native.chip_descriptor('boss', {pos = {x = 'invalid', y = 0}}) == nil)
calls = {}
assert(Native.chip(g, 'shop', 100, 200, 76))
local sign = matching('draw')[1]
assert(sign.args[1] == shop and sign.args[2].w == 113 and sign.args[2].h == 57)
near(sign.args[6], sign.args[7])
assert(Native.chip_descriptor('unsupported') == nil)
local animation = G.ANIMATION_ATLAS
G.ANIMATION_ATLAS = nil
G.ASSET_ATLAS.blind_chips = animation.blind_chips
assert(Native.chip_descriptor('small') == nil, 'static registry never substitutes a missing animation atlas')
G.ANIMATION_ATLAS, G.ASSET_ATLAS.blind_chips = animation, nil
local card_atlas = G.ASSET_ATLAS.centers
G.ASSET_ATLAS.centers = nil
calls = {}
assert(not Native.card_shell(g, 0, 0, 71, 95) and #calls == 0,
    'missing native art fails safely without inventing replacement art')
G.ASSET_ATLAS.centers = card_atlas

local layout, view = {width = 1000, height = 800}, {pan_x = -100, pan_y = -50, scale = 1}
local canvas, minimap = {x = 70, y = 78, w = 200, h = 100}, {x = 10, y = 20, w = 100, h = 80}
local viewport = assert(Native.viewport(layout, view, canvas, minimap, Graph))
near(viewport.x, 20); near(viewport.y, 25); near(viewport.w, 20); near(viewport.h, 10)
near(viewport.world.x, 100); near(viewport.world.y, 50)
assert(not viewport.outside)
view.scale = 0.5
viewport = assert(Native.viewport(layout, view, canvas, minimap, Graph))
near(viewport.x, 30); near(viewport.y, 30); near(viewport.w, 40); near(viewport.h, 20)
local fallback = assert(Native.viewport(layout, view, canvas, minimap))
near(fallback.x, viewport.x); near(fallback.y, viewport.y); near(fallback.w, viewport.w)
view = {pan_x = 50, pan_y = 25, scale = 1}
viewport = assert(Native.viewport({width = 100, height = 50}, view, canvas, minimap, Graph))
near(viewport.x, minimap.x); near(viewport.y, minimap.y)
near(viewport.w, minimap.w); near(viewport.h, minimap.h)
assert(not viewport.outside, 'a graph wholly inside the camera gives a full minimap frame')
viewport = assert(Native.viewport(layout, view, canvas, minimap, Graph))
near(viewport.x, 10); near(viewport.w, 15)
near(viewport.y, 20); near(viewport.h, 7.5)
for _, pan_x in ipairs({-1000000, 1000000}) do
    for _, pan_y in ipairs({-1000000, 1000000}) do
        local result = assert(Native.viewport(layout, {pan_x = pan_x, pan_y = pan_y, scale = 1}, canvas, minimap, Graph))
        assert(result.outside and result.w == 2 and result.h == 2)
        assert(result.x >= minimap.x and result.x + result.w <= minimap.x + minimap.w)
        assert(result.y >= minimap.y and result.y + result.h <= minimap.y + minimap.h)
    end
end
assert(Native.viewport({width = 0, height = 1}, view, canvas, minimap, Graph) == nil)
assert(Native.viewport(layout, {pan_x = 0 / 0}, canvas, minimap, Graph) == nil)

calls = {}
view = {pan_x = -100, pan_y = -50, scale = 1}
local original_clip, original_colour = {90, 130, 100, 80}, colour
clip = original_clip
assert(Native.minimap_viewport(g, layout, view, canvas, minimap, Graph))
local clipping = matching('scissor')[1].args
assert(clipping[1] == 90 and clipping[2] == 130 and clipping[3] == 100 and clipping[4] == 80,
    'minimap clip transforms with native canvas scaling and intersects the caller clip')
assert(clip == original_clip and colour == original_colour and #stack == 0)
assert(#matching('rectangle') == 6, 'four outside masks, viewport fill, and visible frame are drawn')
for _, call in ipairs(matching('rectangle')) do
    local a = call.args
    assert(a[2] >= minimap.x and a[3] >= minimap.y
        and a[2] + a[4] <= minimap.x + minimap.w
        and a[3] + a[5] <= minimap.y + minimap.h,
        'viewport geometry cannot spill outside the minimap')
end
local rectangle = g.rectangle
g.rectangle = function() error('simulated viewport draw failure') end
assert(not pcall(Native.minimap_viewport, g, layout, view, canvas, minimap, Graph))
assert(#stack == 0 and clip == original_clip and colour == original_colour)
g.rectangle = rectangle
local draw = g.draw
g.draw = function() error('simulated native image failure') end
assert(not pcall(Native.card_shell, g, 0, 0, 71, 95))
assert(#stack == 0 and clip == original_clip and colour == original_colour)
g.draw = draw

-- The main graph window makes clipping legible with a narrow edge fade and
-- native stepped panel boundary, while keeping the center entirely untouched.
g.polygon = function(...) record('polygon', ...) end
calls = {}
local frame_canvas = {x = 70, y = 78, w = 200, h = 100}
local frame_clip = {210, 250, 130, 90}
clip = frame_clip
local frame_colour, frame_line_width = colour, line_width
assert(Native.canvas_frame(g, frame_canvas))
assert(#stack == 0 and clip == frame_clip and colour == frame_colour and line_width == frame_line_width,
    'canvas framing restores inherited clipping, tint and line width')
local frame_scissor = matching('scissor')[1].args
assert(frame_scissor[1] == 210 and frame_scissor[2] == 250
    and frame_scissor[3] == 130 and frame_scissor[4] == 90,
    'the graph-window frame uses transformed canvas clipping, intersected with its caller')
local fills, colours = matching('rectangle'), matching('colour')
assert(#fills == 26 and #colours == 9, 'six edge rings plus two quiet inner highlight lines')
for index = 2, 6 do
    assert(colours[index - 1].args[4] > colours[index].args[4] and colours[index].args[4] > 0,
        'edge alpha fades progressively toward the graph content')
end
near(colours[1].args[4], 0.55)
local middle_x, middle_y = frame_canvas.x + frame_canvas.w / 2, frame_canvas.y + frame_canvas.h / 2
for _, call in ipairs(fills) do
    local a = call.args
    assert(a[2] >= frame_canvas.x and a[3] >= frame_canvas.y
        and a[2] + a[4] <= frame_canvas.x + frame_canvas.w
        and a[3] + a[5] <= frame_canvas.y + frame_canvas.h)
    assert(not (middle_x >= a[2] and middle_x <= a[2] + a[4]
        and middle_y >= a[3] and middle_y <= a[3] + a[5]),
        'the edge overlay must never dim the middle of the graph')
    assert(call.clip[1] == frame_clip[1] and call.clip[2] == frame_clip[2])
end
local outlines = matching('polygon')
assert(#outlines == 1 and outlines[1].args[1] == 'line')
local corners = outlines[1].args
for index = 2, #corners - 2, 2 do
    assert(corners[index] == corners[index + 2] or corners[index + 1] == corners[index + 3],
        'the panel boundary uses native pixel steps, not rounded or diagonal modern borders')
end
assert(corners[#corners - 1] == corners[2] or corners[#corners] == corners[3])
assert(#matching('draw') == 0 and #matching('quad') == 0,
    'the visible-window frame needs no new textures, game objects or shaders')
calls = {}
assert(Native.canvas_frame(g, {x = 70, y = 78, w = 0, h = 100}) == false and #calls == 0)
g.polygon = function() error('simulated canvas frame failure') end
assert(not pcall(Native.canvas_frame, g, frame_canvas))
assert(#stack == 0 and clip == frame_clip and colour == frame_colour and line_width == frame_line_width,
    'a boundary draw failure cannot leak clipping or graphics state into the native game')


-- Mirror one triangle, so both page arrows have identical visual dimensions.
g.polygon=function(...) record('polygon',...) end
calls={};Native.arrow(g,20,20,12,7,'up');local up=matching('polygon')[1].args
calls={};Native.arrow(g,20,20,12,7,'down');local down=matching('polygon')[1].args
assert(#up==#down and #up==7)
for i=2,#up,2 do assert(up[i]==down[i]);near(up[i+1]+down[i+1],40) end
calls={};Native.dashed_region(g,{x=10,y=20,w=300,h=240})
assert(#matching('rectangle')>20,'fold boundaries have clear dashes on all four sides')
local frame=matching('rectangle')[1].args
assert(frame[2]<10 and frame[3]<20 and frame[4]>300 and frame[5]>240)

-- Enhanced playing cards layer native face, rank/suit, seal and sticker art.
local fronts,stickers=image(13*71,4*95),image(5*71,3*95)
G.ASSET_ATLAS.cards_1={image=fronts,px=71,py=95}
G.ASSET_ATLAS.stickers={image=stickers,px=71,py=95}
G.P_CENTERS={m_bonus={set='Enhanced',pos={x=1,y=1}}}
G.SETTINGS={}
local saved={key='m_bonus',set='Enhanced',suit='Spades',rank='Ace',seal='Red',eternal=true,ability={bonus=30}}
calls={};assert(Native.card(g,saved,0,0,71,95))
local face,seal,sticker=false,false,false
for _,call in ipairs(matching('draw')) do
    local image,quad=call.args[1],call.args[2]
    face=face or image==fronts and quad.x==12*71 and quad.y==3*95
    seal=seal or image==centers and quad.x==5*71 and quad.y==4*95
    sticker=sticker or image==stickers and quad.x==0 and quad.y==0
end
assert(face and seal and sticker and saved.ability.bonus==30 and saved.seal=='Red')

G, Card, Sprite, UIBox, math.random, math.randomseed, pseudorandom = previous.G,
    previous.Card, previous.Sprite, previous.UIBox, previous.random, previous.randomseed, previous.pseudorandom
return true

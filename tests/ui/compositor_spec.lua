local Compositor = dofile('src/ui/compositor.lua')
local function clone(value)
    if type(value) ~= 'table' or value.canvas_object then return value end
    local result = {}
    for key, item in pairs(value) do result[key] = clone(item) end
    return result
end
local function equal(a, b)
    if type(a) ~= type(b) then return false end
    if type(a) ~= 'table' or a.canvas_object then return a == b end
    for key, value in pairs(a) do if not equal(value, b[key]) then return false end end
    for key in pairs(b) do if a[key] == nil then return false end end
    return true
end
local function near(a, b) assert(math.abs(a - b) < 0.000001, tostring(a) .. ' ~= ' .. tostring(b)) end
local scene = {canvas_object = true, pixel = {0.1, 0.2, 0.3, 1}}
local depth_canvas = {canvas_object = true}
local second_target = {canvas_object = true}
local state = {targets = {{scene, mipmap = 1}, {second_target, mipmap = 2},
    depthstencil = {depth_canvas, mipmap = 1}, stencil = true, depth = true},
    shader = 'native shader', scissor = {13, 27, 400, 300}, stencil = {'equal', 4},
    depth = {'less', true}, blend = {'add', 'premultiplied'}, color = {0.7, 0.6, 0.5, 0.4},
    color_mask = {true, false, true, false}, wireframe = true,
    transform = {x = 23, y = 41, sx = 1.5, sy = 1.5}}
local original = clone(state)
local stack, calls, canvases, allocations, fail_allocation = {}, {}, {}, 0, false
local g = {}
local function record(name, ...) calls[#calls + 1] = {name = name, args = {...}, state = clone(state)} end
function g.getStackDepth() return #stack end
function g.push(mode) assert(mode == 'all'); stack[#stack + 1] = clone(state); record('push', mode) end
function g.pop() assert(#stack > 0); state = table.remove(stack); record('pop') end
function g.getCanvas() error('Do not reconstruct native attachments from SMODS getCanvas') end
function g.getDPIScale() error('Native logical canvas dimensions must not be scaled twice') end
function g.newCanvas(w, h, options)
    if fail_allocation then error('GPU allocation failed') end
    allocations = allocations + 1
    assert(w > 0 and h > 0 and options.format == 'rgba8' and options.dpiscale == 1 and options.msaa == 0)
    local canvas = {canvas_object = true, width = w, height = h, pixel = {0, 0, 0, 0}}
    function canvas:setFilter(a, b) assert(a == 'linear' and b == 'linear'); self.filtered = true end
    function canvas:release() assert(not self.released); self.released = true; record('release', self) end
    canvases[#canvases + 1] = canvas
    record('newCanvas', w, h, options)
    return canvas
end
function g.setCanvas(canvas) state.targets = {{canvas, mipmap = 1}}; record('setCanvas', canvas) end
function g.origin() state.transform = {x = 0, y = 0, sx = 1, sy = 1}; record('origin') end
function g.setShader(shader) state.shader = shader; record('setShader', shader) end
function g.setScissor(...) state.scissor = select('#', ...) > 0 and {...} or nil; record('setScissor', ...) end
function g.setStencilTest(...) state.stencil = select('#', ...) > 0 and {...} or nil; record('setStencilTest', ...) end
function g.setDepthMode(...) state.depth = select('#', ...) > 0 and {...} or nil; record('setDepthMode', ...) end
function g.setColorMask(...) state.color_mask = {...}; record('setColorMask', ...) end
function g.setWireframe(value) state.wireframe = value; record('setWireframe', value) end
function g.setBlendMode(...) state.blend = {...}; record('setBlendMode', ...) end
function g.setColor(...) state.color = {...}; record('setColor', ...) end
function g.clear(r, green, b, a)
    assert(not state.scissor and not state.stencil and not state.depth)
    assert(state.targets[1][1] ~= scene, 'never clear the native scene or stencil attachment')
    state.targets[1][1].pixel = {r, green, b, a}; record('clear', r, green, b, a)
end
local function blend(source)
    local pixel = state.targets[1][1].pixel
    local factor = state.blend[2] == 'alphamultiply' and source[4] or 1
    for i = 1, 3 do pixel[i] = source[i] * factor + pixel[i] * (1 - source[4]) end
    pixel[4] = source[4] + pixel[4] * (1 - source[4])
end
function g.rectangle()
    assert(state.blend[1] == 'alpha' and state.blend[2] == 'alphamultiply')
    blend(state.color); record('rectangle')
end
function g.draw(canvas, ...)
    assert(state.targets[1][1] == scene and state.targets.depthstencil[1] == depth_canvas,
        'restore the complete native attachments before compositing')
    assert(state.targets[2][1] == second_target and state.targets[2].mipmap == 2)
    local color = {}
    for i = 1, 4 do color[i] = canvas.pixel[i] * state.color[i] end
    blend(color); record('draw', canvas, ...)
end
local function reset_calls() calls = {} end
local function count(name)
    local result = 0; for _, item in ipairs(calls) do if item.name == name then result = result + 1 end end
    return result
end
local function matches_original()
    assert(equal(state, original), 'native canvas/shader/scissor/stencil/depth/blend/mask/transform leaked')
    assert(#stack == 0)
end
local old_random, old_G, old_love = math.random, G, love
math.random = function() error('compositing must not consume RNG') end
G = {GAME = {seeded = false}, SETTINGS = {GRAPHICS = {crt = 82}}}
love = {graphics = g, filesystem = {write = function() error('no save access') end}}

-- Fully open is a direct pass; no texture, canvas switch or fade draw is needed.
local callback_calls = 0
assert(Compositor.draw(g, 1600, 900, 1, 1, function()
    callback_calls = callback_calls + 1
    assert(equal(state.targets, original.targets))
    g.setShader('callback shader'); g.setScissor(); g.origin()
end))
assert(callback_calls == 1 and allocations == 0 and count('setCanvas') == 0 and count('draw') == 0)
matches_original()
assert(Compositor.draw(g, 1600, 900, 0, 0.97, function() error('hidden callback must not run') end) == false)
assert(allocations == 0)

reset_calls()
assert(Compositor.draw(g, 1600, 900, 0.4, 0.97, function()
    callback_calls = callback_calls + 1
    assert(state.targets[1][1] ~= scene and not state.targets.depthstencil)
    assert(not state.shader and not state.scissor and not state.stencil and not state.depth)
    assert(state.color_mask[1] and state.color_mask[2] and state.color_mask[3] and state.color_mask[4])
    assert(not state.wireframe)
    g.setColor(1, 0, 0, 0.5); g.rectangle('fill', 0, 0, 20, 20)
    g.setColor(0, 0, 1, 0.5); g.rectangle('fill', 0, 0, 20, 20)
end))
assert(callback_calls == 2 and allocations == 1 and count('draw') == 1)
near(canvases[1].pixel[1], 0.25); near(canvases[1].pixel[3], 0.5); near(canvases[1].pixel[4], 0.75)
near(scene.pixel[1], 0.17); near(scene.pixel[2], 0.14); near(scene.pixel[3], 0.41); near(scene.pixel[4], 1)
for _, item in ipairs(calls) do
    if item.name == 'draw' then
        assert(item.state.blend[1] == 'alpha' and item.state.blend[2] == 'premultiplied')
        for i = 1, 4 do near(item.state.color[i], 0.4) end
        local p = item.args
        assert(p[2] == 800 and p[3] == 450 and p[4] == 0 and p[5] == 0.97 and p[6] == 0.97
            and p[7] == 800 and p[8] == 450, 'scale around the native viewport center')
    end
end
matches_original()

-- Same-size transitions reuse and clear the texture; resize releases the old one.
assert(Compositor.draw(g, 1600, 900, 0.8, 0.99, function() end))
assert(allocations == 1)
assert(Compositor.draw(g, 1601, 901, 1, 1, function() end))
assert(allocations == 1 and canvases[1].released, 'fully open resize retires stale texture without allocating')
assert(Compositor.draw(g, 1920, 1080, 0.8, 0.99, function() end))
assert(allocations == 2 and canvases[1].released and not canvases[2].released)
matches_original()
fail_allocation = true
local success, err = Compositor.draw(g, 2560, 1440, 0.5, 0.98, function() error('no texture') end)
assert(success == nil and tostring(err):find('GPU allocation failed', 1, true))
assert(not canvases[2].released, 'failed resize preserves the usable prior cache')
matches_original()
fail_allocation = false

-- A callback can fail after changing every state and adding unbalanced pushes.
local marker = {technical_error = true}
success, err = Compositor.draw(g, 1920, 1080, 1, 1, function()
    g.setShader('direct failed shader'); g.setStencilTest(); g.setScissor(); g.origin()
    error(marker)
end)
assert(success == nil and err == marker)
matches_original()
success, err = Compositor.draw(g, 1920, 1080, 0.4, 0.97, function()
    g.push('all'); g.setCanvas({canvas_object = true}); g.setShader('failed shader')
    g.setScissor(1, 2, 3, 4); g.setStencilTest('greater', 10); g.setDepthMode('equal', true)
    g.setBlendMode('subtract', 'alphamultiply'); g.origin()
    error(marker)
end)
assert(success == nil and err == marker, 'retain the exact original error value')
matches_original()
assert(Compositor.draw(g, 1920, 1080, 1, 1, function() end), 'a failed frame does not leave the compositor busy')
success, err = Compositor.draw(g, 1920, 1080, 0.5, 0.98, function() return nil, 'returned error' end)
assert(success == nil and err == 'returned error')
matches_original()
reset_calls()
assert(Compositor.draw(g, 1920, 1080, 0.5, 0.98, function() return false end) == false)
assert(count('draw') == 0)
matches_original()

-- Existing caller stack frames are not ours to pop; reentry is rejected safely.
g.push('all')
assert(Compositor.draw(g, 1920, 1080, 0.5, 0.98, function()
    local nested, reason = Compositor.draw(g, 1920, 1080, 0.5, 0.98, function() end)
    assert(nested == nil and reason:find('already drawing', 1, true))
end))
assert(#stack == 1); g.pop(); matches_original()
assert(Compositor.draw(g, 0, 900, 0.5, 1, function() end) == nil)
assert(Compositor.draw(g, 1600.2, 900, 0.5, 1, function() end) == nil)
assert(Compositor.draw(g, 1600, 900, 0/0, 1, function() end) == nil)

-- Native transition borrows only shader source; shared game shaders stay untouched.
local reads, compilations, shader = 0,0,nil
love.filesystem = {read=function(path)
    assert(path=='resources/shaders/dissolve.fs'); reads=reads+1; return 'native dissolve source' end}
g.newShader = function(source)
    assert(source=='native dissolve source'); compilations=compilations+1
    shader = {uniforms={}}
    function shader:send(key,value) self.uniforms[key]=value end
    return shader
end
local shared = {send=function() error('Shared native shader must never change') end}
G.SHADERS={dissolve=shared}
assert(Compositor.draw(g,1920,1080,0.5,1,function() g.setColor(1,1,1,1); g.rectangle() end,
    {native_dissolve=true,time=12}))
near(shader.uniforms.dissolve,0.5); near(shader.uniforms.time,12)
assert(shader.uniforms.image_details[1]==192 and shader.uniforms.texture_details[4]==108)
matches_original()
assert(Compositor.draw(g,1920,1080,0.8,1,function() end,{native_dissolve=true,time=14}))
assert(reads==1 and compilations==1 and G.SHADERS.dissolve==shared)
near(shader.uniforms.dissolve,0.2); matches_original()
assert(Compositor.release(g) and canvases[2].released)
assert(Compositor.release(g) == false)
assert(not G.GAME.seeded and G.SETTINGS.GRAPHICS.crt == 82)
math.random, G, love = old_random, old_G, old_love
print('PASS compositor: cached whole-UI alpha/scale, exact native attachments, resize and failure-state recovery')

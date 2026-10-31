-- Transition-only group compositing, before the game's own CRT pass.
-- LÖVE 11.5 push('all') preserves native RenderTargetsStrongRef, including the
-- depth/stencil attachment. pop restores it in Graphics::restoreStateChecked.
-- Do not reconstruct these targets with SMODS' lossy getCanvas() wrapper.
local Compositor = {}
local caches = setmetatable({}, {__mode = 'k'})
local busy = setmetatable({}, {__mode = 'k'})
local dissolve_shaders = setmetatable({}, {__mode = 'k'})

local function native_dissolve(g, width, height, amount, options)
    if not (options and options.native_dissolve) then return nil end
    local entry = dissolve_shaders[g]
    if not entry then
        entry = {}; dissolve_shaders[g] = entry
        if love and love.filesystem and love.filesystem.read and g.newShader then
            local ok, shader = pcall(function()
                return g.newShader(assert(love.filesystem.read('resources/shaders/dissolve.fs')))
            end)
            if ok then entry.shader = shader end
        end
    end
    if not entry.shader then return nil end
    local shader = entry.shader
    local ok = pcall(function()
        -- Use the original dissolve program used by native wipe cards, with a
        -- private instance. Calling wipe_on would create random Cards and lock
        -- the gameplay event queue, so this transition only masks our own canvas.
        shader:send('dissolve', 1 - amount)
        shader:send('time', options.time or 0)
        shader:send('texture_details', {0, 0, width / 10, height / 10})
        shader:send('image_details', {width / 10, height / 10})
        shader:send('shadow', false)
        shader:send('burn_colour_1', {1, 0.57, 0.13, 1})
        shader:send('burn_colour_2', {1, 0.82, 0.24, 1})
        shader:send('hovering', 0)
        shader:send('mouse_screen_pos', {0, 0})
        shader:send('screen_scale', 1)
    end)
    if not ok then entry.shader = nil; return nil end
    return shader
end

local function finite(value)
    return type(value) == 'number' and value == value and math.abs(value) ~= math.huge
end

local function release_canvas(canvas)
    if canvas and type(canvas.release) == 'function' then canvas:release() end
end

local function canvas_for(g, width, height)
    local previous = caches[g]
    if previous and previous.width == width and previous.height == height then return previous.canvas end
    -- Allocate before retiring the old texture, so a failed resize remains
    -- retryable. Both allocation and release run only in the caller's draw thread.
    local canvas = assert(g.newCanvas(width, height,
        {format = 'rgba8', dpiscale = 1, msaa = 0, readable = true}), 'Cannot create transition canvas')
    local ok, err = pcall(canvas.setFilter, canvas, 'linear', 'linear')
    if not ok then pcall(release_canvas, canvas); error(err, 0) end
    caches[g] = {canvas = canvas, width = width, height = height}
    if previous then release_canvas(previous.canvas) end
    return canvas
end

local function scope(g, callback)
    local depth = g.getStackDepth()
    g.push('all')
    local ok, value, err = pcall(callback)
    local returned_depth = g.getStackDepth()
    -- A callback may throw after pushing its own state. Unwind its remaining
    -- frames as well, without popping any frame belonging to the native game.
    while g.getStackDepth() > depth do g.pop() end
    if not ok then error(value, 0) end
    assert(returned_depth == depth + 1, 'Unbalanced graphics stack in transition callback')
    return value, err
end

local function neutral(g)
    g.origin()
    g.setShader()
    g.setScissor()
    g.setStencilTest()
    g.setDepthMode()
    g.setColorMask(true, true, true, true)
    g.setWireframe(false)
end

local function run_callback(callback)
    local result, err = callback()
    if result == nil and err ~= nil then error(err, 0) end
    return result ~= false
end

-- width/height are the native target's logical dimensions (already including
-- CANV_SCALE). Never multiply them by window DPIScale. Callback performs its
-- usual Renderer origin/layout/render_scale work and is invoked at most once.
-- Invoke outside love.graphics.stencil's write callback, as at the cursor hook.
function Compositor.draw(g, width, height, opacity, scale, callback, options)
    if type(g) ~= 'table' or type(callback) ~= 'function' then return nil, 'Invalid transition renderer' end
    if not finite(width) or not finite(height) or width <= 0 or height <= 0
        or width % 1 ~= 0 or height % 1 ~= 0 then return nil, 'Invalid transition canvas dimensions' end
    opacity, scale = opacity == nil and 1 or opacity, scale == nil and 1 or scale
    if not finite(opacity) or not finite(scale) or scale <= 0 then return nil, 'Invalid transition amount' end
    if busy[g] then return nil, 'Transition compositor is already drawing' end
    opacity = math.max(0, math.min(1, opacity))
    if opacity == 0 then return false end
    busy[g] = true
    local ok, result = pcall(function()
        return scope(g, function()
            if opacity == 1 and scale == 1 then
                local previous = caches[g]
                if previous and (previous.width ~= width or previous.height ~= height) then
                    release_canvas(previous.canvas)
                    caches[g] = nil
                end
                return run_callback(callback)
            end
            local canvas = canvas_for(g, width, height)
            local painted = scope(g, function()
                g.setCanvas(canvas)
                neutral(g)
                g.setBlendMode('alpha', 'alphamultiply')
                g.setColor(1, 1, 1, 1)
                g.clear(0, 0, 0, 0)
                return run_callback(callback)
            end)
            if not painted then return false end
            -- Inner pop has restored the exact original scene attachments.
            -- Canvas pixels are already premultiplied by the primitive pass;
            -- multiply RGB and alpha together for a true whole-interface fade.
            neutral(g)
            local dissolve = native_dissolve(g, width, height, opacity, options)
            if dissolve then
                -- The native shader has a binary alpha mask; alphamultiply
                -- prevents invisible masked RGB from leaking onto the scene.
                g.setShader(dissolve)
                g.setBlendMode('alpha', 'alphamultiply')
                g.setColor(1, 1, 1, 1)
            else
                g.setBlendMode('alpha', 'premultiplied')
                g.setColor(opacity, opacity, opacity, opacity)
            end
            g.draw(canvas, width / 2, height / 2, 0, scale, scale, width / 2, height / 2)
            return true
        end)
    end)
    busy[g] = nil
    if not ok then return nil, result end
    return result
end

-- Optional shutdown/cleanup entry point; call on the same main render thread.
function Compositor.release(g)
    if busy[g] then return nil, 'Transition compositor is already drawing' end
    local cached = caches[g]
    if not cached then return false end
    local ok, err = pcall(release_canvas, cached.canvas)
    if not ok then return nil, err end
    caches[g] = nil
    return true
end

return Compositor

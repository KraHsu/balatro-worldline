-- Read-only use of native card/chip art plus camera-to-minimap projection.
-- No Card/Sprite/UIBox objects, animation updates, gameplay calls or RNG.
local Native = {CARD_WIDTH = 71, CARD_HEIGHT = 95}
local quad_cache = setmetatable({}, {__mode = 'k'})
local generic_chips = {start = 0, choose = 3, skip = 2, failed = 1}

local function finite(value)
    return type(value) == 'number' and value == value and math.abs(value) ~= math.huge
end
local function positive(value) return finite(value) and value > 0 end
local function clamp(value, low, high) return math.max(low, math.min(high, value)) end
local function tint(g, colour, alpha)
    colour = colour or {1, 1, 1, 1}
    g.setColor(colour[1] or 1, colour[2] or 1, colour[3] or 1,
        alpha ~= nil and alpha or colour[4] or 1)
end
local function protected(g, fn)
    g.push('all')
    local ok, result = pcall(fn)
    g.pop()
    if not ok then error(result, 0) end
    return result
end
local function fit(x, y, w, h, native_w, native_h)
    if not (finite(x) and finite(y) and positive(w) and positive(h)) then return nil end
    local scale = math.min(w / native_w, h / native_h)
    local fw, fh = native_w * scale, native_h * scale
    return {x = x + (w - fw) / 2, y = y + (h - fh) / 2, w = fw, h = fh}
end

function Native.card_rect(x, y, w, h)
    return fit(x, y, w, h, Native.CARD_WIDTH, Native.CARD_HEIGHT)
end

local function descriptor(key, animated, x, y, contains_text)
    local registry
    if G then
        if animated then registry = G.ANIMATION_ATLAS else registry = G.ASSET_ATLAS end
    end
    local data = registry and registry[key]
    if not (data and data.image and type(data.image.getDimensions) == 'function'
        and positive(data.px) and positive(data.py) and finite(x) and finite(y)
        and x >= 0 and y >= 0 and x % 1 == 0 and y % 1 == 0) then return nil end
    local ok, iw, ih = pcall(data.image.getDimensions, data.image)
    if not (ok and positive(iw) and positive(ih)) then return nil end
    if (x + 1) * data.px > iw or (y + 1) * data.py > ih then return nil end
    return {atlas_key = key, animated = animated, image = data.image,
        pos = {x = x, y = y}, px = data.px, py = data.py,
        image_w = iw, image_h = ih, contains_text = contains_text == true}
end

local function draw_atlas(g, item, rect, colour, alpha)
    if not (item and rect and type(g.newQuad) == 'function') then return false end
    local cache = quad_cache[item.image]
    if not cache then cache = {}; quad_cache[item.image] = cache end
    local key = table.concat({item.pos.x, item.pos.y, item.px, item.py}, ':')
    if not cache[key] then
        cache[key] = g.newQuad(item.pos.x * item.px, item.pos.y * item.py,
            item.px, item.py, item.image_w, item.image_h)
    end
    tint(g, colour, alpha)
    g.draw(item.image, cache[key], rect.x, rect.y, 0, rect.w / item.px, rect.h / item.py)
    return true
end

function Native.card_shell(g, x, y, w, h, options)
    options = options or {}
    local rect = Native.card_rect(x, y, w, h)
    local blank = descriptor('centers', false, 1, 0)
    if not (rect and blank and type(g.newQuad) == 'function') then return false, rect end
    protected(g, function()
        -- Shadow and selection use the same native silhouette, never a second
        -- invented frame or corner system. Card art keeps its natural 71:95 ratio.
        if options.shadow ~= false then
            draw_atlas(g, blank, {x = rect.x + 3, y = rect.y + 5, w = rect.w, h = rect.h},
                {0, 0, 0}, options.shadow_alpha or 0.32)
        end
        if options.selected or options.current or options.hover then
            local border = options.highlight or (options.current and {1, 0.82, 0.24, 1}
                or {0.38, 0.75, 1, 1})
            local scale = (rect.w + 6) / rect.w
            local bw, bh = rect.w * scale, rect.h * scale
            draw_atlas(g, blank, {x = rect.x - (bw - rect.w) / 2,
                y = rect.y - (bh - rect.h) / 2, w = bw, h = bh}, border,
                options.hover and not (options.current or options.selected) and 0.5 or nil)
        end
        draw_atlas(g, blank, rect, options.tint)
    end)
    return true, rect
end

function Native.chip_descriptor(kind, options)
    options = options or {}
    if kind == 'shop' then return descriptor('shop_sign', true, 0, 0) end
    if kind == 'small' or kind == 'big' or kind == 'boss' then
        local key = options.blind_key or (kind == 'small' and 'bl_small')
            or (kind == 'big' and 'bl_big')
        local blind = G and G.P_BLINDS and G.P_BLINDS[key]
        if not blind then blind = G and G.b_undiscovered end
        local pos = options.pos or blind and blind.pos or {x = 0, y = 30}
        if type(pos) ~= 'table' or not (finite(pos.x or 0) and finite(pos.y or 0)) then return nil end
        local requested_frame = tonumber(options.frame)
        local frame = finite(requested_frame) and math.floor(requested_frame) or 0
        local data = G and G.ANIMATION_ATLAS and G.ANIMATION_ATLAS.blind_chips
        local frames = data and positive(data.frames) and data.frames or 1
        frame = clamp(frame, 0, math.max(0, frames - 1))
        local item = descriptor('blind_chips', true, (pos.x or 0) + frame, pos.y or 0, true)
        if item then item.blind_key = key; return item end
    end
    -- Native chips.png has 29px cells: white, red, green, blue, black. The
    -- upper row is the full face; unlike blind_chips it has no embedded label.
    local column = generic_chips[kind]
    if column ~= nil then return descriptor('chips', false, column, 0) end
    return nil
end

function Native.chip(g, kind, cx, cy, size, options)
    local item = Native.chip_descriptor(kind, options)
    if not item or not (positive(size) and finite(cx) and finite(cy)) then return false, item end
    local rect = fit(cx - size / 2, cy - size / 2, size, size, item.px, item.py)
    if not rect then return false, item end
    local ok = protected(g, function() return draw_atlas(g, item, rect, options and options.tint) end)
    return ok, item
end

function Native.viewport(layout, view, canvas, minimap, Graph)
    if not (layout and view and canvas and minimap and positive(layout.width)
        and positive(layout.height) and positive(canvas.w) and positive(canvas.h)
        and positive(minimap.w) and positive(minimap.h)
        and finite(view.pan_x or 0) and finite(view.pan_y or 0)
        and finite(canvas.x or 0) and finite(canvas.y or 0)
        and finite(minimap.x) and finite(minimap.y)) then return nil end
    local left, top, right, bottom
    if Graph and type(Graph.screen_to_world) == 'function' then
        left, top = Graph.screen_to_world(view, canvas.x or 0, canvas.y or 0, canvas)
        right, bottom = Graph.screen_to_world(view, (canvas.x or 0) + canvas.w,
            (canvas.y or 0) + canvas.h, canvas)
    else
        local scale = clamp(finite(view.scale) and view.scale or 1, 0.25, 1.6)
        left, top = -(view.pan_x or 0) / scale, -(view.pan_y or 0) / scale
        right, bottom = left + canvas.w / scale, top + canvas.h / scale
    end
    if not (finite(left) and finite(top) and finite(right) and finite(bottom)) then return nil end
    local raw_x = minimap.x + left / layout.width * minimap.w
    local raw_y = minimap.y + top / layout.height * minimap.h
    local raw_right = minimap.x + right / layout.width * minimap.w
    local raw_bottom = minimap.y + bottom / layout.height * minimap.h
    local x, y = clamp(raw_x, minimap.x, minimap.x + minimap.w),
        clamp(raw_y, minimap.y, minimap.y + minimap.h)
    local w = clamp(raw_right, minimap.x, minimap.x + minimap.w) - x
    local h = clamp(raw_bottom, minimap.y, minimap.y + minimap.h) - y
    local outside = w <= 0 or h <= 0
    -- A camera entirely beyond the graph leaves a small indicator at the edge,
    -- instead of drawing an unbounded box or pretending all nodes are visible.
    local mw, mh = math.min(2, minimap.w), math.min(2, minimap.h)
    if w < mw then w = mw; x = clamp(x - mw / 2, minimap.x, minimap.x + minimap.w - mw) end
    if h < mh then h = mh; y = clamp(y - mh / 2, minimap.y, minimap.y + minimap.h - mh) end
    return {x = x, y = y, w = w, h = h, outside = outside,
        world = {x = left, y = top, w = right - left, h = bottom - top}}
end

local function clip_rect(g, bounds)
    local left, top, right, bottom = bounds.x, bounds.y, bounds.x + bounds.w, bounds.y + bounds.h
    if type(g.transformPoint) == 'function' then
        local x1, y1 = g.transformPoint(left, top)
        local x2, y2 = g.transformPoint(right, bottom)
        local x3, y3 = g.transformPoint(left, bottom)
        local x4, y4 = g.transformPoint(right, top)
        left, top, right, bottom = math.min(x1, x2, x3, x4), math.min(y1, y2, y3, y4),
            math.max(x1, x2, x3, x4), math.max(y1, y2, y3, y4)
    end
    if type(g.getScissor) == 'function' then
        local x, y, w, h = g.getScissor()
        if x then left, top, right, bottom = math.max(left, x), math.max(top, y),
            math.min(right, x + w), math.min(bottom, y + h) end
    end
    g.setScissor(left, top, math.max(0, right - left), math.max(0, bottom - top))
end

function Native.minimap_viewport(g, layout, view, canvas, minimap, Graph, options)
    local rect = Native.viewport(layout, view, canvas, minimap, Graph)
    if not rect then return nil end
    options = options or {}
    protected(g, function()
        clip_rect(g, minimap)
        local outside_alpha = options.outside_alpha or 0.18
        tint(g, {0, 0, 0}, outside_alpha)
        local function mask(x, y, w, h)
            if w > 0 and h > 0 then g.rectangle('fill', x, y, w, h) end
        end
        mask(minimap.x, minimap.y, minimap.w, rect.y - minimap.y)
        mask(minimap.x, rect.y + rect.h, minimap.w, minimap.y + minimap.h - rect.y - rect.h)
        mask(minimap.x, rect.y, rect.x - minimap.x, rect.h)
        mask(rect.x + rect.w, rect.y, minimap.x + minimap.w - rect.x - rect.w, rect.h)
        local colour = options.tint or {1, 0.96, 0.81, 1}
        tint(g, colour, rect.outside and 0.04 or 0.10)
        g.rectangle('fill', rect.x, rect.y, rect.w, rect.h)
        tint(g, colour, rect.outside and 0.65 or 1)
        g.setLineWidth(options.line_width or 1.5)
        g.rectangle('line', rect.x + 0.5, rect.y + 0.5, math.max(0, rect.w - 1), math.max(0, rect.h - 1))
    end)
    return rect
end

function Native.canvas_frame(g, canvas, options)
    if not (canvas and finite(canvas.x) and finite(canvas.y) and positive(canvas.w) and positive(canvas.h)) then
        return false
    end
    options = options or {}
    local requested_width = tonumber(options.edge_width)
    local edge_width = clamp(finite(requested_width) and requested_width or 12, 0,
        math.min(canvas.w, canvas.h) / 2)
    protected(g, function()
        clip_rect(g, canvas)
        local steps, band = 6, edge_width / 6
        local edge_colour = options.edge_tint or {0.018, 0.13, 0.12, 1}
        local edge_alpha = options.edge_alpha or 0.55
        local function rect(x, y, w, h)
            if w > 0 and h > 0 then g.rectangle('fill', x, y, w, h) end
        end
        -- Disjoint two-pixel rings soften the hard content cutoff without
        -- painting the center or adding another canvas/shader/postprocess pass.
        for index = 0, steps - 1 do
            local inset = index * band
            local x, y = canvas.x + inset, canvas.y + inset
            local w, h = canvas.w - inset * 2, canvas.h - inset * 2
            local amount = (steps - index) / steps
            tint(g, edge_colour, edge_alpha * amount * amount)
            rect(x, y, w, band)
            rect(x, y + h - band, w, band)
            rect(x, y + band, band, h - band * 2)
            rect(x + w - band, y + band, band, h - band * 2)
        end
        -- Native Balatro panels use square pixels with stepped cut corners.
        -- Keep the thin outline inside the content clip rather than expanding
        -- the visual frame into adjacent controls or the convergence sidebar.
        local x, y = canvas.x + 0.5, canvas.y + 0.5
        local w, h = math.max(0, canvas.w - 1), math.max(0, canvas.h - 1)
        local cut = math.min(4, w / 4, h / 4)
        tint(g, options.border_tint or {0.35, 0.54, 0.46, 1}, options.border_alpha or 0.62)
        g.setLineWidth(1)
        g.polygon('line', x + cut, y, x + w - cut, y,
            x + w - cut, y + cut, x + w, y + cut,
            x + w, y + h - cut, x + w - cut, y + h - cut,
            x + w - cut, y + h, x + cut, y + h,
            x + cut, y + h - cut, x, y + h - cut,
            x, y + cut, x + cut, y + cut)
        tint(g, {0.72, 0.84, 0.74, 1}, 0.16)
        rect(canvas.x + cut + 2, canvas.y + math.min(1, math.max(0, canvas.h - 1)),
            canvas.w - (cut + 2) * 2, math.min(1, canvas.h))
        tint(g, {0.005, 0.04, 0.035, 1}, 0.26)
        rect(canvas.x + cut + 2, canvas.y + math.max(0, canvas.h - 2),
            canvas.w - (cut + 2) * 2, math.min(1, canvas.h))
    end)
    return true
end


-- Draw stored card faces from native atlases without a live Card/Sprite object.
function Native.card(g, item, x, y, w, h, options)
    item,options=item or {},options or {}
    local rect=Native.card_rect(x,y,w,h)
    if not rect then return false end
    local key=item.card_key or item.key
    local center=G and G.P_CENTERS and G.P_CENTERS[key] or {}
    local set=item.set or center.set or 'Joker'
    if set=='Tag' then
        local proto=G and G.P_TAGS and G.P_TAGS[key] or {}
        local pos=item.pos or proto.pos or {}
        return draw_atlas(g,descriptor(item.atlas or proto.atlas or 'tags',false,pos.x or 0,pos.y or 0),
            fit(x,y,w,h,34,34),options.tint)
    end
    Native.card_shell(g,x,y,w,h,options)
    local pos=item.pos or center.pos
    local atlas_key=item.atlas or center.atlas
    if not atlas_key then
        atlas_key=(set=='Joker' or set=='Tarot' or set=='Planet' or set=='Spectral' or set=='Voucher' or set=='Booster') and set or 'centers'
    end
    local face=pos and descriptor(atlas_key,false,pos.x or 0,pos.y or 0)
    if not face and pos and (set=='Planet' or set=='Spectral') then face=descriptor('Tarot',false,pos.x or 0,pos.y or 0) end
    if not face then face=descriptor('centers',false,5,3) end
    draw_atlas(g,face,rect,options.tint)
    if item.suit and key~='m_stone' then
        local base=item.base or {}
        local proto=G and G.P_CARDS and G.P_CARDS[item.base_key] or {}
        local rank=({Jack=11,Queen=12,King=13,Ace=14})[item.rank] or tonumber(item.rank)
        local suit=({Hearts=0,Clubs=1,Diamonds=2,Spades=3})[item.suit]
        local front_pos=base.pos or proto.pos or (rank and suit and {x=rank-2,y=suit})
        local front_atlas=base.atlas or proto.atlas or ('cards_'..(G and G.SETTINGS and G.SETTINGS.colourblind_option and 2 or 1))
        if front_pos then draw_atlas(g,descriptor(front_atlas,false,front_pos.x,front_pos.y),rect,options.tint) end
    end
    local seal=({Gold={2,0},Purple={4,4},Red={5,4},Blue={6,4}})[item.seal]
    if seal then draw_atlas(g,descriptor('centers',false,seal[1],seal[2]),rect) end
    for _,entry in ipairs({{'eternal',0,0},{'perishable',0,2},{'rental',1,2}}) do
        if item[entry[1]] then draw_atlas(g,descriptor('stickers',false,entry[2],entry[3]),rect) end
    end
    return face~=nil,rect
end

-- Both controls share these exact vertices; sign flips only the vertical axis.
function Native.arrow(g,x,y,w,h,direction,colour)
    local sign=direction=='up' and -1 or 1
    tint(g,colour)
    g.polygon('fill',x-w/2,y-sign*h/2,x,y+sign*h/2,x+w/2,y-sign*h/2)
end

function Native.dashed_region(g,rect,options)
    options=options or {};local pad=options.padding or 13
    local x,y,w,h=rect.x-pad,rect.y-pad,rect.w+2*pad,rect.h+2*pad
    tint(g,options.colour or {0.38,0.75,1},0.07);g.rectangle('fill',x,y,w,h)
    tint(g,options.colour or {0.38,0.75,1},0.95)
    local dash,gap,thick=12,8,3
    local function horizontal(yy) local xx=x;while xx<x+w do g.rectangle('fill',xx,yy,math.min(dash,x+w-xx),thick);xx=xx+dash+gap end end
    local function vertical(xx) local yy=y;while yy<y+h do g.rectangle('fill',xx,yy,thick,math.min(dash,y+h-yy));yy=yy+dash+gap end end
    horizontal(y);horizontal(y+h-thick);vertical(x);vertical(x+w-thick)
end

return Native

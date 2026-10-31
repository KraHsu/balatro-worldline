-- Candidate eligibility from the root's profile. The reference is a vanilla
-- run seeded from the start: its discoveries/unlocks do not evolve in-run.
-- Real profile progress is never reverted. Only synchronous pool calculations
-- see these saved flags, and every native algorithm/RNG call stays unchanged.
local Pool = {}
local installed = setmetatable({}, {__mode = 'k'})
local cached_environment, cached_centers, cached_rows
local depth = 0
local function encode(value)
    return value == true and 2 or value == false and 1 or 0
end
local function decode(value)
    if value == 2 then return true elseif value == 1 then return false end
end
function Pool.capture(centers)
    local result = {schema = 1, centers = {}}
    for key, center in pairs(centers or {}) do
        if type(key) == 'string' and type(center) == 'table' then
            result.centers[key] = encode(center.unlocked) + 3 * encode(center.discovered)
        end
    end
    return result
end
function Pool.validate(value)
    if type(value) ~= 'table' or value.schema ~= 1 or type(value.centers) ~= 'table' then return false end
    local count = 0
    for key, flags in pairs(value.centers) do
        count = count + 1
        if count > 4096 or type(key) ~= 'string' or #key < 1 or #key > 256
            or type(flags) ~= 'number' or flags < 0 or flags > 8 or flags % 1 ~= 0 then return false end
    end
    return true
end
local function rows_for(environment, centers)
    if cached_environment == environment and cached_centers == centers then return cached_rows end
    local rows = {}
    for key, flags in pairs(environment.centers) do
        local center = centers[key]
        if type(center) == 'table' then
            rows[#rows + 1] = {center = center, unlocked = decode(flags % 3), discovered = decode(math.floor(flags / 3))}
        end
    end
    cached_environment, cached_centers, cached_rows = environment, centers, rows
    return rows
end
local function pack(...) return {n = select('#', ...), ...} end
function Pool.call(environment, fn, ...)
    if not environment or depth > 0 or not G or not G.P_CENTERS then return fn(...) end
    local rows = rows_for(environment, G.P_CENTERS)
    for _, row in ipairs(rows) do
        row.live_unlocked, row.live_discovered = row.center.unlocked, row.center.discovered
        row.center.unlocked, row.center.discovered = row.unlocked, row.discovered
    end
    depth = depth + 1
    local results = pack(pcall(fn, ...))
    depth = depth - 1
    for _, row in ipairs(rows) do
        row.center.unlocked, row.center.discovered = row.live_unlocked, row.live_discovered
        row.live_unlocked, row.live_discovered = nil, nil
    end
    if not results[1] then error(results[2], 0) end
    return unpack(results, 2, results.n)
end
function Pool.install(environment)
    local function wrap(holder, key)
        if type(holder) ~= 'table' or type(holder[key]) ~= 'function' then return end
        installed[holder] = installed[holder] or {}
        if installed[holder][key] == holder[key] then return end
        local original = holder[key]
        local wrapper = function(...) return Pool.call(environment(), original, ...) end
        holder[key], installed[holder][key] = wrapper, wrapper
    end
    wrap(_G, 'get_current_pool')
    -- SMODS may generate a direct object pool without get_current_pool.
    if SMODS then wrap(SMODS, 'poll_object') end
end
return Pool

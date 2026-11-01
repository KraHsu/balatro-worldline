-- Track the native repeating card pulse without changing its scheduling or
-- callback. Nonblocking flags alone do not prove that an event is cosmetic.
local Policy = {}
local installed, pulse_depth = false, 0
local unpack_values = unpack or table.unpack
local function pack(...) return {n = select('#', ...), ...} end

local function pulse_shape(event)
    return type(event) == 'table' and event.trigger == 'after' and event.timer == 'REAL'
        and event.blocking == false and event.blockable == false
end

function Policy.is_visual(event)
    return pulse_shape(event) and event._worldline_visual == 'juice_card_until'
end

function Policy.install()
    if installed or type(juice_card_until) ~= 'function'
        or type(EventManager) ~= 'table' or type(EventManager.add_event) ~= 'function' then return false end
    local native_pulse, native_add = juice_card_until, EventManager.add_event
    EventManager.add_event = function(self, event, ...)
        if pulse_depth > 0 and pulse_shape(event) then event._worldline_visual = 'juice_card_until' end
        return native_add(self, event, ...)
    end
    juice_card_until = function(...)
        pulse_depth = pulse_depth + 1
        local result = pack(pcall(native_pulse, ...))
        pulse_depth = pulse_depth - 1
        if not result[1] then error(result[2], 0) end
        return unpack_values(result, 2, result.n)
    end
    installed = true
    return true
end

return Policy

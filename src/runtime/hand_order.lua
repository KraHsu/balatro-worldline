-- Native RNG consumers turn pairs(G.GAME.hands) into candidate arrays.
-- Preserve the observed enumeration after restore; all other tables retain
-- native pairs behavior. A weak registry does not retain abandoned games.
local HandOrder={}
local native_pairs=pairs
local orders=setmetatable({},{__mode='k'})
local installed=false
function HandOrder.pairs(value)
    local order=orders[value]
    if not order then return native_pairs(value) end
    local index=0
    return function()
        index=index+1
        local key=order[index]
        if key~=nil then return key,value[key] end
    end,value,nil
end
function HandOrder.install()
    if installed then return end
    installed=true;pairs=HandOrder.pairs
end
function HandOrder.capture(hands)
    if type(hands)~='table' then return nil end
    local order={}
    for key in HandOrder.pairs(hands) do order[#order+1]=key end
    return order
end
function HandOrder.validate(order,hands)
    if order==nil then return true end
    if type(order)~='table' or type(hands)~='table' or #order>64 then return false end
    local seen,count={},0
    for index,key in native_pairs(order) do
        if type(index)~='number' or index<1 or index%1~=0 or index>#order
            or type(key)~='string' or hands[key]==nil or seen[key] then return false end
        seen[key]=true;count=count+1
    end
    for key in native_pairs(hands) do if not seen[key] then return false end end
    return count==#order
end
function HandOrder.bind(hands,order)
    if order==nil then return end -- Historical recordings did not retain this information.
    assert(HandOrder.validate(order,hands),'Invalid recorded poker-hand order')
    local saved={}
    for index,key in ipairs(order) do saved[index]=key end
    orders[hands]=saved
end
return HandOrder

local Pool = dofile('src/domain/pool_environment.lua')
G = {P_CENTERS = {
    j_locked = {unlocked=false,discovered=false}, j_open={unlocked=true,discovered=true},
    e_foil={unlocked=true,discovered=false}, missing={}
}, GAME={seeded=false,pseudorandom={seed='POOLTEST',state=0.25}}}
local root = Pool.capture(G.P_CENTERS)
assert(Pool.validate(root))
assert(root.centers.j_locked == 4 and root.centers.j_open == 8 and root.centers.missing == 0)
G.P_CENTERS.j_locked.unlocked, G.P_CENTERS.e_foil.discovered = true, true
local function native_pool()
    return G.P_CENTERS.j_locked.unlocked, G.P_CENTERS.e_foil.discovered, nil,
        G.P_CENTERS.missing.unlocked, G.GAME.pseudorandom.state
end
local a,b,c,d,e = Pool.call(root,native_pool)
assert(a == false and b == false and c == nil and d == nil and e == 0.25)
assert(G.P_CENTERS.j_locked.unlocked == true and G.P_CENTERS.e_foil.discovered == true)
assert(G.GAME.seeded == false and G.GAME.pseudorandom.state == 0.25)
-- Reentrant pool helpers see one environment; the real profile is restored
-- after success, nil returns, native error objects and nested failures.
local marker = {}
local ok,err=pcall(function() Pool.call(root,function()
    assert(G.P_CENTERS.j_locked.unlocked == false)
    Pool.call(root,function() error(marker) end)
end) end)
assert(not ok and err == marker and G.P_CENTERS.j_locked.unlocked == true)
assert(Pool.call(root,function() return nil,'second',nil,'fourth' end) == nil)
local captured = {Pool.call(root,function() return nil,'second',nil,'fourth' end)}
assert(captured[2]=='second' and captured[4]=='fourth')
assert(Pool.call(nil,native_pool) == true, 'legacy/no-worldline uses native profile')
-- Profile/table replacement does not use old prototype references.
G.P_CENTERS={j_locked={unlocked=true},e_foil={discovered=true},missing={}}
assert(Pool.call(root,native_pool) == false)
assert(G.P_CENTERS.j_locked.unlocked == true)
assert(not Pool.validate({schema=1,centers={bad=9}}))
assert(not Pool.validate({schema=1,centers={bad=0/0}}))
assert(not Pool.validate({schema=1,centers={bad='true'}}))
local active=root
get_current_pool=native_pool
SMODS={poll_object=function() return get_current_pool() end,
    poll_object_type=function() return SMODS.poll_object() end}
Pool.install(function() return active end)
local wrapped=get_current_pool
Pool.install(function() error('install should be idempotent') end)
assert(wrapped == get_current_pool and SMODS.poll_object_type() == false)
active=nil
assert(SMODS.poll_object_type() == true)
assert(G.P_CENTERS.j_locked.unlocked == true and G.P_CENTERS.e_foil.discovered == true)
print('PASS pool environment: root profile eligibility, native calls, nested errors, exact flags, live profile isolation')

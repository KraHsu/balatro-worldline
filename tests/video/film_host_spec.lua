local Host=dofile('src/video/host.lua')
local original_game,tree={},{}
G={GAME=original_game,FPS_CAP=30}
local messages,requests={},{}
local function channel(rows) return {
    push=function(_,value) rows[#rows+1]=value end,
    pop=function()return table.remove(rows,1)end,
    clear=function()for k in pairs(rows)do rows[k]=nil end end} end
local results={}
local ctx={tree=tree,busy=true}
local host=Host.new(ctx,function(ok,why,path,cancelled)results[#results+1]={ok,why,path,cancelled}end)
host.active,host.phase,host.old_fps,host.output=true,'starting',500,'C:/videos/a.mp4'
host.progress=0
host.requests,host.responses=channel(requests),channel(messages)
host.thread={getError=function()end}
messages[1]={phase='rendering',progress=0.4,completed=2}
host:before_update()
assert(host.active and ctx.busy and host.completed==2 and host.progress==0.4)
assert(G.GAME==original_game and ctx.tree==tree,'Progress cannot load snapshots into the visible game')
host:cancel();host:cancel()
assert(#requests==1 and requests[1].kind=='cancel' and host.active and ctx.busy,
    'Cancel keeps the progress modal alive until the worker acknowledges')
messages[1]={phase='rendering',progress=0.5}
host:update();assert(host.phase=='cancelling')
messages[1]={phase='cancelled'}
host:update()
assert(not host.active and not ctx.busy and G.FPS_CAP==500 and results[1][4])
assert(#requests==0 and G.GAME==original_game and ctx.tree==tree)
host.active,ctx.busy,host.phase,host.old_fps=true,true,'rendering',144
host.cancelled=nil
host:fail('renderer failed')
messages[1]={phase='cancelled'}
host:update()
assert(not results[2][1] and results[2][2]=='renderer failed' and not results[2][4],
    'A failed export must not be reported as a user cancellation')
assert(G.FPS_CAP==144)
print('PASS video host: live game isolation, progress, acknowledged cancellation, errors and frame-cap recovery')

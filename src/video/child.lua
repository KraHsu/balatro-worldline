local Loader
if SMODS and SMODS.load_file then
    Loader = assert(SMODS.load_file('loader.lua', 'WorldLine'))()
else
    Loader = dofile('src/loader.lua')
end
-- Entry point used only by the copied offline executable on its own desktop.
local Child={}
function Child.install(root)
    assert(os.getenv('WORLDLINE_RENDER_JOB')==root and not G.STEAM,'Invalid renderer launch')
    local module = Loader.load
    local Codec,Film,Runtime,W=module('codec'),module('film'),module('film_runtime'),module('film_windows')
    local job=assert(Codec.decode(assert(W.read(root..'/job.json')),JSON))
    assert(love.filesystem.getIdentity()==job.identity,'Renderer save identity escaped isolation')
    assert(love.filesystem.getSaveDirectory():gsub('\\','/'):sub(1,#root+9)==root..'/appdata/','Renderer save path escaped isolation')
    local api,snapshot=WORLDLINE,WORLDLINE.snapshot
    G.PROFILES=job.profiles
    for name,group in pairs(job.flags) do for id,flags in pairs(group) do
        local p=G[name] and G[name][id]
        if p then p.unlocked,p.discovered,p.alerted=flags.unlocked,flags.discovered,flags.alerted end
    end end
    -- Output timing comes from Runtime's fixed simulation dt. Let the private
    -- renderer work faster than playback while retaining a bounded loop rate.
    G.SETTINGS.language=job.language;G.FPS_CAP=240
    local height=job.plan.options.height or 720
    love.window.setMode(height*16/9,height,{resizable=false,vsync=0})
    api.tree={metadata={pool_environment=job.pool}}
    api.busy,api.restoring=true,true
    local finish_at,last_write,final_status
    local function write(status)
        W.write(root..'/status.json',JSON.encode(status))
    end
    local boot={active=true,phase='loading',before_update=function()return true end,capture=function()end}
    function boot:fail(err)
        self.active=false;final_status={phase='error',error=tostring(err)}
        write(final_status);finish_at=love.timer.getTime()+0.3
    end
    function boot:cancel() self:fail('Export cancelled') end
    function boot:update()
        local done,err=snapshot.update()
        if err then return self:fail(err) end
        if not done then return end
        api.game_ref=G.GAME
        local worker=Loader.source('film_worker')
        local runtime=Runtime.new(api,Film,snapshot,worker,function(ok,reason,output,cancelled)
            final_status={phase=ok and 'done' or cancelled and 'cancelled' or 'error',progress=ok and 1 or 0,
                error=reason,output=output}
            finish_at=love.timer.getTime()+0.3;write(final_status)
            api.film_runtime={active=true,before_update=function()return false end,update=function()end,
                capture=function()end,cancel=function()end,fail=function()end}
        end)
        job.plan.output=job.output
        runtime:start(job.plan);api.film_runtime=runtime
    end
    api.film_runtime=boot
    assert(snapshot.restore(job.plan.start))
    local native_update=love.update
    love.update=function(dt,...)
        local ok,err=pcall(native_update,dt,...)
        if not ok then api.film_runtime:fail(err) end
        local runtime=api.film_runtime
        if W.attributes(root..'/cancel') and runtime.active then runtime:cancel() end
        local now=love.timer.getTime()
        if not final_status and (not last_write or now-last_write>=0.15) then
            last_write=now
            local completed=0
            for i=1,(runtime.edge or 1)-1 do completed=completed+#job.plan.edges[i].steps end
            completed=math.min(job.plan.total,completed+math.max(0,(runtime.step or 1)-1))
            local encoding=runtime.phase=='returning' or runtime.phase=='encoding'
            write{phase=encoding and 'encoding' or 'rendering',completed=completed,
                progress=encoding and 0.92 or 0.1+0.8*(completed/math.max(1,job.plan.total)),
                video_seconds=(runtime.sent or 0)/job.plan.options.fps}
        end
        if finish_at and now>=finish_at then love.event.quit() end
    end
    -- This process has no live player history and no external profile to save.
    love.quit=function() return false end
end
return Child

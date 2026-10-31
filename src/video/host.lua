local Loader
if SMODS and SMODS.load_file then
    Loader = assert(SMODS.load_file('loader.lua', 'WorldLine'))()
else
    Loader = dofile('src/loader.lua')
end
-- The visible game never loads replay snapshots. One private process owns them.
local Host={};Host.__index=Host
function Host.new(ctx,finished)
    return setmetatable({ctx=ctx,finished=finished,background=true},Host)
end
function Host:start(plan,mod)
    assert(love.system.getOS()=='Windows','Background video export is currently supported on Windows')
    local read = Loader.source
    local Files=assert(loadstring(read('film_files')))()
    local base=love.filesystem.getSaveDirectory():gsub('\\','/')
    local key=os.date('!%Y%m%dT%H%M%SZ')..'_'..math.floor(love.timer.getTime()*1000)
    local output_dir=plan.options.output_dir~='' and plan.options.output_dir or base..'/WorldLine/recordings'
    local root=base..'/WorldLine/render-jobs/'..key
    local sources={windows=read('film_windows'),zip=read('film_zip'),codec=read('codec'),
        json=assert(SMODS.NFS.read(SMODS.path..'libs/json/json.lua'))}
    local in_name,out_name='WorldLine.export.in.'..key,'WorldLine.export.out.'..key
    self.requests,self.responses=love.thread.getChannel(in_name),love.thread.getChannel(out_name)
    self.requests:clear();self.responses:clear()
    self.thread=love.thread.newThread(read('film_prepare'))
    self.collector=Files.new(SMODS.NFS,{
        {kind='mod',root=mod.path:gsub('/+$',''),relative=''},
        {kind='smods',root=SMODS.path:gsub('/+$',''),relative=''}})
    self.collect_step=Files.step
    self.output=output_dir..(output_dir:sub(-1)=='/' and '' or '/')..'WorldLine_'..key..'.mp4'
    self.total,self.completed,self.progress=plan.total,0,0
    self.active,self.phase=true,'preparing'
    self.old_fps=G.FPS_CAP;G.FPS_CAP=math.min(G.FPS_CAP or 30,30)
    self.ctx.busy=true
    local flags={}
    for _,name in ipairs({'P_CENTERS','P_BLINDS','P_TAGS','P_SEALS','P_STAKES'}) do
        flags[name]={}
        for id,p in pairs(G[name] or {}) do flags[name][id]={unlocked=p.unlocked,discovered=p.discovered,alerted=p.alerted} end
    end
    self.job={root=root,key=key,identity='WorldLineRender_'..key,
        game=(self.ctx.film_source or love.filesystem.getSource()):gsub('\\','/'),
        mod=mod.path:gsub('\\','/'):gsub('/+$',''),smods=SMODS.path:gsub('\\','/'):gsub('/+$',''),
        sources=sources,plan=plan,output=self.output,output_dir=output_dir,profiles=G.PROFILES,
        pool=self.ctx.tree and self.ctx.tree.metadata.pool_environment,flags=flags,language=G.SETTINGS.language}
    self.input_name,self.output_name=in_name,out_name
    return self.output
end
function Host:cancel()
    if self.active and not self.cancelled then
        self.cancelled=true;self.phase='cancelling'
        if self.collector then self.collector=nil;self.job=nil;self:complete(false)
        else self.requests:push{kind='cancel'} end
    end
end
function Host:complete(success,reason)
    if not self.active then return end
    self.active=false;self.ctx.busy=false;G.FPS_CAP=self.old_fps
    self.collector,self.job=nil,nil
    self.requests:clear();self.responses:clear()
    self.finished(success,reason,self.output,not self.error and (self.cancelled or self.phase=='cancelled'))
end
function Host:fail(reason)
    self.error=tostring(reason);self.phase='cancelling'
    if self.collector then self:complete(false,self.error);return end
    if self.active then self.requests:push{kind='cancel'} end
end
function Host:update()
    if self.collector then
        local started=love.timer.getTime()
        repeat
            local ok,done,files=pcall(self.collect_step,self.collector,4)
            if not ok then self.error=tostring(done);self:complete(false,self.error);return end
            if done then
                self.job.files=files
                self.requests:push(self.job)
                self.collector,self.job=nil,nil
                local launched,err=pcall(self.thread.start,self.thread,self.input_name,self.output_name)
                if not launched then self:complete(false,err);return end
                break
            end
        until love.timer.getTime()-started>=0.004
        return
    end
    while self.active do
        local message=self.responses:pop();if not message then break end
        if not self.cancelled then self.phase=message.phase or self.phase end
        self.progress=math.max(self.progress,tonumber(message.progress) or 0)
        self.completed=message.completed or self.completed
        self.video_seconds=message.video_seconds or self.video_seconds
        if message.phase=='done' then self:complete(true)
        elseif message.phase=='error' then self:complete(false,message.error)
        elseif message.phase=='cancelled' then self:complete(false,self.error) end
    end
    if self.active and self.thread:getError() then self:complete(false,self.thread:getError()) end
end
function Host:before_update() self:update();return true end
function Host:capture() end
return Host

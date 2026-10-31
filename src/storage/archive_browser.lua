-- On-demand, read-only archive metadata loading. The game thread only stats
-- files and receives compact rows; gameplay snapshots are decoded in a worker.
local Browser = {}
Browser.__index = Browser
local kinds = {archives=true,backups=true}

local function copy(value)
    if type(value)~='table' then return value end
    local out={};for k,v in pairs(value) do out[k]=copy(v) end;return out
end

function Browser.signature(fs,kind)
    assert(kinds[kind],'Invalid archive browser kind')
    local path='WorldLine/'..(kind=='archives' and 'trees' or 'backups')
    local parts={}
    for _,name in ipairs(fs.getDirectoryItems(path) or {}) do
        local accepted=kind=='archives' and (name:match('^[%w_-]+%.[ab]%.json$') or name:match('^[%w_-]+%.deleted%.json$'))
            or kind=='backups' and name:match('^[%w_-]+%.worldline%.json$')
        if accepted then
            local info=fs.getInfo(path..'/'..name)
            parts[#parts+1]=name..':'..(info and (tostring(info.type)..':'..tostring(info.size)..':'..tostring(info.modtime)) or 'missing')
        end
    end
    table.sort(parts);return table.concat(parts,'|')
end

function Browser.new(options)
    assert(type(options)=='table' and options.fs and options.thread,'Archive browser requires filesystem and thread APIs')
    return setmetatable({options=options,serial=0,revision=0,entries={
        archives={epoch=0},backups={epoch=0}}},Browser)
end

function Browser:_start()
    if self.worker then return true end
    local options=self.options
    local ok,value=pcall(function()
        assert(type(options.source)=='string' and type(options.protocol_source)=='string'
            and type(options.modules)=='table' and type(options.json_source)=='string','Missing archive browser worker source')
        local input,output=options.thread.newChannel(),options.thread.newChannel()
        local thread=options.thread.newThread(options.source)
        thread:start(input,output,{modules=options.modules,json_source=options.json_source,protocol_source=options.protocol_source})
        return {input=input,output=output,thread=thread}
    end)
    if not ok then return nil,tostring(value) end
    self.worker=value;return true
end

function Browser:_dispatch(kind)
    if self.pending then return end
    local entry=self.entries[kind]
    if not entry.loading then return end
    local ok,signature=pcall(Browser.signature,self.options.fs,kind)
    if not ok then entry.error=tostring(signature);entry.loading=false;return end
    entry.signature=signature
    local ready,err=self:_start()
    if not ready then entry.error=err;entry.loading=false;return end
    self.serial=self.serial+1
    local pending={kind=kind,serial=self.serial,epoch=entry.epoch,signature=signature}
    self.pending=pending
    local sent,send_err=pcall(self.worker.input.push,self.worker.input,pending)
    if not sent then
        self.pending=nil;entry.error=tostring(send_err);entry.loading=false
    end
end

function Browser:_receive()
    local pending,worker=self.pending,self.worker
    if not pending or not worker then return end
    local message=worker.output:pop()
    if not message then
        local err=worker.thread:getError()
        if err or not worker.thread:isRunning() then
            local entry=self.entries[pending.kind]
            entry.error=tostring(err or 'Archive browser stopped');entry.loading=false
            self.pending,self.worker=nil,nil
        end
        return
    end
    self.pending=nil
    local entry=self.entries[pending.kind]
    if message.serial~=pending.serial or message.kind~=pending.kind then
        entry.error='Unexpected archive browser response';entry.loading=false;return
    end
    -- Invalidation during a scan must not reintroduce deleted/renamed records.
    if entry.epoch~=pending.epoch then return end
    if message.stale then entry.loading=true;return end
    if not message.ok then entry.error=tostring(message.error or 'Cannot read worldline archives');entry.loading=false;return end
    local ok,current=pcall(Browser.signature,self.options.fs,pending.kind)
    if not ok then entry.error=tostring(current);entry.loading=false;return end
    if current~=pending.signature or message.signature~=pending.signature then entry.loading=true;return end
    if type(message.rows)~='table' then entry.error='Invalid archive browser rows';entry.loading=false;return end
    entry.rows,entry.signature,entry.valid,entry.error,entry.loading=message.rows,current,true,nil,false
    self.revision=self.revision+1
end

-- Call request only for an explicit browser action, not from every update.
function Browser:request(kind)
    assert(kinds[kind],'Invalid archive browser kind')
    self:_receive()
    local entry=self.entries[kind]
    local ok,signature=pcall(Browser.signature,self.options.fs,kind)
    if not ok then entry.error=tostring(signature);entry.loading=false;return nil,entry.error end
    if not entry.valid or entry.error or signature~=entry.signature then
        if signature~=entry.signature then entry.epoch=entry.epoch+1 end
        entry.signature,entry.loading,entry.error,entry.valid=signature,true,nil,false
    end
    self:_dispatch(kind)
    return self:poll(kind)
end

-- While loading, poll only consumes messages and observes worker health. File
-- metadata is checked once when dispatching/accepting a result, never every frame.
function Browser:poll(kind)
    assert(kinds[kind],'Invalid archive browser kind')
    self:_receive()
    local entry=self.entries[kind]
    if not entry.valid and not entry.error then entry.loading=true end
    self:_dispatch(kind)
    if entry.loading then return nil,'loading' end
    if entry.error then return nil,entry.error end
    if not entry.valid then return nil,'loading' end
    return copy(entry.rows)
end

function Browser:invalidate(kind)
    assert(kind==nil or kinds[kind],'Invalid archive browser kind')
    for name,entry in pairs(self.entries) do
        if kind==nil or name==kind then
            entry.epoch,entry.valid,entry.error=entry.epoch+1,false,nil
            -- Do not start a scan in the background merely because gameplay saved.
            if self.pending and self.pending.kind==name then entry.loading=true end
        end
    end
end

function Browser:last_rows(kind)
    assert(kinds[kind],'Invalid archive browser kind')
    return copy(self.entries[kind].rows)
end

function Browser:stop()
    if self.worker then pcall(self.worker.input.push,self.worker.input,{stop=true}) end
    self.worker,self.pending=nil,nil
    for _,entry in pairs(self.entries) do entry.loading=false end
end

return Browser

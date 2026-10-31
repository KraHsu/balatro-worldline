local Browser=dofile('src/storage/archive_browser.lua')
local files={['WorldLine/trees/a.a.json']='first'}
local stat_calls,reads=0,0
local fs={}
function fs.getDirectoryItems(path)
    local out={};for key in pairs(files) do if key:sub(1,#path+1)==path..'/' then out[#out+1]=key:sub(#path+2) end end
    return out
end
function fs.getInfo(path) stat_calls=stat_calls+1;if files[path] then return {type='file',size=#files[path],modtime=1} end end
function fs.read() reads=reads+1;error('Main browser must not read gameplay JSON') end
local function channel()
    local result={queue={}}
    function result:push(v) self.queue[#self.queue+1]=v end
    function result:pop() return table.remove(self.queue,1) end
    function result:demand() return assert(self:pop(),'Empty test channel') end
    return result
end
local fake_thread,starts={},0
function fake_thread.newChannel() return channel() end
function fake_thread.newThread()
    local thread={running=true}
    function thread:start(input,output,config) starts=starts+1;self.input,self.output,self.config=input,output,config end
    function thread:getError() return self.error end
    function thread:isRunning() return self.running end
    return thread
end
local browser=Browser.new{fs=fs,thread=fake_thread,source='trusted worker',protocol_source='trusted protocol',modules={},json_source='trusted json'}
local function respond(rows,extra)
    local pending=assert(browser.pending)
    local message={serial=pending.serial,kind=pending.kind,signature=pending.signature,ok=true,rows=rows}
    for key,value in pairs(extra or {}) do message[key]=value end
    browser.worker.output:push(message)
end
local rows,err=browser:request('archives')
assert(rows==nil and err=='loading' and starts==1 and reads==0)
local before=stat_calls
for i=1,30 do rows,err=browser:poll('archives');assert(not rows and err=='loading') end
assert(stat_calls==before,'waiting frames do not rescan file metadata')
respond({{id='a',name='First',summary={dollars=4}}})
rows=assert(browser:poll('archives'));assert(rows[1].name=='First')
rows[1].name='UI edit';rows[1].summary.dollars=99
rows=assert(browser:request('archives'));assert(rows[1].name=='First' and rows[1].summary.dollars==4 and starts==1)
assert(reads==0 and not browser.pending)
files['WorldLine/trees/a.b.json']='second'
assert(select(2,browser:request('archives'))=='loading')
browser:invalidate('archives')
respond({{id='a',name='Stale'}})
rows,err=browser:poll('archives')
assert(rows==nil and err=='loading' and browser.pending,'invalidated scan cannot publish obsolete data')
respond({{id='a',name='Fresh'}})
assert(browser:poll('archives')[1].name=='Fresh')
browser:invalidate('archives')
assert(select(2,browser:request('archives'))=='loading')
files['WorldLine/trees/a.deleted.json']='marker'
respond({{id='a',name='Deleted while reading'}})
assert(select(2,browser:poll('archives'))=='loading','a stat change after worker completion rejects its result')
respond({})
assert(#browser:poll('archives')==0)
assert(select(2,browser:request('backups'))=='loading')
browser:invalidate('archives')
assert(select(2,browser:request('archives'))=='loading')
assert(browser.pending.kind=='backups' and starts==1,'both kinds share one serialized worker')
respond({{id='backup',label='Backup'}})
assert(select(2,browser:poll('archives'))=='loading' and browser.pending.kind=='archives')
respond({{id='a',name='Latest'}})
assert(browser:poll('archives')[1].name=='Latest' and browser:poll('backups')[1].label=='Backup')
browser:invalidate()
assert(select(2,browser:request('archives'))=='loading')
browser.worker.thread.error='reader failed'
rows,err=browser:poll('archives');assert(not rows and err=='reader failed')
assert(browser:last_rows('archives')[1].name=='Latest','failed refresh preserves the last good display data')
assert(select(2,browser:request('archives'))=='loading' and starts==2,'explicit retry restarts a failed worker')
local old=browser.worker
browser:stop()
assert(old.input.queue[#old.input.queue].stop and browser.pending==nil and browser.worker==nil)

-- Execute the actual worker source under a deterministic read-only filesystem.
-- This checks JSON validation and compaction, not just the controller protocol.
do
    local Tree=dofile('src/domain/tree.lua')
    local Codec=dofile('src/storage/codec.lua')
    local Storage=dofile('src/storage/repository.lua')
    local data={}
    local memory={}
    function memory.getDirectoryItems(path)
        local out={};for key in pairs(data) do if key:sub(1,#path+1)==path..'/' then out[#out+1]=key:sub(#path+2) end end
        return out
    end
    function memory.getInfo(path) if data[path] then return {type='file',size=#data[path],modtime=1} end end
    function memory.read(path) return data[path] end
    function memory.write(path,value) data[path]=value;return true end
    function memory.createDirectory() return true end
    local tree=Tree.new({seed='FIXED',save={GAME={dollars=4}}},{run_id='safe',seed='FIXED'})
    tree:get(tree.current).summary={deck='b_red',stake=3,dollars=4,jokers={{key='j_joker'}},snapshot='must not cross channel'}
    local store=Storage.new(Codec,Tree,TEST_JSON,memory)
    assert(store:save(tree));local backup=assert(store:backup(tree,'manual'))
    data['WorldLine/trees/unsafe.a.json']='return os.execute("not JSON")'
    local readonly={getDirectoryItems=memory.getDirectoryItems,getInfo=memory.getInfo,read=memory.read}
    local function read_file(path) local f=assert(io.open(path,'rb'));local value=f:read('*a');f:close();return value end
    local config={modules={codec=read_file('src/storage/codec.lua'),tree=read_file('src/domain/tree.lua'),
        storage=read_file('src/storage/repository.lua')},protocol_source=read_file('src/storage/archive_browser.lua'),json_source='return TEST_JSON'}
    local input,output=channel(),channel()
    input:push{serial=1,kind='archives',signature=Browser.signature(readonly,'archives')}
    input:push{serial=2,kind='backups',signature=Browser.signature(readonly,'backups')}
    input:push{serial=3,kind='archives',signature='stale signature'}
    input:push{stop=true}
    local env=setmetatable({love={filesystem=readonly},TEST_JSON=TEST_JSON,require=function(name) assert(name=='love.filesystem') end},{__index=_G})
    env.loadstring=function(text,name) local f,err=loadstring(text,name);if f then setfenv(f,env) end;return f,err end
    local worker=assert(loadstring(read_file('src/workers/archive_browser.lua'),'@worker-test'))
    setfenv(worker,env);worker(input,output,config)
    local archive_result=assert(output:pop());local backup_result=assert(output:pop());local stale=assert(output:pop())
    assert(archive_result.ok and #archive_result.rows==1 and archive_result.rows[1].id=='safe')
    assert(archive_result.rows[1].summary.stake==3 and archive_result.rows[1].summary.jokers==nil
        and archive_result.rows[1].summary.snapshot==nil,'only compact presentation metadata crosses the worker boundary')
    assert(backup_result.ok and backup_result.rows[1].id==backup.id and backup_result.rows[1].summary.dollars==4)
    assert(stale.stale and not stale.rows,'mismatched initial filesystem signature is never decoded/published')
end
print('PASS archive browser: nonblocking requests, stale-result rejection, compact read-only worker, retries and shutdown')
return true

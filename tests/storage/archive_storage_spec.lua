-- Archive editing uses only a private in-memory filesystem. Never user saves.
local Tree = dofile('src/domain/tree.lua')
local Codec = dofile('src/storage/codec.lua')
local Storage = dofile('src/storage/repository.lua')
local original_time = os.time
os.time = function() return 123456 end
local function snapshot(dollars)
    return {seed='ARCHIVE',save={GAME={dollars=dollars,pseudorandom={seed='ARCHIVE',shop=0.25}}}}
end
local function fixture(id)
    local files, events, faults = {}, {}, {}
    local fs = {}
    function fs.createDirectory() return true end
    function fs.getInfo(path) return files[path] and {type='file',size=#files[path]} end
    function fs.read(path)
        if faults.corrupt_read and path:find(faults.corrupt_read,1,true) then return 'damaged' end
        return files[path]
    end
    function fs.write(path,data)
        events[#events+1]='write:'..path
        if faults.write and path:find(faults.write,1,true) then
            files[path]=data:sub(1,10)
            return nil,'disk full'
        end
        files[path]=data
        return true
    end
    function fs.remove(path)
        events[#events+1]='remove:'..path
        if faults.remove and path:find(faults.remove,1,true) then return nil,'permission denied' end
        files[path]=nil
        return true
    end
    function fs.getDirectoryItems(path)
        local result={}
        for file in pairs(files) do
            if file:sub(1,#path+1)==path..'/' then result[#result+1]=file:sub(#path+2) end
        end
        return result
    end
    local tree=Tree.new(snapshot(4),{seed='ARCHIVE',run_id=id or 'to_delete',name='Shop experiment'})
    tree:commit({kind='buy'},snapshot(0),{money=0})
    tree.resume={parent=tree.current,snapshot=snapshot(2),summary={money=2},choices={{kind='sell'}}}
    local store=Storage.new(Codec,Tree,TEST_JSON,fs)
    assert(store:save(tree));assert(store:save(tree))
    return store,tree,files,events,faults
end

local store,tree,files,events,faults=fixture()
local a,b=files['WorldLine/trees/to_delete.a.json'],files['WorldLine/trees/to_delete.b.json']
local original=Codec.encode(tree:export(),TEST_JSON)
local receipt=assert(store:backup(tree,'branch'))
assert(receipt.reason=='branch' and receipt.label=='Shop experiment' and receipt.node_count==2)
assert(receipt.source_id=='to_delete' and receipt.path=='WorldLine/backups/'..receipt.id..'.worldline.json')
local backed,info=assert(store:load_backup(receipt.id))
assert(info.id==receipt.id and Codec.encode(backed:export(),TEST_JSON)==original)
assert(files['WorldLine/trees/to_delete.a.json']==a and files['WorldLine/trees/to_delete.b.json']==b)
assert(Codec.encode(tree:export(),TEST_JSON)==original, 'backup cannot alter the source archive or live object')
local second=assert(store:backup(tree,'rename'))
assert(second.id~=receipt.id and files[receipt.path], 'same-second backup names never overwrite')
local restarted=Storage.new(Codec,Tree,TEST_JSON,store.fs)
local third=assert(restarted:backup(tree,'manual'))
assert(third.id~=receipt.id and third.id~=second.id and files[receipt.path] and files[second.path],
    'a restarted storage owner checks existing names before writing a new backup')
assert(#store:backups()==3 and store:archives()[1].name=='Shop experiment')
assert(store:archives()[1].label:find('Shop experiment',1,true))
assert(not store:backup(tree,'unrecognized') and not store:load_backup('../bad'))

-- A verified backup is required before either generation can be removed.
faults.write='/backups/'
assert(not store:delete_archive(tree))
assert(files['WorldLine/trees/to_delete.a.json']==a and files['WorldLine/trees/to_delete.b.json']==b)
assert(store:load('to_delete') and not store:is_deleted('to_delete'))
faults.write=nil;faults.corrupt_read='/backups/'
assert(not store:delete_archive(tree))
assert(files['WorldLine/trees/to_delete.a.json']==a and files['WorldLine/trees/to_delete.b.json']==b)
faults.corrupt_read=nil
faults.write='.deleted.json'
assert(not store:delete_archive(tree))
assert(not store:is_deleted('to_delete') and store:load('to_delete'))
assert(files['WorldLine/trees/to_delete.a.json']==a and files['WorldLine/trees/to_delete.b.json']==b)
faults.write=nil

-- Exported files are independent shares, not the local archive being deleted.
local exported=assert(store:export(tree));local exported_text=files[exported]
files['WorldLine/imports/received.worldline.json']=exported_text
faults.remove='.b.json'
local deletion=assert(store:delete_archive(tree))
assert(deletion.reason=='archive' and deletion.cleanup_warning)
assert(not files['WorldLine/trees/to_delete.a.json'] and files['WorldLine/trees/to_delete.b.json']==b)
assert(store:is_deleted('to_delete') and not store:load('to_delete') and #store:archives()==0)
assert(not store:save(tree) and not store:start_save(tree,999), 'stale owners cannot recreate a deleted archive')
assert(files[exported]==exported_text and files['WorldLine/imports/received.worldline.json']==exported_text)
local recovered=assert(store:load_backup(deletion.id))
assert(recovered.resume.snapshot.save.GAME.dollars==2 and recovered.resume.choices[1].kind=='sell')
recovered.metadata.run_id='restored_copy'
faults.remove=nil
assert(store:save(recovered))
assert(store:load('restored_copy') and not store:load('to_delete'))
assert(#store:archives()==1 and store:archives()[1].id=='restored_copy')
-- A stale process putting both files back still cannot override the marker.
files['WorldLine/trees/to_delete.a.json']=a
local reopened=Storage.new(Codec,Tree,TEST_JSON,store.fs)
assert(reopened:is_deleted('to_delete') and not reopened:load('to_delete') and #reopened:archives()==1)

-- Bad marker data and backup path traversal never become valid deletion state.
files['WorldLine/trees/restored_copy.deleted.json']='{"format":"worldline-deleted","schema":1,"source_id":"other","backup_id":"../outside"}'
assert(not reopened:is_deleted('restored_copy') and reopened:load('restored_copy'))
files['WorldLine/backups/bad.worldline.json']=files[receipt.path]
assert(not reopened:load_backup('bad'), 'backup receipt ID must match its filename')
for path in pairs(files) do
    assert(path:sub(1,#'WorldLine/')=='WorldLine/' and not path:find('%.%.'), 'all writes stay in managed directories')
end

-- An unfinished accepted save is settled before deletion, and failure aborts
-- deletion without creating a marker. This uses the real cooperative encoder.
local queued,queued_tree,queued_files,queued_events,queued_faults=fixture('queued')
queued_tree:commit({kind='sell'},snapshot(3),{money=3})
assert(queued:start_save(queued_tree,10))
local queued_deletion=assert(queued:delete_archive(queued_tree))
assert(not queued:busy_save() and queued:is_deleted('queued'))
assert(queued:load_backup(queued_deletion.id).current==3)
local marker_index,save_index
for index,event in ipairs(queued_events) do
    if event=='write:WorldLine/trees/queued.deleted.json' then marker_index=index end
    if event=='write:WorldLine/trees/queued.a.json' then save_index=index end
end
assert(save_index<marker_index, 'no active generation is left behind the deletion commit point')
local blocked,blocked_tree,blocked_files,_,blocked_faults=fixture('blocked')
assert(blocked:start_save(blocked_tree,11))
blocked_faults.write='/trees/'
assert(not blocked:delete_archive(blocked_tree) and not blocked:is_deleted('blocked'))
assert(blocked:load('blocked'), 'failed pending save leaves the previous valid generation usable')
os.time = original_time
print('PASS archive storage: verified backups, safe deletion markers, writer barrier, failure recovery and fresh-ID restore')

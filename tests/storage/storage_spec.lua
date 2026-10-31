local Tree = dofile("src/domain/tree.lua")
local Codec = dofile("src/storage/codec.lua")
local Storage = dofile("src/storage/repository.lua")
local files, fail_write = {}, false
local fs = {}
function fs.createDirectory() return true end
function fs.getInfo(path)
    local data = files[path]
    if data then return {type = "file", size = #data, modtime = 1} end
end
function fs.read(path) return files[path] end
function fs.write(path, data)
    if fail_write then files[path] = data:sub(1, 20); return false, "disk full" end
    files[path] = data
    return true
end
function fs.getDirectoryItems(path)
    local result = {}
    for name in pairs(files) do
        if name:sub(1, #path + 1) == path .. "/" then
            result[#result + 1] = name:sub(#path + 2)
        end
    end
    return result
end
local function snapshot(amount)
    return {schema = 1, seed = "FIXED", save = {GAME = {
        dollars = amount, pseudorandom = {seed = "FIXED", lucky_mult = 0.75}
    }}, extra = {selected = {hand = {[1] = 9, [3] = 11}}}}
end
local tree = Tree.new(snapshot(4), {run_id = "test_run", seed = "FIXED"})
local store = Storage.new(Codec, Tree, TEST_JSON, fs)
assert(store:save(tree))
tree:commit({kind = "buy"}, snapshot(0), {})
assert(store:save(tree))
tree:commit({kind = "sell"}, snapshot(2), {})
fail_write = true
local saved, err = store:save(tree)
assert(not saved and err == "disk full")
local recovered = assert(store:load("test_run"))
assert(recovered.current == 2, "a torn write must preserve the last valid generation")
assert(recovered:peek(2).save.GAME.dollars == 0)
assert(recovered.resume == nil)
fail_write = false
tree.resume = {parent = tree.current, snapshot = snapshot(1),
    summary = {money = 1, jokers = {{key = "j_joker", name = "Joker"}}}}
assert(store:save(tree))
local reopened = Storage.new(Codec, Tree, TEST_JSON, fs)
local continued = assert(reopened:load("test_run"))
assert(continued.current == 3 and continued.next_id == 4)
assert(continued.resume.parent == 3 and continued.resume.snapshot.save.GAME.dollars == 1)
assert(continued:peek(3).save.GAME.dollars == 2, "private resume must not overwrite the public milestone")
local rows = reopened:archives()
assert(#rows == 1 and rows[1].id == "test_run" and rows[1].node_count == 3)
assert(rows[1].has_resume and rows[1].summary.money == 1)
local share_path = assert(store:export(tree))
local imported = assert(store:decode_share(files[share_path]))
assert(imported.current == tree.current)
assert(imported.next_id == tree.next_id and imported.resume.parent == tree.current)
assert(imported.resume.summary.jokers[1].key == "j_joker")
assert(imported.resume.snapshot.save.GAME.dollars == 1, "sharing retains unfinished shopping without a public node")
assert(imported:peek(1).extra.selected.hand[3] == 11, "sparse numeric keys must survive JSON")
assert(not store:decode_share("return os.execute('should never execute')"))
assert(not store:load("../save"))
files["WorldLine/imports/shared.worldline.json"] = files[share_path]
assert(store:import_latest().metadata.seed == "FIXED")
assert(store:import_latest().resume.snapshot.save.GAME.dollars == 1)
assert(share_path == 'WorldLine/exports/test_run.worldline.json', 'branding leaves shared file paths compatible')
local wire = assert(Codec.decode(files[share_path], TEST_JSON))
assert(wire.format == 'worldline' and wire.schema == 1 and wire.kind == 'share',
    'branding leaves archive magic and schema compatible')
local chinese = true
assert(store:set_text(function(zh, en)
    if not chinese then return en end
    return zh or ({['disk full'] = '磁盘已满'})[en] or en
end) == store)
local _, localized_error = store:load('../save')
assert(localized_error == '存档标识无效')
_, localized_error = store:decode_share(false)
assert(localized_error == '世界线文件超过 128 MiB 或不是文本')
_, localized_error = store:decode_share(assert(Codec.encode({format = 'wrong', schema = 1, kind = 'share'}, TEST_JSON)))
assert(localized_error == '无法识别此世界线文件')
fail_write = true
_, localized_error = store:save(tree)
assert(localized_error == '磁盘已满', 'filesystem reasons also pass through the localization callback')
fail_write = false
assert(store:archives()[1].label:find('收束点', 1, true))
chinese = false
_, localized_error = store:load('../save')
assert(localized_error == 'Invalid archive identifier', 'translation is resolved at operation time, not cached')
assert(store:archives()[1].label:find(' points', 1, true))
for path in pairs(files) do
    assert(path:sub(1, #"WorldLine/") == "WorldLine/")
    assert(not path:find("save.jkr", 1, true))
end
-- Storage reads the internal view directly without mutating source snapshots,
-- while a regular public export still owns its own deep copies.
local before = Codec.encode(tree:export(), TEST_JSON)
local public_export = tree.export
tree.export = function() error('Storage must not deep-copy the full worldline before encoding') end
local optimized = assert(store:_encode(tree, 'share'))
tree.export = public_export
assert(Codec.encode(tree:export(), TEST_JSON) == before, 'encoding leaves metadata, nodes and resume unchanged')
local legacy_store = Storage.new(Codec, Tree, TEST_JSON, fs)
local legacy_tree = {metadata = tree.metadata, export = function() return tree:export() end}
local compatible = assert(legacy_store:_encode(legacy_tree, 'share'))
assert(optimized == compatible, 'the read-only view produces the existing wire archive byte-for-byte')
local bad_json = {encode = function() error('simulated serializer failure') end}
local failing = Storage.new(Codec, Tree, bad_json, fs)
assert(not failing:_encode(tree, 'share'))
assert(Codec.encode(tree:export(), TEST_JSON) == before, 'failed serialization never mutates source data')

-- Browsing repeatedly must not deserialize every historical gameplay snapshot.
-- Cache only detached metadata; actual loads retain authoritative validation.
do
    local data, revisions, reads = {}, {}, 0
    local cached_fs = {}
    function cached_fs.createDirectory() return true end
    function cached_fs.getInfo(path)
        if data[path] then return {type='file',size=#data[path],modtime=revisions[path] or 1} end
    end
    function cached_fs.read(path) reads=reads+1; return data[path] end
    function cached_fs.write(path,value) data[path]=value; return true end
    function cached_fs.getDirectoryItems(path)
        local list={}
        for key in pairs(data) do if key:sub(1,#path+1)==path..'/' then list[#list+1]=key:sub(#path+2) end end
        return list
    end
    local writer=Storage.new(Codec,Tree,TEST_JSON,cached_fs)
    local example=Tree.new(snapshot(4),{run_id='cached',seed='FIXED',name='First'})
    example:get(example.current).summary={money=4,jokers={{key='j_joker'}}}
    assert(writer:save(example))
    local browser=Storage.new(Codec,Tree,TEST_JSON,cached_fs)
    local first=browser:archives(); local cold_reads=reads
    assert(cold_reads>0 and first[1].name=='First')
    first[1].name='UI edit';first[1].summary.jokers[1].key='UI edit'
    for i=1,12 do
        local result=browser:archives()
        assert(result[1].name=='First' and result[1].summary.jokers[1].key=='j_joker')
    end
    assert(reads==cold_reads,'unchanged browsing must use small metadata without reading gameplay files')
    assert(browser:load('cached') and reads>cold_reads,'explicit loading still reads and validates the save')
    local path='WorldLine/trees/cached.a.json'
    data[path]=data[path]..' ';revisions[path]=2
    local read_before=reads
    assert(browser:archives()[1].name=='First' and reads>read_before,'external file changes invalidate the metadata')
    assert(browser:save(example))
    assert(example:set_name('Other'))
    assert(browser:save(example)) -- Same-length name, coarse timestamp: own writes still invalidate/update.
    assert(browser:archives()[1].name=='Other')
    assert(example:set_name('Live'))
    read_before=reads
    assert(browser:archives({cached=example})[1].name=='Live' and reads==read_before,
        'live current progress does not reload its own complete history')
    assert(browser:archives()[1].name=='Other','live preview must not poison the disk metadata cache')
    data[path]=nil;data['WorldLine/trees/cached.b.json']=nil
    assert(#browser:archives()==0 and next(browser.archive_cache)==nil,'removed archives evict cached rows')
end
print("PASS storage: two-generation recovery, private resume, sharing, sparse keys, path isolation")

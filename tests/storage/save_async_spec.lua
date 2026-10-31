local Tree = dofile('src/domain/tree.lua')
local Codec = dofile('src/storage/codec.lua')
local Storage = dofile('src/storage/repository.lua')
local function same(a, b)
    assert(type(a) == type(b), 'different value types')
    if type(a) ~= 'table' then assert(a == b); return end
    for key, value in pairs(a) do same(value, b[key]) end
    for key in pairs(b) do assert(a[key] ~= nil) end
end
local function encode(value)
    local task, steps = Codec.new_encoder(value, TEST_JSON), 0
    while true do
        local state, result = task:step(0)
        steps = steps + 1
        assert(steps < 100000, 'encoder must terminate')
        if state ~= false then
            if not state then return nil, result end
            local text = table.concat(result.chunks)
            assert(#text == result.size)
            return text, steps
        end
    end
end
local tricky = {seed = 0.30072781822578326, sparse = {[false] = 'false', [3] = 'three', ['3'] = 3},
    text = '\0\1\31\b\f\r\n\t"\\世界线', zero = {0, -1 / math.huge}, many = {}}
for i = 1, 700 do tricky.many[i] = {name = 'same', values = {i, 2, 3}, repeated = {1, 2}} end
local text, steps = assert(encode(tricky))
assert(steps > 100, 'encoding and JSON construction must yield throughout the work')
same(tricky, assert(Codec.decode(text, TEST_JSON)))
local wire = TEST_JSON.decode(text)
local legacy = TEST_JSON.decode(Codec.encode(tricky, TEST_JSON))
same(wire, legacy) -- Field order may differ; dictionary tags/IDs stay identical.
local decoded = assert(Codec.decode(text, TEST_JSON))
assert(1 / decoded.zero[1] == math.huge and 1 / decoded.zero[2] == -math.huge)
decoded.many[1].repeated[1] = 99
assert(decoded.many[2].repeated[1] == 1)
local cycle = {}; cycle.self = cycle
assert(not encode(cycle))
assert(not encode({n = math.huge}))
assert(not encode({fn = function() end}))
local prior_limit = Codec.MAX_BYTES
Codec.MAX_BYTES = 128
assert(not encode(tricky), 'streaming output enforces the original byte limit')
Codec.MAX_BYTES = prior_limit

local files, fail_write = {}, false
local fs = {}
function fs.getInfo(path) return files[path] and {type = 'file', size = #files[path]} end
function fs.read(path) return files[path] end
function fs.write(path, value) files[path] = value; return true end
function fs.createDirectory(path) assert(path:sub(1, #'WorldLine/') == 'WorldLine/'); return true end
function fs.newFile(path)
    local f = {path = path}
    function f:open(mode) assert(mode == 'w'); files[self.path] = ''; return true end
    function f:write(chunk)
        files[self.path] = files[self.path] .. chunk
        if fail_write then error('simulated disk full') end
        return true
    end
    function f:flush() return true end
    function f:close() self.closed = true; return true end
    return f
end
local threads, max_queued = {}, 0
local thread_api = {}
function thread_api.newChannel()
    local channel = {values = {}}
    function channel:push(value)
        self.values[#self.values + 1] = value
        max_queued = math.max(max_queued, #self.values)
    end
    function channel:pop() return table.remove(self.values, 1) end
    function channel:getCount() return #self.values end
    function channel:demand()
        while #self.values == 0 do coroutine.yield() end
        return self:pop()
    end
    return channel
end
local function service()
    for _, thread in ipairs(threads) do
        if thread.running then
            local ok, err = coroutine.resume(thread.co)
            if not ok then thread.err = tostring(err) end
            thread.running = ok and coroutine.status(thread.co) ~= 'dead'
        end
    end
end
function thread_api.newThread(source)
    local thread = {}
    function thread:start(input, output)
        self.co = coroutine.create(assert(loadstring(source)))
        local ok, err = coroutine.resume(self.co, input, output)
        self.running, self.err = ok and coroutine.status(self.co) ~= 'dead', not ok and tostring(err) or nil
    end
    function thread:isRunning() return self.running end
    function thread:getError() return self.err end
    threads[#threads + 1] = thread
    return thread
end
local original_love = love
love = {filesystem = fs}
local original_loader = package.preload['love.filesystem']
package.preload['love.filesystem'] = function() return fs end
package.loaded['love.filesystem'] = nil
local source_file = assert(io.open('src/workers/save.lua', 'rb'))
local worker_source = source_file:read('*a'); source_file:close()
local function state(dollars) return {seed = 'SAME', save = {GAME = {dollars = dollars}}, cards = tricky.many} end
local tree = Tree.new(state(4), {seed = 'SAME', run_id = 'async'})
local store = Storage.new(Codec, Tree, TEST_JSON, fs):configure_async({thread = thread_api,
    source = worker_source, sleep = service})
local function finish()
    for _ = 1, 100000 do
        local result = store:poll_save(0)
        if result then return result end
        service()
    end
    error('save did not finish')
end
assert(store:start_save(tree, 1))
assert(store:busy_save() and store.generations.async == 0)
assert(not store:start_save(tree, 2), 'one active generation per storage')
-- Mutations while encoding must not change the accepted worldline revision.
tree:commit({kind = 'blind'}, state(0), {})
tree.metadata.progress_locked = true
tree.resume = {parent = 2, snapshot = state(3), summary = {dollars = 3}}
local result = finish()
assert(result.ok and result.ticket == 1 and result.tree == tree and not store:busy_save())
local loaded = assert(store:load('async'))
assert(loaded.current == 1 and loaded.next_id == 2 and #loaded.nodes[1].children == 0)
assert(not loaded.metadata.progress_locked and loaded.resume == nil,
    'metadata, child links and cursor are frozen at start_save')
assert(store.generations.async == 1 and max_queued <= 8)
assert(store:start_save(tree, 2))
result = finish()
assert(result.ok and result.ticket == 2 and store.generations.async == 2)
loaded = assert(store:load('async'))
assert(loaded.current == 2 and loaded.resume.snapshot.save.GAME.dollars == 3)
-- A failed partial write keeps the preceding generation recoverable and does
-- not silently turn into a blocking main-thread fs.write fallback.
tree:commit({kind = 'shop'}, state(8), {})
fail_write = true
assert(store:start_save(tree, 3))
result = finish()
assert(not result.ok and result.error:find('simulated disk full', 1, true))
assert(store.generations.async == 2 and store:load('async').current == 2)
fail_write = false
assert(store:start_save(tree, 4))
result = finish()
assert(result.ok and store.generations.async == 3 and store:load('async').current == 3)
-- A synchronous save is an ordered barrier: the older accepted view completes
-- first, and can never overwrite the newer direct save with a late ACK.
assert(store:start_save(tree, 5))
tree:commit({kind = 'leave'}, state(9), {})
assert(store:save(tree))
assert(not store:busy_save() and store.generations.async == 5)
assert(store:load('async').current == 4)
assert(store:stop_writer())
service()
assert(not threads[#threads]:isRunning())

-- Copy-on-write replacement of an immutable checkpoint, and rollback editing
-- its live child array, leave an already accepted view structurally complete.
local view = tree:export_save_view()
local checkpoint = {run_id = 'async', current = 1, next_id = 2}
tree:rollback(checkpoint)
tree.nodes[1].snapshot = tree:peek(1)
tree.nodes[1].snapshot.save.GAME.dollars = 77
tree.metadata.progress_locked = false
local isolated = assert(Tree.import(view))
assert(isolated.current == 4 and isolated.next_id == 5 and isolated.metadata.progress_locked)
assert(isolated.nodes[1].snapshot.save.GAME.dollars == 4)

-- Delete while the real worker protocol has an open generation. The barrier
-- waits for its close/ACK before backing up and placing a deletion marker;
-- subsequently servicing the channel cannot resurrect the archive.
function fs.remove(path) files[path] = nil; return true end
local delete_tree = Tree.new(state(12), {seed = 'SAME', run_id = 'delete_async'})
local delete_store = Storage.new(Codec, Tree, TEST_JSON, fs):configure_async({thread = thread_api,
    source = worker_source, sleep = service})
assert(delete_store:start_save(delete_tree, 6))
while not delete_store.active_save.writing do assert(not delete_store:poll_save(0)) end
service()
assert(delete_store:busy_save(), 'writer is still awaiting queued chunks/finish')
local deletion = assert(delete_store:delete_archive(delete_tree))
assert(not delete_store:busy_save() and delete_store:is_deleted('delete_async'))
for _ = 1, 10 do service() end
assert(not files['WorldLine/trees/delete_async.a.json'] and not files['WorldLine/trees/delete_async.b.json'])
assert(delete_store:load_backup(deletion.id).nodes[1].snapshot.save.GAME.dollars == 12)
assert(not delete_store:start_save(delete_tree, 7) and not delete_store:load('delete_async'))
assert(delete_store:stop_writer()); service()
assert(not threads[#threads]:isRunning())

love = original_love
package.preload['love.filesystem'] = original_loader
package.loaded['love.filesystem'] = nil
print('PASS async saving: bounded encoding/transfer, frozen views, ordered ACKs, partial-write recovery, barriers, worker shutdown')

-- Tree files live below LÖVE's save directory, never in the game's install tree.
-- Two generations keep the preceding valid file available after a failed write.
local Storage = {}
Storage.__index = Storage
Storage.ROOT = "WorldLine"
Storage.MAX_BYTES = 128 * 1024 * 1024

local function safe_id(id)
    return type(id) == "string" and #id > 0 and #id <= 96
        and id:match("^[%w_-]+$") ~= nil
end

local function tr(self, zh, en)
    return self.text and self.text(zh, en) or en
end

local function reason(self, value)
    return tr(self, nil, tostring(value))
end

function Storage.new(codec, tree_class, json, filesystem, translate)
    return setmetatable({codec = codec, Tree = tree_class, json = json,
        fs = filesystem, generations = {}, archive_cache = {}, text = translate, serial = 0}, Storage)
end

function Storage:configure_async(options)
    assert(not self.active_save, 'Cannot replace a writer during a save')
    self.async_options = options or {}
    self.clock = self.async_options.clock or os.clock
    return self
end

function Storage:busy_save() return self.active_save ~= nil end

local function count_nodes(tree)
    if type(tree.node_count) == 'function' then return tree:node_count() end
    local count = 0
    for _ in pairs(tree.nodes or {}) do count = count + 1 end
    return count
end

local function archive_name(tree)
    local name = tree.metadata.name
    return type(name) == 'string' and name ~= '' and name or tostring(tree.metadata.seed)
end

-- Browser rows contain only presentation metadata, never a retained game tree.
-- Return detached rows because callers overlay their current unsaved progress.
local function copy_data(value)
    if type(value) ~= 'table' then return value end
    local result = {}
    for k, v in pairs(value) do result[k] = copy_data(v) end
    return result
end

local function archive_row(tree)
    return {id=tree.metadata.run_id, seed=tree.metadata.seed, name=tree.metadata.name,
        node_count=count_nodes(tree), created_at=tree.metadata.created_at or 0,
        has_resume=tree.resume~=nil,
        summary=copy_data(tree.resume and tree.resume.summary or tree:get(tree.current).summary)}
end

function Storage:_archive_stamp(id)
    local parts = {tostring(self.generations[id] or 0)}
    for _, slot in ipairs({'a','b'}) do
        local info = self.fs.getInfo(self.ROOT .. '/trees/' .. id .. '.' .. slot .. '.json')
        if info then
            -- Filesystems without reliable stat data keep the original read path.
            if type(info.size)~='number' or type(info.modtime)~='number' then return nil end
            parts[#parts+1]=tostring(info.type)..':'..info.size..':'..info.modtime
        else parts[#parts+1]='missing' end
    end
    return table.concat(parts,'|')
end

function Storage:_remember_archive(tree)
    local id = tree.metadata.run_id
    local stamp = self:_archive_stamp(id)
    self.archive_cache[id] = stamp and {stamp=stamp,row=archive_row(tree)} or nil
end

function Storage:_browser_changed(kind)
    if self.on_browser_change then pcall(self.on_browser_change,kind) end
end

local backup_reasons = {archive = true, branch = true, rename = true, manual = true}
local function valid_receipt(receipt, id)
    return type(receipt) == 'table' and safe_id(receipt.id) and receipt.id == id
        and safe_id(receipt.source_id) and backup_reasons[receipt.reason] == true
        and type(receipt.label) == 'string' and #receipt.label <= 512
        and type(receipt.created_at) == 'number' and receipt.created_at >= 0
        and receipt.created_at <= 9007199254740991 and receipt.created_at % 1 == 0
        and type(receipt.node_count) == 'number' and receipt.node_count >= 1
        and receipt.node_count <= 10000 and receipt.node_count % 1 == 0
end

-- A valid deletion marker is authoritative even if a failed removal left one
-- generation behind, or an obsolete external writer later recreates that file.
-- Invalid/partial markers are not silently treated as successful deletion.
function Storage:is_deleted(id)
    if not safe_id(id) then return false end
    local path = self.ROOT .. '/trees/' .. id .. '.deleted.json'
    local info = self.fs.getInfo(path)
    if not info or info.type ~= 'file' or info.size and info.size > 4096 then return false end
    local ok, text = pcall(self.fs.read, path)
    if not ok or type(text) ~= 'string' or #text > 4096 then return false end
    local decoded, marker = pcall(self.json.decode, text)
    if not decoded or type(marker) ~= 'table' or marker.format ~= 'worldline-deleted'
        or marker.schema ~= 1 or marker.source_id ~= id or not safe_id(marker.backup_id) then return false end
    return true, marker
end

local function completion(self, ok, detail)
    local job = self.active_save
    if not job then return nil end
    self.active_save = nil
    self.archive_cache[job.id] = nil
    if ok then self.generations[job.id] = job.generation; self:_browser_changed('archives') end
    return {ticket = job.ticket, id = job.id, tree = job.tree, ok = ok == true,
        path = ok and job.path or nil, error = not ok and reason(self, detail or 'Cannot write worldline archive') or nil}
end

function Storage:_ensure_writer()
    if self.writer then return true end
    local options = self.async_options
    if not options then return true end -- Offline/custom filesystems use the synchronous write fallback.
    local ok, result = pcall(function()
        assert(options.thread and type(options.source) == 'string' and #options.source > 0,
            'Worldline background writer is unavailable')
        local input, output = options.thread.newChannel(), options.thread.newChannel()
        -- Pass source, not an absolute filename outside LÖVE's virtual FS.
        local thread = options.thread.newThread(options.source)
        thread:start(input, output)
        return {input = input, output = output, thread = thread}
    end)
    if not ok then return nil, tostring(result) end
    self.writer = result
    return true
end

-- The owner coalesces dirty revisions. Only one writer/encoder can be active,
-- so alternating generations cannot race or overwrite a newer completion.
function Storage:start_save(tree, ticket)
    if self.active_save then return nil, 'A worldline save is already pending' end
    local id = tree and tree.metadata and tree.metadata.run_id
    if not safe_id(id) then return nil, tr(self, '存档标识无效', 'Invalid archive identifier') end
    if self:is_deleted(id) then return nil, tr(self, nil, 'This worldline has been deleted') end
    self.archive_cache[id] = nil
    local ok, view = pcall(function()
        return tree.export_save_view and tree:export_save_view() or tree:export()
    end)
    if not ok then return nil, reason(self, view) end
    -- Normally new IDs are known unused and loaded runs already have a cached
    -- generation. The fallback protects callers attaching an existing ID.
    if self.generations[id] == nil then
        local base = self.ROOT .. '/trees/' .. id
        if self.fs.getInfo(base .. '.a.json') or self.fs.getInfo(base .. '.b.json') then self:load(id) end
        self.generations[id] = self.generations[id] or 0
    end
    local generation = self.generations[id] + 1
    if generation > 9007199254740991 then return nil, 'Worldline generation limit reached' end
    local encoder_ok, encoder = pcall(self.codec.new_encoder, {
        format = 'worldline', schema = 1, kind = 'local', generation = generation, tree = view
    }, self.json, self.clock or os.clock)
    if not encoder_ok then return nil, reason(self, encoder) end
    self.serial = self.serial + 1
    self.active_save = {tree = tree, id = id, ticket = ticket, generation = generation,
        serial = self.serial, encoder = encoder,
        path = self.ROOT .. '/trees/' .. id .. (generation % 2 == 1 and '.a.json' or '.b.json')}
    return true
end

function Storage:poll_save(budget)
    local job = self.active_save
    if not job then return nil end
    if job.writing then
        local writer = self.writer
        local message = writer.output:pop()
        if message then
            if message.serial ~= job.serial then return completion(self, false, 'Unexpected worldline writer acknowledgement') end
            return completion(self, message.ok, message.error)
        end
        local err = writer.thread:getError()
        if err or not writer.thread:isRunning() then
            self.writer = nil
            return completion(self, false, err or 'Worldline background writer stopped')
        end
        if job.chunks then
            local sent, push_err = pcall(function()
                -- Bound both per-frame transfer and queued data. A stalled disk
                -- must not build an unbounded Channel backlog on the game side.
                local count = 0
                while job.send_index <= #job.chunks and count < 4 and writer.input:getCount() < 8 do
                    writer.input:push({serial = job.serial, chunk = job.chunks[job.send_index]})
                    job.send_index, count = job.send_index + 1, count + 1
                end
                if job.send_index > #job.chunks and writer.input:getCount() < 8 then
                    writer.input:push({serial = job.serial, finish = true})
                    job.chunks = nil
                end
            end)
            if not sent then return completion(self, false, push_err) end
        end
        return nil
    end
    local state, result = job.encoder:step(budget)
    if state == nil then return completion(self, false, result) end
    if not state then return nil end
    job.encoder = nil -- Release dictionaries before handing chunks to the writer.
    local ready, err = self:_ensure_writer()
    if not ready then return completion(self, false, err) end
    if self.writer then
        local pushed, push_err = pcall(self.writer.input.push, self.writer.input,
            {serial = job.serial, path = job.path, begin = true})
        if not pushed then return completion(self, false, push_err) end
        job.writing, job.chunks, job.send_index = true, result.chunks, 1
        return nil
    end
    -- No thread dependency for deterministic offline/custom filesystem tests.
    -- The actual game always configures a worker, and never falls back to a
    -- blocking write when that worker fails.
    local ok, written, write_err = pcall(function()
        local prepared, prepare_err = self:prepare()
        if not prepared then return nil, prepare_err end
        return self.fs.write(job.path, table.concat(result.chunks))
    end)
    return completion(self, ok and written, ok and write_err or written)
end

function Storage:stop_writer()
    if self.active_save then return nil, 'A worldline save is still pending' end
    if self.writer then
        self.writer.input:push({stop = true})
        self.writer = nil
    end
    return true
end

function Storage:finish_save()
    while self.active_save do
        local result = self:poll_save(0.01)
        if result then return result end
        -- Only explicit shutdown/flush callers block. Ordinary update polling
        -- never waits for the disk or invokes thread:wait().
        if self.active_save and self.active_save.writing and self.async_options
            and self.async_options.sleep then self.async_options.sleep(0.001) end
    end
    return nil
end

function Storage:set_text(translate)
    self.text = translate
    return self
end

function Storage:prepare()
    for _, name in ipairs({"trees", "exports", "imports", "backups"}) do
        local ok, err = self.fs.createDirectory(self.ROOT .. "/" .. name)
        if not ok then return nil, err and reason(self, err)
            or tr(self, "无法创建世界线数据目录", "Cannot create worldline data directory") end
    end
    return true
end

function Storage:_read(path)
    local info = self.fs.getInfo(path)
    if not info or info.type ~= "file" then return nil, tr(self, "找不到文件", "File not found") end
    if info.size and info.size > self.MAX_BYTES then return nil, tr(self, "世界线文件超过 128 MiB", "Worldline file exceeds 128 MiB") end
    local text, err = self.fs.read(path)
    if not text then return nil, err and reason(self, err) or tr(self, "无法读取世界线文件", "Cannot read worldline file") end
    if #text > self.MAX_BYTES then return nil, tr(self, "世界线文件超过 128 MiB", "Worldline file exceeds 128 MiB") end
    return text
end

function Storage:_decode(text, kind)
    local ok, payload, err = pcall(self.codec.decode, text, self.json)
    if not ok then return nil, reason(self, payload) end
    if not payload then return nil, err and reason(self, err) or tr(self, "世界线数据无效", "Invalid worldline data") end
    if type(payload) ~= "table" or payload.format ~= "worldline"
        or payload.schema ~= 1 or payload.kind ~= kind then
        return nil, tr(self, "无法识别此世界线文件", "Unrecognized Worldline file")
    end
    local tree_ok, tree, tree_err = pcall(self.Tree.import, payload.tree)
    if not tree_ok then return nil, reason(self, tree) end
    if not tree then return nil, tree_err and reason(self, tree_err) or tr(self, "世界线无效", "Invalid worldline") end
    return tree, payload
end

function Storage:load(id)
    if not safe_id(id) then return nil, tr(self, "存档标识无效", "Invalid archive identifier") end
    if self:is_deleted(id) then return nil, tr(self, nil, 'This worldline has been deleted') end
    local best, generation, last_error
    for _, slot in ipairs({"a", "b"}) do
        local path = self.ROOT .. "/trees/" .. id .. "." .. slot .. ".json"
        local text, read_err = self:_read(path)
        if text then
            local tree, payload = self:_decode(text, "local")
            if tree and tree.metadata.run_id == id and type(payload.generation) == "number"
                and payload.generation >= 1 and payload.generation % 1 == 0
                and payload.generation <= 9007199254740991 then
                if not generation or payload.generation > generation then
                    best, generation = tree, payload.generation
                end
            else
                last_error = type(payload) == "string" and payload
                    or tr(self, "存档代次无效", "Invalid archive generation")
            end
        else
            last_error = read_err
        end
    end
    if best then
        self.generations[id] = math.max(self.generations[id] or 0, generation)
        self:_remember_archive(best)
        return best
    end
    return nil, last_error or tr(self, "找不到存档", "Archive not found")
end

function Storage:_encode(tree, kind, generation)
    -- Encoding is synchronous and Codec only reads source data. Avoid copying
    -- every historical snapshot before it walks those same snapshots again.
    local view = tree.export_view and tree:export_view() or tree:export()
    local ok, text = pcall(self.codec.encode, {
        format = "worldline", schema = 1, kind = kind,
        generation = generation or 0, tree = view
    }, self.json)
    if not ok then return nil, reason(self, text) end
    if type(text) ~= "string" or #text > self.MAX_BYTES then
        return nil, tr(self, "世界线文件超过 128 MiB", "Worldline file exceeds 128 MiB")
    end
    return text
end

function Storage:save(tree)
    -- Explicit synchronous operations are a barrier for previously queued data.
    -- A late background ACK can never advance after this newer save.
    if self.active_save then
        local prior = self:finish_save()
        if prior and not prior.ok then return nil, prior.error end
    end
    local id = tree.metadata.run_id
    if not safe_id(id) then return nil, tr(self, "存档标识无效", "Invalid archive identifier") end
    if self:is_deleted(id) then return nil, tr(self, nil, 'This worldline has been deleted') end
    self.archive_cache[id] = nil
    local ok, err = self:prepare()
    if not ok then return nil, err end
    if not self.generations[id] then self:load(id) end
    local generation = (self.generations[id] or 0) + 1
    local text, encode_err = self:_encode(tree, "local", generation)
    if not text then return nil, encode_err end
    local slot = generation % 2 == 1 and "a" or "b"
    local path = self.ROOT .. "/trees/" .. id .. "." .. slot .. ".json"
    self.archive_cache[id] = nil
    local written, write_err = self.fs.write(path, text)
    if not written then return nil, write_err and reason(self, write_err)
        or tr(self, "无法写入世界线存档", "Cannot write worldline archive") end
    self.generations[id] = generation
    self:_remember_archive(tree)
    self:_browser_changed('archives')
    return true, path
end

function Storage:archives(live)
    local rows, ids = {}, {}
    for _, filename in ipairs(self.fs.getDirectoryItems(self.ROOT .. "/trees") or {}) do
        local id = filename:match("^([%w_-]+)%.[ab]%.json$")
        if id then ids[id] = true end
    end
    for id in pairs(ids) do
        if not self:is_deleted(id) then
            local row
            if live and live[id] then row=archive_row(live[id])
            else
                local cached, stamp = self.archive_cache[id], self:_archive_stamp(id)
                if cached and stamp and cached.stamp==stamp then row=copy_data(cached.row)
                else
                    local tree=self:load(id)
                    if tree then row=archive_row(tree) else self.archive_cache[id]=nil end
                end
            end
            if row then
                row.label=tostring(row.name or row.seed)..' / '..row.node_count
                    ..tr(self,' 个收束点',' points')..' / '..id:sub(-12)
                rows[#rows+1]=row
            end
        else self.archive_cache[id]=nil
        end
    end
    for id in pairs(self.archive_cache) do if not ids[id] then self.archive_cache[id]=nil end end
    table.sort(rows, function(a, b)
        if a.created_at == b.created_at then return a.id > b.id end
        return a.created_at > b.created_at
    end)
    return rows
end

function Storage:export(tree)
    local ok, err = self:prepare()
    if not ok then return nil, err end
    if not safe_id(tree.metadata.run_id) then return nil, tr(self, "存档标识无效", "Invalid archive identifier") end
    local text, encode_err = self:_encode(tree, "share")
    if not text then return nil, encode_err end
    local path = self.ROOT .. "/exports/" .. tree.metadata.run_id .. ".worldline.json"
    local written, write_err = self.fs.write(path, text)
    if not written then return nil, write_err and reason(self, write_err)
        or tr(self, "无法写入世界线分享文件", "Cannot write shared worldline") end
    return path
end

function Storage:decode_share(text)
    if type(text) ~= "string" or #text > self.MAX_BYTES then
        return nil, tr(self, "世界线文件超过 128 MiB 或不是文本", "Worldline file exceeds 128 MiB or is not text")
    end
    return self:_decode(text, "share")
end

function Storage:import_latest()
    local files = {}
    for _, name in ipairs(self.fs.getDirectoryItems(self.ROOT .. "/imports") or {}) do
        if name:lower():match("%.json$") and not name:find("[/\\]") then
            local path = self.ROOT .. "/imports/" .. name
            local info = self.fs.getInfo(path)
            if info and info.type == "file" then
                files[#files + 1] = {path = path, time = info.modtime or 0}
            end
        end
    end
    table.sort(files, function(a, b)
        if a.time == b.time then return a.path > b.path end
        return a.time > b.time
    end)
    if not files[1] then return nil, tr(self, "WorldLine/imports 中没有 JSON 文件", "No JSON file in WorldLine/imports") end
    local text, err = self:_read(files[1].path)
    if not text then return nil, err end
    return self:decode_share(text)
end

-- Manual destructive operations are explicit barriers. No old background
-- generation may still be writing after a verified deletion marker is placed.
local function finish_prior(self)
    if self.active_save then
        local prior = self:finish_save()
        if not prior or not prior.ok then return nil, prior and prior.error or 'Worldline save did not complete' end
    end
    return true
end

function Storage:load_backup(id)
    if not safe_id(id) then return nil, tr(self, '存档标识无效', 'Invalid archive identifier') end
    local path = self.ROOT .. '/backups/' .. id .. '.worldline.json'
    local text, err = self:_read(path)
    if not text then return nil, err end
    local tree, payload = self:_decode(text, 'backup')
    if not tree then return nil, payload end
    local receipt = payload.backup
    if not valid_receipt(receipt, id) or receipt.source_id ~= tree.metadata.run_id
        or receipt.node_count ~= count_nodes(tree) then
        return nil, tr(self, nil, 'Invalid worldline backup')
    end
    receipt.path = path
    return tree, receipt
end

function Storage:backup(tree, purpose)
    local id = tree and tree.metadata and tree.metadata.run_id
    if not safe_id(id) then return nil, tr(self, '存档标识无效', 'Invalid archive identifier') end
    purpose = purpose or 'manual'
    if not backup_reasons[purpose] then return nil, tr(self, nil, 'Invalid backup reason') end
    local complete, prior_err = finish_prior(self)
    if not complete then return nil, prior_err end
    local prepared, prepare_err = self:prepare()
    if not prepared then return nil, prepare_err end
    local stamp, backup_id, path = os.time()
    repeat
        self.backup_serial = (self.backup_serial or 0) + 1
        backup_id = 'backup_' .. tostring(stamp) .. '_' .. tostring(self.backup_serial)
        path = self.ROOT .. '/backups/' .. backup_id .. '.worldline.json'
    until not self.fs.getInfo(path)
    local receipt = {id = backup_id, source_id = id, label = archive_name(tree), created_at = stamp,
        reason = purpose, node_count = count_nodes(tree)}
    local encoded, text = pcall(function()
        local view = tree.export_view and tree:export_view() or tree:export()
        return self.codec.encode({format = 'worldline', schema = 1, kind = 'backup', generation = 0,
            backup = receipt, tree = view}, self.json)
    end)
    if not encoded then return nil, reason(self, text) end
    if type(text) ~= 'string' or #text > self.MAX_BYTES then
        return nil, tr(self, '世界线文件超过 128 MiB', 'Worldline file exceeds 128 MiB')
    end
    local write_ok, written, write_err = pcall(self.fs.write, path, text)
    if not write_ok or not written then
        return nil, reason(self, write_ok and write_err or written or 'Cannot write worldline backup')
    end
    local read_text, read_err = self:_read(path)
    if read_text ~= text then return nil, read_err or tr(self, nil, 'Worldline backup verification failed') end
    local verified, verified_receipt = self:load_backup(backup_id)
    if not verified then return nil, verified_receipt end
    self:_browser_changed('backups')
    return verified_receipt
end

function Storage:backups()
    local rows = {}
    for _, filename in ipairs(self.fs.getDirectoryItems(self.ROOT .. '/backups') or {}) do
        local id = filename:match('^([%w_-]+)%.worldline%.json$')
        if id then
            local tree, receipt = self:load_backup(id)
            if tree then
                receipt.seed, receipt.has_resume = tree.metadata.seed, tree.resume ~= nil
                receipt.summary = tree.resume and tree.resume.summary or tree:get(tree.current).summary
                rows[#rows + 1] = receipt
            end
        end
    end
    table.sort(rows, function(a, b)
        if a.created_at == b.created_at then return a.id > b.id end
        return a.created_at > b.created_at
    end)
    return rows
end

function Storage:delete_archive(tree)
    local id = tree and tree.metadata and tree.metadata.run_id
    if not safe_id(id) then return nil, tr(self, '存档标识无效', 'Invalid archive identifier') end
    if self:is_deleted(id) then return nil, tr(self, nil, 'This worldline has been deleted') end
    if type(self.fs.remove) ~= 'function' then return nil, tr(self, nil, 'Archive removal is unavailable') end
    local receipt, backup_err = self:backup(tree, 'archive')
    if not receipt then return nil, backup_err end
    local marker_path = self.ROOT .. '/trees/' .. id .. '.deleted.json'
    local encoded, marker_text = pcall(self.json.encode, {format = 'worldline-deleted', schema = 1,
        source_id = id, backup_id = receipt.id})
    if not encoded then return nil, reason(self, marker_text) end
    local wrote, written, write_err = pcall(self.fs.write, marker_path, marker_text)
    local read_ok, read_text = pcall(self.fs.read, marker_path)
    if not wrote or not written or not read_ok or read_text ~= marker_text or not self:is_deleted(id) then
        -- The generations are untouched. Try to remove a torn/unconfirmed
        -- marker so it cannot turn a failed operation into a hidden archive.
        pcall(self.fs.remove, marker_path)
        if not self:is_deleted(id) then
            local failure = not wrote and written or not written and (write_err or 'Cannot delete worldline')
                or 'Deletion marker verification failed'
            return nil, reason(self, failure)
        end
        -- Some filesystems can report failure after persisting the full marker.
        -- If rollback removal also failed, its verified state is already the
        -- commit point; report logical deletion with a recoverable backup.
        receipt.cleanup_warning = tr(self, nil, 'Deletion completed; some files could not be removed')
    end
    local cleanup = false
    for _, slot in ipairs({'a', 'b'}) do
        local path = self.ROOT .. '/trees/' .. id .. '.' .. slot .. '.json'
        if self.fs.getInfo(path) then
            local ok, removed = pcall(self.fs.remove, path)
            if not ok or not removed or self.fs.getInfo(path) then cleanup = true end
        end
    end
    if cleanup then receipt.cleanup_warning = tr(self, nil, 'Deletion completed; some files could not be removed') end
    self.generations[id] = nil
    self.archive_cache[id] = nil
    self:_browser_changed('archives')
    return receipt
end

return Storage

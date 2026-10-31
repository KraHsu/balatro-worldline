-- Safe data-only JSON. A table dictionary deduplicates unchanged checkpoint
-- suworldlines; decimal strings preserve every binary double used by gameplay RNG.
local Codec = {MAX_BYTES = 128 * 1024 * 1024, MAX_TABLES = 1000000,
    MAX_ENTRIES = 10000000, MAX_EXPANDED_ENTRIES = 20000000, MAX_DEPTH = 96}

local function number_text(value)
    assert(value == value and math.abs(value) ~= math.huge, "Non-finite number")
    return string.format("%.17g", value)
end

local function key_order(a, b)
    local ka, kb = type(a), type(b)
    if ka ~= kb then return ka < kb end
    if ka == "boolean" then return a == false and b == true end
    return a < b
end

-- These tags describe already encoded atoms, never arbitrary Lua tables.
-- Length prefixes count raw bytes (including NUL/UTF-8); fixed tags distinguish
-- strings, decimal-number strings, references and booleans without escaping.
-- Alternating key/value tokens form an injective signature for sorted entries.
local function signature_atom(value)
    local kind = type(value)
    if kind == "string" then return "s" .. #value .. ":" .. value end
    if kind == "boolean" then return value and "t;" or "f;" end
    if value.r then return "r" .. value.r .. ";" end
    if value.n then return "n" .. #value.n .. ":" .. value.n end
    return "z;"
end

function Codec.encode(value, JSON)
    local tables, signatures, stack, count = {}, {}, {}, 0
    local numbers, number_count = {}, 0
    local function decimal(value)
        -- Lua equates +0 and -0 as table keys. Preserve the existing formatter's
        -- representation for both rather than sharing their cached spelling.
        if value == 0 then return number_text(value) end
        local result = numbers[value]
        if not result then
            result = number_text(value)
            if number_count < Codec.MAX_ENTRIES then
                numbers[value], number_count = result, number_count + 1
            end
        end
        return result
    end
    local encode
    encode = function(item, depth)
        assert(depth <= Codec.MAX_DEPTH, "Tree data nesting limit exceeded")
        local kind = type(item)
        if kind == "nil" then return {z = true} end
        if kind == "number" then return {n = decimal(item)} end
        if kind == "string" or kind == "boolean" then return item end
        assert(kind == "table", "Only plain data can be shared")
        assert(not stack[item], "Cyclic data cannot be shared")
        stack[item] = true
        local keys, entries = {}, {}
        for key in pairs(item) do
            local kt = type(key)
            assert(kt == "number" or kt == "string" or kt == "boolean", "Invalid data key")
            if kt == "number" then decimal(key) end
            keys[#keys + 1] = key
        end
        table.sort(keys, key_order)
        for _, key in ipairs(keys) do
            count = count + 1
            assert(count <= Codec.MAX_ENTRIES, "Tree data entry limit exceeded")
            entries[#entries + 1] = {k = encode(key, depth + 1), v = encode(item[key], depth + 1)}
        end
        stack[item] = nil
        local tokens = {}
        for _, entry in ipairs(entries) do
            tokens[#tokens + 1] = signature_atom(entry.k)
            tokens[#tokens + 1] = signature_atom(entry.v)
        end
        local signature = table.concat(tokens)
        local id = signatures[signature]
        if not id then
            id = #tables + 1
            assert(id <= Codec.MAX_TABLES, "Tree data table limit exceeded")
            tables[id], signatures[signature] = entries, id
        end
        return {r = id}
    end
    local root = encode(value, 0)
    local text = JSON.encode({format = "worldline-data", schema = 1, root = root, tables = tables})
    assert(#text <= Codec.MAX_BYTES, "Tree data exceeds 128 MiB")
    return text
end

-- Autosaves stream the same dictionary wire format in short cooperative slices.
-- Each new dictionary entry is emitted immediately: retaining a second giant
-- wire.tables graph and then JSON.encode-ing it caused both long frames and a
-- large temporary heap. No gameplay object is mutated by this encoder.
function Codec.new_encoder(value, JSON, clock)
    clock = clock or os.clock
    local job = {clock = clock, deadline = 0, operations = 0}
    local function tick()
        job.operations = job.operations + 1
        if job.operations % 32 == 0 and (job.operations >= 4096 or clock() >= job.deadline) then
            coroutine.yield()
        end
    end
    job.thread = coroutine.create(function()
        local chunks, buffer, buffered, size = {}, {}, 0, 0
        local function emit(text)
            size = size + #text
            assert(size <= Codec.MAX_BYTES, 'Tree data exceeds 128 MiB')
            buffer[#buffer + 1], buffered = text, buffered + #text
            if buffered >= 16384 then
                chunks[#chunks + 1], buffer, buffered = table.concat(buffer), {}, 0
            end
            tick()
        end
        local escapes = {['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b', ['\f'] = '\\f',
            ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t'}
        local function quoted(text)
            emit('"')
            -- Bound each native gsub, including for imported long text strings.
            for index = 1, #text, 1024 do
                emit((text:sub(index, index + 1023):gsub('[%z\1-\31\\"]', function(c)
                    return escapes[c] or string.format('\\u%04x', string.byte(c))
                end)))
            end
            emit('"')
        end
        local function write_atom(atom)
            local kind = type(atom)
            if kind == 'string' then quoted(atom)
            elseif kind == 'boolean' then emit(atom and 'true' or 'false')
            elseif atom.r then emit('{"r":' .. atom.r .. '}')
            elseif atom.n then emit('{"n":'); quoted(atom.n); emit('}')
            else emit('{"z":true}') end
        end
        -- Merge sorting permits yields even for a large imported table. Lua's
        -- table.sort comparator is a non-yieldable C boundary on Lua 5.1.
        local function sorted_keys(item)
            local keys = {}
            for key in pairs(item) do
                local kind = type(key)
                assert(kind == 'number' or kind == 'string' or kind == 'boolean', 'Invalid data key')
                if kind == 'number' then
                    assert(key == key and math.abs(key) ~= math.huge, 'Non-finite number')
                end
                keys[#keys + 1] = key
                tick()
            end
            local width, count, scratch = 1, #keys, {}
            while width < count do
                for base = 1, count, width * 2 do
                    local a, a_end = base, math.min(base + width - 1, count)
                    local b, b_end = base + width, math.min(base + width * 2 - 1, count)
                    for target = base, b_end do
                        if a <= a_end and (b > b_end or key_order(keys[a], keys[b])) then
                            scratch[target], a = keys[a], a + 1
                        else scratch[target], b = keys[b], b + 1 end
                        tick()
                    end
                end
                keys, scratch, width = scratch, keys, width * 2
            end
            return keys
        end
        local signatures, stack, numbers, references = {}, {}, {}, {}
        local count, table_count = 0, 0
        local encode
        encode = function(item, depth)
            tick()
            assert(depth <= Codec.MAX_DEPTH, 'Tree data nesting limit exceeded')
            local kind = type(item)
            if kind == 'nil' then return {z = true} end
            if kind == 'number' then
                if item == 0 then return {n = number_text(item)} end
                local atom = numbers[item]
                if not atom then atom = {n = number_text(item)}; numbers[item] = atom end
                return atom
            end
            if kind == 'string' or kind == 'boolean' then return item end
            assert(kind == 'table', 'Only plain data can be shared')
            assert(not stack[item], 'Cyclic data cannot be shared')
            stack[item] = true
            local keys, atoms, tokens = sorted_keys(item), {}, {}
            for _, key in ipairs(keys) do
                count = count + 1
                assert(count <= Codec.MAX_ENTRIES, 'Tree data entry limit exceeded')
                local k, v = encode(key, depth + 1), encode(item[key], depth + 1)
                atoms[#atoms + 1], atoms[#atoms + 2] = k, v
                tokens[#tokens + 1], tokens[#tokens + 2] = signature_atom(k), signature_atom(v)
                tick()
            end
            stack[item] = nil
            local signature = table.concat(tokens)
            local id = signatures[signature]
            if not id then
                table_count = table_count + 1
                assert(table_count <= Codec.MAX_TABLES, 'Tree data table limit exceeded')
                id, signatures[signature] = table_count, table_count
                references[id] = {r = id}
                if id > 1 then emit(',') end
                emit('[')
                for index = 1, #atoms, 2 do
                    if index > 1 then emit(',') end
                    emit('{"k":'); write_atom(atoms[index]); emit(',"v":'); write_atom(atoms[index + 1]); emit('}')
                end
                emit(']')
            end
            return references[id]
        end
        emit('{"format":"worldline-data","schema":1,"tables":[')
        local root = encode(value, 0)
        emit('],"root":'); write_atom(root); emit('}')
        if buffered > 0 then chunks[#chunks + 1] = table.concat(buffer) end
        return {chunks = chunks, size = size}
    end)
    function job:step(budget)
        if self.result then return true, self.result end
        if self.error then return nil, self.error end
        self.deadline, self.operations = self.clock() + math.max(0, budget or 0.00075), 0
        local ok, result = coroutine.resume(self.thread)
        if not ok then
            self.error, self.thread = tostring(result), nil
            return nil, self.error
        end
        if coroutine.status(self.thread) == 'dead' then
            self.result, self.thread = result, nil
            return true, result
        end
        return false
    end
    return job
end

local function array(value, limit)
    assert(type(value) == "table" and #value <= limit, "Invalid data array")
    local count = 0
    for key in pairs(value) do
        assert(type(key) == "number" and key % 1 == 0 and key >= 1 and key <= #value, "Invalid data array key")
        count = count + 1
    end
    assert(count == #value, "Sparse data array")
end

local function only_field(value, field)
    local count = 0
    for key in pairs(value) do assert(key == field, "Unexpected data tag"); count = count + 1 end
    assert(count == 1, "Invalid data tag")
end

local function decode(text, JSON)
    assert(type(text) == "string" and #text <= Codec.MAX_BYTES, "Tree data exceeds 128 MiB")
    local wire = JSON.decode(text)
    assert(type(wire) == "table" and wire.format == "worldline-data" and wire.schema == 1, "Unknown data format")
    array(wire.tables, Codec.MAX_TABLES)
    local visiting, expanded = {}, 0
    local read
    read = function(value, depth)
        assert(depth <= Codec.MAX_DEPTH, "Tree data nesting limit exceeded")
        local kind = type(value)
        if kind == "string" or kind == "boolean" then return value end
        assert(kind == "table", "Invalid encoded value")
        if value.z ~= nil then only_field(value, "z"); assert(value.z == true); return nil end
        if value.n ~= nil then
            only_field(value, "n")
            assert(type(value.n) == "string" and #value.n <= 32, "Invalid number")
            local result = tonumber(value.n)
            assert(result and result == result and math.abs(result) ~= math.huge, "Invalid number")
            return result
        end
        only_field(value, "r")
        local id = value.r
        assert(type(id) == "number" and id % 1 == 0 and id >= 1 and id <= #wire.tables, "Invalid table reference")
        assert(not visiting[id], "Cyclic table reference")
        visiting[id] = true
        local entries, result = wire.tables[id], {}
        array(entries, Codec.MAX_ENTRIES)
        for _, entry in ipairs(entries) do
            expanded = expanded + 1
            assert(expanded <= Codec.MAX_EXPANDED_ENTRIES, "Expanded tree data limit exceeded")
            assert(type(entry) == "table" and entry.k ~= nil and entry.v ~= nil, "Invalid table entry")
            for key in pairs(entry) do assert(key == "k" or key == "v", "Invalid table entry field") end
            local key = read(entry.k, depth + 1)
            local kt = type(key)
            assert(kt == "string" or kt == "number" or kt == "boolean", "Invalid decoded key")
            assert(result[key] == nil, "Repeated table key")
            local item = read(entry.v, depth + 1)
            assert(item ~= nil, "Nil table entry")
            result[key] = item
        end
        visiting[id] = nil
        return result
    end
    return read(wire.root, 0)
end

function Codec.decode(text, JSON)
    local ok, value = pcall(decode, text, JSON)
    if not ok then return nil, tostring(value) end
    return value
end

return Codec

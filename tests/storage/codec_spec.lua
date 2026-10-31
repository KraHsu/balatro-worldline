local Codec = dofile("src/storage/codec.lua")
local number = 0.30072781822578326
local original = {name = "决策树", flag = false, sparse = {[1] = "one", [4] = "four"},
    mixed = {[false] = "false key", [2] = 9, ["2"] = 10}, seed = number,
    objects = {{key = "same", values = {1, 2, 3}}, {key = "same", values = {1, 2, 3}}}}
local text = Codec.encode(original, TEST_JSON)
local decoded = assert(Codec.decode(text, TEST_JSON))
assert(decoded.seed == number, "RNG doubles must not lose precision through JSON")
assert(decoded.flag == false and decoded.name == original.name)
assert(decoded.sparse[2] == nil and decoded.sparse[4] == "four")
assert(decoded.mixed[false] == "false key" and decoded.mixed[2] == 9 and decoded.mixed["2"] == 10)
decoded.objects[1].values[1] = 99
assert(decoded.objects[2].values[1] == 1, "deduplication must not alias mutable decoded tables")
assert(not Codec.decode("os.execute('not Lua input')", TEST_JSON))
assert(not Codec.decode('{"format":"worldline-data","schema":1,"root":{"r":1},"tables":[[{"k":"self","v":{"r":1}}]]}', TEST_JSON))
assert(not Codec.decode('{"format":"worldline-data","schema":1,"root":{"r":99},"tables":[]}', TEST_JSON))
local cycle = {}; cycle.self = cycle
assert(not pcall(Codec.encode, cycle, TEST_JSON))
assert(not pcall(Codec.encode, {fn = function() end}, TEST_JSON))
assert(not pcall(Codec.encode, {number = math.huge}, TEST_JSON))

-- Signatures must distinguish arbitrary byte strings, numeric spellings,
-- booleans, reference-looking strings and different key/value boundaries.
local tricky = {
    {v = 'r1;'}, {v = 't;'}, {v = 'f;'}, {v = 'z;'}, {v = 'n1:1'},
    {v = ''}, {v = 's0:'}, {v = '\0'}, {v = 'x\0y:;"\\世界线'},
    {v = 1}, {v = '1'}, {v = true}, {v = false}, {v = {}},
    {a = 'bc'}, {ab = 'c'}, {[true] = false}, {['true'] = false},
    {[1] = 'x', ['1'] = 'y', [false] = 'f', [true] = 't'},
    {v = {n = '1'}}, {v = {r = 1}}, {v = {z = true}},
}
local function same(a, b)
    assert(type(a) == type(b))
    if type(a) ~= 'table' then assert(a == b); return end
    for k, v in pairs(a) do same(v, b[k]) end
    for k in pairs(b) do assert(a[k] ~= nil) end
end
local json_calls = 0
local counting_json = {encode = function(value)
    json_calls = json_calls + 1
    return TEST_JSON.encode(value)
end}
local encoded = Codec.encode(tricky, counting_json)
same(tricky, assert(Codec.decode(encoded, TEST_JSON)))
assert(json_calls == 1, 'signature construction never recursively serializes temporary tables as JSON')
local wire = TEST_JSON.decode(Codec.encode({foo = 'x'}, TEST_JSON))
assert(wire.format == 'worldline-data' and wire.schema == 1 and wire.root.r == 1)
same(wire.tables, {{{k = 'foo', v = 'x'}}}) -- Existing archive wire format is unchanged.

local positive_zero, negative_zero = 0, -1 / math.huge
local zero = assert(Codec.decode(Codec.encode({positive_zero, negative_zero}, TEST_JSON), TEST_JSON))
assert(1 / zero[1] == math.huge and 1 / zero[2] == -math.huge,
    'numeric caching preserves signed zero even though Lua equates their keys')
for _, value in ipairs({number, 1e-300, -1e-300, 1e300, -1e300, 9007199254740991}) do
    same({value, value, [value] = value}, assert(Codec.decode(Codec.encode({value, value, [value] = value}, TEST_JSON), TEST_JSON)))
end
local old_entries, old_tables, old_depth = Codec.MAX_ENTRIES, Codec.MAX_TABLES, Codec.MAX_DEPTH
Codec.MAX_ENTRIES = 2
assert(not pcall(Codec.encode, {1, 2, 3}, TEST_JSON), 'entry limits still bound encoding and number caches')
Codec.MAX_ENTRIES, Codec.MAX_TABLES = old_entries, 1
assert(not pcall(Codec.encode, {{value = 1}}, TEST_JSON))
Codec.MAX_TABLES, Codec.MAX_DEPTH = old_tables, 2
assert(not pcall(Codec.encode, {{{1}}}, TEST_JSON))
Codec.MAX_DEPTH = old_depth
print("PASS codec: exact typed signatures, precise doubles/signed zero, sparse keys, deduplication, limits, inert malformed input")

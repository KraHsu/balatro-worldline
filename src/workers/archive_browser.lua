-- Read-only worker: sources are shipped Mod code, archives are inert JSON.
-- No game objects, native saves, write calls or imported Lua are available here.
require('love.filesystem')
local input,output,configuration=...
local function source(name)
    return assert(loadstring(assert(configuration.modules[name]),'@worldline-browser/'..name..'.lua'))()
end
local Browser=assert(loadstring(configuration.protocol_source,'@worldline-browser/protocol.lua'))()
local Codec,Tree,Storage=source('codec'),source('tree'),source('storage')
local JSON=assert(loadstring(configuration.json_source,'@worldline-browser/json.lua'))()
local fs={getDirectoryItems=love.filesystem.getDirectoryItems,getInfo=love.filesystem.getInfo,read=love.filesystem.read}
local store=Storage.new(Codec,Tree,JSON,fs)
local summary_fields={'deck','deck_name','stake','ante','round','money','dollars','state',
    'blind_key','blind_name','hands_left','discards_left','joker_count','hand_count','deck_count'}
local row_fields={'id','seed','name','label','node_count','created_at','has_resume','path','source_id','reason'}
local function primitive(value)
    if type(value)=='string' then return value:sub(1,1024) end
    if type(value)=='boolean' or type(value)=='number' then return value end
end
local function compact(rows)
    local result={}
    for _,row in ipairs(rows) do
        local item={summary={}}
        for _,key in ipairs(row_fields) do item[key]=primitive(row[key]) end
        for _,key in ipairs(summary_fields) do item.summary[key]=primitive(row.summary and row.summary[key]) end
        result[#result+1]=item
    end
    return result
end
while true do
    local message=input:demand()
    if message.stop then break end
    local response={serial=message.serial,kind=message.kind}
    local ok,err=pcall(function()
        local before=Browser.signature(fs,message.kind)
        if before~=message.signature then response.stale=true;return end
        -- Explicit refresh epochs also invalidate same-size/coarse-time writes.
        store.archive_cache={}
        local rows=message.kind=='archives' and store:archives() or store:backups()
        local after=Browser.signature(fs,message.kind)
        if after~=before then response.stale=true;return end
        response.rows,response.signature,response.ok=compact(rows),after,true
    end)
    if not ok then response.error=tostring(err);response.ok=false end
    output:push(response)
    collectgarbage('collect')
end

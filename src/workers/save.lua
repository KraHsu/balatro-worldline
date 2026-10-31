-- The only background operation is writing an already encoded worldline. This
-- thread never loads a game, evaluates imported Lua, or writes native saves.
require('love.filesystem')
local input, output = ...
local file, serial, failed, size
local function close()
    if file then pcall(file.close, file); file = nil end
end
while true do
    local message = input:demand()
    if message.stop then close(); break end
    local ok, err = pcall(function()
        if message.begin then
            close()
            serial, failed, size = message.serial, false, 0
            assert(type(message.path) == 'string'
                and message.path:match('^WorldLine/trees/[%w_%-]+%.[ab]%.json$'), 'Invalid worldline write path')
            assert(love.filesystem.createDirectory('WorldLine/trees'))
            file = assert(love.filesystem.newFile(message.path))
            assert(file:open('w'))
        elseif message.serial == serial and not failed then
            assert(file, 'Missing worldline write stream')
            if message.finish then
                assert(file:flush())
                assert(file:close())
                file = nil
                output:push({serial = serial, ok = true})
                return
            end
            assert(type(message.chunk) == 'string', 'Invalid worldline chunk')
            size = size + #message.chunk
            assert(size <= 128 * 1024 * 1024, 'Worldline exceeds 128 MiB')
            assert(file:write(message.chunk))
        end
    end)
    if not ok then
        close()
        failed = true
        output:push({serial = message.serial, ok = false, error = tostring(err)})
    end
end

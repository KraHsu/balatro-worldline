-- Steamodded entry point. Runtime ownership lives in src/runtime/app.lua.
local Loader = assert(SMODS.load_file('loader.lua', 'WorldLine'))()
return Loader.load('app')

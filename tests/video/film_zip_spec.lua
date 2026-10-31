local Zip=dofile('src/video/bootstrap_zip.lua')
local prefix='MZ-owned-private-engine'
local files={['main.lua']='hello',['game.lua']='world'}
local values={hello=0x3610a686,world=0x3a771143}
local bytes=Zip.append(prefix,files,function(v)return assert(values[v])end)
assert(Zip.read(bytes,'main.lua')=='hello' and Zip.read(bytes,'game.lua')=='world')
assert(Zip.engine(bytes)==prefix,'The private executable contains only the engine and patched bootstrap')
assert(not pcall(Zip.read,bytes,'missing.lua'))
assert(not pcall(Zip.read,bytes:sub(1,-5),'main.lua'))
assert(not pcall(Zip.engine,'not an executable'))
print('PASS private render bootstrap ZIP: exact files, executable prefix and malformed-archive rejection')

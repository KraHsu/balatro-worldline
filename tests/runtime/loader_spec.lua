local Loader=dofile('src/loader.lua')
assert(Loader.MOD_ID=='WorldLine' and Loader.path('app')=='runtime/app.lua')
assert(not pcall(Loader.path,'../outside'))
assert(type(Loader.load('tree').new)=='function')
assert(Loader.source('film_worker'):find('encoder_source',1,true))
local old=SMODS
SMODS={current_mod={id='AnotherMod',path='wrong/'},Mods={WorldLine={id='WorldLine',path='test.zip.mnt/'}},
 load_file=function(path,id)assert(id=='WorldLine' and path=='domain/tree.lua');return function()return 'loaded'end end,
 NFS={read=function(path)assert(path=='test.zip.mnt/workers/encode.lua');return 'worker source'end}}
assert(Loader.load('tree')=='loaded' and Loader.source('film_worker')=='worker source')
SMODS=old
print('PASS module registry: native/ZIP/offline paths, fixed mod identity and unknown-module rejection')

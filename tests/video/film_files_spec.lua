local Files=dofile('src/video/sources.lua')
local bytes={['virtual.zip.mnt/Mod/WorldLine.json']='{"id":"WorldLine"}',
 ['virtual.zip.mnt/Mod/assets/icon.png']='\0PNG', ['smods/src/core.lua']='source'}
local dirs={['virtual.zip.mnt/Mod']={'WorldLine.json','assets'},['virtual.zip.mnt/Mod/assets']={'icon.png'},
 ['smods']={'src'},['smods/src']={'core.lua'}}
local reads=0
local fs={getInfo=function(path)return bytes[path] and {type='file'} or dirs[path] and {type='directory'}end,
 getDirectoryItems=function(path)return assert(dirs[path])end,
 read=function(path)reads=reads+1;return bytes[path]end}
local state=Files.new(fs,{{kind='mod',root='virtual.zip.mnt/Mod',relative=''},
 {kind='smods',root='smods',relative=''}})
local done,files
for i=1,30 do
 local before=reads;done,files=Files.step(state,1);assert(reads-before<=1,'Source collection stays bounded per step')
 if done then break end
end
assert(done and files.mod['WorldLine.json']=='{"id":"WorldLine"}' and files.mod['assets/icon.png']=='\0PNG')
assert(files.smods['src/core.lua']=='source' and reads==3,'Mounted ZIP bytes come from the loader filesystem')
local invalid=Files.new(fs,{{kind='mod',root='missing',relative=''}})
assert(not pcall(Files.step,invalid,1),'Missing sources cannot silently create an empty mod')
print('PASS renderer source materialization: virtual ZIPs, assets, bounded reads and missing-source rejection')

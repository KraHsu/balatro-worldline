local Dialog=dofile('src/platform/file_dialog.lua')
local results,messages={},{}
local picker=Dialog.new(function()error('No source read is needed while polling')end,
 function(path,err,cancelled)results[#results+1]={path=path,error=err,cancelled=cancelled}end)
local clear_count=0
picker.requests={clear=function()clear_count=clear_count+1 end}
picker.responses={pop=function()return table.remove(messages,1)end,clear=function()clear_count=clear_count+1 end}
picker.thread={getError=function()end};picker.active=true
messages[1]={path='D:/视频 & 文件/ffmpeg.exe'}
picker:update()
assert(not picker.active and results[1].path=='D:/视频 & 文件/ffmpeg.exe' and not results[1].cancelled)
picker.active=true;messages[1]={cancelled=true};picker:update()
assert(not picker.active and results[2].cancelled and results[2].path==nil,'Picker cancellation cannot replace settings')
picker.active=true;messages[1]={error='native dialog error'};picker:update()
assert(results[3].error=='native dialog error' and not results[3].cancelled)
assert(clear_count==6,'Completed native dialogs release their channels')
print('PASS native picker polling: Unicode selections, cancellation, failures and channel cleanup')

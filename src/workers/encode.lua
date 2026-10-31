-- Stream bounded RGBA frames into FFmpeg while the next game frames render.
require('love.thread')
local request_name,response_name=...
local requests,responses=love.thread.getChannel(request_name),love.thread.getChannel(response_name)
local job=requests:demand()
local process
local function send(value)responses:push(value)end
local function cancel()
    process.close(true);process.discard();send{kind='cancelled'}
end
local ok,err=xpcall(function()
    local Encoder=assert(loadstring(job.encoder_source))()
    process=Encoder.open(job,requests)
    send{kind='ready'}
    local frames=0
    while true do
        local item=requests:demand()
        if item.kind=='cancel' then cancel();return end
        if item.kind=='finish' then
            assert(frames>0,'No video frames were captured')
            job.video_seconds=frames/job.fps
            local success,cancelled=process.close(false)
            if cancelled then process.discard();send{kind='cancelled'};return end
            assert(success,'FFmpeg encoding failed; check the encoder log')
            assert(process.finalize(),'Cannot finalize recording file')
            send{kind='done',path=job.output,frames=frames};return
        end
        assert(item.kind=='frame' and type(item.data)=='string' and #item.data==job.width*job.height*4,'Invalid recording frame')
        if not process.write(item.data)then cancel();return end
        frames=frames+1;send{kind='frame',index=frames}
    end
end,debug.traceback)
if not ok then
    if process then pcall(process.close,true);pcall(process.discard)end
    send{kind='error',error=tostring(err),log=job.log}
end

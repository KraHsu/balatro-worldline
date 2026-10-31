local Encoder=dofile('src/video/encoder.lua')
local args=Encoder.arguments{width=2560,height=1440,fps=60,ffmpeg='C:/FFmpeg/ffmpeg.exe',partial='D:/Videos/out.partial.mp4'}
local joined=table.concat(args,' ')
assert(joined:find('-f rawvideo -pixel_format rgba',1,true) and joined:find('-video_size 2560x1440',1,true))
assert(joined:find('-framerate 60 -i pipe:0',1,true) and not joined:find('.png',1,true))
local function run(items,mode)
    local sent,trace={},{}
    local source=[[return {open=function(job,requests)
        return {write=function(frame)
            TEST_TRACE[#TEST_TRACE+1]=frame
            if TEST_MODE=='write_error' then error('synthetic pipe failure')end
            return TEST_MODE~='write_cancel'
        end,close=function(cancel)
            TEST_TRACE[#TEST_TRACE+1]=cancel and 'cancel' or 'eof'
            return TEST_MODE~='encoder_error',TEST_MODE=='flush_cancel'
        end,finalize=function()TEST_TRACE[#TEST_TRACE+1]='publish';return true end,
        discard=function()TEST_TRACE[#TEST_TRACE+1]='discard'end}
    end}]]
    table.insert(items,1,{encoder_source=source,width=1,height=1,fps=30,output='out.mp4',log='out.log'})
    local requests={demand=function()return assert(table.remove(items,1))end}
    local responses={push=function(_,value)sent[#sent+1]=value end}
    local env=setmetatable({TEST_TRACE=trace,TEST_MODE=mode,
        require=function(name)assert(name=='love.thread')end,
        love={thread={getChannel=function(name)return name=='input' and requests or responses end}}},{__index=_G})
    env.loadstring=function(text)local fn=assert(loadstring(text));setfenv(fn,env);return fn end
    local worker=assert(loadfile('src/workers/encode.lua'));setfenv(worker,env);worker('input','output')
    return sent,trace
end
local sent,trace=run({{kind='frame',data='1234'},{kind='frame',data='5678'},{kind='finish'}})
assert(table.concat(trace,',')=='1234,5678,eof,publish')
assert(sent[1].kind=='ready' and sent[2].index==1 and sent[3].index==2 and sent[4].kind=='done' and sent[4].frames==2)
for _,mode in ipairs({'write_cancel','flush_cancel','write_error','encoder_error'})do
    sent,trace=run({{kind='frame',data='1234'},{kind='finish'}},mode)
    assert(trace[#trace]=='discard' and not table.concat(trace,','):find('publish',1,true),'Failed/cancelled exports cannot publish partial video')
    assert(sent[#sent].kind==(mode:find('error') and 'error' or 'cancelled'))
end
sent,trace=run({{kind='frame',data='bad'}},nil)
assert(sent[#sent].kind=='error' and table.concat(trace,',')=='cancel,discard')
print('PASS video frame stream: raw RGBA input, ordered acknowledgements, pipe/encoder failures and cancellation without partial publication')

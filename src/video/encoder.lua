-- Windows raw-frame pipe. No PNG intermediates, shell, or unbounded frame queue.
local Encoder={}
function Encoder.arguments(job)
    assert(type(job.width)=='number' and type(job.height)=='number'
        and job.width>0 and job.height>0 and job.width%1==0 and job.height%1==0,'Invalid video dimensions')
    return {job.ffmpeg,'-hide_banner','-loglevel','error','-n','-f','rawvideo',
        '-pixel_format','rgba','-video_size',job.width..'x'..job.height,
        '-framerate',tostring(job.fps),'-i','pipe:0','-an','-c:v','libx264',
        '-preset','veryfast','-threads','2','-filter_threads','1','-crf','20',
        '-vf','pad=ceil(iw/2)*2:ceil(ih/2)*2','-pix_fmt','yuv420p','-movflags','+faststart',job.partial}
end
local function quote(s)
    return '"'..tostring(s):gsub('(\\*)"','%1%1\\"'):gsub('(\\+)$','%1%1')..'"'
end
function Encoder.open(job,requests)
    local ffi=require('ffi')
    ffi.cdef[[
      typedef void* WL_ENC_HANDLE; typedef unsigned long WL_ENC_DWORD; typedef int WL_ENC_BOOL;
      typedef struct {WL_ENC_DWORD nLength; void* lpSecurityDescriptor; WL_ENC_BOOL bInheritHandle;} WL_ENC_SECURITY;
      typedef struct {WL_ENC_DWORD cb; unsigned short* lpReserved; unsigned short* lpDesktop;
        unsigned short* lpTitle; WL_ENC_DWORD dwX,dwY,dwXSize,dwYSize,dwXCountChars,dwYCountChars;
        WL_ENC_DWORD dwFillAttribute,dwFlags; unsigned short wShowWindow,cbReserved2;
        unsigned char* lpReserved2; WL_ENC_HANDLE hStdInput,hStdOutput,hStdError;} WL_ENC_STARTUP;
      typedef struct {WL_ENC_HANDLE hProcess,hThread; WL_ENC_DWORD dwProcessId,dwThreadId;} WL_ENC_PROCESS;
      int MultiByteToWideChar(unsigned int,WL_ENC_DWORD,const char*,int,unsigned short*,int);
      WL_ENC_BOOL CreatePipe(WL_ENC_HANDLE*,WL_ENC_HANDLE*,WL_ENC_SECURITY*,WL_ENC_DWORD);
      WL_ENC_BOOL SetHandleInformation(WL_ENC_HANDLE,WL_ENC_DWORD,WL_ENC_DWORD);
      WL_ENC_BOOL WriteFile(WL_ENC_HANDLE,const void*,WL_ENC_DWORD,WL_ENC_DWORD*,void*);
      WL_ENC_HANDLE CreateFileW(const unsigned short*,WL_ENC_DWORD,WL_ENC_DWORD,WL_ENC_SECURITY*,WL_ENC_DWORD,WL_ENC_DWORD,WL_ENC_HANDLE);
      WL_ENC_BOOL CreateProcessW(const unsigned short*,unsigned short*,WL_ENC_SECURITY*,WL_ENC_SECURITY*,WL_ENC_BOOL,WL_ENC_DWORD,void*,const unsigned short*,WL_ENC_STARTUP*,WL_ENC_PROCESS*);
      WL_ENC_BOOL CloseHandle(WL_ENC_HANDLE); WL_ENC_DWORD GetLastError(void);
      WL_ENC_DWORD WaitForSingleObject(WL_ENC_HANDLE,WL_ENC_DWORD);
      WL_ENC_BOOL GetExitCodeProcess(WL_ENC_HANDLE,WL_ENC_DWORD*);
      WL_ENC_BOOL TerminateProcess(WL_ENC_HANDLE,unsigned int);
      WL_ENC_BOOL MoveFileW(const unsigned short*,const unsigned short*);
      WL_ENC_BOOL DeleteFileW(const unsigned short*);
    ]]
    local k=ffi.load('kernel32')
    local function wide(s)
        local n=k.MultiByteToWideChar(65001,0,s,#s,nil,0);assert(n>0,'Cannot encode video path')
        local out=ffi.new('unsigned short[?]',n+1);k.MultiByteToWideChar(65001,0,s,#s,out,n);return out
    end
    local function check(ok,message)assert(ok~=0,message..' (Windows '..tonumber(k.GetLastError())..')')end
    local read,write,log,process
    local function close(handle)if handle then k.CloseHandle(handle)end end
    local ok,err=pcall(function()
        local sa=ffi.new('WL_ENC_SECURITY')
        sa.nLength=ffi.sizeof(sa);sa.bInheritHandle=1
        local rd,wr=ffi.new('WL_ENC_HANDLE[1]'),ffi.new('WL_ENC_HANDLE[1]')
        check(k.CreatePipe(rd,wr,sa,1024*1024),'Cannot create video pipe');read,write=rd[0],wr[0]
        check(k.SetHandleInformation(write,1,0),'Cannot protect video pipe')
        log=k.CreateFileW(wide(job.log),0x40000000,3,sa,2,0x80,nil)
        if log==ffi.cast('WL_ENC_HANDLE',-1) then log=nil;error('Cannot create encoder log')end
        local args=Encoder.arguments(job)
        for i,v in ipairs(args)do args[i]=quote(v)end
        local startup=ffi.new('WL_ENC_STARTUP');startup.cb=ffi.sizeof(startup)
        startup.dwFlags=0x100;startup.hStdInput=read;startup.hStdOutput=log;startup.hStdError=log
        local pi=ffi.new('WL_ENC_PROCESS')
        check(k.CreateProcessW(nil,wide(table.concat(args,' ')),nil,nil,1,0x08004000,nil,nil,startup,pi),'Cannot launch FFmpeg')
        process=pi.hProcess;close(pi.hThread)
    end)
    close(read);close(log)
    if not ok then close(write);if process then k.TerminateProcess(process,1);close(process)end;error(err,0)end
    local closed=false
    local function cancelled()
        local item=requests:peek()
        if item and item.kind=='cancel' then requests:pop();return true end
    end
    return {
        write=function(frame)
            assert(not closed,'Video pipe is closed')
            local pointer=ffi.cast('const unsigned char*',frame)
            local offset,written=0,ffi.new('WL_ENC_DWORD[1]')
            while offset<#frame do
                if cancelled()then return false end
                local ok=k.WriteFile(write,pointer+offset,math.min(1024*1024,#frame-offset),written,nil)
                if ok==0 then
                    local reason=tonumber(k.GetLastError());local code=ffi.new('WL_ENC_DWORD[1]');k.GetExitCodeProcess(process,code)
                    error('FFmpeg stopped receiving video frames (Windows '..reason..', exit '..tonumber(code[0])..')')
                end
                assert(written[0]>0,'FFmpeg accepted no video data');offset=offset+tonumber(written[0])
            end
            return true
        end,
        close=function(cancel)
            if closed then return false,cancel end
            closed=true;close(write);write=nil
            local waited,elapsed,was_cancelled=258,0,cancel
            local limit=math.min(900000,math.max(30000,(job.video_seconds or 0)*3000))
            repeat
                was_cancelled=was_cancelled or cancelled()
                if was_cancelled then break end
                waited=k.WaitForSingleObject(process,100);elapsed=elapsed+100
            until waited~=258 or elapsed>=limit
            if waited~=0 then k.TerminateProcess(process,1);k.WaitForSingleObject(process,1000)end
            local code=ffi.new('WL_ENC_DWORD[1]');k.GetExitCodeProcess(process,code);close(process);process=nil
            return waited==0 and tonumber(code[0])==0,was_cancelled
        end,
        finalize=function()return k.MoveFileW(wide(job.partial),wide(job.output))~=0 end,
        discard=function()k.DeleteFileW(wide(job.partial))end,
    }
end
return Encoder

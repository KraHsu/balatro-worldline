-- Windows-only isolated process and UTF-8 filesystem operations. Loaded lazily.
local ffi=require('ffi')
ffi.cdef[[
typedef void* WL_HANDLE; typedef unsigned long WL_DWORD; typedef int WL_BOOL;
typedef struct {WL_DWORD cb; unsigned short *reserved,*desktop,*title; WL_DWORD x,y,w,h,cx,cy,fill,flags;
 unsigned short show,reserved_bytes; unsigned char* bytes; WL_HANDLE input,output,error;} WL_SI;
typedef struct {WL_HANDLE process,thread; WL_DWORD pid,tid;} WL_PI;
typedef struct {WL_DWORD attributes; unsigned long time[6]; WL_DWORD size_high,size_low,reserved[2];
 unsigned short name[260],alternate[14];} WL_FIND;
typedef struct {long long process_time,job_time; WL_DWORD flags; size_t minimum,maximum;
 WL_DWORD active_limit; uintptr_t affinity; WL_DWORD priority,scheduling;} WL_JOB_BASIC;
typedef struct {WL_JOB_BASIC basic; unsigned long long io[6]; size_t process_memory,job_memory,peak_process,peak_job;} WL_JOB_LIMITS;
int MultiByteToWideChar(unsigned int,WL_DWORD,const char*,int,unsigned short*,int);
int WideCharToMultiByte(unsigned int,WL_DWORD,const unsigned short*,int,char*,int,const char*,int*);
WL_BOOL CreateDirectoryW(const unsigned short*,void*);
WL_BOOL CopyFileW(const unsigned short*,const unsigned short*,WL_BOOL);
WL_HANDLE CreateFileW(const unsigned short*,WL_DWORD,WL_DWORD,void*,WL_DWORD,WL_DWORD,WL_HANDLE);
WL_BOOL ReadFile(WL_HANDLE,void*,WL_DWORD,WL_DWORD*,void*);
WL_BOOL WriteFile(WL_HANDLE,const void*,WL_DWORD,WL_DWORD*,void*);
WL_DWORD GetFileSize(WL_HANDLE,WL_DWORD*); WL_DWORD GetFileAttributesW(const unsigned short*);
WL_HANDLE FindFirstFileW(const unsigned short*,WL_FIND*); WL_BOOL FindNextFileW(WL_HANDLE,WL_FIND*);
WL_BOOL FindClose(WL_HANDLE); WL_BOOL CloseHandle(WL_HANDLE); WL_DWORD GetLastError(void);
unsigned short* GetEnvironmentStringsW(void); WL_BOOL FreeEnvironmentStringsW(unsigned short*);
WL_HANDLE CreateDesktopW(const unsigned short*,void*,void*,WL_DWORD,WL_DWORD,void*);
WL_BOOL CloseDesktop(WL_HANDLE);
WL_BOOL CreateProcessW(const unsigned short*,unsigned short*,void*,void*,WL_BOOL,WL_DWORD,void*,const unsigned short*,WL_SI*,WL_PI*);
WL_DWORD WaitForSingleObject(WL_HANDLE,WL_DWORD); WL_BOOL GetExitCodeProcess(WL_HANDLE,WL_DWORD*);
WL_BOOL TerminateProcess(WL_HANDLE,unsigned int); WL_DWORD GetCurrentProcessId(void);
WL_HANDLE CreateJobObjectW(void*,const unsigned short*);
WL_BOOL SetInformationJobObject(WL_HANDLE,int,void*,WL_DWORD);
WL_BOOL AssignProcessToJobObject(WL_HANDLE,WL_HANDLE); WL_DWORD ResumeThread(WL_HANDLE);
WL_DWORD GetFullPathNameW(const unsigned short*,WL_DWORD,unsigned short*,unsigned short**);
WL_BOOL DeleteFileW(const unsigned short*); WL_BOOL RemoveDirectoryW(const unsigned short*);
]]
local k,u=ffi.load('kernel32'),ffi.load('user32')
local W={};local invalid=ffi.cast('WL_HANDLE',-1)
function W.wide(s)
    local n=k.MultiByteToWideChar(65001,0,s,#s,nil,0);assert(n>0,'Invalid UTF-8 path')
    local out=ffi.new('unsigned short[?]',n+1);k.MultiByteToWideChar(65001,0,s,#s,out,n);return out
end
local function utf8(s,n)
    local size=k.WideCharToMultiByte(65001,0,s,n,nil,0,nil,nil)
    local out=ffi.new('char[?]',size+1);k.WideCharToMultiByte(65001,0,s,n,out,size,nil,nil);return ffi.string(out,size)
end
function W.utf8(s)
    local n=0;while s[n]~=0 do n=n+1;assert(n<32768,'Selected path exceeds its limit') end
    return utf8(s,n)
end
function W.attributes(path) local n=k.GetFileAttributesW(W.wide(path));return n~=0xffffffff and tonumber(n) or nil end
function W.mkdir(path)
    path=path:gsub('\\','/')
    if #path>3 then path=path:gsub('/+$','') end
    assert(path:match('^%a:/') or path:sub(1,2)=='//','Use an absolute output directory')
    if W.attributes(path) then assert(W.attributes(path)%32>=16,'Output path is not a directory');return end
    local parent=path:match('^(.*)/[^/]+$');assert(parent and parent~=path,'Invalid directory')
    if #parent>2 then W.mkdir(parent) end
    assert(k.CreateDirectoryW(W.wide(path),nil)~=0 or k.GetLastError()==183,'Cannot create directory: '..path)
end
function W.copy(from,to)
    W.mkdir(assert(to:match('^(.*)/[^/]+$')))
    assert(k.CopyFileW(W.wide(from),W.wide(to),0)~=0,'Cannot copy render dependency: '..from)
end
function W.read(path)
    local h=k.CreateFileW(W.wide(path),0x80000000,7,nil,3,0x80,nil)
    if h==invalid then return nil end
    local high=ffi.new('WL_DWORD[1]');local size=tonumber(k.GetFileSize(h,high))
    if high[0]~=0 or size>512*1024*1024 then k.CloseHandle(h);error('Render file exceeds limit') end
    local data=ffi.new('char[?]',math.max(1,size));local n=ffi.new('WL_DWORD[1]')
    local ok=k.ReadFile(h,data,size,n,nil);k.CloseHandle(h)
    if ok==0 or tonumber(n[0])~=size then return nil end
    return ffi.string(data,size)
end
function W.write(path,data)
    local h=k.CreateFileW(W.wide(path),0x40000000,7,nil,2,0x80,nil);assert(h~=invalid,'Cannot write: '..path)
    local n=ffi.new('WL_DWORD[1]');local ok=k.WriteFile(h,data,#data,n,nil);k.CloseHandle(h)
    assert(ok~=0 and tonumber(n[0])==#data,'Incomplete render write')
end
function W.list(path)
    local info=ffi.new('WL_FIND');local h=k.FindFirstFileW(W.wide(path..'/*'),info);local out={}
    if h==invalid then return out end
    repeat
        local n=0;while info.name[n]~=0 do n=n+1 end
        local name=utf8(info.name,n)
        if name~='.' and name~='..' then out[#out+1]={name=name,directory=tonumber(info.attributes)%32>=16,
            link=math.floor(tonumber(info.attributes)/1024)%2==1} end
    until k.FindNextFileW(h,info)==0
    k.FindClose(h);return out
end
function W.remove_file(path) return k.DeleteFileW(W.wide(path))~=0 end
function W.full_path(path)
    local n=k.GetFullPathNameW(W.wide(path),0,nil,nil);assert(n>0,'Cannot resolve render path')
    local out=ffi.new('unsigned short[?]',n+1)
    n=k.GetFullPathNameW(W.wide(path),n+1,out,nil);assert(n>0,'Cannot resolve render path')
    return utf8(out,n):gsub('\\','/'):gsub('/+$','')
end
function W.clean_job(path,key)
    assert(key:match('^[%w_-]+$'),'Invalid render job key')
    local root=W.full_path(path)
    local suffix='/WorldLine/render-jobs/'..key
    assert(root:sub(-#suffix):lower()==suffix:lower(),'Cleanup escaped the owned render job')
    local function remove(directory)
        local resolved=W.full_path(directory)
        assert(resolved:lower()==root:lower() or resolved:sub(1,#root+1):lower()==root:lower()..'/',
            'Cleanup escaped the owned render job')
        local attributes=W.attributes(directory)
        if not attributes or math.floor(attributes/1024)%2==1 then return end
        for _,entry in ipairs(W.list(directory)) do
            if not entry.link then
                local child=directory..'/'..entry.name
                if entry.directory then remove(child) else W.remove_file(child) end
            end
        end
        k.RemoveDirectoryW(W.wide(directory))
    end
    remove(root)
end
local function quote(s) return '"'..s:gsub('(\\*)"','%1%1\\"'):gsub('(\\+)$','%1%1')..'"' end
function W.spawn(exe,cwd,overrides,key)
    local entries={};local raw=k.GetEnvironmentStringsW();assert(raw~=nil,'Cannot read render environment')
    local at=0
    while raw[at]~=0 do
        local n=0;while raw[at+n]~=0 do n=n+1 end
        local row=utf8(raw+at,n);local name=row:match('^([^=]+)=')
        if name and not name:upper():match('^STEAM') and not name:upper():match('^LOVELY') then entries[name:upper()]=row end
        at=at+n+1
    end
    k.FreeEnvironmentStringsW(raw)
    for name,value in pairs(overrides) do entries[name:upper()]=name..'='..value end
    local rows={} for _,row in pairs(entries) do rows[#rows+1]=row end table.sort(rows)
    local desktop_name='WorldLineRender-'..tonumber(k.GetCurrentProcessId())..'-'..key
    local desktop=u.CreateDesktopW(W.wide(desktop_name),nil,nil,0,0x1ff,nil)
    assert(desktop~=nil,'Cannot create isolated render desktop')
    local si=ffi.new('WL_SI');si.cb=ffi.sizeof(si)
    local desk=W.wide('WinSta0\\'..desktop_name);si.desktop=desk;si.flags=1;si.show=0
    local pi=ffi.new('WL_PI')
    local ok=k.CreateProcessW(W.wide(exe),W.wide(quote(exe)),nil,nil,0,0x08000400+0x4000+4,
        W.wide(table.concat(rows,'\0')..'\0\0'),W.wide(cwd),si,pi)
    if ok==0 then u.CloseDesktop(desktop);error('Cannot launch render process: '..tonumber(k.GetLastError())) end
    local group=k.CreateJobObjectW(nil,nil)
    local limits=ffi.new('WL_JOB_LIMITS');limits.basic.flags=0x2000
    if group==nil or k.SetInformationJobObject(group,9,limits,ffi.sizeof(limits))==0
        or k.AssignProcessToJobObject(group,pi.process)==0 then
        k.TerminateProcess(pi.process,1);k.CloseHandle(pi.thread);k.CloseHandle(pi.process)
        if group~=nil then k.CloseHandle(group) end
        u.CloseDesktop(desktop);error('Cannot contain the private video renderer')
    end
    k.ResumeThread(pi.thread)
    k.CloseHandle(pi.thread)
    return {handle=pi.process,desktop=desktop,group=group}
end
function W.exited(p)
    if k.WaitForSingleObject(p.handle,0)~=0 then return false end
    local code=ffi.new('WL_DWORD[1]');k.GetExitCodeProcess(p.handle,code);return true,tonumber(code[0])
end
function W.close(p,terminate)
    if terminate then k.TerminateProcess(p.handle,1);k.WaitForSingleObject(p.handle,3000) end
    k.CloseHandle(p.handle);k.CloseHandle(p.group);u.CloseDesktop(p.desktop)
end
return W

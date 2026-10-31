-- IFileOpenDialog, shared by executable and folder pickers. No shell commands.
local ffi=require('ffi');local bit=require('bit')
ffi.cdef[[
typedef struct {unsigned long a; unsigned short b,c; unsigned char d[8];} WL_PICK_GUID;
typedef struct {const unsigned short *name,*spec;} WL_PICK_FILTER;
long CoInitializeEx(void*,unsigned long); void CoUninitialize(void);
long CLSIDFromString(const unsigned short*,WL_PICK_GUID*);
long CoCreateInstance(const WL_PICK_GUID*,void*,unsigned long,const WL_PICK_GUID*,void**);
void CoTaskMemFree(void*);
long SHCreateItemFromParsingName(const unsigned short*,void*,const WL_PICK_GUID*,void**);
]]
local ole,shell=ffi.load('ole32'),ffi.load('shell32')
local Picker={}
local function method(object,index,signature)
    return ffi.cast(signature,ffi.cast('void***',object)[0][index])
end
local function release(object)
    if object and object~=ffi.NULL then method(object,2,'unsigned long (__stdcall *)(void*)')(object) end
end
local function check(hr,label) assert(tonumber(hr)>=0,label..' (HRESULT '..tostring(tonumber(hr))..')') end
function Picker.open(W,job,show)
    check(ole.CoInitializeEx(nil,2),'Cannot initialize file picker')
    local dialog,item,path
    local ok,result=xpcall(function()
        local function guid(value)
            local out=ffi.new('WL_PICK_GUID[1]');check(ole.CLSIDFromString(W.wide(value),out),'Invalid picker identifier');return out
        end
        local clsid=guid('{DC1C5A9C-E88A-4DDE-A5A1-60F82A20AEF7}')
        local iid=guid('{D57C7288-D4AD-4768-BE02-9D969532D960}')
        local siid=guid('{43826D1E-E718-42EE-BC55-A1E261C37BFE}')
        local out=ffi.new('void*[1]');check(ole.CoCreateInstance(clsid,nil,1,iid,out),'Cannot create file picker')
        dialog=out[0]
        local options=ffi.new('unsigned long[1]')
        check(method(dialog,10,'long (__stdcall *)(void*,unsigned long*)')(dialog,options),'Cannot read picker options')
        local flags=bit.bor(tonumber(options[0]),0x40,0x8,0x800,0x2000000,job.kind=='folder' and 0x20 or 0x1000)
        check(method(dialog,9,'long (__stdcall *)(void*,unsigned long)')(dialog,flags),'Cannot set picker options')
        check(method(dialog,17,'long (__stdcall *)(void*,const unsigned short*)')(dialog,W.wide(job.title)),'Cannot name file picker')
        local buffers={}
        if job.kind~='folder' then
            buffers={W.wide('FFmpeg (ffmpeg.exe)'),W.wide('ffmpeg.exe'),W.wide('*.exe'),W.wide('*.exe')}
            local filters=ffi.new('WL_PICK_FILTER[2]',{{buffers[1],buffers[2]},{buffers[3],buffers[4]}})
            check(method(dialog,4,'long (__stdcall *)(void*,unsigned int,const WL_PICK_FILTER*)')(dialog,2,filters),'Cannot set file filter')
        end
        local initial=(job.initial or ''):gsub('\\','/')
        local folder=job.kind=='folder' and initial or initial:match('^(.*)/[^/]+$')
        if folder and folder~='' then
            local selected=ffi.new('void*[1]')
            if tonumber(shell.SHCreateItemFromParsingName(W.wide(folder),nil,siid,selected))>=0 then
                method(dialog,12,'long (__stdcall *)(void*,void*)')(dialog,selected[0]);release(selected[0])
            end
        end
        if show==false then return {configured=true,options=flags} end
        local hr=tonumber(method(dialog,3,'long (__stdcall *)(void*,void*)')(dialog,ffi.cast('void*',job.owner)))
        if hr==-2147023673 then return {cancelled=true} end
        check(hr,'File picker failed')
        local selected=ffi.new('void*[1]');check(method(dialog,20,'long (__stdcall *)(void*,void**)')(dialog,selected),'Cannot read selected path')
        item=selected[0]
        local text=ffi.new('unsigned short*[1]')
        check(method(item,5,'long (__stdcall *)(void*,unsigned long,unsigned short**)')(item,0x80058000,text),'Selection has no filesystem path')
        path=text[0]
        return {path=W.utf8(path)}
    end,debug.traceback)
    if path then ole.CoTaskMemFree(path) end
    release(item);release(dialog);ole.CoUninitialize()
    if not ok then return {error=tostring(result)} end
    return result
end
return Picker

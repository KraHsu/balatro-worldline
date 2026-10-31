-- Native pickers run on a separate STA thread, leaving the game loop responsive.
local Dialog={};Dialog.__index=Dialog
function Dialog.new(read,finished) return setmetatable({read=read,finished=finished},Dialog) end
function Dialog:start(kind,title,initial)
    assert(not self.active,'A file picker is already open')
    assert(love.system.getOS()=='Windows','Use Enter path on this platform')
    local ffi=require('ffi');ffi.cdef[[void* GetActiveWindow(void);]]
    local owner=tonumber(ffi.cast('uintptr_t',ffi.load('user32').GetActiveWindow()))
    assert(owner~=0,'Activate the game window before choosing a path')
    local key=tostring(math.floor(love.timer.getTime()*1000000))
    local incoming,outgoing='WorldLine.picker.in.'..key,'WorldLine.picker.out.'..key
    self.requests,self.responses=love.thread.getChannel(incoming),love.thread.getChannel(outgoing)
    self.requests:clear();self.responses:clear()
    self.thread=love.thread.newThread(self.read('file_dialog_worker'))
    self.requests:push{kind=kind,title=title,initial=initial,owner=owner,windows=self.read('film_windows'),shell=self.read('file_dialog_windows')}
    self.thread:start(incoming,outgoing);self.active=true
    return true
end
function Dialog:update()
    if not self.active then return end
    local result=self.responses:pop()
    local err=self.thread:getError()
    if result or err then
        self.active=false;self.requests:clear();self.responses:clear()
        if err then self.finished(nil,tostring(err),false)
        else self.finished(result.path,result.error,result.cancelled==true) end
    end
end
return Dialog

-- Copies a private bootstrap/loader and supervises one lower-priority renderer.
require('love.thread');require('love.timer');require('love.data')
local incoming,outgoing=...
local requests,responses=love.thread.getChannel(incoming),love.thread.getChannel(outgoing)
local job=requests:demand()
local W=assert(loadstring(job.sources.windows))()
local Zip=assert(loadstring(job.sources.zip))()
local Codec=assert(loadstring(job.sources.codec))()
local JSON=assert(loadstring(job.sources.json))()
local process,cancelled,terminal
local function send(v) responses:push(v) end
local function cancelled_now()
    local request=requests:pop()
    if request and request.kind=='cancel' then cancelled=true end
    return cancelled
end
local function materialize(files,to)
    assert(type(files)=='table' and next(files),'Renderer source is empty')
    for relative,bytes in pairs(files) do
        assert(not relative:find('\\') and not relative:match('^/') and not relative:find(':')
            and not ('/'..relative..'/'):find('/../',1,true),'Renderer source escaped its directory')
        assert(not cancelled_now(),'Export cancelled')
        local path=to..'/'..relative
        W.mkdir(assert(path:match('^(.*)/[^/]+$')));W.write(path,bytes)
    end
end
local function once(source,pattern,replacement)
    local start,finish=source:find(pattern,1,true)
    assert(start and not source:find(pattern,finish+1,true),'This game version cannot be exported in the background')
    return source:sub(1,start-1)..replacement..source:sub(finish+1)
end
local function crc(data)
    local bit=require('bit');local n=-1
    for i=1,#data do
        n=bit.bxor(n,data:byte(i))
        for _=1,8 do n=bit.bxor(bit.rshift(n,1),bit.band(n,1)==1 and 0xedb88320 or 0) end
    end
    n=bit.bnot(n);return n<0 and n+4294967296 or n
end
local function lua(s) return string.format('%q',s) end
local ok,err=xpcall(function()
    send{phase='preparing',progress=0.01}
    assert(not W.attributes(job.root),'Render job already exists')
    W.mkdir(job.root);W.mkdir(job.root..'/engine');W.mkdir(job.root..'/appdata');W.mkdir(job.root..'/localappdata');W.mkdir(job.root..'/temp')
    W.mkdir(job.output_dir)
    local native=assert(W.read(job.game),'Cannot read the installed game')
    local function raw(name) return Zip.read(native,name,function(bytes)return love.data.decompress('string','deflate',bytes)end) end
    local main=raw('main.lua'):gsub('\r\n','\n')
    main=once(main,'\t--Steam integration\n\tlocal os = love.system.getOS()',
        '\t--Steam integration\n\tif false then -- WorldLine offline renderer\n\tlocal os = love.system.getOS()')
    main=once(main,'\t--Set the mouse to invisible immediately, this visibility is handled in the G.CONTROLLER',
        '\tend -- WorldLine offline renderer\n\tG.STEAM=nil\n\t--Set the mouse to invisible immediately, this visibility is handled in the G.CONTROLLER')
    main='local worldline_archive=love.filesystem.newFileData(assert(require("worldline_windows").read('
        ..lua(job.game)..')),"balatro-source.zip")\n'
        ..'assert(love.filesystem.mount(worldline_archive,"",true),"Cannot mount installed game")\n'
        ..'package.preload.luasteam=function() error("Steam is disabled in the renderer") end\n'..main
    main=main..'\nlocal worldline_load=love.load\nfunction love.load(...)\n'
        ..'local ok,why=pcall(function(...) worldline_load(...);assert(not G.STEAM);'
        ..'assert(SMODS.load_file("loader.lua","WorldLine"))().load("film_child").install('..lua(job.root)..') end,...)\n'
        ..'if not ok then local message=tostring(why):gsub("[%z\\1-\\31\\\\\\\"]",function(c)return string.format("\\\\u%04x",c:byte())end);'
        ..'require("worldline_windows").write('..lua(job.root..'/status.json')
        ..',\'{"phase":"error","error":"\'..message..\'"}\');love.event.quit() end\nend\n'
    local game=raw('game.lua'):gsub('\r\n','\n')
    game=once(game,'    self:init_window()',[[    self.F_CRASH_REPORTS,self.F_HTTP_SCORES,self.F_DISCORD=false,false,false
    self.F_NO_ACHIEVEMENTS,self.F_SKIP_TUTORIAL,self.F_MUTE=true,true,true
    self.SETTINGS.crashreports=false
    self.SETTINGS.skip_splash='Yes';self.SETTINGS.tutorial_complete=true
    self.SETTINGS.WINDOW.screenmode='Windowed'
    self.SETTINGS.SOUND.volume=0;self.SETTINGS.SOUND.music_volume=0;self.SETTINGS.SOUND.game_sounds_volume=0
    self:init_window()]])
    game=once(game,'    self.SETTINGS.crashreports=false',
        '    self.SETTINGS.language='..lua(job.language)..'\n    self.SETTINGS.crashreports=false')
    local conf='_RELEASE_MODE=true\n_DEMO=false\nfunction love.conf(t)\n t.identity='..lua(job.identity)
        ..'\n t.appendidentity=false;t.console=false;t.window.title="WorldLine renderer"'
        ..'\n t.window.width='..((job.plan.options.height or 720)*16/9)..';t.window.height='..(job.plan.options.height or 720)
        ..';t.window.fullscreen=false;t.window.vsync=0;t.window.resizable=false\nend\n'
    local exe=Zip.append(Zip.engine(native),{['main.lua']=main,['conf.lua']=conf,['game.lua']=game,
        ['worldline_windows.lua']=job.sources.windows},crc)
    W.write(job.root..'/engine/WorldLineRender.exe',exe)
    native=nil;exe=nil;collectgarbage('collect')
    send{phase='preparing',progress=0.04}
    for _,entry in ipairs(W.list(assert(job.game:match('^(.*)/[^/]+$')))) do
        if not entry.directory and entry.name:lower():match('%.dll$') then
            W.copy(job.game:match('^(.*)/[^/]+$')..'/'..entry.name,job.root..'/engine/'..entry.name)
        end
    end
    materialize(job.files.smods,job.root..'/Mods/smods')
    materialize(job.files.mod,job.root..'/Mods/WorldLine')
    local manifest=assert(JSON.decode(assert(W.read(job.root..'/Mods/WorldLine/WorldLine.json'))))
    assert(manifest.id=='WorldLine' and W.attributes(job.root..'/Mods/WorldLine/main.lua'),
        'Renderer WorldLine manifest or entry point is missing')
    W.write(job.root..'/job.json',assert(Codec.encode({plan=job.plan,output=job.output,profiles=job.profiles,
        pool=job.pool,language=job.language,identity=job.identity,root=job.root,flags=job.flags},JSON)))
    assert(not cancelled_now(),'Export cancelled')
    send{phase='starting',progress=0.08}
    process=W.spawn(job.root..'/engine/WorldLineRender.exe',job.root..'/engine',{
        APPDATA=job.root..'/appdata',LOCALAPPDATA=job.root..'/localappdata',TEMP=job.root..'/temp',TMP=job.root..'/temp',
        LOVELY_MOD_DIR=job.root..'/Mods',WORLDLINE_RENDER_JOB=job.root},job.key)
    local started,last,notified=love.timer.getTime(),'',false
    while true do
        if cancelled_now() and not notified then W.write(job.root..'/cancel','cancel');notified=true end
        local bytes=W.read(job.root..'/status.json')
        if bytes and bytes~=last then
            local parsed_ok,status=pcall(JSON.decode,bytes)
            if parsed_ok and type(status)=='table' then
                last=bytes
                if status.phase=='done' or status.phase=='error' or status.phase=='cancelled' then terminal=status;break end
                send(status)
            end
        end
        local exited,code=W.exited(process)
        if exited then error('Render process stopped without completing (code '..tostring(code)..')') end
        assert(last~='' or love.timer.getTime()-started<90,'Video renderer did not start; check the private render log')
        assert(love.timer.getTime()-started<7200,'Background export timed out')
        if notified then
            job.cancel_at=job.cancel_at or love.timer.getTime()
            if love.timer.getTime()-job.cancel_at>10 then break end
        end
        love.timer.sleep(0.05)
    end
end,debug.traceback)
if process then
    local exited=W.exited(process)
    W.close(process,not exited)
end
if cancelled or terminal and (terminal.phase=='done' or terminal.phase=='cancelled') then
    if cancelled or terminal.phase=='cancelled' then W.remove_file(job.output..'.partial.mp4') end
    pcall(W.clean_job,job.root,job.key)
end
if cancelled then send{phase='cancelled',progress=0}
elseif not ok then send{phase='error',error=tostring(err)}
elseif terminal then send(terminal) end

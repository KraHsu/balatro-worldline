-- Bounded reads through Steamodded's filesystem, including mounted ZIP mods.
local Files={}
function Files.new(fs,roots)
    return {fs=fs,pending=roots,files={mod={},smods={}},bytes=0,count=0,visited={}}
end
function Files.step(state,limit)
    for _=1,limit or 6 do
        local entry=table.remove(state.pending)
        if not entry then return true,state.files end
        local key=entry.kind..':'..entry.relative
        assert(not state.visited[key],'Repeated renderer source path')
        state.visited[key]=true
        local path=entry.root..(entry.relative=='' and '' or '/'..entry.relative)
        local info=assert(state.fs.getInfo(path),'Missing renderer source: '..path)
        if info.type=='directory' then
            assert(#entry.relative<1024,'Renderer source nesting is too deep')
            for _,name in ipairs(state.fs.getDirectoryItems(path)) do
                assert(name~='.' and name~='..' and not name:find('[/\\]'),'Invalid renderer source name')
                if name~='.git' then state.pending[#state.pending+1]={kind=entry.kind,root=entry.root,
                    relative=entry.relative=='' and name or entry.relative..'/'..name} end
            end
        elseif info.type=='file' then
            local bytes=assert(state.fs.read(path),'Cannot read renderer source: '..path)
            state.bytes,state.count=state.bytes+#bytes,state.count+1
            assert(state.bytes<=32*1024*1024 and state.count<=4000,'Renderer source exceeds its size limit')
            state.files[entry.kind][entry.relative]=bytes
        else error('Unsupported renderer source: '..path) end
    end
    return false
end
return Files

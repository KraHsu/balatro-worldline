-- Small ZIP reader/writer for a private render bootstrap. Never extracts files.
local Zip={}
local function u16(s,p) local a,b=s:byte(p,p+1);assert(b,'Truncated ZIP');return a+b*256 end
local function u32(s,p) return u16(s,p)+u16(s,p+2)*65536 end
local function p16(n) return string.char(n%256,math.floor(n/256)%256) end
local function p32(n) return p16(n%65536)..p16(math.floor(n/65536)) end
function Zip.engine(source)
    local e
    for p=#source-21,math.max(1,#source-65557),-1 do
        if source:sub(p,p+3)=='PK\5\6' and p+21+u16(source,p+20)==#source then e=p;break end
    end
    assert(e,'Missing game archive')
    local prefix=e-1-u32(source,e+12)-u32(source,e+16)
    local at=prefix+u32(source,e+16)+1;local first=#source
    for _=1,u16(source,e+10) do
        assert(source:sub(at,at+3)=='PK\1\2','Invalid game archive')
        first=math.min(first,prefix+u32(source,at+42))
        at=at+46+u16(source,at+28)+u16(source,at+30)+u16(source,at+32)
    end
    assert(first>0 and source:sub(1,2)=='MZ','Unsupported game executable')
    return source:sub(1,first)
end
function Zip.read(source,name,decompress)
    local eocd
    for p=#source-21,math.max(1,#source-65557),-1 do
        if source:sub(p,p+3)=='PK\5\6' and p+21+u16(source,p+20)==#source then eocd=p;break end
    end
    assert(eocd and u16(source,eocd+4)==0 and u16(source,eocd+6)==0,'Unsupported game archive')
    local size,offset=u32(source,eocd+12),u32(source,eocd+16)
    local prefix=eocd-1-size-offset
    local at=prefix+offset+1
    for _=1,u16(source,eocd+10) do
        assert(source:sub(at,at+3)=='PK\1\2','Invalid game directory')
        local fn,extra,comment=u16(source,at+28),u16(source,at+30),u16(source,at+32)
        if source:sub(at+46,at+45+fn)==name then
            local method,n=u16(source,at+10),u32(source,at+20)
            local local_at=prefix+u32(source,at+42)+1
            assert(source:sub(local_at,local_at+3)=='PK\3\4','Invalid game file')
            local start=local_at+30+u16(source,local_at+26)+u16(source,local_at+28)
            local bytes=source:sub(start,start+n-1)
            assert(#bytes==n,'Truncated game file')
            if method==0 then return bytes end
            assert(method==8 and decompress,'Unsupported game compression')
            return decompress(bytes)
        end
        at=at+46+fn+extra+comment
    end
    error('Missing game file: '..name)
end
function Zip.append(prefix,files,crc)
    local names={} for name in pairs(files) do names[#names+1]=name end table.sort(names)
    local local_parts,directory={},{}
    local offset=#prefix
    for _,name in ipairs(names) do
        local bytes=files[name];local checksum=crc(bytes)
        local header='PK\3\4'..p16(20)..p16(0)..p16(0)..p16(0)..p16(33)..p32(checksum)
            ..p32(#bytes)..p32(#bytes)..p16(#name)..p16(0)..name
        local_parts[#local_parts+1]=header..bytes
        directory[#directory+1]='PK\1\2'..p16(20)..p16(20)..p16(0)..p16(0)..p16(0)..p16(33)
            ..p32(checksum)..p32(#bytes)..p32(#bytes)..p16(#name)..p16(0)..p16(0)..p16(0)..p16(0)
            ..p32(0)..p32(offset)..name
        offset=offset+#header+#bytes
    end
    local dir=table.concat(directory)
    return prefix..table.concat(local_parts)..dir..'PK\5\6'..p16(0)..p16(0)..p16(#names)..p16(#names)
        ..p32(#dir)..p32(offset)..p16(0)
end
return Zip

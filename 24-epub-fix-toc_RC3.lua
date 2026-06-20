--24-epub-fix-toc.lua RC3
--PocketBook / KOReader: fix epub toc.ncx spine/navpoint mismatch
--
-- RC3 CHANGES vs RC2:
--   * Fast pre-check via "unzip -p" (reads single file from zip, NO temp dir)
--   * Full extraction to /tmp only when spine/ncx count MISMATCH is detected
--   * Supports both STORED and DEFLATE-compressed NCX entries via ffi/zlib

local logger = require("logger")
local TAG = "epub-fix-toc"
local bit  = require("bit")
local band, bxor, rshift = bit.band, bit.bxor, bit.rshift
local ffi  = require("ffi")

logger.info(TAG .. ": *** PATCH LOADING ***")

local DocumentRegistry = require("document/documentregistry")
local orig_openDocument = DocumentRegistry.openDocument

-- ============================================================
-- zlib via ffi
-- ============================================================
local zlib
pcall(function()
    ffi.cdef[[
        typedef unsigned long uLong;
        typedef unsigned char Byte;
        int compress2(Byte* dest, uLong* destLen,
                      const Byte* source, uLong sourceLen, int level);
    ]]
    zlib = ffi.load("z")
end)

local function zlib_compress(data)
    if not zlib then return nil end
    local src_len  = #data
    local dst_len  = ffi.new("unsigned long[1]", src_len + src_len/100 + 13)
    local dst_buf  = ffi.new("uint8_t[?]", dst_len[0])
    local src_buf  = ffi.new("uint8_t[?]", src_len, data)
    local rc = zlib.compress2(dst_buf, dst_len, src_buf, src_len, 6)
    if rc ~= 0 then return nil end
    local zlib_out = ffi.string(dst_buf, dst_len[0])
    return zlib_out:sub(3, -5)
end

-- ============================================================
-- utils
-- ============================================================
local function sh(cmd)    return os.execute(cmd) end
local function safe(s)    return s:gsub("'", "'\\''" ) end
local function popen1(cmd)
    local h = io.popen(cmd); if not h then return nil end
    local r = h:read("*l"); h:close()
    return (r and r ~= "") and r or nil
end
local function popen_all(cmd)
    local h = io.popen(cmd); if not h then return nil end
    local r = h:read("*a"); h:close()
    return (r and r ~= "") and r or nil
end
local function read_file(path)
    local f = io.open(path, "rb"); if not f then return nil end
    local s = f:read("*a"); f:close(); return s
end
local function write_file(path, data)
    local f = io.open(path, "wb"); if not f then return false end
    f:write(data); f:close(); return true
end
local function make_tempdir(filepath)
    local name = (filepath:match("[^/]+$") or "epub"):gsub("[^%w%._%-]","_")
    return "/tmp/epuftoc_" .. name
end

-- ============================================================
-- RC3: read single zip entry without extracting to disk
-- ============================================================
local function read_zip_entry(zipfile, entry)
    local cmd = "unzip -p '" .. safe(zipfile) .. "' '" .. safe(entry) .. "' 2>/dev/null"
    return popen_all(cmd)
end

local function find_zip_entry(zipfile, pattern)
    local cmd = "unzip -Z1 '" .. safe(zipfile) .. "' 2>/dev/null | grep '" .. pattern .. "' | head -1"
    return popen1(cmd)
end

-- ============================================================
-- CRC32
-- ============================================================
local crc32_table
local function build_crc32()
    crc32_table = {}
    for i = 0,255 do
        local c = i
        for _ = 1,8 do
            if band(c,1)==1 then c = bxor(0xEDB88320, rshift(c,1))
            else c = rshift(c,1) end
        end
        crc32_table[i] = c
    end
end
local function crc32(data)
    if not crc32_table then build_crc32() end
    local crc = 0xFFFFFFFF
    for i = 1,#data do
        crc = bxor(crc32_table[band(bxor(crc, data:byte(i)), 0xFF)], rshift(crc,8))
    end
    return band(bxor(crc, 0xFFFFFFFF), 0xFFFFFFFF)
end

-- ============================================================
-- ZIP patch helpers
-- ============================================================
local function u16(s,p) return s:byte(p) + s:byte(p+1)*256 end
local function u32(s,p)
    return s:byte(p) + s:byte(p+1)*256 + s:byte(p+2)*65536 + s:byte(p+3)*16777216
end
local function le16(n) return string.char(band(n,0xFF), band(rshift(n,8),0xFF)) end
local function le32(n)
    return string.char(band(n,0xFF), band(rshift(n,8),0xFF),
                       band(rshift(n,16),0xFF), band(rshift(n,24),0xFF))
end
local PK34,PK12,PK56 = "PK\3\4","PK\1\2","PK\5\6"

local function cd_entry_len(s, p)
    if p + 45 > #s then return nil end
    local fnl = u16(s, p+28)
    local exl = u16(s, p+30)
    local cml = u16(s, p+32)
    return 46 + fnl + exl + cml
end

local function patch_zip_entry(zippath, entry_name, new_data)
    local zb = read_file(zippath)
    if not zb then logger.warn(TAG..": cannot read zip"); return false end

    local fp, scan = nil, 1
    while true do
        local p = zb:find(PK34, scan, true)
        if not p then break end
        local fnl = u16(zb, p+26)
        if p+30+fnl-1 <= #zb and zb:sub(p+30, p+30+fnl-1) == entry_name then
            fp = p; break
        end
        scan = p+1
    end
    if not fp then
        logger.warn(TAG..": entry '"..entry_name.."' not found"); return false
    end

    local method  = u16(zb, fp+8)
    local old_csz = u32(zb, fp+18)
    local old_usz = u32(zb, fp+22)
    local fnl     = u16(zb, fp+26)
    local exl     = u16(zb, fp+28)
    local dstart  = fp + 30 + fnl + exl

    logger.info(TAG..": entry '"..entry_name.."' method="..method
        .." csz="..old_csz.." usz="..old_usz)

    local new_usz  = #new_data
    local new_csz, new_payload, new_method
    if method == 0 then
        new_method  = 0
        new_payload = new_data
        new_csz     = new_usz
    elseif method == 8 then
        new_payload = zlib_compress(new_data)
        if not new_payload then
            logger.warn(TAG..": zlib not available, trying STORED fallback")
            new_method  = 0
            new_payload = new_data
            new_csz     = new_usz
        else
            new_method = 8
            new_csz    = #new_payload
        end
    else
        logger.warn(TAG..": unknown method "..method.." — skip"); return false
    end

    local nc    = crc32(new_data)
    local fp0   = fp - 1
    local delta = new_csz - old_csz
    local fname_b = zb:sub(fp+30, fp+30+fnl-1)
    local extra_b = zb:sub(fp+30+fnl, dstart-1)

    logger.info(TAG..": new_csz="..new_csz.." delta="..delta)

    local new_lhdr = PK34
        .. zb:sub(fp+4,  fp+5)
        .. zb:sub(fp+6,  fp+7)
        .. le16(new_method)
        .. zb:sub(fp+10, fp+13)
        .. le32(nc)
        .. le32(new_csz)
        .. le32(new_usz)
        .. le16(fnl) .. le16(#extra_b)
        .. fname_b .. extra_b

    local before = zb:sub(1, fp-1)
    local after  = zb:sub(fp + 30 + fnl + exl + old_csz)

    if delta ~= 0 then
        local parts, cp = {}, 1
        while cp <= #after do
            local p2 = after:find(PK12, cp, true)
            if not p2 then
                parts[#parts+1] = after:sub(cp)
                break
            end
            parts[#parts+1] = after:sub(cp, p2-1)
            local clen = cd_entry_len(after, p2)
            if not clen then
                parts[#parts+1] = after:sub(p2)
                break
            end
            local lh = u32(after, p2+42)
            if lh > fp0 then
                parts[#parts+1] = after:sub(p2, p2+41) .. le32(lh+delta)
                parts[#parts+1] = after:sub(p2+46, p2+clen-1)
            else
                parts[#parts+1] = after:sub(p2, p2+clen-1)
            end
            cp = p2 + clen
        end
        after = table.concat(parts)

        local ep = after:find(PK56, 1, true)
        if ep and ep+19 <= #after then
            local old_cdo = u32(after, ep+16)
            after = after:sub(1,ep+15) .. le32(old_cdo+delta) .. after:sub(ep+20)
        end
    end

    local scan2 = 1
    while true do
        local p2 = after:find(PK12, scan2, true)
        if not p2 then break end
        local clen = cd_entry_len(after, p2)
        if clen and u32(after, p2+42) == fp0 then
            after = after:sub(1, p2+9)
                .. le16(new_method)
                .. after:sub(p2+12, p2+15)
                .. le32(nc)
                .. le32(new_csz)
                .. le32(new_usz)
                .. after:sub(p2+28)
            logger.info(TAG..": CD entry updated at offset "..fp0)
            break
        end
        scan2 = p2 + (clen or 1)
    end

    if write_file(zippath, before .. new_lhdr .. new_payload .. after) then
        return new_method == 8 and "deflate" or "stored"
    end
    return false
end

-- ============================================================
-- Parse spine hrefs from OPF
-- ============================================================
local function get_spine_hrefs(opf)
    local manifest = {}
    for attrs in opf:gmatch("<item([^>]+)/?>") do
        local id   = attrs:match('id="([^"]+)"')
        local href = attrs:match('href="([^"]+)"')
        if id and href then manifest[id] = href end
    end
    local spine_block = opf:match("<spine[^>]*>(.-)</spine>")
    local spine = {}
    if spine_block then
        for idref in spine_block:gmatch('idref="([^"]+)"') do
            if manifest[idref] then spine[#spine+1] = manifest[idref] end
        end
    end
    return spine
end

local function parse_ncx_labels(ncx)
    local map = {}
    for block in ncx:gmatch("<navPoint[^>]*>(.-)</navPoint>") do
        local src   = block:match('<content[^>]+src="([^"#]+)')
        local label = block:match("<text>%s*(.-)%s*</text>")
        if src and label then
            label = label:gsub("<[^>]+>","")
            label = label:gsub("&amp;","&"):gsub("&lt;","<"):gsub("&gt;",">")
            label = label:match("^%s*(.-)%s*$")
            if label ~= "" then map[src] = label end
        end
    end
    return map
end

local function parse_guide_titles(opf)
    local map = {}
    local guide = opf:match("<guide>(.-)</guide>")
    if not guide then return map end
    for attrs in guide:gmatch("<reference([^>]+)/?>") do
        local href  = attrs:match('href="([^"#]+)')
        local title = attrs:match('title="([^"]*)"')
        if href and title and title:match("%S") then
            local bare = href:match("[^/]+$") or href
            if not map[bare] then map[bare] = title end
        end
    end
    return map
end

local function get_xhtml_title(path)
    local s = read_file(path); if not s then return nil end
    local t = s:match("<[Hh][1-3][^>]*>%s*(.-)%s*</[Hh][1-3]>")
            or s:match("<title[^>]*>%s*(.-)%s*</title>")
    if not t then return nil end
    t = t:gsub("<[^>]+>","")
    t = t:gsub("&amp;","&"):gsub("&lt;","<"):gsub("&gt;",">"):gsub("&quot;",'"')
    t = t:gsub("&#(%d+);", function(nn) return string.char(tonumber(nn) or 63) end)
    t = t:match("^%s*(.-)%s*$")
    return (#t >= 2) and t or nil
end

local function build_ncx(title, uid, navpoints)
    local function esc(s)
        return (s or ""):gsub("&","&amp;"):gsub("<","&lt;"):gsub(">","&gt;")
    end
    local items = {}
    for i, np in ipairs(navpoints) do
        items[i] = ('  <navPoint id="navPoint-%d" playOrder="%d">\n'
                 .. '    <navLabel><text>%s</text></navLabel>\n'
                 .. '    <content src="%s"/>\n'
                 .. '  </navPoint>'):format(i,i, esc(np.label), esc(np.src))
    end
    return ('<?xml version="1.0" encoding="utf-8"?>\n'
         .. '<!DOCTYPE ncx PUBLIC "-//NISO//DTD ncx 2005-1//EN" '
         .. '"http://www.daisy.org/z3986/2005/ncx-2005-1.dtd">\n'
         .. '<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">\n'
         .. '<head>\n'
         .. '  <meta name="dtb:uid" content="%s"/>\n'
         .. '  <meta name="dtb:depth" content="1"/>\n'
         .. '  <meta name="dtb:totalPageCount" content="0"/>\n'
         .. '  <meta name="dtb:maxPageNumber" content="0"/>\n'
         .. '</head>\n'
         .. '<docTitle><text>%s</text></docTitle>\n'
         .. '<navMap>\n%s\n</navMap>\n'
         .. '</ncx>\n'):format(esc(uid), esc(title), table.concat(items,"\n"))
end

local function fast_precheck(file)
    local opf_entry = find_zip_entry(file, "content\\.opf")
    local ncx_entry = find_zip_entry(file, "toc\\.ncx")
    if not opf_entry or not ncx_entry then
        logger.info(TAG..": opf/ncx not found in zip — skip")
        return nil
    end

    local opf = read_zip_entry(file, opf_entry)
    local ncx = read_zip_entry(file, ncx_entry)
    if not opf or not ncx then
        logger.warn(TAG..": failed to read opf/ncx via unzip -p")
        return nil
    end

    return opf, ncx, opf_entry, ncx_entry
end

DocumentRegistry.openDocument = function(self, file, provider)
    if not (file and file:lower():match("%.epub$")) then
        return orig_openDocument(self, file, provider)
    end

    logger.info(TAG..": === "..file.." ===")

    local opf, ncx, opf_entry, ncx_entry = fast_precheck(file)
    if not opf then
        return orig_openDocument(self, file, provider)
    end

    local spine = get_spine_hrefs(opf)
    local ncx_count = 0
    for _ in ncx:gmatch("<navPoint") do ncx_count = ncx_count + 1 end

    logger.info(TAG..": spine="..#spine.." ncx="..ncx_count)

    if #spine == ncx_count then
        logger.info(TAG..": TOC ok — skip (no extraction)")
        return orig_openDocument(self, file, provider)
    end

    logger.info(TAG..": MISMATCH — extracting to /tmp for xhtml title lookup")

    local sf   = safe(file)
    local tdir = make_tempdir(file)
    local stdir = safe(tdir)

    sh("rm -rf '"   ..stdir.."'")
    sh("mkdir -p '" ..stdir.."'")
    local rc = sh("unzip -o '"..sf.."' -d '"..stdir.."' 2>/dev/null")
    if rc ~= 0 then
        logger.warn(TAG..": unzip failed")
        sh("rm -rf '"..stdir.."'")
        return orig_openDocument(self, file, provider)
    end

    local opf_path = popen1("find '"..stdir.."' -name 'content.opf' -type f 2>/dev/null | head -1")
    local opf_dir  = opf_path and (opf_path:match("^(.*)/[^/]+$") or tdir) or tdir

    local book_title = (opf:match("<dc:title[^>]*>(.+)</dc:title>") or "Unknown"):match("^%s*(.-)%s*$")
    local uid        = (opf:match("<dc:identifier[^>]*>(.+)</dc:identifier>") or "uid"):match("^%s*(.-)%s*$")

    local ncx_labels   = parse_ncx_labels(ncx)
    local guide_titles = parse_guide_titles(opf)

    local navpoints = {}
    for _, href in ipairs(spine) do
        local bare  = href:match("^([^#]+)") or href
        local fname = bare:match("[^/]+$") or bare

        local label = ncx_labels[fname] or ncx_labels[bare]
        if not label then label = guide_titles[fname] or guide_titles[bare] end
        if not label then label = get_xhtml_title(opf_dir.."/"..bare) end
        if not label then label = get_xhtml_title(tdir.."/"..bare) end
        if not label then
            if fname:match("^title") then label = book_title
            elseif fname:match("^toc") then label = "\208\161\208\190\208\180\208\181\209\128\208\182\208\176\208\189\208\184\208\181"
            else label = fname:match("^(.+)%.xhtml?$") or fname end
        end

        navpoints[#navpoints+1] = { src=fname, label=label }
        logger.info(TAG..": navpoint"..#navpoints.." "..fname.." => "..label)
    end

    local new_ncx = build_ncx(book_title, uid, navpoints)
    logger.info(TAG..": new_ncx="..#new_ncx.." bytes")

    local backup = file..".toc_backup"
    local bf = io.open(backup,"rb")
    if not bf then
        write_file(backup, ncx)
        logger.info(TAG..": backup -> "..backup)
    else
        bf:close()
    end

    logger.info(TAG..": patching '"..ncx_entry.."'")

    local ok = patch_zip_entry(file, ncx_entry, new_ncx)

    sh("rm -rf '"..stdir.."'")

    if ok then
        logger.info(TAG..": patched ("..tostring(ok)..") OK")
    else
        logger.warn(TAG..": patch failed — opening original as-is")
    end

    return orig_openDocument(self, file, provider)
end

logger.info(TAG .. ": *** PATCH LOADED ***")

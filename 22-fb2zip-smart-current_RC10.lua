-- 22-fb2zip-smart RC10: .fb2.zip -> распаковка во /tmp, прогресс по zip.
-- Исправлен краш при фоновом извлечении обложек (coverbrowser).
local logger = require("logger")
local TAG = "fb2zip-smart"
logger.info(TAG .. ": *** PATCH LOADING ***")
pcall(function() os.setlocale("C.UTF-8", "all") end)

local ffi = require("ffi")
local unpack = table.unpack or unpack

local DocumentRegistry = require("document/documentregistry")
local orig_openDocument = DocumentRegistry.openDocument
local Document = require("document/document")
local orig_close = Document.close
local Utf8Proc = require("ffi/utf8proc")

local function n(s)
    if type(s) ~= "string" then return s end
    if Utf8Proc and Utf8Proc.normalize_NFC then return Utf8Proc.normalize_NFC(s) end
    return s
end

-- маппинг: временный путь fb2 -> реальный путь zip (для DocSettings)
local _fb2map = {}

-- ============================ утилиты ============================
local function read_file(path)
    local f = io.open(path, "rb"); if not f then return nil end
    local s = f:read("*a"); f:close(); return s
end
local function write_file(path, data)
    local f = io.open(path, "wb"); if not f then return false end
    f:write(data); f:close(); return true
end
local function u16(s, p) return s:byte(p) + s:byte(p + 1) * 256 end
local function u32(s, p) return s:byte(p) + s:byte(p + 1) * 256 + s:byte(p + 2) * 65536 + s:byte(p + 3) * 16777216 end

local function find_fb2_file_simple(directory)
    local cmd = "find " .. directory:gsub("'", "'\\''") .. " -name '*.fb2' -type f 2>/dev/null | head -1"
    local handle = io.popen(cmd)
    if not handle then return nil end
    local result = handle:read("*l"); handle:close()
    if result and result ~= "" then return result end
    return nil
end

local function validate_fb2(path)
    local f = io.open(path, "rb"); if not f then return false, 0 end
    local head = f:read(512)
    local size = f:seek("end") or 0
    f:close()
    if not head or size < 200 then return false, size end
    local h = head:gsub("^\239\187\191", ""):match("^%s*(.*)")
    if h:find("<?xml", 1, true) or h:find("<FictionBook", 1, true) then return true, size end
    return false, size
end

-- ============================ zlib (raw inflate) ============================
local zlib
pcall(function()
    ffi.cdef[[
    typedef struct z_stream_s {
        const unsigned char *next_in; unsigned int avail_in; unsigned long total_in;
        unsigned char *next_out; unsigned int avail_out; unsigned long total_out;
        const char *msg; void *state; void *zalloc; void *zfree; void *opaque;
        int data_type; unsigned long adler; unsigned long reserved;
    } z_stream;
    const char* zlibVersion(void);
    int inflateInit2_(z_stream*, int, const char*, int);
    int inflate(z_stream*, int);
    int inflateEnd(z_stream*);
    ]]
    zlib = ffi.load("z")
end)

local function raw_inflate(comp, expected)
    if not zlib or not comp or #comp == 0 then return nil end
    local ok, res = pcall(function()
        local strm = ffi.new("z_stream")
        local src = ffi.new("uint8_t[?]", #comp); ffi.copy(src, comp, #comp)
        strm.next_in = src; strm.avail_in = #comp
        local cap = (expected and expected > 0) and (expected + 64) or (#comp * 3 + 4096)
        local dst = ffi.new("uint8_t[?]", cap); strm.next_out = dst; strm.avail_out = cap
        local ver = ffi.string(zlib.zlibVersion())
        if zlib.inflateInit2_(strm, -15, ver, ffi.sizeof("z_stream")) ~= 0 then return nil end
        local Z_OK, Z_STREAM_END, Z_NO_FLUSH = 0, 1, 0
        while true do
            local rc = zlib.inflate(strm, Z_NO_FLUSH)
            if rc == Z_STREAM_END then break end
            if rc ~= Z_OK then zlib.inflateEnd(strm); return nil end
            if strm.avail_out == 0 then
                local newcap = cap * 2; local ndst = ffi.new("uint8_t[?]", newcap)
                ffi.copy(ndst, dst, cap); dst = ndst; strm.next_out = dst + cap
                strm.avail_out = newcap - cap; cap = newcap
            elseif strm.avail_in == 0 then break end
        end
        local out = ffi.string(dst, tonumber(strm.total_out)); zlib.inflateEnd(strm); return out
    end)
    if ok then return res end
    return nil
end

local function extract_fb2_via_ffi(zippath)
    local zb = read_file(zippath)
    if not zb or #zb < 22 then return nil end
    local scan, eocd = 1, nil
    while true do local p = zb:find("PK\5\6", scan, true); if not p then break end; eocd = p; scan = p + 1 end
    if not eocd then return nil end
    local cd_entries = u16(zb, eocd + 10); local cd_offset = u32(zb, eocd + 16)
    if cd_offset == 0xFFFFFFFF then return nil end
    local p = cd_offset + 1
    for _ = 1, cd_entries do
        if p + 46 > #zb then break end
        if zb:sub(p, p + 3) ~= "PK\1\2" then break end
        local method = u16(zb, p + 10); local comp_size = u32(zb, p + 20); local uncomp_size = u32(zb, p + 24)
        local fname_len = u16(zb, p + 28); local extra_len = u16(zb, p + 30); local comment_len = u16(zb, p + 32)
        local local_off = u32(zb, p + 42); local fname = zb:sub(p + 46, p + 46 + fname_len - 1)
        if fname:lower():match("%.fb2$") then
            local lp = local_off + 1
            if zb:sub(lp, lp + 3) ~= "PK\3\4" then return nil end
            local l_fname_len = u16(zb, lp + 26); local l_extra_len = u16(zb, lp + 28)
            local data_start = lp + 30 + l_fname_len + l_extra_len
            local comp = zb:sub(data_start, data_start + comp_size - 1)
            if method == 0 then return comp
            elseif method == 8 then return raw_inflate(comp, uncomp_size) end
            return nil
        end
        p = p + 46 + fname_len + extra_len + comment_len
    end
    return nil
end

-- ============================ перехват DocSettings ============================
local ok_ds, DocSettings = pcall(require, "docsettings")
if ok_ds and DocSettings and type(DocSettings.open) == "function" then
    local orig_ds_open = DocSettings.open
    DocSettings.open = function(a, b, ...)
        local self_arg, file_arg, rest
        if a == DocSettings then self_arg, file_arg, rest = a, b, { ... }
        else self_arg, file_arg, rest = nil, a, { b, ... } end
        if type(file_arg) == "string" then
            local m = _fb2map[file_arg]
            if m then file_arg = m end
        end
        if self_arg then return orig_ds_open(self_arg, file_arg, unpack(rest))
        else return orig_ds_open(file_arg, unpack(rest)) end
    end
    logger.info(TAG .. ": DocSettings.open hooked (progress keyed by zip path)")
else
    logger.warn(TAG .. ": DocSettings.open not hooked (progress may not persist)")
end

-- ============================ перехват открытия ============================
-- Кэш распакованных файлов (чтобы не распаковывать повторно)
local _zip_cache = {}

DocumentRegistry.openDocument = function(self, file, provider)
    if file and file:lower():match("%.fb2%.zip$") then
        local cached = _zip_cache[file]
        local tempdir, fb2_file

        if cached then
            tempdir = cached.tempdir
            fb2_file = cached.fb2_file
            local f = io.open(fb2_file, "r")
            if f then
                f:close()
                logger.info(TAG .. ": *** USING CACHED EXTRACTION: " .. fb2_file)
            else
                _zip_cache[file] = nil
                cached = nil
                logger.warn(TAG .. ": cached file missing, re-extracting")
            end
        end

        if not cached then
            logger.info(TAG .. ": *** DETECTED .fb2.zip: " .. n(file))
            local zip_hash = file:gsub("[^%w]", "_"):sub(1, 64)
            tempdir = "/tmp/fb2zip_" .. zip_hash
            os.execute("mkdir -p '" .. tempdir .. "'")
            local safe_file = file:gsub("'", "'\\''")

            os.execute("unzip -o '" .. safe_file .. "' -d '" .. tempdir .. "' >/dev/null 2>&1")
            local cand = find_fb2_file_simple(tempdir)
            if cand then
                local ok, size = validate_fb2(cand)
                logger.info(TAG .. ": unzip -o -> valid=" .. tostring(ok) .. " size=" .. size)
                if ok then fb2_file = cand end
            end
            if not fb2_file then
                local data = extract_fb2_via_ffi(file)
                if data then
                    local out = tempdir .. "/extracted.fb2"; write_file(out, data)
                    local ok, size = validate_fb2(out)
                    logger.info(TAG .. ": ffi inflate -> valid=" .. tostring(ok) .. " size=" .. size)
                    if ok then fb2_file = out end
                else logger.warn(TAG .. ": ffi inflate returned nothing") end
            end

            if fb2_file then
                logger.info(TAG .. ": *** USING EXTRACTED FILE: " .. fb2_file)
                _zip_cache[file] = {fb2_file = fb2_file, tempdir = tempdir}
            else
                logger.warn(TAG .. ": all extraction methods FAILED — opening original as-is")
                os.execute("rm -rf '" .. tempdir .. "'")
                return orig_openDocument(self, file, provider)
            end
        end

        _fb2map[fb2_file] = file
        -- Создаем новый документ. DocumentRegistry сам его зарегистрирует по пути fb2_file.
        local doc = orig_openDocument(self, fb2_file, provider)
        if doc then
            doc._fb2zip_alias = file
            doc._fb2zip_real  = fb2_file
            doc._fb2zip_tempdir = tempdir
            -- doc.file НЕ трогаем: DocumentRegistry должен видеть fb2_file для корректного закрытия
        else
            logger.warn(TAG .. ": orig_openDocument returned nil, cleaning up")
            _fb2map[fb2_file] = nil
            _zip_cache[file] = nil
            os.execute("rm -rf '" .. tempdir .. "'")
        end
        return doc
    end
    return orig_openDocument(self, file, provider)
end

-- ============================ закрытие/уборка ============================
Document.close = function(self)
    if self._fb2zip_tempdir then
        if self._fb2zip_real then _fb2map[self._fb2zip_real] = nil end
        if self._fb2zip_alias then
            _zip_cache[self._fb2zip_alias] = nil
        end
        logger.info(TAG .. ": Cleaning up tempdir: " .. self._fb2zip_tempdir)
        os.execute("rm -rf '" .. self._fb2zip_tempdir .. "'")
        self._fb2zip_alias = nil; self._fb2zip_real = nil; self._fb2zip_tempdir = nil
    end
    return orig_close(self)
end

logger.info(TAG .. ": *** PATCH LOADED SUCCESSFULLY ***")
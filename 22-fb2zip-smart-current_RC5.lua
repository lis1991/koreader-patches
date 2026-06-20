--22-fb2zip-smart-current.lua

--PocketBook: intercept .fb2.zip and extract, preserving reading progress

local logger = require("logger")
local TAG = "fb2zip-smart"

logger.info(TAG .. ": *** PATCH LOADING ***")

pcall(function() os.setlocale("C.UTF-8", "all") end)

local DocumentRegistry = require("document/documentregistry")
local orig_openDocument = DocumentRegistry.openDocument

local Document = require("document/document")
local orig_close = Document.close

local Utf8Proc = require("ffi/utf8proc")

local function n(s)
    if type(s) ~= "string" then
        return s
    end
    if Utf8Proc and Utf8Proc.normalize_NFC then
        return Utf8Proc.normalize_NFC(s)
    end
    return s
end

local function find_fb2_file_simple(directory)
    local cmd = "find " .. directory:gsub("'", "'\''") .. " -name '*.fb2' -type f 2>/dev/null | head -1"
    local handle = io.popen(cmd)
    if not handle then
        logger.error(TAG .. ": Failed to execute find command")
        return nil
    end
    local result = handle:read("*l")
    handle:close()
    if result and result ~= "" then
        return result
    end
    return nil
end

DocumentRegistry.openDocument = function(self, file, provider)
    if file and file:lower():match("%.fb2%.zip$") then
        logger.info(TAG .. ": *** DETECTED .fb2.zip: " .. n(file))

        local tempdir = "/tmp/fb2zip_" .. os.time()
        logger.info(TAG .. ": Creating tempdir: " .. tempdir)
        os.execute("mkdir -p '" .. tempdir .. "'")

        local safe_file = file:gsub("'", "'\''")
        local unzip_cmd = "unzip -o '" .. safe_file .. "' -d '" .. tempdir .. "' 2>&1"
        logger.info(TAG .. ": Running: " .. unzip_cmd)
        os.execute(unzip_cmd)

        local fb2_file = find_fb2_file_simple(tempdir)

        if fb2_file then
            logger.info(TAG .. ": *** USING EXTRACTED FILE: " .. fb2_file)

            local doc = orig_openDocument(self, fb2_file, provider)

            if doc then
                if type(self.openDocuments) == "table" then
                    self.openDocuments[file] = self.openDocuments[fb2_file]
                    logger.info(TAG .. ": Registry alias added: " .. file)
                end

                doc._fb2zip_real_file = fb2_file
                doc._fb2zip_alias     = file
                doc._fb2zip_tempdir   = tempdir

                doc.file = file
                logger.info(TAG .. ": doc.file remapped to: " .. file)
            else
                logger.warn(TAG .. ": orig_openDocument returned nil, cleaning up tempdir")
                os.execute("rm -rf '" .. tempdir .. "'")
            end

            return doc
        end

        logger.warn(TAG .. ": Failed to extract " .. file .. " - no .fb2 file found")
        os.execute("rm -rf '" .. tempdir .. "'")
        return orig_openDocument(self, file, provider)
    end

    return orig_openDocument(self, file, provider)
end

Document.close = function(self)
    if self._fb2zip_tempdir then
        if self._fb2zip_alias and type(DocumentRegistry.openDocuments) == "table" then
            DocumentRegistry.openDocuments[self._fb2zip_alias] = nil
            logger.info(TAG .. ": Registry alias removed: " .. self._fb2zip_alias)
        end

        if self._fb2zip_real_file then
            self.file = self._fb2zip_real_file
            logger.info(TAG .. ": doc.file restored to: " .. self._fb2zip_real_file)
        end

        logger.info(TAG .. ": Cleaning up tempdir: " .. self._fb2zip_tempdir)
        os.execute("rm -rf '" .. self._fb2zip_tempdir .. "'")

        self._fb2zip_alias     = nil
        self._fb2zip_real_file = nil
        self._fb2zip_tempdir   = nil
    end
    return orig_close(self)
end

logger.info(TAG .. ": *** PATCH LOADED SUCCESSFULLY ***")

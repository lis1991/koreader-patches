-- 9-clear-crashlog-on-exit.lua
--
-- PocketBook/KOReader: clear crash.log on clean exit (exit code 0).
-- If KOReader crashes, the log is preserved for diagnostics.
--
-- NOTE: prefix '9' — executed right before exit (per KOReader user-patches spec).

local logger = require("logger")
local TAG = "clear-crashlog"

local function get_crashlog_path()
    local candidates = {
        (os.getenv("KO_HOME") or "/mnt/ext1/.adds/koreader") .. "/crash.log",
        "./crash.log",
    }
    for _, path in ipairs(candidates) do
        local f = io.open(path, "r")
        if f then
            f:close()
            return path
        end
    end
    return nil
end

local function clear_crashlog()
    local path = get_crashlog_path()
    if not path then
        logger.info(TAG .. ": crash.log not found, nothing to clear")
        return
    end
    local f = io.open(path, "w")
    if f then
        f:close()
        logger.info(TAG .. ": crash.log cleared (" .. path .. ")")
    else
        logger.warn(TAG .. ": cannot open crash.log for writing: " .. path)
    end
end

clear_crashlog()

logger.info(TAG .. ": patch executed (pre-exit)")

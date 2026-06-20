-- 8-clear-crashlog-on-exit.lua
--
-- PocketBook/KOReader: clear crash.log on clean exit.
-- If KOReader crashes, the log is preserved for diagnostics.
--
-- NOTE: prefix '8' (before_exit) — more reliable than '9' on PocketBook v2026.03.
-- Phase '9' (on_exit) appears to run after the logger is already closed.

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

logger.info(TAG .. ": patch executed (before_exit)")

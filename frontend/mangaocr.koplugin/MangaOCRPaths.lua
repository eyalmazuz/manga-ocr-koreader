local DataStorage = require("datastorage")
local ffiutil = require("ffi/util")

local Paths = {}

function Paths.getPluginDirectory()
    local source = debug.getinfo(1, "S").source
    if source:sub(1, 1) ~= "@" then
        error("Manga OCR: could not determine the plugin directory")
    end

    local directory = source:match("^@(.*)/[^/]+$")
    return ffiutil.realpath(directory) or directory
end

function Paths.getDataDirectory()
    return DataStorage:getDataDir() .. "/mangaocr"
end

function Paths.getWorkerPath()
    return os.getenv("MANGAOCR_WORKER") or (Paths.getPluginDirectory() .. "/mangaocr-worker")
end

return Paths

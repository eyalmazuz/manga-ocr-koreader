-- Lightweight KOReader dependency adapters for running the plugin's pure Lua
-- specs outside a complete KOReader checkout. Production code never loads this
-- file; Busted loads it explicitly with --helper.

local json = require("dkjson")
local lfs = require("lfs")
local json_null = {}

local function testDigest(value)
    value = tostring(value or "")
    local first = 5381
    local second = 52711
    for index = 1, #value do
        local byte = value:byte(index)
        first = (first * 33 + byte) % 2147483647
        second = (second * 65599 + byte) % 2147483629
    end
    return string.format(
        "%08x%08x%08x%08x",
        first,
        second,
        (first + second) % 2147483647,
        (first * 17 + second * 31) % 2147483647
    )
end

package.preload.rapidjson = function()
    return {
        decode = function(content)
            local value, _, decode_error = json.decode(content, 1, json_null)
            if decode_error then
                error(decode_error)
            end
            return value
        end,
        encode = json.encode,
    }
end

package.preload.util = function()
    return {
        cleanupSelectedText = function(text)
            return text:gsub("^%s+", ""):gsub("%s+$", "")
        end,
        makePath = function(path)
            return lfs.mkdir(path)
        end,
        partialMD5 = testDigest,
    }
end

package.preload["ffi/sha2"] = function()
    return {
        md5 = testDigest,
    }
end

package.preload["libs/libkoreader-lfs"] = function()
    return lfs
end

package.preload.MangaOCRPaths = function()
    return {
        getDataDirectory = function()
            return "/tmp/mangaocr-tests"
        end,
    }
end

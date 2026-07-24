local Paths = require("MangaOCRPaths")
local rapidjson = require("rapidjson")
local sha2 = require("ffi/sha2")
local util = require("util")
local lfs = require("libs/libkoreader-lfs")

local Storage = {}
Storage.__index = Storage

local ZIP_EOCD = "PK\005\006"
local ZIP_MAX_COMMENT = 65535

local function readFile(path)
    local file = io.open(path, "rb")
    if not file then
        return nil
    end
    local content = file:read("*all")
    file:close()
    return content
end

local function isFile(path)
    return path and lfs.attributes(path, "mode") == "file"
end

local function decodeJSON(content)
    local ok, value = pcall(rapidjson.decode, content)
    if not ok or type(value) ~= "table" then
        return nil
    end
    return value
end

function Storage:new(options)
    options = options or {}
    return setmetatable({
        root = options.root or Paths.getDataDirectory(),
    }, self)
end

function Storage:isSupported(path)
    if type(path) ~= "string" then
        return false
    end
    local extension = path:match("%.([^./]+)$")
    extension = extension and extension:lower()
    return extension == "cbz" or extension == "zip"
end

-- Parse an EOCD record from the tail of a ZIP. This is deliberately independent
-- of an archiver so Rakuyomi's origin survives both RAM and persistent downloads.
function Storage.zipCommentFromTail(data)
    if type(data) ~= "string" or #data < 22 then
        return nil, "ZIP end record not found"
    end

    for index = #data - 21, 1, -1 do
        if data:sub(index, index + 3) == ZIP_EOCD then
            local low = data:byte(index + 20)
            local high = data:byte(index + 21)
            local comment_length = low + high * 256
            if index + 21 + comment_length == #data then
                return data:sub(index + 22, index + 21 + comment_length)
            end
        end
    end

    return nil, "ZIP end record not found"
end

function Storage.getZipComment(path)
    local file, open_error = io.open(path, "rb")
    if not file then
        return nil, open_error
    end

    local size = file:seek("end")
    if not size then
        file:close()
        return nil, "Could not determine ZIP size"
    end

    local read_size = math.min(size, ZIP_MAX_COMMENT + 22)
    file:seek("set", size - read_size)
    local data = file:read(read_size)
    file:close()
    if not data then
        return nil, "Could not read ZIP end record"
    end

    return Storage.zipCommentFromTail(data)
end

function Storage.parseRakuyomiOriginComment(comment)
    if type(comment) ~= "string" or comment == "" then
        return nil
    end
    local value = decodeJSON(comment)
    if not value
            or type(value.source_id) ~= "string" or value.source_id == ""
            or type(value.manga_id) ~= "string" or value.manga_id == ""
            or type(value.chapter_id) ~= "string" or value.chapter_id == "" then
        return nil
    end

    return {
        source_id = value.source_id,
        manga_id = value.manga_id,
        chapter_id = value.chapter_id,
    }
end

function Storage.getRakuyomiOrigin(path)
    local comment = Storage.getZipComment(path)
    return Storage.parseRakuyomiOriginComment(comment)
end

function Storage.keyForOrigin(origin)
    if type(origin) ~= "table" then
        return nil
    end
    local source_id = origin.source_id
    local manga_id = origin.manga_id
    local chapter_id = origin.chapter_id
    if type(source_id) ~= "string"
            or type(manga_id) ~= "string"
            or type(chapter_id) ~= "string" then
        return nil
    end

    return "rakuyomi-" .. sha2.md5(table.concat({
        "rakuyomi",
        source_id,
        manga_id,
        chapter_id,
    }, "\0"))
end

function Storage:keyForFile(path)
    local origin = Storage.getRakuyomiOrigin(path)
    local origin_key = Storage.keyForOrigin(origin)
    if origin_key then
        return origin_key, origin
    end

    local ok, digest = pcall(util.partialMD5, path)
    if not ok or type(digest) ~= "string" or digest == "" then
        digest = sha2.md5(path)
    end
    return "file-" .. digest
end

function Storage:ensureDirectories()
    local directories = {
        self.root,
        self.root .. "/cache",
        self.root .. "/status",
        self.root .. "/logs",
    }
    for _, directory in ipairs(directories) do
        local ok, err = util.makePath(directory)
        if not ok and lfs.attributes(directory, "mode") ~= "directory" then
            return nil, err or ("Could not create " .. directory)
        end
    end
    return true
end

function Storage:getPaths(path)
    local key, origin = self:keyForFile(path)
    return {
        key = key,
        origin = origin,
        output = self.root .. "/cache/" .. key .. ".mokuro",
        status = self.root .. "/status/" .. key .. ".json",
        log = self.root .. "/logs/" .. key .. ".log",
    }
end

function Storage:getAdjacentPath(path)
    local stem = path:gsub("%.[^./]+$", "")
    return stem .. ".mokuro"
end

function Storage:hasCache(path)
    return isFile(self:getPaths(path).output)
end

function Storage:hasFailures(path)
    local paths = self:getPaths(path)
    local status = self:readStatus(paths.status)
    if status and tonumber(status.failed) and tonumber(status.failed) > 0 then
        return true
    end
    if status and type(status.failures) == "table" and #status.failures > 0 then
        return true
    end

    local output = decodeJSON(readFile(paths.output) or "")
    local metadata = output and output.mangaocr
    return type(metadata) == "table"
        and type(metadata.failed_pages) == "table"
        and #metadata.failed_pages > 0
end

function Storage:readStatus(path)
    local content = readFile(path)
    if not content then
        return nil
    end
    local value = decodeJSON(content)
    if not value or type(value.state) ~= "string" then
        return nil
    end
    return value
end

function Storage:deleteCache(path)
    local paths = self:getPaths(path)
    local removed = false
    for _, candidate in ipairs({ paths.output, paths.status, paths.log }) do
        if isFile(candidate) then
            local ok = os.remove(candidate)
            removed = ok and true or removed
        end
    end
    return removed
end

function Storage:readEmbedded(path)
    local Archiver = require("ffi/archiver")
    local reader = Archiver.Reader:new()
    local open_ok, opened = pcall(reader.open, reader, path)
    if not open_ok or not opened then
        return nil
    end

    local ok, content, entry_path = pcall(function()
        local found_path
        for entry in reader:iterate() do
            if type(entry.path) == "string"
                    and entry.path:lower():match("%.mokuro$")
                    and (entry.mode == nil or entry.mode == "file") then
                found_path = entry.path
                break
            end
        end

        if found_path then
            return reader:extractToMemory(found_path), found_path
        end
    end)
    pcall(reader.close, reader)
    if not ok or not content or content == "" then
        return nil
    end
    return content, entry_path
end

-- Generated central data is authoritative so a user-requested rescan takes
-- effect. Existing upstream sidecars and embedded data remain read fallbacks.
function Storage:getCandidates(path)
    local candidates = {}
    local central = self:getPaths(path).output
    if isFile(central) then
        candidates[#candidates + 1] = {
            kind = "cache",
            path = central,
            content = readFile(central),
        }
    end

    local adjacent = self:getAdjacentPath(path)
    if isFile(adjacent) then
        candidates[#candidates + 1] = {
            kind = "adjacent",
            path = adjacent,
            content = readFile(adjacent),
        }
    end

    local embedded, entry = self:readEmbedded(path)
    if embedded then
        candidates[#candidates + 1] = {
            kind = "embedded",
            path = entry,
            content = embedded,
        }
    end
    return candidates
end

return Storage

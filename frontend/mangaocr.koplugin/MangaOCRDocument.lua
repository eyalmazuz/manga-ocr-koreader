local lfs = require("libs/libkoreader-lfs")
local util = require("util")

local MangaOCRDocument = {}
local Session = {}
Session.__index = Session

local TARGET_LONG_EDGE = 1800
local MAX_RENDER_ZOOM = 4
local document_registry

local FIXED_LAYOUT_PROVIDER_BY_EXTENSION = {
    cbr = "is_pdf",
    cbt = "is_pdf",
    djv = "is_djvu",
    djvu = "is_djvu",
    gif = "is_pic",
    hdp = "is_pdf",
    j2k = "is_pdf",
    jp2 = "is_pdf",
    jxr = "is_pdf",
    pdf = "is_pdf",
    tif = "is_pdf",
    tiff = "is_pdf",
    wdp = "is_pdf",
    webp = "is_pic",
    xps = "is_pdf",
}

local function extension(path)
    local suffix = type(path) == "string"
        and path:match("%.([^./\\]+)$")
        or nil
    return suffix and suffix:lower() or nil
end

local function finitePositiveNumber(value)
    return type(value) == "number"
        and value == value
        and value > 0
        and value ~= math.huge
end

local function positiveInteger(value)
    return finitePositiveNumber(value) and value == math.floor(value)
end

local function getDocumentRegistry()
    if document_registry then
        return document_registry
    end
    local ok, registry = pcall(require, "document/documentregistry")
    if not ok then
        return nil, tostring(registry)
    end
    document_registry = registry
    return registry
end

local function closeOwnedDocument(document)
    if document and type(document.close) == "function" then
        pcall(document.close, document)
    end
end

local function lowLevelDocument(document)
    local ok, low_level = pcall(function()
        return document._document
    end)
    if not ok or low_level == nil then
        return nil
    end
    local method_ok, open_page = pcall(function()
        return low_level.openPage
    end)
    if not method_ok or type(open_page) ~= "function" then
        return nil
    end
    return low_level
end

local function validateDocument(document)
    if type(document) ~= "table" then
        return nil, "KOReader did not provide a document"
    end
    if type(document.info) ~= "table"
            or document.info.has_pages ~= true then
        return nil, "The document is not a fixed-layout page source"
    end
    if document.is_reflowable == true then
        return nil, "Reflowable documents do not have stable page geometry"
    end
    if document.is_locked then
        return nil, "The document is locked"
    end
    if type(document.getPageCount) ~= "function" then
        return nil, "The document does not expose a page count"
    end

    local ok, page_count = pcall(document.getPageCount, document)
    if not ok or not positiveInteger(page_count) then
        return nil, "The document has no renderable pages"
    end
    if not lowLevelDocument(document) then
        return nil, "The document does not expose page rendering"
    end
    return page_count
end

local function normalizeManifestPages(pages, page_count)
    if type(pages) ~= "table" then
        return nil, "Manifest pages must be a table"
    end

    local normalized = {}
    local seen = {}
    for _, page in ipairs(pages) do
        if type(page) ~= "table"
                or not positiveInteger(page.index)
                or page.index > page_count
                or type(page.path) ~= "string"
                or page.path == "" then
            return nil, "Manifest pages contain an invalid entry"
        end
        if seen[page.index] then
            return nil, "Manifest pages contain a duplicate index"
        end
        seen[page.index] = true
        normalized[#normalized + 1] = {
            index = page.index,
            path = page.path,
        }
    end
    table.sort(normalized, function(left, right)
        return left.index < right.index
    end)
    return normalized
end

function MangaOCRDocument.isFixedLayoutPath(path)
    if type(path) ~= "string" or path == "" then
        return false
    end
    local provider_flag = FIXED_LAYOUT_PROVIDER_BY_EXTENSION[extension(path)]
    if not provider_flag then
        return false
    end
    local registry = getDocumentRegistry()
    if not registry or type(registry.getProvider) ~= "function" then
        return false
    end
    local ok, provider = pcall(registry.getProvider, registry, path)
    return ok
        and type(provider) == "table"
        and provider[provider_flag] == true
        or false
end

function MangaOCRDocument.getSourceInfo(path)
    if type(path) ~= "string" or path == "" then
        return nil, "Source path is invalid"
    end
    local attributes, attributes_error = lfs.attributes(path)
    if not attributes
            or attributes.mode ~= "file"
            or type(attributes.size) ~= "number"
            or attributes.size < 0 then
        return nil, attributes_error or "Source is not a regular file"
    end

    local ok, fingerprint = pcall(util.partialMD5, path)
    if not ok or type(fingerprint) ~= "string" or fingerprint == "" then
        return nil, "Could not fingerprint the source file"
    end
    return {
        fingerprint = fingerprint,
        size = attributes.size,
    }
end

function MangaOCRDocument.buildManifest(source_info, page_count, pages)
    if type(source_info) ~= "table"
            or type(source_info.fingerprint) ~= "string"
            or source_info.fingerprint == ""
            or type(source_info.size) ~= "number"
            or source_info.size < 0
            or not positiveInteger(page_count) then
        return nil, "Manifest source information is invalid"
    end
    local normalized, normalize_error = normalizeManifestPages(
        pages,
        page_count
    )
    if not normalized then
        return nil, normalize_error
    end
    return {
        version = 1,
        source_fingerprint = source_info.fingerprint,
        source_size = source_info.size,
        page_count = page_count,
        pages = normalized,
    }
end

function MangaOCRDocument.open(path, existing_document)
    if type(path) ~= "string" or path == "" then
        return nil, "Source path is invalid"
    end

    local document = existing_document
    local owns_document = false
    if document then
        if type(document.file) == "string" and document.file ~= path then
            return nil, "The open document does not match the source path"
        end
    else
        local registry, registry_error = getDocumentRegistry()
        if not registry or type(registry.openDocument) ~= "function" then
            return nil, registry_error or "KOReader document support is unavailable"
        end
        local ok
        ok, document = pcall(registry.openDocument, registry, path)
        if not ok or not document then
            return nil, "KOReader could not open the document"
        end
        -- openDocument acquired one registry reference even when the same
        -- document object was already open elsewhere.
        owns_document = true
    end

    local page_count, validation_error = validateDocument(document)
    if not page_count then
        if owns_document then
            closeOwnedDocument(document)
        end
        return nil, validation_error
    end
    local source_info, source_error = MangaOCRDocument.getSourceInfo(path)
    if not source_info then
        if owns_document then
            closeOwnedDocument(document)
        end
        return nil, source_error
    end

    return setmetatable({
        path = path,
        document = document,
        owns_document = owns_document,
        page_count = page_count,
        source_info = source_info,
        closed = false,
    }, Session)
end

function Session:close()
    if self.closed then
        return true
    end
    self.closed = true
    if self.owns_document then
        closeOwnedDocument(self.document)
    end
    self.document = nil
    return true
end

function Session:getSourceInfo()
    if self.closed then
        return nil, "Document session is closed"
    end
    return {
        fingerprint = self.source_info.fingerprint,
        size = self.source_info.size,
    }
end

function Session:getPageCount()
    if self.closed then
        return nil, "Document session is closed"
    end
    return self.page_count
end

function Session:buildManifest(pages)
    if self.closed then
        return nil, "Document session is closed"
    end
    return MangaOCRDocument.buildManifest(
        self.source_info,
        self.page_count,
        pages
    )
end

function Session:renderPage(page_index, output_path)
    if self.closed or not self.document then
        return nil, "Document session is closed"
    end
    if not positiveInteger(page_index)
            or page_index > self.page_count then
        return nil, "Page index is outside the document"
    end
    if type(output_path) ~= "string" or output_path == "" then
        return nil, "Output path is invalid"
    end

    local BaseDocument = require("document/document")
    local Blitbuffer = require("ffi/blitbuffer")
    local DrawContext = require("ffi/drawcontext")
    local document = self.document
    local page
    local buffer
    local rendered_width
    local rendered_height

    os.remove(output_path)
    local ok, render_error = xpcall(function()
        local native_dimensions = BaseDocument.getNativePageDimensions(
            document,
            page_index
        )
        if type(native_dimensions) ~= "table"
                or not finitePositiveNumber(native_dimensions.w)
                or not finitePositiveNumber(native_dimensions.h) then
            error("KOReader returned invalid page dimensions")
        end

        local long_edge = math.max(
            native_dimensions.w,
            native_dimensions.h
        )
        local zoom = math.min(
            MAX_RENDER_ZOOM,
            TARGET_LONG_EDGE / long_edge
        )
        local width = math.max(
            1,
            math.ceil(native_dimensions.w * zoom - 0.001)
        )
        local height = math.max(
            1,
            math.ceil(native_dimensions.h * zoom - 0.001)
        )
        rendered_width = width
        rendered_height = height

        -- A fixed grayscale target keeps staging independent of display color
        -- settings and is sufficient for text recognition.
        buffer = Blitbuffer.new(
            width,
            height,
            Blitbuffer.TYPE_BB8
        )
        local draw_context = DrawContext.new()
        draw_context:setRotate(0)
        draw_context:setZoom(zoom)
        draw_context:setOffset(0, 0)
        draw_context:setGamma(1.0)
        local low_level = assert(
            lowLevelDocument(document),
            "The document renderer is unavailable"
        )
        page = low_level:openPage(page_index)
        if not page or type(page.draw) ~= "function" then
            error("KOReader could not open the requested page")
        end
        page:draw(
            draw_context,
            buffer,
            0,
            0,
            document.render_mode
        )
        buffer:writePNG(output_path)
    end, debug.traceback)

    if page and type(page.close) == "function" then
        pcall(page.close, page)
    end
    if buffer and type(buffer.free) == "function" then
        pcall(buffer.free, buffer)
    end

    if not ok then
        os.remove(output_path)
        return nil, tostring(render_error)
    end
    local attributes = lfs.attributes(output_path)
    if not attributes
            or attributes.mode ~= "file"
            or type(attributes.size) ~= "number"
            or attributes.size <= 0 then
        os.remove(output_path)
        return nil, "KOReader did not create a usable page image"
    end
    return {
        index = page_index,
        path = output_path,
        width = rendered_width,
        height = rendered_height,
    }
end

return MangaOCRDocument

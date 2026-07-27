-- luacheck: globals describe it assert before_each after_each

local lfs = require("lfs")

local provider = { is_pdf = true }
local registry
local render_state

package.preload["document/documentregistry"] = function()
    return registry
end

package.preload["document/document"] = function()
    return {
        getNativePageDimensions = function()
            return render_state.native_dimensions
                or { w = 600, h = 900 }
        end,
    }
end

package.preload["ffi/drawcontext"] = function()
    return {
        new = function()
            local context = {}
            function context:setRotate(rotation)
                render_state.rotation = rotation
            end
            function context:setZoom(zoom)
                render_state.zoom = zoom
            end
            function context:setOffset(x, y)
                render_state.offset_x = x
                render_state.offset_y = y
            end
            function context:setGamma(gamma)
                render_state.gamma = gamma
            end
            return context
        end,
    }
end

package.preload["ffi/blitbuffer"] = function()
    return {
        TYPE_BB8 = 1,
        new = function(width, height, buffer_type)
            render_state.width = width
            render_state.height = height
            render_state.buffer_type = buffer_type
            local buffer = {
                w = width,
                h = height,
            }
            function buffer:writePNG(path)
                local file = assert(io.open(path, "wb"))
                file:write("page")
                file:close()
            end
            function buffer:free()
                render_state.buffer_freed = true
            end
            return buffer
        end,
    }
end

local MangaOCRDocument = require("MangaOCRDocument")

local source_path
local output_path
local close_count
local document

local function makeDocument()
    local page = {}
    function page:draw(context, _, x, y)
        render_state.draw_context = context
        render_state.draw_x = x
        render_state.draw_y = y
        if render_state.fail_draw then
            error("render failed")
        end
    end
    function page:close()
        render_state.page_closed = true
    end

    return {
        file = source_path,
        info = { has_pages = true },
        _document = {
            openPage = function(_, index)
                render_state.page_index = index
                return page
            end,
        },
        getPageCount = function()
            return 3
        end,
        close = function()
            close_count = close_count + 1
        end,
    }
end

describe("Manga OCR fixed-layout document adapter", function()
    before_each(function()
        source_path = os.tmpname()
        output_path = os.tmpname()
        os.remove(output_path)
        local source = assert(io.open(source_path, "wb"))
        source:write("fixed-layout source")
        source:close()

        close_count = 0
        render_state = {}
        document = makeDocument()
        provider = { is_pdf = true }
        registry = {
            getProvider = function()
                return provider
            end,
            openDocument = function()
                return document
            end,
        }
    end)

    after_each(function()
        os.remove(source_path)
        os.remove(output_path)
    end)

    it("classifies only matching fixed-layout extensions and providers", function()
        provider = { is_pdf = true }
        assert.is_true(MangaOCRDocument.isFixedLayoutPath("book.pdf"))
        assert.is_true(MangaOCRDocument.isFixedLayoutPath("series.volume.pdf"))
        provider = {}
        assert.is_false(MangaOCRDocument.isFixedLayoutPath("book.pdf"))
        provider = { is_djvu = true }
        assert.is_false(MangaOCRDocument.isFixedLayoutPath("book.pdf"))

        assert.is_false(MangaOCRDocument.isFixedLayoutPath("book.epub"))
        provider = { is_djvu = true }
        assert.is_true(MangaOCRDocument.isFixedLayoutPath("book.djvu"))
        provider = { is_pic = true }
        assert.is_true(MangaOCRDocument.isFixedLayoutPath("book.webp"))
    end)

    it("closes only a document reference acquired by the adapter", function()
        local owned = assert(MangaOCRDocument.open(source_path))
        assert.is_true(owned:close())
        assert.is_true(owned:close())
        assert.are.equal(1, close_count)

        local borrowed = assert(
            MangaOCRDocument.open(source_path, document)
        )
        assert.is_true(borrowed:close())
        assert.are.equal(1, close_count)
    end)

    it("renders a full unrotated page into an owned buffer", function()
        local session = assert(
            MangaOCRDocument.open(source_path, document)
        )
        local rendered = assert(session:renderPage(2, output_path))

        assert.are.equal(2, rendered.index)
        assert.are.equal(output_path, rendered.path)
        assert.are.equal(2, render_state.page_index)
        assert.are.equal(2, render_state.zoom)
        assert.are.equal(0, render_state.rotation)
        assert.are.equal(0, render_state.offset_x)
        assert.are.equal(0, render_state.offset_y)
        assert.are.equal(1, render_state.gamma)
        assert.are.equal(1200, render_state.width)
        assert.are.equal(1800, render_state.height)
        assert.are.equal(0, render_state.draw_x)
        assert.are.equal(0, render_state.draw_y)
        assert.is_true(render_state.page_closed)
        assert.is_true(render_state.buffer_freed)
        assert.are.equal("file", lfs.attributes(output_path, "mode"))
    end)

    it("downscales oversized pages to the render budget", function()
        local session = assert(
            MangaOCRDocument.open(source_path, document)
        )
        render_state.native_dimensions = { w = 4000, h = 6000 }
        local rendered = assert(session:renderPage(1, output_path))

        assert.are.equal(0.3, render_state.zoom)
        assert.are.equal(1200, rendered.width)
        assert.are.equal(1800, rendered.height)
        assert.are.equal(1200, render_state.width)
        assert.are.equal(1800, render_state.height)
    end)

    it("rejects reflowable page sources", function()
        document.is_reflowable = true
        local session, open_error = MangaOCRDocument.open(
            source_path,
            document
        )

        assert.is_nil(session)
        assert.is_truthy(open_error:find("stable page geometry", 1, true))
    end)

    it("releases rendering resources after an error", function()
        local session = assert(
            MangaOCRDocument.open(source_path, document)
        )
        render_state.fail_draw = true
        local rendered = session:renderPage(1, output_path)

        assert.is_nil(rendered)
        assert.is_true(render_state.page_closed)
        assert.is_true(render_state.buffer_freed)
        assert.is_nil(lfs.attributes(output_path))
    end)

    it("builds a sorted sparse version-one manifest", function()
        local session = assert(
            MangaOCRDocument.open(source_path, document)
        )
        local source_info = assert(session:getSourceInfo())
        local manifest = assert(session:buildManifest({
            { index = 3, path = "/tmp/page-3.png" },
            { index = 1, path = "/tmp/page-1.png" },
        }))

        assert.are.equal(1, manifest.version)
        assert.are.equal(source_info.fingerprint, manifest.source_fingerprint)
        assert.are.equal(source_info.size, manifest.source_size)
        assert.are.equal(3, manifest.page_count)
        assert.are.same({
            { index = 1, path = "/tmp/page-1.png" },
            { index = 3, path = "/tmp/page-3.png" },
        }, manifest.pages)
    end)
end)

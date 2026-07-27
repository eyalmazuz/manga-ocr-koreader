-- luacheck: globals describe it assert

local Storage = require("MangaOCRStorage")

local function zipTail(comment)
    local length = #comment
    return "PK\005\006"
        .. string.rep("\0", 16)
        .. string.char(length % 256, math.floor(length / 256))
        .. comment
end

describe("Manga OCR source classification", function()
    it("recognizes direct archives case-insensitively", function()
        assert.is_true(Storage.isArchive("/books/volume.CBZ"))
        assert.is_true(Storage.isArchive("/books/volume.ZiP"))
        assert.is_true(Storage:new{ root = "/unused" }:isArchive("/books/volume.cbz"))
        assert.is_false(Storage.isArchive("/books/volume.cbr"))
        assert.is_false(Storage.isArchive("/books/volume.pdf"))
    end)

    it("recognizes directly decodable standalone images case-insensitively", function()
        for _, suffix in ipairs({
            "BMP",
            "JpEg",
            "jpg",
            "PAM",
            "pbm",
            "PGM",
            "png",
            "PNM",
            "ppm",
        }) do
            assert.is_true(Storage.isDirectImage("/books/page." .. suffix))
            assert.is_true(Storage.isDirect("/books/page." .. suffix))
        end
        assert.is_true(Storage.isDirectImage("/books/chapter.page.JPG"))
        assert.is_true(Storage.isDirect("/books/chapter.page.JPG"))
        for _, suffix in ipairs({ "gif", "TIF", "tiff", "WEBP" }) do
            assert.is_false(Storage.isDirectImage("/books/page." .. suffix))
            assert.is_false(Storage.isDirect("/books/page." .. suffix))
        end
        assert.is_false(Storage.isDirectImage("/books/page.jp2"))
        assert.is_false(Storage.isDirectImage("/books/page"))
        assert.is_false(Storage.isDirectImage(nil))
    end)

    it("does not inspect nonarchives for Rakuyomi metadata", function()
        local probed = false
        local origin = Storage.getRakuyomiOrigin("/books/page.PNG", function()
            probed = true
            return ""
        end)

        assert.is_nil(origin)
        assert.is_false(probed)
    end)

    it("does not inspect nonarchives for embedded Mokuro data", function()
        local storage = Storage:new{
            root = "/mangaocr-storage-spec",
        }
        local probed = false
        storage.readEmbedded = function()
            probed = true
            return "unexpected"
        end

        local candidates = storage:getCandidates("/books/page.PNG")

        assert.are.equal(0, #candidates)
        assert.is_false(probed)
    end)

    it("identifies only completed page records in a partial cache", function()
        local output_path = os.tmpname()
        local output = assert(io.open(output_path, "wb"))
        output:write([[
            {
                "pages": [
                    null,
                    {"img_path":"page-000002.png"},
                    null,
                    {"img_path":"page-000004.png"}
                ]
            }
        ]])
        output:close()

        local storage = Storage:new{ root = "/unused" }
        storage.getPaths = function()
            return { output = output_path }
        end
        assert.are.same(
            { 2, 4 },
            storage:getCompletedPageIndices("/books/document.pdf")
        )
        os.remove(output_path)
    end)
end)

describe("Manga OCR storage identity", function()
    it("parses a Rakuyomi JSON ZIP comment", function()
        local comment = [[{"source_id":"en.example","manga_id":"series-7","chapter_id":"42"}]]
        local extracted = assert(Storage.zipCommentFromTail(zipTail(comment)))
        local origin = assert(Storage.parseRakuyomiOriginComment(extracted))

        assert.are.equal("en.example", origin.source_id)
        assert.are.equal("series-7", origin.manga_id)
        assert.are.equal("42", origin.chapter_id)
    end)

    it("rejects unrelated ZIP comments", function()
        assert.is_nil(Storage.parseRakuyomiOriginComment([[{"title":"not Rakuyomi"}]]))
    end)

    it("builds a stable key from all three origin fields", function()
        local origin = {
            source_id = "en.example",
            manga_id = "series-7",
            chapter_id = "42",
        }
        local first = Storage.keyForOrigin(origin)
        local second = Storage.keyForOrigin(origin)
        assert.are.equal(first, second)
        assert.is_truthy(first:match("^rakuyomi%-%x+$"))

        origin.chapter_id = "43"
        assert.are_not.equal(first, Storage.keyForOrigin(origin))
    end)
end)

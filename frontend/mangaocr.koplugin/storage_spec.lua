-- luacheck: globals describe it assert

local Storage = require("MangaOCRStorage")

local function zipTail(comment)
    local length = #comment
    return "PK\005\006"
        .. string.rep("\0", 16)
        .. string.char(length % 256, math.floor(length / 256))
        .. comment
end

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

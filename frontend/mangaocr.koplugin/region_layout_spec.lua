-- luacheck: globals describe it assert

local Layout = require("MangaOCRRegionLayout")

describe("Manga OCR region layout", function()
    it("counts Unicode characters rather than UTF-8 bytes", function()
        assert.are.equal(3, Layout.utf8Length("俺がい"))
        assert.are.equal(0, Layout.utf8Length(""))
    end)

    it("keeps UTF-8 characters intact in a vertical column", function()
        assert.are.equal(
            "俺\nが\nい",
            Layout.verticalColumnText("俺がい")
        )
    end)

    it("returns an empty column for invalid input", function()
        assert.are.equal("", Layout.verticalColumnText(false))
    end)

    it("places vertical lines from right to left", function()
        assert.are.same(
            { "右", "中", "左" },
            Layout.orderedVerticalLines({ "左", "中", "右" })
        )
    end)

    it("ignores invalid and empty lines", function()
        assert.are.same(
            { "甲" },
            Layout.orderedVerticalLines({ "", false, "甲", nil })
        )
    end)
end)

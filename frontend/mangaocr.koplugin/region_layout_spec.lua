-- luacheck: globals describe it assert

local Layout = require("MangaOCRRegionLayout")

describe("Manga OCR region layout", function()
    it("counts Unicode characters rather than UTF-8 bytes", function()
        assert.are.equal(3, Layout.utf8Length("俺がい"))
        assert.are.equal(0, Layout.utf8Length(""))
    end)

    it("keeps UTF-8 characters intact in a vertical column", function()
        assert.are.equal(
            "  俺\nが\nい",
            Layout.verticalColumnText("俺がい", "  ")
        )
    end)

    it("keeps multiple vertical columns in one selectable grid", function()
        local fullwidth_space = Layout.FULLWIDTH_SPACE
        assert.are.equal(
            "  あ" .. fullwidth_space .. "何\n"
                .. "  い" .. fullwidth_space .. "や\n"
                .. "  つ" .. fullwidth_space .. "っ",
            Layout.verticalGridText({ "あいつ", "何やっ" }, "  ")
        )
    end)

    it("records the character position of each vertical grid cell", function()
        local grid = Layout.verticalGrid({ "あい", "何" }, "  ")
        assert.are.equal(3, grid.cells[1][1])
        assert.are.equal(5, grid.cells[1][2])
        assert.are.equal(9, grid.cells[2][1])
        assert.are.same({ row = 2, column = 1 }, grid.index_to_cell[9])
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

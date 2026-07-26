-- luacheck: globals describe it assert

local Selection = require("MangaOCRSelection")

describe("Manga OCR popup selection", function()
    it("maps leading selection padding to the first real character", function()
        assert.are.same(
            { 3, 3 },
            { Selection.exactIndices(1, 2, 8, 3) }
        )
    end)

    it("keeps an exact Japanese character range", function()
        assert.are.same(
            { 3, 5 },
            { Selection.exactIndices(3, 5, 8, 3) }
        )
        assert.are.same(
            { 3, 5 },
            { Selection.exactIndices(5, 3, 8, 3) }
        )
    end)

    it("does not turn blank space after the text into its final character", function()
        local start_index, end_index = Selection.exactIndices(9, 9, 8, 3)
        assert.is_nil(start_index)
        assert.is_nil(end_index)
        assert.are.same(
            { 5, 8 },
            { Selection.exactIndices(5, 9, 8, 3) }
        )
    end)

    it("uses exact start and release endpoints only on the XText path", function()
        local function nativeNonXtextSelection()
            return 4, 4
        end
        local widget = {
            charlist = { " ", " ", "甲", "乙", "丙" },
            getCharPosAtXY = function(_, x)
                return x
            end,
            getNonXtextHighlightIndices = nativeNonXtextSelection,
        }

        assert.is_true(Selection.enableExactXtextRanges(widget, 3))
        assert.are.same(
            { 3, 3 },
            { widget:getXtextHighlightIndices(3, 1, 3, 1) }
        )
        assert.are.same(
            { 3, 4 },
            { widget:getXtextHighlightIndices(3, 1, 4, 1) }
        )
        assert.are.equal(
            nativeNonXtextSelection,
            widget.getNonXtextHighlightIndices
        )
    end)
end)

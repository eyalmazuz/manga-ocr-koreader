local Selection = {}

local function finiteInteger(value)
    return type(value) == "number"
        and value == math.floor(value)
        and value > -math.huge
        and value < math.huge
end

function Selection.exactIndices(raw_start, raw_end, text_length, first_text_index)
    if not finiteInteger(raw_start)
            or not finiteInteger(raw_end)
            or not finiteInteger(text_length)
            or not finiteInteger(first_text_index)
            or text_length < first_text_index then
        return nil, nil
    end

    if raw_start > raw_end then
        raw_start, raw_end = raw_end, raw_start
    end
    if raw_start > text_length then
        return nil, nil
    end
    raw_start = math.max(first_text_index, math.min(text_length, raw_start))
    raw_end = math.max(first_text_index, math.min(text_length, raw_end))
    return raw_start, raw_end
end

function Selection.enableExactXtextRanges(
    text_widget,
    first_text_index
)
    if type(text_widget) ~= "table"
            or type(text_widget.getCharPosAtXY) ~= "function"
            or not finiteInteger(first_text_index) then
        return false
    end

    local function exactRange(widget, start_x, start_y, end_x, end_y)
        local raw_start = widget:getCharPosAtXY(start_x, start_y)
        local raw_end = widget:getCharPosAtXY(end_x, end_y)
        local ok, text_length = pcall(function()
            return #widget.charlist
        end)
        if not ok then
            return nil, nil
        end
        return Selection.exactIndices(
            raw_start,
            raw_end,
            text_length,
            first_text_index
        )
    end

    -- XText normally expands both endpoints with Unicode word-break rules. A
    -- stationary Japanese hold naturally has equal endpoints; a hold-pan or a
    -- release-only drag keeps its exact multi-character range. KOReader's
    -- non-XText path already handles CJK characters individually.
    text_widget.getXtextHighlightIndices = exactRange
    return true
end

return Selection

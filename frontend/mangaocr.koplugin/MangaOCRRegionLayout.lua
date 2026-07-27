local Layout = {}
Layout.FULLWIDTH_SPACE = "\227\128\128"

local function splitUtf8(text)
    local characters = {}
    local index = 1
    while index <= #text do
        local byte = text:byte(index)
        local length
        if byte < 0x80 then
            length = 1
        elseif byte < 0xE0 then
            length = 2
        elseif byte < 0xF0 then
            length = 3
        else
            length = 4
        end
        characters[#characters + 1] = text:sub(index, index + length - 1)
        index = index + length
    end
    return characters
end

function Layout.utf8Length(text)
    if type(text) ~= "string" then
        return 0
    end
    return #splitUtf8(text)
end

function Layout.verticalColumnText(text, prefix)
    if type(text) ~= "string" then
        return prefix or ""
    end
    local characters = splitUtf8(text)
    if #characters == 0 then
        return prefix or ""
    end
    return (prefix or "") .. table.concat(characters, "\n")
end

function Layout.verticalGrid(lines, prefix, separator)
    if type(lines) ~= "table" or #lines == 0 then
        return {
            text = prefix or "",
            columns = {},
            cells = {},
            index_to_cell = {},
        }
    end

    separator = separator or Layout.FULLWIDTH_SPACE
    local columns = {}
    local row_count = 0
    for index, line in ipairs(lines) do
        if type(line) == "string" then
            columns[index] = splitUtf8(line)
            row_count = math.max(row_count, #columns[index])
        else
            columns[index] = {}
        end
    end

    local rows = {}
    local cells = {}
    local index_to_cell = {}
    local raw_index = 1
    local prefix_length = #splitUtf8(prefix or "")
    local separator_length = #splitUtf8(separator)
    for row = 1, row_count do
        local row_values = {}
        for column = 1, #columns do
            row_values[#row_values + 1] = columns[column][row]
                or Layout.FULLWIDTH_SPACE
        end
        -- Keep a constant leading inset on every row. This makes the visual
        -- columns line up even when a column has fewer characters than its
        -- neighbors, while the first real character still has a small
        -- selection hit area before it.
        local row_text = (prefix or "") .. table.concat(row_values, separator)
        rows[#rows + 1] = row_text

        local row_cells = {}
        raw_index = raw_index + prefix_length
        for column = 1, #columns do
            if columns[column][row] then
                row_cells[column] = raw_index
                index_to_cell[raw_index] = { row = row, column = column }
            end
            raw_index = raw_index + 1
            if column < #columns then
                raw_index = raw_index + separator_length
            end
        end
        cells[row] = row_cells
        if row < row_count then
            raw_index = raw_index + 1
        end
    end

    return {
        text = table.concat(rows, "\n"),
        columns = columns,
        cells = cells,
        index_to_cell = index_to_cell,
    }
end

function Layout.verticalGridText(lines, prefix, separator)
    return Layout.verticalGrid(lines, prefix, separator).text
end

function Layout.orderedVerticalLines(lines)
    if type(lines) ~= "table" then
        return {}
    end
    local ordered = {}
    -- OCR lines are stored in manga reading order. Vertical Japanese columns
    -- are displayed from right to left, so reverse them for screen layout.
    for index = #lines, 1, -1 do
        if type(lines[index]) == "string" and lines[index] ~= "" then
            ordered[#ordered + 1] = lines[index]
        end
    end
    return ordered
end

return Layout

local Layout = {}

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

function Layout.verticalColumnText(text)
    if type(text) ~= "string" then
        return ""
    end
    local characters = splitUtf8(text)
    return table.concat(characters, "\n")
end

function Layout.horizontalLines(lines, fallback)
    local normalized = {}
    if type(lines) == "table" then
        for _, line in ipairs(lines) do
            if type(line) == "string" and line ~= "" then
                normalized[#normalized + 1] = line
            end
        end
    end
    if #normalized == 0 and type(fallback) == "string" and fallback ~= "" then
        normalized[1] = fallback
    end
    return normalized
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

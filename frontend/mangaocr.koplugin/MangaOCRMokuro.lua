local rapidjson = require("rapidjson")
local util = require("util")

local Mokuro = {}

local function codepointAt(text, index)
    local first = text:byte(index)
    if not first then
        return nil
    elseif first < 0x80 then
        return first
    elseif first < 0xE0 then
        local second = text:byte(index + 1)
        if second then
            return (first - 0xC0) * 0x40 + second - 0x80
        end
    elseif first < 0xF0 then
        local second, third = text:byte(index + 1, index + 2)
        if second and third then
            return (first - 0xE0) * 0x1000
                + (second - 0x80) * 0x40
                + third - 0x80
        end
    elseif first < 0xF8 then
        local second, third, fourth = text:byte(index + 1, index + 3)
        if second and third and fourth then
            return (first - 0xF0) * 0x40000
                + (second - 0x80) * 0x1000
                + (third - 0x80) * 0x40
                + fourth - 0x80
        end
    end
    return first
end

local function firstNonSpaceCodepoint(text)
    local index = 1
    while index <= #text do
        local byte = text:byte(index)
        if byte >= 0x80 or not text:sub(index, index):match("%s") then
            return codepointAt(text, index)
        end
        index = index + 1
    end
end

local function lastNonSpaceCodepoint(text)
    local trimmed = text:gsub("%s+$", "")
    local index = #trimmed
    while index > 0 do
        local byte = trimmed:byte(index)
        if byte < 0x80 or byte >= 0xC0 then
            return codepointAt(trimmed, index)
        end
        index = index - 1
    end
end

local function isCJKCodepoint(codepoint)
    if not codepoint then
        return false
    end
    return (codepoint >= 0x2E80 and codepoint <= 0x312F)
        or (codepoint >= 0x31C0 and codepoint <= 0x31FF)
        or (codepoint >= 0x3400 and codepoint <= 0x4DBF)
        or (codepoint >= 0x4E00 and codepoint <= 0x9FFF)
        or (codepoint >= 0xF900 and codepoint <= 0xFAFF)
        or (codepoint >= 0xFE30 and codepoint <= 0xFE4F)
        or (codepoint >= 0xFF01 and codepoint <= 0xFF20)
        or (codepoint >= 0xFF3B and codepoint <= 0xFF40)
        or (codepoint >= 0xFF5B and codepoint <= 0xFF9F)
        or (codepoint >= 0x20000 and codepoint <= 0x323AF)
end

local no_space_before = {
    [0x21] = true, -- !
    [0x22] = true, -- "
    [0x25] = true, -- %
    [0x27] = true, -- '
    [0x29] = true, -- )
    [0x2C] = true, -- ,
    [0x2D] = true, -- -
    [0x2E] = true, -- .
    [0x2F] = true, -- /
    [0x3A] = true, -- :
    [0x3B] = true, -- ;
    [0x3F] = true, -- ?
    [0x5D] = true, -- ]
    [0x7D] = true, -- }
}

local no_space_after = {
    [0x23] = true, -- #
    [0x24] = true, -- $
    [0x28] = true, -- (
    [0x2D] = true, -- -
    [0x2F] = true, -- /
    [0x5B] = true, -- [
    [0x7B] = true, -- {
}

local function lineSeparator(left, right)
    if left == "" or right == ""
            or left:match("%s$") or right:match("^%s") then
        return ""
    end

    local left_codepoint = lastNonSpaceCodepoint(left)
    local right_codepoint = firstNonSpaceCodepoint(right)
    if isCJKCodepoint(left_codepoint)
            or isCJKCodepoint(right_codepoint)
            or no_space_after[left_codepoint]
            or no_space_before[right_codepoint] then
        return ""
    end
    return " "
end

local function codepointLength(first_byte)
    if first_byte < 0x80 then
        return 1
    elseif first_byte < 0xE0 then
        return 2
    elseif first_byte < 0xF0 then
        return 3
    end
    return 4
end

local function isHanCodepoint(codepoint)
    return (codepoint >= 0x3400 and codepoint <= 0x4DBF)
        or (codepoint >= 0x4E00 and codepoint <= 0x9FFF)
        or (codepoint >= 0xF900 and codepoint <= 0xFAFF)
        or (codepoint >= 0x20000 and codepoint <= 0x323AF)
end

local function isKanaCodepoint(codepoint)
    return (codepoint >= 0x3040 and codepoint <= 0x30FF)
        or (codepoint >= 0x31F0 and codepoint <= 0x31FF)
        or (codepoint >= 0xFF66 and codepoint <= 0xFF9F)
        or (codepoint >= 0x1B000 and codepoint <= 0x1B16F)
end

local function isReadingPunctuation(codepoint)
    return codepoint == 0x20
        or (codepoint >= 0x21 and codepoint <= 0x2F)
        or (codepoint >= 0x3A and codepoint <= 0x40)
        or (codepoint >= 0x5B and codepoint <= 0x60)
        or (codepoint >= 0x7B and codepoint <= 0x7E)
        or (codepoint >= 0x3000 and codepoint <= 0x303F)
        or (codepoint >= 0xFF01 and codepoint <= 0xFF0F)
        or (codepoint >= 0xFF1A and codepoint <= 0xFF20)
        or (codepoint >= 0xFF3B and codepoint <= 0xFF40)
        or (codepoint >= 0xFF5B and codepoint <= 0xFF65)
end

local function textHasHan(text)
    local index = 1
    while index <= #text do
        local first_byte = text:byte(index)
        local codepoint = codepointAt(text, index)
        if isHanCodepoint(codepoint) then
            return true
        end
        index = index + codepointLength(first_byte)
    end
    return false
end

local function intervalOverlap(first_min, first_max, second_min, second_max)
    return math.max(0, math.min(first_max, second_max) - math.max(first_min, second_min))
end

local function cloneBox(box)
    return { box[1], box[2], box[3], box[4] }
end

local function finiteNumber(value)
    return type(value) == "number"
        and value == value
        and value ~= math.huge
        and value ~= -math.huge
end

local function normalizeBox(box)
    if type(box) ~= "table" then
        return nil
    end
    for index = 1, 4 do
        if not finiteNumber(box[index]) then
            return nil
        end
    end

    local left = math.min(box[1], box[3])
    local top = math.min(box[2], box[4])
    local right = math.max(box[1], box[3])
    local bottom = math.max(box[2], box[4])
    if right <= left or bottom <= top then
        return nil
    end
    return { left, top, right, bottom }
end

local function normalizePolygon(polygon)
    if type(polygon) ~= "table" then
        return nil
    end

    local normalized = {}
    for index = 1, 4 do
        local point = polygon[index]
        if type(point) ~= "table"
                or not finiteNumber(point[1])
                or not finiteNumber(point[2]) then
            return nil
        end
        normalized[index] = { point[1], point[2] }
    end
    return normalized
end

local function polygonBox(polygon)
    polygon = normalizePolygon(polygon)
    if not polygon then
        return nil
    end

    local left = math.huge
    local top = math.huge
    local right = -math.huge
    local bottom = -math.huge
    for index = 1, 4 do
        local point = polygon[index]
        left = math.min(left, point[1])
        top = math.min(top, point[2])
        right = math.max(right, point[1])
        bottom = math.max(bottom, point[2])
    end
    if right <= left or bottom <= top then
        return nil
    end
    return { left, top, right, bottom }
end

local function utf8Characters(text)
    local characters = {}
    local index = 1
    while index <= #text do
        local length = codepointLength(text:byte(index))
        characters[#characters + 1] = text:sub(index, index + length - 1)
        index = index + length
    end
    return characters
end

local function boxWidth(box)
    return box[3] - box[1]
end

local function boxHeight(box)
    return box[4] - box[2]
end

local function boxCenterX(box)
    return (box[1] + box[3]) / 2
end

local function unionBoxes(first, second)
    if not first then
        return cloneBox(second)
    end
    return {
        math.min(first[1], second[1]),
        math.min(first[2], second[2]),
        math.max(first[3], second[3]),
        math.max(first[4], second[4]),
    }
end

local function textIsReadingOnly(text)
    if text == "" then
        return false
    end
    local has_kana = false
    local index = 1
    while index <= #text do
        local first_byte = text:byte(index)
        local codepoint = codepointAt(text, index)
        if isKanaCodepoint(codepoint) then
            has_kana = true
        elseif not isReadingPunctuation(codepoint) then
            return false
        end
        index = index + codepointLength(first_byte)
    end
    return has_kana
end

-- Lens occasionally returns both horizontal row fragments and an overlapping
-- vertical fragment for the same Japanese text. The duplicate vertical
-- fragment provides enough evidence to recover the original columns without
-- guessing from the image or changing valid, non-overlapping OCR blocks.
local function repairOverlappingVerticalRows(block)
    if block.vertical or #block.lines < 4 then
        return block
    end

    local rows = {}
    local vertical_fragments = {}
    for index, line_box in ipairs(block.line_boxes) do
        if not line_box then
            return block
        end
        local width = boxWidth(line_box)
        local height = boxHeight(line_box)
        if width >= height * 1.35 then
            rows[#rows + 1] = index
        elseif height >= width * 1.35 then
            vertical_fragments[#vertical_fragments + 1] = index
        end
    end
    if #rows < 3 or #vertical_fragments < 2 then
        return block
    end

    local centers = {}
    local cluster_tolerance = math.max(4, (block.font_size or 1) * 0.55)
    table.sort(vertical_fragments, function(first, second)
        return boxCenterX(block.line_boxes[first])
            < boxCenterX(block.line_boxes[second])
    end)
    for _, index in ipairs(vertical_fragments) do
        local center = boxCenterX(block.line_boxes[index])
        local cluster = centers[#centers]
        if cluster and center - cluster.center <= cluster_tolerance then
            cluster.total = cluster.total + center
            cluster.count = cluster.count + 1
            cluster.center = cluster.total / cluster.count
        else
            centers[#centers + 1] = {
                center = center,
                total = center,
                count = 1,
            }
        end
    end
    if #centers < 2 or #centers > 3 then
        return block
    end

    local columns = {}
    for index, cluster in ipairs(centers) do
        columns[index] = { center = cluster.center, characters = {}, box = nil }
    end

    local duplicate_fragments = {}
    for _, index in ipairs(rows) do
        local line_box = block.line_boxes[index]
        local intersecting = {}
        for column_index, column in ipairs(columns) do
            if column.center >= line_box[1] - cluster_tolerance * 0.25
                    and column.center <= line_box[3] + cluster_tolerance * 0.25 then
                intersecting[#intersecting + 1] = column_index
            end
        end
        local characters = utf8Characters(block.lines[index])
        if #intersecting == 0 or #characters < #intersecting then
            return block
        end
        if #characters > #intersecting then
            local extra = table.concat(characters, "", #intersecting + 1)
            if #characters ~= #intersecting + 1
                    or not textHasHan(block.lines[index])
                    or not textIsReadingOnly(extra) then
                return block
            end
        end
        for offset, column_index in ipairs(intersecting) do
            local column = columns[column_index]
            column.characters[#column.characters + 1] = characters[offset]
            column.box = unionBoxes(column.box, line_box)
        end
    end

    for _, index in ipairs(vertical_fragments) do
        local text = block.lines[index]
        local characters = utf8Characters(text)
        local line_box = block.line_boxes[index]
        local nearest = 1
        local nearest_distance = math.huge
        for column_index, column in ipairs(columns) do
            local distance = math.abs(column.center - boxCenterX(line_box))
            if distance < nearest_distance then
                nearest = column_index
                nearest_distance = distance
            end
        end
        if #characters >= 2 and textHasHan(text) then
            duplicate_fragments[#duplicate_fragments + 1] = {
                column = nearest,
                text = text,
            }
        elseif not textHasHan(text) and not textIsReadingOnly(text) then
            local column = columns[nearest]
            column.characters[#column.characters + 1] = text
            column.box = unionBoxes(column.box, line_box)
        end
    end

    if #duplicate_fragments == 0 then
        return block
    end
    local duplicate_characters = 0
    for _, fragment in ipairs(duplicate_fragments) do
        local column_text = table.concat(columns[fragment.column].characters)
        if not column_text:find(fragment.text, 1, true) then
            return block
        end
        duplicate_characters = duplicate_characters + #utf8Characters(fragment.text)
    end
    if duplicate_characters < 2 then
        return block
    end

    local repaired_lines = {}
    local repaired_boxes = {}
    local half_width = math.max(1, math.floor((block.font_size or 1) / 2))
    for index = #columns, 1, -1 do
        local column = columns[index]
        local text = table.concat(column.characters)
        if text == "" or not column.box then
            return block
        end
        repaired_lines[#repaired_lines + 1] = text
        repaired_boxes[#repaired_boxes + 1] = {
            math.floor(column.center - half_width),
            column.box[2],
            math.ceil(column.center + half_width),
            column.box[4],
        }
    end

    block.lines = repaired_lines
    block.line_boxes = repaired_boxes
    block.vertical = true
    return block
end

local function dominantLineThickness(block)
    local thicknesses = {}
    for _, line_box in ipairs(block.line_boxes) do
        if line_box then
            thicknesses[#thicknesses + 1] = block.vertical
                and boxWidth(line_box) or boxHeight(line_box)
        end
    end
    if #thicknesses == 0 then
        return block.font_size or 1
    end
    table.sort(thicknesses)
    return thicknesses[math.max(1, math.ceil(#thicknesses * 0.75))]
end

local function hasThinReadingGeometry(block, dominant)
    for _, line_box in ipairs(block.line_boxes) do
        if line_box then
            local thickness = block.vertical and boxWidth(line_box) or boxHeight(line_box)
            if thickness <= dominant * 0.6 then
                return true
            end
        end
    end
    return false
end

local function mergeVerticalBlocks(first, second)
    local entries = {}
    for _, block in ipairs({ first, second }) do
        for index, text in ipairs(block.lines) do
            entries[#entries + 1] = {
                text = text,
                box = block.line_boxes[index],
                source = #entries,
            }
        end
    end
    table.sort(entries, function(left, right)
        local left_center = boxCenterX(left.box)
        local right_center = boxCenterX(right.box)
        local tolerance = math.min(boxWidth(left.box), boxWidth(right.box)) / 2
        if math.abs(left_center - right_center) > tolerance then
            return left_center > right_center
        end
        if left.box[2] ~= right.box[2] then
            return left.box[2] < right.box[2]
        end
        return left.source < right.source
    end)

    local lines = {}
    local line_boxes = {}
    for _, entry in ipairs(entries) do
        lines[#lines + 1] = entry.text
        line_boxes[#line_boxes + 1] = entry.box
    end
    return {
        box = unionBoxes(first.box, second.box),
        lines = lines,
        line_boxes = line_boxes,
        vertical = true,
        font_size = math.floor((dominantLineThickness(first)
            + dominantLineThickness(second)) / 2 + 0.5),
    }
end

local function shouldRepairSplitVerticalBlocks(first, second)
    if not first.vertical or not second.vertical then
        return false
    end
    for _, block in ipairs({ first, second }) do
        for index = 1, #block.lines do
            if not block.line_boxes[index] then
                return false
            end
        end
    end
    local first_font = math.max(1, first.font_size or 1)
    local second_font = math.max(1, second.font_size or 1)
    local reported_ratio = math.max(first_font, second_font)
        / math.min(first_font, second_font)
    if reported_ratio < 1.6 then
        return false
    end

    local first_dominant = dominantLineThickness(first)
    local second_dominant = dominantLineThickness(second)
    local dominant_ratio = math.max(first_dominant, second_dominant)
        / math.max(1, math.min(first_dominant, second_dominant))
    if dominant_ratio > 1.35
            or not (hasThinReadingGeometry(first, first_dominant)
                or hasThinReadingGeometry(second, second_dominant)) then
        return false
    end

    local horizontal_gap = math.max(
        0,
        math.max(first.box[1], second.box[1])
            - math.min(first.box[3], second.box[3])
    )
    if horizontal_gap > math.min(first_dominant, second_dominant) * 0.2 then
        return false
    end
    local overlap = intervalOverlap(
        first.box[2], first.box[4], second.box[2], second.box[4]
    )
    local shorter_height = math.min(boxHeight(first.box), boxHeight(second.box))
    return shorter_height > 0 and overlap >= shorter_height * 0.65
end

local function repairSplitVerticalBlocks(blocks)
    local changed = true
    while changed do
        changed = false
        for first = 1, #blocks - 1 do
            for second = first + 1, #blocks do
                if shouldRepairSplitVerticalBlocks(blocks[first], blocks[second]) then
                    blocks[first] = mergeVerticalBlocks(blocks[first], blocks[second])
                    table.remove(blocks, second)
                    changed = true
                    break
                end
            end
            if changed then
                break
            end
        end
    end
    return blocks
end

local function normalizeBlock(block)
    if type(block) ~= "table" then
        return nil
    end
    local box = normalizeBox(block.box)
    if not box or type(block.lines) ~= "table" then
        return nil
    end

    local lines = {}
    local line_boxes = {}
    for index = 1, #block.lines do
        if type(block.lines[index]) == "string" then
            lines[#lines + 1] = block.lines[index]
            local polygon = type(block.lines_coords) == "table"
                and block.lines_coords[index]
                or nil
            line_boxes[#line_boxes + 1] = polygonBox(polygon) or false
        end
    end
    if #lines == 0 then
        return nil
    end

    return repairOverlappingVerticalRows({
        box = box,
        lines = lines,
        -- Keep line geometry aligned with lines. `false` deliberately preserves
        -- an unknown entry without creating a nil hole in the Lua array.
        line_boxes = line_boxes,
        vertical = block.vertical == true,
        font_size = finiteNumber(block.font_size) and block.font_size or nil,
    })
end

local function normalizePage(page, ordinal)
    if type(page) ~= "table"
            or not finiteNumber(page.img_width) or page.img_width <= 0
            or not finiteNumber(page.img_height) or page.img_height <= 0 then
        return nil
    end

    local blocks = {}
    if type(page.blocks) == "table" then
        for index = 1, #page.blocks do
            local block = normalizeBlock(page.blocks[index])
            if block then
                blocks[#blocks + 1] = block
            end
        end
    end

    blocks = repairSplitVerticalBlocks(blocks)

    return {
        ordinal = ordinal,
        img_width = page.img_width,
        img_height = page.img_height,
        blocks = blocks,
    }
end

function Mokuro.validate(value)
    if type(value) ~= "table" or type(value.pages) ~= "table" then
        return nil, "Missing pages array"
    end

    local page_count = #value.pages
    local pages = {}
    local valid_page_count = 0
    -- false is an intentional placeholder. Unlike nil it preserves the ordinal
    -- of later pages when rapidjson decoded a JSON null in a partial result.
    for ordinal = 1, page_count do
        local page = normalizePage(value.pages[ordinal], ordinal)
        pages[ordinal] = page or false
        if page then
            valid_page_count = valid_page_count + 1
        end
    end

    return {
        version = value.version,
        pages = pages,
        page_count = page_count,
        valid_page_count = valid_page_count,
    }
end

function Mokuro.decode(content)
    if type(content) ~= "string" or content == "" then
        return nil, "Empty Mokuro data"
    end
    local ok, value = pcall(rapidjson.decode, content)
    if not ok then
        return nil, tostring(value)
    end
    return Mokuro.validate(value)
end

function Mokuro.getPage(data, ordinal)
    if type(data) ~= "table"
            or type(data.pages) ~= "table"
            or type(ordinal) ~= "number" then
        return nil
    end
    local page = data.pages[ordinal]
    return type(page) == "table" and page or nil
end

-- Script alone never makes text furigana: normal manga dialogue may be all
-- hiragana or katakana. It only makes a line eligible for the strict
-- kanji-adjacency geometry check below.
local function textIsKanaOnly(text)
    local has_kana = false
    local index = 1
    while index <= #text do
        local first_byte = text:byte(index)
        local codepoint = codepointAt(text, index)
        if isKanaCodepoint(codepoint) then
            has_kana = true
        elseif not isReadingPunctuation(codepoint) then
            return false
        end
        index = index + codepointLength(first_byte)
    end
    return has_kana
end

-- This main/ruby size-and-adjacency test adapts Manatan's MIT-licensed
-- furigana filtering heuristic. See THIRD_PARTY_NOTICES.md and
-- LICENSE.Manatan in release packages.
local function likelyFurigana(reading, base)
    if not reading.box
            or not base.box
            or reading.vertical ~= base.vertical
            or not textIsKanaOnly(reading.text)
            or not textHasHan(base.text) then
        return false
    end

    local reading_thickness
    local base_thickness
    local reading_length
    local base_length
    local overlap
    local gap
    if reading.vertical then
        reading_thickness = reading.box[3] - reading.box[1]
        base_thickness = base.box[3] - base.box[1]
        reading_length = reading.box[4] - reading.box[2]
        base_length = base.box[4] - base.box[2]
        overlap = intervalOverlap(
            reading.box[2],
            reading.box[4],
            base.box[2],
            base.box[4]
        )
        -- Ruby for vertical Japanese is immediately to the right of its base.
        gap = reading.box[1] - base.box[3]
    else
        reading_thickness = reading.box[4] - reading.box[2]
        base_thickness = base.box[4] - base.box[2]
        reading_length = reading.box[3] - reading.box[1]
        base_length = base.box[3] - base.box[1]
        overlap = intervalOverlap(
            reading.box[1],
            reading.box[3],
            base.box[1],
            base.box[3]
        )
        -- Ruby for horizontal Japanese is immediately above its base.
        gap = base.box[2] - reading.box[4]
    end

    return reading_thickness > 0
        and base_thickness > 0
        and reading_length > 0
        and base_length > 0
        and reading_thickness <= base_thickness * 0.75
        and reading_length <= base_length * 1.25
        and overlap >= reading_length * 0.75
        and gap >= -base_thickness * 0.35
        and gap <= base_thickness * 0.55
end

local function filteredPage(page)
    local entries = {}
    for block_index, block in ipairs(page.blocks) do
        for line_index, text in ipairs(block.lines) do
            entries[#entries + 1] = {
                block_index = block_index,
                line_index = line_index,
                text = text,
                box = block.line_boxes[line_index] or nil,
                vertical = block.vertical,
            }
        end
    end

    local hidden = {}
    for _, reading in ipairs(entries) do
        if textIsKanaOnly(reading.text) and reading.box then
            for _, base in ipairs(entries) do
                if reading ~= base and likelyFurigana(reading, base) then
                    hidden[reading.block_index] = hidden[reading.block_index] or {}
                    hidden[reading.block_index][reading.line_index] = true
                    break
                end
            end
        end
    end

    local blocks = {}
    for block_index, block in ipairs(page.blocks) do
        local lines = {}
        local line_boxes = {}
        local all_boxes_known = true
        local box
        for line_index, text in ipairs(block.lines) do
            if not (hidden[block_index] and hidden[block_index][line_index]) then
                lines[#lines + 1] = text
                local line_box = block.line_boxes[line_index] or false
                line_boxes[#line_boxes + 1] = line_box
                if line_box then
                    if not box then
                        box = cloneBox(line_box)
                    else
                        box[1] = math.min(box[1], line_box[1])
                        box[2] = math.min(box[2], line_box[2])
                        box[3] = math.max(box[3], line_box[3])
                        box[4] = math.max(box[4], line_box[4])
                    end
                else
                    all_boxes_known = false
                end
            end
        end

        if #lines > 0 then
            blocks[#blocks + 1] = {
                box = all_boxes_known and box or cloneBox(block.box),
                lines = lines,
                line_boxes = line_boxes,
                vertical = block.vertical,
                font_size = block.font_size,
            }
        end
    end

    return {
        ordinal = page.ordinal,
        img_width = page.img_width,
        img_height = page.img_height,
        blocks = blocks,
    }
end

-- Return display data with probable ruby readings removed. The normalized
-- source remains untouched, so the setting can be toggled without rescanning.
function Mokuro.withoutFurigana(data)
    if type(data) ~= "table" or type(data.pages) ~= "table" then
        return data
    end

    local pages = {}
    for ordinal = 1, data.page_count do
        local page = data.pages[ordinal]
        pages[ordinal] = type(page) == "table" and filteredPage(page) or false
    end
    return {
        version = data.version,
        pages = pages,
        page_count = data.page_count,
        valid_page_count = data.valid_page_count,
    }
end

function Mokuro.getBlockText(block)
    if type(block) ~= "table" or type(block.lines) ~= "table" then
        return ""
    end

    local text
    for _, line in ipairs(block.lines) do
        if type(line) == "string" then
            if text == nil then
                text = line
            else
                text = text .. lineSeparator(text, line) .. line
            end
        end
    end
    return text or ""
end

-- Convert OCR image coordinates to the document's native page coordinates.
-- ReaderView remains responsible for zoom, crop, rotation, scroll and dual-page
-- placement through pageToScreenTransform.
function Mokuro.boxToNativeRect(box, image_width, image_height, native_dimensions)
    box = normalizeBox(box)
    if not box
            or not finiteNumber(image_width) or image_width <= 0
            or not finiteNumber(image_height) or image_height <= 0
            or type(native_dimensions) ~= "table"
            or not finiteNumber(native_dimensions.w) or native_dimensions.w <= 0
            or not finiteNumber(native_dimensions.h) or native_dimensions.h <= 0 then
        return nil
    end

    local left = math.max(0, math.min(image_width, box[1]))
    local top = math.max(0, math.min(image_height, box[2]))
    local right = math.max(0, math.min(image_width, box[3]))
    local bottom = math.max(0, math.min(image_height, box[4]))
    if right <= left or bottom <= top then
        return nil
    end

    local scale_x = native_dimensions.w / image_width
    local scale_y = native_dimensions.h / image_height
    return {
        x = left * scale_x,
        y = top * scale_y,
        w = (right - left) * scale_x,
        h = (bottom - top) * scale_y,
    }
end

function Mokuro.cleanupSelection(text)
    if type(text) ~= "string" then
        return ""
    end
    local cleaned = util.cleanupSelectedText(text)
    -- TextBoxWidget may insert visual spaces between CJK glyphs. Check actual
    -- Unicode ranges so spaces between non-CJK three-byte characters survive.
    cleaned = cleaned:gsub("()(%s+)()", function(before, whitespace, after)
        local left_codepoint = lastNonSpaceCodepoint(cleaned:sub(1, before - 1))
        local right_codepoint = firstNonSpaceCodepoint(cleaned:sub(after))
        if isCJKCodepoint(left_codepoint) and isCJKCodepoint(right_codepoint) then
            return ""
        end
        return whitespace
    end)
    return cleaned
end

return Mokuro

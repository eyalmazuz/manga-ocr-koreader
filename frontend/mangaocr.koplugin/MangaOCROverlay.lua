local Blitbuffer = require("ffi/blitbuffer")
local Geom = require("ui/geometry")
local Mokuro = require("MangaOCRMokuro")
local Widget = require("ui/widget/widget")

local Overlay = Widget:extend{
    data = nil,
    show_outlines = false,
    border_size = 1,
}

function Overlay:setData(data)
    self.data = data
end

function Overlay:setShowOutlines(enabled)
    self.show_outlines = enabled and true or false
end

function Overlay:_currentPages()
    local pages = self.view and self.view:getCurrentPageList() or {}
    if #pages == 0 and self.ui and self.ui.getCurrentPage then
        local page = self.ui:getCurrentPage()
        if page then
            pages[1] = page
        end
    end
    return pages
end

function Overlay:getScreenBlocks()
    local visible = {}
    if not self.data or not self.view or not self.ui or not self.ui.document then
        return visible
    end

    for _, ordinal in ipairs(self:_currentPages()) do
        local page = Mokuro.getPage(self.data, ordinal)
        if page and #page.blocks > 0 then
            local ok, native_dimensions = pcall(
                self.ui.document.getNativePageDimensions,
                self.ui.document,
                ordinal
            )
            if ok and native_dimensions then
                for _, block in ipairs(page.blocks) do
                    local native_rect = Mokuro.boxToNativeRect(
                        block.box,
                        page.img_width,
                        page.img_height,
                        native_dimensions
                    )
                    if native_rect then
                        local screen_rect = self.view:pageToScreenTransform(
                            ordinal,
                            Geom:new(native_rect)
                        )
                        if screen_rect and screen_rect.w > 0 and screen_rect.h > 0 then
                            visible[#visible + 1] = {
                                page = ordinal,
                                block = block,
                                rect = screen_rect,
                                area = screen_rect.w * screen_rect.h,
                            }
                        end
                    end
                end
            end
        end
    end
    return visible
end

function Overlay:findBlockAtScreenPosition(position)
    if not position then
        return nil
    end
    local best
    for _, candidate in ipairs(self:getScreenBlocks()) do
        local rect = candidate.rect
        if position.x >= rect.x and position.x <= rect.x + rect.w
                and position.y >= rect.y and position.y <= rect.y + rect.h
                and (not best or candidate.area < best.area) then
            best = candidate
        end
    end
    return best
end

function Overlay:paintTo(bb, x, y)
    if not self.show_outlines then
        return
    end
    for _, candidate in ipairs(self:getScreenBlocks()) do
        local rect = candidate.rect
        bb:paintBorder(
            math.floor(x + rect.x),
            math.floor(y + rect.y),
            math.max(1, math.ceil(rect.w)),
            math.max(1, math.ceil(rect.h)),
            self.border_size,
            Blitbuffer.COLOR_BLACK
        )
    end
end

return Overlay

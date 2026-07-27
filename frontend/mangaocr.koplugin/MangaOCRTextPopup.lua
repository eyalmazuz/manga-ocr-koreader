-- The popup layout and text-selection event forwarding adapt the MIT-licensed
-- mokuroreader-koreader plugin. See THIRD_PARTY_NOTICES.md and
-- LICENSE.mokuroreader-koreader in release packages.
local Blitbuffer = require("ffi/blitbuffer")
local BottomContainer = require("ui/widget/container/bottomcontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local InputContainer = require("ui/widget/container/inputcontainer")
local MovableContainer = require("ui/widget/container/movablecontainer")
local RegionLayout = require("MangaOCRRegionLayout")
local Selection = require("MangaOCRSelection")
local ScrollTextWidget = require("ui/widget/scrolltextwidget")
local Size = require("ui/size")
local UIManager = require("ui/uimanager")
local HorizontalSpan = require("ui/widget/horizontalspan")

local Screen = Device.screen
local SELECTION_PADDING = "  "
local FIRST_TEXT_INDEX = 3
local REGION_WIDTH_RATIO = 0.86
local REGION_HEIGHT_RATIO = 0.72
local REGION_SCALE = 1.3
local REGION_MIN_WIDTH = 120
local REGION_MIN_HEIGHT = 100
local REGION_COLUMN_GAP = Screen:scaleBySize(8)
local DEFAULT_REGION_FONT_SIZE = 44
local MIN_REGION_FONT_SIZE = 16

local function scaledRegionLimit(anchor, field, minimum, maximum, fallback)
    local source = anchor and anchor[field]
    if type(source) ~= "number" or source <= 0 then
        source = fallback
    end
    return math.min(
        maximum,
        math.max(minimum, math.floor(source * REGION_SCALE))
    )
end

local function verticalMetrics(lines, font_size)
    local max_characters = 1
    for _, line in ipairs(lines) do
        max_characters = math.max(max_characters, RegionLayout.utf8Length(line))
    end

    -- A compact column still needs room for the leading selection padding and
    -- one glyph. The old layout divided most of the screen between columns,
    -- which made short regions look disconnected from the tapped source.
    local column_width = math.max(
        math.floor(font_size * 1.75),
        font_size + 2 * Size.padding.small
    )
    local line_height = math.max(1, math.floor(font_size * 1.3))
    return {
        column_width = column_width,
        line_height = line_height,
        width = #lines * column_width + math.max(0, #lines - 1) * REGION_COLUMN_GAP,
        height = max_characters * line_height,
    }
end

local function readFontSize(setting, default)
    local value = G_reader_settings:readSetting(setting, default)
    if type(value) ~= "number" or value < 1 then
        return default
    end
    return math.floor(value)
end

local TextPopup = InputContainer:extend{
    modal = false,
    text = "",
    lines = nil,
    vertical = false,
    region_mode = false,
    anchor = nil,
    on_selection = nil,
    close_callback = nil,
}

function TextPopup:init()
    local is_region = self.region_mode == true and self.anchor ~= nil
    local padding = Size.padding.large
    local border = Size.border.window
    local width
    local height
    if is_region then
        width = scaledRegionLimit(
            self.anchor,
            "w",
            Screen:scaleBySize(REGION_MIN_WIDTH),
            math.floor(Screen:getWidth() * REGION_WIDTH_RATIO),
            math.floor(Screen:getWidth() * 0.45)
        )
        height = scaledRegionLimit(
            self.anchor,
            "h",
            Screen:scaleBySize(REGION_MIN_HEIGHT),
            math.floor(Screen:getHeight() * REGION_HEIGHT_RATIO),
            math.floor(Screen:getHeight() * 0.35)
        )
    else
        width = Screen:getWidth()
        height = math.floor(Screen:getHeight() / 3)
    end
    local content_width = math.max(1, width - 2 * padding - 2 * border)
    local content_height = math.max(1, height - 2 * padding - 2 * border)
    local font_size = is_region
        and readFontSize("mangaocr_region_font_size", DEFAULT_REGION_FONT_SIZE)
        or readFontSize("mangaocr_font_size", 40)
    local language = G_reader_settings:readSetting("mangaocr_language", "ja")
    if type(language) ~= "string" then
        language = "ja"
    end

    self.text_widgets = {}
    self.vertical_popup = is_region and self.vertical == true

    if self.vertical_popup and type(self.lines) == "table" then
        local lines = RegionLayout.orderedVerticalLines(self.lines)
        if #lines > 0 then
            local metrics = verticalMetrics(lines, font_size)
            -- Fit a region to a bounded enlargement of the source box. The
            -- font is reduced only when the text would exceed that bound; the
            -- resulting widget uses the text's natural dimensions, so short
            -- regions do not become full-screen panels.
            while font_size > MIN_REGION_FONT_SIZE
                    and (metrics.width > content_width
                        or metrics.height > content_height) do
                font_size = font_size - 1
                metrics = verticalMetrics(lines, font_size)
            end

            -- The source box is a sizing hint, not a clipping rectangle. If
            -- the minimum readable font still needs more room, let the popup
            -- grow to the natural text size so the last column is not hidden.
            local maximum_content_width = math.max(
                1,
                math.floor(Screen:getWidth() * REGION_WIDTH_RATIO)
                    - 2 * padding - 2 * border
            )
            local maximum_content_height = math.max(
                1,
                math.floor(Screen:getHeight() * REGION_HEIGHT_RATIO)
                    - 2 * padding - 2 * border
            )
            content_width = math.min(maximum_content_width, metrics.width)
            content_height = math.min(maximum_content_height, metrics.height)
            local column_width = metrics.column_width
            local column_gap = math.max(
                Size.padding.small,
                math.floor(font_size * 0.18),
                REGION_COLUMN_GAP
            )
            local group_width = #lines * column_width
                + math.max(0, #lines - 1) * column_gap
            if group_width > content_width then
                column_gap = math.max(
                    0,
                    math.floor((content_width - #lines * column_width)
                        / math.max(1, #lines - 1))
                )
            end

            self.content_widget = HorizontalGroup:new{
                align = "top",
                allow_mirroring = false,
            }
            for index, line in ipairs(lines) do
                -- Each OCR line becomes a top-to-bottom column. The visual
                -- order is reversed by orderedVerticalLines so the first
                -- Japanese reading column appears on the right.
                local line_height = math.min(
                    content_height,
                    math.max(
                        metrics.line_height,
                        RegionLayout.utf8Length(line) * metrics.line_height
                    )
                )
                local text_widget = ScrollTextWidget:new{
                    text = RegionLayout.verticalColumnText(line, SELECTION_PADDING),
                    face = Font:getFace("cfont", font_size),
                    width = column_width,
                    height = line_height,
                    scroll_bar_width = 0,
                    text_scroll_span = 0,
                    dialog = self,
                    justified = false,
                    para_direction_rtl = false,
                    auto_para_direction = false,
                    alignment = "center",
                    lang = language,
                    highlight_text_selection = true,
                }
                if language:match("^ja") then
                    Selection.enableExactXtextRanges(
                        text_widget.text_widget,
                        FIRST_TEXT_INDEX
                    )
                end
                self.text_widgets[#self.text_widgets + 1] = text_widget
                self.content_widget[#self.content_widget + 1] = text_widget
                if index < #lines then
                    self.content_widget[#self.content_widget + 1] = HorizontalSpan:new{
                        width = column_gap,
                    }
                end
            end
            self.vertical_popup = #self.text_widgets > 0
        end
        -- Empty or malformed line data should still leave a usable popup.
        if #self.text_widgets == 0 then
            self.vertical_popup = false
        end
    end

    if not self.vertical_popup then
        self.text_widget = ScrollTextWidget:new{
            -- TextBoxWidget cannot reliably start a touch selection on a glyph
            -- flush with the beginning of the text. Leading spaces provide a
            -- small hit area before the first real character; lookup cleanup
            -- removes them from the selected text.
            text = SELECTION_PADDING .. self.text,
            face = Font:getFace("cfont", font_size),
            width = content_width,
            height = content_height,
            dialog = self,
            justified = false,
            para_direction_rtl = false,
            auto_para_direction = false,
            alignment = "left",
            lang = language,
            highlight_text_selection = true,
        }
        self.text_widgets[1] = self.text_widget
        if language:match("^ja") then
            Selection.enableExactXtextRanges(
                self.text_widget.text_widget,
                FIRST_TEXT_INDEX
            )
        end
        self.content_widget = self.text_widget
    end

    self.frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = border,
        padding = padding,
        margin = 0,
        self.content_widget,
    }
    if is_region then
        local popup_size = self.frame:getSize()
        local popup_x = self.anchor.x
            + (self.anchor.w - popup_size.w) / 2
        local popup_y = self.anchor.y
            + (self.anchor.h - popup_size.h) / 2
        popup_x = math.max(
            0,
            math.min(Screen:getWidth() - popup_size.w, popup_x)
        )
        popup_y = math.max(
            0,
            math.min(Screen:getHeight() - popup_size.h, popup_y)
        )
        local centered_popup = MovableContainer:new{
            unmovable = true,
            self.frame,
        }
        centered_popup:setMovedOffset(Geom:new{
            x = popup_x,
            y = popup_y,
        })
        self[1] = centered_popup
    else
        self[1] = BottomContainer:new{
            dimen = Screen:getSize(),
            self.frame,
        }
    end

    if Device:isTouchDevice() then
        local screen_range = Geom:new{
            x = 0,
            y = 0,
            w = Screen:getWidth(),
            h = Screen:getHeight(),
        }
        local hold_pan_rate = G_reader_settings:readSetting("hold_pan_rate")
        if not hold_pan_rate then
            hold_pan_rate = Screen.low_pan_rate and 5.0 or 30.0
        end
        self.ges_events = {
            TapClose = {
                GestureRange:new{
                    ges = "tap",
                    range = screen_range,
                },
            },
            HoldStartText = {
                GestureRange:new{
                    ges = "hold",
                    range = screen_range,
                },
            },
            HoldPanText = {
                GestureRange:new{
                    ges = "hold_pan",
                    range = screen_range,
                    rate = hold_pan_rate,
                },
            },
            HoldReleaseText = {
                GestureRange:new{
                    ges = "hold_release",
                    range = screen_range,
                },
            },
        }
    end

    if Device:hasKeys() then
        self.key_events = {
            Close = { { Device.input.group.Back } },
        }
    end
end

function TextPopup:onHoldStartText(arg, gesture)
    if self.vertical_popup then
        self.active_text_widget = self:_textWidgetAt(gesture.pos)
        if not self.active_text_widget then
            return false
        end
        return self.active_text_widget.text_widget:onHoldStartText(arg, gesture)
    end
    return self.text_widget.text_widget:onHoldStartText(arg, gesture)
end

function TextPopup:onHoldPanText(arg, gesture)
    local text_widget = self.vertical_popup
        and self.active_text_widget
        or self.text_widget
    if not text_widget then
        return false
    end
    return text_widget.text_widget:onHoldPanText(arg, gesture)
end

function TextPopup:onHoldReleaseText(_, gesture)
    local text_widget = self.vertical_popup
        and self.active_text_widget
        or self.text_widget
    if not text_widget then
        return false
    end
    local handled = text_widget.text_widget:onHoldReleaseText(function(text, hold_duration)
        if self.on_selection and text and text ~= "" then
            self.on_selection(text, hold_duration, function()
                if text_widget and text_widget.text_widget then
                    text_widget.text_widget:scheduleClearHighlightAndRedraw()
                end
            end)
        end
    end, gesture)
    self.active_text_widget = nil
    return handled
end

function TextPopup:_textWidgetAt(position)
    if not position then
        return nil
    end
    for _, text_widget in ipairs(self.text_widgets or {}) do
        local widget = text_widget.text_widget
        local dimen = widget and widget.dimen
        if dimen and position.x >= dimen.x and position.x < dimen.x + dimen.w
                and position.y >= dimen.y and position.y < dimen.y + dimen.h then
            return text_widget
        end
    end
    return nil
end

function TextPopup:onTapClose(_, gesture)
    if self.frame.dimen and gesture.pos:notIntersectWith(self.frame.dimen) then
        UIManager:close(self)
        return true
    end
    return false
end

function TextPopup:onClose()
    UIManager:close(self)
    return true
end

function TextPopup:onCloseWidget()
    if not self._close_callback_called and self.close_callback then
        self._close_callback_called = true
        self.close_callback(self)
    end
    if self.frame and self.frame.dimen then
        UIManager:setDirty(nil, "partial", self.frame.dimen)
    end
end

return TextPopup

-- The popup layout and text-selection event forwarding adapt the MIT-licensed
-- mokuroreader-koreader plugin. See THIRD_PARTY_NOTICES.md and
-- LICENSE.mokuroreader-koreader in release packages.
local Blitbuffer = require("ffi/blitbuffer")
local BottomContainer = require("ui/widget/container/bottomcontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
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
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")

local Screen = Device.screen
local SELECTION_PADDING = "  "
local FIRST_TEXT_INDEX = 3
local REGION_WIDTH_RATIO = 0.86
local REGION_HEIGHT_RATIO = 0.72
local REGION_SCALE = 1.3
local REGION_MIN_WIDTH = 120
local REGION_MIN_HEIGHT = 100
local DEFAULT_REGION_FONT_SIZE = 44
local MIN_REGION_FONT_SIZE = 16
local ABSOLUTE_MIN_REGION_FONT_SIZE = 8

local function hasValidAnchor(anchor)
    return type(anchor) == "table"
        and type(anchor.x) == "number"
        and type(anchor.y) == "number"
        and type(anchor.w) == "number"
        and anchor.w > 0
        and type(anchor.h) == "number"
        and anchor.h > 0
end

local function scaledRegionLimit(anchor, field, minimum, maximum)
    return math.min(
        maximum,
        math.max(minimum, math.floor(anchor[field] * REGION_SCALE))
    )
end

local function verticalMetrics(lines, font_size)
    local font_pixels = Screen:scaleBySize(font_size)
    local max_characters = 1
    for _, line in ipairs(lines) do
        max_characters = math.max(max_characters, RegionLayout.utf8Length(line))
    end

    local column_width = math.max(
        math.floor(font_pixels * 1.45),
        font_pixels + 2 * Size.padding.small
    )
    local line_height = math.max(1, math.floor(font_pixels * 1.3))
    return {
        column_width = column_width,
        line_height = line_height,
        width = #lines * column_width,
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
    local is_region = self.region_mode == true and hasValidAnchor(self.anchor)
    local padding = Size.padding.large
    local border = Size.border.window
    local width
    local height
    if is_region then
        width = scaledRegionLimit(
            self.anchor,
            "w",
            Screen:scaleBySize(REGION_MIN_WIDTH),
            math.floor(Screen:getWidth() * REGION_WIDTH_RATIO)
        )
        height = scaledRegionLimit(
            self.anchor,
            "h",
            Screen:scaleBySize(REGION_MIN_HEIGHT),
            math.floor(Screen:getHeight() * REGION_HEIGHT_RATIO)
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
            local metrics = verticalMetrics(lines, font_size)
            while font_size > MIN_REGION_FONT_SIZE
                    and (metrics.width > content_width
                        or metrics.height > content_height) do
                font_size = font_size - 1
                metrics = verticalMetrics(lines, font_size)
            end

            -- Very long regions may still exceed the screen at the normal
            -- minimum. Keep shrinking in that unusual case instead of
            -- clipping an entire column or the end of the text.
            while font_size > ABSOLUTE_MIN_REGION_FONT_SIZE
                    and (metrics.width > maximum_content_width
                        or metrics.height > maximum_content_height) do
                font_size = font_size - 1
                metrics = verticalMetrics(lines, font_size)
            end

            local columns = HorizontalGroup:new{
                align = "top",
                allow_mirroring = false,
            }
            local face = Font:getFace("cfont", font_size)
            for _, line in ipairs(lines) do
                local text_widget = TextBoxWidget:new{
                    -- Each OCR line is its own selectable top-to-bottom
                    -- column. The surrounding frame remains one popup.
                    text = RegionLayout.verticalColumnText(line),
                    face = face,
                    width = metrics.column_width,
                    dialog = self,
                    justified = false,
                    para_direction_rtl = false,
                    auto_para_direction = false,
                    alignment = "center",
                    alignment_strict = true,
                    lang = language,
                    highlight_text_selection = true,
                }
                if language:match("^ja") then
                    Selection.enableExactXtextRanges(text_widget, 1)
                end
                self.text_widgets[#self.text_widgets + 1] = text_widget
                columns[#columns + 1] = text_widget
            end

            local column_size = columns:getSize()
            content_width = math.min(
                maximum_content_width,
                math.max(content_width, column_size.w)
            )
            content_height = math.min(
                maximum_content_height,
                math.max(content_height, column_size.h)
            )
            self.content_widget = CenterContainer:new{
                dimen = Geom:new{
                    w = content_width,
                    h = content_height,
                },
                columns,
            }
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
        self.text_widgets[1] = self.text_widget.text_widget
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
        local popup_x = math.floor(self.anchor.x
            + (self.anchor.w - popup_size.w) / 2
        )
        local popup_y = math.floor(self.anchor.y
            + (self.anchor.h - popup_size.h) / 2
        )
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
                -- Supplying the callback as event args lets KOReader route the
                -- release to whichever text widget consumed the hold. This is
                -- important when a vertical popup contains several columns.
                args = function(text, hold_duration)
                    if self.on_selection and text and text ~= "" then
                        self.on_selection(text, hold_duration, function()
                            for _, text_widget in ipairs(self.text_widgets) do
                                text_widget:scheduleClearHighlightAndRedraw()
                            end
                        end)
                    end
                end,
            },
        }
    end

    if Device:hasKeys() then
        self.key_events = {
            Close = { { Device.input.group.Back } },
        }
    end
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

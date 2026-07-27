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

local Screen = Device.screen
local SELECTION_PADDING = "  "
local FIRST_TEXT_INDEX = 3
local REGION_WIDTH_RATIO = 0.86
local REGION_HEIGHT_RATIO = 0.72
local DEFAULT_REGION_FONT_SIZE = 52
local MIN_REGION_FONT_SIZE = 24

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
    local width = is_region
        and math.floor(Screen:getWidth() * REGION_WIDTH_RATIO)
        or Screen:getWidth()
    local height = is_region
        and math.floor(Screen:getHeight() * REGION_HEIGHT_RATIO)
        or math.floor(Screen:getHeight() / 3)
    local padding = Size.padding.large
    local border = Size.border.window
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
        local column_count = math.max(1, #lines)
        local column_width = math.max(1, math.floor(content_width / column_count))
        local maximum_font_size = column_width - 2 * Size.padding.small
        if maximum_font_size >= MIN_REGION_FONT_SIZE then
            font_size = math.min(font_size, maximum_font_size)
        else
            font_size = MIN_REGION_FONT_SIZE
        end
        column_width = math.max(column_width, font_size + 2 * Size.padding.small)
        self.content_widget = HorizontalGroup:new{
            align = "top",
            allow_mirroring = false,
        }
        for _, line in ipairs(lines) do
            local text_widget = ScrollTextWidget:new{
                -- Each OCR line becomes a top-to-bottom column. The visual
                -- order is reversed by orderedVerticalLines so the first
                -- Japanese reading column appears on the right.
                text = RegionLayout.verticalColumnText(line, SELECTION_PADDING),
                face = Font:getFace("cfont", font_size),
                width = column_width,
                height = content_height,
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
        self[1] = MovableContainer:new{
            anchor = self.anchor,
            unmovable = true,
            self.frame,
        }
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

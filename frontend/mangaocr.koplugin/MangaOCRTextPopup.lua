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
local InputContainer = require("ui/widget/container/inputcontainer")
local Selection = require("MangaOCRSelection")
local ScrollTextWidget = require("ui/widget/scrolltextwidget")
local Size = require("ui/size")
local UIManager = require("ui/uimanager")

local Screen = Device.screen
local SELECTION_PADDING = "  "
local FIRST_TEXT_INDEX = 3

local TextPopup = InputContainer:extend{
    modal = false,
    text = "",
    on_selection = nil,
    close_callback = nil,
}

function TextPopup:init()
    local width = Screen:getWidth()
    local height = math.floor(Screen:getHeight() / 3)
    local padding = Size.padding.large
    local border = Size.border.window
    local content_width = math.max(1, width - 2 * padding - 2 * border)
    local content_height = math.max(1, height - 2 * padding - 2 * border)
    local font_size = G_reader_settings:readSetting("mangaocr_font_size", 40)
    local language = G_reader_settings:readSetting("mangaocr_language", "ja")
    if type(language) ~= "string" then
        language = "ja"
    end

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
    if language:match("^ja") then
        Selection.enableExactXtextRanges(
            self.text_widget.text_widget,
            FIRST_TEXT_INDEX
        )
    end
    self.frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = border,
        padding = padding,
        margin = 0,
        self.text_widget,
    }
    self[1] = BottomContainer:new{
        dimen = Screen:getSize(),
        self.frame,
    }

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
    return self.text_widget.text_widget:onHoldStartText(arg, gesture)
end

function TextPopup:onHoldPanText(arg, gesture)
    return self.text_widget.text_widget:onHoldPanText(arg, gesture)
end

function TextPopup:onHoldReleaseText(_, gesture)
    return self.text_widget.text_widget:onHoldReleaseText(function(text, hold_duration)
        if self.on_selection and text and text ~= "" then
            self.on_selection(text, hold_duration, function()
                if self.text_widget and self.text_widget.text_widget then
                    self.text_widget.text_widget:scheduleClearHighlightAndRedraw()
                end
            end)
        end
    end, gesture)
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

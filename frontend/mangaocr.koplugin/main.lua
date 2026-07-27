local ConfirmBox = require("ui/widget/confirmbox")
local DocumentSource = require("MangaOCRDocument")
local Event = require("ui/event")
local InfoMessage = require("ui/widget/infomessage")
local Mokuro = require("MangaOCRMokuro")
local NetworkMgr = require("ui/network/manager")
local Overlay = require("MangaOCROverlay")
local ProgressbarDialog = require("ui/widget/progressbardialog")
local Storage = require("MangaOCRStorage")
local TextPopup = require("MangaOCRTextPopup")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Worker = require("MangaOCRWorker")
local logger = require("logger")
local rapidjson = require("rapidjson")
local time = require("ui/time")
local util = require("util")
local _ = require("gettext")
local T = require("ffi/util").template

local active_rendered_scans = {}

local MangaOCR = WidgetContainer:extend{
    name = "mangaocr",
    is_doc_only = false,
}

function MangaOCR:init()
    self.storage = Storage:new()
    self.scan_progress = {}
    self.rendered_scan_jobs = active_rendered_scans

    if self.ui.name == "ReaderUI" then
        self:_initReader()
    -- PluginLoader passes the FileManager container itself here. It has no
    -- `name`; only its nested FileChooser is named "filemanager". Detect the
    -- public extension API instead so this also works across KOReader versions.
    elseif type(self.ui.addFileDialogButtons) == "function" then
        self._is_filemanager = true
        self:_initFileManager()
    end
end

function MangaOCR:_showMessage(text, timeout)
    UIManager:show(InfoMessage:new{
        text = text,
        timeout = timeout,
    })
end

function MangaOCR:_closeFileDialog()
    local chooser = self.ui and self.ui.file_chooser
    if chooser and chooser.file_dialog then
        UIManager:close(chooser.file_dialog)
    end
end

function MangaOCR:_initFileManager()
    self.ui:addFileDialogButtons("mangaocr_scan", function(file, is_file)
        if not is_file or not self.storage:isSupported(file) then
            return nil
        end

        local row = {
            {
                text = _("Scan manga with Google Lens"),
                callback = function()
                    self:_closeFileDialog()
                    self:_requestScan(file, false)
                end,
            },
        }
        if self.storage:hasCache(file) then
            row[#row + 1] = {
                text = _("Rescan manga"),
                callback = function()
                    self:_closeFileDialog()
                    self:_requestScan(file, true)
                end,
            }
        end
        return row
    end)

    self.ui:addFileDialogButtons("mangaocr_delete", function(file, is_file)
        if not is_file
                or not self.storage:isSupported(file)
                or not self.storage:hasCache(file) then
            return nil
        end
        local row = {}
        if self.storage:hasFailures(file) then
            row[#row + 1] = {
                text = _("Retry failed pages"),
                callback = function()
                    self:_closeFileDialog()
                    self:_requestScan(file, false, nil, true)
                end,
            }
        end
        row[#row + 1] = {
            text = _("Delete Manga OCR cache"),
            callback = function()
                self:_closeFileDialog()
                self:_confirmDeleteCache(file)
            end,
        }
        return row
    end)
end

function MangaOCR:_initReader()
    self.hotspots_enabled = G_reader_settings:nilOrTrue("mangaocr_hotspots_enabled")
    self.region_popup_enabled = G_reader_settings:nilOrTrue("mangaocr_region_popup_enabled")
    self.show_outlines = G_reader_settings:isTrue("mangaocr_show_outlines")
    self.hide_furigana = G_reader_settings:nilOrTrue("mangaocr_hide_furigana")
    self.overlay = Overlay:new{
        show_outlines = self.show_outlines,
    }
    self.ui.menu:registerToMainMenu(self)
end

function MangaOCR:_currentDocumentPath()
    return self.ui
        and self.ui.document
        and self.ui.document.file
        or nil
end

function MangaOCR:_isCurrentDocumentSupported()
    return self.storage:isSupported(self:_currentDocumentPath())
end

function MangaOCR:onReaderReady()
    if not self:_isCurrentDocumentSupported() then
        return
    end

    if not self._overlay_registered then
        self.ui.view:registerViewModule("mangaocr_overlay", self.overlay)
        self._overlay_registered = true
    end
    self:_registerTouchZones()
    self:loadOCR(true)
    self:_attachToRunningScan(self:_currentDocumentPath())
end

function MangaOCR:_registerTouchZones()
    if self._touch_zones_registered then
        return
    end
    self._touch_zones_registered = true
    self.ui:registerTouchZones({
        {
            id = "mangaocr_tap",
            ges = "tap",
            screen_zone = {
                ratio_x = 0,
                ratio_y = 0,
                ratio_w = 1,
                ratio_h = 1,
            },
            overrides = {
                "readerhighlight_tap",
                "tap_top_left_corner",
                "tap_top_right_corner",
                "tap_left_bottom_corner",
                "tap_right_bottom_corner",
                "readerfooter_tap",
                "readerconfigmenu_ext_tap",
                "readerconfigmenu_tap",
                "readermenu_ext_tap",
                "readermenu_tap",
                "tap_forward",
                "tap_backward",
            },
            handler = function(gesture)
                return self:onMangaOCRTap(gesture)
            end,
        },
    })
end

function MangaOCR:_redrawReader()
    if self.ui and self.ui.name == "ReaderUI" then
        UIManager:setDirty(self.ui, "ui")
    end
end

function MangaOCR:_applyFuriganaSetting()
    self.mokuro_data = self.mokuro_raw_data
    if self.hide_furigana and self.mokuro_raw_data then
        self.mokuro_data = Mokuro.withoutFurigana(self.mokuro_raw_data)
    end
    if self.overlay then
        self.overlay:setData(self.mokuro_data)
    end
    self:_redrawReader()
end

function MangaOCR:loadOCR(silent)
    local path = self:_currentDocumentPath()
    if not self.storage:isSupported(path) then
        self.mokuro_raw_data = nil
        self.mokuro_data = nil
        self.mokuro_source = nil
        if self.overlay then
            self.overlay:setData(nil)
        end
        return false
    end

    local loaded
    local candidates = self.storage:getCandidates(path)
    for _, candidate in ipairs(candidates) do
        if candidate.content then
            local data, parse_error = Mokuro.decode(candidate.content)
            if data then
                loaded = {
                    data = data,
                    source = candidate,
                }
                break
            end
            logger.warn("Manga OCR: ignoring malformed", candidate.kind, "Mokuro:", parse_error)
        end
    end

    self.mokuro_raw_data = loaded and loaded.data or nil
    self.mokuro_source = loaded and loaded.source or nil
    self:_applyFuriganaSetting()

    if not silent then
        if self.mokuro_data then
            self:_showMessage(T(
                _("Loaded OCR for %1 of %2 manga pages."),
                self.mokuro_data.valid_page_count,
                self.mokuro_data.page_count
            ))
        else
            self:_showMessage(_("No valid .mokuro data was found for this manga."))
        end
    end
    return self.mokuro_data ~= nil
end

function MangaOCR:onMangaOCRTap(gesture)
    if not self.hotspots_enabled or not self.mokuro_data or not self.overlay then
        return false
    end
    local hit = self.overlay:findBlockAtScreenPosition(gesture.pos)
    if not hit then
        return false
    end
    return self:_showTextBlock(hit.block, hit.rect)
end

function MangaOCR:_showTextBlock(block, anchor)
    local block_text = Mokuro.getBlockText(block)
    if block_text == "" then
        return false
    end

    if self.text_popup then
        UIManager:close(self.text_popup)
    end
    self._previous_highlight_selection = self.ui.highlight
        and self.ui.highlight.selected_text
        or nil

    local popup
    popup = TextPopup:new{
        text = block_text,
        lines = block.lines,
        vertical = block.vertical == true,
        region_mode = self.region_popup_enabled,
        anchor = anchor,
        on_selection = function(selected_text, hold_duration, clear_callback)
            self:_lookupSelection(selected_text, hold_duration, clear_callback)
        end,
        close_callback = function(closed_popup)
            self:_onTextPopupClosed(closed_popup)
        end,
    }
    self.text_popup = popup
    UIManager:show(popup)
    return true
end

function MangaOCR:_lookupSelection(selected_text, hold_duration, clear_callback)
    local cleaned = Mokuro.cleanupSelection(selected_text)
    if cleaned == "" then
        return
    end

    self._owned_highlight_selection = { text = cleaned }
    if self.ui.highlight then
        self.ui.highlight.selected_text = self._owned_highlight_selection
    end

    local lookup_event = hold_duration < time.s(3)
        and "LookupWord"
        or "LookupWikipedia"
    self.ui:handleEvent(Event:new(
        lookup_event,
        cleaned,
        nil,
        nil,
        nil,
        nil,
        clear_callback
    ))
end

function MangaOCR:_onTextPopupClosed(popup)
    if self.text_popup == popup then
        self.text_popup = nil
    end
    if self.ui.highlight
            and self.ui.highlight.selected_text == self._owned_highlight_selection then
        self.ui.highlight.selected_text = self._previous_highlight_selection
    end
    self._owned_highlight_selection = nil
    self._previous_highlight_selection = nil
end

function MangaOCR:_privacyConfirmed(callback)
    if G_reader_settings:isTrue("mangaocr_google_lens_privacy_acknowledged") then
        callback()
        return
    end

    UIManager:show(ConfirmBox:new{
        text = _(
            "Google Lens OCR uploads the manga pages you scan to Google through an unofficial, unsupported endpoint. "
            .. "This is not a private or offline operation. Continue?"
        ),
        ok_text = _("I understand"),
        ok_callback = function()
            G_reader_settings:makeTrue("mangaocr_google_lens_privacy_acknowledged")
            callback()
        end,
    })
end

function MangaOCR:_requestScan(path, force, page, retry_failed)
    if not self.storage:isSupported(path) then
        self:_showMessage(_(
            "Manga OCR can scan supported image archives, raster images, "
            .. "and fixed-layout KOReader documents."
        ))
        return
    end

    self:_privacyConfirmed(function()
        self:_showMessage(_("Waiting for an Internet connection to start OCR…"), 3)
        NetworkMgr:runWhenOnline(function()
            self:_startScan(path, force, page, retry_failed)
        end)
    end)
end

function MangaOCR:_startScan(path, force, page, retry_failed)
    local ok, directory_error = self.storage:ensureDirectories()
    if not ok then
        self:_showMessage(T(_("Could not create the Manga OCR cache: %1"), directory_error))
        return
    end

    local paths = self.storage:getPaths(path)
    if Worker.isRunning(paths.output) or self.rendered_scan_jobs[paths.output] then
        self:_attachToRunningScan(path)
        self:_showMessage(_("An OCR scan for this manga is already running."), 3)
        return
    end
    if not self.storage:isDirect(path) then
        self:_startRenderedScan(path, paths, force, page, retry_failed)
        return
    end
    self:_startDirectScan(path, paths, force, page, retry_failed)
end

function MangaOCR:_startDirectScan(path, paths, force, page, retry_failed)
    local listener = self:_makeWorkerListener(path, paths)
    local job, worker_error, already_running = Worker.start({
        input = path,
        output = paths.output,
        status = paths.status,
        log = paths.log,
        language = G_reader_settings:readSetting("mangaocr_language", "ja"),
        force = force,
        page = page,
        retry_failed = retry_failed,
    }, listener)
    if not job then
        self:_showMessage(worker_error)
        return
    end
    self._attached_jobs = self._attached_jobs or {}
    self._attached_jobs[paths.output] = true

    self.scan_progress[paths.output] = self.scan_progress[paths.output] or {
        paths = paths,
        input = path,
    }
    if already_running then
        self:_showMessage(_("An OCR scan for this manga is already running."), 3)
    else
        local message
        if page then
            message = T(_("Scanning manga page %1 in the background."), page)
        elseif retry_failed then
            message = _("Retrying failed manga pages in the background.")
        else
            message = _("Scanning the manga in the background.")
        end
        self:_showMessage(message, 3)
    end
end

function MangaOCR:_renderedPageList(page_count, page, retry_failed, path)
    if page then
        if page < 1 or page > page_count then
            return nil, T(
                _("Page %1 is outside this document's 1–%2 page range."),
                page,
                page_count
            )
        end
        return { page }
    end

    if retry_failed then
        local pages = {}
        for _, failed_page in ipairs(self.storage:getFailedPageIndices(path)) do
            if failed_page <= page_count then
                pages[#pages + 1] = failed_page
            end
        end
        if #pages == 0 then
            return nil, _("There are no failed pages to retry.")
        end
        return pages
    end

    local pages = {}
    for page_index = 1, page_count do
        pages[#pages + 1] = page_index
    end
    return pages
end

function MangaOCR:_removeRenderedStaging(paths)
    os.remove(paths.page)
    os.remove(paths.manifest)
end

function MangaOCR:_forEachRenderedObserver(job, callback)
    for observer in pairs(job.observers or {}) do
        local ok, observer_error = xpcall(function()
            callback(observer)
        end, debug.traceback)
        if not ok then
            logger.warn(
                "Manga OCR: rendered scan observer failed:",
                observer_error
            )
        end
    end
end

function MangaOCR:_notifyRenderedStatus(job, status)
    self:_forEachRenderedObserver(job, function(observer)
        observer:_onScanStatus(job.path, job.paths, status)
    end)
end

function MangaOCR:_runRenderedSafely(job, callback)
    local ok, callback_error = xpcall(callback, debug.traceback)
    if ok then
        return
    end
    logger.err("Manga OCR: rendered scan failed:", callback_error)
    self:_finishRenderedScan(job, tostring(callback_error))
end

function MangaOCR:_scheduleRenderedStep(job)
    UIManager:nextTick(function()
        self:_runRenderedSafely(job, function()
            self:_runNextRenderedPage(job)
        end)
    end)
end

function MangaOCR:_startRenderedScan(path, paths, force, page, retry_failed)
    -- Acquire a separate registry reference so rendering can finish even if
    -- the reader closes while a background scan is active.
    local session, session_error = DocumentSource.open(path)
    if not session then
        self:_showMessage(T(
            _("Could not prepare this document for OCR: %1"),
            session_error
        ))
        return
    end

    local page_count, page_count_error = session:getPageCount()
    if not page_count then
        session:close()
        self:_showMessage(T(
            _("Could not determine the document page count: %1"),
            page_count_error
        ))
        return
    end
    local pages, pages_error = self:_renderedPageList(
        page_count,
        page,
        retry_failed,
        path
    )
    if not pages then
        session:close()
        self:_showMessage(pages_error)
        return
    end

    self:_removeRenderedStaging(paths)
    local rendered_job = {
        path = path,
        paths = paths,
        session = session,
        pages = pages,
        position = 1,
        succeeded = 0,
        failed = 0,
        completed = 0,
        consecutive_service_failures = 0,
        force_page = force and page ~= nil,
        reset_before_first = force and page == nil,
        skip_completed = not force and page == nil and not retry_failed,
        language = G_reader_settings:readSetting("mangaocr_language", "ja"),
        observers = setmetatable({ [self] = true }, { __mode = "k" }),
    }
    self.rendered_scan_jobs[paths.output] = rendered_job
    UIManager:preventStandby()
    rendered_job.standby_prevented = true
    self.scan_progress[paths.output] = {
        paths = paths,
        input = path,
    }
    self:_notifyRenderedStatus(rendered_job, {
        current = 0,
        total = #pages,
        succeeded = 0,
        failed = 0,
    })
    self:_showMessage(
        page and _("Preparing the current page for OCR.")
            or _("Preparing document pages for OCR in the background."),
        3
    )
    self:_scheduleRenderedStep(rendered_job)
end

function MangaOCR:_writeRenderedManifest(job, page_index)
    local manifest, manifest_error = job.session:buildManifest({
        {
            index = page_index,
            path = job.paths.page,
        },
    })
    if not manifest then
        return nil, manifest_error
    end

    local encode_ok, content = pcall(rapidjson.encode, manifest)
    if not encode_ok or type(content) ~= "string" then
        return nil, "Could not encode the rendered-page manifest"
    end
    local write_ok, write_error = util.writeToFile(
        content,
        job.paths.manifest,
        true,
        false,
        true
    )
    if not write_ok then
        return nil, write_error or "Could not write the rendered-page manifest"
    end
    return true
end

function MangaOCR:_runNextRenderedPage(job)
    if self.rendered_scan_jobs[job.paths.output] ~= job then
        return
    end
    if job.position > #job.pages then
        self:_finishRenderedScan(job, nil)
        return
    end

    local page_index = job.pages[job.position]
    if job.completed_pages and job.completed_pages[page_index] then
        job.succeeded = job.succeeded + 1
        job.completed = job.completed + 1
        job.position = job.position + 1
        self:_notifyRenderedStatus(job, {
            current = job.completed,
            total = #job.pages,
            succeeded = job.succeeded,
            failed = job.failed,
        })
        self:_scheduleRenderedStep(job)
        return
    end

    self:_removeRenderedStaging(job.paths)
    local rendered, render_error = job.session:renderPage(
        page_index,
        job.paths.page
    )
    if not rendered then
        -- Let the worker record this page as a local failure so its ordinal is
        -- retained and the remaining pages can continue.
        logger.warn(
            "Manga OCR: fixed-layout page rendering failed:",
            page_index,
            render_error
        )
        local placeholder_ok, placeholder_error = util.writeToFile(
            "",
            job.paths.page,
            true
        )
        if not placeholder_ok then
            self:_finishRenderedScan(
                job,
                placeholder_error or render_error
            )
            return
        end
    end

    local manifest_ok, manifest_error = self:_writeRenderedManifest(
        job,
        page_index
    )
    if not manifest_ok then
        self:_finishRenderedScan(job, manifest_error)
        return
    end

    local worker, worker_error = Worker.start({
        input = job.path,
        output = job.paths.output,
        status = job.paths.status,
        log = job.paths.log,
        language = job.language,
        force = job.force_page,
        reset = job.reset_before_first and job.position == 1,
        page = page_index,
        rendered_pages = job.paths.manifest,
    }, {
        on_complete = function(success, status, completion_error)
            self:_runRenderedSafely(job, function()
                self:_onRenderedPageComplete(
                    job,
                    success,
                    status,
                    completion_error
                )
            end)
        end,
    })
    if not worker then
        self:_finishRenderedScan(job, worker_error)
    end
end

function MangaOCR:_onRenderedPageComplete(job, success, status, worker_error)
    if self.rendered_scan_jobs[job.paths.output] ~= job then
        return
    end
    self:_removeRenderedStaging(job.paths)

    if not success then
        local status_error = status
            and type(status.error) == "string"
            and status.error
            or worker_error
        self:_finishRenderedScan(
            job,
            status_error or _("Unknown worker error")
        )
        return
    end

    local failed = status and tonumber(status.failed) or 0
    if failed > 0 then
        job.failed = job.failed + 1
        local failure = type(status.failures) == "table"
            and status.failures[1]
            or nil
        if failure and failure.service_failure == true then
            job.consecutive_service_failures =
                job.consecutive_service_failures + 1
        else
            job.consecutive_service_failures = 0
        end
    else
        job.succeeded = job.succeeded + 1
        job.consecutive_service_failures = 0
    end
    job.completed = job.completed + 1
    if job.skip_completed and not job.completed_pages then
        job.completed_pages = {}
        for _, page_index in ipairs(
            self.storage:getCompletedPageIndices(job.path)
        ) do
            job.completed_pages[page_index] = true
        end
    end
    self:_notifyRenderedStatus(job, {
        current = job.completed,
        total = #job.pages,
        succeeded = job.succeeded,
        failed = job.failed,
    })

    if job.consecutive_service_failures >= 3 then
        self:_finishRenderedScan(
            job,
            _("OCR paused after repeated service or network failures.")
        )
        return
    end

    job.position = job.position + 1
    self:_scheduleRenderedStep(job)
end

function MangaOCR:_finishRenderedScan(job, stop_error)
    if self.rendered_scan_jobs[job.paths.output] ~= job then
        return
    end
    self.rendered_scan_jobs[job.paths.output] = nil
    self:_removeRenderedStaging(job.paths)
    pcall(job.session.close, job.session)
    if job.standby_prevented then
        job.standby_prevented = false
        UIManager:allowStandby()
    end

    self:_forEachRenderedObserver(job, function(observer)
        local progress = observer.scan_progress[job.paths.output]
        if progress and progress.dialog then
            progress.dialog.dismiss_callback = nil
            progress.dialog:close()
        end
        observer.scan_progress[job.paths.output] = nil

        if observer.ui.name == "ReaderUI"
                and observer:_currentDocumentPath() == job.path then
            observer:loadOCR(true)
        end

        local total = #job.pages
        if stop_error then
            observer:_showMessage(T(
                _("Manga OCR stopped: %1/%2 scanned — %3 failed. Completed pages were kept.\n\n%4\n\nWorker log: %5"),
                job.succeeded,
                total,
                job.failed,
                stop_error,
                job.paths.log
            ))
        elseif job.failed > 0 then
            observer:_showMessage(T(
                _("Manga OCR finished: %1/%2 scanned — %3 failed. Successful pages were loaded."),
                job.succeeded,
                total,
                job.failed
            ))
        else
            observer:_showMessage(T(
                _("Manga OCR complete: %1 of %2 pages scanned."),
                job.succeeded,
                total
            ))
        end
    end)
end

function MangaOCR:_makeWorkerListener(path, paths)
    return {
        on_status = function(status)
            self:_onScanStatus(path, paths, status)
        end,
        on_complete = function(success, status, worker_error)
            self:_onScanComplete(path, paths, success, status, worker_error)
        end,
    }
end

function MangaOCR:_attachToRunningScan(path)
    if not path then
        return
    end
    local paths = self.storage:getPaths(path)
    local rendered_job = self.rendered_scan_jobs[paths.output]
    if rendered_job then
        rendered_job.observers = rendered_job.observers
            or setmetatable({}, { __mode = "k" })
        rendered_job.observers[self] = true
        self:_onScanStatus(path, paths, {
            current = rendered_job.completed,
            total = #rendered_job.pages,
            succeeded = rendered_job.succeeded,
            failed = rendered_job.failed,
        })
        return
    end

    self._attached_jobs = self._attached_jobs or {}
    local last_reloaded_count
    local attached = not self._attached_jobs[paths.output]
        and Worker.addListener(paths.output, {
            on_status = function(status)
                local current = tonumber(status.current) or 0
                if self.ui.name == "ReaderUI"
                        and self:_currentDocumentPath() == path
                        and current > 0
                        and current ~= last_reloaded_count then
                    last_reloaded_count = current
                    self:loadOCR(true)
                end
            end,
            on_complete = function()
                if self.ui.name == "ReaderUI"
                        and self:_currentDocumentPath() == path then
                    self:loadOCR(true)
                end
                if self._attached_jobs then
                    self._attached_jobs[paths.output] = nil
                end
            end,
        })
    if attached then
        self._attached_jobs[paths.output] = true
    end
end

function MangaOCR:_onScanStatus(path, paths, status)
    local progress = self.scan_progress[paths.output]
    if not progress then
        progress = {
            paths = paths,
            input = path,
        }
        self.scan_progress[paths.output] = progress
    end

    local current = tonumber(status.current) or 0
    local total = tonumber(status.total) or 0
    local failed = tonumber(status.failed) or 0
    local succeeded = tonumber(status.succeeded)
        or math.max(0, current - failed)
    local status_text = T(
        _("%1/%2 scanned — %3 failed"),
        succeeded,
        total,
        failed
    )
    if total > 0 and not progress.dismissed then
        if not progress.dialog or progress.total ~= total then
            if progress.dialog then
                progress.dialog.dismiss_callback = nil
                progress.dialog:close()
            end
            progress.total = total
            progress.dialog = ProgressbarDialog:new{
                title = _("Scanning manga with Google Lens"),
                subtitle = status_text,
                progress_max = total,
                dismiss_callback = function()
                    progress.dismissed = true
                    progress.dialog = nil
                end,
            }
            progress.dialog:show()
            local vertical_group = progress.dialog[1] and progress.dialog[1][1]
            progress.status_widget = vertical_group and vertical_group[2]
        end
        if progress.status_widget and progress.status_widget.setText then
            progress.status_widget:setText(status_text)
        end
        progress.dialog:reportProgress(math.min(succeeded + failed, total))
    end

    if self.ui.name == "ReaderUI"
            and self:_currentDocumentPath() == path
            and current > 0
            and current ~= progress.last_reloaded_count then
        progress.last_reloaded_count = current
        self:loadOCR(true)
    end
end

function MangaOCR:_onScanComplete(path, paths, success, status, worker_error)
    local progress = self.scan_progress[paths.output]
    if progress and progress.dialog then
        progress.dialog.dismiss_callback = nil
        progress.dialog:close()
        progress.dialog = nil
    end
    self.scan_progress[paths.output] = nil
    if self._attached_jobs then
        self._attached_jobs[paths.output] = nil
    end

    if self.ui.name == "ReaderUI" and self:_currentDocumentPath() == path then
        self:loadOCR(true)
    end

    if success then
        local current = status and tonumber(status.current) or 0
        local total = status and tonumber(status.total) or current
        local failed = status and tonumber(status.failed) or 0
        local succeeded = status and tonumber(status.succeeded)
            or math.max(0, current - failed)
        if failed > 0 then
            self:_showMessage(T(
                _("Manga OCR finished: %1/%2 scanned — %3 failed. Successful pages were loaded."),
                succeeded,
                total,
                failed
            ))
        else
            self:_showMessage(T(_("Manga OCR complete: %1 of %2 pages scanned."), succeeded, total))
        end
    else
        local status_error = status
            and type(status.error) == "string"
            and status.error
            or nil
        if status then
            local current = tonumber(status.current) or 0
            local total = tonumber(status.total) or current
            local failed = tonumber(status.failed) or 0
            local succeeded = tonumber(status.succeeded)
                or math.max(0, current - failed)
            self:_showMessage(T(
                _("Manga OCR stopped: %1/%2 scanned — %3 failed. Completed pages were kept.\n\n%4\n\nWorker log: %5"),
                succeeded,
                total,
                failed,
                status_error or worker_error or _("Unknown worker error"),
                paths.log
            ))
        else
            self:_showMessage(T(
                _("Manga OCR stopped. Any completed pages were kept.\n\n%1\n\nWorker log: %2"),
                worker_error or _("Unknown worker error"),
                paths.log
            ))
        end
    end
end

function MangaOCR:_confirmDeleteCache(path)
    local paths = self.storage:getPaths(path)
    if Worker.isRunning(paths.output) or self.rendered_scan_jobs[paths.output] then
        self:_showMessage(_("The OCR cache cannot be deleted while its scan is running."))
        return
    end

    UIManager:show(ConfirmBox:new{
        text = _("Delete the centrally cached OCR data and its status log for this manga?"),
        ok_text = _("Delete"),
        ok_callback = function()
            local removed = self.storage:deleteCache(path)
            if self.ui.name == "ReaderUI" and self:_currentDocumentPath() == path then
                self:loadOCR(true)
            end
            self:_showMessage(removed
                and _("Manga OCR cache deleted.")
                or _("There was no Manga OCR cache to delete."))
        end,
    })
end

function MangaOCR:_setBooleanSetting(name, value)
    G_reader_settings:saveSetting(name, value and true or false)
end

function MangaOCR:_scanCurrentPage()
    local page = self.ui:getCurrentPage()
    if not page then
        self:_showMessage(_("Could not determine the current manga page."))
        return
    end
    -- A current-page action should refresh an already cached page too. This
    -- also lets layout-processing improvements be applied without rescanning
    -- the rest of a volume.
    self:_requestScan(self:_currentDocumentPath(), true, page)
end

function MangaOCR:addToMainMenu(menu_items)
    menu_items.mangaocr = {
        text = _("Manga OCR"),
        sorting_hint = "tools",
        enabled_func = function()
            return self:_isCurrentDocumentSupported()
        end,
        sub_item_table = {
            {
                text = _("Scan current page"),
                callback = function()
                    self:_scanCurrentPage()
                end,
            },
            {
                text = _("Scan entire manga"),
                callback = function()
                    self:_requestScan(self:_currentDocumentPath(), false)
                end,
            },
            {
                text = _("Rescan entire manga"),
                callback = function()
                    self:_requestScan(self:_currentDocumentPath(), true)
                end,
                separator = true,
            },
            {
                text = _("Retry failed pages"),
                enabled_func = function()
                    local path = self:_currentDocumentPath()
                    return path and self.storage:hasFailures(path)
                end,
                callback = function()
                    self:_requestScan(self:_currentDocumentPath(), false, nil, true)
                end,
                separator = true,
            },
            {
                text = _("Reload OCR data"),
                callback = function()
                    self:loadOCR(false)
                end,
            },
            {
                text = _("Enable OCR hotspots"),
                checked_func = function()
                    return self.hotspots_enabled
                end,
                callback = function()
                    self.hotspots_enabled = not self.hotspots_enabled
                    self:_setBooleanSetting("mangaocr_hotspots_enabled", self.hotspots_enabled)
                end,
            },
            {
                text = _("Show enlarged OCR text over the tapped region"),
                checked_func = function()
                    return self.region_popup_enabled
                end,
                callback = function()
                    self.region_popup_enabled = not self.region_popup_enabled
                    self:_setBooleanSetting(
                        "mangaocr_region_popup_enabled",
                        self.region_popup_enabled
                    )
                end,
            },
            {
                text = _("Show OCR box outlines"),
                checked_func = function()
                    return self.show_outlines
                end,
                callback = function()
                    self.show_outlines = not self.show_outlines
                    self.overlay:setShowOutlines(self.show_outlines)
                    self:_setBooleanSetting("mangaocr_show_outlines", self.show_outlines)
                    self:_redrawReader()
                end,
            },
            {
                text = _("Hide furigana (small kana readings)"),
                checked_func = function()
                    return self.hide_furigana
                end,
                callback = function()
                    self.hide_furigana = not self.hide_furigana
                    self:_setBooleanSetting("mangaocr_hide_furigana", self.hide_furigana)
                    self:_applyFuriganaSetting()
                end,
                separator = true,
            },
            {
                text = _("OCR language"),
                sub_item_table = {
                    {
                        text = _("Japanese"),
                        checked_func = function()
                            return G_reader_settings:readSetting("mangaocr_language", "ja") == "ja"
                        end,
                        callback = function()
                            G_reader_settings:saveSetting("mangaocr_language", "ja")
                        end,
                    },
                    {
                        text = _("English"),
                        checked_func = function()
                            return G_reader_settings:readSetting("mangaocr_language", "ja") == "en"
                        end,
                        callback = function()
                            G_reader_settings:saveSetting("mangaocr_language", "en")
                        end,
                    },
                },
                separator = true,
            },
            {
                text = _("Delete OCR cache"),
                enabled_func = function()
                    local path = self:_currentDocumentPath()
                    return path and self.storage:hasCache(path)
                end,
                callback = function()
                    self:_confirmDeleteCache(self:_currentDocumentPath())
                end,
            },
        },
    }
end

function MangaOCR:_cleanReaderLifecycle()
    if self.text_popup then
        UIManager:close(self.text_popup)
        self.text_popup = nil
    end
    if self.ui and self.ui.highlight
            and self.ui.highlight.selected_text == self._owned_highlight_selection then
        self.ui.highlight.selected_text = self._previous_highlight_selection
    end
    self._owned_highlight_selection = nil
    self._previous_highlight_selection = nil
end

function MangaOCR:onCloseDocument()
    if self.ui.name == "ReaderUI" then
        self:_cleanReaderLifecycle()
    end
end

function MangaOCR:onCloseWidget()
    if self._is_filemanager then
        self.ui:removeFileDialogButtons("mangaocr_delete")
        self.ui:removeFileDialogButtons("mangaocr_scan")
    elseif self.ui.name == "ReaderUI" then
        self:_cleanReaderLifecycle()
    end
end

return MangaOCR

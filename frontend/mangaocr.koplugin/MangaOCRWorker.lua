local Paths = require("MangaOCRPaths")
local UIManager = require("ui/uimanager")
local ffi = require("ffi")
local ffiutil = require("ffi/util")
local rapidjson = require("rapidjson")
local util = require("util")

local C = ffi.C
local Worker = {}
local active_jobs = {}
local COPY_CHUNK_SIZE = 64 * 1024

pcall(require, "ffi/posix_h")

local function declareFFI()
    if not pcall(ffi.typeof, "posix_spawn_file_actions_t") then
        local ok = pcall(ffi.cdef, [[
            typedef struct { uint64_t __pad[16]; } posix_spawn_file_actions_t;
        ]])
        if not ok then
            return false
        end
    end

    local declarations = {
        "extern char **environ;",
        [[int posix_spawn(int *pid, const char *path,
            const posix_spawn_file_actions_t *file_actions, const void *attrp,
            const char *const argv[], char *const envp[]);]],
        "int posix_spawn_file_actions_init(posix_spawn_file_actions_t *actions);",
        [[int posix_spawn_file_actions_addopen(posix_spawn_file_actions_t *actions,
            int fd, const char *path, int oflag, int mode);]],
        [[int posix_spawn_file_actions_adddup2(posix_spawn_file_actions_t *actions,
            int fd, int newfd);]],
        "int posix_spawn_file_actions_destroy(posix_spawn_file_actions_t *actions);",
        "int mkstemp(char *template_name);",
        "long write(int fd, const void *buffer, unsigned long count);",
        "int fsync(int fd);",
        "int fchmod(int fd, unsigned int mode);",
        "int close(int fd);",
        "char *strerror(int error_number);",
    }
    for _, declaration in ipairs(declarations) do
        pcall(ffi.cdef, declaration)
    end

    local symbols = {
        "posix_spawn",
        "posix_spawn_file_actions_init",
        "posix_spawn_file_actions_addopen",
        "posix_spawn_file_actions_adddup2",
        "posix_spawn_file_actions_destroy",
    }
    for _, name in ipairs(symbols) do
        if not pcall(function() return C[name] end) then
            return false
        end
    end
    return true
end

local ffi_ready = declareFFI()

local function errnoMessage(prefix, error_number)
    error_number = error_number or ffi.errno()
    local ok, description = pcall(function()
        return ffi.string(C.strerror(error_number))
    end)
    if ok and description ~= "" then
        return prefix .. " (error " .. error_number .. ": " .. description .. ")"
    end
    return prefix .. " (error " .. error_number .. ")"
end

local function posixConstant(name, fallback)
    local ok, value = pcall(function()
        return tonumber(C[name])
    end)
    return ok and value or fallback
end

local function readStatus(path)
    local file = io.open(path, "rb")
    if not file then
        return nil
    end
    local content = file:read("*all")
    file:close()
    local ok, status = pcall(rapidjson.decode, content)
    if not ok or type(status) ~= "table" or type(status.state) ~= "string" then
        return nil
    end
    return status
end

local function statusFingerprint(status)
    if not status then
        return ""
    end
    return table.concat({
        tostring(status.state),
        tostring(status.current),
        tostring(status.total),
        tostring(status.succeeded),
        tostring(status.failed),
        tostring(status.page),
        tostring(status.error),
    }, "\0")
end

local function notify(job, callback_name, ...)
    for _, listener in ipairs(job.listeners) do
        local callback = listener and listener[callback_name]
        if callback then
            local ok, err = pcall(callback, ...)
            if not ok then
                require("logger").warn("Manga OCR worker callback failed:", err)
            end
        end
    end
end

local function temporaryDirectories()
    local directories = {}
    local seen = {}
    local candidates = {}
    local configured = os.getenv("TMPDIR")
    if configured then
        candidates[#candidates + 1] = configured
    end
    candidates[#candidates + 1] = "/var/tmp"
    candidates[#candidates + 1] = "/tmp"

    for _, directory in ipairs(candidates) do
        if type(directory) == "string" and directory:sub(1, 1) == "/" then
            directory = directory:gsub("/+$", "")
            if directory == "" then
                directory = "/"
            end
            if not seen[directory] then
                seen[directory] = true
                directories[#directories + 1] = directory
            end
        end
    end
    return directories
end

local function stageBinaryInDirectory(source_path, directory)
    local source, open_error = io.open(source_path, "rb")
    if not source then
        return nil, "could not read the installed worker: " .. tostring(open_error)
    end

    local separator = directory == "/" and "" or directory
    local template_path = separator .. "/mangaocr-worker.XXXXXX"
    local template = ffi.new("char[?]", #template_path + 1)
    ffi.copy(template, template_path)

    local mkstemp_ok, fd = pcall(function()
        return C.mkstemp(template)
    end)
    if not mkstemp_ok or fd < 0 then
        local error_number = mkstemp_ok and ffi.errno() or nil
        source:close()
        if not mkstemp_ok then
            return nil,
                "could not create a runtime worker in " .. directory
                .. ": " .. tostring(fd)
        end
        return nil, errnoMessage(
            "could not create a runtime worker in " .. directory,
            error_number
        )
    end

    local runtime_path = ffi.string(template)
    local function fail(message)
        source:close()
        pcall(C.close, fd)
        os.remove(runtime_path)
        return nil, message
    end

    while true do
        local read_ok, chunk, read_error = pcall(
            source.read,
            source,
            COPY_CHUNK_SIZE
        )
        if not read_ok then
            return fail(
                "could not read the installed worker: " .. tostring(chunk)
            )
        end
        if not chunk then
            if read_error then
                return fail(
                    "could not read the installed worker: "
                    .. tostring(read_error)
                )
            end
            break
        end

        local pointer = ffi.cast("const unsigned char *", chunk)
        local offset = 0
        while offset < #chunk do
            local write_ok, written = pcall(function()
                return tonumber(C.write(fd, pointer + offset, #chunk - offset))
            end)
            if not write_ok then
                return fail(
                    "could not copy the worker to " .. runtime_path
                    .. ": " .. tostring(written)
                )
            end
            if not written or written <= 0 then
                local error_number = ffi.errno()
                if written == -1
                        and error_number == posixConstant("EINTR", 4) then
                    -- Retry the same bytes when a signal interrupts write(2).
                else
                    return fail(errnoMessage(
                        "could not copy the worker to " .. runtime_path,
                        error_number
                    ))
                end
            else
                offset = offset + written
            end
        end
    end
    source:close()

    local chmod_ok
    local chmod_result
    local chmod_error
    repeat
        chmod_ok, chmod_result = pcall(function()
            return C.fchmod(fd, 448) -- 0700
        end)
        if chmod_ok and chmod_result ~= 0 then
            chmod_error = ffi.errno()
        end
    until not chmod_ok
        or chmod_result == 0
        or chmod_error ~= posixConstant("EINTR", 4)
    if not chmod_ok or chmod_result ~= 0 then
        pcall(C.close, fd)
        os.remove(runtime_path)
        if not chmod_ok then
            return nil,
                "could not make the runtime worker executable: "
                .. tostring(chmod_result)
        end
        return nil, errnoMessage(
            "could not make the runtime worker executable",
            chmod_error
        )
    end

    local sync_ok
    local sync_result
    local sync_error
    repeat
        sync_ok, sync_result = pcall(function()
            return C.fsync(fd)
        end)
        if sync_ok and sync_result ~= 0 then
            sync_error = ffi.errno()
        end
    until not sync_ok
        or sync_result == 0
        or sync_error ~= posixConstant("EINTR", 4)
    pcall(C.close, fd)
    if not sync_ok or sync_result ~= 0 then
        os.remove(runtime_path)
        if not sync_ok then
            return nil,
                "could not finish writing the runtime worker: "
                .. tostring(sync_result)
        end
        return nil, errnoMessage(
            "could not finish writing the runtime worker",
            sync_error
        )
    end
    if not ffiutil.isExecutable(runtime_path) then
        os.remove(runtime_path)
        return nil, "the temporary filesystem " .. directory .. " does not allow executable files"
    end
    return runtime_path
end

local function stageBinary(source_path, first_directory_index)
    local readable = io.open(source_path, "rb")
    if not readable then
        return nil,
            "Manga OCR worker file is missing or unreadable: " .. source_path
            .. "\nReinstall the complete platform package; mangaocr-worker must be beside main.lua."
    end
    readable:close()

    local last_error
    local directories = temporaryDirectories()
    for index = first_directory_index or 1, #directories do
        local directory = directories[index]
        local runtime_path, stage_error = stageBinaryInDirectory(source_path, directory)
        if runtime_path then
            return runtime_path, nil, index
        end
        last_error = stage_error
    end
    return nil,
        "Manga OCR worker exists but cannot be executed from its installed location, "
        .. "and no executable runtime copy could be created.\n"
        .. (last_error or "No writable temporary directory was found.")
end

local function removeTemporaryBinary(path)
    if path then
        os.remove(path)
    end
end

local function resolveBinary()
    local configured = Paths.getWorkerPath()
    local candidate = configured
    if not configured:find("/", 1, true) then
        candidate = util.which(configured)
        if not candidate then
            return nil, "Manga OCR worker was not found in PATH: " .. configured
        end
    end

    if ffiutil.isExecutable(candidate) then
        return candidate, nil, false, candidate, 1
    end

    local staged, stage_error, directory_index = stageBinary(candidate)
    if staged then
        return staged, nil, true, candidate, directory_index + 1
    end
    return nil, stage_error
end

local function finishJob(job, status, error_message)
    active_jobs[job.output] = nil
    UIManager:allowStandby()
    removeTemporaryBinary(job.temporary_binary)
    job.temporary_binary = nil

    local success = status and status.state == "complete"
    if not success and not error_message then
        error_message = status
            and type(status.error) == "string"
            and status.error
            or "The OCR worker exited without a complete status"
    end
    notify(job, "on_complete", success, status, error_message, job)
end

local function schedulePoll(job)
    UIManager:scheduleIn(0.75, job.poll)
end

local function startPolling(job)
    job.poll = function()
        local status = readStatus(job.status)
        local fingerprint = statusFingerprint(status)
        if status and fingerprint ~= job.last_status_fingerprint then
            job.last_status_fingerprint = fingerprint
            job.last_status = status
            notify(job, "on_status", status, job)
        end

        local ok, done = pcall(ffiutil.isSubProcessDone, job.pid)
        if not ok then
            finishJob(job, status, tostring(done))
        elseif done then
            status = readStatus(job.status) or status
            if status and statusFingerprint(status) ~= job.last_status_fingerprint then
                notify(job, "on_status", status, job)
            end
            finishJob(job, status)
        else
            schedulePoll(job)
        end
    end
    UIManager:nextTick(job.poll)
end

function Worker.isRunning(output)
    return active_jobs[output] ~= nil
end

function Worker.addListener(output, listener)
    local job = active_jobs[output]
    if not job then
        return nil
    end
    job.listeners[#job.listeners + 1] = listener
    if job.last_status and listener and listener.on_status then
        listener.on_status(job.last_status, job)
    end
    return job
end

function Worker.start(options, listener)
    if type(options) ~= "table"
            or type(options.input) ~= "string"
            or type(options.output) ~= "string"
            or type(options.status) ~= "string"
            or type(options.log) ~= "string" then
        return nil, "Invalid OCR worker options"
    end

    local existing = active_jobs[options.output]
    if existing then
        if listener then
            existing.listeners[#existing.listeners + 1] = listener
        end
        return existing, nil, true
    end

    if not ffi_ready then
        return nil, "Asynchronous worker launch is not supported on this platform. Existing .mokuro files can still be read."
    end

    local binary, binary_error, binary_is_temporary, source_binary,
        next_directory_index = resolveBinary()
    if not binary then
        return nil, binary_error
    end
    local function failAfterResolve(error_message)
        removeTemporaryBinary(binary_is_temporary and binary or nil)
        return nil, error_message
    end

    local arguments = {
        binary,
        "scan",
        "--input", options.input,
        "--output", options.output,
        "--status", options.status,
        "--language", options.language or "ja",
    }
    if options.page then
        arguments[#arguments + 1] = "--page"
        arguments[#arguments + 1] = tostring(options.page)
    end
    if options.force then
        arguments[#arguments + 1] = "--force"
    end
    if options.retry_failed then
        arguments[#arguments + 1] = "--retry-failed"
    end

    local argv = ffi.new("const char *[?]", #arguments + 1)
    for index, argument in ipairs(arguments) do
        argv[index - 1] = argument
    end
    argv[#arguments] = nil

    local actions = ffi.new("posix_spawn_file_actions_t")
    local result = C.posix_spawn_file_actions_init(actions)
    if result ~= 0 then
        return failAfterResolve(
            "Could not initialize worker process actions (error " .. result .. ")"
        )
    end

    -- ffi/posix_h provides the platform-specific values on every KOReader
    -- Unix target it supports (notably, O_CREAT/O_TRUNC differ on macOS).
    local O_WRONLY = posixConstant("O_WRONLY", 1)
    local O_CREAT = posixConstant("O_CREAT", ffi.os == "OSX" and 512 or 64)
    local O_TRUNC = posixConstant("O_TRUNC", ffi.os == "OSX" and 1024 or 512)
    result = C.posix_spawn_file_actions_addopen(
        actions,
        1,
        options.log,
        O_WRONLY + O_CREAT + O_TRUNC,
        420
    )
    if result == 0 then
        result = C.posix_spawn_file_actions_adddup2(actions, 1, 2)
    end
    if result ~= 0 then
        C.posix_spawn_file_actions_destroy(actions)
        return failAfterResolve(
            "Could not redirect OCR worker logs (error " .. result .. ")"
        )
    end

    -- Never let a stale terminal status make a child that failed before main()
    -- look successful. Failed-page discovery also reads the persisted Mokuro
    -- metadata, so truncating this transient file does not lose retry state.
    local status_file, status_error = io.open(options.status, "wb")
    if not status_file then
        C.posix_spawn_file_actions_destroy(actions)
        return failAfterResolve(
            "Could not reset OCR worker status: " .. tostring(status_error)
        )
    end
    status_file:close()

    local pid_pointer = ffi.new("int[1]")
    local ok
    local spawn_result
    local staging_error
    repeat
        ok, spawn_result = pcall(
            C.posix_spawn,
            pid_pointer,
            binary,
            actions,
            nil,
            argv,
            C.environ
        )
        if not ok or spawn_result ~= posixConstant("EACCES", 13) then
            break
        end

        -- access(X_OK) is not a reliable exec probe on every FUSE/noexec
        -- combination. If exec itself rejects this location, retry from the
        -- next executable temporary filesystem.
        removeTemporaryBinary(binary_is_temporary and binary or nil)
        binary, staging_error, next_directory_index = stageBinary(
            source_binary,
            next_directory_index
        )
        if not binary then
            break
        end
        binary_is_temporary = true
        next_directory_index = next_directory_index + 1
        arguments[1] = binary
        argv[0] = binary
    until false
    C.posix_spawn_file_actions_destroy(actions)
    if not ok then
        return failAfterResolve(
            "Could not launch OCR worker: " .. tostring(spawn_result)
        )
    end
    if spawn_result ~= 0 then
        if staging_error then
            return failAfterResolve(
                "Could not launch the installed OCR worker (error "
                .. spawn_result .. "), and its runtime copy failed: "
                .. staging_error
            )
        end
        return failAfterResolve(
            "Could not launch OCR worker (error " .. spawn_result .. ")"
        )
    end

    local job = {
        pid = tonumber(pid_pointer[0]),
        input = options.input,
        output = options.output,
        status = options.status,
        log = options.log,
        page = options.page,
        temporary_binary = binary_is_temporary and binary or nil,
        listeners = listener and { listener } or {},
    }
    active_jobs[options.output] = job
    UIManager:preventStandby()
    startPolling(job)
    return job
end

return Worker

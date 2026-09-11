--- Completion controller: orchestrates context capture, backend requests,
--- stream consumption, and ghost-text rendering for one app instance. All
--- per-buffer completion state lives in CompletionSession objects owned here.
local Session = require 'harmonize.completion.session'

local api = vim.api

---@class harmonize.CompletionController
local Controller = {}
Controller.__index = Controller

---@param deps table { config, backend, context, view, notify, events }
function Controller.new(deps)
    return setmetatable({
        config = deps.config,
        backend = deps.backend,
        context = deps.context,
        view = deps.view,
        notify = deps.notify,
        events = deps.events,
        text = deps.text,
        sessions = {},
        timer = nil,
        is_on_throttle = false,
        request_generation = 0,
        -- Typing-only trigger mode distinguishes real typing from pure
        -- navigation: `last_seen_changedtick` remembers the buffer state the
        -- last event processed, and `typing_event_armed` marks that a
        -- TextChangedI / CursorMovedI pair has already handled the change,
        -- so the partner event is not mistaken for an arrow-key move.
        last_seen_changedtick = 0,
        typing_event_armed = false,
        request = nil,
    }, Controller)
end

---@param bufnr? integer
---@return harmonize.CompletionSession
function Controller:session(bufnr)
    bufnr = bufnr or api.nvim_get_current_buf()
    if bufnr == 0 then
        bufnr = api.nvim_get_current_buf()
    end
    local session = self.sessions[bufnr]
    if not session then
        session = Session.new()
        self.sessions[bufnr] = session
    end
    return session
end

function Controller:drop_session(bufnr)
    self.sessions[bufnr] = nil
end

---@param session harmonize.CompletionSession
function Controller:cleanup(session)
    self:stop_timer()
    session:reset()
    self.view:clear()
end

function Controller:stop_timer()
    local timer = self.timer
    self.timer = nil
    if timer and not timer:is_closing() then
        timer:stop()
        timer:close()
    end
end

--- Cancel the active backend request, if any.
function Controller:close_request()
    local request = self.request
    if request then
        self.request = nil
        self.request_generation = self.request_generation + 1
        request:cancel()
    end
end

--- Replace the backend and drop any in-flight request.
---@param backend harmonize.Backend
function Controller:set_backend(backend)
    self:close_request()
    self.backend = backend
end

---@param context harmonize.Context
function Controller:set_context(context)
    self.context = context
end

---@return boolean
local function should_auto_trigger()
    return vim.b.harmonize_virtual_text_auto_trigger
end

--- Runs a list of functions one by one. Stops and returns false immediately
--- if a function returns false.
---@param hooks function[]
---@return boolean
local function run_hooks_until_failure(hooks)
    for _, func in ipairs(hooks) do
        if not func() then
            return false
        end
    end
    return true
end

---@return string[]?
function Controller:get_last_typed_text(ctx)
    local last_typed = nil
    local last_pos = ctx.last_pos
    if not last_pos then
        return { '' }
    end

    local current_pos = api.nvim_win_get_cursor(0)

    -- Convert 1-based line to 0-based for nvim_buf_get_text
    local start_row = last_pos[1] - 1
    local start_col = last_pos[2]
    local end_row = current_pos[1] - 1
    local end_col = current_pos[2]

    if start_row < end_row or (start_row == end_row and start_col <= end_col) then
        last_typed = api.nvim_buf_get_text(0, start_row, start_col, end_row, end_col, {})
    end

    return last_typed
end

---@param ctx harmonize.CompletionSession
---@return string?
function Controller:current_suggestion(ctx)
    if not vim.fn.mode():match '^[iR]' or not ctx.suggestion or #ctx.suggestion == 0 then
        return nil
    end
    return ctx.suggestion
end

---@param ctx harmonize.CompletionSession
function Controller:refresh_preview(ctx)
    if not self:current_suggestion(ctx) then
        self.view:clear()
        return
    end
    self.view:update(ctx)
end

---@param ctx harmonize.CompletionSession
---@return boolean true when the typed text continues the current suggestion
function Controller:update_suggestion_on_typing(ctx)
    if not ctx.suggestion then
        return false
    end

    local last_typed_text = self:get_last_typed_text(ctx)
    if not (last_typed_text and #last_typed_text > 0) then
        return false
    end

    local typed = table.concat(last_typed_text, '\n')
    if not ctx:consume_typed(typed) then
        return false
    end

    self:refresh_preview(ctx)
    self:stop_timer()
    return true
end

--- Request a completion for the current buffer and render it.
---@param bufnr integer
function Controller:trigger(bufnr)
    if bufnr ~= api.nvim_get_current_buf() or vim.fn.mode() ~= 'i' then
        return
    end

    self.notify.notify('Harmonize virtual text started', 'verbose')

    local snapshot = self.context:capture(bufnr)
    local ctx = self:session(bufnr)
    ctx:start_stream()
    local stream = ctx.stream

    self:close_request()
    self.request_generation = self.request_generation + 1
    local generation = self.request_generation
    local finished = false
    local request

    request = self.backend:complete(snapshot, {
        on_finish = function(data)
            finished = true
            if generation ~= self.request_generation then
                if data and next(data) then
                    -- Notify if outdated (and non-empty) completion items arrive.
                    self.notify.notify(
                        'Completion items arrived, but too late, aborted',
                        'debug',
                        vim.log.levels.INFO
                    )
                end
                return
            end
            if self.request == request then
                self.request = nil
            end

            local current = self:session(bufnr)

            if current.stream == stream and #stream.raw > 0 then
                -- The tokens already arrived one by one and were shown as they
                -- streamed; mark the stream done so the state resets once the
                -- user has taken the rest.
                stream.done = true
                current:refresh()
                if not current.suggestion or current.suggestion == '' then
                    current:reset()
                end
                return
            end

            data = self.text.list_dedup(data or {})

            if data[1] then
                current.suggestion = data[1]
            end

            self:refresh_preview(current)
        end,
        on_update = function(streamed)
            -- Each update is the complete response received so far. Replacing
            -- the snapshot keeps rendering independent of token and stdout
            -- chunk sizes.
            if generation ~= self.request_generation then
                return
            end
            local current = self:session(bufnr)
            if current.stream ~= stream then
                return
            end
            current:update_raw(streamed)
            self:refresh_preview(current)
        end,
    })

    if not finished then
        self.request = request
    end
end

--- Debounce a trigger: schedules the request and gates it behind the
--- throttle, the completion menu, and the enable predicates.
function Controller:schedule()
    if self.is_on_throttle then
        return
    end

    self:stop_timer()

    local config = self.config
    local bufnr = api.nvim_get_current_buf()

    local timer
    timer = vim.defer_fn(function()
        if self.timer == timer then
            self.timer = nil
        end
        if
            self.is_on_throttle
            or (not config.show_with_completion_menu and self.view:menu_visible())
            or (not run_hooks_until_failure(config.enable_predicates))
        then
            return
        end

        self.is_on_throttle = true
        vim.defer_fn(function()
            self.is_on_throttle = false
        end, config.throttle)

        self:trigger(bufnr)
    end, config.debounce)
    self.timer = timer
end

--- Insert `lines` at the cursor and move the cursor to the end. The pum is
--- closed first: while it is open the insertion would be reverted when Vim
--- restores the buffer state on pum close.
---@param lines string[]
---@param on_inserted? fun()
local function insert_lines(lines, on_inserted)
    local cursor = api.nvim_win_get_cursor(0)
    local line, col = cursor[1] - 1, cursor[2]

    if vim.fn.pumvisible() == 1 then
        api.nvim_feedkeys(api.nvim_replace_termcodes('<C-e>', true, true, true), 'n', true)
    end

    vim.schedule(function()
        api.nvim_buf_set_text(0, line, col, line, col, lines)
        local new_col = #lines[#lines]
        -- For single-line insertions, adjust the column by the current offset.
        if #lines == 1 then
            new_col = new_col + col
        end
        api.nvim_win_set_cursor(0, { line + #lines, new_col })
        if on_inserted then
            on_inserted()
        end
    end)
end

--- Accept the visible suggestion up to the next chunk boundary and keep the
--- rest available for further acceptance.
function Controller:accept()
    local ctx = self:session()
    if not self:current_suggestion(ctx) then
        return
    end

    local chunk, remaining = ctx:take_chunk()
    local lines = vim.split(chunk, '\n', { plain = true })

    self.view:clear()
    insert_lines(lines, function()
        -- Accepting changes the buffer without invalidating the cached tail.
        self.last_seen_changedtick = vim.b.changedtick
        ctx.event_pos = api.nvim_win_get_cursor(0)
        ctx.event_tick = vim.b.changedtick
        if remaining then
            self:refresh_preview(ctx)
        end
    end)
end

---@param n_lines? integer number of lines to accept; nil accepts everything
function Controller:accept_lines(n_lines)
    local ctx = self:session()
    if not self:current_suggestion(ctx) then
        return
    end

    local lines, remaining = ctx:take_lines(n_lines)
    self.view:clear()
    insert_lines(lines, function()
        self.last_seen_changedtick = vim.b.changedtick
        ctx.event_pos = api.nvim_win_get_cursor(0)
        ctx.event_tick = vim.b.changedtick
        if #remaining > 0 then
            self:refresh_preview(ctx)
        end
    end)
end

function Controller:accept_line()
    self:accept_lines(1)
end

function Controller:dismiss()
    self:cleanup(self:session())
end

function Controller:is_visible()
    return self.view:is_visible()
end

--- Re-baseline the change tick so the first cursor move inside insert mode
--- is never mistaken for a freshly typed character.
function Controller:on_insert_enter()
    self.last_seen_changedtick = vim.b.changedtick
    local ctx = self:session()
    ctx.event_pos = api.nvim_win_get_cursor(0)
    ctx.event_tick = vim.b.changedtick
    if should_auto_trigger() and self.config.completion_trigger == 'on_insert' then
        self:schedule()
    end
end

function Controller:on_insert_leave()
    self:cleanup(self:session())
end

function Controller:on_buf_leave()
    if vim.fn.mode():match '^[iR]' then
        self:on_insert_leave()
    end
end

function Controller:on_buf_enter()
    if vim.fn.mode():match '^[iR]' then
        self:on_insert_enter()
    end
end

--- Returns true when the event closes out a real text change (typing, paste)
--- and was handled; false for a pure cursor move with no buffer change.
function Controller:handle_insert_change()
    if self.typing_event_armed then
        -- The partner event of this TextChangedI / CursorMovedI pair already
        -- did the work.
        self.typing_event_armed = false
        return true
    end

    local tick = vim.b.changedtick
    if tick == self.last_seen_changedtick then
        -- TextChangedI can fire without a change (insert-enter, typeahead
        -- drain); treat it as nothing.
        return false
    end
    self.last_seen_changedtick = tick
    self.typing_event_armed = true

    local ctx = self:session()
    if self:update_suggestion_on_typing(ctx) then
        -- The typed text continues the current suggestion; keep it in sync
        -- without starting a new request.
        return true
    end

    if ctx.shown then
        self:cleanup(ctx)
    end
    if should_auto_trigger() then
        self:schedule()
    end
    return true
end

function Controller:on_cursor_moved_i()
    local ctx = self:session()
    local cursor = api.nvim_win_get_cursor(0)

    if self.config.completion_trigger == 'on_type' then
        if not self:handle_insert_change() then
            -- Pure navigation (arrow keys, scrolling): never fire a request;
            -- drop a stale suggestion left at the previous position.
            if ctx.shown and (not ctx.last_pos or cursor[1] ~= ctx.last_pos[1] or cursor[2] ~= ctx.last_pos[2]) then
                self:cleanup(ctx)
            end
        end
        return
    end

    local tick = vim.b.changedtick
    local backspaced = ctx.event_pos
        and ctx.event_tick ~= tick
        and (cursor[1] < ctx.event_pos[1] or (cursor[1] == ctx.event_pos[1] and cursor[2] < ctx.event_pos[2]))
    ctx.event_pos = cursor
    ctx.event_tick = tick
    if backspaced then
        self:stop_timer()
        if ctx.shown then
            self:cleanup(ctx)
        end
        return
    end

    if ctx.shown and ctx.last_pos and cursor[1] == ctx.last_pos[1] and cursor[2] == ctx.last_pos[2] then
        return
    end
    if self:update_suggestion_on_typing(ctx) then
        return
    end

    -- We don't cleanup immediately if the completion has arrived but not
    -- been displayed yet.
    if ctx.shown then
        self:cleanup(ctx)
    end
    if should_auto_trigger() then
        self:schedule()
    end
end

function Controller:on_text_changed_i()
    if self.config.completion_trigger == 'on_type' then
        self:handle_insert_change()
    end
end

function Controller:on_cursor_hold_i()
    self:refresh_preview(self:session())
end

function Controller:on_text_changed_p()
    self:on_text_changed_i()
end

--- Drop every session and cancel in-flight work. Idempotent.
function Controller:close()
    self:stop_timer()
    self:close_request()
    self.view:clear()
    self.sessions = {}
end

return Controller

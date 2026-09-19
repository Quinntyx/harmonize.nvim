local helpers = require 'tests.helpers'

-- Drives a real request through the autocommand path: the config is set up, a
-- stub backend serves the suggestion, and typing one character runs the same
-- schedule/trigger chain as a keystroke.
local function with_display_scenario(overrides, backend, scenario)
    local app = helpers.new_app(vim.tbl_deep_extend('force', {
        provider = 'test_display',
        debounce = 0,
        throttle = 0,
        extension_options = { enabled = false },
    }, overrides or {}), {
        backend = {
            start = function() end,
            close = function() end,
            complete = backend.complete,
        },
    })
    app:start()

    local bufnr = helpers.create_buffer({ 'local value =' }, { 1, 13 })
    vim.b.harmonize_virtual_text_auto_trigger = true

    local original_mode = vim.fn.mode
    vim.fn.mode = function()
        return 'i'
    end

    local ok, err = xpcall(scenario, debug.traceback, bufnr, app)

    vim.fn.mode = original_mode
    helpers.delete_buffer(bufnr)
    app:close()
    if not ok then
        error(err, 0)
    end
end

local function type_char(bufnr)
    vim.api.nvim_buf_set_text(bufnr, 0, 12, 0, 12, { 'x' })
    vim.api.nvim_exec_autocmds('TextChangedI', { buffer = bufnr })
end

local function extmark_details(app, bufnr)
    local mark = vim.api.nvim_buf_get_extmark_by_id(bufnr, app.view.ns_id, 1, { details = true })
    return mark[3]
end

local function float_text(app)
    local bufnr = app.view.float_bufnr
    if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
        return nil
    end
    return vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1]
end

return {
    {
        name = 'below display overlays one cursor-aligned line without moving buffer lines',
        run = function()
            with_display_scenario(nil, {
                complete = function(_, _, callbacks)
                    callbacks.on_finish { 'foo(bar).baz' }
                end,
            }, function(bufnr, app)
                local line_count = vim.api.nvim_buf_line_count(bufnr)
                type_char(bufnr)
                helpers.wait_until(function()
                    return float_text(app) == 'foo(bar).baz'
                end, 1000, 'the below-line suggestion must be shown')

                helpers.expect_equal(vim.api.nvim_buf_line_count(bufnr), line_count)
                local config = vim.api.nvim_win_get_config(app.view.float_winid)
                local position = vim.api.nvim_win_get_position(app.view.float_winid)
                local cursor = vim.api.nvim_win_get_cursor(0)
                helpers.expect_equal(position, { cursor[1], cursor[2] })
                helpers.expect_truthy(config.zindex < 100, 'the completion menu must have higher priority')
                helpers.expect_equal(vim.api.nvim_get_option_value('wrap', { win = app.view.float_winid }), false)
                helpers.expect_equal(
                    vim.api.nvim_get_option_value('winhl', { win = app.view.float_winid }),
                    'Normal:HarmonizeVirtualTextBelow,NormalNC:HarmonizeVirtualTextBelow'
                )

                local chunks = app.view:display_chunks('foo(bar).baz', 'below')
                helpers.expect_equal(chunks, {
                    { 'foo(', 'HarmonizeNextChunkBelow' },
                    { 'bar).baz', 'HarmonizeVirtualTextBelow' },
                })
                local accent = vim.api.nvim_get_hl(0, { name = 'HarmonizeNextChunkBelow' })
                local text = vim.api.nvim_get_hl(0, { name = 'HarmonizeVirtualTextBelow' })
                local special = vim.api.nvim_get_hl(0, { name = 'Special' })
                local pmenu = vim.api.nvim_get_hl(0, { name = 'Pmenu' })
                helpers.expect_equal(accent.fg, special.fg)
                helpers.expect_equal(accent.bg, pmenu.bg)
                helpers.expect_equal(text.bg, pmenu.bg)
            end)
        end,
    },
    {
        name = 'below display clips long completions at the window edge',
        run = function()
            local suggestion = string.rep('x', 400)
            with_display_scenario(nil, {
                complete = function(_, _, callbacks)
                    callbacks.on_finish { suggestion }
                end,
            }, function(bufnr, app)
                local line_count = vim.api.nvim_buf_line_count(bufnr)
                type_char(bufnr)
                helpers.wait_until(function()
                    return float_text(app) == suggestion
                end, 1000, 'the long suggestion must be shown')

                local config = vim.api.nvim_win_get_config(app.view.float_winid)
                helpers.expect_equal(vim.api.nvim_buf_line_count(bufnr), line_count)
                helpers.expect_truthy(config.width < vim.fn.strdisplaywidth(suggestion), 'the preview must be clipped')
                helpers.expect_equal(vim.api.nvim_get_option_value('wrap', { win = app.view.float_winid }), false)
            end)
        end,
    },
    {
        name = 'line display accepts a direct next-chunk color',
        run = function()
            with_display_scenario({
                display = 'line',
                display_options = {
                    below = { background_highlight = '#234567' },
                    line = { next_chunk_highlight = '#123456' },
                },
            }, {
                complete = function(_, _, callbacks)
                    callbacks.on_finish { 'foo(bar).baz' }
                end,
            }, function(bufnr, app)
                type_char(bufnr)
                helpers.wait_until(function()
                    return extmark_details(app, bufnr) ~= nil
                end, 1000, 'the line suggestion must be shown')

                local details = extmark_details(app, bufnr)
                helpers.expect_equal(details.virt_text, {
                    { 'foo(', 'HarmonizeNextChunkLine' },
                    { 'bar).baz', 'HarmonizeVirtualText' },
                })
                local accent = vim.api.nvim_get_hl(0, { name = 'HarmonizeNextChunkLine' })
                helpers.expect_equal(accent.fg, 0x123456)
                local below = app.view:text_highlight 'below'
                local background = vim.api.nvim_get_hl(0, { name = below })
                helpers.expect_equal(background.bg, 0x234567)
            end)
        end,
    },
    {
        name = 'below display puts newline-leading text in its actual next-line position',
        run = function()
            with_display_scenario(nil, {
                complete = function(_, _, callbacks)
                    callbacks.on_update '\n.first line\nsecond line\nthird line'
                    callbacks.on_finish { '\n.first line\nsecond line\nthird line' }
                end,
            }, function(bufnr, app)
                type_char(bufnr)
                local line_count = vim.api.nvim_buf_line_count(bufnr)
                helpers.wait_until(function()
                    local details = extmark_details(app, bufnr)
                    return details and details.virt_lines
                end, 1000, 'the in-place next-line suggestion must be shown')

                local details = extmark_details(app, bufnr)
                local rendered = table.concat(vim.tbl_map(function(chunk)
                    return chunk[1]
                end, details.virt_lines[1]))
                helpers.expect_equal(rendered, '.first line')
                helpers.expect_equal(details.virt_text[1], { ' ↵', 'HarmonizeNextChunkBelow' })
                helpers.expect_equal(details.virt_lines[1], {
                    { '.first line', 'HarmonizeVirtualTextBelow' },
                })
                helpers.expect_equal(details.virt_text_pos, 'overlay')
                helpers.expect_equal(vim.api.nvim_buf_line_count(bufnr), line_count)
                helpers.expect_falsy(float_text(app), 'newline-leading text must not use the cursor-relative float')
            end)
        end,
    },
    {
        name = 'chunk display marks a newline as the next accepted character',
        run = function()
            with_display_scenario({
                display = 'chunk',
            }, {
                complete = function(_, _, callbacks)
                    callbacks.on_finish { '\nnext line' }
                end,
            }, function(bufnr, app)
                type_char(bufnr)
                helpers.wait_until(function()
                    local details = extmark_details(app, bufnr)
                    return details and details.virt_text
                end, 1000, 'the newline indicator must be shown')

                local details = extmark_details(app, bufnr)
                helpers.expect_equal(details.virt_text[1], { ' ↵', 'HarmonizeVirtualText' })
                helpers.expect_falsy(details.virt_lines, 'chunk display must show only the next accepted chunk')
            end)
        end,
    },
    {
        name = 'chunk display shows exactly what the next accept completes',
        run = function()
            with_display_scenario({
                display = 'chunk',
            }, {
                complete = function(_, _, callbacks)
                    callbacks.on_update 'foo(bar)\nbaz'
                    callbacks.on_finish { 'foo(bar)\nbaz' }
                end,
            }, function(bufnr, app)
                type_char(bufnr)
                helpers.wait_until(function()
                    return extmark_details(app, bufnr) ~= nil
                end, 1000, 'the suggestion must be shown')

                local details = extmark_details(app, bufnr)
                -- 'foo(' is the whole first chunk: the identifier plus the
                -- special characters that follow it.
                helpers.expect_equal(details.virt_text[1], { 'foo(', 'HarmonizeVirtualText' })
                helpers.expect_equal(details.virt_text_pos, 'overlay')
                helpers.expect_falsy(details.virt_lines)
            end)
        end,
    },
    {
        name = 'streamed snapshots replace the ghost instead of repeating prefixes',
        run = function()
            with_display_scenario(nil, {
                complete = function(_, _, callbacks)
                    callbacks.on_update 'foo'
                    callbacks.on_update 'foobar'
                    callbacks.on_finish { 'foobar' }
                end,
            }, function(bufnr, app)
                type_char(bufnr)
                helpers.wait_until(function()
                    return float_text(app) == 'foobar'
                end, 1000, 'the suggestion must be shown')
            end)
        end,
    },
    {
        name = 'action.trigger requests a completion on demand',
        run = function()
            with_display_scenario(nil, {
                complete = function(_, _, callbacks)
                    callbacks.on_update 'manual completion'
                    callbacks.on_finish { 'manual completion' }
                end,
            }, function(bufnr, app)
                app.controller:trigger(bufnr)
                helpers.wait_until(function()
                    return float_text(app) == 'manual completion'
                end, 1000, 'the suggestion must be shown')
            end)
        end,
    },
    {
        name = 'keymap.trigger binds the manual request action',
        run = function()
            with_display_scenario({
                keymap = { trigger = '<M-b>' },
            }, {
                complete = function(_, _, callbacks)
                    callbacks.on_finish { 'x' }
                end,
            }, function()
                local binding = vim.fn.maparg('<M-b>', 'i', false, true)
                helpers.expect_truthy(binding.callback or binding.rhs, 'the trigger key must be bound')
                helpers.expect_equal(binding.desc, '[harmonize] manually request a completion')
            end)
        end,
    },
    {
        name = 'newline-only suggestions do not add a blank virtual line',
        run = function()
            with_display_scenario(nil, {
                complete = function(_, _, callbacks)
                    callbacks.on_finish { '\n' }
                end,
            }, function(bufnr, app)
                type_char(bufnr)
                helpers.wait_until(function()
                    return extmark_details(app, bufnr) ~= nil
                end, 1000, 'the newline indicator must be shown')

                local details = extmark_details(app, bufnr)
                helpers.expect_equal(details.virt_text[1][1], ' ↵')
                helpers.expect_falsy(details.virt_lines, 'a newline without text must not create a screen-line gap')
            end)
        end,
    },
    {
        name = 'scrolling redraws a visible below-line preview',
        run = function()
            with_display_scenario(nil, {
                complete = function(_, _, callbacks)
                    callbacks.on_finish { 'suggestion' }
                end,
            }, function(bufnr, app)
                type_char(bufnr)
                helpers.wait_until(function()
                    return float_text(app) == 'suggestion'
                end, 1000, 'the below-line suggestion must be shown')

                local redraws = 0
                local update = app.view.update
                app.view.update = function(view, session)
                    redraws = redraws + 1
                    return update(view, session)
                end
                vim.api.nvim_exec_autocmds('WinScrolled', { buffer = bufnr })
                helpers.expect_equal(redraws, 1)
            end)
        end,
    },
    {
        name = 'matching displaces and then skips an existing line suffix',
        run = function()
            with_display_scenario(nil, {
                complete = function() end,
            }, function(bufnr, app)
                local line = 'foo(a, b, c, )'
                vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { line })
                vim.api.nvim_win_set_cursor(0, { 1, #line - 1 })
                local session = app.controller:session(bufnr)
                session.suggestion = 'bar)\n'
                app.view:update(session)

                local details = extmark_details(app, bufnr)
                helpers.expect_equal(details.virt_text_pos, 'inline')
                helpers.expect_equal(details.virt_text[1][1], '   ')
                helpers.expect_equal(float_text(app), 'bar)')

                app.controller:accept()
                vim.wait(100)
                helpers.expect_equal(vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1], 'foo(a, b, c, bar)')
                -- Headless normal mode clamps the API cursor to the final byte;
                -- in insert mode this is the insertion point after the paren.
                helpers.expect_equal(vim.api.nvim_win_get_cursor(0), { 1, #'foo(a, b, c, bar)' - 1 })
                helpers.expect_equal(session.suggestion, '\n')
            end)
        end,
    },
    {
        name = 'existing suffix matching can be disabled',
        run = function()
            with_display_scenario({
                match_existing_text = false,
            }, {
                complete = function() end,
            }, function(bufnr, app)
                vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'call)' })
                vim.api.nvim_win_set_cursor(0, { 1, 4 })
                local session = app.controller:session(bufnr)
                session.suggestion = ')'

                app.controller:accept()
                vim.wait(100)
                helpers.expect_equal(vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1], 'call))')
            end)
        end,
    },
    {
        name = 'matching reuses an identical predicted next line',
        run = function()
            with_display_scenario(nil, {
                complete = function() end,
            }, function(bufnr, app)
                vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'call()', '    }' })
                vim.api.nvim_win_set_cursor(0, { 1, #'call()' })
                local session = app.controller:session(bufnr)
                session.suggestion = '\n    }'
                app.view:update(session)

                helpers.expect_falsy(
                    extmark_details(app, bufnr).virt_lines,
                    'an existing matching next line must not be duplicated on screen'
                )
                app.controller:accept()
                vim.wait(100)
                helpers.expect_equal(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), { 'call()', '    }' })
                helpers.expect_equal(vim.api.nvim_win_get_cursor(0), { 2, 4 })
                helpers.expect_equal(session.suggestion, '}')

                app.controller:accept()
                vim.wait(100)
                helpers.expect_equal(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), { 'call()', '    }' })
                helpers.expect_equal(vim.api.nvim_win_get_cursor(0), { 2, 4 })
                helpers.expect_falsy(session.suggestion)
            end)
        end,
    },
    {
        name = 'a short initial completion starts an extension immediately',
        run = function()
            local requests = 0
            local extension_snapshot
            with_display_scenario({
                extension_options = {
                    enabled = true,
                    minimum_remaining_lines = 2,
                },
            }, {
                complete = function(_, snapshot, callbacks)
                    requests = requests + 1
                    if requests == 1 then
                        callbacks.on_finish { 'one' }
                        return
                    end
                    extension_snapshot = snapshot
                    return { cancel = function() end }
                end,
            }, function(bufnr)
                type_char(bufnr)
                helpers.wait_until(function()
                    return requests == 2
                end, 1000, 'the short completion must start a background extension')

                helpers.expect_match(extension_snapshot.lines_before, 'one$')
                helpers.expect_match(extension_snapshot.lines_after, '^=')
            end)
        end,
    },
    {
        name = 'finishing an exhausted initial stream starts an extension',
        run = function()
            local requests = 0
            local initial_callbacks
            local extension_snapshot
            with_display_scenario({
                extension_options = {
                    enabled = true,
                    minimum_remaining_lines = 2,
                },
            }, {
                complete = function(_, snapshot, callbacks)
                    requests = requests + 1
                    if requests == 1 then
                        initial_callbacks = callbacks
                    else
                        extension_snapshot = snapshot
                    end
                    return { cancel = function() end }
                end,
            }, function(bufnr, app)
                type_char(bufnr)
                helpers.wait_until(function()
                    return initial_callbacks ~= nil
                end, 1000, 'the initial stream must start')

                initial_callbacks.on_update 'one'
                app.controller:accept()
                vim.wait(100)
                helpers.expect_equal(app.controller:session(bufnr).suggestion, '')

                initial_callbacks.on_finish {}
                helpers.expect_equal(requests, 2)
                helpers.expect_match(extension_snapshot.lines_before, 'one$')
            end)
        end,
    },
    {
        name = 'acceptance extends a short completion from its predicted endpoint',
        run = function()
            local requests = 0
            local extension_callbacks
            local extension_snapshot
            with_display_scenario({
                extension_options = {
                    enabled = true,
                    minimum_remaining_lines = 2,
                },
            }, {
                complete = function(_, snapshot, callbacks)
                    requests = requests + 1
                    extension_snapshot = snapshot
                    extension_callbacks = callbacks
                    return { cancel = function() end }
                end,
            }, function(bufnr, app)
                vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { '' })
                vim.api.nvim_win_set_cursor(0, { 1, 0 })
                local session = app.controller:session(bufnr)
                session.suggestion = 'one'
                app.view:update(session)

                app.controller:accept()
                vim.wait(100)
                helpers.expect_equal(requests, 1)
                helpers.expect_match(extension_snapshot.lines_before, 'one$')
                helpers.expect_equal(vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1], 'one')
                helpers.expect_equal(session.suggestion, '')

                extension_callbacks.on_update '\ntwo\nthree'
                helpers.expect_equal(session.suggestion, '\ntwo\nthree')
                helpers.expect_truthy(extmark_details(app, bufnr), 'the appended continuation must be shown')
                extension_callbacks.on_finish {}
                helpers.expect_equal(requests, 1, 'one acceptance must start at most one extension')
            end)
        end,
    },
    {
        name = 'two complete remaining lines do not trigger an extension',
        run = function()
            local requests = 0
            with_display_scenario({
                extension_options = {
                    enabled = true,
                    minimum_remaining_lines = 2,
                },
            }, {
                complete = function()
                    requests = requests + 1
                end,
            }, function(bufnr, app)
                local session = app.controller:session(bufnr)
                session.suggestion = 'one\ntwo\nthree'
                app.view:update(session)
                app.controller:accept()
                vim.wait(100)
                helpers.expect_equal(requests, 0)
            end)
        end,
    },
    {
        name = 'accept redraws a cached below preview without replacing its float',
        run = function()
            with_display_scenario(nil, {
                complete = function(_, _, callbacks)
                    callbacks.on_finish { 'foo(bar)' }
                end,
            }, function(bufnr, app)
                type_char(bufnr)
                helpers.wait_until(function()
                    return float_text(app) == 'foo(bar)'
                end, 1000, 'the below-line suggestion must be shown')

                local winid = app.view.float_winid
                app.controller:accept()
                helpers.expect_equal(app.view.float_winid, winid)
                vim.wait(100)
                helpers.expect_equal(app.view.float_winid, winid)
                helpers.expect_equal(float_text(app), 'bar)')
            end)
        end,
    },
    {
        name = 'accept inserts one chunk and keeps the rest of the suggestion',
        run = function()
            with_display_scenario({
                display = 'chunk',
            }, {
                complete = function(_, _, callbacks)
                    callbacks.on_update 'foo(bar)\nbaz'
                    callbacks.on_finish { 'foo(bar)\nbaz' }
                end,
            }, function(bufnr, app)
                type_char(bufnr)
                helpers.wait_until(function()
                    return extmark_details(app, bufnr) ~= nil
                end, 1000, 'the suggestion must be shown')

                local before = vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1]
                local cursor = vim.api.nvim_win_get_cursor(0)
                app.controller:accept()
                vim.wait(100)

                local text = vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1]
                helpers.expect_equal(text, before:sub(1, cursor[2]) .. 'foo(' .. before:sub(cursor[2] + 1))
                -- The rest of the suggestion is still offered as the next chunk.
                local details = extmark_details(app, bufnr)
                helpers.expect_truthy(details, 'the remaining suggestion must still be shown')
                helpers.expect_equal(details.virt_text[1][1], 'bar)')
            end)
        end,
    },
    {
        name = 'repeated accepts reuse the cached completion',
        run = function()
            local requests = 0
            with_display_scenario({
                display = 'chunk',
            }, {
                complete = function(_, _, callbacks)
                    requests = requests + 1
                    callbacks.on_update 'foo(bar)baz'
                    callbacks.on_finish { 'foo(bar)baz' }
                end,
            }, function(bufnr, app)
                type_char(bufnr)
                helpers.wait_until(function()
                    return extmark_details(app, bufnr) ~= nil
                end, 1000, 'the suggestion must be shown')

                app.controller:accept()
                vim.wait(100)
                vim.api.nvim_exec_autocmds('TextChangedI', { buffer = bufnr })
                vim.api.nvim_exec_autocmds('CursorMovedI', { buffer = bufnr })
                vim.wait(20)

                helpers.expect_equal(requests, 1, 'the first accept must not start another request')
                helpers.expect_equal(app.controller:session(bufnr).suggestion, 'bar)baz')
                helpers.expect_equal(extmark_details(app, bufnr).virt_text[1][1], 'bar)')

                app.controller:accept()
                vim.wait(100)
                vim.api.nvim_exec_autocmds('TextChangedI', { buffer = bufnr })
                vim.api.nvim_exec_autocmds('CursorMovedI', { buffer = bufnr })
                vim.wait(20)

                helpers.expect_equal(requests, 1, 'the second accept must still use the cached completion')
                helpers.expect_equal(app.controller:session(bufnr).suggestion, 'baz')
                helpers.expect_equal(extmark_details(app, bufnr).virt_text[1][1], 'baz')
            end)
        end,
    },
    {
        name = 'keymap.toggle binds the auto-completion toggle action',
        run = function()
            with_display_scenario({
                keymap = { toggle = '<M-t>' },
            }, {
                complete = function(_, _, callbacks)
                    callbacks.on_finish { 'x' }
                end,
            }, function(_, app)
                local binding = vim.fn.maparg('<M-t>', 'i', false, true)
                helpers.expect_truthy(binding.callback or binding.rhs, 'the toggle key must be bound')
                helpers.expect_equal(binding.desc, '[harmonize] toggle auto completion')

                -- The toggle flips the buffer-local auto-trigger flag.
                helpers.expect_equal(vim.b.harmonize_virtual_text_auto_trigger, true)
                app.bindings:toggle_auto_trigger()
                helpers.expect_equal(vim.b.harmonize_virtual_text_auto_trigger, false)
                app.bindings:toggle_auto_trigger()
                helpers.expect_equal(vim.b.harmonize_virtual_text_auto_trigger, true)
            end)
        end,
    },
    {
        name = 'accepting a streamed line advances past the inserted text',
        run = function()
            local Session = require 'harmonize.completion.session'
            local session = Session.new()
            session:start_stream()
            session:update_raw 'first\nsecond'

            local lines, remaining = session:take_lines(1)
            helpers.expect_equal(lines, { 'first' })
            helpers.expect_equal(remaining, { '', 'second' })
            helpers.expect_equal(session.stream.consumed, 5)
            helpers.expect_equal(session.suggestion, '\nsecond')

            session:update_raw 'first\nsecond tail'
            helpers.expect_equal(session.suggestion, '\nsecond tail')
        end,
    },
    {
        name = 'closing the app clears rendered ghost text',
        run = function()
            with_display_scenario(nil, {
                complete = function(_, _, callbacks)
                    callbacks.on_finish { 'visible' }
                end,
            }, function(bufnr, app)
                app.controller:trigger(bufnr)
                helpers.wait_until(function()
                    return app.view:is_visible()
                end, 1000, 'the suggestion must be shown')

                app:close()
                helpers.expect_falsy(app.view:is_visible(), 'close must remove the ghost text')
            end)
        end,
    },
}

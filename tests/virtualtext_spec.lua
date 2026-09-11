local helpers = require 'tests.helpers'

-- Drives a real request through the autocommand path: the config is set up, a
-- stub backend serves the suggestion, and typing one character runs the same
-- schedule/trigger chain as a keystroke.
local function with_display_scenario(overrides, backend, scenario)
    local app = helpers.new_app(vim.tbl_deep_extend('force', {
        provider = 'test_display',
        debounce = 0,
        throttle = 0,
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

return {
    {
        name = 'line display shows only one line below the cursor',
        run = function()
            with_display_scenario({
                display = 'line',
            }, {
                complete = function(_, _, callbacks)
                    callbacks.on_update '\nfirst line\nsecond line\nthird line'
                    callbacks.on_finish { '\nfirst line\nsecond line\nthird line' }
                end,
            }, function(bufnr, app)
                type_char(bufnr)
                helpers.wait_until(function()
                    return extmark_details(app, bufnr) ~= nil
                end, 1000, 'the suggestion must be shown')

                local details = extmark_details(app, bufnr)
                helpers.expect_equal(details.virt_text[1][1], '')
                helpers.expect_equal(#details.virt_lines, 1)
                helpers.expect_equal(details.virt_lines[1][1][1], 'first line')
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
                helpers.expect_equal(details.virt_text[1][1], 'foo(')
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
                    return extmark_details(app, bufnr) ~= nil
                end, 1000, 'the suggestion must be shown')

                local details = extmark_details(app, bufnr)
                helpers.expect_equal(details.virt_text[1][1], 'foobar')
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
                    return extmark_details(app, bufnr) ~= nil
                end, 1000, 'the suggestion must be shown')

                local details = extmark_details(app, bufnr)
                helpers.expect_equal(details.virt_text[1][1], 'manual completion')
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
                    return extmark_details(app, bufnr) ~= nil
                end, 1000, 'the suggestion must be shown')

                app:close()
                helpers.expect_falsy(extmark_details(app, bufnr), 'close must remove the ghost text')
            end)
        end,
    },
}

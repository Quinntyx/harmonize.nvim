local helpers = require 'tests.helpers'

-- Runs a scenario against the real autocommands: the config is set up, a stub
-- backend counts requests, and the scenario drives TextChangedI/CursorMovedI
-- manually while the app's own bindings run.
local function with_trigger_scenario(overrides, scenario)
    local calls = 0
    local answer = 'oobar'

    local app = helpers.new_app(vim.tbl_deep_extend('force', {
        provider = 'test_trigger',
        debounce = 0,
        throttle = 0,
    }, overrides or {}), {
        backend = {
            start = function() end,
            close = function() end,
            complete = function(_, _, callbacks)
                calls = calls + 1
                callbacks.on_finish { answer }
            end,
        },
    })
    app:start()

    local bufnr = helpers.create_buffer({ 'hel' }, { 1, 3 })
    vim.b.harmonize_virtual_text_auto_trigger = true

    local original_mode = vim.fn.mode
    vim.fn.mode = function()
        return 'i'
    end

    local ok, err = xpcall(function()
        scenario(bufnr, function()
            return calls
        end, app)
    end, debug.traceback)

    vim.fn.mode = original_mode
    helpers.delete_buffer(bufnr)
    app:close()
    if not ok then
        error(err, 0)
    end
end

-- A single keystroke raises both events; drive them as a pair like real
-- typing does.
local function type_char(bufnr, c)
    local col = vim.fn.col '.'
    vim.api.nvim_buf_set_text(bufnr, 0, col - 1, 0, col - 1, { c })
    -- The cursor ends up after the inserted character, as in real typing.
    vim.api.nvim_win_set_cursor(0, { 1, col + 1 })
    vim.api.nvim_exec_autocmds('TextChangedI', { buffer = bufnr })
    vim.api.nvim_exec_autocmds('CursorMovedI', { buffer = bufnr })
end

local function arrow_move(bufnr)
    vim.api.nvim_win_set_cursor(0, { 1, vim.fn.col '.' + 1 })
    vim.api.nvim_exec_autocmds('CursorMovedI', { buffer = bufnr })
end

local function extmark_shown(app, bufnr)
    return vim.api.nvim_buf_get_extmark_by_id(bufnr, app.view.ns_id, 1, { details = true })[3] ~= nil
end

return {
    {
        name = 'typing-only trigger fires a request for the first typed character',
        run = function()
            with_trigger_scenario(nil, function(bufnr, get_calls)
                helpers.expect_equal(get_calls(), 0, 'nothing requested on insert-enter alone')
                type_char(bufnr, 'x')
                helpers.wait_until(function()
                    return get_calls() == 1
                end, 1000, 'the first typed character must request a completion')
            end)
        end,
    },
    {
        name = 'typing-only trigger ignores arrow-key navigation without a request',
        run = function()
            with_trigger_scenario(nil, function(bufnr, get_calls)
                type_char(bufnr, 'x')
                helpers.wait_until(function()
                    return get_calls() == 1
                end, 1000, 'the typed character must request a completion')

                arrow_move(bufnr)
                vim.wait(200)
                helpers.expect_equal(get_calls(), 1, 'arrow keys must not fire a new request')
            end)
        end,
    },
    {
        name = 'typing that continues the suggestion advances it without a new request',
        run = function()
            with_trigger_scenario(nil, function(bufnr, get_calls, app)
                type_char(bufnr, 'f')
                helpers.wait_until(function()
                    return get_calls() == 1
                end, 1000, 'the first typed character must request a completion')

                type_char(bufnr, 'o')
                vim.wait(200)
                helpers.expect_equal(get_calls(), 1, 'matching typed text must not re-request')

                -- The visible suggestion advanced from 'oobar' to 'obar'.
                local mark = vim.api.nvim_buf_get_extmark_by_id(bufnr, app.view.ns_id, 1, { details = true })
                helpers.expect_truthy(mark[3], 'the advanced suggestion must still be shown')
                helpers.expect_equal(mark[3].virt_text[1][1], 'obar')
            end)
        end,
    },
    {
        name = 'arrow keys dismiss a stale suggestion without requesting',
        run = function()
            with_trigger_scenario(nil, function(bufnr, get_calls, app)
                type_char(bufnr, 'f')
                helpers.wait_until(function()
                    return get_calls() == 1
                end, 1000, 'the typed character must request a completion')

                helpers.expect_truthy(extmark_shown(app, bufnr), 'the suggestion must be visible')

                arrow_move(bufnr)
                vim.wait(200)
                helpers.expect_falsy(extmark_shown(app, bufnr), 'arrow keys must dismiss the suggestion')
                helpers.expect_equal(get_calls(), 1, 'arrow keys must not fire a new request')
            end)
        end,
    },
    {
        name = 'permissive trigger still requests on insert-enter (legacy mode)',
        run = function()
            with_trigger_scenario({
                completion_trigger = 'on_insert',
            }, function(_, get_calls)
                vim.api.nvim_exec_autocmds('InsertEnter', {})
                helpers.wait_until(function()
                    return get_calls() == 1
                end, 1000, 'permissive mode must request on insert-enter')
            end)
        end,
    },
    {
        name = 'typing-only trigger does not request on insert-enter',
        run = function()
            with_trigger_scenario(nil, function(_, get_calls)
                vim.api.nvim_exec_autocmds('InsertEnter', {})
                vim.wait(200)
                helpers.expect_equal(get_calls(), 0, 'typing-only must stay quiet on insert-enter')
            end)
        end,
    },
}

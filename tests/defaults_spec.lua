local helpers = require 'tests.helpers'

return {
    {
        name = 'a blank config binds no keys and configures no provider',
        run = function()
            local config = helpers.merged_config()

            helpers.expect_falsy(config.provider, 'no provider must be configured by default')
            for _, key in ipairs { 'accept', 'accept_line', 'dismiss', 'trigger', 'toggle' } do
                helpers.expect_falsy(config.keymap[key], 'keymap.' .. key .. ' must not be bound by default')
            end
            helpers.expect_equal(config.auto_trigger_ft, {})
        end,
    },
    {
        name = 'triggering without a provider stays quiet instead of erroring',
        run = function()
            local app = helpers.new_app()
            app:start()

            local bufnr = helpers.create_buffer({ 'local value =' }, { 1, 13 })
            vim.api.nvim_set_current_buf(bufnr)
            local original_mode = vim.fn.mode
            vim.fn.mode = function()
                return 'i'
            end
            vim.b.harmonize_virtual_text_auto_trigger = true

            local ok, err = xpcall(function()
                app.controller:trigger(bufnr)
                vim.wait(100)
            end, debug.traceback)

            vim.fn.mode = original_mode
            helpers.delete_buffer(bufnr)
            app:close()
            if not ok then
                error(err, 0)
            end

            helpers.expect_falsy(app.view:is_visible(), 'no ghost text may appear')
        end,
    },
}

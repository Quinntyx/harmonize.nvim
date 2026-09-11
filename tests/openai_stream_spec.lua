local helpers = require 'tests.helpers'

local function options(stream)
    return {
        model = 'test-model',
        name = 'Test',
        stream = stream,
        optional = {},
        transform = {},
        end_point = 'http://127.0.0.1/completions',
        api_key = 'TERM',
        template = {
            prompt = function()
                return 'prompt'
            end,
            suffix = false,
        },
    }
end

local function with_mocked_job(run)
    local handlers
    local data_file

    local deps = {
        notify = require 'harmonize.notify',
        events = require 'harmonize.events',
        secret = require 'harmonize.secret',
        transport = {
            post = function(_, _endpoint, _headers, body, value)
                handlers = value
                data_file = vim.fn.tempname()
                vim.fn.writefile({ vim.json.encode(body) }, data_file)
                return { cancel = function() end }
            end,
        },
    }

    local ok, err = xpcall(function()
        run({
            backend = function(stream)
                local config = helpers.merged_config {
                    notify = false,
                    before_cursor_filter_length = 0,
                    after_cursor_filter_length = 0,
                    provider_options = {
                        openai_fim_compatible = options(stream),
                    },
                }
                return require('harmonize.backend.openai_fim').new('openai_fim_compatible', config, deps)
            end,
            get_handlers = function()
                return handlers
            end,
            get_data_file = function()
                return data_file
            end,
        })
    end, debug.traceback)

    if data_file and vim.uv.fs_stat(data_file) then
        vim.uv.fs_unlink(data_file)
    end

    if not ok then
        error(err, 0)
    end
end

local context = {
    lines_before = '',
    lines_after = '',
    opts = {},
}

return {
    {
        name = 'openai FIM streaming emits complete snapshots without duplicating chunks',
        run = function()
            with_mocked_job(function(ctx)
                local backend = ctx.backend(true)
                local updates = {}
                local result

                backend:complete(context, {
                    on_finish = function(items)
                        result = items
                    end,
                    on_update = function(text)
                        table.insert(updates, text)
                    end,
                })

                local h = assert(ctx.get_handlers())
                helpers.expect_truthy(h.on_stdout)

                h.on_stdout(nil, 'data: {"choices":[{"text":"foo"}]}\r')
                h.on_stdout(nil, '\ndata: {"choices":[{"text":"bar"}]}\r\n')
                h.on_stdout(nil, 'data: [DONE]\r\n')
                h.on_exit({ code = 0 }, ctx.get_data_file())

                helpers.expect_equal(updates, { 'foo', 'foobar' })
                helpers.expect_equal(result, { 'foobar' })
            end)
        end,
    },
    {
        name = 'openai FIM non-streaming leaves stdout collection to vim.system',
        run = function()
            with_mocked_job(function(ctx)
                local backend = ctx.backend(false)
                local result

                backend:complete(context, {
                    on_finish = function(items)
                        result = items
                    end,
                })

                local h = assert(ctx.get_handlers())
                helpers.expect_falsy(h.on_stdout)
                h.on_exit({ code = 0, stdout = '{"choices":[{"text":"plain"}]}' }, ctx.get_data_file())

                helpers.expect_equal(result, { 'plain' })
            end)
        end,
    },
}

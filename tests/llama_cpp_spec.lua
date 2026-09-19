local helpers = require 'tests.helpers'

-- A transport double that captures the request: the body goes through a temp
-- file referenced as `-d @<file>` exactly like the real transport, so the
-- backend's handler wiring is exercised.
local function with_mocked_job(run)
    local captured

    local deps = {
        notify = require 'harmonize.notify',
        events = require 'harmonize.events',
        secret = require 'harmonize.secret',
        transport = {
            post = function(_, endpoint, _headers, body, handlers)
                local data_file = vim.fn.tempname()
                vim.fn.writefile({ vim.json.encode(body) }, data_file)
                captured = {
                    args = { '-d', '@' .. data_file, endpoint },
                    handlers = handlers,
                    data_file = data_file,
                }
                return { cancel = function() end }
            end,
        },
    }

    local ok, err = xpcall(function()
        run({
            backend = function(overrides)
                local config = helpers.merged_config(vim.tbl_deep_extend('force', {
                    notify = false,
                    before_cursor_filter_length = 0,
                    after_cursor_filter_length = 0,
                }, overrides or {}))
                return require('harmonize.backend.llama_cpp').new('llama_cpp', config, deps)
            end,
            get = function()
                return captured
            end,
        })
    end, debug.traceback)

    if captured and captured.data_file and vim.uv.fs_stat(captured.data_file) then
        vim.uv.fs_unlink(captured.data_file)
    end

    if not ok then
        error(err, 0)
    end
end

---The request body goes through a temp file referenced as `-d @<file>`.
local function request_body(args)
    for i, arg in ipairs(args) do
        if arg == '-d' then
            local data_file = args[i + 1]:sub(2) -- strip '@'
            return vim.json.decode(vim.fn.readfile(data_file)[1])
        end
    end
    error('the request body must be passed to curl')
end

local context = {
    lines_before = 'function add(a, b) {',
    lines_after = '\n}',
}

return {
    {
        name = 'llama_cpp streaming sends input_prefix and input_suffix to /infill and accumulates the stream',
        run = function()
            with_mocked_job(function(ctx)
                local backend = ctx.backend()
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

                local captured = ctx.get()
                local body = request_body(captured.args)
                helpers.expect_equal(body.input_prefix, context.lines_before)
                helpers.expect_equal(body.input_suffix, context.lines_after)
                helpers.expect_equal(body.stream, true)
                -- The native endpoint builds the FIM prompt on the server:
                -- no template keys and no model are sent.
                helpers.expect_falsy(body.prompt)
                helpers.expect_falsy(body.suffix)
                helpers.expect_falsy(body.model)

                -- The provider endpoint is passed through as-is.
                local end_point_seen = false
                for _, arg in ipairs(captured.args) do
                    if arg == 'http://127.0.0.1:8012/infill' then
                        end_point_seen = true
                    end
                end
                helpers.expect_truthy(end_point_seen, 'the /infill endpoint must be requested')

                local handlers = captured.handlers
                helpers.expect_truthy(handlers.on_stdout)
                handlers.on_stdout(nil, 'data: {"content":"turn","stop":false}\r\n')
                handlers.on_stdout(nil, 'data: {"content":" a + b;","stop":true}\r\n')
                handlers.on_exit({ code = 0 }, captured.data_file)

                helpers.expect_equal(updates, { 'turn', 'turn a + b;' })
                helpers.expect_equal(result, { 'turn a + b;' })
            end)
        end,
    },
    {
        name = 'llama_cpp non-streaming reads the content field from the response',
        run = function()
            with_mocked_job(function(ctx)
                local backend = ctx.backend({
                    provider_options = {
                        llama_cpp = { stream = false },
                    },
                })
                local result

                backend:complete(context, {
                    on_finish = function(items)
                        result = items
                    end,
                })

                local handlers = ctx.get().handlers
                helpers.expect_falsy(handlers.on_stdout)
                handlers.on_exit({ code = 0, stdout = '{"content":"plain"}' }, ctx.get().data_file)

                helpers.expect_equal(result, { 'plain' })
            end)
        end,
    },
    {
        name = 'llama_cpp forwards the captured extra context as input_extra',
        run = function()
            local context_with_extra = vim.deepcopy(context)
            context_with_extra.extra = {
                { filename = 'src/utils.lua', text = 'local function helper() end' },
            }

            with_mocked_job(function(ctx)
                local backend = ctx.backend()
                local result

                backend:complete(context_with_extra, {
                    on_finish = function(items)
                        result = items
                    end,
                })

                local body = request_body(ctx.get().args)
                helpers.expect_equal(body.input_extra, {
                    { filename = 'src/utils.lua', text = 'local function helper() end' },
                })

                local handlers = ctx.get().handlers
                handlers.on_stdout(nil, 'data: {"content":"ok","stop":true}\r\n')
                handlers.on_exit({ code = 0 }, ctx.get().data_file)
                helpers.expect_equal(result, { 'ok' })
            end)
        end,
    },
    {
        name = 'llama_cpp omits input_extra when the context has none',
        run = function()
            with_mocked_job(function(ctx)
                local backend = ctx.backend()

                backend:complete(context, {
                    on_finish = function() end,
                })

                local body = request_body(ctx.get().args)
                helpers.expect_falsy(body.input_extra)
            end)
        end,
    },
}

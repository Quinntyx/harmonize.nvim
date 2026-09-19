--- Response decoding shared by all backends: turns a finished curl job into
--- the raw completion text, for both streamed and non-streamed responses.
local notify = require 'harmonize.notify'

local M = {}

---@param response vim.SystemCompleted
function M.no_stream_decode(response, data_file, provider, get_text_fn)
    vim.uv.fs_unlink(data_file)

    if response.code ~= 0 then
        if response.code == 28 then
            notify.notify('Request timed out.', 'warn', vim.log.levels.WARN)
        else
            notify.notify(string.format('Request failed with exit code %d', response.code), 'error', vim.log.levels.ERROR)
        end
        return
    end

    local result = response.stdout or ''
    local success, json = pcall(vim.json.decode, result)
    if not success then
        if result ~= '' then
            notify.notify(
                'Failed to parse ' .. provider .. ' API response as json: ' .. vim.inspect(result),
                'error',
                vim.log.levels.ERROR
            )
        end
        return
    end

    local result_str

    success, result_str = pcall(get_text_fn, json)

    if not success or type(result_str) ~= 'string' or result_str == '' then
        if result:find 'error' then
            notify.notify(provider .. ' returns error: ' .. vim.inspect(result), 'error', vim.log.levels.ERROR)
        else
            notify.notify(provider .. ' returns no text: ' .. vim.inspect(json), 'verbose', vim.log.levels.INFO)
        end
        return
    end

    return result_str
end

---@param response vim.SystemCompleted
function M.stream_decode(response, data_file, provider, get_text_fn)
    vim.uv.fs_unlink(data_file)

    if not (response.code == 28 or response.code == 0) then
        notify.notify(string.format('Request failed with exit code %d', response.code), 'error', vim.log.levels.ERROR)
        return
    end

    local result = {}
    local responses = vim.split(response.stdout or '', '\n', { plain = true, trimempty = false })

    for _, line in ipairs(responses) do
        local success, json, text

        line = line:gsub('^data:', '')
        success, json = pcall(vim.json.decode, line)
        if not success then
            goto continue
        end

        success, text = pcall(get_text_fn, json)
        if not success then
            goto continue
        end

        if type(text) == 'string' and text ~= '' then
            table.insert(result, text)
        end
        ::continue::
    end

    local result_str = #result > 0 and table.concat(result) or nil

    if not result_str then
        local notified_on_error = false
        for _, line in ipairs(responses) do
            if line:find 'error' then
                notify.notify(
                    provider .. ' returns error on streaming: ' .. vim.inspect(responses),
                    'error',
                    vim.log.levels.ERROR
                )

                notified_on_error = true

                break
            end
        end

        if not notified_on_error then
            notify.notify(
                provider .. ' returns no text on streaming: ' .. vim.inspect(responses),
                'verbose',
                vim.log.levels.INFO
            )
        end
        return
    end

    return result_str
end

return M

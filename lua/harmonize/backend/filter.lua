--- Completion-item normalization shared by the backends.
local notify = require 'harmonize.notify'
local text = require 'harmonize.text'

local M = {}

--- Split raw completion text on the <endCompletion> marker.
---@param items_raw string?
---@param provider string
function M.parse_completion_items(items_raw, provider)
    local success, items_table = pcall(vim.split, items_raw, '<endCompletion>')
    if not success then
        notify.notify('Failed to parse ' .. provider .. "'s content text", 'error', vim.log.levels.ERROR)
        return {}
    end

    return items_table
end

--- Trim parts of each item that duplicate the already-sent context, then drop
--- entries that became empty.
---@param items string[]
---@param snapshot { lines_before: string, lines_after: string }
---@param before_length integer
---@param after_length integer
---@return string[]
function M.filter_against_context(items, snapshot, before_length, after_length)
    local filtered = {}

    for _, item in ipairs(items) do
        local processed = text.filter_text(item, snapshot.lines_before, snapshot.lines_after, before_length, after_length)
        if type(processed) == 'string' and processed:find '%S' then
            filtered[#filtered + 1] = processed
        end
    end

    return filtered
end

---@param str_list string[]
---@return table[]
function M.create_chat_messages_from_list(str_list)
    local result = {}
    local roles = { 'user', 'assistant' }

    for i, content in ipairs(str_list) do
        table.insert(result, { role = roles[(i - 1) % 2 + 1], content = content })
    end

    return result
end

---@class harmonize.TransformedRequest
---@field end_point string
---@field headers table
---@field body table

--- Apply the provider's transform functions to the request.
---@param transform fun(data: harmonize.TransformedRequest)[]
---@param end_point string
---@param headers table
---@param body table
---@return harmonize.TransformedRequest
function M.apply_transforms(transform, end_point, headers, body)
    local transformed_data = {
        end_point = end_point,
        headers = headers,
        body = body,
    }

    for _, fun in ipairs(transform or {}) do
        transformed_data = fun(transformed_data)
    end

    return transformed_data
end

return M

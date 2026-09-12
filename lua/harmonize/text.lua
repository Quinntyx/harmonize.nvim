--- Pure text helpers shared by the backends and completion handling.
local M = {}

---@class harmonize.TrimCompletionItemOpts
---@field keep_leading_newline? boolean

--- Remove trailing and leading whitespace from a single completion item.
---@param item string
---@param opts? harmonize.TrimCompletionItemOpts
---@return string?
local function trim_item(item, opts)
    if not item:find '%S' then -- skip entries that contain only whitespace
        return nil
    end

    local start_pattern = opts and opts.keep_leading_newline and '^[ \t]+' or '^%s+'

    -- replace the trailing spaces
    item = item:gsub('%s+$', '')
    -- replace the leading spaces
    item = item:gsub(start_pattern, '')

    return item
end

function M.trim_completion_item(item, opts)
    return trim_item(item, opts)
end

--- Remove trailing and leading whitespace from each completion item.
---@param items string[]
---@param opts? harmonize.TrimCompletionItemOpts
---@return string[]
function M.trim_completion_items(items, opts)
    local new = {}

    for _, item in ipairs(items) do
        local item_processed = trim_item(item, opts)
        if item_processed then
            table.insert(new, item_processed)
        end
    end

    return new
end

-- Find the longest string that is a prefix of A and a suffix of B. The
-- function iterates from the longest possible match length downwards for
-- efficiency. If A or B are not strings, it returns an empty string.
---@param a string?
---@param b string?
function M.find_longest_match(a, b)
    if type(a) ~= 'string' or type(b) ~= 'string' then
        return ''
    end

    local max_len = math.min(#a, #b)

    for len = max_len, 1, -1 do
        local prefix_a = string.sub(a, 1, len)
        local suffix_b = string.sub(b, -len)

        if prefix_a == suffix_b then
            return prefix_a
        end
    end

    return ''
end

--- Trim the parts of a completion that duplicate already-sent context.
---@param text string?
---@param before string? text already sent before the cursor
---@param after string? text already sent after the cursor
---@param before_length integer minimum match length to trim from the front
---@param after_length integer minimum match length to trim from the end
---@return string?
function M.filter_text(text, before, after, before_length, after_length)
    if not text then
        return text
    end

    if before_length <= 0 and after_length <= 0 then
        return text
    end

    text = trim_item(text, { keep_leading_newline = true })
    before = trim_item(before or '')
    after = trim_item(after or '')

    if not text then
        return
    end

    local filtered_text = text

    -- Filter based on context before cursor (trim from the beginning of completion)
    if before and before_length > 0 then
        local match_before = M.find_longest_match(filtered_text, before)
        local match_len = vim.fn.strchars(match_before)
        if match_before and match_len >= before_length then
            filtered_text = vim.fn.strcharpart(filtered_text, match_len)
        end
    end

    -- Filter based on context after cursor (trim from the end of completion)
    if after and after_length > 0 then
        local match_after = M.find_longest_match(after, filtered_text)
        local match_len = vim.fn.strchars(match_after)
        if match_after and match_len >= after_length then
            local text_len = vim.fn.strchars(filtered_text)
            filtered_text = vim.fn.strcharpart(filtered_text, 0, text_len - match_len)
        end
    end

    return filtered_text
end

--- Drop duplicate strings, keeping the first occurrence of each.
---@param list string[]
---@return string[]
function M.list_dedup(list)
    local hash = {}
    local cleaned = {}

    for _, item in ipairs(list) do
        if type(item) == 'string' and not hash[item] then
            hash[item] = true
            table.insert(cleaned, item)
        end
    end

    return cleaned
end

return M

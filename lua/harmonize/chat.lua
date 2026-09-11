--- Chat prompt construction shared by the chat-style legacy backends.
local value = require 'harmonize.value'

local M = {}

---Expand `{{{key}}}` placeholders in `template_str`. Each key is looked up in
---`values` and the raw value passed to `eval`; a string result is substituted,
---anything else drops the placeholder. Substituted text is inserted literally
---and never rescanned for placeholders.
---@param template_str string
---@param values table<string, any>
---@param eval fun(value: any): any
---@return string
function M.expand_template(template_str, values, eval)
    local parts = {}
    local last_pos = 1

    while true do
        local start_pos, end_pos = template_str:find('{{{.-}}}', last_pos)
        if not start_pos then
            table.insert(parts, template_str:sub(last_pos))
            break
        end

        table.insert(parts, template_str:sub(last_pos, start_pos - 1))

        local rendered = eval(values[template_str:sub(start_pos + 3, end_pos - 3)])
        if type(rendered) == 'string' then
            table.insert(parts, rendered)
        end

        last_pos = end_pos + 1
    end

    return table.concat(parts)
end

function M.get_or_eval(val)
    return value.get_or_eval(val)
end

---@param template table System prompt spec: `template`, optional `n_completion_template`, plus placeholder values.
---@param n_completion number?
---@return string
function M.make_system_prompt(template, n_completion)
    local system_prompt = value.get_or_eval(template.template)
    local n_completion_template = value.get_or_eval(template.n_completion_template)
    local values = vim.tbl_extend('force', {}, template)
    values.template = nil
    values.n_completion_template = nil

    if type(n_completion_template) == 'string' and type(n_completion) == 'number' then
        values.n_completion_template = string.format(n_completion_template, n_completion)
    end

    return M.expand_template(system_prompt, values, value.get_or_eval)
end

---@param context table cursor snapshot
---@param template table Chat input spec: `template` (string or string[]) plus placeholder values.
---@return string[]
function M.make_chat_llm_shot(context, template)
    local inputs = template.template
    if type(inputs) == 'string' then
        inputs = { inputs }
    end
    local values = vim.tbl_extend('force', {}, template)
    values.template = nil

    local function eval(entry)
        if type(entry) == 'function' then
            return entry(context.lines_before, context.lines_after, context.opts)
        end
        return entry
    end

    local results = {}
    for _, input in ipairs(inputs) do
        table.insert(results, M.expand_template(input, values, eval))
    end

    return results
end

return M

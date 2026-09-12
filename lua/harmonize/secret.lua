--- Reads an API key from an environment variable or a function.
local M = {}

---@param env_var string|fun(): string?
---@return string?
function M.get_api_key(env_var)
    local api_key
    if type(env_var) == 'function' then
        api_key = env_var()
    elseif type(env_var) == 'string' then
        api_key = vim.env[env_var]
    end

    if type(api_key) ~= 'string' or api_key == '' then
        return nil
    end

    return api_key
end

return M

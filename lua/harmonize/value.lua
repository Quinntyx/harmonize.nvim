--- Calls a value when it is a function, otherwise returns it as-is.
---@generic T
---@param val T|fun(): T
---@return T
local M = {}

function M.get_or_eval(val)
    if type(val) ~= 'function' then
        return val
    end
    return val()
end

return M

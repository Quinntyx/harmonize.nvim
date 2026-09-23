--- Finding and downloading the llama.cpp binary backing the auto-started
--- server. Stateless; the ManagedServer object owns the process itself.
local value = require 'harmonize.value'

local M = {}

local data_dir = vim.fn.stdpath('data') .. '/harmonize'

-- Release tags before the v0.x scheme published one zip per platform; the
-- v0.x tags carry no binary assets. When the GitHub API is unreachable this
-- pinned tag is used instead.
M.fallback_release = 'b4600'

M.data_dir = data_dir

-- Where the binaries sit inside an extracted release zip, relative to the
-- extraction directory. The layout differs between releases: the pinned
-- b4600 zip nests them under build/bin/.
local binary_relpaths = {
    '/bin/llama',
    '/bin/llama-server',
    '/build/bin/llama',
    '/build/bin/llama-server',
}

--- Whether curl is available for downloads and health checks.
function M.has_curl()
    return vim.fn.executable 'curl' == 1
end

--- The llama.cpp binary: an installed one wins, otherwise the downloaded
--- release in the data directory.
function M.resolve_binary()
    for _, name in ipairs { 'llama', 'llama-server' } do
        if vim.fn.executable(name) == 1 then
            return name
        end
    end

    for _, rel in ipairs(binary_relpaths) do
        local best, best_build
        for _, candidate in ipairs(vim.fn.glob(data_dir .. '/llama.cpp/*' .. rel, false, true)) do
            local build = tonumber(candidate:match('/b(%d+)/')) or -1
            if vim.fn.executable(candidate) == 1 and (not best_build or build > best_build) then
                best = candidate
                best_build = build
            end
        end
        if best then
            return best
        end
    end

    return nil
end

--- Newest tag whose Ubuntu x64 asset still exists; `nil` when the API cannot
--- be reached (the caller falls back to the pinned tag).
function M.latest_release_tag()
    if not M.has_curl() then
        return nil
    end

    local ok_handle, handle_or_err = pcall(vim.system, {
        'curl',
        '-fsSL',
        '--max-time',
        '10',
        'https://api.github.com/repos/ggml-org/llama.cpp/releases?per_page=20',
    }, { text = true })
    if not ok_handle then
        return nil
    end

    local result = handle_or_err:wait()
    if result.code ~= 0 then
        return nil
    end

    local ok_parse, releases = pcall(vim.json.decode, result.stdout)
    if not ok_parse or type(releases) ~= 'table' then
        return nil
    end

    for _, release in ipairs(releases) do
        local tag = release.tag_name
        if type(tag) == 'string' and tag:match '^b%d+$' then
            for _, asset in ipairs(release.assets or {}) do
                if type(asset.name) == 'string' and asset.name:match '^llama%-b%d+%-bin%-ubuntu%-x64%.zip$' then
                    return tag
                end
            end
        end
    end

    return nil
end

--- Download a llama.cpp release zip and unpack it into the data directory,
--- then call `then_fn`.
---@param version string
---@param then_fn fun()
function M.download_binary(version, then_fn)
    local dest_dir = data_dir .. '/llama.cpp/' .. version
    local zip_path = vim.fn.tempname() .. '.zip'

    for _, rel in ipairs(binary_relpaths) do
        if vim.fn.filereadable(dest_dir .. rel) == 1 then
            then_fn()
            return
        end
    end

    if vim.fn.executable 'unzip' ~= 1 then
        vim.notify('llama.cpp not found and `unzip` is missing; install it or put `llama` on PATH', vim.log.levels.ERROR)
        return
    end

    if not M.has_curl() then
        vim.notify(
            'llama.cpp not found and `curl` is missing; install it or put `llama` on PATH',
            vim.log.levels.ERROR
        )
        return
    end

    -- unzip creates the final component of -d only when its parent exists,
    -- and a fresh data directory has no llama.cpp/ yet.
    vim.fn.mkdir(dest_dir, 'p')

    local url = ('https://github.com/ggml-org/llama.cpp/releases/download/%s/llama-%s-bin-ubuntu-x64.zip')
        :format(version, version)

    vim.notify('Downloading llama.cpp ' .. version .. ' (' .. url .. ')', vim.log.levels.INFO)
    -- The system callbacks run in a fast event, where vim.notify errors, so
    -- they are scheduled back onto the main loop.
    vim.system({ 'curl', '-fL', '--retry', '2', '-o', zip_path, url }, nil, vim.schedule_wrap(function(out)
        if out.code ~= 0 then
            vim.uv.fs_unlink(zip_path)
            vim.notify(
                ('llama.cpp download failed (exit %d): %s'):format(out.code, vim.trim(out.stderr or '')),
                vim.log.levels.ERROR
            )
            return
        end
        vim.system({ 'unzip', '-q', '-o', zip_path, '-d', dest_dir }, nil, vim.schedule_wrap(function(unzip_out)
            vim.uv.fs_unlink(zip_path)
            if unzip_out.code ~= 0 then
                vim.notify(
                    ('llama.cpp download failed to unzip (exit %d): %s'):format(
                        unzip_out.code,
                        vim.trim(unzip_out.stderr or '')
                    ),
                    vim.log.levels.ERROR
                )
                return
            end
            vim.notify('llama.cpp ' .. version .. ' installed in ' .. dest_dir, vim.log.levels.INFO)
            then_fn()
        end))
    end))
end

--- Build the server command from the base command in `opts.cmd`, the model
--- (a Hugging Face repo id or a local file), the host and port to listen on,
--- and the extra arguments.
---@param opts table the auto_start options
---@param host string
---@param port integer
---@return string[]? cmd nil when the binary could not be resolved
function M.server_cmd(opts, host, port)
    local words = vim.split(opts.cmd, '%s+', { trimempty = true })
    local binary = words[1]

    if vim.fn.executable(binary) ~= 1 then
        -- The binary leading the command is not on PATH; fall back to a
        -- downloaded llama.cpp release.
        binary = M.resolve_binary()
        if not binary then
            return nil
        end
        words[1] = binary
        -- The downloaded `llama` binary needs its `serve` subcommand; an
        -- explicit `llama-server` binary does not.
        if vim.fn.fnamemodify(binary, ':t') == 'llama' and not vim.tbl_contains(words, 'serve') then
            table.insert(words, 2, 'serve')
        end
    end

    local expanded_model = vim.fn.expand(opts.model)
    local is_local_model = opts.model:lower():match '%.gguf$' or vim.fn.filereadable(expanded_model) == 1
    if opts.model:match '^[^/]+/[^/]+$' and not is_local_model then
        vim.list_extend(words, { '-hf', opts.model })
    else
        vim.list_extend(words, { '--model', expanded_model })
    end

    vim.list_extend(words, { '--host', host, '--port', tostring(port) })
    vim.list_extend(words, value.get_or_eval(opts.extra_args) or {})

    return words
end

return M

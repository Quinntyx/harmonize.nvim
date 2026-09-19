--- The completion as a live character stream: the model appends to `raw`
--- while the user takes from the front by typing or accepting. The visible
--- suggestion is the unconsumed remainder. Pure state: no nvim APIs.
---@class harmonize.CompletionSession
local Session = {}
Session.__index = Session

---@param chunk_options? table
function Session.new(chunk_options)
    return setmetatable({
        chunk_options = chunk_options or {},
        suggestion = nil,
        shown = nil,
        last_pos = nil,
        event_pos = nil,
        event_tick = nil,
        stream = nil, -- { raw, consumed, done }
    }, Session)
end

function Session:start_stream()
    self.stream = { raw = '', consumed = 0, done = false }
end

--- Reset all suggestion state, e.g. on insert leave or dismiss.
function Session:reset()
    self.suggestion = nil
    self.shown = nil
    self.last_pos = nil
    self.stream = nil
end

function Session:remaining()
    return self.stream.raw:sub(self.stream.consumed + 1)
end

--- Recompute the suggestion as the part of the stream the user has not taken.
function Session:refresh()
    self.suggestion = self:remaining()
end

--- Replace the raw stream text with the latest complete snapshot.
---@param text string
function Session:update_raw(text)
    self.stream.raw = text
    self:refresh()
end

--- Start appending a continuation to the current suggestion stream.
---@return table stream
---@return string base_raw
function Session:start_extension()
    if not self.stream then
        self.stream = {
            raw = self.suggestion or '',
            consumed = 0,
            done = false,
        }
    else
        self.stream.done = false
    end
    return self.stream, self.stream.raw
end

---@param stream table
---@param base_raw string
---@param extension string
---@return boolean updated
function Session:update_extension(stream, base_raw, extension)
    if self.stream ~= stream then
        return false
    end
    stream.raw = base_raw .. extension
    self:refresh()
    return true
end

---@return integer
function Session:complete_line_count()
    return select(2, (self.suggestion or ''):gsub('\n', ''))
end

--- Advance the stream by `typed` when it continues the current suggestion.
---@param typed string
---@return boolean true when the suggestion advanced
function Session:consume_typed(typed)
    if #typed == 0 or typed ~= self.suggestion:sub(1, #typed) then
        return false
    end

    if self.stream and #self.stream.raw > 0 then
        -- In stream mode the typing advances the stream pointer instead of
        -- trimming in place: the model keeps appending to the tail.
        self.stream.consumed = self.stream.consumed + #typed
        self:refresh()
    else
        self.suggestion = self.suggestion:sub(#typed + 1, -1)
    end

    return true
end

--- Split a suggestion at the next chunk boundary. Walk the suggestion one
--- character at a time: consume alphanumeric characters and underscores, and
--- the first special character switches to terminating mode. In that mode the
--- next alphanumeric character ends the chunk and is excluded from it, so a
--- chunk is one identifier plus the special characters that follow it. A run
--- of spaces or tabs ends the chunk after that whitespace, so "value == other"
--- splits as "value ", "== ", and "other". When the suggestion starts with
--- special characters, those close out the previous chunk (its identifier was
--- already typed): after typing "r" of "r#my_var_name", the next chunk is "#"
--- and only then "my_var_name".
---
--- A chunk never crosses a newline unless the newline is its first character.
--- Such a chunk contains the newline and its indentation. Configured
--- allow_post_newline_chars may include punctuation such as "." after it.
---@param suggestion string
---@param options? table
---@return string, string the next chunk and the remaining suggestion
function Session.split_chunk(suggestion, options)
    options = options or {}
    local allowed_after_newline = options.allow_post_newline_chars or ''
    local terminates = false

    for pos = 1, #suggestion do
        local byte = suggestion:byte(pos)
        if byte == 10 then
            if pos ~= 1 then
                return suggestion:sub(1, pos - 1), suggestion:sub(pos)
            end

            local chunk_end = 1
            while chunk_end < #suggestion do
                local next_byte = suggestion:byte(chunk_end + 1)
                if next_byte ~= 32 and next_byte ~= 9 then
                    break
                end
                chunk_end = chunk_end + 1
            end
            while chunk_end < #suggestion do
                local character = suggestion:sub(chunk_end + 1, chunk_end + 1)
                if not allowed_after_newline:find(character, 1, true) then
                    break
                end
                chunk_end = chunk_end + 1
            end
            return suggestion:sub(1, chunk_end), suggestion:sub(chunk_end + 1)
        elseif byte == 32 or byte == 9 then
            local chunk_end = pos
            while chunk_end < #suggestion do
                local next_byte = suggestion:byte(chunk_end + 1)
                if next_byte ~= 32 and next_byte ~= 9 then
                    break
                end
                chunk_end = chunk_end + 1
            end
            return suggestion:sub(1, chunk_end), suggestion:sub(chunk_end + 1)
        elseif byte == 95 or (byte >= 48 and byte <= 57) or (byte >= 65 and byte <= 90) or (byte >= 97 and byte <= 122) then
            -- Alphanumeric or underscore. In terminating mode the chunk ends
            -- here, leaving this character and the rest for the next chunk.
            if terminates then
                return suggestion:sub(1, pos - 1), suggestion:sub(pos)
            end
        else
            -- Any other character switches to terminating mode.
            terminates = true
        end
    end

    return suggestion, ''
end

--- Take the next chunk: advance the stream and return what to insert plus
--- whether any suggestion remains.
---@return string chunk, string? remaining nil when the session reset
function Session:take_chunk()
    local chunk, remaining = Session.split_chunk(self.suggestion, self.chunk_options)

    -- Taking a chunk counts as taking it from the stream, so the ghost
    -- continues with what follows and the next accept takes the chunk after
    -- it instead of re-inserting the same one.
    if self.stream then
        self.stream.consumed = self.stream.consumed + #chunk
        self:refresh()
    else
        self.suggestion = remaining
    end

    local more = #remaining > 0 or (self.stream and #self.stream.raw > 0 and not self.stream.done)
    if not more then
        self:reset()
        remaining = nil
    end

    return chunk, remaining
end

--- Take the first n_lines of the suggestion (or all of it when n_lines is
--- nil) and return the text to insert plus the not-yet-accepted lines.
---@param n_lines? integer
---@return string[] lines, string[] remaining_lines
function Session:take_lines(n_lines)
    local suggestion = self.suggestion
    local lines = vim.split(suggestion, '\n', { plain = true })

    if n_lines then
        -- A leading empty element represents the newline before the first
        -- visible line, so accepting one visible line takes two elements.
        if lines[1] == '' then
            n_lines = n_lines + 1
        end
        n_lines = math.min(n_lines, #lines)
        lines = vim.list_slice(lines, 1, n_lines)
    end

    local accepted = table.concat(lines, '\n')
    local remaining = suggestion:sub(#accepted + 1)

    if self.stream then
        self.stream.consumed = self.stream.consumed + #accepted
        self:refresh()
    else
        self.suggestion = remaining
    end

    local more = remaining ~= '' or (self.stream and not self.stream.done)
    if not more then
        self:reset()
    end

    local remaining_lines = remaining == '' and {} or vim.split(remaining, '\n', { plain = true })
    return lines, remaining_lines
end

return Session

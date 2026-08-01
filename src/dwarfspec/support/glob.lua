-- Case-sensitive canonical-identity glob compiler for DwarfSpec commands.

local M = {}

---Escapes one Lua pattern character.
---@param character string
---@return string
local function escape_pattern(character)
    if character:match('[%^%$%(%)%%%.%[%]%+%-%*%?]') then
        return '%' .. character
    end
    return character
end

---Compiles one documented glob into a complete Lua pattern.
---@param expression string
---@return string
function M.compile(expression)
    assert(type(expression) == 'string' and expression ~= '',
        'glob must be a nonempty string')
    local pattern = {'^'}
    local index = 1
    while index <= #expression do
        local character = expression:sub(index, index)
        if character == '\\' then
            assert(index < #expression,
                'malformed glob: trailing escape character')
            index = index + 1
            table.insert(pattern, escape_pattern(
                expression:sub(index, index)))
        elseif character == '*' then
            local run_end = index
            while expression:sub(run_end + 1, run_end + 1) == '*' do
                run_end = run_end + 1
            end
            local count = run_end - index + 1
            assert(count <= 2,
                'malformed glob: at most two adjacent stars are allowed')
            if count == 2 and expression:sub(run_end + 1,
                    run_end + 1) == '/' then
                table.insert(pattern, '.-')
                run_end = run_end + 1
            else
                table.insert(pattern, count == 2 and '.*' or '[^/]*')
            end
            index = run_end
        elseif character == '?' then
            table.insert(pattern, '[^/]')
        elseif character == '[' or character == ']' then
            error('malformed glob: character classes are not supported', 2)
        else
            table.insert(pattern, escape_pattern(character))
        end
        index = index + 1
    end
    table.insert(pattern, '$')
    return table.concat(pattern)
end

---Returns whether one canonical identity matches a compiled glob.
---@param identity string
---@param expression string
---@return boolean
function M.matches(identity, expression)
    assert(type(identity) == 'string', 'identity must be a string')
    return identity:match(M.compile(expression)) ~= nil
end

---Selects matching identities without changing their stable input order.
---@param identities string[]
---@param expression string|nil
---@return string[]
function M.select(identities, expression)
    if expression == nil then
        local copy = {}
        for _, identity in ipairs(identities) do
            table.insert(copy, identity)
        end
        return copy
    end
    local pattern = M.compile(expression)
    local selected = {}
    for _, identity in ipairs(identities) do
        if identity:match(pattern) then table.insert(selected, identity) end
    end
    return selected
end

return M

-- Starts an in-process Busted automation run and returns immediately.

local arguments = {...}

---Derives the DwarfSpec package root from this entry point's source path.
---@return string
local function package_root()
    local source = debug.getinfo(1, 'S').source:gsub('^@', '')
    local root = source:match('^(.*)[/\\]tests[/\\]automation[/\\]bootstrap%.lua$')
    return assert(root, 'could not derive repository root from ' .. source)
end

---Parses one positive integer option.
---@param name string
---@param value string
---@return integer
local function positive_integer(name, value)
    local number = tonumber(value)
    if not number or number < 1 or number % 1 ~= 0 then
        error(name .. ' must be a positive integer')
    end
    return number
end

---Parses the intentionally small bootstrap option surface.
---@param args string[]
---@return table
local function parse_options(args)
    local options = {
        run_id=assert(args[1], 'run id argument is required'),
        filters={},
        filter_out={},
        names={},
        tags={},
        exclude_tags={},
        repeat_count=1,
        seed=1,
        spec=nil,
        project_root=dfhack.filesystem.getcwd(),
        defer_frames=1,
        lease_timeout_ms=5000,
        lease_check_frames=30,
    }
    for index = 2, #args do
        local argument = args[index]
        local name, value = argument:match('^%-%-([%w-]+)=(.*)$')
        if not name then error('invalid automation option: ' .. argument) end
        if name == 'filter' then
            table.insert(options.filters, value)
        elseif name == 'filter-out' then
            table.insert(options.filter_out, value)
        elseif name == 'name' then
            table.insert(options.names, value)
        elseif name == 'tag' then
            table.insert(options.tags, value)
        elseif name == 'exclude-tag' then
            table.insert(options.exclude_tags, value)
        elseif name == 'repeat' then
            options.repeat_count = positive_integer('--repeat', value)
        elseif name == 'seed' then
            options.seed = positive_integer('--seed', value)
        elseif name == 'defer-frames' then
            options.defer_frames = positive_integer('--defer-frames', value)
        elseif name == 'lease-timeout-ms' then
            options.lease_timeout_ms = positive_integer(
                '--lease-timeout-ms', value)
        elseif name == 'lease-check-frames' then
            options.lease_check_frames = positive_integer(
                '--lease-check-frames', value)
        elseif name == 'spec' then
            if not value:match('^[%w_./-]+_spec%.ds%.lua$') or
                    value:match('^[/\\]') or value:match('%.%.[/\\]') then
                error('--spec must name one project-relative *_spec.ds.lua path')
            end
            options.spec = value
        elseif name == 'project-root' then
            if value == '' then error('--project-root must not be empty') end
            options.project_root = value
        else
            error('unknown automation option: --' .. name)
        end
    end
    return options
end

local root = package_root()
local options = parse_options(arguments)
local host = assert(loadfile(root ..
    '/tests/automation/support/busted_host.lua'))()
local run = host.start(root, options.project_root, options)
print(('DWARFSPEC protocol=%d run_id=%s state=%s generation=%d')
    :format(run.protocol_version, run.run_id, run.state, run.generation))
print('DWARFSPEC_JSON ' .. host.encode_report(run))

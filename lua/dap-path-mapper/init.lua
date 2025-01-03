local M = {}

--- Split a string by a separator.
---@param input string
---@param sep string|nil The separator pattern to split the string by. Defaults to whitespace.
local function split(input, sep)
    if sep == nil then
        sep = "%s"
    end

    local parts = {}
    for str in string.gmatch(input, "([^" .. sep .. "]+)") do
        table.insert(parts, str)
    end

    return parts
end

--- Normalize a system path to a directory.
---
--- If the path is a file, the directory containing the file is returned.
--- If the path is a directory, the path is returned unchanged.
---@param file_or_dir string
function M.normalize_to_dir(file_or_dir)
    local dir = vim.fn.fnamemodify(file_or_dir, ':p:h')
    if dir == '' then
        return '/'
    end

    return dir
end

---@class DockerMount
---@field Type string
---@field Source string
---@field Destination string
---@field Mode string
---@field RW boolean
---@field Propagation string

--- Get the Docker mounts for a file or directory.
---@param file_or_dir string
---@return DockerMount[]
function M.docker_mounts_for(file_or_dir)
    local opts = { text = true, cwd = M.normalize_to_dir(file_or_dir) }

    local id_cmd = vim.system({ 'docker', 'compose', 'ps', '-a', '--format', '{{ .ID }}' }, opts):wait()
    local ids = split(vim.trim(id_cmd.stdout))

    local mounts = {}
    for _, id in ipairs(ids) do
        local mnt_cmd = vim.system({ 'docker', 'inspect', id, '--format', '{{ json .Mounts }}' }, opts):wait()
        local found = vim.json.decode(mnt_cmd.stdout)

        for _, mount in ipairs(found) do
            -- only consider bind mounts
            if mount.Type == 'bind' then
                table.insert(mounts, mount)
            end
        end
    end

    return mounts
end

---@enum PathMappingType
local PathMappingType = {
    MAP = "map",
    LIST = "list",
}

---@class PathMapping
---@field localRoot string
---@field remoteRoot string

--- Get the path mappings for a file or directory.
---@param file_or_dir string
---@return PathMapping[]
function M.get_path_mappings_for(file_or_dir)
    local mounts = M.docker_mounts_for(file_or_dir)

    ---@type table<string, PathMapping>
    local mappings = {}

    for _, mount in ipairs(mounts) do
        -- skip duplicate remote roots
        if mappings[mount.Destination] == nil then
            mappings[mount.Destination] = {
                localRoot = mount.Source,
                remoteRoot = mount.Destination,
            }
        end
    end

    return vim.tbl_values(mappings)
end

local function convert_path_mappings_list_to_map(mappings)
    local map = {}
    for _, mapping in ipairs(mappings) do
        map[mapping.remoteRoot] = mapping.localRoot
    end

    return map
end

--- Convert a callback-style function to return the result directly instead.
---
---@param func fun(callback: fun(result: any), ...)
---@return fun(...): any
---@overload fun(func: nil): nil
local function convert_callback_func_to_returning_func(func)
    if func == nil then
        return nil
    end

    return function(...)
        local result = nil

        -- the callback just sets the passed argument to our outer `result`
        local function extract_result(arg)
            result = arg
        end

        -- call the original function with all the given args
        func(extract_result, ...)

        return result
    end
end

---@param _existing_enrich_config fun(config: table, on_config: fun(config: table))|nil
---@param adapter_options AdapterOptions
local function wrap_enrich_config(_existing_enrich_config, adapter_options)
    -- convert this to a returning function to make it easier to wrap
    local external_enrich_config = convert_callback_func_to_returning_func(_existing_enrich_config)

    -- the actual enrich_config that adds all the path mappings
    return function(config, on_config)
        local final_config = vim.deepcopy(config)

        if external_enrich_config ~= nil then
            final_config = external_enrich_config(final_config)
        end

        local existing_mappings = final_config.pathMappings or {}
        local new_mappings = M.get_path_mappings_for(final_config.program)

        local merged_mappings
        if not vim.islist(existing_mappings) or adapter_options.path_mapping_type == PathMappingType.MAP then
            local converted_mappings = convert_path_mappings_list_to_map(new_mappings)
            merged_mappings = vim.tbl_extend("force", {}, converted_mappings, existing_mappings)
        else
            merged_mappings = vim.iter({ existing_mappings, new_mappings }):flatten():totable()
        end

        final_config.pathMappings = merged_mappings

        on_config(final_config)
    end
end

---@class AdapterOptions
---@field path_mapping_type PathMappingType

---@class SetupOptions
---@field adapter_options table<string, AdapterOptions>

--- Enrich all existing DAP configurations with path mappings.
---@param opts SetupOptions|nil
function M.setup(opts)
    opts = vim.tbl_deep_extend("force", {
        adapter_options = {
            php = {
                path_mapping_type = PathMappingType.MAP,
            },
        },
    }, opts or {})

    local dap = require('dap')
    local defined_adapters = vim.tbl_keys(dap.adapters)

    for _, name in ipairs(defined_adapters) do
        local existing_adapter = dap.adapters[name]

        local wrapper = function(on_config, config, parent_session)
            local adapter_tbl

            -- resolve the initial adapter table
            if vim.is_callable(existing_adapter) then
                local inner_adapter_func = convert_callback_func_to_returning_func(existing_adapter)
                adapter_tbl = inner_adapter_func(config, parent_session)
            else
                adapter_tbl = existing_adapter
            end

            -- inject our enrich_config, wrapping around any existing enrich_config
            adapter_tbl.enrich_config = wrap_enrich_config(config.enrich_config, opts.adapter_options[name] or {})

            -- register the new adapter
            on_config(adapter_tbl)
        end

        dap.adapters[name] = wrapper
    end
end

return M

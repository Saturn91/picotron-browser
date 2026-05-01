function get_dir_size(path)
    local total = 0
    local files = ls(path)
    for f in all(files) do
        local full = path .. "/" .. f
        local sub_entries = ls(full)
        if sub_entries ~= nil then
            total += get_dir_size(full)
        else
            local _, size = fstat(full)
            total += size or 0
        end
    end
    return total
end

function get_podnet_stats()
    local base_url = "podnet://" .. stat(64)

    local tot_size = get_dir_size(base_url)

    local MB    = 1000000
    local MB_64 = 64 * MB
    local fill_rate = tot_size / MB_64
    local percentage = ceil(fill_rate * 1000) / 10

    return tot_size, percentage
end

p.id = "debug_wiki"
p.help = "Builds a 3D museum of block types (auto-enumerated, crashers excluded). "
      .. "Usage: debug_wiki [start] [count] [filter]"

local function build_block_list()
    local arr = ga_get_block_names_with_prefix("XAR_")
    local names = {}
    if arr then
        for _, v in ipairs(arr) do
            local nm = v
            if type(v) == "table" then nm = v.name end
            if type(nm) == "string" then
                local excluded = block_wiki_bad_blocks and block_wiki_bad_blocks[nm]
                if not excluded then names[#names + 1] = nm end
            end
        end
    end
    table.sort(names)
    return names
end

function p.get_help_str()
    return p.help
end

function p.__load_game()
    if game_command_system then
        game_command_system.add_command(p.id, p.handler)
        game_command_system.add_help(p.id, p.get_help_str())
    end
end

function p.handler(str)
    local level = ga_get_viewer_level()
    local bp_origin = ga_get_viewer_bp(level)
    local ox, oy, oz = bp_origin.x, bp_origin.y, bp_origin.z

    local args = {}
    for word in string.gmatch(str, "%S+") do table.insert(args, word) end

    local start_idx  = tonumber(args[1]) or 1
    local batch_size = tonumber(args[2]) or 1000
    local filter_str = args[3]

    local blocks = build_block_list()
    local total_blocks = #blocks
    if total_blocks == 0 then
        ga_console_print("DEBUG: ERROR - no blocks enumerated. "
            .. "ga_get_block_names_with_prefix returned nothing.")
        return false
    end

    if filter_str then
        ga_console_print("DEBUG: Searching for MAX " .. batch_size .. " blocks matching '"
            .. filter_str .. "' starting at " .. start_idx .. " (of " .. total_blocks .. ")")
    else
        ga_console_print("DEBUG: placing " .. batch_size .. " blocks starting at "
            .. start_idx .. " (of " .. total_blocks .. ")")
    end

    local side = 32
    local spacing = tonumber(args[4]) or 2

    local current_idx = start_idx
    local matches_found = 0

    while matches_found < batch_size and current_idx <= total_blocks do
        local name = blocks[current_idx]
        if name then
            local is_match = true
            if filter_str then
                if not string.find(string.upper(name), string.upper(filter_str)) then
                    is_match = false
                end
            end

            if is_match then
                local idx = matches_found
                local layer_size = side * side

                local yi = math.floor(idx / layer_size)
                local layer_idx = idx % layer_size

                local xi = layer_idx % side
                local zi = math.floor(layer_idx / side)

                local tx = ox + (xi * spacing)
                local ty = oy + (yi * spacing)
                local tz = oz + (zi * spacing)

                local bp = std.bp(tx, ty, tz)

                if matches_found % 10 == 0 then
                    ga_console_print("Placing ["..current_idx.."]: " .. name)
                end

                local _h = ga_open_file_for_writing("debug_wiki_progress.txt")
                if _h then ga_write(_h, "idx=" .. current_idx .. " name=" .. name .. "\n"); ga_close_file(_h) end

                local status, err = pcall(ga_block_change_perm, level, bp, name)
                if not status then
                    ga_console_print("  -> FAILED: " .. tostring(err))
                end

                matches_found = matches_found + 1
            end
        end
        current_idx = current_idx + 1
    end

    ga_console_print("Batch Complete. Placed " .. matches_found .. " blocks. Scanned up to " .. (current_idx - 1))
    if current_idx <= total_blocks then
        if filter_str then
             ga_console_print("Next command: debug_wiki " .. current_idx .. " " .. batch_size .. " " .. filter_str)
        else
             ga_console_print("Next command: debug_wiki " .. current_idx .. " " .. batch_size)
        end
    else
        ga_console_print("End of block list reached.")
    end
    return false
end
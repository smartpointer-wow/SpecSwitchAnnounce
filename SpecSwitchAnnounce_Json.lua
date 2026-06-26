local ADDON, ns = ...
local json = {}
ns.JSON = json

local function skip_ws(str, idx)
    local _, e = str:find("^[ \n\r\t]*", idx)
    return e + 1
end

local parse_value

local escapes = {
    ['"'] = '"', ['\\'] = '\\', ['/'] = '/',
    b = '\b', f = '\f', n = '\n', r = '\r', t = '\t',
}

local function parse_string(str, idx)
    idx = idx + 1
    local buf = {}
    while true do
        local c = str:sub(idx, idx)
        if c == "" then error("unterminated string") end
        if c == '"' then
            return table.concat(buf), idx + 1
        elseif c == '\\' then
            local n = str:sub(idx + 1, idx + 1)
            if n == 'u' then
                local code = tonumber(str:sub(idx + 2, idx + 5), 16) or 0
                if code < 0x80 then
                    buf[#buf + 1] = string.char(code)
                elseif code < 0x800 then
                    buf[#buf + 1] = string.char(0xC0 + math.floor(code / 0x40), 0x80 + code % 0x40)
                else
                    buf[#buf + 1] = string.char(
                        0xE0 + math.floor(code / 0x1000),
                        0x80 + math.floor(code / 0x40) % 0x40,
                        0x80 + code % 0x40)
                end
                idx = idx + 6
            else
                buf[#buf + 1] = escapes[n] or n
                idx = idx + 2
            end
        else
            buf[#buf + 1] = c
            idx = idx + 1
        end
    end
end

local function parse_number(str, idx)
    local s, e = str:find("^%-?%d+%.?%d*[eE]?[%+%-]?%d*", idx)
    return tonumber(str:sub(s, e)), e + 1
end

local function parse_array(str, idx)
    local arr = {}
    idx = skip_ws(str, idx + 1)
    if str:sub(idx, idx) == ']' then return arr, idx + 1 end
    while true do
        local val
        val, idx = parse_value(str, idx)
        arr[#arr + 1] = val
        idx = skip_ws(str, idx)
        local c = str:sub(idx, idx)
        if c == ',' then
            idx = skip_ws(str, idx + 1)
        elseif c == ']' then
            return arr, idx + 1
        else
            error("expected ',' or ']' at " .. idx)
        end
    end
end

local function parse_object(str, idx)
    local obj = {}
    idx = skip_ws(str, idx + 1)
    if str:sub(idx, idx) == '}' then return obj, idx + 1 end
    while true do
        idx = skip_ws(str, idx)
        if str:sub(idx, idx) ~= '"' then error("expected key at " .. idx) end
        local key
        key, idx = parse_string(str, idx)
        idx = skip_ws(str, idx)
        if str:sub(idx, idx) ~= ':' then error("expected ':' at " .. idx) end
        idx = skip_ws(str, idx + 1)
        local val
        val, idx = parse_value(str, idx)
        obj[key] = val
        idx = skip_ws(str, idx)
        local c = str:sub(idx, idx)
        if c == ',' then
            idx = idx + 1
        elseif c == '}' then
            return obj, idx + 1
        else
            error("expected ',' or '}' at " .. idx)
        end
    end
end

function parse_value(str, idx)
    idx = skip_ws(str, idx)
    local c = str:sub(idx, idx)
    if c == '{' then return parse_object(str, idx)
    elseif c == '[' then return parse_array(str, idx)
    elseif c == '"' then return parse_string(str, idx)
    elseif c == 't' then return true, idx + 4
    elseif c == 'f' then return false, idx + 5
    elseif c == 'n' then return nil, idx + 4
    else return parse_number(str, idx) end
end

function json.decode(str)
    if type(str) ~= "string" then return nil, "input is not a string" end
    local ok, val = pcall(parse_value, str, 1)
    if ok then return val end
    return nil, tostring(val)
end

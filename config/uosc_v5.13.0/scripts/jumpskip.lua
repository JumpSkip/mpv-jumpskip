--[[
    mpv-skip-segment
    version 2.3
    ================
    A Lua script for mpv that detects and skips segments (intros, recaps, outros/credits, previews,
    and movie end-credits/post-credits) using crowdsourced data from TheIntroDB (api.theintrodb.org),
    IntroDB (introdb.app), and SkipDB (skipdb.tv).

    Features:
    - Triple provider support: TheIntroDB (v4 OpenAPI), IntroDB (OpenAPI), and SkipDB (openAPI)
    - Movie support: IntroDB end-credits (outro) and post-credits segments (is_movie=true)
    - Automatic provider fallback and intelligent segment merging
    - Fully non-blocking asynchronous HTTP requests using curl via mp.command_native_async
    - Interactive on-screen clickable button (Netflix-style) with cursor hover feedback
    - Dynamic mouse click capture (MBTN_LEFT) only while hovering over the button
    - Keybindable action (default: Tab)
    - Automatic media identification via file metadata tags, filename regex (SxxExx, movie years, IDs),
      and fallback title lookup
    - Configurable auto-skip with optional countdown
    - Fully configurable via ~~/script-opts/jumpskip.conf

    License: MIT
--]]

local mp      = require 'mp'
local utils   = require 'mp.utils'
local assdraw = require 'mp.assdraw'
local options = require 'mp.options'

local user_opts = {
    enabled              = true,
    playlist_prefetch    = true,
    auto_skip            = false,
    auto_skip_countdown  = 0,
    autoskip_types       = "",
    skip_button_timeout  = 0,

    filter_directories      = "",
    show_colored_segments         = true,
    show_colored_intro_segments   = true,
    show_colored_recap_segments   = true,
    show_colored_outro_segments   = true,
    show_colored_preview_segments = true,
    show_colored_post_credits_segments = true,
    skip_intro           = true,
    skip_recap           = true,
    skip_outro           = true,
    skip_preview         = false,
    skip_post_credits    = false,

    theintrodb_intro_segment   = true,
    theintrodb_recap_segment   = true,
    theintrodb_outro_segment   = true,
    theintrodb_preview_segment = true,
    introdb_intro_segment      = true,
    introdb_recap_segment      = true,
    introdb_outro_segment      = true,
    introdb_preview_segment    = true,
    introdb_post_credits_segment = true,
    skipdb_intro_segment       = true,
    skipdb_recap_segment       = true,
    skipdb_outro_segment       = true,
    skipdb_preview_segment     = true,
    mark_chapters        = true,
    default_chapter_title = "Chapter",
    start_offset         = 0.0,
    end_offset           = 0.0,
    provider_priority_tvshow = "",
    provider_priority_movie = "",
    merge_providers      = true,
    theintrodb_api_key   = "",
    introdb_api_key      = "",
    skipdb_api_key       = "",
    tmdb_api_key         = "",
    request_timeout      = 8,
    keybind              = "Tab",
    toggle_keybind       = "Ctrl+j",
    provider_keybind     = "Ctrl+p",
    min_segment_duration = 3.0,
    enable_submission           = true,
    submission_keybind          = "Ctrl+Q",
    theintrodb_submit_enabled   = true,
    introdb_submit_enabled      = true,
    skipdb_submit_enabled       = true,
    button_position      = "bottom-right",
    button_margin_x      = 60,
    button_margin_y      = 80,
    button_width         = 220,
    button_height        = 56,
    button_font_size     = 24,
    button_font          = "mpv-osd",
    button_color_by_segment = false,
    accent_color         = "E75C6C",
    bg_color             = "0A0A0A",
    text_color           = "FFFFFF",
    hint_color           = "AAAAAA",
    show_osd_message     = true,
    osd_message_duration = 2.0,
    debug_mode           = false,
    chapter_skip_enabled        = true,
    chapter_skip_intro          = true,
    chapter_skip_outro          = true,
    chapter_skip_recap          = true,
    chapter_skip_preview        = true,
    chapter_skip_keywords_intro = "intro,introduction,opening,op,theme,title sequence",
    chapter_skip_keywords_outro = "ed,ending,outro,credits,end credits,closing",
    chapter_skip_keywords_recap = "recap,previously",
    chapter_skip_keywords_preview = "preview,next episode",
    chapter_skip_min_duration   = 10.0,
    chapter_skip_max_duration   = 300.0,
    chapter_skip_overlap_threshold = 0.5,
}

local default_opts = {}
for key, value in pairs(user_opts) do default_opts[key] = value end

local runtime_overrides = { providers = {} }

local function log_info(msg, ...)
    mp.msg.info(string.format(msg, ...))
end

local function log_warn(msg, ...)
    mp.msg.warn(string.format(msg, ...))
end

local function log_debug(msg, ...)
    if user_opts.debug_mode then
        mp.msg.info("[DEBUG] " .. string.format(msg, ...))
    end
end

local function log_request(context, level, msg, ...)
    if context and context.quiet then return end
    if level == 'debug' then log_debug(msg, ...)
    else log_info(msg, ...) end
end

local current_bound_key = nil
local current_submission_bound_key = nil
local perform_skip
local toggle_submission_overlay
local render_submission_overlay
local close_submission_overlay
local toggle_enabled
local cycle_provider
local check_playback_position

local function update_runtime_keybinds()
    mp.remove_key_binding("jumpskip_toggle")
    mp.remove_key_binding("jumpskip_cycle_provider")
    mp.add_key_binding(user_opts.toggle_keybind ~= "" and user_opts.toggle_keybind or nil,
        "jumpskip_toggle", function() toggle_enabled() end)
    mp.add_key_binding(user_opts.provider_keybind ~= "" and user_opts.provider_keybind or nil,
        "jumpskip_cycle_provider", function() cycle_provider() end)
end

local function update_keybind()
    if current_bound_key then
        mp.remove_key_binding("jumpskip")
    end
    if user_opts.keybind and #user_opts.keybind > 0 then
        mp.add_key_binding(user_opts.keybind, "jumpskip", function()
            if perform_skip then perform_skip() end
        end)
        current_bound_key = user_opts.keybind
    end
end

local function update_submission_keybind()
    if current_submission_bound_key then
        mp.remove_key_binding("jumpskip_submit")
    end
    if user_opts.submission_keybind and #user_opts.submission_keybind > 0 then
        mp.add_key_binding(user_opts.submission_keybind, "jumpskip_submit", function()
            toggle_submission_overlay()
        end)
        current_submission_bound_key = user_opts.submission_keybind
    end
end

local VALID_SEGMENT_TYPES = { intro = true, recap = true, outro = true, preview = true, post_credits = true }

local autoskip_type_set     = {}
local autoskip_types_active = false

local VALID_PROVIDERS = { theintrodb = true, introdb = true, skipdb = true }

local function parse_provider_priority(priority_str)
    local providers = {}
    local seen = {}
    if not priority_str or #priority_str == 0 then
        return providers
    end
    for token in string.gmatch(priority_str, "([^,%s]+)") do
        local p = token:match("^%s*(.-)%s*$"):lower()
        if #p > 0 then
            if VALID_PROVIDERS[p] then
                if not seen[p] then
                    table.insert(providers, p)
                    seen[p] = true
                end
            else
                log_warn("Ignoring unknown provider '%s' in priority list (valid: theintrodb, introdb, skipdb)", p)
            end
        end
    end
    return providers
end

local function validate_options()
    autoskip_type_set     = {}
    autoskip_types_active = false
    for token in string.gmatch(tostring(user_opts.autoskip_types or ""), "([^,]+)") do
        local t = token:match("^%s*(.-)%s*$"):lower():gsub("%-", "_")
        if #t > 0 then
            if VALID_SEGMENT_TYPES[t] then
                autoskip_type_set[t]  = true
                autoskip_types_active = true
            else
                log_warn("Ignoring invalid autoskip_types entry '%s' (valid values: intro, recap, outro, preview, post_credits)", t)
            end
        end
    end

    local timeout = tonumber(user_opts.skip_button_timeout)
    if timeout == nil then
        log_warn("Invalid skip_button_timeout value '%s'; using 0 (button stays visible for entire segment)",
            tostring(user_opts.skip_button_timeout))
        timeout = 0
    end
    if timeout < 0 then timeout = 0 end
    user_opts.skip_button_timeout = timeout
end

local function load_configuration()
    for key, value in pairs(default_opts) do user_opts[key] = value end

    local script_dir = debug.getinfo(1, 'S').source:match("@?(.*[/\\])")
    local candidates = {}
    if script_dir then
        for _, relative in ipairs({'jumpskip.conf', '../jumpskip.conf', '../script-opts/jumpskip.conf', '../scripts-opts/jumpskip.conf'}) do
            candidates[#candidates + 1] = script_dir .. relative
        end
    end
    candidates[#candidates + 1] = './jumpskip.conf'
    candidates[#candidates + 1] = './script-opts/jumpskip.conf'

    local loaded_from = nil
    for _, path in ipairs(candidates) do
        if path then
            local f = io.open(path, "r")
            if f then
                for line in f:lines() do
                    line = line:match("^%s*(.-)%s*$")
                    if line ~= "" and not line:match("^[#;]") then
                        local k, v = line:match("^([%w_%-]+)%s*=%s*(.*)$")
                        if k and v then
                            k = k:gsub("%-", "_")
                            if user_opts[k] ~= nil then
                                if type(user_opts[k]) == "boolean" then
                                    local low = v:lower()
                                    user_opts[k] = (low == "yes" or low == "true" or low == "1" or low == "on")
                                elseif type(user_opts[k]) == "number" then
                                    local num = tonumber(v)
                                    if num then user_opts[k] = num end
                                else
                                    user_opts[k] = v
                                end
                            end
                        end
                    end
                end
                f:close()
                loaded_from = path
                break
            end
        end
    end

    options.read_options(user_opts, "jumpskip")
    if runtime_overrides.enabled ~= nil then user_opts.enabled = runtime_overrides.enabled end
    validate_options()
    update_keybind()
    update_submission_keybind()
    update_runtime_keybinds()
    log_info("Configuration active (keybind: %s, auto_skip: %s, tv_priority: %s, movie_priority: %s)%s",
        tostring(user_opts.keybind), tostring(user_opts.auto_skip),
        tostring(user_opts.provider_priority_tvshow), tostring(user_opts.provider_priority_movie),
        loaded_from and (" [source: " .. loaded_from .. "]") or "")
end

local function round(v)
    return math.floor(v + 0.5)
end

local function clamp(val, min, max)
    if val < min then return min end
    if val > max then return max end
    return val
end

local function opacity_to_alpha(opacity)
    local clamped = clamp(opacity, 0.0, 1.0)
    return 255 - round(255 * clamped)
end

local function url_encode(str)
    if not str then return "" end
    return string.gsub(str, "([^%w%-%_%.%~])", function(c)
        return string.format("%%%02X", string.byte(c))
    end)
end

local TitleParser = {}

function TitleParser.max_release_year()
    local cur_year = tonumber(os.date("%Y")) or 2026
    return cur_year + 1
end

local SPECIAL_TERMS = {
    "rifftrax", "commentary", "reaction", "re edit", "re-edit",
    "behind the scenes", "featurette", "making of", "interview",
    "deleted scenes", "bonus", "short", "documentary"
}

function TitleParser.contains_special(str)
    if not str then return false end
    local low = str:lower()
    for _, term in ipairs(SPECIAL_TERMS) do
        local pat = "[%s%p]" .. term:gsub("%-", "%%-") .. "[%s%p]"
        local prefixed = " " .. low .. " "
        if prefixed:find(pat) or low:find("^" .. term:gsub("%-", "%%-") .. "[%s%p]") or low:find("[%s%p]" .. term:gsub("%-", "%%-") .. "$") or low == term then
            return true, term
        end
    end
    return false, nil
end

local function trim_title(s)
    return (s:gsub('%s+', ' '):gsub('^[%s%._%-:]+', ''):gsub('[%s%._%-:]+$', ''))
end

local function has_title(s)
    return s and s:find('[%w\128-\255]') ~= nil
end

local MEDIA_EXTENSIONS = {
    mkv=true, mp4=true, m4v=true, avi=true, mov=true, wmv=true, webm=true,
    flv=true, mpg=true, mpeg=true, ts=true, m2ts=true, mts=true, vob=true,
    ogv=true, m3u8=true, m3u=true, mpd=true, m4s=true, mp3=true, flac=true,
    ogg=true, opus=true, wav=true, m4a=true, aac=true, iso=true,
}

local function strip_media_extension(s)
    local ext = s:match('%.([%w]+)$')
    if ext and MEDIA_EXTENSIONS[ext:lower()] then return s:sub(1, -#ext - 2) end
    return s
end

local function is_url(s)
    return s:match('^%a[%w+.-]*://') ~= nil
end

local function media_basename(s, url_context)
    s = s or ''
    local encoded = url_context or is_url(s)
    if encoded then s = s:gsub('[?#].*$', '') end
    s = s:match('([^/\\]*)$') or ''
    if encoded then
        s = s:gsub('%%(%x%x)', function(hex) return string.char(tonumber(hex, 16)) end)
    end
    return s:gsub('%c', ' ')
end

local RELEASE_PATTERNS = {
    '%d%d%d[pi]', '%d%d%d%d[pi]', '[48]k', 'uhd', 'fhd', '[xh]26[45]',
    'h[ .]26[45]', 'hevc', 'avc', 'av1', 'xvid', 'divx', '10bit', '8bit',
    'blu[ ._-]*ray', '[bd]drip', 'brrip', 'web[ ._-]*dl', 'web[ ._-]*rip',
    'hdtv', 'pdtv', 'dvdrip', 'remux', 'dts', 'truehd', 'atmos', 'eac3',
    'ac3', 'aac', 'flac', 'ddp%d', 'dd%+%d',
}

local function release_start(s)
    local low, first = s:lower(), nil
    for _, pat in ipairs(RELEASE_PATTERNS) do
        local pos = low:find('%f[%w]' .. pat .. '%f[%W]')
        if pos and has_title(s:sub(1, pos - 1)) and (not first or pos < first) then first = pos end
    end
    return first
end

local function prepare_title(raw)
    local s = strip_media_extension(raw or '')
    while true do
        local group, rest = s:match('^%s*(%b[])%s*(.*)$')
        if not group or not has_title(rest) then break end
        if rest:match('^[%(%[]?%d%d%d%d[%s%p]') or rest:match('^[%(%[]?%d%d%d%d[%]%)]?$') then break end
        s = rest
    end
    local group, rest = s:match('^%s*%((.-)%)%s*[_%-]?%s*(.*)$')
    if group and (group:lower() == 'hi10' or group:lower() == 'hi10p') and has_title(rest) then s = rest end
    s = s:gsub('%b{}', function(block)
        if block:lower():match('imdb') or block:lower():match('tmdb') or block:lower():match('tvdb') then return ' ' end
        return block
    end)
    for _, pattern in ipairs({'%b[]', '%b()'}) do
        s = s:gsub(pattern, function(block)
            local inner = block:sub(2, -2)
            if (#inner >= 8 and inner:match('^%x+$')) or inner:lower():match('^imdb[%s:=_-]')
                or inner:lower():match('^[tT][mv]db[%s:=_-]') then return ' ' end
            return block
        end)
    end
    local cut = release_start(s)
    if cut then s = s:sub(1, cut - 1):gsub('[%s%._%-%[%({]+$', '') end
    for _, edition in ipairs({'extended', 'unrated', 'uncut', 'remastered', 'proper', 'repack', 'directors[ ._-]+cut'}) do
        local pos = s:lower():find('%f[%w]' .. edition .. '%f[%W]')
        if pos and s:sub(1, pos - 1):match('%d%d%d%d[%s._%-%]%)]*$') then s = s:sub(1, pos - 1); break end
    end
    return trim_title(s)
end

function TitleParser.clean_title(raw)
    local s = prepare_title(raw)
    s = s:gsub('[%._%-]', ' '):gsub('%(%s*%)', ' '):gsub('%[%s*%]', ' ')
    return trim_title(s)
end

local function parse_title_year(raw)
    local clean = TitleParser.clean_title(raw)
    local years, pos = {}, 1
    while true do
        local a, b, value = clean:find('%f[%d](%d%d%d%d)%f[%D]', pos)
        if not a then break end
        local year = tonumber(value)
        local before, after = clean:sub(1, a - 1), clean:sub(b + 1)
        local wrapped = (before:sub(-1) == '(' and after:sub(1, 1) == ')')
            or (before:sub(-1) == '[' and after:sub(1, 1) == ']')
        if year >= 1888 and year <= TitleParser.max_release_year()
            and not before:match('[%w]$') and not after:match('^[%w]') then
            years[#years + 1] = {a=a, b=b, year=year, wrapped=wrapped}
        end
        pos = b + 1
    end
    local chosen
    for _, y in ipairs(years) do
        if y.wrapped and has_title(clean:sub(1, y.a - 2)) then chosen = y end
    end
    if not chosen then
        local last = years[#years]
        if last and clean:sub(last.b + 1):match('^%s*$') and has_title(clean:sub(1, last.a - 1)) then
            chosen = last
            local prev = years[#years - 1]
            if prev and has_title(clean:sub(1, prev.a - 1)) and math.abs(prev.year - last.year) <= 1
                and prev.year ~= last.year and clean:sub(prev.b + 1, last.a - 1):match('^%s+$') then
                return clean, nil, clean, true
            end
        end
    end
    if chosen then
        local before = clean:sub(1, chosen.a - (chosen.wrapped and 2 or 1))
        return trim_title(before), chosen.year, clean, false
    end
    return clean, nil, clean, false
end

function TitleParser.parse_season_episode(str)
    if not str or #str == 0 then return nil, nil, nil, false end
    str = prepare_title(str)
    local low = str:lower()
    local sep = '[%s%._%-%[%]():]*'
    local a, b, season, episode
    for _, pat in ipairs({
        '%f[%w]s(%d%d?)' .. sep .. 'e[p]?' .. sep .. '(%d+)',
        '%f[%w](%d%d?)x(%d+)',
        '%f[%w]season' .. sep .. '(%d%d?)' .. sep .. 'episode' .. sep .. '(%d+)',
    }) do
        a, b, season, episode = low:find(pat)
        if a then break end
    end
    local missing = false
    if not a then
        for _, pat in ipairs({'%f[%w]episode' .. sep .. '(%d+)', '%f[%w]ep' .. sep .. '(%d+)', '%f[%w]e(%d+)'}) do
            a, b, episode = low:find(pat)
            if a then season, missing = '1', true; break end
        end
    end
    if not a then
        a, b, episode = low:find('[%s_]+%-[%s_]+(%d+)')
        if not a then a, b, episode = low:find('[%s._]+(0%d%d?)v?%d*$') end
        if a then
            local n = tonumber(episode)
            if n == 0 or n > 2000 or (n >= 1888 and n <= TitleParser.max_release_year()) then a = nil end
            season, missing = '1', true
        end
    end
    if not a then return nil, nil, nil, false end
    local tail = low:sub(b + 1)
    if tail:match('^v%d+') then tail = tail:gsub('^v%d+', '') end
    if tail:match('^[%w]') and not tail:match('^e%d+') then return nil, nil, nil, false end
    if tonumber(episode) > 9999 then return nil, nil, nil, false end
    local prefix = str:sub(1, a - 1):gsub('[%s%._%-%[%]():]+$', '')
    if missing then
        local title, sn = prefix:lower():match('^(.-)%s+season%s*(%d%d?)$')
        if not title then title, sn = prefix:lower():match('^(.-)[%s._]+s(%d%d?)$') end
        if title then prefix, season, missing = prefix:sub(1, #title), sn, false end
    end
    local title, year, title_with_year = parse_title_year(prefix)
    return title, tonumber(season), tonumber(episode), missing, year, title_with_year
end

function TitleParser.canonical_title(str)
    if not str then return "" end
    local s = str:lower()
    s = s:gsub("part%s+one%f[%W]", "part 1")
    s = s:gsub("part%s+two%f[%W]", "part 2")
    s = s:gsub("part%s+three%f[%W]", "part 3")
    s = s:gsub("part%s+four%f[%W]", "part 4")
    s = s:gsub("part%s+i%f[%W]", "part 1")
    s = s:gsub("part%s+ii%f[%W]", "part 2")
    s = s:gsub("part%s+iii%f[%W]", "part 3")
    s = s:gsub("part%s+iv%f[%W]", "part 4")
    s = s:gsub("%s*&%s*", " and ")
    s = s:gsub("%s*%+%s*", " plus ")
    s = s:gsub("%s*@%s*", " at ")
    s = s:gsub("%f[%w]versus%f[%W]", "vs")
    s = s:gsub("%s*vs%.%s*", " vs ")
    s = s:gsub("[%p]", " ")
    s = s:gsub("%s+", " ")
    return s:match("^%s*(.-)%s*$") or ""
end

function TitleParser.canonical_sequel(canon_str)
    if not canon_str then return "" end
    local s = canon_str:gsub("part%s+(%d+)", "%1")
    s = s:gsub("%s+", " ")
    return s:match("^%s*(.-)%s*$") or ""
end

function TitleParser.validate_series_seasons(meta_videos, media_info)
    if not media_info.is_tv then return true end
    if not media_info.season_missing then return true end
    if type(meta_videos) ~= 'table' then return false, 0 end

    local seasons_set = {}
    for _, v in ipairs(meta_videos) do
        local s = type(v) == 'table' and tonumber(v.season)
        if s and s > 0 and s == math.floor(s) then
            seasons_set[s] = true
        end
    end

    local season_count = 0
    for _ in pairs(seasons_set) do
        season_count = season_count + 1
    end

    if season_count ~= 1 then
        return false, season_count
    end

    media_info.season = next(seasons_set)
    media_info.season_missing = false
    return true, season_count
end

local function candidate_release_year(candidate)
    for _, value in ipairs({candidate.year or '', candidate.releaseInfo or ''}) do
        local year = tonumber(tostring(value):match('^(%d%d%d%d)%f[%D]'))
        if year then return year end
    end
    return tonumber(candidate.name:match('%((%d%d%d%d)%)%s*$'))
end

function TitleParser.score_movie_candidate(candidate, query_title, target_year, all_candidates)
    if type(candidate) ~= 'table' or type(candidate.name) ~= 'string' then return -99999 end

    local cand_name = candidate.name
    local cand_year = candidate_release_year(candidate)

    local query_has_special = TitleParser.contains_special(query_title)
    local cand_has_special = TitleParser.contains_special(cand_name)
    local cand_is_doc_or_short = false
    if type(candidate.genres) == 'table' then
        for _, g in ipairs(candidate.genres) do
            local gl = tostring(g):lower()
            if gl == "short" or gl == "documentary" then cand_is_doc_or_short = true end
        end
    end

    local exact_title = TitleParser.canonical_title(query_title) == TitleParser.canonical_title(cand_name)
    if not exact_title and not query_has_special and (cand_has_special or cand_is_doc_or_short) then
        return -99999
    end

    if target_year and cand_year and math.abs(cand_year - target_year) > 1 then return -99999 end

    local q_canon = TitleParser.canonical_title(query_title)
    local c_canon = TitleParser.canonical_title(cand_name)
    if q_canon == '' or c_canon == '' then return -99999 end
    local q_seq = TitleParser.canonical_sequel(q_canon)
    local c_seq = TitleParser.canonical_sequel(c_canon)

    local function strip_articles(s)
        return (s or ""):gsub("^the%s+", ""):gsub("^a%s+", ""):gsub("^an%s+", "")
    end

    local q_clean = strip_articles(q_canon)
    local c_clean = strip_articles(c_canon)

    for c_num in c_seq:gmatch("%f[%w](%d+)%f[%W]") do
        local n = tonumber(c_num)
        if n and n > 1 and n < 1900 then
            local q_has_num = q_seq:find("%f[%w]" .. c_num .. "%f[%W]") ~= nil
            if not q_has_num then
                return -99999
            end
        end
    end

    for q_num in q_seq:gmatch("%f[%w](%d+)%f[%W]") do
        local n = tonumber(q_num)
        if n and n > 1 and n < 1900 and not c_seq:find('%f[%w]' .. q_num .. '%f[%W]') then
            return -99999
        end
    end

    if target_year then
        c_canon = c_canon:gsub("%s+" .. tostring(target_year) .. "$", "")
        c_clean = c_clean:gsub("%s+" .. tostring(target_year) .. "$", "")
        c_seq   = c_seq:gsub("%s+" .. tostring(target_year) .. "$", "")
    end

    local score = 0

    if exact_title or q_canon == c_canon or q_seq == c_seq or q_clean == c_clean then
        score = 1000
    elseif c_canon:find("^" .. q_canon .. "%s+part%s+%d+") or c_clean:find("^" .. q_clean .. "%s+part%s+%d+") then
        if target_year and cand_year and math.abs(cand_year - target_year) <= 1 then
            score = 950
        else
            score = 400
        end
    elseif q_canon:find("^" .. c_canon .. "%s+part%s+%d+") or q_clean:find("^" .. c_clean .. "%s+part%s+%d+") then
        score = 800
    else
        local q_words = {}
        for w in q_canon:gmatch("%S+") do
            if w ~= "the" and w ~= "a" and w ~= "an" then q_words[w] = true end
        end
        local c_words = {}
        local c_extra_words = 0
        for w in c_canon:gmatch("%S+") do
            if w ~= "the" and w ~= "a" and w ~= "an" then
                c_words[w] = true
                if not q_words[w] and w ~= "part" and not tonumber(w) then
                    c_extra_words = c_extra_words + 1
                end
            end
        end
        local match_count = 0
        local total_q = 0
        for w in pairs(q_words) do
            total_q = total_q + 1
            if c_words[w] then match_count = match_count + 1 end
        end
        if total_q > 0 and match_count == total_q and c_extra_words == 0 then
            score = 800
        else
            score = 0
        end
    end

    if score > 0 and target_year and cand_year then
        local diff = math.abs(cand_year - target_year)
        if diff == 0 then
            score = score + 200
        elseif diff == 1 then
            score = score + 100
        end
    end

    if score > 0 and query_has_special and cand_has_special then
        score = score + 500
    end

    return score
end

function TitleParser.score_series_candidate(candidate, query_title, target_year_or_candidates, all_candidates)
    if type(candidate) ~= 'table' or type(candidate.name) ~= 'string' then return -99999 end

    local target_year = nil
    if type(target_year_or_candidates) == "number" then
        target_year = target_year_or_candidates
    elseif type(target_year_or_candidates) == "table" and not all_candidates then
        all_candidates = target_year_or_candidates
    end

    local q_canon = TitleParser.canonical_title(query_title)
    local c_canon = TitleParser.canonical_title(candidate.name)
    if q_canon == '' or c_canon == '' then return -99999 end

    local function strip_articles(s)
        return (s or ""):gsub("^the%s+", ""):gsub("^a%s+", ""):gsub("^an%s+", "")
    end
    local q_clean = strip_articles(q_canon)
    local c_clean = strip_articles(c_canon)

    local cand_year = candidate_release_year(candidate)

    local score = 0
    if q_canon == c_canon or q_clean == c_clean then
        score = 1000
    else
        local q_words = {}
        for w in q_clean:gmatch("%S+") do q_words[w] = true end
        local c_words = {}
        local c_extra = 0
        for w in c_clean:gmatch("%S+") do
            c_words[w] = true
            if not q_words[w] then c_extra = c_extra + 1 end
        end

        local match_count = 0
        local total_q = 0
        for w in pairs(q_words) do
            total_q = total_q + 1
            if c_words[w] then match_count = match_count + 1 end
        end

        local word_match_bonus = match_count * 10

        if total_q > 0 and match_count == total_q and c_extra == 0 then
            score = 800 + word_match_bonus
        elseif total_q > 0 and match_count == total_q and c_extra <= 1 then
            score = 400 + word_match_bonus
        elseif match_count > 0 then
            score = word_match_bonus
        else
            score = 0
        end
    end

    if score > 0 and target_year and cand_year then
        local diff = math.abs(cand_year - target_year)
        if diff <= 1 then
            score = score + 200
        elseif diff > 1 then
            return -99999
        end
    end

    return score
end

local function generic_media_name(s, remote)
    local base = strip_media_extension(s):lower()
    local generic = {index=true, master=true, playlist=true, stream=true, video=true,
        audio=true, media=true, live=true, manifest=true, init=true, videoplayback=true}
    if base == '' or generic[base] then return true end
    if base:match('^seg%-%d+$') or base:match('^segment%-%d+$') or base:match('^chunk%-%d+$') then return true end
    if remote and ((#base >= 16 and base:match('^%x+$')) or base:match('^%x+%-%x+%-%x+%-%x+%-%x+$')) then return true end
    return not has_title(base)
end

local function integer(value, minimum)
    local n = tonumber(value)
    if n and n >= minimum and n <= 999999999 and n == math.floor(n) then return n end
end

local function imdb_id(value)
    local id = tostring(value or ''):lower():match('%f[%w](tt%d+)%f[%W]')
    if id and #id >= 9 then return id end
end

function TitleParser.extract_media_metadata(path, filename, raw_media_title, metadata)
    path, filename, raw_media_title = path or '', filename or '', raw_media_title or ''
    local tags = {}
    for k, v in pairs(metadata or {}) do
        local key = tostring(k):lower():gsub('[%s_-]', '')
        if type(v) == 'string' or type(v) == 'number' then tags[key] = tostring(v) end
    end
    local function tag(...)
        for _, key in ipairs({...}) do if tags[key] and tags[key]:match('%S') then return tags[key] end end
    end
    local info = {is_tv=false, season_missing=false, year_ambiguous=false}
    info.imdb_id = imdb_id(tag('imdbid', 'imdb'))
    for _, provider in ipairs({'tmdb', 'tvdb'}) do
        local value = tag(provider .. 'id', provider)
        info[provider .. '_id'] = value and integer(value:match('%d+'), 1) or nil
    end
    local meta_season = integer(tag('seasonnumber', 'season', 'tvsn'), 0)
    local meta_episode = integer(tag('episodenumber', 'episodesort', 'episode', 'episodeid', 'tves'), 0)
    local show = tag('show', 'tvshow', 'series', 'seriestitle')
    local remote = is_url(path) or is_url(filename)
    local source_name = filename ~= '' and filename or path
    local fn = ''
    if not source_name:match('^av://') and not source_name:match('^lavfi:') then
        fn = media_basename(source_name, remote)
    end
    local extension = fn:lower():match('%.([%w]+)$')
    local manifest = extension == 'm3u8' or extension == 'm3u' or extension == 'mpd'
    local texts = {fn, path, raw_media_title}
    for _, value in ipairs(texts) do
        value = value:lower()
        info.imdb_id = info.imdb_id or imdb_id(value)
        for _, provider in ipairs({'tmdb', 'tvdb'}) do
            local id = value:match('%f[%w]' .. provider .. 'id[%s:=_-]+(%d+)%f[%W]')
                or value:match('%f[%w]' .. provider .. '[%s:=_-]+(%d+)%f[%W]')
            info[provider .. '_id'] = info[provider .. '_id'] or integer(id, 1)
        end
    end
    local function parse_source(value, basename)
        if not value or value == '' or value:match('^av://') or value:match('^lavfi:') then return nil end
        if basename or is_url(value) then value = media_basename(value, remote or is_url(value)) end
        if generic_media_name(value, remote) then return nil end
        local title, season, episode, missing, year, full = TitleParser.parse_season_episode(value)
        if title ~= nil then
            return {title=title, season=season, episode=episode, season_missing=missing,
                year=year, title_with_year=full, is_tv=true, year_ambiguous=false}
        end
        local ambiguous
        title, year, full, ambiguous = parse_title_year(value)
        if not has_title(title) then return nil end
        return {title=title, year=year, title_with_year=full, is_tv=false,
            season_missing=false, year_ambiguous=ambiguous}
    end
    local file_info = parse_source(fn)
    local raw_info = parse_source(raw_media_title)
    local tag_info = parse_source(tag('title'))
    local chosen = file_info or (raw_info and raw_info.is_tv and raw_info) or tag_info or raw_info
    if remote or manifest then
        local display_is_filename = raw_media_title == path or media_basename(raw_media_title, remote) == fn
        local stream_title = (not display_is_filename and raw_info) or tag_info
        if tag_info and tag_info.is_tv and (not stream_title or not stream_title.is_tv) then
            stream_title = tag_info
        end
        if stream_title and (manifest or not file_info or not file_info.is_tv or stream_title.is_tv) then
            chosen = stream_title
        end
    end
    if chosen then for k, v in pairs(chosen) do info[k] = v end end
    if show then
        local show_title, show_year, full = parse_title_year(show)
        if has_title(show_title) then
            info.title, info.year, info.title_with_year = show_title, show_year, full
            info.is_tv, info.year_ambiguous = true, false
        end
    end
    local episode_info = chosen and chosen.is_tv and chosen
        or (not manifest and file_info and file_info.is_tv and file_info)
    if episode_info then
        info.season, info.episode, info.season_missing = episode_info.season, episode_info.episode, episode_info.season_missing
        info.is_tv = true
    end
    if meta_season ~= nil then info.season, info.season_missing, info.is_tv = meta_season, false, true end
    if meta_episode ~= nil then info.episode, info.is_tv = meta_episode, true end
    if info.is_tv and not info.season then info.season, info.season_missing = 1, true end

    if not remote and path ~= '' then
        local dir = path:gsub('\\', '/'):match('^(.*)/[^/]*$') or ''
        local parent = dir:match('([^/]+)$') or ''
        local parent_season = parent:lower():match('^season[%s._%-]*(%d+)$') or parent:lower():match('^s(%d+)$')
        if parent:lower() == 'specials' then parent_season = '0' end
        if parent_season and not info.is_tv then
            local stem = strip_media_extension(fn)
            local ep = stem:match('^(%d+)$') or stem:match('^(%d+)%s+%-%s+')
            if ep and tonumber(ep) < 1888 then
                info.title, info.is_tv, info.episode = nil, true, tonumber(ep)
                info.season, info.season_missing = tonumber(parent_season), false
            end
        end
        if info.is_tv and info.season_missing and parent_season then
            info.season, info.season_missing = tonumber(parent_season), false
        end
        if info.is_tv and not has_title(info.title) then
            if parent_season then parent = dir:match('([^/]+)/[^/]+$') or '' end
            local folder = parse_source(parent)
            if folder then info.title, info.year, info.title_with_year = folder.title, folder.year, folder.title_with_year end
        end
    end
    local date = tag('year')
    if not info.is_tv then date = date or tag('date', 'releasedate', 'originaldate') end
    local year = date and tonumber(date:match('^(%d%d%d%d)%f[%D]'))
    if year and year >= 1888 and year <= TitleParser.max_release_year() then info.year, info.year_ambiguous = year, false end
    if not has_title(info.title) then info.title = nil end
    return info
end

local function clean_title(raw)
    return TitleParser.clean_title(raw)
end

_G.TitleParser = TitleParser

local function format_hms(sec)
    if type(sec) ~= "number" or sec ~= sec or sec == math.huge or sec < 0 then
        sec = 0
    end
    local total   = math.floor(sec)
    local hours   = math.floor(total / 3600)
    local minutes = math.floor((total % 3600) / 60)
    local seconds = total % 60
    return string.format("%d:%02d:%02d", hours, minutes, seconds)
end

local function make_segment(seg_type, label, start_sec, end_sec, provider)
    return {
        type      = seg_type,
        label     = label,
        start_sec = math.max(0, start_sec + user_opts.start_offset),
        end_sec   = end_sec + user_opts.end_offset,
        provider  = provider,
        skipped   = false,
    }
end

local function parse_keywords(keyword_str)
    local keywords = {}
    if not keyword_str or #keyword_str == 0 then return keywords end
    for kw in string.gmatch(keyword_str, "([^,]+)") do
        local trimmed = kw:match("^%s*(.-)%s*$")
        if trimmed and #trimmed > 0 then
            table.insert(keywords, trimmed:lower())
        end
    end
    return keywords
end

local function normalize_chapter_title(title)
    local normalized = title:lower():gsub("[%p]", " "):gsub("%s+", " ")
    return normalized:match("^%s*(.-)%s*$") or ""
end

local function chapter_matches_keywords(chapter_title, keywords)
    if not chapter_title or #chapter_title == 0 then return false end
    local normalized = normalize_chapter_title(chapter_title)
    for _, kw in ipairs(keywords) do
        local keyword = normalize_chapter_title(kw)
        if #keyword > 0 then
            if #keyword <= 3 then
                if normalized == keyword or (normalized:sub(1, #keyword) == keyword
                    and normalized:sub(#keyword + 1):match("^ ?%d+$")) then
                    return true
                end
            elseif (" " .. normalized .. " "):find(" " .. keyword .. " ", 1, true) then
                return true
            end
        end
    end
    return false
end

local function check_overlap(chapter_start, chapter_end, existing_segments, threshold)
    threshold = threshold or user_opts.chapter_skip_overlap_threshold
    local chapter_duration = chapter_end - chapter_start
    if chapter_duration <= 0 then return true end
    
    for _, seg in ipairs(existing_segments) do
        local overlap_start = math.max(chapter_start, seg.start_sec)
        local overlap_end = math.min(chapter_end, seg.end_sec)
        local overlap_duration = math.max(0, overlap_end - overlap_start)
        local overlap_ratio = overlap_duration / chapter_duration
        if overlap_ratio >= threshold then
            return true, overlap_ratio
        end
    end
    return false, 0
end

local function detect_chapter_segments(chapters, duration, existing_segments, media_info)
    local detected = {}
    if not chapters or type(chapters) ~= "table" or #chapters == 0 then
        log_debug("chapter-skip: no chapters")
        return detected
    end
    if not duration or duration <= 0 then
        log_debug("chapter-skip: invalid duration")
        return detected
    end

    local keyword_lists = {
        intro    = parse_keywords(user_opts.chapter_skip_keywords_intro),
        outro    = parse_keywords(user_opts.chapter_skip_keywords_outro),
        recap    = parse_keywords(user_opts.chapter_skip_keywords_recap),
        preview  = parse_keywords(user_opts.chapter_skip_keywords_preview),
    }

    local category_enabled = {
        intro   = user_opts.chapter_skip_intro,
        outro   = user_opts.chapter_skip_outro,
        recap   = user_opts.chapter_skip_recap,
        preview = user_opts.chapter_skip_preview,
    }

    local sorted_chapters = {}
    for _, ch in ipairs(chapters) do
        if ch and ch.time then
            table.insert(sorted_chapters, {
                time  = tonumber(ch.time) or 0,
                title = ch.title or "",
            })
        end
    end
    table.sort(sorted_chapters, function(a, b) return a.time < b.time end)

    if #sorted_chapters == 0 then return detected end

    local min_dur = user_opts.chapter_skip_min_duration
    local max_dur = user_opts.chapter_skip_max_duration

    for i, ch in ipairs(sorted_chapters) do
        local start_time = ch.time
        local end_time = (i < #sorted_chapters) and sorted_chapters[i + 1].time or duration
        local chapter_duration = end_time - start_time

        local matched = false
        for cat, keywords in pairs(keyword_lists) do
            if category_enabled[cat] and chapter_matches_keywords(ch.title, keywords) then
                matched = true
                if chapter_duration < min_dur or chapter_duration > max_dur then
                    log_debug("chapter-skip: '%s' matches %s but ignored (dur %.1fs out of bounds)", ch.title, cat, chapter_duration)
                    break
                end
                local overlaps, ratio = check_overlap(start_time, end_time, existing_segments)
                if overlaps then
                    log_debug("chapter-skip: '%s' matches %s but overlaps provider (%.0f%%)", ch.title, cat, ratio * 100)
                else
                    local label = cat:gsub("^%l", string.upper)
                    if cat == "outro" and media_info and not media_info.is_tv then
                        label = "Credits"
                    end
                    table.insert(detected, make_segment(cat, label, start_time, end_time, "Chapters"))
                    log_info("Detected %s segment from chapter: '%s' at %.2fs-%.2fs",
                        cat, ch.title, start_time, end_time)
                end
                break
            end
        end
        if not matched then
            log_debug("chapter-skip: no match for '%s'", ch.title)
        end
    end

    return detected
end

local function build_auth_header(key, header_prefix)
    if key and #key > 0 then
        return { header_prefix .. key }
    end
    return {}
end

local state = {
    file_id              = 0,
    path                 = nil,
    filename             = nil,
    duration             = 0,
    media_info           = nil,
    segments             = {},
    segments_loaded      = false,
    query_in_progress    = false,
    active_segment       = nil,
    button_visible       = false,
    mouse_hover          = false,
    mbtn_bound           = false,
    auto_skip_timer      = nil,
    auto_skip_target_time = nil,
    button_timeout_timer = nil,
    last_time            = nil,
    display_w            = 1920,
    display_h            = 1080,
    box                  = { x1 = 0, y1 = 0, x2 = 0, y2 = 0 },
    overlay              = nil,
    submission_overlay   = nil,
    submission_visible   = false,
    submission_data      = {
        segment_type = "intro",
        start_sec = nil,
        end_sec = nil,
        status = "",
        status_color = "FFFFFF",
        submitting = false,
    },
    submission_selected_field = "segment_type",
    submission_keybinds_active = false,
    submission_status_timer = nil,
    submission_buttons = {},
    submission_hover = nil,
    submission_mbtn_bound = false,
}

-- Only completed playlist lookups survive a file change. Playback state and
-- chapter data always belong to the currently loaded file.
local playlist_prefetch = {cache = {}}

local function copy_table(value)
    if type(value) ~= 'table' then return value end
    local copy = {}
    for key, item in pairs(value) do copy[key] = copy_table(item) end
    return copy
end

local function cancel_requests(context)
    if not context then return end
    context.cancelled = true
    local requests = context.requests or {}
    context.requests = {}
    for id in pairs(requests) do
        if mp.abort_async_command then pcall(mp.abort_async_command, id) end
    end
end

function playlist_prefetch.stop(keep_progress)
    if playlist_prefetch.timer then playlist_prefetch.timer:kill() end
    playlist_prefetch.timer = nil
    cancel_requests(playlist_prefetch.active)
    playlist_prefetch.active = nil
    if not keep_progress then
        playlist_prefetch.progress_key, playlist_prefetch.progress_complete = nil, false
    end
end

local function extract_media_metadata()
    local path            = mp.get_property("path") or ""
    local filename        = mp.get_property("filename") or ""
    local raw_media_title = mp.get_property("media-title") or ""
    local metadata        = mp.get_property_native("metadata") or {}

    local info = TitleParser.extract_media_metadata(path, filename, raw_media_title, metadata)

    log_debug("Media parsed: title='%s', is_tv=%s, S=%s, E=%s, Year=%s, imdb=%s, tmdb=%s, tvdb=%s",
        tostring(info.title), tostring(info.is_tv), tostring(info.season), tostring(info.episode),
        tostring(info.year), tostring(info.imdb_id), tostring(info.tmdb_id), tostring(info.tvdb_id))

    return info
end

local function redact_http_secrets(value)
    return tostring(value or ''):gsub('([?&]([^=&#]+)=)([^&#%s]*)', function(prefix, key, secret)
        local normalized = key:lower():gsub('[_%-]', '')
        if normalized == 'apikey' or normalized == 'token' or normalized == 'accesstoken' then
            return prefix .. '[redacted]'
        end
        return prefix .. secret
    end)
end

local function async_http_request(method, url, headers, data, timeout_sec, callback, context)
    if context and context.cancelled then return end
    local json_data
    if method == 'POST' then
        local err
        json_data, err = utils.format_json(data)
        if not json_data then callback(false, nil, 'JSON encoding failed: ' .. tostring(err), 0); return end
    end
    local body_file = os.tmpname()
    local args = {
        'curl', '-s', '-S', '--max-time', tostring(timeout_sec or user_opts.request_timeout),
        '--connect-timeout', '4', '-H', 'User-Agent: mpv-skip-segment/1.0',
        '-H', 'Accept: application/json', '-w', '%{http_code}', '-o', body_file,
    }
    if method == 'POST' then
        for _, arg in ipairs({'-H', 'Content-Type: application/json', '-X', 'POST', '--data-binary', json_data}) do
            args[#args + 1] = arg
        end
    end
    for _, header in ipairs(headers or {}) do
        args[#args + 1], args[#args + 2] = '-H', header
    end
    args[#args + 1] = url
    log_request(context, 'debug', 'HTTP %s: %s', method, redact_http_secrets(url))

    local completed_once, request_id = false, nil
    local function completed(success, res, err)
        if completed_once then return end
        completed_once = true
        if context and request_id then context.requests[request_id] = nil end
        local code = tonumber(res and res.stdout and res.stdout:match('(%d%d%d)%s*$')) or 0
        local body = ''
        local f = io.open(body_file, 'rb')
        if f then body = f:read('*a') or ''; f:close() end
        os.remove(body_file)
        if context and context.cancelled then return end
        if not success or not res or res.status ~= 0 then
            local message = res and ('curl error (exit code ' .. tostring(res.status) .. '): ' .. (res.stderr or ''))
                or err or 'curl execution failed'
            callback(false, nil, redact_http_secrets(message), code)
            return
        end
        local parsed, parse_err = utils.parse_json(body)
        if code < 200 or code >= 300 then
            local detail = type(parsed) == 'table' and (parsed.error or parsed.message) or nil
            callback(false, parsed, 'HTTP ' .. code .. (detail and (': ' .. tostring(detail)) or ''), code)
        elseif code == 204 and not body:match('%S') then
            callback(true, {}, nil, code)
        elseif parse_err or type(parsed) ~= 'table' then
            callback(false, nil, 'invalid JSON response: ' .. tostring(parse_err or 'expected an object or array'), code)
        else
            callback(true, parsed, nil, code)
        end
    end
    local ok, launched_id = pcall(mp.command_native_async, {
        name='subprocess', args=args, capture_stdout=true, capture_stderr=true, playback_only=false,
    }, completed)
    request_id = launched_id
    if not ok then
        os.remove(body_file)
        if completed_once then error(request_id) end
        completed_once = true
        callback(false, nil, redact_http_secrets(request_id), 0)
    elseif context and not completed_once then
        context.requests = context.requests or {}
        context.requests[request_id] = true
    end
    return ok and request_id or nil
end

local function async_http_get(url, headers, timeout_sec, callback, context)
    return async_http_request('GET', url, headers, nil, timeout_sec, callback, context)
end

local function async_http_post(url, headers, data, timeout_sec, callback)
    return async_http_request('POST', url, headers, data, timeout_sec, callback)
end

local function resolve_title_to_imdb(media_info, current_file_id, callback, context)
    local function request(url, done)
        async_http_get(url, nil, 6, function(ok, data)
            if state.file_id ~= current_file_id or (context and context.cancelled) then return end
            done(ok and type(data) == 'table', type(data) == 'table' and data or nil)
        end, context)
    end
    local function has_id()
        return media_info.imdb_id ~= nil or media_info.tmdb_id ~= nil or media_info.tvdb_id ~= nil
    end
    local function finish_existing()
        callback(has_id() and not media_info.season_missing)
    end
    local function validate_cinemeta_season(id, done)
        if not media_info.is_tv or not media_info.season_missing then done(true); return end
        request('https://v3-cinemeta.strem.io/meta/series/' .. id .. '.json', function(ok, data)
            local valid = ok and data and type(data.meta) == 'table'
                and TitleParser.validate_series_seasons(data.meta.videos, media_info)
            if not valid then log_request(context, 'info', "Could not establish a unique season for '%s'", media_info.title or id) end
            done(valid == true)
        end)
    end
    if media_info.imdb_id then
        validate_cinemeta_season(media_info.imdb_id, callback)
        return
    end
    if media_info.year_ambiguous then
        log_request(context, 'info', 'Filename contains conflicting years; rejecting title resolution')
        callback(false)
        return
    end
    local function pick_best(candidates, query, year)
        local best, best_score = nil, 0
        for rank, candidate in ipairs(candidates) do
            local score
            if media_info.is_tv then score = TitleParser.score_series_candidate(candidate, query, year, candidates)
            else score = TitleParser.score_movie_candidate(candidate, query, year, candidates) end
            score = score - (rank - 1) * 0.5
            log_request(context, 'debug', "Title candidate #%d '%s' score=%.1f", rank, type(candidate) == 'table' and candidate.name or '', score)
            if score > best_score then best, best_score = candidate, score end
        end
        if best_score >= 300 then return best, best_score end
    end
    local queries = {{title=media_info.title, year=media_info.year}}
    if media_info.title_with_year and media_info.title_with_year ~= media_info.title then
        queries[#queries + 1] = {title=media_info.title_with_year}
    end
    local function accept_query(query)
        media_info.title, media_info.year = query.title, query.year
    end
    local function search_cinemeta(index)
        index = index or 1
        local query = queries[index]
        if not query or not has_title(query.title) then finish_existing(); return end
        local kind = media_info.is_tv and 'series' or 'movie'
        local url = string.format('https://v3-cinemeta.strem.io/catalog/%s/top/search=%s.json', kind, url_encode(query.title))
        request(url, function(ok, data)
            local candidates = ok and data and type(data.metas) == 'table' and data.metas or {}
            local best, score = pick_best(candidates, query.title, query.year)
            local id = best and imdb_id(best.imdb_id or best.id)
            if not id then search_cinemeta(index + 1); return end
            validate_cinemeta_season(id, function(valid)
                if not valid then callback(false); return end
                media_info.imdb_id = id
                accept_query(query)
                log_request(context, 'info', "Resolved '%s' to IMDb ID %s via Cinemeta (score=%.1f)", media_info.title, id, score)
                callback(true)
            end)
        end)
    end
    if not user_opts.tmdb_api_key or user_opts.tmdb_api_key == '' then search_cinemeta(); return end
    local kind = media_info.is_tv and 'tv' or 'movie'
    local api_key = url_encode(user_opts.tmdb_api_key)
    local function on_tmdb_match(id, query)
        local function fetch_external_ids()
            media_info.tmdb_id = id
            if query then accept_query(query) end
            local url = string.format('https://api.themoviedb.org/3/%s/%d/external_ids?api_key=%s', kind, id, api_key)
            request(url, function(ok, data)
                if ok and data then
                    media_info.imdb_id = imdb_id(data.imdb_id)
                    media_info.tvdb_id = media_info.tvdb_id or integer(data.tvdb_id, 1)
                end
                log_request(context, 'info', "Resolved '%s' to TMDb ID %d", media_info.title or '?', id)
                callback(true)
            end)
        end
        if not media_info.is_tv or not media_info.season_missing then fetch_external_ids(); return end
        request(string.format('https://api.themoviedb.org/3/tv/%d?api_key=%s', id, api_key), function(ok, data)
            if not ok or not data or tonumber(data.number_of_seasons) ~= 1 then
                log_request(context, 'info', "Could not establish a unique season for '%s'", media_info.title or '?')
                callback(false)
                return
            end
            local seasons = data.seasons
            if type(seasons) == 'table' then
                local videos = {}
                for _, season in ipairs(seasons) do
                    if type(season) == 'table' then videos[#videos + 1] = {season=season.season_number} end
                end
                if not TitleParser.validate_series_seasons(videos, media_info) then callback(false); return end
            else
                media_info.season, media_info.season_missing = 1, false
            end
            fetch_external_ids()
        end)
    end
    if media_info.tmdb_id then on_tmdb_match(media_info.tmdb_id); return end
    local function search_tmdb(index, no_year)
        index = index or 1
        local query = queries[index]
        if not query or not has_title(query.title) then search_cinemeta(); return end
        local url = string.format('https://api.themoviedb.org/3/search/%s?api_key=%s&query=%s', kind, api_key, url_encode(query.title))
        if query.year and not no_year then
            url = url .. (media_info.is_tv and '&first_air_date_year=' or '&primary_release_year=') .. query.year
        end
        request(url, function(ok, data)
            local candidates = {}
            for _, result in ipairs(ok and data and type(data.results) == 'table' and data.results or {}) do
                if type(result) == 'table' and integer(result.id, 1) then
                    local date = tostring(result.release_date or result.first_air_date or '')
                    candidates[#candidates + 1] = {id=result.id, name=result.title or result.name,
                        year=tonumber(date:match('^(%d%d%d%d)'))}
                end
            end
            local best = pick_best(candidates, query.title, query.year)
            if best then on_tmdb_match(best.id, query)
            elseif query.year and not no_year then search_tmdb(index, true)
            else search_tmdb(index + 1) end
        end)
    end
    search_tmdb()
end

local function query_theintrodb(media_info, current_file_id, callback, context)
    local duration = context and context.duration or state.duration
    if not media_info.tvdb_id and not media_info.tmdb_id and not media_info.imdb_id then
        callback(false, nil, "Missing ID (tvdb_id, tmdb_id, or imdb_id)")
        return
    end

    if media_info.is_tv and (media_info.season_missing or not media_info.season or not media_info.episode) then
        callback(false, nil, "TheIntroDB requires season and episode for TV shows")
        return
    end

    local params = {}
    if media_info.tvdb_id then
        table.insert(params, "tvdb_id=" .. tostring(media_info.tvdb_id))
    elseif media_info.tmdb_id then
        table.insert(params, "tmdb_id=" .. tostring(media_info.tmdb_id))
    elseif media_info.imdb_id then
        table.insert(params, "imdb_id=" .. tostring(media_info.imdb_id))
    end
    if media_info.is_tv then
        table.insert(params, "season="  .. tostring(media_info.season))
        table.insert(params, "episode=" .. tostring(media_info.episode))
    end
    if duration and duration > 0 then
        table.insert(params, "duration_ms=" .. tostring(round(duration * 1000)))
    end

    local url     = "https://api.theintrodb.org/v4/media?" .. table.concat(params, "&")
    local headers = build_auth_header(user_opts.theintrodb_api_key, "Authorization: Bearer ")

    async_http_get(url, headers, user_opts.request_timeout, function(success, data, err, http_code)
        if state.file_id ~= current_file_id or (context and context.cancelled) then return end
        if http_code == 404 then
            log_request(context, 'info', "TheIntroDB returned 0 segment(s)")
            callback(true, {}, nil)
            return
        end
        if not success or not data then
            callback(false, nil, err or "TheIntroDB request failed")
            return
        end
        if data.error then
            callback(false, nil, "TheIntroDB API error: " .. tostring(data.error))
            return
        end

        local normalized = {}

        local function add_ranges(list, seg_type, label)
            if not list or type(list) ~= "table" then return end
            for _, item in ipairs(list) do
                local s_ms = item.start_ms
                local e_ms = item.end_ms
                local is_no_segment = false
                if (seg_type == "intro" or seg_type == "recap") and e_ms == 0 then
                    is_no_segment = true
                elseif (seg_type == "outro" or seg_type == "preview") and (s_ms == 0 or e_ms == 0) then
                    is_no_segment = true
                end

                if not is_no_segment then
                    local s_sec = s_ms and (s_ms / 1000.0) or 0.0
                    local e_sec = e_ms and (e_ms / 1000.0) or (duration > 0 and duration or nil)
                    if e_sec and (e_sec - s_sec) >= user_opts.min_segment_duration then
                        table.insert(normalized, make_segment(seg_type, label, s_sec, e_sec, "TheIntroDB"))
                    end
                end
            end
        end

        local outro_label = media_info.is_tv and "Outro" or "Credits"
        if user_opts.skip_intro   and user_opts.theintrodb_intro_segment   then add_ranges(data.intro,    "intro",   "Intro")       end
        if user_opts.skip_recap   and user_opts.theintrodb_recap_segment   then add_ranges(data.recap,    "recap",   "Recap")       end
        if user_opts.skip_outro   and user_opts.theintrodb_outro_segment   then add_ranges(data.credits,  "outro",   outro_label)   end
        if user_opts.skip_preview and user_opts.theintrodb_preview_segment then add_ranges(data.preview,  "preview", "Preview")     end

        log_request(context, 'info', "TheIntroDB returned %d segment(s)", #normalized)
        callback(true, normalized, nil)
    end, context)
end

local function query_introdb(media_info, current_file_id, callback, context)
    if not media_info.imdb_id then
        callback(false, nil, "IntroDB requires imdb_id")
        return
    end

    local is_movie = not media_info.is_tv
    if not is_movie and (media_info.season_missing or not media_info.season or not media_info.episode) then
        callback(false, nil, "IntroDB requires season and episode for TV shows")
        return
    end

    local url
    if is_movie then
        url = string.format("https://api.introdb.app/segments?imdb_id=%s&is_movie=true",
            media_info.imdb_id)
    else
        url = string.format("https://api.introdb.app/segments?imdb_id=%s&season=%d&episode=%d",
            media_info.imdb_id, media_info.season, media_info.episode)
    end
    local headers = build_auth_header(user_opts.introdb_api_key, "X-API-Key: ")

    async_http_get(url, headers, user_opts.request_timeout, function(success, data, err)
        if state.file_id ~= current_file_id or (context and context.cancelled) then return end
        if not success or not data then
            callback(false, nil, err or "IntroDB request failed")
            return
        end
        if data.error then
            callback(false, nil, "IntroDB API error: " .. tostring(data.error))
            return
        end

        local normalized = {}

        local function add_segment(item, seg_type, label)
            if not item or type(item) ~= "table" then return end
            local s_sec = item.start_sec or (item.start_ms and (item.start_ms / 1000.0)) or 0.0
            local e_sec = item.end_sec   or (item.end_ms   and (item.end_ms   / 1000.0)) or nil
            if e_sec and (e_sec - s_sec) >= user_opts.min_segment_duration then
                table.insert(normalized, make_segment(seg_type, label, s_sec, e_sec, "IntroDB"))
            end
        end

        if user_opts.skip_intro then add_segment(data.intro,  "intro",  "Intro")  end
        if user_opts.skip_recap then add_segment(data.recap,  "recap",  "Recap")  end
        if user_opts.skip_outro then
            add_segment(data.outro, "outro", is_movie and "Credits" or "Outro")
        end
        if user_opts.skip_post_credits then
            add_segment(data.post_credits, "post_credits", "Post-Credits")
        end

        log_request(context, 'info', "IntroDB returned %d segment(s)", #normalized)
        callback(true, normalized, nil)
    end, context)
end

local function query_skipdb(media_info, current_file_id, callback, context)
    local duration = context and context.duration or state.duration
    if not media_info.imdb_id then
        callback(false, nil, "SkipDB requires imdb_id")
        return
    end

    if media_info.is_tv and (media_info.season_missing or not media_info.season or not media_info.episode) then
        callback(false, nil, "SkipDB requires season and episode for TV shows")
        return
    end

    local url = "https://api.skipdb.tv/api/segments?imdb_id=" .. media_info.imdb_id
    if media_info.is_tv and media_info.season and media_info.episode then
        url = url .. "&season="  .. tostring(media_info.season)
                  .. "&episode=" .. tostring(media_info.episode)
    end
    if duration and duration > 0 then
        url = url .. "&duration=" .. tostring(math.floor(duration))
    end

    local headers = build_auth_header(user_opts.skipdb_api_key, "Authorization: Bearer ")

    async_http_get(url, headers, user_opts.request_timeout, function(success, data, err)
        if state.file_id ~= current_file_id or (context and context.cancelled) then return end
        if not success or not data then
            callback(false, nil, err or "SkipDB request failed")
            return
        end
        if data.error then
            callback(false, nil, "SkipDB API error: " .. tostring(data.error))
            return
        end

        local segs = data.segments
        if type(segs) ~= "table" then
            callback(false, nil, "SkipDB: unexpected response format")
            return
        end

        local normalized = {}

        local function add_segment(item, seg_type, label)
            if not item or type(item) ~= "table" then return end
            if item.start_ms == 0 and item.end_ms == 0 then return end
            local s_sec = (item.start_ms or 0) / 1000.0
            local e_sec = item.end_ms and (item.end_ms / 1000.0) or nil
            if e_sec and (e_sec - s_sec) >= user_opts.min_segment_duration then
                table.insert(normalized, make_segment(seg_type, label, s_sec, e_sec, "SkipDB"))
            end
        end

        if user_opts.skip_intro   then add_segment(segs.intro,   "intro",   "Intro")   end
        if user_opts.skip_recap   then add_segment(segs.recap,   "recap",   "Recap")   end
        if user_opts.skip_outro   then add_segment(segs.outro,   "outro",   "Outro")   end
        if user_opts.skip_preview then add_segment(segs.preview, "preview", "Preview") end

        log_request(context, 'info', "SkipDB returned %d segment(s)", #normalized)
        callback(true, normalized, nil)
    end, context)
end

local provider_fns = {
    theintrodb = query_theintrodb,
    introdb    = query_introdb,
    skipdb     = query_skipdb,
}

local SUBMISSION_SEGMENT_TYPES = {
    intro         = { theintrodb = "intro",    introdb = "intro",    skipdb = "intro" },
    recap         = { theintrodb = "recap",    introdb = "recap",    skipdb = "recap" },
    outro         = { theintrodb = "credits",  introdb = "outro",    skipdb = "outro" },
    preview       = { theintrodb = "preview",  introdb = nil,        skipdb = "preview" },
    post_credits  = { theintrodb = nil,        introdb = "post-credits", skipdb = nil },
}

local SEGMENT_DURATION_LIMITS = {
    intro        = { min = 5,   max = 200 },
    recap        = { min = 5,   max = 1200 },
    outro        = { min = 5,   max = 1800 },
    preview      = { min = 5,   max = 1800 },
    post_credits = { min = 5,   max = 1800 },
}

local function format_media_title(media_info)
    local title = media_info.title or "Unknown"
    if media_info.is_tv and media_info.season and media_info.episode then
        title = string.format("%s Season %d Episode %d", title, media_info.season, media_info.episode)
    end
    return title
end

local function validate_submission_data(data)
    local seg_type = data.segment_type
    local start_sec = data.start_sec
    local end_sec = data.end_sec
    
    if not seg_type or not VALID_SEGMENT_TYPES[seg_type] then
        return false, "Invalid segment type"
    end
    
    if start_sec == nil or end_sec == nil then
        return false, "Start and end times are required"
    end
    if type(start_sec) ~= 'number' or type(end_sec) ~= 'number'
        or start_sec ~= start_sec or end_sec ~= end_sec then
        return false, 'Times must be valid numbers'
    end
    
    if start_sec < 0 or end_sec < 0 then
        return false, "Times cannot be negative"
    end
    
    if start_sec >= end_sec then
        return false, "Start time must be before end time"
    end
    
    local duration = end_sec - start_sec
    local limits = SEGMENT_DURATION_LIMITS[seg_type]
    if limits then
        if duration < limits.min then
            return false, string.format("Segment too short (minimum %ds for %s)", limits.min, seg_type)
        end
        if duration > limits.max then
            return false, string.format("Segment too long (maximum %ds for %s)", limits.max, seg_type)
        end
    end
    
    if end_sec > 21600 then
        return false, "Times cannot exceed 6 hours"
    end
    
    return true, nil
end

local function interpret_submission_error(http_code, err, provider)
    if http_code and http_code > 0 then
        if http_code == 401 or http_code == 403 then
            return string.format("%s: Invalid API key (HTTP %d)", provider, http_code)
        elseif http_code == 400 or http_code == 422 then
            return string.format("%s: Validation error (HTTP %d): %s", provider, http_code, tostring(err or ""))
        elseif http_code == 409 then
            return string.format("%s: Conflict (HTTP %d): %s", provider, http_code, tostring(err or "already submitted"))
        elseif http_code == 429 then
            return string.format("%s: Rate limited (HTTP 429), retry later", provider)
        elseif http_code >= 500 then
            return string.format("%s: Server error (HTTP %d)", provider, http_code)
        else
            return string.format("%s: Submission failed (HTTP %d): %s", provider, http_code, tostring(err or ""))
        end
    end
    return string.format("%s: %s", provider, tostring(err or "submission failed"))
end

local function finish_submission(provider, success, data, err, http_code, callback)
    if success and type(data) == 'table' and data.ok ~= false and data.success ~= false and not data.error then
        callback(true, data)
    else
        local detail = type(data) == 'table' and (data.error or data.message) or nil
        callback(false, interpret_submission_error(http_code, detail or err, provider))
    end
end

local function submit_to_theintrodb(media_info, submission_data, callback)
    if not user_opts.theintrodb_submit_enabled or not user_opts.theintrodb_api_key or #user_opts.theintrodb_api_key == 0 then
        callback(false, "TheIntroDB submission disabled or no API key")
        return
    end
    
    local seg_type = SUBMISSION_SEGMENT_TYPES[submission_data.segment_type].theintrodb
    if not seg_type then
        callback(false, "Segment type not supported by TheIntroDB")
        return
    end
    
    if not media_info.tvdb_id and not media_info.tmdb_id and not media_info.imdb_id then
        callback(false, "TheIntroDB requires tvdb_id, tmdb_id, or imdb_id")
        return
    end

    if media_info.is_tv and (media_info.season_missing or not media_info.season or not media_info.episode) then
        callback(false, "TheIntroDB requires season and episode for TV shows")
        return
    end
    
    local body = {
        type = media_info.is_tv and "tv" or "movie",
        segment = seg_type,
        start_sec = submission_data.start_sec,
        end_sec = submission_data.end_sec,
    }

    if media_info.tvdb_id then
        body.tvdb_id = media_info.tvdb_id
    elseif media_info.tmdb_id then
        body.tmdb_id = media_info.tmdb_id
    elseif media_info.imdb_id then
        body.imdb_id = media_info.imdb_id
    end

    if media_info.imdb_id and not body.imdb_id then
        body.imdb_id = media_info.imdb_id
    end
    
    if media_info.is_tv then
        body.season = media_info.season
        body.episode = media_info.episode
    end
    
    if state.duration and state.duration > 0 then
        local dur_ms = round(state.duration * 1000)
        if dur_ms >= 300000 and dur_ms <= 21600000 then
            body.video_duration_ms = dur_ms
        end
    end
    
    local headers = build_auth_header(user_opts.theintrodb_api_key, "Authorization: Bearer ")
    local url = "https://api.theintrodb.org/v4/submit"
    
    async_http_post(url, headers, body, user_opts.request_timeout, function(success, data, err, http_code)
        finish_submission('TheIntroDB', success, data, err, http_code, callback)
    end)
end

local function submit_to_introdb(media_info, submission_data, callback)
    if not user_opts.introdb_submit_enabled or not user_opts.introdb_api_key or #user_opts.introdb_api_key == 0 then
        callback(false, "IntroDB submission disabled or no API key")
        return
    end
    
    local seg_type = SUBMISSION_SEGMENT_TYPES[submission_data.segment_type].introdb
    if not seg_type then
        callback(false, "Segment type not supported by IntroDB")
        return
    end
    
    if seg_type == "post-credits" and media_info.is_tv then
        callback(false, "Post-credits only supported for movies on IntroDB")
        return
    end
    
    if not media_info.imdb_id then
        callback(false, "IntroDB requires IMDb ID")
        return
    end
    
    local body = {
        segment_type = seg_type,
        imdb_id = media_info.imdb_id,
        start_sec = submission_data.start_sec,
        end_sec = submission_data.end_sec,
    }
    
    if media_info.is_tv then
        body.is_movie = false
        body.season = media_info.season
        body.episode = media_info.episode
    else
        body.is_movie = true
    end
    
    if media_info.tvdb_id then
        body.tvdb_id = media_info.tvdb_id
    end
    if media_info.tmdb_id then
        body.tmdb_id = media_info.tmdb_id
    end
    
    local headers = build_auth_header(user_opts.introdb_api_key, "X-API-Key: ")
    local url = "https://api.introdb.app/submit"
    
    async_http_post(url, headers, body, user_opts.request_timeout, function(success, data, err, http_code)
        finish_submission('IntroDB', success, data, err, http_code, callback)
    end)
end

local function submit_to_skipdb(media_info, submission_data, callback)
    if not user_opts.skipdb_submit_enabled or not user_opts.skipdb_api_key or #user_opts.skipdb_api_key == 0 then
        callback(false, "SkipDB submission disabled or no API key")
        return
    end
    
    local seg_type = SUBMISSION_SEGMENT_TYPES[submission_data.segment_type].skipdb
    if not seg_type then
        callback(false, "Segment type not supported by SkipDB")
        return
    end
    
    if not media_info.imdb_id then
        callback(false, "SkipDB requires IMDb ID")
        return
    end
    
    local body = {
        imdb_id = media_info.imdb_id,
        segment_type = seg_type,
        start_ms = round(submission_data.start_sec * 1000),
        end_ms = round(submission_data.end_sec * 1000),
        duration_ms = state.duration > 0 and round(state.duration * 1000) or nil,
    }
    
    if media_info.is_tv then
        body.season = media_info.season
        body.episode = media_info.episode
    end
    
    local headers = build_auth_header(user_opts.skipdb_api_key, "Authorization: Bearer ")
    local url = "https://api.skipdb.tv/api/segments"
    
    async_http_post(url, headers, body, user_opts.request_timeout, function(success, data, err, http_code)
        finish_submission('SkipDB', success, data, err, http_code, callback)
    end)
end

local function submit_to_all_providers(media_info, submission_data, callback)
    local results, jobs = {}, {}
    local functions = {theintrodb=submit_to_theintrodb, introdb=submit_to_introdb, skipdb=submit_to_skipdb}
    for _, name in ipairs({'theintrodb', 'introdb', 'skipdb'}) do
        if user_opts[name .. '_submit_enabled'] and (user_opts[name .. '_api_key'] or '') ~= '' then
            jobs[#jobs + 1] = {name=name, submit=functions[name]}
        end
    end
    local pending = #jobs
    if pending == 0 then callback(results); return end
    for _, job in ipairs(jobs) do
        job.submit(media_info, submission_data, function(success, data)
            if results[job.name] then return end
            results[job.name] = {success=success, data=data}
            pending = pending - 1
            if pending == 0 then callback(results) end
        end)
    end
end

local SUBMISSION_TYPE_ORDER = { "intro", "recap", "outro", "preview", "post_credits" }

local SUBMISSION_TYPE_LABELS = {
    intro        = "Intro",
    recap        = "Recap",
    outro        = "Outro",
    preview      = "Preview",
    post_credits = "Post-Credits",
}

local function format_submission_time(sec)
    if type(sec) ~= "number" or sec ~= sec or sec < 0 then
        return "--:--:--"
    end
    return format_hms(sec)
end

local function cycle_submission_segment_type()
    local order = SUBMISSION_TYPE_ORDER
    local current = state.submission_data.segment_type
    local idx = 1
    for i, t in ipairs(order) do
        if t == current then
            idx = i
            break
        end
    end
    local next_type = order[(idx % #order) + 1]
    state.submission_data.segment_type = next_type
    state.submission_data.status = ""
    state.submission_data.status_color = "FFFFFF"
    render_submission_overlay()
end

local function submission_set_start()
    local t = mp.get_property_number("time-pos")
    if t == nil then
        state.submission_data.status = "No playback position available"
        state.submission_data.status_color = "E75C6C"
    else
        state.submission_data.start_sec = t
        state.submission_data.status = ""
        state.submission_data.status_color = "FFFFFF"
    end
    render_submission_overlay()
end

local function submission_set_end()
    local t = mp.get_property_number("time-pos")
    if t == nil then
        state.submission_data.status = "No playback position available"
        state.submission_data.status_color = "E75C6C"
    else
        state.submission_data.end_sec = t
        state.submission_data.status = ""
        state.submission_data.status_color = "FFFFFF"
    end
    render_submission_overlay()
end

local function submission_submit()
    if state.submission_data.submitting then
        return
    end
    local data = state.submission_data
    local ok, err = validate_submission_data(data)
    if not ok then
        data.status = err or "Invalid submission"
        data.status_color = "E75C6C"
        render_submission_overlay()
        return
    end
    if not state.media_info then
        data.status = "No media information available"
        data.status_color = "E75C6C"
        render_submission_overlay()
        return
    end
    if state.media_info.is_tv and (state.media_info.season_missing or not state.media_info.season or not state.media_info.episode) then
        data.status = "TV show requires season and episode information"
        data.status_color = "E75C6C"
        render_submission_overlay()
        return
    end
    data.submitting = true
    data.status = "Submitting..."
    data.status_color = "FFD700"
    render_submission_overlay()
    local current_file_id = state.file_id
    submit_to_all_providers(state.media_info, data, function(results)
        if state.file_id ~= current_file_id then return end
        data.submitting = false
        local success_count = 0
        local total = 0
        local messages = {}
        for provider, res in pairs(results) do
            total = total + 1
            if res.success then
                success_count = success_count + 1
            else
                table.insert(messages, provider .. ": " .. tostring(res.data))
            end
        end
        if total == 0 then
            data.status = "No providers enabled (check API keys)"
            data.status_color = "E75C6C"
        elseif success_count == total then
            data.status = "Submitted successfully to all providers"
            data.status_color = "7CFC00"
        else
            data.status = string.format("Submitted to %d/%d providers", success_count, total)
            data.status_color = "FFA500"
            if #messages > 0 then
                data.status = data.status .. " | " .. table.concat(messages, " | ")
            end
        end
        render_submission_overlay()
        if success_count == total and total > 0 then
            if state.submission_status_timer then state.submission_status_timer:kill() end
            state.submission_status_timer = mp.add_timeout(3.0, function()
                state.submission_status_timer = nil
                if state.submission_visible then
                    data.status = ""
                    data.status_color = "FFFFFF"
                    render_submission_overlay()
                end
            end)
        end
    end)
end

close_submission_overlay = function()
    if not state.submission_visible then
        return
    end
    state.submission_visible = false
    if state.submission_status_timer then
        state.submission_status_timer:kill()
        state.submission_status_timer = nil
    end
    if state.submission_overlay then
        state.submission_overlay.data = ""
        state.submission_overlay:update()
    end
    if state.submission_keybinds_active then
        mp.remove_key_binding("jumpskip_submit_f1")
        mp.remove_key_binding("jumpskip_submit_f2")
        mp.remove_key_binding("jumpskip_submit_f")
        mp.remove_key_binding("jumpskip_submit_enter")
        mp.remove_key_binding("jumpskip_submit_esc")
        state.submission_keybinds_active = false
    end
    if state.submission_mbtn_bound then
        mp.remove_key_binding("jumpskip_submit_click")
        state.submission_mbtn_bound = false
    end
    state.submission_hover = nil
    state.submission_buttons = {}
end

local function open_submission_overlay()
    if not user_opts.enabled then
        mp.osd_message("JumpSkip is disabled", 2)
        return
    end
    if not user_opts.enable_submission then
        mp.osd_message("Segment submission is disabled", 2)
        return
    end
    if not state.media_info then
        state.media_info = extract_media_metadata()
    end
    state.submission_visible = true
    state.submission_data.status = ""
    state.submission_data.status_color = "FFFFFF"
    if not state.submission_overlay then
        state.submission_overlay = mp.create_osd_overlay("ass-events")
    end
    if not state.submission_keybinds_active then
        mp.add_forced_key_binding("F1", "jumpskip_submit_f1", submission_set_start)
        mp.add_forced_key_binding("F2", "jumpskip_submit_f2", submission_set_end)
        mp.add_forced_key_binding("f", "jumpskip_submit_f", cycle_submission_segment_type)
        mp.add_forced_key_binding("ENTER", "jumpskip_submit_enter", submission_submit)
        mp.add_forced_key_binding("ESC", "jumpskip_submit_esc", close_submission_overlay)
        state.submission_keybinds_active = true
    end
    render_submission_overlay()
end

toggle_submission_overlay = function()
    if state.submission_visible then
        close_submission_overlay()
    else
        open_submission_overlay()
    end
end

local function submission_render_button(ass, id, x1, y1, x2, y2, label, accent, hovered, selected)
    local radius = 8
    local bg_color = selected and accent or (hovered and "3A3A3A" or "1E1E1E")
    local border_color = (selected or hovered) and accent or "555555"
    local text_color = (selected or hovered) and "FFFFFF" or "DDDDDD"

    ass:new_event()
    ass:pos(x1, y1)
    ass:append(string.format("{\\an7\\bord0\\shad0\\1c&H%s&\\alpha&H00&\\p1}", bg_color))
    ass:draw_start()
    ass:round_rect_cw(0, 0, x2 - x1, y2 - y1, radius)
    ass:draw_stop()

    ass:new_event()
    ass:pos(x1, y1)
    ass:append(string.format("{\\an7\\bord0\\shad0\\1c&H%s&\\alpha&H00&\\p1}", border_color))
    ass:draw_start()
    ass:round_rect_cw(1, 1, (x2 - x1) - 1, (y2 - y1) - 1, radius)
    ass:draw_stop()

    local cx = (x1 + x2) / 2
    local cy = (y1 + y2) / 2
    ass:new_event()
    ass:pos(cx, cy)
    ass:append(string.format("{\\an5\\bord0\\shad0\\fs18\\1c&H%s&}", text_color))
    ass:append(label)

    return { id = id, x1 = x1, y1 = y1, x2 = x2, y2 = y2 }
end

render_submission_overlay = function()
    if not state.submission_visible then
        return
    end
    if not state.submission_overlay then
        state.submission_overlay = mp.create_osd_overlay("ass-events")
    end

    local w = state.display_w
    local h = state.display_h
    local ass = assdraw.ass_new()

    local box_w = 640
    local box_h = 400
    local box_x = (w - box_w) / 2
    local box_y = (h - box_h) / 2

    local bg_alpha = opacity_to_alpha(0.85)
    local border_alpha = opacity_to_alpha(0.0)

    ass:new_event()
    ass:pos(box_x, box_y)
    ass:append(string.format("{\\an7\\bord0\\shad0\\1c&H%s&\\alpha&H%s&\\p1}", "0A0A0A", bg_alpha))
    ass:draw_start()
    ass:rect_cw(0, 0, box_w, box_h)
    ass:draw_stop()

    ass:new_event()
    ass:pos(box_x, box_y)
    ass:append(string.format("{\\an7\\bord0\\shad0\\1c&H%s&\\alpha&H%s&\\p1}", "E75C6C", border_alpha))
    ass:draw_start()
    ass:rect_cw(0, 0, box_w, 3)
    ass:rect_cw(0, box_h - 3, box_w, box_h)
    ass:rect_cw(0, 0, 3, box_h)
    ass:rect_cw(box_w - 3, 0, box_w, box_h)
    ass:draw_stop()

    local margin = 24
    local cx = box_x + box_w / 2
    local y = margin

    local media_info = state.media_info
    local media_title = media_info and format_media_title(media_info) or "Unknown"
    local data = state.submission_data
    local hover = state.submission_hover

    local buttons = {}

    local close_btn = 26
    table.insert(buttons, submission_render_button(ass, "close",
        box_x + box_w - margin - close_btn, box_y + margin,
        box_x + box_w - margin, box_y + margin + close_btn,
        "✕", "E75C6C", hover == "close"))

    ass:new_event()
    ass:pos(cx, box_y + y)
    ass:append(string.format("{\\an8\\bord0\\shad0\\fs22\\1c&H%s&}", "FFFFFF"))
    ass:append(media_title)
    y = y + 30

    local id_parts = {}
    if media_info and media_info.tvdb_id then
        table.insert(id_parts, "TVDB: " .. media_info.tvdb_id)
    end
    if media_info and media_info.imdb_id then
        table.insert(id_parts, "IMDB: " .. media_info.imdb_id)
    end
    if media_info and media_info.tmdb_id then
        table.insert(id_parts, "TMDB: " .. media_info.tmdb_id)
    end
    if #id_parts > 0 then
        ass:new_event()
        ass:pos(cx, box_y + y)
        ass:append(string.format("{\\an8\\bord0\\shad0\\fs16\\1c&H%s&}", "888888"))
        ass:append(table.concat(id_parts, "    "))
        y = y + 26
    end

    ass:new_event()
    ass:pos(box_x, box_y + y)
    ass:append(string.format("{\\an7\\bord0\\shad0\\1c&H%s&\\alpha&H00&\\p1}", "333333"))
    ass:draw_start()
    ass:rect_cw(0, 0, box_w, 1)
    ass:draw_stop()
    y = y + 24

    ass:new_event()
    ass:pos(cx, box_y + y)
    ass:append(string.format("{\\an8\\bord0\\shad0\\fs18\\1c&H%s&}", "AAAAAA"))
    ass:append("Segment Type (F)")
    y = y + 34

    local seg_btn_h = 30
    local seg_gap = 10
    local seg_btn_w = 150
    local row1_types = { "intro", "recap", "outro" }
    local row1_w = #row1_types * seg_btn_w + (#row1_types - 1) * seg_gap
    local row1_x = cx - row1_w / 2
    local seg_btn_y1 = box_y + y
    local seg_btn_y2 = seg_btn_y1 + seg_btn_h
    for i, seg_type in ipairs(row1_types) do
        local seg_x1 = row1_x + (i - 1) * (seg_btn_w + seg_gap)
        local seg_x2 = seg_x1 + seg_btn_w
        local is_selected = (data.segment_type == seg_type)
        local is_hovered = (hover == ("seg_" .. seg_type))
        table.insert(buttons, submission_render_button(ass, "seg_" .. seg_type,
            seg_x1, seg_btn_y1, seg_x2, seg_btn_y2,
            SUBMISSION_TYPE_LABELS[seg_type] or seg_type,
            "E75C6C", is_hovered, is_selected))
    end
    y = y + seg_btn_h + 10

    local row2_types = { "preview", "post_credits" }
    local row2_w = #row2_types * seg_btn_w + (#row2_types - 1) * seg_gap
    local row2_x = cx - row2_w / 2
    local seg_btn_y1 = box_y + y
    local seg_btn_y2 = seg_btn_y1 + seg_btn_h
    for i, seg_type in ipairs(row2_types) do
        local seg_x1 = row2_x + (i - 1) * (seg_btn_w + seg_gap)
        local seg_x2 = seg_x1 + seg_btn_w
        local is_selected = (data.segment_type == seg_type)
        local is_hovered = (hover == ("seg_" .. seg_type))
        table.insert(buttons, submission_render_button(ass, "seg_" .. seg_type,
            seg_x1, seg_btn_y1, seg_x2, seg_btn_y2,
            SUBMISSION_TYPE_LABELS[seg_type] or seg_type,
            "E75C6C", is_hovered, is_selected))
    end
    y = y + seg_btn_h + 24

    local time_btn_w = 210
    local time_btn_h = 34
    local time_gap = 20
    local time_row_w = 2 * time_btn_w + time_gap
    local time_row_x = cx - time_row_w / 2
    local time_btn_y1 = box_y + y
    local time_btn_y2 = time_btn_y1 + time_btn_h
    table.insert(buttons, submission_render_button(ass, "set_start",
        time_row_x, time_btn_y1, time_row_x + time_btn_w, time_btn_y2,
        "Set Start Time (F1)", "4C9AFF", hover == "set_start"))
    table.insert(buttons, submission_render_button(ass, "set_end",
        time_row_x + time_btn_w + time_gap, time_btn_y1, time_row_x + 2 * time_btn_w + time_gap, time_btn_y2,
        "Set End Time (F2)", "4C9AFF", hover == "set_end"))
    y = y + time_btn_h + 8

    local start_cx = time_row_x + time_btn_w / 2
    local end_cx = time_row_x + time_btn_w + time_gap + time_btn_w / 2
    ass:new_event()
    ass:pos(start_cx, box_y + y)
    ass:append(string.format("{\\an8\\bord0\\shad0\\fs18\\1c&H%s&}", "FFFFFF"))
    ass:append(format_submission_time(data.start_sec))
    ass:new_event()
    ass:pos(end_cx, box_y + y)
    ass:append(string.format("{\\an8\\bord0\\shad0\\fs18\\1c&H%s&}", "FFFFFF"))
    ass:append(format_submission_time(data.end_sec))
    y = y + 30

    local submit_w = 200
    local submit_h = 36
    local submit_x1 = cx - submit_w / 2
    local submit_y1 = box_y + y
    table.insert(buttons, submission_render_button(ass, "submit",
        submit_x1, submit_y1, submit_x1 + submit_w, submit_y1 + submit_h,
        "Submit", "2ECC71", hover == "submit"))
    y = y + submit_h + 20

    if data.status and #data.status > 0 then
        ass:new_event()
        ass:pos(cx, box_y + y)
        ass:append(string.format("{\\an8\\bord0\\shad0\\fs16\\1c&H%s&}", data.status_color))
        ass:append(data.status)
    end

    state.submission_buttons = buttons
    state.submission_overlay.res_x = state.display_w
    state.submission_overlay.res_y = state.display_h
    state.submission_overlay.data = ass.text
    state.submission_overlay:update()
end

local function submission_handle_click()
    if not state.submission_visible then
        return
    end
    local id = state.submission_hover
    if not id then
        return
    end
    if id == "set_start" then
        submission_set_start()
    elseif id == "set_end" then
        submission_set_end()
    elseif id == "submit" then
        submission_submit()
    elseif id == "close" then
        close_submission_overlay()
    elseif id:sub(1, 4) == "seg_" then
        local seg_type = id:sub(5)
        if state.submission_data.segment_type ~= seg_type then
            state.submission_data.segment_type = seg_type
            render_submission_overlay()
        end
    end
end

local function submission_set_mbtn_binding(enable)
    if enable and not state.submission_mbtn_bound then
        mp.add_forced_key_binding("MBTN_LEFT", "jumpskip_submit_click", submission_handle_click)
        state.submission_mbtn_bound = true
    elseif not enable and state.submission_mbtn_bound then
        mp.remove_key_binding("jumpskip_submit_click")
        state.submission_mbtn_bound = false
    end
end

local function submission_handle_mouse(x, y)
    if not state.submission_visible then
        if state.submission_hover then
            state.submission_hover = nil
            submission_set_mbtn_binding(false)
        end
        return
    end

    local hovered = nil
    for _, btn in ipairs(state.submission_buttons) do
        if x >= btn.x1 and x <= btn.x2 and y >= btn.y1 and y <= btn.y2 then
            hovered = btn.id
            break
        end
    end

    if hovered ~= state.submission_hover then
        state.submission_hover = hovered
        submission_set_mbtn_binding(hovered ~= nil)
        render_submission_overlay()
    end
end

local function log_segments_summary(segments, providers_raw)
    local sep = string.rep("-", 60)
    if providers_raw and #providers_raw > 0 then
        mp.msg.info("[jumpskip] " .. sep)
        mp.msg.info("[jumpskip] SEGMENT QUERY RESULTS (per provider)")
        mp.msg.info("[jumpskip] " .. sep)
        for _, prov in ipairs(providers_raw) do
            local pname = prov.name
            local psegs = prov.segs
            if not psegs or #psegs == 0 then
                local reason = prov.err and (" (" .. prov.err .. ")") or "  (no segments)"
                mp.msg.info(string.format("[jumpskip]   %-16s%s", pname, reason))
            else
                mp.msg.info(string.format("[jumpskip]   %-16s  %d segment(s):", pname, #psegs))
                for _, s in ipairs(psegs) do
                    mp.msg.info(string.format("[jumpskip]     %-10s  %7.2fs (%s) -> %7.2fs (%s)",
                        s.label,
                        s.start_sec, format_hms(s.start_sec),
                        s.end_sec, format_hms(s.end_sec)))
                end
            end
        end
        mp.msg.info("[jumpskip] " .. sep)
    end
    if not segments or #segments == 0 then
        mp.msg.info("[jumpskip] FINAL SEGMENTS: none")
        mp.msg.info("[jumpskip] " .. sep)
        return
    end
    mp.msg.info(string.format("[jumpskip] FINAL SEGMENTS: %d total", #segments))
    mp.msg.info("[jumpskip] " .. sep)
    mp.msg.info(string.format("[jumpskip]   %-10s  %-16s  %-20s  %-20s", "Type", "Provider", "Start", "End"))
    mp.msg.info("[jumpskip] " .. string.rep("-", 74))
    for _, s in ipairs(segments) do
        mp.msg.info(string.format("[jumpskip]   %-10s  %-16s  %-20s  %-20s",
            s.label, s.provider,
            string.format("%.2fs (%s)", s.start_sec, format_hms(s.start_sec)),
            string.format("%.2fs (%s)", s.end_sec, format_hms(s.end_sec))))
    end
    mp.msg.info("[jumpskip] " .. sep)
end

local function merge_segment_lists(primary, secondary)
    local result = {}
    local primary_types = {}
    for _, s in ipairs(primary) do
        table.insert(result, s)
        primary_types[s.type] = true
    end
    for _, s in ipairs(secondary) do
        if not primary_types[s.type] then
            table.insert(result, s)
            log_info("Merged missing '%s' segment from %s into final segments list", s.label, s.provider)
        end
    end
    table.sort(result, function(a, b) return a.start_sec < b.start_sec end)
    return result
end

local function segment_marker_enabled(seg_type)
    if not user_opts.show_colored_segments then return false end
    local per_type = user_opts["show_colored_" .. tostring(seg_type) .. "_segments"]
    if per_type == nil then return true end
    return per_type
end

local function chapter_title_for_segment(seg_type)
    local title = tostring(seg_type):gsub("_", " "):gsub("^%l", string.upper)
    if seg_type == "outro" then
        local mi = state.media_info
        if mi and not mi.is_tv then
            title = "Credits"
        end
    end
    return title
end

local function build_marked_chapters(base_chapters, segments, duration, default_title)
    local EPSILON = 0.05
    default_title = (default_title and default_title ~= "") and default_title or "Chapter"
    duration = tonumber(duration) or 0

    local original_chapters = {}
    if type(base_chapters) == "table" then
        for _, ch in ipairs(base_chapters) do
            if ch and ch.time then
                table.insert(original_chapters, {
                    time  = tonumber(ch.time) or 0,
                    title = ch.title or "",
                })
            end
        end
    end
    table.sort(original_chapters, function(a, b) return a.time < b.time end)

    local function get_original_chapter_title_at(time_pos)
        if #original_chapters == 0 then return nil end
        local matched = nil
        for _, ch in ipairs(original_chapters) do
            if ch.time <= time_pos + EPSILON then
                matched = ch.title
            else
                break
            end
        end
        return matched
    end

    local active_segs = {}
    if type(segments) == "table" then
        for _, seg in ipairs(segments) do
            if segment_marker_enabled(seg.type) then
                local s = math.max(0, tonumber(seg.start_sec) or 0)
                local e = tonumber(seg.end_sec) or 0
                if duration > 0 and e > duration then
                    e = duration
                end
                if e > s + EPSILON then
                    table.insert(active_segs, {
                        start_sec = s,
                        end_sec   = e,
                        type      = seg.type,
                        title     = chapter_title_for_segment(seg.type),
                    })
                end
            end
        end
    end
    table.sort(active_segs, function(a, b) return a.start_sec < b.start_sec end)

    if #active_segs == 0 then
        return original_chapters, 0
    end

    local function is_inside_any_segment(t)
        for _, s in ipairs(active_segs) do
            if (s.start_sec + EPSILON) <= t and t < (s.end_sec - EPSILON) then
                return true
            end
        end
        return false
    end

    local function another_seg_starts_at(t, current_seg)
        for _, s in ipairs(active_segs) do
            if s ~= current_seg and math.abs(s.start_sec - t) < EPSILON then
                return true
            end
        end
        return false
    end

    local function original_chapter_starts_at(t)
        for _, ch in ipairs(original_chapters) do
            if math.abs(ch.time - t) < EPSILON then
                return true
            end
        end
        return false
    end

    local function segment_starts_at(t)
        for _, s in ipairs(active_segs) do
            if math.abs(s.start_sec - t) < EPSILON then
                return s
            end
        end
        return nil
    end

    local candidate_chapters = {}

    for _, ch in ipairs(original_chapters) do
        local t = ch.time
        if not segment_starts_at(t) and not is_inside_any_segment(t) then
            table.insert(candidate_chapters, {
                time   = t,
                title  = ch.title,
                source = "base",
                prio   = 2,
            })
        end
    end

    for _, seg in ipairs(active_segs) do

        table.insert(candidate_chapters, {
            time   = seg.start_sec,
            title  = seg.title,
            source = "seg_start",
            prio   = 3,
        })

        local e = seg.end_sec
        local skip_closing = false
        if duration > 0 and e >= duration - EPSILON then
            skip_closing = true
        elseif is_inside_any_segment(e) then
            skip_closing = true
        elseif another_seg_starts_at(e, seg) then
            skip_closing = true
        elseif original_chapter_starts_at(e) then
            skip_closing = true
        end

        if not skip_closing then
            local orig_title = get_original_chapter_title_at(e)
            local closing_title = (orig_title and orig_title ~= "") and orig_title or default_title
            table.insert(candidate_chapters, {
                time   = e,
                title  = closing_title,
                source = "seg_end",
                prio   = 1,
            })
        end
    end

    table.sort(candidate_chapters, function(a, b)
        if math.abs(a.time - b.time) < EPSILON then
            return a.prio > b.prio
        end
        return a.time < b.time
    end)

    local deduped = {}
    for _, ch in ipairs(candidate_chapters) do
        local t = math.max(0, ch.time)
        if not (duration > 0 and t >= duration - EPSILON) then
            if #deduped == 0 then
                table.insert(deduped, { time = t, title = ch.title })
            else
                local last = deduped[#deduped]
                if math.abs(t - last.time) < EPSILON then

                else
                    table.insert(deduped, { time = t, title = ch.title })
                end
            end
        end
    end

    return deduped, #active_segs
end

local function publish_segments(segments)
    local published = {}
    for _, seg in ipairs(segments) do
        if segment_marker_enabled(seg.type) then
            table.insert(published, {
                start   = seg.start_sec,
                ["end"] = seg.end_sec,
                kind    = seg.type,
            })
        end
    end
    local ok = pcall(mp.set_property_native, "user-data/jumpskip/segments", published)
    if not ok then
        log_debug("user-data properties unavailable (mpv < 0.36); seekbar highlights disabled")
    end
    if user_opts.mark_chapters then

        if state.base_chapter_list == nil then
            state.base_chapter_list = mp.get_property_native("chapter-list") or {}
        end

        local file_dur = state.duration
        if not file_dur or file_dur <= 0 then
            file_dur = mp.get_property_number("duration") or 0
        end

        local chapters, marked_count = build_marked_chapters(
            state.base_chapter_list,
            segments,
            file_dur,
            user_opts.default_chapter_title
        )

        mp.set_property_native("chapter-list", chapters)
        log_debug("Updated chapter markers (%d segment(s) marked, %d total chapters in chapter-list)",
            marked_count, #chapters)
    end
end

local function provider_segment_allowed(provider, seg_type, context)
    if not provider or not seg_type then return true end
    local key = tostring(provider):lower() .. '_' .. tostring(seg_type):lower() .. '_segment'
    local enabled = user_opts[key]
    if enabled == nil then
        log_request(context, 'debug', 'No per-provider toggle %s (unknown provider or segment type); allowing segment', key)
        return true
    end
    return enabled == true
end

local function filter_provider_segments(segs, context)
    local filtered = {}
    for _, seg in ipairs(segs) do
        if provider_segment_allowed(seg.provider, seg.type, context) then
            table.insert(filtered, seg)
        else
            log_request(context, 'info', 'Dropping %s segment from %s (disabled via %s_%s_segment=no)',
                tostring(seg.type), tostring(seg.provider),
                tostring(seg.provider):lower(), tostring(seg.type):lower())
        end
    end
    return filtered
end

local function get_provider_priority(media_info, configured_only)

    local priority_str
    if media_info.is_tv then
        priority_str = user_opts.provider_priority_tvshow
    else
        priority_str = user_opts.provider_priority_movie
    end

    local providers = parse_provider_priority(priority_str)
    if configured_only then return providers end
    local media_type = media_info.is_tv and 'tvshow' or 'movie'
    local selected = runtime_overrides.providers[media_type]
    if selected then
        for _, name in ipairs(providers) do
            if name == selected then return {selected} end
        end
        runtime_overrides.providers[media_type] = nil
    end
    return providers
end

function playlist_prefetch.key(path)
    if not path or path == '' then return nil end
    if not is_url(path) then
        local ok, normalized = pcall(mp.command_native, {'normalize-path', path})
        if ok and type(normalized) == 'string' then return normalized end
    end
    return path
end

function playlist_prefetch.signature(info)
    local values = {}
    for _, field in ipairs({'title', 'title_with_year', 'year', 'year_ambiguous',
        'is_tv', 'season', 'episode', 'season_missing', 'imdb_id', 'tmdb_id', 'tvdb_id'}) do
        values[#values + 1] = tostring(info[field])
    end
    return utils.format_json(values)
end

function playlist_prefetch.sync_options()
    local keys, values = {}, {}
    for key in pairs(default_opts) do keys[#keys + 1] = key end
    table.sort(keys)
    for _, key in ipairs(keys) do values[#values + 1] = tostring(user_opts[key]) end
    values[#values + 1] = tostring(runtime_overrides.providers.tvshow)
    values[#values + 1] = tostring(runtime_overrides.providers.movie)
    local signature = utils.format_json(values)
    if playlist_prefetch.options ~= signature then
        playlist_prefetch.stop()
        playlist_prefetch.cache = {}
        playlist_prefetch.options = signature
    end
end

local function query_segments_pipeline(job, allow_cached)
    if not job then
        playlist_prefetch.stop()
        cancel_requests(state.query_context)
        state.query_id = (state.query_id or 0) + 1
        state.query_in_progress, state.prefetch_ready = false, false
    end
    local current_query_id, current_file_id = state.query_id, state.file_id
    local source = job and job.media_info or state.media_info
    if not user_opts.enabled or not source then return end
    if not job then playlist_prefetch.sync_options() end

    local context = job and job.context or {duration=state.duration}
    local path_key = job and job.path_key or playlist_prefetch.key(state.path)
    local signature = playlist_prefetch.signature(source)
    local key = path_key and (path_key .. '\0' .. signature)
    local cached = allow_cached and user_opts.playlist_prefetch and key and playlist_prefetch.cache[key]
    if cached and (cached.signature ~= signature or not cached.id_found) then cached = nil end
    local media_info = copy_table(cached and cached.media_info or source)
    local function is_current()
        return not context.cancelled and state.file_id == current_file_id and state.query_id == current_query_id
    end
    if not job then
        state.query_context = context
        state.query_in_progress, state.segments_loaded = true, false
        state.segments = {}
    end
    local providers = get_provider_priority(media_info)
    local media_type = media_info.is_tv and 'tvshow' or 'movie'
    if not job then
        mp.commandv('script-message', 'jumpskip-provider-order', media_type, table.concat(providers, ','))
    end

    local finished, id_resolved = false, false
    local function finish(results)
        if finished or not is_current() then return end
        finished = true
        if user_opts.playlist_prefetch and key then
            playlist_prefetch.cache[key] = {path_key=path_key, signature=signature, media_info=copy_table(media_info),
                results=copy_table(results), duration=context.duration, id_found=id_resolved}
        end
        if job then
            playlist_prefetch.active = nil
            playlist_prefetch.schedule()
            return
        end
        local final_segs = {}
        for _, result in ipairs(results) do
            if result.ok and #result.segs > 0 then
                final_segs = merge_segment_lists(final_segs, result.segs)
                if not user_opts.merge_providers then break end
            end
        end
        if user_opts.chapter_skip_enabled then
            local chapters = state.base_chapter_list or mp.get_property_native('chapter-list') or {}
            local derived = detect_chapter_segments(chapters, state.duration, final_segs, media_info)
            for _, segment in ipairs(derived) do final_segs[#final_segs + 1] = segment end
        end
        table.sort(final_segs, function(a, b) return a.start_sec < b.start_sec end)
        state.media_info, state.segments = media_info, final_segs
        state.segments_loaded, state.query_in_progress = true, false
        state.query_context, state.prefetch_ready = nil, true
        log_segments_summary(final_segs, results)
        publish_segments(final_segs)
        check_playback_position(mp.get_property_number('time-pos'))
        playlist_prefetch.schedule()
    end
    if #providers == 0 then finish({}); return end
    log_request(context, 'info', 'Querying segment timestamps from %d provider(s) [%s]: %s...', #providers, media_type, table.concat(providers, ' -> '))
    local function resolved(id_found)
        if not is_current() then return end
        id_resolved = id_found
        if not id_found then finish({}); return end
        local results, pending = {}, #providers
        for idx, name in ipairs(providers) do
            if not is_current() then return end
            local result = cached and cached.results[idx]
            if result and result.name ~= name then result = nil end
            local cached_duration = result and (result.duration or cached.duration)
            local response_duration = context.duration
            local function completed(ok, segs, err)
                if not is_current() or results[idx] then return end
                if not ok and result and result.ok then
                    log_warn('%s refresh failed; using cached segments: %s', name, tostring(err))
                    ok, segs, err = true, copy_table(result.segs), nil
                    response_duration = cached_duration
                end
                -- Keep each provider's original runtime on fallback. A failed
                -- refresh must not prevent another attempt on a later load.
                results[idx] = {name=name, ok=ok, segs=ok and segs and filter_provider_segments(segs, context) or {},
                    err=err, duration=response_duration}
                pending = pending - 1
                if pending == 0 then finish(results) end
            end
            local query = provider_fns[name]
            -- Duration-sensitive providers must see the loaded file's runtime;
            -- keep their prefetched segments if that refresh fails offline.
            local duration_matches = result and (name == 'introdb' or cached_duration == context.duration)
            if result and result.ok and duration_matches then
                response_duration = cached_duration
                completed(true, copy_table(result.segs), nil)
            elseif query then query(media_info, current_file_id, completed, context)
            else completed(false, nil, 'Unknown provider: ' .. name) end
        end
    end
    if cached then
        log_info("Using prefetched metadata for '%s'", media_info.title or '?')
        resolved(true)
    else
        resolve_title_to_imdb(media_info, current_file_id, resolved, context)
    end
end

local function update_button_coordinates()
    local w = state.display_w
    local h = state.display_h

    local scale   = h / 1080.0
    local btn_w   = user_opts.button_width    * scale
    local btn_h   = user_opts.button_height   * scale
    local margin_x = user_opts.button_margin_x * scale
    local margin_y = user_opts.button_margin_y * scale

    local x1, y1, x2, y2
    if user_opts.button_position == "bottom-left" then
        x1, y1 = margin_x,           h - margin_y - btn_h
        x2, y2 = margin_x + btn_w,   h - margin_y
    elseif user_opts.button_position == "top-right" then
        x1, y1 = w - margin_x - btn_w, margin_y
        x2, y2 = w - margin_x,         margin_y + btn_h
    elseif user_opts.button_position == "top-left" then
        x1, y1 = margin_x,           margin_y
        x2, y2 = margin_x + btn_w,   margin_y + btn_h
    else
        x1, y1 = w - margin_x - btn_w, h - margin_y - btn_h
        x2, y2 = w - margin_x,         h - margin_y
    end

    state.box.x1 = x1
    state.box.y1 = y1
    state.box.x2 = x2
    state.box.y2 = y2
end

local default_segment_colors = {
    intro = "8416FF", recap = "FF7F2B", outro = "FF46AD",
    preview = "A7BB00", post_credits = "A7BB00",
}

local function skip_button_accent(seg)
    if not user_opts.button_color_by_segment then return user_opts.accent_color end
    local colors = mp.get_property_native("user-data/jumpskip/osc-colors")
    if type(colors) == "table" then
        local kind = seg.type
        if kind == "outro" and state.media_info and not state.media_info.is_tv and colors.credits then
            kind = "credits"
        end
        local color = colors[kind]
        if type(color) == "string" and color:match("^%x%x%x%x%x%x$") then return color end
    end
    return default_segment_colors[seg.type] or user_opts.accent_color
end

local function render_skip_button()
    if not state.button_visible or not state.active_segment then
        if state.overlay then
            state.overlay.data = ""
            state.overlay:update()
        end
        return
    end

    if not state.overlay then
        state.overlay = mp.create_osd_overlay("ass-events")
    end

    update_button_coordinates()

    local seg      = state.active_segment
    local accent   = skip_button_accent(seg)
    local scale    = state.display_h / 1080.0
    local x1, y1, x2, y2 = state.box.x1, state.box.y1, state.box.x2, state.box.y2
    local center_x = round((x1 + x2) / 2)
    local center_y = round((y1 + y2) / 2)
    local radius   = round(12 * scale)

    local ass = assdraw.ass_new()

    local is_hover     = state.mouse_hover
    local bg_opacity   = is_hover and 0.95 or 0.85
    local border_alpha = is_hover and "00" or "40"
    local border_width = is_hover and round(2.0 * scale) or round(1.2 * scale)
    local glow_opacity = is_hover and 0.35 or 0.15

    ass:new_event()
    ass:append(string.format("{\\pos(0,0)\\rDefault\\an7\\blur%d\\bord0\\1c&H%s&\\1a&H%02X&}",
        round(8 * scale), accent, opacity_to_alpha(glow_opacity)))
    ass:draw_start()
    ass:round_rect_cw(x1 - (3 * scale), y1 - (3 * scale), x2 + (3 * scale), y2 + (3 * scale), radius + (2 * scale))
    ass:draw_stop()

    ass:new_event()
    ass:append(string.format("{\\pos(0,0)\\rDefault\\an7\\blur0\\bord%d\\1c&H%s&\\1a&H%02X&\\3c&H%s&\\3a&H%s&}",
        border_width, user_opts.bg_color, opacity_to_alpha(bg_opacity), accent, border_alpha))
    ass:draw_start()
    ass:round_rect_cw(x1, y1, x2, y2, radius)
    ass:draw_stop()

    local main_label = string.format("Skip %s \xe2\x96\xb6", seg.label or "Segment")
    if state.auto_skip_target_time then
        local remaining = math.max(0, math.ceil(state.auto_skip_target_time - mp.get_time()))
        main_label = string.format("Skip %s (%ds)", seg.label or "Segment", remaining)
    end

    local font_size = round(user_opts.button_font_size * scale)

    ass:new_event()
    ass:append(string.format("{\\pos(%d,%d)\\rDefault\\an5\\fn%s\\fs%d\\b1\\bord0\\shad1\\4c&H000000&\\1c&H%s&}",
        center_x, center_y, user_opts.button_font, font_size, user_opts.text_color))
    ass:append(main_label)

    state.overlay.res_x = state.display_w
    state.overlay.res_y = state.display_h
    state.overlay.data  = ass.text
    state.overlay.z     = 2000
    state.overlay:update()
end

local function show_autoskip_notification(label)
    if not state.overlay then
        state.overlay = mp.create_osd_overlay("ass-events")
    end
    local w        = state.display_w
    local h        = state.display_h
    local scale    = h / 1080.0
    local fs       = math.floor(user_opts.button_font_size * scale)
    local margin_y = math.floor(user_opts.button_margin_y * scale)
    local ay       = h - margin_y - math.floor(user_opts.button_height * scale) - math.floor(8 * scale)
    local ax       = w / 2
    local a_accent = string.format("%02X", 255 - math.floor(0.92 * 255))
    local a_bg     = string.format("%02X", 255 - math.floor(0.85 * 255))
    local ass = string.format(
        "{\\an8}{\\pos(%d,%d)}{\\bord0}{\\shad2}{\\4c&H%s&}{\\1c&H%s&}{\\alpha&H%s&}"
        .. "{\\fn%s}{\\fs%d}{\\b1}Auto-skipped: %s",
        ax, ay,
        user_opts.bg_color, user_opts.accent_color, a_accent,
        user_opts.button_font, fs, label)
    state.overlay.data = ass
    state.overlay:update()
    mp.add_timeout(user_opts.osd_message_duration, function()
        if state.overlay then
            state.overlay.data = ""
            state.overlay:update()
        end
    end)
end

perform_skip = function(is_auto)
    if not user_opts.enabled then return end
    if not state.active_segment then
        log_debug("perform_skip called but no active segment")
        return
    end

    local seg    = state.active_segment
    local target = seg.end_sec
    if not target or target <= 0 then
        log_warn("Cannot skip: segment end time unknown")
        return
    end

    local skip_kind = is_auto and "Auto-skipping" or "Skipping"
    log_info("%s %s from %.2fs to %.2fs (provider: %s)", skip_kind, seg.label, seg.start_sec, target, seg.provider)

    seg.skipped = true
    mp.commandv("seek", target, "absolute", "exact")

    if user_opts.show_osd_message then
        if is_auto then
            show_autoskip_notification(seg.label)
        else
            mp.osd_message(string.format("Skipped %s", seg.label), user_opts.osd_message_duration)
        end
    end

    if state.auto_skip_timer then
        state.auto_skip_timer:kill()
        state.auto_skip_timer      = nil
        state.auto_skip_target_time = nil
    end
    if state.button_timeout_timer then
        state.button_timeout_timer:kill()
        state.button_timeout_timer = nil
    end

    state.button_visible = false
    state.active_segment = nil
    render_skip_button()
end

local function set_mbtn_binding(enable)
    if enable and not state.mbtn_bound then
        mp.add_forced_key_binding("MBTN_LEFT", "jumpskip_click", perform_skip)
        state.mbtn_bound = true
        log_debug("MBTN_LEFT skip binding enabled")
    elseif not enable and state.mbtn_bound then
        mp.remove_key_binding("jumpskip_click")
        state.mbtn_bound = false
        log_debug("MBTN_LEFT skip binding disabled")
    end
end

local function should_autoskip(seg_type)
    if autoskip_types_active then
        return autoskip_type_set[seg_type] == true
    end
    return user_opts.auto_skip
end

check_playback_position = function(current_time)
    if not user_opts.enabled or not current_time or not state.segments_loaded then return end

    local last = state.last_time
    if last and current_time < last - 1.0 then
        for _, seg in ipairs(state.segments) do
            if seg.skipped and current_time < seg.end_sec then
                seg.skipped = false
                log_debug("Reset skipped flag for '%s' (backward seek detected)", seg.label)
            end
        end
    end
    state.last_time = current_time

    local matched_segment = nil
    for _, seg in ipairs(state.segments) do
        if not seg.skipped and current_time >= seg.start_sec and current_time < (seg.end_sec - 0.2) then
            matched_segment = seg
            break
        end
    end

    if matched_segment then
        if state.active_segment ~= matched_segment then
            if state.auto_skip_timer then state.auto_skip_timer:kill(); state.auto_skip_timer = nil end
            if state.button_timeout_timer then state.button_timeout_timer:kill(); state.button_timeout_timer = nil end
            state.auto_skip_target_time = nil
            state.active_segment = matched_segment
            state.button_visible = true
            log_info("Playback entered %s segment (%.2fs (%s) - %.2fs (%s))",
                matched_segment.label,
                matched_segment.start_sec, format_hms(matched_segment.start_sec),
                matched_segment.end_sec, format_hms(matched_segment.end_sec))

            if should_autoskip(matched_segment.type) then
                if user_opts.auto_skip_countdown > 0 then
                    state.auto_skip_target_time = mp.get_time() + user_opts.auto_skip_countdown
                    if state.auto_skip_timer then state.auto_skip_timer:kill() end
                    state.auto_skip_timer = mp.add_periodic_timer(0.25, function()
                        if not state.active_segment then
                            if state.auto_skip_timer then state.auto_skip_timer:kill() end
                            return
                        end
                        if mp.get_time() >= state.auto_skip_target_time then
                            if state.auto_skip_timer then state.auto_skip_timer:kill() end
                            state.auto_skip_timer       = nil
                            state.auto_skip_target_time = nil
                            perform_skip(true)
                        else
                            render_skip_button()
                        end
                    end)
                else
                    perform_skip(true)
                    return
                end
            elseif user_opts.skip_button_timeout > 0 then
                if state.button_timeout_timer then state.button_timeout_timer:kill() end
                state.button_timeout_timer = mp.add_timeout(user_opts.skip_button_timeout, function()
                    state.button_timeout_timer = nil
                    if state.button_visible then
                        state.button_visible = false
                        state.mouse_hover    = false
                        set_mbtn_binding(false)
                        render_skip_button()
                        log_debug("Skip button hidden after %gs timeout (keybind '%s' still active)",
                            user_opts.skip_button_timeout, tostring(user_opts.keybind))
                    end
                end)
            end

            render_skip_button()
        end
    else
        if state.active_segment then
            log_debug("Playback exited %s segment", state.active_segment.label)
            state.active_segment = nil
            state.button_visible = false
            set_mbtn_binding(false)
            if state.auto_skip_timer then
                state.auto_skip_timer:kill()
                state.auto_skip_timer       = nil
                state.auto_skip_target_time = nil
            end
            if state.button_timeout_timer then
                state.button_timeout_timer:kill()
                state.button_timeout_timer = nil
            end
            render_skip_button()
        end
    end
end

local function on_mouse_pos(_, mouse)
    if not mouse then
        return
    end

    local x, y = mouse.x, mouse.y

    if state.submission_visible then
        submission_handle_mouse(x, y)
        if state.mouse_hover then
            state.mouse_hover = false
            set_mbtn_binding(false)
        end
        return
    end

    if not state.button_visible then
        if state.mouse_hover then
            state.mouse_hover = false
            set_mbtn_binding(false)
            render_skip_button()
        end
        return
    end

    local is_inside = (x >= state.box.x1 and x <= state.box.x2 and
                       y >= state.box.y1 and y <= state.box.y2)
    if is_inside ~= state.mouse_hover then
        state.mouse_hover = is_inside
        set_mbtn_binding(is_inside)
        render_skip_button()
    end
end

local function reset_state()
    playlist_prefetch.stop()
    cancel_requests(state.query_context)
    state.query_context, state.prefetch_ready = nil, false
    state.file_id          = state.file_id + 1
    state.query_id         = (state.query_id or 0) + 1
    state.path             = nil
    state.filename         = nil
    state.duration         = 0
    state.media_info       = nil
    state.query_in_progress = false
    state.last_time        = nil
    state.auto_skip_target_time = nil
    state.active_segment   = nil
    state.button_visible   = false
    state.mouse_hover      = false
    state.segments_loaded  = false
    state.segments         = {}
    state.base_chapter_list = nil
    set_mbtn_binding(false)
    if state.submission_visible then
        close_submission_overlay()
    end
    if state.submission_status_timer then
        state.submission_status_timer:kill()
        state.submission_status_timer = nil
    end
    state.submission_data.segment_type = "intro"
    state.submission_data.start_sec = nil
    state.submission_data.end_sec = nil
    state.submission_data.status = ""
    state.submission_data.status_color = "FFFFFF"
    state.submission_data.submitting = false
    if state.auto_skip_timer then
        state.auto_skip_timer:kill()
        state.auto_skip_timer = nil
    end
    if state.button_timeout_timer then
        state.button_timeout_timer:kill()
        state.button_timeout_timer = nil
    end
    if state.overlay then
        state.overlay.data = ""
        state.overlay:update()
    end
    pcall(mp.set_property_native, "user-data/jumpskip/segments", {})
end

local function refresh_current_segments()
    playlist_prefetch.cache = {}
    local path, filename = state.path, state.filename
    local duration, media_info = state.duration, state.media_info
    if state.base_chapter_list ~= nil then
        mp.set_property_native("chapter-list", state.base_chapter_list)
    end
    reset_state()
    state.path, state.filename = path, filename
    state.duration, state.media_info = duration, media_info
    query_segments_pipeline()
end

toggle_enabled = function()
    user_opts.enabled = not user_opts.enabled
    runtime_overrides.enabled = user_opts.enabled
    refresh_current_segments()
    local status = user_opts.enabled and "enabled" or "disabled"
    mp.osd_message("JumpSkip: " .. status, user_opts.osd_message_duration)
    log_info("JumpSkip %s", status)
end

cycle_provider = function()
    if not state.media_info then
        mp.osd_message("JumpSkip: load an allowed video to switch providers", user_opts.osd_message_duration)
        return
    end
    local media_type = state.media_info.is_tv and 'tvshow' or 'movie'
    local providers = get_provider_priority(state.media_info, true)
    if #providers == 0 then
        mp.osd_message("JumpSkip: no providers configured for " .. media_type, user_opts.osd_message_duration)
        return
    end
    local index = 0
    for i, name in ipairs(providers) do
        if name == runtime_overrides.providers[media_type] then index = i; break end
    end
    local selected = providers[index + 1]
    runtime_overrides.providers[media_type] = selected
    refresh_current_segments()
    local labels = {theintrodb="TheIntroDB", introdb="IntroDB", skipdb="SkipDB"}
    local label = selected and labels[selected] or "Auto (configured priority)"
    if not user_opts.enabled then label = label .. " (script disabled)" end
    mp.osd_message("JumpSkip provider: " .. label, user_opts.osd_message_duration)
    log_info("JumpSkip provider [%s]: %s", media_type, label)
end

local function url_decode(s)
    if not s then return s end
    return (s:gsub("%%(%x%x)", function(hex)
        return string.char(tonumber(hex, 16))
    end))
end

local function normalize_absolute_path(path)
    if not path or #path == 0 then
        return nil
    end

    local clean = path:gsub("^file://localhost", ""):gsub("^file://", "")
    clean = url_decode(clean)

    clean = clean:gsub("^/([a-zA-Z]:)", "%1")

    local norm = nil
    pcall(function()
        norm = mp.command_native({"normalize-path", clean})
    end)
    if not norm or #norm == 0 then
        local is_abs = clean:match("^[a-zA-Z]:") or clean:match("^[\\/]")
        if not is_abs then
            local work_dir = mp.get_property("working-directory")
            if not work_dir or #work_dir == 0 then
                pcall(function() work_dir = utils.getcwd() end)
            end
            if work_dir and #work_dir > 0 then
                clean = utils.join_path(work_dir, clean)
            end
        end
        norm = clean
    end

    norm = norm:gsub("\\", "/"):gsub("^/([a-zA-Z]:)", "%1")
    return norm:lower()
end

local function is_directory_allowed(path, context)
    local filter = user_opts.filter_directories or ""
    if #filter == 0 then
        return true
    end
    if not path or #path == 0 then
        return false, "empty path"
    end

    local norm = normalize_absolute_path(path)
    if not norm then
        return false, "failed to normalize path"
    end

    local dir = norm:match("^(.*)/[^/]*$")
    local folder = nil
    if dir then
        folder = dir:match("([^/]+)/?$")

        if folder and folder:match("^[a-zA-Z]:$") then
            folder = nil
        end
    end

    local wrapped_dir = nil
    if dir and #dir > 0 then
        local trimmed_dir = dir:gsub("^/+", ""):gsub("/+$", "")
        wrapped_dir = "/" .. trimmed_dir .. "/"
    end

    local exclusions = {}
    local inclusions = {}

    for entry in filter:gmatch("[^,]+") do
        local raw = entry:match("^%s*(.-)%s*$")
        if raw and #raw > 0 then
            local is_exclusion = raw:find("%*") ~= nil
            local is_fragment  = raw:find("[\\/]") ~= nil
            local clean        = raw:gsub("%*", "")

            if is_fragment then
                clean = clean:gsub("^[\\/]+", ""):gsub("\\", "/"):gsub("/+$", ""):match("^%s*(.-)%s*$"):lower()
                if #clean > 0 then
                    local rule = { mode = "fragment", pattern = clean, raw = raw }
                    if is_exclusion then
                        exclusions[#exclusions + 1] = rule
                    else
                        inclusions[#inclusions + 1] = rule
                    end
                end
            else
                clean = clean:match("^%s*(.-)%s*$"):lower()
                if #clean > 0 then
                    local rule = { mode = "parent", pattern = clean, raw = raw }
                    if is_exclusion then
                        exclusions[#exclusions + 1] = rule
                    else
                        inclusions[#inclusions + 1] = rule
                    end
                end
            end
        end
    end

    local function rule_matches(rule)
        if rule.mode == "parent" then
            return folder and (folder == rule.pattern)
        elseif rule.mode == "fragment" then
            return wrapped_dir and string.find(wrapped_dir, "/" .. rule.pattern .. "/", 1, true) ~= nil
        end
        return false
    end

    for _, rule in ipairs(exclusions) do
        if rule_matches(rule) then
            log_request(context, 'debug', "filter_directories: file '%s' matched exclusion rule '%s' -> skipping", path, rule.raw)
            return false, "matched exclusion rule '" .. rule.raw .. "'"
        end
    end

    if #inclusions == 0 then
        return true
    end

    for _, rule in ipairs(inclusions) do
        if rule_matches(rule) then
            log_request(context, 'debug', "filter_directories: file '%s' matched inclusion rule '%s' -> allowed", path, rule.raw)
            return true
        end
    end

    log_request(context, 'debug', "filter_directories: file '%s' did not match any inclusion rules -> skipping", path)
    return false, "folder not in filter_directories inclusions"
end

function playlist_prefetch.schedule()
    if not user_opts.enabled or not user_opts.playlist_prefetch or not state.prefetch_ready
        or state.query_in_progress or playlist_prefetch.active or playlist_prefetch.timer then return end
    -- Yield between entries, including synchronous cache hits and failures.
    playlist_prefetch.timer = mp.add_timeout(0.1, function()
        playlist_prefetch.timer = nil
        playlist_prefetch.sync_options()
        local entries = mp.get_property_native('playlist') or {}
        local position = mp.get_property_number('playlist-pos', -1)
        if position < 0 then return end
        local present, snapshot = {}, {tostring(state.file_id), tostring(position)}
        for index, entry in ipairs(entries) do
            local key = playlist_prefetch.key(entry.filename)
            if key then present[key] = true end
            if index > position then
                snapshot[#snapshot + 1] = {entry.filename or '', entry.title or ''}
            end
        end
        for key, cached in pairs(playlist_prefetch.cache) do
            if not present[cached.path_key] then playlist_prefetch.cache[key] = nil end
        end
        local total = #entries - position
        if total <= 1 then return end
        local progress_key = utils.format_json(snapshot)
        if playlist_prefetch.progress_key ~= progress_key then
            playlist_prefetch.progress_key, playlist_prefetch.progress_complete = progress_key, false
            log_info('Prefetching playlist: 1/%d', total)
        end
        local context = {quiet=true}
        for index = position + 2, #entries do
            local entry = entries[index]
            local path = entry.filename
            local key = playlist_prefetch.key(path)
            if key and is_directory_allowed(path, context) then
                -- Never read the playing file's metadata, title, or chapters
                -- when identifying a different playlist entry.
                local info = TitleParser.extract_media_metadata(path, path, entry.title or '', {})
                local signature = playlist_prefetch.signature(info)
                local cached = playlist_prefetch.cache[key .. '\0' .. signature]
                if not cached then
                    if #get_provider_priority(info) > 0 then
                        context.duration = tonumber(entry.duration) or 0
                        playlist_prefetch.active = context
                        query_segments_pipeline({path_key=key, media_info=info, context=context})
                        return
                    end
                end
            end
        end
        if not playlist_prefetch.progress_complete then
            playlist_prefetch.progress_complete = true
            log_info('Prefetching playlist complete: %d/%d', total, total)
        end
    end)
end

local function on_playlist_changed()
    -- Re-read the queue after edits so removed/reordered items cannot keep an
    -- obsolete queue alive. Completed lookups remain reusable by path.
    playlist_prefetch.stop(true)
    playlist_prefetch.schedule()
end

local function on_file_loaded()
    load_configuration()
    reset_state()
    state.path     = mp.get_property("path")
    state.filename = mp.get_property("filename")

    local allowed, reason = is_directory_allowed(state.path)
    if not allowed then
        log_debug("Skipping file (%s): %s", reason or "excluded by filter_directories", state.path or "(none)")
        playlist_prefetch.sync_options()
        state.prefetch_ready = true
        playlist_prefetch.schedule()
        return
    end

    state.duration   = mp.get_property_number("duration") or 0
    state.media_info = extract_media_metadata()
    query_segments_pipeline(nil, true)
end

local function on_end_file()
    reset_state()
end

local function on_osd_dimensions_change(_, dim)
    if dim and dim.w and dim.h and dim.w > 0 and dim.h > 0 then
        state.display_w = dim.w
        state.display_h = dim.h
        if state.button_visible then render_skip_button() end
        if state.submission_visible then render_submission_overlay() end
    end
end

mp.register_script_message("skip-segment", perform_skip)
mp.register_script_message("toggle-jumpskip", toggle_enabled)
mp.register_script_message("cycle-jumpskip-provider", cycle_provider)
mp.register_script_message("reload-segments", function()
    log_info("Reloading segment timestamps...")
    refresh_current_segments()
end)
mp.register_script_message("reload-config", function()
    runtime_overrides.enabled, runtime_overrides.providers = nil, {}
    load_configuration()
    if state.path then refresh_current_segments() end
end)

mp.observe_property("time-pos",       "number", function(_, cur_time) check_playback_position(cur_time) end)
mp.observe_property("osd-dimensions", "native", on_osd_dimensions_change)
mp.observe_property("mouse-pos",      "native", on_mouse_pos)
mp.observe_property("playlist",       "native", on_playlist_changed)
mp.observe_property("user-data/jumpskip/osc-colors", "native", function()
    if user_opts.button_color_by_segment and state.button_visible then render_skip_button() end
end)

mp.register_event("file-loaded", on_file_loaded)
mp.register_event("end-file",    on_end_file)
mp.register_event("start-file", function()
    playlist_prefetch.stop()
    cancel_requests(state.query_context)
    state.prefetch_ready = false
end)
mp.register_event("shutdown", function()
    playlist_prefetch.stop()
    cancel_requests(state.query_context)
end)

load_configuration()

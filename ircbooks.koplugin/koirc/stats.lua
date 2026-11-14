--[[--
Reading statistics: pages and time per day, from rows of KOReader's own
statistics database (the Reading statistics plugin).

No KOReader dependencies: rows are passed in, so this can be tested on a
desktop.
]]

local M = {}

--- Days as "YYYY-MM-DD", newest first, ending on today.
function M.days(today_time, count)
    local out = {}
    for i = 0, count - 1 do
        out[#out + 1] = os.date("%Y-%m-%d", today_time - i * 86400)
    end
    return out
end

--- Add up rows of {day, title, pages, seconds} (one row per day and book).
-- Returns {days = {[day] = {pages, seconds}}, books = {{title, pages, seconds}},
-- pages, seconds, active_days}.
function M.summarize(rows)
    local by_day, by_book, books = {}, {}, {}
    local pages, seconds, active = 0, 0, 0
    for _, r in ipairs(rows or {}) do
        local p, s = tonumber(r.pages) or 0, tonumber(r.seconds) or 0
        local d = by_day[r.day]
        if not d then
            d = { pages = 0, seconds = 0 }
            by_day[r.day] = d
            active = active + 1
        end
        d.pages, d.seconds = d.pages + p, d.seconds + s
        local title = r.title or "?"
        local b = by_book[title]
        if not b then
            b = { title = title, pages = 0, seconds = 0 }
            by_book[title] = b
            books[#books + 1] = b
        end
        b.pages, b.seconds = b.pages + p, b.seconds + s
        pages, seconds = pages + p, seconds + s
    end
    table.sort(books, function(a, b) return a.seconds > b.seconds end)
    return { days = by_day, books = books, pages = pages, seconds = seconds, active_days = active }
end

--- Days in a row with some reading, counting back from today (or from
-- yesterday when nothing was read yet today).
function M.streak(by_day, today_time)
    local n, t = 0, today_time
    if not by_day[os.date("%Y-%m-%d", t)] then t = t - 86400 end
    while by_day[os.date("%Y-%m-%d", t)] do
        n = n + 1
        t = t - 86400
    end
    return n
end

function M.duration(seconds)
    seconds = math.floor((tonumber(seconds) or 0) + 0.5)
    local h, m = math.floor(seconds / 3600), math.floor(seconds % 3600 / 60)
    if h > 0 then return string.format("%dh %02dm", h, m) end
    if m > 0 then return string.format("%dm", m) end
    return seconds > 0 and "<1m" or "0m"
end

--- The dashboard as text. labels: translated strings (see the defaults).
function M.format(sum, day_list, today_time, labels)
    labels = labels or {}
    local L = function(k, d) return labels[k] or d end
    local lines = {}
    local today = sum.days[day_list[1]] or { pages = 0, seconds = 0 }
    lines[#lines + 1] = string.format("%s: %d %s · %s", L("today", "Today"), today.pages,
        L("pages", "pages"), M.duration(today.seconds))
    lines[#lines + 1] = string.format("%s: %d %s · %s", L("period", "Last days"), sum.pages,
        L("pages", "pages"), M.duration(sum.seconds))
    if sum.active_days > 0 then
        lines[#lines + 1] = string.format("%s: %d %s · %s", L("average", "Per reading day"),
            math.floor(sum.pages / sum.active_days + 0.5), L("pages", "pages"),
            M.duration(sum.seconds / sum.active_days))
    end
    lines[#lines + 1] = string.format("%s: %d", L("streak", "Days in a row"), M.streak(sum.days, today_time))
    lines[#lines + 1] = ""
    local max = 0
    for _, d in ipairs(day_list) do
        local x = sum.days[d]
        if x and x.seconds > max then max = x.seconds end
    end
    for _, d in ipairs(day_list) do
        local x = sum.days[d] or { pages = 0, seconds = 0 }
        local w = max > 0 and math.floor(x.seconds / max * 12 + 0.5) or 0
        if x.seconds > 0 and w == 0 then w = 1 end
        local t = os.time{ year = tonumber(d:sub(1, 4)), month = tonumber(d:sub(6, 7)), day = tonumber(d:sub(9, 10)), hour = 12 }
        lines[#lines + 1] = string.format("%s  %s %s", os.date("%a %d %b", t), string.rep("█", w),
            x.seconds > 0 and string.format("%d p · %s", x.pages, M.duration(x.seconds)) or "–")
    end
    if #sum.books > 0 then
        lines[#lines + 1] = ""
        lines[#lines + 1] = L("books", "Books")
        for i, b in ipairs(sum.books) do
            if i > 8 then break end
            lines[#lines + 1] = string.format("• %s — %d p · %s", b.title, b.pages, M.duration(b.seconds))
        end
    end
    return table.concat(lines, "\n")
end

--- Progress toward a reading goal. count: books read so far, goal: books
-- wanted, from/to: start and end of the goal period (seconds; default: this
-- calendar year). Returns {count, goal, pct, expected, diff, days_left}:
-- expected is how many books would be read by now at an even pace, diff is
-- count - expected (positive: ahead).
function M.goal(count, goal, now, from, to)
    now = now or os.time()
    if not from or not to then
        local y = tonumber(os.date("%Y", now))
        from = os.time{ year = y, month = 1, day = 1, hour = 0 }
        to = os.time{ year = y + 1, month = 1, day = 1, hour = 0 }
    end
    goal = math.max(1, tonumber(goal) or 1)
    count = tonumber(count) or 0
    local span = math.max(1, to - from)
    local share = math.max(0, math.min(1, (now - from) / span))
    local expected = goal * share
    return {
        count = count, goal = goal,
        pct = math.floor(math.min(count / goal, 1) * 100 + 0.5),
        expected = expected,
        diff = count - expected,
        days_left = math.max(0, math.ceil((to - now) / 86400)),
    }
end

--- A text bar such as "▓▓▓▓░░░░░░" for pct (0..100).
function M.bar(pct, width)
    width = width or 10
    local n = math.floor((tonumber(pct) or 0) * width / 100 + 0.5)
    n = math.max(0, math.min(width, n))
    return string.rep("▓", n) .. string.rep("░", width - n)
end

--- Lines for the dashboard. g from M.goal; labels: {goal, ahead, behind,
-- on_track, done, days_left} with %1/%2 placeholders filled by the caller's
-- template function T.
function M.goalLines(g, title, T, labels)
    local lines = {}
    lines[#lines + 1] = T(labels.goal, title, g.count, g.goal, g.pct)
    lines[#lines + 1] = M.bar(g.pct, 20)
    if g.count >= g.goal then
        lines[#lines + 1] = labels.done
    else
        local d = math.floor(g.diff + 0.5)
        if d >= 1 then lines[#lines + 1] = T(labels.ahead, d)
        elseif d <= -1 then lines[#lines + 1] = T(labels.behind, -d)
        else lines[#lines + 1] = labels.on_track end
        lines[#lines + 1] = T(labels.days_left, g.days_left, g.goal - g.count)
    end
    return lines
end

return M

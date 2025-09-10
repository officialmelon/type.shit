--======================================================================
-- Typing Test (Refactored)
--======================================================================
-- Environment glue
print = trace.log

--======================================================================
-- Config / Constants
--======================================================================
local DEBUG = true

local DEFAULTS = {
    timeLimit = 30,          -- seconds
    wordCount = 30,          -- 0 = infinite (use full generated text)
    mode      = "words",     -- "words" | "quotes" | "numbers"
}

local WORDS_PER_LINE = 10

-- Colors (BBCode-like tinting for your renderer)
local COLORS = {
    TYPED      = "#C8E0F7",
    INCORRECT  = "#F54927",
    REMAINING  = "#707d89ff",
}

-- Data (content pools)
local DATA = {
    Quotes = {
        "The only limit to our realization of tomorrow is our doubts of today.",
        "In the middle of every difficulty lies opportunity.",
        "Life is 10% what happens to us and 90% how we react to it.",
        "The best way to predict the future is to create it.",
        "Success is not final, failure is not fatal: It is the courage to continue that counts."
    },
    Words = {
        "Inspire","Create","Believe","Achieve","Dream","Hello","World","If","You","Can","Read","This",
        "Vibecode","Are","Awesome","Lua","Scripting","Is","Fun","Typing","Test","Shit","Man","Human",
        "Buss","Facedev","Game","Godot","Love","Peace","Unity","CSharp","JavaScript","Python","Hackathon",
        "Gurt","Gurted","Luis","Mackabu","Github","open","source","code","ai",
        "Machine","Deep","Learning","Real","Thick","It"
    }
}

--======================================================================
-- Utils
--======================================================================
local function dbg(fmt, ...)
    if not DEBUG then return end
    local ok, msg = pcall(string.format, fmt, ...)
    print(ok and msg or "[dbg-format-error] " .. tostring(fmt))
end

-- Normalize Time.now() to seconds across environments (ns/ms/s)
local function nowSeconds()
    local ok, t = pcall(function() return Time and Time.now and Time.now() or 0 end)
    if not ok then return 0 end
    if t > 1e12 then return t / 1e9 end  -- nanoseconds
    if t > 1e6 then return t / 1000 end  -- milliseconds
    return t                              -- seconds
end

local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

local function safeToOneLine(s)
    if not s then return "<nil>" end
    return tostring(s):gsub("\n", "\\n"):gsub("\t", "\\t"):gsub(" ", "·")
end

local function safeClearInterval(id)
    if id then
        clearInterval(id)
    end
end

--======================================================================
-- DOM / Elements
--======================================================================
local E = {
    testWords       = gurt.select('#test-words'),
    restartBtn      = gurt.select('#restart-btn'),

    wpm             = gurt.select('#wpm-value'),
    accuracy        = gurt.select('#accuracy-value'),
    timer           = gurt.select('#time-value'),

    -- time buttons
    time30          = gurt.select('#time-30'),
    time60          = gurt.select('#time-60'),
    time120         = gurt.select('#time-120'),

    -- mode switches
    typeWords       = gurt.select('#type-words'),
    typeQuotes      = gurt.select('#type-quotes'),
    typeNumbers     = gurt.select('#type-numbers'),

    -- word count
    word30          = gurt.select('#words-30'),
    word60          = gurt.select('#words-60'),
    wordInf         = gurt.select('#words-inf'),
}

--======================================================================
-- State
--======================================================================
local S = {
    cfg = {
        timeLimit = DEFAULTS.timeLimit,
        wordCount = DEFAULTS.wordCount,
        mode      = DEFAULTS.mode,
    },

    -- runtime
    active              = false,
    startSec            = 0,        -- absolute start (seconds)
    elapsedSeconds      = 0,        -- whole seconds elapsed (timer ticks)
    timerId             = nil,
    timerSession        = 0,        -- monotonic to avoid stale intervals

    -- text and progress
    fullText            = "",
    linesRaw            = {},       -- raw text per line (string)
    errorAtIndex        = {},       -- absolute char index => true
    totalTyped          = 0,        -- absolute chars typed
    totalErrors         = 0,        -- total mistakes
}

--======================================================================
-- Rendering helpers
--======================================================================
local function tint(s, color)
    return "[color=" .. color .. "]" .. s .. "[/color]"
end

local function colorizeText(rawText, typedCount)
    rawText = rawText or ""
    local len = #rawText
    if len == 0 then return "" end
    typedCount = clamp(typedCount or 0, 0, len)
    if typedCount == 0  then return tint(rawText, COLORS.REMAINING) end
    if typedCount == len then return tint(rawText, COLORS.TYPED) end
    return tint(rawText:sub(1, typedCount), COLORS.TYPED)
        .. tint(rawText:sub(typedCount + 1), COLORS.REMAINING)
end

local function colorizeLine(rawText, typedCount, startAbsIndex, errors)
    local len = #rawText
    if len == 0 then return "" end
    typedCount = clamp(typedCount or 0, 0, len)

    local parts, currentColor, buffer = {}, nil, {}
    local function flush()
        if currentColor and #buffer > 0 then
            table.insert(parts, tint(table.concat(buffer), currentColor))
            buffer = {}
        end
    end

    for i = 1, len do
        local absIndex = startAbsIndex + i - 1
        local ch = rawText:sub(i, i)
        local color
        if i <= typedCount then
            color = errors[absIndex] and COLORS.INCORRECT or COLORS.TYPED
        else
            color = COLORS.REMAINING
        end

        if color ~= currentColor then
            flush()
            currentColor = color
        end
        table.insert(buffer, ch)
    end
    flush()

    return table.concat(parts)
end

local function clearTextArea()
    local el = E.testWords
    if not el then return end
    el.text = ""
    for i = #el.children, 1, -1 do
        local child = el.children[i]
        if child and child.remove then child:remove() end
    end
end

local function resetRuntime()
    S.active         = false
    S.startSec       = 0
    S.elapsedSeconds = 0
    S.totalTyped     = 0
    S.totalErrors    = 0
    S.fullText       = ""
    S.linesRaw       = {}
    S.errorAtIndex   = {}
end

local function buildLinesFromText(text)
    S.linesRaw = {}

    -- chunk by words into lines; preserves spaces between words and trailing
    local words = {}
    for w in text:gmatch("%S+") do table.insert(words, w) end

    if #words == 0 then
        S.linesRaw[1] = text
        return
    end

    local line, lineIdx = {}, 1
    for i, w in ipairs(words) do
        table.insert(line, w)
        local endOfLine = (#line == WORDS_PER_LINE) or (i == #words)
        if endOfLine then
            local base = table.concat(line, " ")
            local raw = (i == #words) and base or (base .. " ")
            S.linesRaw[lineIdx] = raw
            line, lineIdx = {}, lineIdx + 1
        end
    end
end

local function renderLinesInitial()
    clearTextArea()
    for i = 1, #S.linesRaw do
        local raw = S.linesRaw[i]
        E.testWords:append(gurt.create('span', {
            className = "word",
            id        = 'line-' .. i,
            style     = ".word",
            text      = colorizeText(raw, 0),
            rawText   = raw,
        }))
    end
end

local function renderProgress()
    local charOffset = 0
    for i = 1, #E.testWords.children do
        local lineDiv = E.testWords.children[i]
        local raw = S.linesRaw[i] or (lineDiv and lineDiv.rawText) or ""
        local charsOnLine = math.min(#raw, S.totalTyped - charOffset)
        if charsOnLine > 0 then
            lineDiv.text = colorizeLine(raw, charsOnLine, charOffset + 1, S.errorAtIndex)
        end
        charOffset = charOffset + #raw
    end
end

local function renderComplete()
    local charOffset = 0
    for i = 1, #E.testWords.children do
        local raw = S.linesRaw[i] or ""
        E.testWords.children[i].text = colorizeLine(raw, #raw, charOffset + 1, S.errorAtIndex)
        charOffset = charOffset + #raw
    end
end

--======================================================================
-- Metrics
--======================================================================
local function calcWPM(cpm) return math.floor(cpm / 5) end

local function calcAccuracy(total, errors)
    if total <= 0 then return 100 end
    local pct = ((total - errors) / total) * 100
    return math.floor(clamp(pct, 0, 100))
end

local function updateStats(nowElapsedOpt)
    local elapsed = (S.elapsedSeconds > 0) and S.elapsedSeconds or (nowElapsedOpt or math.max(0.001, nowSeconds() - S.startSec))
    local cpm = (S.totalTyped / elapsed) * 60
    local wpm = calcWPM(cpm)
    local acc = calcAccuracy(S.totalTyped, S.totalErrors)
    if E.wpm      then E.wpm.text      = wpm end
    if E.accuracy then E.accuracy.text = acc .. "%" end
end

--======================================================================
-- Audio
--======================================================================
local function playKey(kind)
    if kind ~= "hard-key" and kind ~= "soft-key" then return end
    gurt.create('audio', {
        src      = 'assets/' .. kind .. '.wav',
        autoplay = true,
        volume   = 0.5,
        loop     = false,
        id       = tostring(math.random(1, 1e9)),
    })
end

--======================================================================
-- Generators
--======================================================================
local function getRandomWord()
    local words = DATA.Words
    return string.lower(words[math.random(1, #words)])
end

local function generateNumbers(count)
    local out = {}
    for i = 1, count do out[i] = tostring(math.random(0, 9)) end
    return table.concat(out)
end

local function generateWords(count)
    local out = {}
    for i = 1, count do out[i] = getRandomWord() end
    return table.concat(out, " ")
end

local function generateText(mode, wordCount)
    if mode == "quotes" then
        return DATA.Quotes[math.random(1, #DATA.Quotes)]
    elseif mode == "numbers" then
        local n = (wordCount and wordCount > 0) and wordCount or 50
        return generateNumbers(n)
    else -- "words"
        local n = (wordCount and wordCount > 0) and wordCount or 50
        return generateWords(n)
    end
end

--======================================================================
-- Timer
--======================================================================
local function stopTimer()
    safeClearInterval(S.timerId)
    S.timerId = nil
end

local function startTimer(seconds)
    stopTimer()
    S.elapsedSeconds = 0

    local secondsLeft = seconds
    S.timerSession = S.timerSession + 1
    local session = S.timerSession

    if E.timer then E.timer.text = string.format("%d", secondsLeft) end

    local function onTick()
        if session ~= S.timerSession then
            stopTimer()
            return
        end
        if not S.active then
            stopTimer()
            return
        end

        S.elapsedSeconds = S.elapsedSeconds + 1
        secondsLeft = secondsLeft - 1

        if E.timer then E.timer.text = string.format("%d", math.max(0, secondsLeft)) end
        updateStats()

        if secondsLeft < 0 then
            stopTimer()
            S.active = false
            updateStats(S.elapsedSeconds)
            dbg("TIMEOUT: total=%d errors=%d elapsed=%d", S.totalTyped, S.totalErrors, S.elapsedSeconds)
        end
    end

    S.timerId = setInterval(onTick, 1000)
    dbg("TIMER started session=%d timeLimit=%d", session, seconds)
end

--======================================================================
-- Test lifecycle
--======================================================================
local function setHudDefaults()
    if E.wpm      then E.wpm.text      = 0 end
    if E.accuracy then E.accuracy.text = "100%" end
    E.restartBtn.visible = false
end

local function startTest()
    if S.active then return end

    stopTimer()
    resetRuntime()
    clearTextArea()

    S.active   = true
    S.startSec = nowSeconds()

    setHudDefaults()

    E.restartBtn.visible = true
    S.fullText = generateText(S.cfg.mode, S.cfg.wordCount)
    buildLinesFromText(S.fullText)
    renderLinesInitial()
    startTimer(S.cfg.timeLimit)

    dbg("TEST START: mode=%s words=%d len=%d text='%s'",
        S.cfg.mode, S.cfg.wordCount or -1, #S.fullText, safeToOneLine(S.fullText))
end

local function endTest(message)
    S.active = false
    E.restartBtn.visible = false
    stopTimer()

    renderComplete()
    updateStats(S.elapsedSeconds)

    if message then
        clearTextArea()
        E.testWords:append(gurt.create('span', {
            className = "word",
            id        = 'line-done',
            style     = ".word",
            text      = colorizeText(message, 0),
            rawText   = message,
        }))
    end

    dbg("TEST END: total=%d errors=%d elapsed=%d",
        S.totalTyped, S.totalErrors, S.elapsedSeconds)
end

--======================================================================
-- Input handling
--======================================================================
local IGNORE_KEYS = {
    Enter = true, Shift = true,
    Control   = true, Alt    = true, Meta  = true,
}

gurt.body:on('keydown', function(event)
    local key = event.key

    -- Escape: cancel / end
    if key == "Escape" then
        endTest("Test Ended. Press any key to start a new test.")
        return
    end

    -- Tab: start
    if key == "Tab" then
        event.preventDefault()
        startTest()
        return
    end

    -- Handle backspace: allow deleting last character when active
    if key == "Backspace" and S.active and S.totalTyped > 0 then
        event.preventDefault()
        -- remove last char
        local idx = S.totalTyped
        if S.errorAtIndex[idx] then
            S.totalErrors = S.totalErrors - 1
            S.errorAtIndex[idx] = nil
        end
        S.totalTyped = idx - 1
        -- update display and stats
        renderProgress()
        updateStats()
        return
    end
    -- Auto-start on first non-control key
    if not S.active then
        startTest()
    end

    -- Ignore other control keys for typing progress
    if IGNORE_KEYS[key] then return end

    playKey("hard-key")

    -- Expected vs typed (case-insensitive)
    local expectedChar = S.fullText:sub(S.totalTyped + 1, S.totalTyped + 1)
    local typedLower   = string.lower(tostring(key or ""))
    local expectedLower= string.lower(expectedChar)

    if typedLower ~= expectedLower then
        S.totalErrors = S.totalErrors + 1
        S.errorAtIndex[S.totalTyped + 1] = true
    end
    S.totalTyped = S.totalTyped + 1

    -- Update progress coloring
    renderProgress()

    -- Complete
    if S.totalTyped >= #S.fullText then
        endTest()
        return
    end

    -- Live stats (prefer timer-based elapsed)
    local elapsedPref = (S.elapsedSeconds > 0) and S.elapsedSeconds or math.max(0.25, nowSeconds() - S.startSec)
    updateStats(elapsedPref)
end)

--======================================================================
-- Config: persistence and UI binding
--======================================================================
local function saveConfig()
    gurt.crumbs.set({
        name  = "Config",
        value = S.cfg.timeLimit .. "," .. S.cfg.wordCount .. "," .. S.cfg.mode,
        days  = 365
    })
end

local function loadConfig()
    local config = gurt.crumbs.get("Config")
    if not config then return end

    local parts = {}
    for part in string.gmatch(config, "[^,]+") do
        table.insert(parts, part)
    end

    S.cfg.timeLimit = tonumber(parts[1]) or DEFAULTS.timeLimit
    S.cfg.wordCount = tonumber(parts[2]) or DEFAULTS.wordCount
    S.cfg.mode      = parts[3] or DEFAULTS.mode
end

-- Time buttons
E.time30:on('click', function()
    if S.active then return end
    S.cfg.timeLimit = 30
    E.time30.classList:add('active')
    E.time60.classList:remove('active')
    E.time120.classList:remove('active')
    saveConfig()
end)

E.time60:on('click', function()
    if S.active then return end
    S.cfg.timeLimit = 60
    E.time30.classList:remove('active')
    E.time60.classList:add('active')
    E.time120.classList:remove('active')
    saveConfig()
end)

E.time120:on('click', function()
    if S.active then return end
    S.cfg.timeLimit = 120
    E.time30.classList:remove('active')
    E.time60.classList:remove('active')
    E.time120.classList:add('active')
    saveConfig()
end)

-- Word count buttons
E.word30:on('click', function()
    if S.active then return end
    S.cfg.wordCount = 30
    E.word30.classList:add('active')
    E.word60.classList:remove('active')
    E.wordInf.classList:remove('active')
    saveConfig()
end)

E.word60:on('click', function()
    if S.active then return end
    S.cfg.wordCount = 60
    E.word30.classList:remove('active')
    E.word60.classList:add('active')
    E.wordInf.classList:remove('active')
    saveConfig()
end)

E.wordInf:on('click', function()
    if S.active then return end
    S.cfg.wordCount = 0
    E.word30.classList:remove('active')
    E.word60.classList:remove('active')
    E.wordInf.classList:add('active')
    saveConfig()
end)

-- Mode buttons
E.typeWords:on('click', function()
    if S.active then return end
    S.cfg.mode = "words"
    E.typeWords.classList:add('active')
    E.typeQuotes.classList:remove('active')
    E.typeNumbers.classList:remove('active')
    saveConfig()
end)

E.typeQuotes:on('click', function()
    if S.active then return end
    S.cfg.mode = "quotes"
    E.typeWords.classList:remove('active')
    E.typeQuotes.classList:add('active')
    E.typeNumbers.classList:remove('active')
    saveConfig()
end)

E.typeNumbers:on('click', function()
    if S.active then return end
    S.cfg.mode = "numbers"
    E.typeWords.classList:remove('active')
    E.typeQuotes.classList:remove('active')
    E.typeNumbers.classList:add('active')
    saveConfig()
end)

-- Restart button
if E.restartBtn then
    E.restartBtn:on('click', startTest)
end

--======================================================================
-- Boot
--======================================================================
local function applyActiveClassesFromConfig()
    -- time
    if S.cfg.timeLimit == 30 then
        E.time30.classList:add('active')
    elseif S.cfg.timeLimit == 60 then
        E.time60.classList:add('active')
    elseif S.cfg.timeLimit == 120 then
        E.time120.classList:add('active')
    end

    -- words
    if S.cfg.wordCount == 30 then
        E.word30.classList:add('active')
    elseif S.cfg.wordCount == 60 then
        E.word60.classList:add('active')
    elseif S.cfg.wordCount == 0 then
        E.wordInf.classList:add('active')
    end

    -- mode
    if S.cfg.mode == "words" then
        E.typeWords.classList:add('active')
    elseif S.cfg.mode == "quotes" then
        E.typeQuotes.classList:add('active')
    elseif S.cfg.mode == "numbers" then
        E.typeNumbers.classList:add('active')
    end
end

loadConfig()
applyActiveClassesFromConfig()
setHudDefaults()
-- Ready. Press Tab or any non-control key to start.
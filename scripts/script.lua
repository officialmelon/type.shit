--======================================================================
-- Typing Test (Refactored)
--======================================================================
-- Environment glue
print = trace.log
-- declare environment globals for lint
local gurt, Time, setInterval, clearInterval, trace = gurt, Time, setInterval, clearInterval, trace

--======================================================================
-- Config / Constants
--======================================================================

-- forward-declare helpers used before their implementation
local skipSpaces
local DEBUG = false

local DEFAULTS = {
    timeLimit = 30,          -- seconds
    wordCount = 30,          -- 0 = infinite (use full generated text)
    mode      = "words",     -- "words" | "quotes" | "numbers"
}

local WORDS_PER_LINE = 10
local INFINITE_LINES = 3     -- Number of lines to keep visible for infinite mode

-- Colors (BBCode-like tinting for your renderer)
local COLORS = {
    PROGRESS   = "#4287f5",
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

function elementCleanLoad(element, tweenTime)
	setTimeout(function()
		element:createTween():to('opacity', 0):duration(0):play()
		Time.sleep(0.01)
		element:createTween():to('opacity', 1):duration(tweenTime):play()
	end, 0)
end

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
    shiftedChars        = 0,        -- characters shifted out in infinite mode
    blinkOn             = false,    -- toggle for blinking highlight
    blinkIntervalId     = nil,      -- interval ID for blink toggling
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
        end
    end

    -- flash the single absolute next character (so only caret blinks)
    local globalNextAbs = S.totalTyped + S.shiftedChars + 1
    for i = 1, len do
        local absIndex = startAbsIndex + i - 1
        local ch = rawText:sub(i, i)
        local color
        if absIndex == globalNextAbs then
            if S.blinkOn then
                color = COLORS.PROGRESS
                -- show placeholder for space when blinking
                if ch == " " then ch = "▯" end
            else
                color = COLORS.REMAINING
            end
        elseif i <= typedCount then
            -- already typed chars
            color = errors[absIndex] and COLORS.INCORRECT or COLORS.TYPED
        else
            -- remaining untyped chars
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
    S.shiftedChars   = 0
end

-- Advance the typed pointer over any spaces so spaces don't require typing
-- (moved below updateStats for cleaner ordering)
-- forward declarations for generators to resolve use-before-definition in infinite mode
local generateText, generateNumbers, generateWords, getRandomWord

local function generateMoreContent()
    if S.cfg.mode == "numbers" then
        return generateNumbers(WORDS_PER_LINE)  -- Maintain line length consistency
    else
        return generateWords(WORDS_PER_LINE)    -- Exactly one line worth of words
    end
end

local function buildLinesFromText(text, isInfinite)
    S.linesRaw = {}
    
    if isInfinite then
        -- For infinite mode, we'll generate lines as needed
        if S.cfg.mode == "numbers" then
            -- For numbers, generate a long string of digits
            local numbers = generateNumbers(100)  -- Generate 100 digits initially
            text = numbers
        else
            -- For words/quotes, use the provided text or generate more
            if not text or text == "" then
                text = generateText(S.cfg.mode, 30)  -- Initial text
            end
        end
        
        -- Split into words for proper line breaking
        local words = {}
        for w in text:gmatch("%S+") do 
            table.insert(words, w) 
        end
        
        -- Build initial lines
        local line, lineIdx = {}, 1
        for i, w in ipairs(words) do
            table.insert(line, w)
            if #line == WORDS_PER_LINE or i == #words then
                S.linesRaw[lineIdx] = table.concat(line, " ") .. (i ~= #words and " " or "")
                line, lineIdx = {}, lineIdx + 1
                if lineIdx > INFINITE_LINES then break end
            end
        end
    else
        -- Original logic for finite mode
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
end

local function renderLinesInitial()
    clearTextArea()
    local charOffset = S.shiftedChars
    for i = 1, #S.linesRaw do
        local raw = S.linesRaw[i]
        E.testWords:append(gurt.create('span', {
            className = "word",
            id        = 'line-' .. i,
            style     = ".word",
            text      = colorizeLine(raw, 0, charOffset + 1, S.errorAtIndex),
            rawText   = raw,
        }))
        charOffset = charOffset + #raw
    end
end

local function renderProgress()
    local charOffset = S.shiftedChars
    for i = 1, #E.testWords.children do
        local lineDiv = E.testWords.children[i]
        local raw = S.linesRaw[i] or (lineDiv and lineDiv.rawText) or ""
        -- calculate how many characters of this line have been typed
        local typedOnLine = S.totalTyped - charOffset
        local charsOnLine = math.min(#raw, math.max(0, typedOnLine))
        -- always update the line text (colorizeLine handles typedCount == 0)
        lineDiv.text = colorizeLine(raw, charsOnLine, charOffset + 1, S.errorAtIndex)
        charOffset = charOffset + #raw
    end
end

local function renderComplete()
    local charOffset = S.shiftedChars
    for i = 1, #E.testWords.children do
        local raw = S.linesRaw[i] or ""
        E.testWords.children[i].text = colorizeLine(raw, #raw, charOffset + 1, S.errorAtIndex)
        charOffset = charOffset + #raw
    end
end

-- New helper: shift the first line out and append a newly generated line (infinite mode)
local function shiftFirstLine()
    -- Ensure we are in infinite mode and have at least one line
    if S.cfg.wordCount ~= 0 or #S.linesRaw == 0 then return end

    local firstLen = #S.linesRaw[1]
    -- Remove first raw line and append a new one
    table.remove(S.linesRaw, 1)
    table.insert(S.linesRaw, generateMoreContent())

    -- Re-map error indices to account for the removed characters
    local remappedErrors = {}
    for idx, _ in pairs(S.errorAtIndex) do
        if idx > firstLen then
            remappedErrors[idx - firstLen] = true
        end
    end
    S.errorAtIndex = remappedErrors

    -- Update counters
    S.totalTyped  = math.max(0, S.totalTyped - firstLen)
    S.shiftedChars = S.shiftedChars + firstLen

    -- Re-render display
    renderLinesInitial()
    renderProgress()
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
        src      = 'https://github.com/officialmelon/type.shit/blob/master/assets/' .. kind .. '.wav?raw=true',
        autoplay = true,
        volume   = 0.5,
        loop     = false,
        id       = tostring(math.random(1, 1e9)),
    })
end

--======================================================================
-- Generators
--======================================================================
getRandomWord = function()
    local words = DATA.Words
    return string.lower(words[math.random(1, #words)])
end

generateNumbers = function(count)
    local out = {}
    for i = 1, count do out[i] = tostring(math.random(0, 9)) end
    return table.concat(out)
end

generateWords = function(count)
    local out = {}
    for i = 1, count do out[i] = getRandomWord() end
    return table.concat(out, " ")
end

generateText = function(mode, wordCount)
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
    -- initialize blinking highlight
    if S.blinkIntervalId then clearInterval(S.blinkIntervalId) end
    S.blinkOn = false
    S.blinkIntervalId = setInterval(function()
        S.blinkOn = not S.blinkOn
        renderProgress()
    end, 500)
    S.startSec = nowSeconds()

    setHudDefaults()

    E.restartBtn.visible = true
    elementCleanLoad(gurt.select('#time-counter'), 1)
    
    -- Handle infinite vs finite mode
    if S.cfg.wordCount == 0 then
        -- Infinite mode - we'll generate content as we go
        S.fullText = ""  -- No full text for infinite mode
        buildLinesFromText("", true)  -- Start with empty text, will generate initial content
    else
        -- Finite mode - original logic
        S.fullText = generateText(S.cfg.mode, S.cfg.wordCount)
        buildLinesFromText(S.fullText, false)
    end
    
    renderLinesInitial()
    startTimer(S.cfg.timeLimit)

    dbg("TEST START: mode=%s words=%d len=%d text='%s'",
        S.cfg.mode, S.cfg.wordCount or -1, #S.fullText, safeToOneLine(S.fullText))
end

local function endTest(message)
    S.active = false
    -- stop blinking highlight
    if S.blinkIntervalId then clearInterval(S.blinkIntervalId) end
    S.blinkIntervalId = nil
    S.blinkOn = false
    E.restartBtn.visible = false

    elementCleanLoad(gurt.select('#wpm-counter'), 1)
    elementCleanLoad(gurt.select('#accuracy-counter'), 1)
    elementCleanLoad(gurt.select('#restart-btn'), 1)

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

    -- Tab: start (only when not active)
    if key == "Tab" then
        if not S.active then startTest() end
        return
    end

    -- Handle backspace: allow deleting last character when active
    if key == "Backspace" and S.active and S.totalTyped > 0 then
        -- remove last char
        local idx = S.totalTyped
        -- Errors are stored as 1-based absolute indices; compute absolute idx
        local absIdx = idx + S.shiftedChars
        if S.errorAtIndex[absIdx + 1] then
            S.totalErrors = math.max(0, S.totalErrors - 1)
            S.errorAtIndex[absIdx + 1] = nil
        end
        S.totalTyped = math.max(0, idx - 1)
        -- update display and stats
        renderProgress()
        updateStats()
        return
    end
    
    -- Auto-start on first non-control key (ignore this keypress for typing)
    if not S.active then
        startTest()
        return
    end

    -- Restrict accepted characters to digits, letters, and space
    if not key:match("^[A-Za-z0-9 ]$") then
        if IGNORE_KEYS[key] then return end -- ignore harmless control keys
        return -- block anything else
    end
    -- treat space as valid input now
    if IGNORE_KEYS[key] then return end


    -- If user pressed space, skip spaces automatically and don't count the keypress
    if key == " " or key == "Space" then
        skipSpaces()
        return
    end

    playKey("hard-key")

    -- infinite mode shift is now handled after rendering progress

    -- Expected vs typed (case-insensitive)
    local currentText = S.cfg.wordCount == 0 and table.concat(S.linesRaw) or S.fullText
    local expectedChar = currentText:sub(S.totalTyped + 1, S.totalTyped + 1)
    local typedLower   = string.lower(tostring(key or ""))
    local expectedLower= string.lower(expectedChar)

    if typedLower ~= expectedLower then
        S.totalErrors = S.totalErrors + 1
    -- store errors using 1-based absolute char indices (matches colorizeLine absIndex)
    S.errorAtIndex[S.totalTyped + S.shiftedChars + 1] = true
    end
    S.totalTyped = S.totalTyped + 1

    -- after typing a character, auto-skip any spaces that follow
    skipSpaces()

    -- Update progress coloring
    renderProgress()
    -- infinite mode: after rendering, shift buffer when first line is fully typed
    if S.cfg.wordCount == 0 and S.active then
        local firstLen = #S.linesRaw[1] or 0
        if S.totalTyped >= firstLen then
            shiftFirstLine()
        end
    end

    -- Complete (only for finite mode)
    if S.cfg.wordCount > 0 and S.totalTyped >= #S.fullText then
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
    E.timer.text = "30"
    E.time30.classList:add('active')
    E.time60.classList:remove('active')
    E.time120.classList:remove('active')
    saveConfig()
end)

E.time60:on('click', function()
    if S.active then return end
    S.cfg.timeLimit = 60
    E.timer.text = "60"
    E.time30.classList:remove('active')
    E.time60.classList:add('active')
    E.time120.classList:remove('active')
    saveConfig()
end)

E.time120:on('click', function()
    if S.active then return end
    S.cfg.timeLimit = 120
    E.timer.text = "120"
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
        E.timer.text = "30"
        E.time30.classList:add('active')
    elseif S.cfg.timeLimit == 60 then
        E.timer.text = "60"
        E.time60.classList:add('active')
    elseif S.cfg.timeLimit == 120 then
        E.timer.text = "120"
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

-- Fade in load
elementCleanLoad(gurt.select('#header'), 1)
elementCleanLoad(gurt.select('#test-section'), 1)
elementCleanLoad(gurt.select('#config-section'), 1)

loadConfig()
applyActiveClassesFromConfig()
setHudDefaults()
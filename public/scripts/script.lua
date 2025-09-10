--// Global
print = trace.log

--// Data
local typeOut = {
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

--// State
local testActive = false
local currentCharIndex = 1
local totalCharsTyped = 0
local totalErrors = 0
local testStartTime = 0
local fullText = ""
local linesRaw = {}
local errorPositions = {}

--// Elements
local testWords = gurt.select('#test-words')
local restartBtn = gurt.select('#restart-btn')
local wpmElement = gurt.select('#wpm-value')
local accuracyElement = gurt.select('#accuracy-value')
local timerElement = gurt.select('#time-value')

local time30 = gurt.select('#time-30')
local time60 = gurt.select('#time-60')
local time120 = gurt.select('#time-120')

local typeWords = gurt.select('#type-words')
local typeQuotes = gurt.select('#type-quotes')
local typeNumbers = gurt.select('#type-numbers')

local word30 = gurt.select('#words-30')
local word60 = gurt.select('#words-60')
local wordInf = gurt.select('#words-inf')

--// Colors
local COLOR_TYPED = "#C8E0F7"
local COLOR_INCORRECT = "#F54927"
local COLOR_REMAINING = "#707d89ff"

--// Utils
local DEBUG = true
local cfg = { timeLimit = 30, wordCount = 30, mode = "words" }

local function dbg(fmt, ...)
    if DEBUG then
        local ok, msg = pcall(string.format, fmt, ...)
        print(ok and msg or "[dbg-format-error] " .. fmt)
    end
end

local function show(s)
    if not s then return "<nil>" end
    return tostring(s):gsub("\n","\\n"):gsub("\t","\\t"):gsub(" ","·")
end

local function getRandomWord()
    local words = typeOut.Words
    return string.lower(words[math.random(1,#words)])
end

local function ColorizeText(rawText, typedCount)
    rawText = rawText or ""
    local len = #rawText
    if len == 0 then return "" end
    typedCount = math.max(0, math.min(typedCount or 0, len))
    local function tint(s,color) return "[color="..color.."]"..s.."[/color]" end
    if typedCount==0 then return tint(rawText,COLOR_REMAINING) end
    if typedCount==len then return tint(rawText,COLOR_TYPED) end
    return tint(rawText:sub(1,typedCount),COLOR_TYPED) .. tint(rawText:sub(typedCount+1),COLOR_REMAINING)
end

local function DetermineWPM(CPM) return math.floor(CPM/5) end
local function DetermineAccuracy(totalChars,errors)
    return totalChars==0 and 100 or math.floor(math.max(0,math.min(100,((totalChars-errors)/totalChars)*100)))
end

local function keyPress(type)
    if type~="hard-key" and type~="soft-key" then return end
    gurt.create('audio',{src='assets/'..type..'.wav',autoplay=true,volume=0.5,loop=false,id=tostring(math.random(1,1e9))})
end

--// Text Area Management
local function resetTextArea()
    testWords.text = ""
    for i=1,#testWords.children do testWords.children[i]:remove() end
    currentCharIndex,totalCharsTyped,totalErrors,testStartTime,fullText,linesRaw,errorPositions = 1,0,0,0,"",{},{}
end

local function setTextArea(wordsString)
    resetTextArea()
    fullText = wordsString
    local words = {}
    for word in wordsString:gmatch("%S+") do table.insert(words,word) end
    local lineCount,currentLine = 1,{}
    for i,word in ipairs(words) do
        table.insert(currentLine,word)
        if #currentLine==10 or i==#words then
            local lineText = table.concat(currentLine," ")
            local raw = (i==#words) and lineText or (lineText.." ")
            linesRaw[lineCount] = raw
            testWords:append(gurt.create('span',{
                className="word", id='line-'..lineCount, style=".word",
                text=ColorizeText(raw,0), rawText=raw
            }))
            currentLine,lineCount = {},lineCount+1
        end
    end
end

local function startTimer(TimeInSeconds)
    local secondsLeft = TimeInSeconds
    local intervalId = setInterval(function()
        timerElement.text = string.format("%d",secondsLeft)
        secondsLeft = secondsLeft - 1
        if secondsLeft<0 then clearInterval(intervalId) end
    end,1000)
end

local function GenerateSpeedTestText(wordCount)
    local text = {}
    for i=1,wordCount do table.insert(text,getRandomWord()) end
    return table.concat(text," ")
end

--// Unified Start/Restart function
local function StartTest()
    testActive = true
    testStartTime = Time.now()
    if cfg.mode=="quotes" then
        fullText = typeOut.Quotes[math.random(1,#typeOut.Quotes)]
        setTextArea(fullText)
        startTimer(cfg.timeLimit)
        dbg("START quote text len=%d text='%s'",#fullText,show(fullText))
        return
    end
    if cfg.mode=="numbers" then
        fullText = tostring(math.random(1e9,1e10-1))
        setTextArea(fullText)
        startTimer(cfg.timeLimit)
        dbg("START number text len=%d text='%s'",#fullText,show(fullText))
        return
    end
    if cfg.mode=="words" then
        local wordCount = cfg.wordCount>0 and cfg.wordCount or 50
        fullText = GenerateSpeedTestText(wordCount)
        setTextArea(fullText)
        startTimer(cfg.timeLimit)
        dbg("START word text len=%d words=%d text='%s'",#fullText,wordCount,show(fullText))
        return
    end
end

local function ColorizeLine(rawText, typedCount, startAbsIndex, errors)
    local len = #rawText
    if len==0 then return "" end
    typedCount = math.max(0,math.min(typedCount,len))
    local parts,currentColor,buffer = {},nil,{}
    local function flush() if currentColor and #buffer>0 then table.insert(parts,"[color="..currentColor.."]"..table.concat(buffer).."[/color]"); buffer={} end end
    for i=1,len do
        local abs,startCh,color = startAbsIndex+i-1,rawText:sub(i,i)
        if i<=typedCount then color=errors[abs] and COLOR_INCORRECT or COLOR_TYPED else color=COLOR_REMAINING end
        if color~=currentColor then flush(); currentColor=color end
        table.insert(buffer,startCh)
    end
    flush()
    return table.concat(parts)
end

--// Main typing handler
gurt.body:on('keydown',function(event)
    local key=event.key
    local ignoreKeys={Backspace=true,Delete=true,Enter=true,Shift=true,Control=true,Alt=true,Meta=true}

    -- Escape: stop test
    if key=="Escape" then
        testActive=false
        setTextArea("Test Ended. Press any key to start a new test.")
        return
    end

    -- Tab: restart test
    if key=="Tab" then
        event.preventDefault()
        StartTest()
        return
    end

    -- First keypress starts test
    if not testActive then StartTest() return end
    if ignoreKeys[key] then return end

    keyPress("hard-key")

    local expectedChar=fullText:sub(totalCharsTyped+1,totalCharsTyped+1)
    local typedLower=string.lower(tostring(key or ""))
    local expectedLower=string.lower(expectedChar)
    if typedLower~=expectedLower then totalErrors=totalErrors+1; errorPositions[totalCharsTyped+1]=true end
    totalCharsTyped=totalCharsTyped+1

    -- Update lines
    local charOffset=0
    for i=1,#testWords.children do
        local lineDiv= testWords.children[i]
        local raw= linesRaw[i] or lineDiv.rawText
        local charsOnLine=math.min(#raw,totalCharsTyped-charOffset)
        if charsOnLine>0 then lineDiv.text=ColorizeLine(raw,charsOnLine,charOffset+1,errorPositions) end
        charOffset=charOffset+#raw
    end

    --// Complete test
    if totalCharsTyped>=#fullText then
        testActive=false
        local charOffset2=0
        for i=1,#testWords.children do
            local raw=linesRaw[i] or ""
            testWords.children[i].text=ColorizeLine(raw,#raw,charOffset2+1,errorPositions)
            charOffset2=charOffset2+#raw
        end
        dbg("TEST COMPLETE: total=%d errors=%d",totalCharsTyped,totalErrors)
        return
    end

    local timeElapsed=math.max(1,Time.now()-testStartTime)
    local cpm=(totalCharsTyped/timeElapsed)*60
    local wpm=DetermineWPM(cpm)
    local acc=DetermineAccuracy(totalCharsTyped,totalErrors)
    if wpmElement then wpmElement.text=wpm end
    if accuracyElement then accuracyElement.text=acc.."%" end
end)

--// Restart button
if restartBtn then restartBtn:on('click',StartTest) end

--// Config buttons
local function saveConfig()
   gurt.crumbs.set({
        name = "Config",
        value = cfg.timeLimit..","..cfg.wordCount..","..cfg.mode,
        days = 365
    })
end

local function loadConfig()
   local config = gurt.crumbs.get("Config")
   if config then
       local parts = {}
       for part in string.gmatch(config, "[^,]+") do
           table.insert(parts, part)
       end
       cfg.timeLimit = tonumber(parts[1]) or 60
       cfg.wordCount = tonumber(parts[2]) or 30
       cfg.mode = parts[3] or "words"
   end
end


--// Time limit buttons
time30:on('click',function()
    cfg.timeLimit=30
    time30.classList:add('active')
    time60.classList:remove('active')
    time120.classList:remove('active')
    saveConfig()
end)

time60:on('click',function()
    cfg.timeLimit=60
    time30.classList:remove('active')
    time60.classList:add('active')
    time120.classList:remove('active')
    saveConfig()
end)

time120:on('click',function()
    cfg.timeLimit=120
    time30.classList:remove('active')
    time60.classList:remove('active')
    time120.classList:add('active')
    saveConfig()
end)

--// Word count buttons

word30:on('click',function()
    cfg.wordCount=30
    word30.classList:add('active')
    word60.classList:remove('active')
    wordInf.classList:remove('active')
    saveConfig()
end)

word60:on('click',function()
    cfg.wordCount=60
    word30.classList:remove('active')
    word60.classList:add('active')
    wordInf.classList:remove('active')
    saveConfig()
end)

wordInf:on('click',function()
    cfg.wordCount=0
    word30.classList:remove('active')
    word60.classList:remove('active')
    wordInf.classList:add('active')
    saveConfig()
end)

--// Mode buttons

typeWords:on('click',function()
    cfg.mode="words"
    typeWords.classList:add('active')
    typeQuotes.classList:remove('active')
    typeNumbers.classList:remove('active')
    saveConfig()
end)
typeQuotes:on('click',function()
    cfg.mode="quotes"
    typeWords.classList:remove('active')
    typeQuotes.classList:add('active')
    typeNumbers.classList:remove('active')
    saveConfig()
end)
typeNumbers:on('click',function()
    cfg.mode="numbers"
    typeWords.classList:remove('active')
    typeQuotes.classList:remove('active')
    typeNumbers.classList:add('active')
    saveConfig()
end)

--// Messy but works
loadConfig()

if cfg.timeLimit == 30 then
    time30.classList:add('active')
elseif cfg.timeLimit == 60 then
    time60.classList:add('active')
elseif cfg.timeLimit == 120 then
    time120.classList:add('active')
end

if cfg.wordCount == 30 then
    word30.classList:add('active')
elseif cfg.wordCount == 60 then
    word60.classList:add('active')
elseif cfg.wordCount == 0 then
    wordInf.classList:add('active')
end

if cfg.mode == "words" then
    typeWords.classList:add('active')
elseif cfg.mode == "quotes" then
    typeQuotes.classList:add('active')
elseif cfg.mode == "numbers" then
    typeNumbers.classList:add('active')
end
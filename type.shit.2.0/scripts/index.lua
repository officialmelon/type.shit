--// https://docs.gurted.com/

local Words = {
    "Word",
    "word",
    "word"
}

local TestStatus = {
    renderedWords = 0,
    currentWord = 1,
    currentChar = 1
}

local wordContainer = gurt.select('#word-container')

--// Utilities

function split(s, delimiter)
    local result = {}
    delimiter = delimiter or "%s+"
    for part in string.gmatch(s, "([^"..delimiter.."]+)") do
        table.insert(result, part)
    end
    return result
end

local function hasUpperCase(str)
  return string.find(str, "%u") ~= nil
end

--// Generation

local function generateWords(wordAmount)
    local generatedWords = {}
    for i = 1, wordAmount do
        table.insert(generatedWords, Words[math.random(#Words)])
    end
    return generatedWords
end

local function sentenceRenderer(words)

    if type(words) == "string" then
        words = split(words, ' ')
    end

    for _, word in ipairs(words) do
        TestStatus.renderedWords = TestStatus.renderedWords + 1
        local wordElement = gurt.create('span', { style = 'word', id = 'word-' .. TestStatus.renderedWords })
        local charIndex = 0

        for _, cp in utf8.codes(word) do
            charIndex = charIndex + 1
            local ch = utf8.char(cp)
            local charId = 'word-' .. TestStatus.renderedWords .. '-char-' .. charIndex
            local letterElement

            if ch == 'W' or ch == '.' then --// This fixes the weird spacing issue with capital W's
                letterElement = gurt.create('h1', { style = 'text-to-type-fix-caps untyped', id = charId })
            else --// Normal characters
                letterElement = gurt.create('h1', { style = 'text-to-type untyped', id = charId })
            end

            letterElement.text = ch
            wordElement:append(letterElement)
        end

        local spacingElement = gurt.create('h1', { style = 'text-to-type-spacing', id = 'word-' .. TestStatus.renderedWords .. '-spacing' })
        spacingElement.text = '_'
        wordContainer:append(spacingElement)
        wordContainer:append(wordElement)
    end
end

--// Test Functions

local function getCurrentWord()
    if TestStatus.currentWord > TestStatus.renderedWords then
        return nil
    end
    return gurt.select('#word-' .. TestStatus.currentWord)
end

local function getCurrentChar()
    -- returns the next element the user should type (char or spacing), or nil when done
    if TestStatus.currentWord > TestStatus.renderedWords then
        return nil
    end

    while true do
        local charElement = gurt.select('#word-' .. TestStatus.currentWord .. '-char-' .. TestStatus.currentChar)
        if charElement then
            if not charElement.classList:contains('typed') then
                return charElement
            end
            -- already typed, move to next char in same word
            TestStatus.currentChar = TestStatus.currentChar + 1
        else
            -- no more chars in this word; check spacing
            local spacing = gurt.select('#word-' .. TestStatus.currentWord .. '-spacing')
            if spacing and not spacing.classList:contains('typed') then
                return spacing
            end
            -- advance to next word
            TestStatus.currentWord = TestStatus.currentWord + 1
            TestStatus.currentChar = 1
            if TestStatus.currentWord > TestStatus.renderedWords then
                return nil
            end
        end
    end
end

local function markElementAsTyped(element)
    if element then
        element.classList:remove('untyped')
        element.classList:add('typed')
    end
end

--// Initialization

sentenceRenderer('Hello World. This is a test of the sentence renderer, it should work fine.')

--// Test

gurt.body:on('keydown', function(event)
    local current = getCurrentChar()
    if not current then
        return
    end

    local expected = current.text
    local pressed = event.key
    print('Expected: ' .. expected .. ', Pressed: ' .. pressed)
    -- treat spacing underscore as expecting the space key
    if expected == '_' then
        if pressed == ' ' or pressed == 'Space' then
            markElementAsTyped(current)
            TestStatus.currentWord = TestStatus.currentWord + 1
            TestStatus.currentChar = 1
        end
        return
    end

    if hasUpperCase(pressed) and not hasUpperCase(expected) then
        pressed = string.lower(pressed) --// fixes weird ahh flumi issue
    end

    if pressed == expected then
        markElementAsTyped(current)
        TestStatus.currentChar = TestStatus.currentChar + 1
    end
end)
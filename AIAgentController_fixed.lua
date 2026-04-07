--====================================================
-- AI AGENT CONTROLLER
-- • Enter API key in-game (never hardcode)
-- • Choose AI provider: Claude / OpenAI / Groq / Gemini
-- • Executor-compatible (syn.request, http.request, etc.)
-- • Mobile + Desktop
--====================================================

local Players          = game:GetService("Players")
local HttpService      = game:GetService("HttpService")
local UserInputService = game:GetService("UserInputService")
local TweenService     = game:GetService("TweenService")

-- Forward declarations (defined later in GUI section but used earlier)
local C = Color3.fromRGB
local addLog  -- defined after log frame is created; functions that call it run after that point

local player    = Players.LocalPlayer
local character = player.Character or player.CharacterAdded:Wait()
local humanoid  = character:WaitForChild("Humanoid")
local root      = character:WaitForChild("HumanoidRootPart")

--====================================================
-- HTTP — executor + Studio compatible
--====================================================
local httpRequest = (syn and syn.request)
    or (http and http.request)
    or (fluxus and fluxus.request)
    or (pcall(function() return request end) and request)
    or nil

local function doRequest(reqTable)
    if httpRequest then
        return httpRequest(reqTable)
    else
        return HttpService:RequestAsync(reqTable)
    end
end

--====================================================
-- MOBILE DETECTION
--====================================================
local isMobile = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled

local FONT_SZ  = isMobile and 16  or 14
local HDR_H    = isMobile and 50  or 38
local INPUT_H  = isMobile and 52  or 40
local BTN_W    = isMobile and 90  or 80
local LOG_H    = isMobile and 155 or 125
local PANEL_H  = isMobile and 310 or 270

--====================================================
-- PROVIDER DEFINITIONS
--====================================================
local PROVIDERS = {
    {
        id    = "claude",
        name  = "Claude",
        label = "Anthropic",
        color = Color3.fromRGB(210, 120, 60),
        url   = "https://api.anthropic.com/v1/messages",
        model = "claude-sonnet-4-20250514",
        buildBody = function(sysPrompt, userMsg, model)
            return HttpService:JSONEncode({
                model      = model,
                max_tokens = 512,
                system     = sysPrompt,
                messages   = {{ role = "user", content = userMsg }}
            })
        end,
        buildHeaders = function(apiKey)
            return {
                ["Content-Type"]      = "application/json",
                ["x-api-key"]         = apiKey,
                ["anthropic-version"] = "2023-06-01",
            }
        end,
        parseResponse = function(body)
            local d = HttpService:JSONDecode(body)
            return d.content and d.content[1] and d.content[1].text
        end,
    },
    {
        id    = "openai",
        name  = "GPT-4o",
        label = "OpenAI",
        color = Color3.fromRGB(80, 180, 120),
        url   = "https://api.openai.com/v1/chat/completions",
        model = "gpt-4o",
        buildBody = function(sysPrompt, userMsg, model)
            return HttpService:JSONEncode({
                model    = model,
                messages = {
                    { role = "system", content = sysPrompt },
                    { role = "user",   content = userMsg   },
                }
            })
        end,
        buildHeaders = function(apiKey)
            return {
                ["Content-Type"]  = "application/json",
                ["Authorization"] = "Bearer " .. apiKey,
            }
        end,
        parseResponse = function(body)
            local d = HttpService:JSONDecode(body)
            return d.choices and d.choices[1] and d.choices[1].message and d.choices[1].message.content
        end,
    },
    {
        id    = "groq",
        name  = "Groq",
        label = "Groq (Free)",
        color = Color3.fromRGB(140, 80, 220),
        url   = "https://api.groq.com/openai/v1/chat/completions",
        model = "llama-3.3-70b-versatile",
        buildBody = function(sysPrompt, userMsg, model)
            return HttpService:JSONEncode({
                model    = model,
                messages = {
                    { role = "system", content = sysPrompt },
                    { role = "user",   content = userMsg   },
                }
            })
        end,
        buildHeaders = function(apiKey)
            return {
                ["Content-Type"]  = "application/json",
                ["Authorization"] = "Bearer " .. apiKey,
            }
        end,
        parseResponse = function(body)
            local d = HttpService:JSONDecode(body)
            return d.choices and d.choices[1] and d.choices[1].message and d.choices[1].message.content
        end,
    },
    {
        id    = "gemini",
        name  = "Gemini",
        label = "Google",
        color = Color3.fromRGB(60, 150, 230),
        url   = "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent",
        model = "gemini-2.0-flash",
        buildBody = function(sysPrompt, userMsg, model)
            return HttpService:JSONEncode({
                system_instruction = { parts = {{ text = sysPrompt }} },
                contents = {{ parts = {{ text = userMsg }} }}
            })
        end,
        buildHeaders = function(apiKey)
            return { ["Content-Type"] = "application/json" }
        end,
        -- Gemini puts key in URL not header
        buildUrl = function(baseUrl, apiKey)
            return baseUrl .. "?key=" .. apiKey
        end,
        parseResponse = function(body)
            local d = HttpService:JSONDecode(body)
            return d.candidates and d.candidates[1]
                and d.candidates[1].content
                and d.candidates[1].content.parts
                and d.candidates[1].content.parts[1]
                and d.candidates[1].content.parts[1].text
        end,
    },
}

local currentProviderIdx = 1
local currentApiKey      = ""

local function getProvider() return PROVIDERS[currentProviderIdx] end

--====================================================
-- SYSTEM PROMPT
-- FIX: Clarified walk uses studs (Roblox units), added distance field,
--      explained WalkSpeed so the AI can reason about time correctly,
--      and added sprint+distance support.
--====================================================
local SYSTEM_PROMPT = [[
You are an AI agent controlling a Roblox character.
Reply ONLY with a valid JSON array of action objects. No explanation, no markdown, no extra text.

IMPORTANT - Roblox units: 1 stud = 0.28 metres. So 1 metre = 3.57 studs.
Default WalkSpeed = 16 studs/sec. Sprint WalkSpeed = 32 studs/sec.

PARALLEL ACTIONS: Add "parallel": true to an action to run it at the SAME TIME as the next action.
Use this for things like walking while jumping, walking while spinning, etc.
The parallel action fires instantly and the queue continues immediately to the next action.

Available actions:
  { "action": "walk",    "direction": "forward"|"backward"|"left"|"right", "distance": <studs> }
  { "action": "walk",    "direction": "forward"|"backward"|"left"|"right", "duration": <seconds> }
  { "action": "sprint",  "distance": <studs> }
  { "action": "sprint",  "duration": <seconds> }
  { "action": "stop" }
  { "action": "jump" }
  { "action": "jump",    "count": <number> }
  { "action": "turn",    "degrees": <number> }  (positive=right, negative=left)
  { "action": "spin",    "rotations": <number>, "duration": <seconds> }
  { "action": "walkTo",  "x": <number>, "y": <number>, "z": <number> }
  { "action": "emote",   "name": "wave"|"dance"|"cheer" }
  { "action": "say",     "text": "<message up to 200 chars>" }
  { "action": "look",       "targetName": "<player name>" }
  { "action": "teleportTo", "targetName": "<player name>" }
  { "action": "fly",        "enable": true|false, "speed": <studs/sec, default 40>, "duration": <seconds, optional> }
  { "action": "wait",    "duration": <seconds> }
  { "action": "respawn" }

Parallel examples:
  Walk forward AND jump at the same time:
    [{"action":"walk","direction":"forward","distance":40,"parallel":true},{"action":"jump"}]
  Walk forward AND spin at the same time:
    [{"action":"walk","direction":"forward","distance":60,"parallel":true},{"action":"spin","rotations":2,"duration":3}]

Distance conversion:
  500m = 1785 studs | 10m = 36 studs | 100m sprint = 357 studs

  { "action": "dex",    "code": "<lua expression or statement>" }
    Run arbitrary Lua to read/write/manipulate any Roblox instance.
    'code' is evaluated with pcall. Use 'return expr' to get a value back.
    Examples:
      {"action":"dex","code":"workspace.Gravity = 0"}
      {"action":"dex","code":"return game.Players.LocalPlayer.Name"}
      {"action":"dex","code":"workspace:FindFirstChild('Baseplate'):Destroy()"}
      {"action":"dex","code":"for _,v in ipairs(workspace:GetChildren()) do if v:IsA('Part') then v.BrickColor = BrickColor.new('Bright red') end end"}

Rules: max 10 actions per reply. Reply must be a valid JSON array only.
Example: [{"action":"sprint","distance":60,"parallel":true},{"action":"jump"},{"action":"say","text":"woohoo!"}]
]]

--====================================================
-- QnA MODE
-- A persistent conversational AI — type questions, get answers.
-- Remembers context across messages in the same session.
--====================================================
local qnaEnabled  = false
local qnaHistory  = {}   -- { role="user"|"assistant", content=string }
local QNA_MAX_HISTORY = 20  -- keep last 20 turns

local QNA_SYSTEM = [[
You are a helpful, knowledgeable assistant embedded inside a Roblox game executor.
Answer questions clearly and directly. You can discuss:
- Roblox scripting (Lua, APIs, exploits, executor methods)
- The current game state (provided in context)
- General knowledge, coding help, game tips, anything the user asks
Keep answers concise but complete. Use plain text — no markdown headers.
If asked something about the current game, use the game state context provided.
]]

-- Detects "qna on/off" commands. Returns true if handled.
local function handleQnACommand(prompt)
    local lower = prompt:lower():match("^%s*(.-)%s*$")
    if lower == "qna on" or lower == "qna" or lower == "chat mode on" then
        qnaEnabled = true
        qnaHistory = {}
        addLog("QnA ON — ask me anything", C(255, 220, 120))
        return true
    end
    if lower == "qna off" or lower == "chat mode off" or lower == "exit qna" then
        qnaEnabled = false
        qnaHistory = {}
        addLog("QnA OFF — back to agent mode", C(200, 180, 100))
        return true
    end
    if lower == "qna clear" or lower == "clear history" then
        qnaHistory = {}
        addLog("QnA history cleared", C(180, 180, 180))
        return true
    end
    return false
end

local function askQnA(prompt, onAnswer, onError)
    task.spawn(function()
        if currentApiKey == "" then onError("No API key set!"); return end

        -- Append user message to history
        table.insert(qnaHistory, { role = "user", content = prompt })
        if #qnaHistory > QNA_MAX_HISTORY then table.remove(qnaHistory, 1) end

        -- Build message list with game state injected as first user message
        local messages = {}
        local stateCtx = { role = "user",      content = "Game context: " .. getGameState() }
        local stateAck = { role = "assistant",  content = "Got it, I have your game context." }
        table.insert(messages, stateCtx)
        table.insert(messages, stateAck)
        for _, h in ipairs(qnaHistory) do
            table.insert(messages, { role = h.role, content = h.content })
        end

        local prov    = getProvider()
        local url     = (prov.buildUrl and prov.buildUrl(prov.url, currentApiKey)) or prov.url
        local headers = prov.buildHeaders(currentApiKey)

        -- Build body with full history (multi-turn)
        local body
        if prov.id == "claude" then
            body = HttpService:JSONEncode({
                model      = prov.model,
                max_tokens = 800,
                system     = QNA_SYSTEM,
                messages   = messages,
            })
        elseif prov.id == "gemini" then
            local parts = {}
            for _, m in ipairs(messages) do
                table.insert(parts, { role = m.role == "assistant" and "model" or "user",
                    parts = {{ text = m.content }} })
            end
            body = HttpService:JSONEncode({
                system_instruction = { parts = {{ text = QNA_SYSTEM }} },
                contents = parts,
            })
        else  -- openai / groq
            local msgs = {{ role = "system", content = QNA_SYSTEM }}
            for _, m in ipairs(messages) do table.insert(msgs, m) end
            body = HttpService:JSONEncode({ model = prov.model, messages = msgs, max_tokens = 800 })
        end

        local ok, result = pcall(doRequest, { Url=url, Method="POST", Headers=headers, Body=body })
        if not ok then onError("Request failed: " .. tostring(result)); return end

        local statusCode = result.StatusCode or result.status_code or 0
        if statusCode ~= 200 then onError("API error " .. statusCode); return end

        local text = prov.parseResponse(result.Body or result.body or "")
        if not text or text:match("^%s*$") then onError("Empty response"); return end
        text = text:match("^%s*(.-)%s*$")

        -- Append assistant reply to history
        table.insert(qnaHistory, { role = "assistant", content = text })
        if #qnaHistory > QNA_MAX_HISTORY then table.remove(qnaHistory, 1) end

        onAnswer(text)
    end)
end

--====================================================
-- DEX EXPLORER ENGINE
-- Exposes the full Roblox instance tree for browsing,
-- property editing, method calls, and AI manipulation.
--====================================================

-- Safe property getter — returns value + type string
local function dexGetProps(inst)
    local props = {}
    -- Common readable properties across all instances
    local commonProps = {"Name","ClassName","Parent","Archivable"}
    -- Try to get all readable properties via reflection if available
    for _, propName in ipairs(commonProps) do
        pcall(function()
            local val = inst[propName]
            table.insert(props, { name = propName, value = tostring(val), type = typeof(val) })
        end)
    end
    -- Extended property scan for known types
    local extProps = {
        BasePart    = {"Position","Size","BrickColor","Material","Anchored","CanCollide","Transparency","CFrame"},
        Humanoid    = {"Health","MaxHealth","WalkSpeed","JumpPower","DisplayName"},
        Model       = {"PrimaryPart"},
        Script      = {"Disabled","Source"},
        LocalScript = {"Disabled"},
        StringValue = {"Value"},
        NumberValue = {"Value"},
        BoolValue   = {"Value"},
        IntValue    = {"Value"},
        Vector3Value= {"Value"},
        RemoteEvent = {},
        RemoteFunction = {},
        BindableEvent  = {},
    }
    local classProps = extProps[inst.ClassName] or {}
    for _, propName in ipairs(classProps) do
        pcall(function()
            local val = inst[propName]
            table.insert(props, { name = propName, value = tostring(val), type = typeof(val) })
        end)
    end
    return props
end

-- Execute a dex action: run 'code' string in a sandboxed pcall with inst in scope
local function dexExec(code)
    local fn, err = loadstring(code)
    if not fn then
        return false, "Syntax error: " .. tostring(err)
    end
    local ok, result = pcall(fn)
    if not ok then
        return false, "Runtime error: " .. tostring(result)
    end
    return true, tostring(result or "ok")
end

-- Recursively list children up to maxDepth
local function dexListChildren(inst, depth, maxDepth, out)
    out = out or {}
    depth = depth or 0
    maxDepth = maxDepth or 2
    if depth > maxDepth then return out end
    local ok, children = pcall(function() return inst:GetChildren() end)
    if not ok then return out end
    for _, child in ipairs(children) do
        table.insert(out, {
            indent = depth,
            name   = child.Name,
            class  = child.ClassName,
            inst   = child,
            hasChildren = #child:GetChildren() > 0,
        })
        if depth < maxDepth then
            dexListChildren(child, depth + 1, maxDepth, out)
        end
    end
    return out
end

-- Search all descendants of root for instances matching a predicate
local function dexSearch(root, predicate)
    local results = {}
    local ok, desc = pcall(function() return root:GetDescendants() end)
    if not ok then return results end
    for _, inst in ipairs(desc) do
        if pcall(predicate, inst) and predicate(inst) then
            table.insert(results, inst)
        end
    end
    return results
end

--====================================================
-- GAME STATE
--====================================================
local function getGameState()
    local pos = root and root.Position or Vector3.zero
    local nearby = {}
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= player and p.Character then
            local r = p.Character:FindFirstChild("HumanoidRootPart")
            if r and (r.Position - pos).Magnitude < 80 then
                table.insert(nearby, { name = p.Name, distance = math.floor((r.Position - pos).Magnitude) })
            end
        end
    end
    return HttpService:JSONEncode({
        position      = { x = math.floor(pos.X), y = math.floor(pos.Y), z = math.floor(pos.Z) },
        health        = humanoid and math.floor(humanoid.Health) or 0,
        maxHealth     = humanoid and humanoid.MaxHealth or 100,
        nearbyPlayers = nearby,
    })
end

--====================================================
-- CHAT LISTENER + CHATBOT ENGINE
--====================================================
local chatLog  = {}   -- { name, text, time }
local MAX_CHAT = 30

-- Chatbot state
local chatbotEnabled   = false
local chatbotWhitelist = {}   -- name -> true; if non-empty, only reply to these
local chatbotBlacklist = {}   -- name -> true; never reply to these
local chatbotCooldowns = {}   -- name -> last reply tick
local CHATBOT_COOLDOWN = 4    -- seconds between replies per player

local CHATBOT_PROMPT = [[
You are pretending to be a real Roblox player having a normal conversation in a game chat.
You MUST directly answer or respond to whatever the player just said to you.

Rules:
- ALWAYS answer the actual question or respond to the actual statement. This is the most important rule.
- If they ask what time it is, give a real time or say you don't have a clock.
- If they ask where you are from, make up a place or say you don't share that.
- If they ask your name, make up a username-style name.
- If they greet you, greet back.
- If they say something random, respond naturally to that specific thing.
- Keep replies SHORT — 1 sentence usually, 2 max. Game chat is fast-paced.
- Sound like a real player, not a formal assistant. Use casual language.
- No emojis unless the other person used them.
- Do NOT say things like "As a player..." or "In this game...".
- Do NOT mention being an AI.
- Output ONLY the reply text. Nothing else. No quotes, no labels, no explanation.

Examples:
  They say: "what time is it"     -> You say: "like 3pm for me lol"
  They say: "where u from"        -> You say: "uk why"
  They say: "how old are you"     -> You say: "19"
  They say: "do you like this game" -> You say: "its ok getting kinda bored tbh"
  They say: "hi"                  -> You say: "hey"
  They say: "wanna team up"       -> You say: "sure where are you"
]]

local function chatbotShouldReply(senderName)
    if not chatbotEnabled then return false end
    if senderName == player.Name then return false end
    if chatbotBlacklist[senderName] then return false end
    if next(chatbotWhitelist) and not chatbotWhitelist[senderName] then return false end
    local last = chatbotCooldowns[senderName] or 0
    if tick() - last < CHATBOT_COOLDOWN then return false end
    return true
end

local function chatbotReply(senderName, message)
    if not chatbotShouldReply(senderName) then return end
    chatbotCooldowns[senderName] = tick()
    if currentApiKey == "" then return end
    task.spawn(function()
        -- Build context: recent chat for conversation history, then clearly mark the new message
        local recentHistory = getChatLog(6)
        local context = "Recent chat history (for context only):\n" .. recentHistory
            .. "\n\n--- NEW MESSAGE TO REPLY TO ---"
            .. "\n" .. senderName .. ": " .. message
            .. "\n\nReply to " .. senderName .. " now:"
        callAPI(CHATBOT_PROMPT, context,
            function(reply)
                -- Strip any accidental quotes or name prefixes the AI might add
                reply = reply:gsub('^"(.*)"$', "%1")
                reply = reply:gsub("^[Yy]ou: ", "")
                reply = reply:gsub("^[Mm]e: ", "")
                reply = reply:match("^%s*(.-)%s*$") -- trim
                if reply == "" then return end
                task.wait(math.random(8, 20) * 0.1) -- 0.8-2s natural delay
                doSay(reply)
                addLog("[bot->" .. senderName .. "] " .. reply, C(180, 255, 180))
            end,
            function() end) -- silently swallow errors
    end)
end

-- Parse chatbot control commands typed into the agent box. Returns true if handled.
local function handleChatbotCommand(prompt)
    local lower = prompt:lower():match("^%s*(.-)%s*$")

    -- ── OFF ──────────────────────────────────────────────────────────
    if lower:match("^chatbot off") or lower:match("^stop chatbot")
        or lower:match("^stop chatting") or lower:match("^stop being a chatbot") then
        chatbotEnabled = false
        addLog("Chatbot OFF", C(255, 160, 100))
        return true
    end

    -- ── ON (everyone) ────────────────────────────────────────────────
    if lower == "chatbot on" or lower:match("^chatbot on$")
        or lower:match("be a chatbot for everyone")
        or lower:match("^start chatbot") or lower:match("^chatbot everyone") then
        chatbotEnabled   = true
        chatbotWhitelist = {}
        chatbotBlacklist = {}
        addLog("Chatbot ON - replying to everyone", C(100, 255, 160))
        return true
    end

    -- ── WHITELIST — "chatbot for [name]" / "whitelist [name]" / "only reply to [name]"
    -- Must come AFTER the "everyone" check above
    local wRaw = lower:match("^chatbot for (.+)")
        or lower:match("^whitelist (.+)")
        or lower:match("^only reply to (.+)")
        or lower:match("^only chat with (.+)")
        or lower:match("^be a chatbot for (.+)")
    if wRaw then
        local wName = wRaw:match("^%s*(.-)%s*$")
        for _, p in ipairs(Players:GetPlayers()) do
            if p.Name:lower():find(wName, 1, true) then
                chatbotEnabled = true
                chatbotWhitelist[p.Name] = true
                chatbotBlacklist[p.Name] = nil
                addLog("Chatbot ON - only replying to: " .. p.Name, C(100, 220, 255))
                return true
            end
        end
        -- Name not found — maybe they mis-typed; still consume the command
        addLog("Chatbot: no player found matching '" .. wName .. "'", C(255, 160, 100))
        return true
    end

    -- ── BLACKLIST — "blacklist [name]" / "ignore [name]" / "don't reply to [name]"
    local bRaw = lower:match("^blacklist (.+)")
        or lower:match("^ignore (.+)")
        or lower:match("^don'?t chat to (.+)")   or lower:match("^don'?t chat with (.+)")
        or lower:match("^don'?t reply to (.+)")  or lower:match("^don'?t reply with (.+)")
        or lower:match("^don'?t talk to (.+)")   or lower:match("^don'?t talk with (.+)")
        or lower:match("^stop chatting to (.+)")   or lower:match("^stop chatting with (.+)")
        or lower:match("^stop replying to (.+)")   or lower:match("^stop replying with (.+)")
        or lower:match("^stop talking to (.+)")    or lower:match("^stop talking with (.+)")
    if bRaw then
        local bName = bRaw:match("^%s*(.-)%s*$")
        for _, p in ipairs(Players:GetPlayers()) do
            if p.Name:lower():find(bName, 1, true) then
                chatbotBlacklist[p.Name] = true
                chatbotWhitelist[p.Name] = nil
                addLog("Chatbot: ignoring " .. p.Name .. " (blacklisted)", C(255, 160, 100))
                return true
            end
        end
        addLog("Chatbot: no player found matching '" .. bName .. "'", C(255, 160, 100))
        return true
    end

    return false
end

local function recordChat(senderName, message)
    if not senderName or message == "" then return end
    table.insert(chatLog, { name = senderName, text = message, time = tick() })
    if #chatLog > MAX_CHAT then table.remove(chatLog, 1) end
    chatbotReply(senderName, message)
end

-- Hook modern TextChatService
task.spawn(function()
    local ok = pcall(function()
        local tcs = game:GetService("TextChatService")
        tcs.MessageReceived:Connect(function(msg)
            local sender = msg.TextSource and msg.TextSource.Name or "Unknown"
            local displayName = sender
            for _, p in ipairs(Players:GetPlayers()) do
                if tostring(p.UserId) == sender then
                    displayName = p.Name
                    break
                end
            end
            recordChat(displayName, msg.Text or "")
        end)
    end)
    if not ok then
        local function hookPlayer(p)
            p.Chatted:Connect(function(msg) recordChat(p.Name, msg) end)
        end
        for _, p in ipairs(Players:GetPlayers()) do hookPlayer(p) end
        Players.PlayerAdded:Connect(hookPlayer)
    end
end)

-- Returns a formatted string of recent chat for injection into AI context
local function getChatLog(maxLines)
    maxLines = maxLines or 15
    if #chatLog == 0 then return "No recent chat." end
    local now = tick()
    local lines = {}
    -- Most recent last
    local start = math.max(1, #chatLog - maxLines + 1)
    for i = start, #chatLog do
        local entry = chatLog[i]
        local ago   = math.floor(now - entry.time)
        local label = ago < 5 and "just now" or (ago .. "s ago")
        table.insert(lines, string.format("[%s] %s: %s", label, entry.name, entry.text))
    end
    return table.concat(lines, "\n")
end

-- Patch getGameState to also include recent chat
local _baseGetGameState = getGameState
getGameState = function()
    local base = HttpService:JSONDecode(_baseGetGameState())
    base.recentChat = getChatLog(10)
    return HttpService:JSONEncode(base)
end

--====================================================
-- ACTION EXECUTOR
--====================================================
local actionQueue  = {}
local isRunning    = false
local stopFlag     = false   -- set true by "stop" to cancel any active walk/sprint

-- Helpers: safely refresh character refs
local function refreshRefs()
    character = player.Character
    if not character then return false end
    humanoid = character:FindFirstChildOfClass("Humanoid")
    root     = character:FindFirstChild("HumanoidRootPart")
    return humanoid ~= nil and root ~= nil
end

-- Get the Animator instance (works in modern Roblox & most executors)
local function getAnimator()
    if not humanoid then return nil end
    local animator = humanoid:FindFirstChildOfClass("Animator")
    if not animator then
        animator = Instance.new("Animator")
        animator.Parent = humanoid
    end
    return animator
end

-- Core movement: walk to an absolute world position at a given WalkSpeed.
-- Chunks long distances so stopFlag is checked frequently.
-- Uses MoveTo (the only reliable way to move a character in Roblox).
local CHUNK_SIZE = 50  -- studs per MoveTo chunk

local function moveToPos(targetPos, speed)
    if not refreshRefs() then return end
    humanoid.WalkSpeed = speed

    local startPos = root.Position
    local totalDist = (targetPos - startPos).Magnitude
    if totalDist < 0.5 then return end

    -- Break the path into chunks so stopFlag can interrupt mid-journey
    local dir = (targetPos - startPos).Unit
    local travelled = 0

    while travelled < totalDist and not stopFlag do
        if not refreshRefs() then break end

        local remaining = totalDist - travelled
        local chunkDist = math.min(CHUNK_SIZE, remaining)
        local chunkTarget = root.Position + dir * chunkDist

        humanoid:MoveTo(chunkTarget)

        local done = false
        local conn = humanoid.MoveToFinished:Connect(function() done = true end)
        -- Timeout = chunk distance / speed + generous buffer
        local timeout = (chunkDist / speed) * 2 + 1
        local deadline = tick() + timeout
        while not done and tick() < deadline and not stopFlag do
            task.wait(0.05)
            -- Recalculate dir each chunk in case character drifted
            if refreshRefs() then
                dir = (targetPos - root.Position).Unit
            end
        end
        pcall(function() conn:Disconnect() end)

        travelled = travelled + chunkDist
    end

    if refreshRefs() then
        humanoid.WalkSpeed = 16
    end
end

-- Direction vector in world space based on character's current facing
local function directionVec(dirName)
    if not refreshRefs() then return Vector3.new(0,0,-1) end
    -- Use root's LookVector for forward/back, RightVector for left/right
    local look  = Vector3.new(root.CFrame.LookVector.X, 0, root.CFrame.LookVector.Z).Unit
    local right = Vector3.new(root.CFrame.RightVector.X, 0, root.CFrame.RightVector.Z).Unit
    local d = (dirName or ""):lower()
    if d == "forward"  then return look
    elseif d == "backward" then return -look
    elseif d == "right"    then return right
    elseif d == "left"     then return -right
    end
    return look
end

-- Time-based movement: walk for N seconds in a direction.
-- Recalculates target every second so it keeps going straight.
local function moveForDuration(dirName, speed, duration)
    if not refreshRefs() then return end
    humanoid.WalkSpeed = speed
    local deadline = tick() + duration
    while tick() < deadline and not stopFlag do
        if not refreshRefs() then break end
        local remaining = deadline - tick()
        -- Project 1 second ahead (or remaining time) so MoveTo keeps refreshing
        local secs = math.min(1, remaining)
        local dir = directionVec(dirName)
        local target = root.Position + dir * (speed * secs)
        humanoid:MoveTo(target)
        task.wait(math.min(secs, 0.5))
    end
    if refreshRefs() then
        humanoid.WalkSpeed = 16
    end
end

-- Instant turn: just pivot the root CFrame, no loop needed.
-- PivotTo moves the whole character model without fighting physics.
local function doTurn(degrees)
    if not refreshRefs() then return end
    root:PivotTo(root.CFrame * CFrame.Angles(0, math.rad(degrees), 0))
    task.wait(0.05)
end

-- Safe say: tries TextChatService first, then legacy bubble chat
local function doSay(text)
    text = tostring(text or ""):sub(1, 200)
    -- Try modern TextChatService (default in new games)
    local ok = pcall(function()
        local tcs = game:GetService("TextChatService")
        local channel = tcs:FindFirstChild("RBXGeneral", true)
            or tcs:FindFirstChildOfClass("TextChannel")
        if channel then
            channel:SendAsync(text)
        else
            error("no channel")
        end
    end)
    -- Fallback: legacy bubble chat
    if not ok then
        pcall(function()
            game:GetService("Chat"):Chat(root, text, Enum.ChatColor.White)
        end)
    end
end

-- Play an emote animation via Animator (not the deprecated humanoid:LoadAnimation)
local function doEmote(name)
    if not refreshRefs() then return end
    local idMap = {
        wave  = "rbxassetid://507770239",
        dance = "rbxassetid://507771019",
        cheer = "rbxassetid://507770523",
    }
    local animId = idMap[tostring(name):lower()] or idMap.wave
    local animator = getAnimator()
    if not animator then return end

    local anim = Instance.new("Animation")
    anim.AnimationId = animId
    local ok, track = pcall(function() return animator:LoadAnimation(anim) end)
    if not ok or not track then return end

    track:Play()
    -- Wait for it to finish (Length may be 0 until first play, so poll)
    local waited = 0
    repeat task.wait(0.1); waited = waited + 0.1 until track.Length > 0 or waited > 0.5
    local length = track.Length > 0 and track.Length or 2
    task.wait(length)
    track:Stop()
    anim:Destroy()
end

local function executeAction(act)
    if not refreshRefs() then return end
    local aType = act.action

    -- STOP: set flag so any active moveToPos/moveForDuration loop exits
    if aType == "stop" then
        stopFlag = true
        humanoid:MoveTo(root.Position) -- cancel current MoveTo
        task.wait(0.1)
        if refreshRefs() then humanoid.WalkSpeed = 16 end

    -- WALK
    elseif aType == "walk" then
        stopFlag = false
        local dist = act.distance and tonumber(act.distance)
        local dur  = act.duration  and tonumber(act.duration)
        if dist then
            local target = root.Position + directionVec(act.direction) * dist
            moveToPos(target, 16)
        else
            moveForDuration(act.direction, 16, dur or 2)
        end

    -- SPRINT
    elseif aType == "sprint" then
        stopFlag = false
        local dist = act.distance and tonumber(act.distance)
        local dur  = act.duration  and tonumber(act.duration)
        if dist then
            local target = root.Position + directionVec(act.direction or "forward") * dist
            moveToPos(target, 32)
        else
            moveForDuration(act.direction or "forward", 32, dur or 2)
        end

    -- JUMP: wait for the character to actually leave the ground, then land
    elseif aType == "jump" then
        local count = math.max(1, math.min(tonumber(act.count) or 1, 10))
        for i = 1, count do
            if not refreshRefs() then break end
            humanoid.Jump = true
            -- Wait until airborne
            local airborne = false
            local t0 = tick()
            repeat task.wait(0.05) until
                (humanoid.FloorMaterial == Enum.Material.Air) or (tick()-t0 > 0.4)
            -- Wait until landed again
            t0 = tick()
            repeat task.wait(0.05) until
                (humanoid.FloorMaterial ~= Enum.Material.Air) or (tick()-t0 > 2)
            if i < count then task.wait(0.15) end
        end

    -- TURN: instant pivot using PivotTo
    elseif aType == "turn" then
        doTurn(tonumber(act.degrees) or 90)

    -- SPIN: repeated small turns over a duration at ~60fps
    elseif aType == "spin" then
        if not refreshRefs() then return end
        local rotations = tonumber(act.rotations) or 1
        local dur       = math.max(0.1, tonumber(act.duration) or 1)
        local totalDeg  = rotations * 360
        local steps     = math.max(1, math.floor(dur / 0.016))
        local perStep   = totalDeg / steps
        for _ = 1, steps do
            if not refreshRefs() then break end
            root:PivotTo(root.CFrame * CFrame.Angles(0, math.rad(perStep), 0))
            task.wait(0.016)
        end

    -- WALK TO: reuse moveToPos so it gets chunking + stopFlag + speed
    elseif aType == "walkTo" then
        stopFlag = false
        if not refreshRefs() then return end
        local target = Vector3.new(
            tonumber(act.x) or root.Position.X,
            tonumber(act.y) or root.Position.Y,
            tonumber(act.z) or root.Position.Z)
        moveToPos(target, 16)

    -- EMOTE via Animator
    elseif aType == "emote" then
        doEmote(act.name)

    -- SAY via TextChatService or legacy Chat
    elseif aType == "say" then
        doSay(act.text)

    -- LOOK AT PLAYER
    elseif aType == "look" then
        local targetName = tostring(act.targetName or ""):lower()
        for _, p in ipairs(Players:GetPlayers()) do
            if p.Name:lower() == targetName then
                local r = p.Character and p.Character:FindFirstChild("HumanoidRootPart")
                if r and refreshRefs() then
                    root:PivotTo(CFrame.new(root.Position,
                        Vector3.new(r.Position.X, root.Position.Y, r.Position.Z)))
                end
                break
            end
        end
        task.wait(0.1)

    -- WAIT
    elseif aType == "wait" then
        task.wait(math.clamp(tonumber(act.duration) or 1, 0.05, 30))

    -- TELEPORT TO PLAYER: instantly move to a named player's position
    elseif aType == "teleportTo" then
        local targetName = tostring(act.targetName or ""):lower()
        local found = false
        for _, p in ipairs(Players:GetPlayers()) do
            if p.Name:lower():find(targetName, 1, true) then
                local r = p.Character and p.Character:FindFirstChild("HumanoidRootPart")
                if r and refreshRefs() then
                    root.CFrame = r.CFrame * CFrame.new(0, 3, 0)
                    addLog("Teleported to " .. p.Name, C(100, 255, 200))
                    found = true
                end
                break
            end
        end
        if not found then
            addLog("Player not found: " .. tostring(act.targetName), C(255, 150, 80))
        end
        task.wait(0.1)

    -- FLY: toggle flight mode using BodyVelocity + RunService (camera-direction)
    elseif aType == "fly" then
        if not refreshRefs() then return end
        local enable = act.enable
        if enable == nil then enable = true end  -- default: enable fly

        -- Clean up any existing fly state first
        local existingVel = root:FindFirstChild("__FlyVelocity")
        if existingVel then existingVel:Destroy() end
        local existingConn = _G.__FlyConnection
        if existingConn then existingConn:Disconnect(); _G.__FlyConnection = nil end
        _G.__FlyActive = false

        if enable then
            local flySpeed = tonumber(act.speed) or 50
            local vel = Instance.new("BodyVelocity")
            vel.Name = "__FlyVelocity"
            vel.MaxForce = Vector3.new(math.huge, math.huge, math.huge)
            vel.Velocity = Vector3.zero
            vel.Parent = root
            _G.__FlyActive = true
            _G.__FlyConnection = game:GetService("RunService").RenderStepped:Connect(function()
                if not _G.__FlyActive then return end
                if not root or not root.Parent then
                    _G.__FlyConnection:Disconnect()
                    _G.__FlyConnection = nil
                    return
                end
                vel.Velocity = workspace.CurrentCamera.CFrame.LookVector * flySpeed
            end)
            -- Auto-stop after duration if specified
            local duration = tonumber(act.duration)
            if duration then
                task.delay(duration, function()
                    if _G.__FlyActive then
                        _G.__FlyActive = false
                        if _G.__FlyConnection then _G.__FlyConnection:Disconnect(); _G.__FlyConnection = nil end
                        local v = root:FindFirstChild("__FlyVelocity")
                        if v then v:Destroy() end
                        addLog("Fly OFF (timer)", C(255, 180, 100))
                    end
                end)
            end
            addLog("Fly ON" .. (duration and (" for " .. duration .. "s") or ""), C(100, 220, 255))
        else
            addLog("Fly OFF", C(255, 180, 100))
        end
        task.wait(0.05)


    -- DEX: run arbitrary Lua code — full access to game tree
    elseif aType == "dex" then
        local code = tostring(act.code or "")
        if code == "" then
            addLog("dex: no code provided", C(255,150,80))
        else
            local ok, result = dexExec(code)
            if ok then
                addLog("dex: " .. (result ~= "nil" and result or "ok"), C(180, 255, 220))
            else
                addLog("dex ERR: " .. result, C(255, 100, 100))
            end
        end

    -- RESPAWN: Humanoid.Health = 0 is the only reliable client-side method.
    -- It triggers the death + respawn cycle natively, no server call needed.
    elseif aType == "respawn" then
        if refreshRefs() then
            humanoid.Health = 0
        end
        task.wait(0.5)
        local oldChar = character
        local t0 = tick()
        repeat task.wait(0.1) until player.Character ~= oldChar or tick()-t0 > 5
        task.wait(1.5) -- let respawn finish loading
        refreshRefs()
    end
end

-- runQueue supports parallel groups.
-- Actions tagged "parallel": true run concurrently alongside the next action.
-- Actions without it (or "parallel": false) block until complete.
-- Example: walk forward + jump at the same time:
--   [{"action":"walk","direction":"forward","distance":50,"parallel":true},{"action":"jump"}]
local function runQueue()
    if isRunning then return end
    isRunning = true
    task.spawn(function()
        while #actionQueue > 0 do
            local act = table.remove(actionQueue, 1)
            if act.parallel then
                -- Fire and forget — don't wait for it
                task.spawn(function()
                    local ok, err = pcall(executeAction, act)
                    if not ok then warn("Parallel action error:", err) end
                end)
                task.wait(0.02)
            else
                -- Sequential — wait for it to fully complete
                local ok, err = pcall(executeAction, act)
                if not ok then warn("Action error:", err) end
                task.wait(0.02)
            end
        end
        isRunning = false
    end)
end

--====================================================
-- JSON ARRAY EXTRACTOR
-- FIX: replaced greedy/lazy single regex with a proper bracket-balanced
--      extractor so nested objects inside the array don't get truncated.
--====================================================
local function extractJsonArray(text)
    local startPos = text:find("%[")
    if not startPos then return nil end

    local depth = 0
    local inStr = false
    local escape = false

    for i = startPos, #text do
        local ch = text:sub(i, i)
        if escape then
            escape = false
        elseif ch == "\\" and inStr then
            escape = true
        elseif ch == '"' then
            inStr = not inStr
        elseif not inStr then
            if ch == "[" or ch == "{" then
                depth = depth + 1
            elseif ch == "]" or ch == "}" then
                depth = depth - 1
                if depth == 0 then
                    return text:sub(startPos, i)
                end
            end
        end
    end
    return nil
end

--====================================================
-- CHAT ANSWER PROMPT
-- Used when the player asks about what someone said,
-- a language, or wants a translation. Returns plain text.
--====================================================
local CHAT_PROMPT = [[
You are a helpful assistant embedded in a Roblox game. The player is asking about something related to the in-game chat log.

You have access to the recent chat history and game state provided.

Rules:
- Answer conversationally in plain English. No JSON, no bullet points unless it genuinely helps.
- If asked to translate, identify the language first, then give the translation.
- If asked what someone said, summarise or quote their recent messages.
- If asked what language someone is speaking, identify it.
- If the chat log has no relevant messages, say so honestly.
- Keep answers short and direct (1-4 sentences).
]]

-- Heuristic: is this prompt a question about chat / what players said?
local CHAT_KEYWORDS = {
    "what.*say", "what.*said", "saying", "translat", "what language",
    "what does.*mean", "what did", "what is.*saying", "what was",
    "speak", "talking about", "telling", "tell me what", "understand",
    "mean in english", "in english", "foreign", "language",
}
local function isChatQuestion(prompt)
    local lower = prompt:lower()
    for _, kw in ipairs(CHAT_KEYWORDS) do
        if lower:match(kw) then return true end
    end
    return false
end

--====================================================
-- TRANSLATOR SYSTEM PROMPT
-- Stage 1: rewrites casual/vague input into a precise
-- instruction the action AI can understand unambiguously.
--====================================================
local TRANSLATE_PROMPT = [[
You are a Roblox game-context interpreter. Your only job is to rewrite a player's casual, vague, or shorthand command into a single clear, precise instruction that another AI can act on.

You have access to the current game state (player position, health, nearby players with distances).

Rules:
- Output ONLY the rewritten instruction. No explanation, no prefix, no quotes.
- Resolve vague references using the game state:
    "that guy" / "him" / "the guy" / "someone" / "the player" / "them"
      → use the nearest player's name and position from nearbyPlayers
    "over there" / "that way" / "forward a bit"
      → convert to approximate studs or a direction
    "a bit" / "a little" / "kinda far"
      → infer a reasonable distance (e.g. "a bit" = ~20 studs, "kinda far" = ~100 studs)
    "spin" / "do a spin" / "twirl"
      → "spin 1 rotation over 0.8 seconds"
    "dance" / "wave" / "cheer"
      → "emote [name]"
    "say hi" / "say something" / "greet"
      → "say [appropriate short phrase]"
    "reset" / "kill yourself" / "respawn"
      → "respawn"
    "teleport to [name]" / "tp to [name]" / "go to [name]"
      → "teleportTo [name]"
    "fly" / "start flying" / "enable fly"
      → "fly enable"
    "stop flying" / "land" / "no fly"
      → "fly disable"
    "fly for 10 seconds"
      → "fly for 10 seconds"
- Keep units in metres (the action AI will convert to studs).
- If the command is already clear and precise, output it unchanged.
- Never refuse. Always produce a usable instruction.

Examples:
  Input:  "walk to that guy"
  State:  nearbyPlayers = [{name:"Bob", distance:45}]
  Output: walk toward Bob who is 45 studs away (walkTo his position)

  Input:  "jump like 3 times"
  Output: jump 3 times

  Input:  "go spin around"
  Output: spin 2 rotations over 1.2 seconds

  Input:  "say hi to everyone"
  Output: say "Hey everyone!"

  Input:  "run forward a bit"
  Output: sprint forward 20 studs
]]

--====================================================
-- LOW-LEVEL API CALL (single request, returns raw text)
--====================================================
local function callAPI(systemPrompt, userMsg, onDone, onError)
    if currentApiKey == "" then onError("No API key set! Open settings."); return end
    local prov    = getProvider()
    local url     = (prov.buildUrl and prov.buildUrl(prov.url, currentApiKey)) or prov.url
    local body    = prov.buildBody(systemPrompt, userMsg, prov.model)
    local headers = prov.buildHeaders(currentApiKey)

    local ok, result = pcall(doRequest, { Url=url, Method="POST", Headers=headers, Body=body })
    if not ok then onError("Request failed: " .. tostring(result)); return end

    local statusCode = result.StatusCode or result.status_code or 0
    if statusCode == 400 then onError("400 Bad Request — check API key format"); return end
    if statusCode == 401 then onError("401 Unauthorized — wrong API key"); return end
    if statusCode == 403 then onError("403 Forbidden — key lacks permission"); return end
    if statusCode == 429 then onError("429 Rate limited — slow down"); return end
    if statusCode ~= 200 then onError("API error " .. statusCode); return end

    local rawBody = result.Body or result.body or ""
    local text = prov.parseResponse(rawBody)
    if not text or text:match("^%s*$") then onError("Empty response from AI"); return end

    onDone(text:match("^%s*(.-)%s*$")) -- trim whitespace
end

--====================================================
-- API CALL (two-stage: translate → act)
--====================================================
local function askAI(prompt, onResult, onError, onTranslated)
    task.spawn(function()
        local state = getGameState()

        -- ── Chat question fast-path ───────────────────────────────────
        -- If the prompt is asking about what someone said / language / translate,
        -- skip action generation entirely and just answer in plain text.
        if isChatQuestion(prompt) then
            local chatMsg = "Game state (includes recentChat):\n" .. state
                .. "\n\nRecent chat log:\n" .. getChatLog(20)
                .. "\n\nPlayer question: " .. prompt
            callAPI(CHAT_PROMPT, chatMsg,
                function(answer)
                    -- Surface the answer as a log line, not as actions
                    onResult({})           -- empty action list so queue doesn't stall
                    onTranslated(answer)   -- reuse the translated slot to print the answer
                end,
                onError)
            return
        end

        -- ── Stage 1: Translate casual input ──────────────────────────
        local translated = prompt  -- fallback: use original if translate fails
        local translateMsg = "Game state: " .. state .. "\n\nPlayer said: " .. prompt

        local tok, terr = nil, nil
        callAPI(TRANSLATE_PROMPT, translateMsg,
            function(t) tok = t end,
            function(e) terr = e end)

        -- callAPI is synchronous inside task.spawn, but we need to wait for it.
        -- Since doRequest yields, tok/terr will be set by the time we reach here.
        if tok then
            translated = tok
            if onTranslated then onTranslated(translated) end
        end
        -- If translation failed, silently proceed with original prompt.

        -- ── Stage 2: Generate actions from translated instruction ─────
        local userMsg = "Game state: " .. state .. "\n\nRequest: " .. translated

        callAPI(SYSTEM_PROMPT, userMsg,
            function(text)
                text = text:gsub("```json",""):gsub("```","")
                local extracted = extractJsonArray(text)
                if not extracted then
                    onError("AI returned no JSON array — try again")
                    return
                end
                local aok, actions = pcall(HttpService.JSONDecode, HttpService, extracted)
                if aok and type(actions) == "table" then
                    onResult(actions)
                else
                    onError("AI returned bad JSON — try again")
                end
            end,
            onError)
    end)
end

--====================================================
-- SCREEN GUI
--====================================================
local gui = Instance.new("ScreenGui")
gui.Name           = "AIAgentUI"
gui.ResetOnSpawn   = false
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.IgnoreGuiInset = true
gui.Parent         = player:WaitForChild("PlayerGui")

-- colour helpers (C already declared at top of file)
local DARK   = C(7, 8, 18)
local CYAN   = C(0, 215, 255)
local DIM    = C(40, 50, 70)

--====================================================
-- ESP SYSTEM
-- • Highlight outlines (BoxESP / Chams via SelectionBox)
-- • Per-player BillboardGui with Name / Distance / Health
-- • Fully RGB-cycle capable (rainbow mode)
-- • Toggle via button OR type "esp on/off" in the input box
-- • Team filter: "esp team on/off" skips teammates
--====================================================

local RunService = game:GetService("RunService")

-- ── Config (edit these defaults) ──────────────────────────────────────────
local ESP_CFG = {
    enabled       = false,
    showName      = true,
    showDistance  = true,
    showHealth    = true,
    teamFilter    = false,   -- if true, skip players on same Team as you
    rainbow       = false,   -- cycle hue over time
    color         = Color3.fromRGB(255, 60, 60),   -- default red
    boxColor      = Color3.fromRGB(255, 60, 60),
    textColor     = Color3.fromRGB(255, 255, 255),
    outlineThick  = 3,       -- SelectionBox line thickness (1-5)
    maxDist       = 1000,    -- studs; players beyond this are hidden
}

-- ── State ──────────────────────────────────────────────────────────────────
local espObjects   = {}   -- [player] = { box, billboard, labels }
local espContainer = Instance.new("Folder")
espContainer.Name   = "ESPContainer"
espContainer.Parent = player:WaitForChild("PlayerGui")

-- ── Rainbow hue ticker ────────────────────────────────────────────────────
local rainbowHue = 0

local function getRainbowColor()
    rainbowHue = (rainbowHue + 0.003) % 1
    return Color3.fromHSV(rainbowHue, 1, 1)
end

-- ── Create ESP for a single player ────────────────────────────────────────
local function createESP(target)
    if target == player then return end
    if espObjects[target] then return end   -- already exists

    local char = target.Character
    if not char then return end
    local rootPart = char:FindFirstChild("HumanoidRootPart")
    if not rootPart then return end

    -- SelectionBox outline (acts as a "chams" / box highlight)
    local box = Instance.new("SelectionBox")
    box.Adornee          = char
    box.LineThickness    = ESP_CFG.outlineThick
    box.Color3           = ESP_CFG.color
    box.SurfaceColor3    = ESP_CFG.color
    box.SurfaceTransparency = 0.85
    box.Parent           = espContainer

    -- BillboardGui for text labels
    local billboard = Instance.new("BillboardGui")
    billboard.Adornee         = rootPart
    billboard.AlwaysOnTop     = true
    billboard.Size            = UDim2.new(0, 200, 0, 90)
    billboard.StudsOffset     = Vector3.new(0, 3.2, 0)
    billboard.LightInfluence  = 0
    billboard.Parent          = espContainer

    -- Name label
    local nameLabel = Instance.new("TextLabel")
    nameLabel.Size             = UDim2.new(1, 0, 0, 22)
    nameLabel.Position         = UDim2.new(0, 0, 0, 0)
    nameLabel.BackgroundTransparency = 1
    nameLabel.Font             = Enum.Font.GothamBold
    nameLabel.TextColor3       = ESP_CFG.textColor
    nameLabel.TextStrokeTransparency = 0.4
    nameLabel.TextSize         = 15
    nameLabel.Text             = target.DisplayName ~= "" and target.DisplayName or target.Name
    nameLabel.Parent           = billboard

    -- Distance label
    local distLabel = Instance.new("TextLabel")
    distLabel.Size             = UDim2.new(1, 0, 0, 18)
    distLabel.Position         = UDim2.new(0, 0, 0, 24)
    distLabel.BackgroundTransparency = 1
    distLabel.Font             = Enum.Font.Code
    distLabel.TextColor3       = C(180, 230, 255)
    distLabel.TextStrokeTransparency = 0.4
    distLabel.TextSize         = 13
    distLabel.Text             = ""
    distLabel.Parent           = billboard

    -- Health bar background
    local hpBg = Instance.new("Frame")
    hpBg.Size             = UDim2.new(0, 100, 0, 8)
    hpBg.Position         = UDim2.new(0.5, -50, 0, 48)
    hpBg.BackgroundColor3 = C(40, 40, 40)
    hpBg.BorderSizePixel  = 0
    hpBg.Parent           = billboard
    Instance.new("UICorner", hpBg).CornerRadius = UDim.new(0, 4)

    -- Health bar fill
    local hpFill = Instance.new("Frame")
    hpFill.Size             = UDim2.new(1, 0, 1, 0)
    hpFill.BackgroundColor3 = C(60, 220, 60)
    hpFill.BorderSizePixel  = 0
    hpFill.Parent           = hpBg
    Instance.new("UICorner", hpFill).CornerRadius = UDim.new(0, 4)

    -- HP text
    local hpText = Instance.new("TextLabel")
    hpText.Size             = UDim2.new(1, 0, 0, 16)
    hpText.Position         = UDim2.new(0, 0, 0, 58)
    hpText.BackgroundTransparency = 1
    hpText.Font             = Enum.Font.Code
    hpText.TextColor3       = C(100, 255, 100)
    hpText.TextStrokeTransparency = 0.4
    hpText.TextSize         = 12
    hpText.Text             = ""
    hpText.Parent           = billboard

    espObjects[target] = {
        box      = box,
        billboard= billboard,
        nameLabel= nameLabel,
        distLabel= distLabel,
        hpBg     = hpBg,
        hpFill   = hpFill,
        hpText   = hpText,
    }
end

-- ── Destroy ESP for one player ────────────────────────────────────────────
local function removeESP(target)
    local obj = espObjects[target]
    if not obj then return end
    pcall(function() obj.box:Destroy() end)
    pcall(function() obj.billboard:Destroy() end)
    espObjects[target] = nil
end

-- ── Destroy all ESP objects ───────────────────────────────────────────────
local function clearAllESP()
    for target in pairs(espObjects) do
        removeESP(target)
    end
end

-- ── Rebuild ESP for all current players ──────────────────────────────────
local function rebuildESP()
    clearAllESP()
    if not ESP_CFG.enabled then return end
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= player then
            createESP(p)
        end
    end
end

-- ── Toggle ESP on/off ────────────────────────────────────────────────────
local function setESP(on)
    ESP_CFG.enabled = on
    if on then
        rebuildESP()
    else
        clearAllESP()
    end
end

-- ── Per-frame update loop ─────────────────────────────────────────────────
local espUpdateConn
local function startESPLoop()
    if espUpdateConn then return end
    espUpdateConn = RunService.Heartbeat:Connect(function()
        if not ESP_CFG.enabled then return end

        local myRoot = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
        local myPos  = myRoot and myRoot.Position or Vector3.zero

        local activeColor = ESP_CFG.rainbow and getRainbowColor() or ESP_CFG.color

        for target, obj in pairs(espObjects) do
            -- Safety: clean up if player left
            if not target.Parent then
                removeESP(target)
                goto continue
            end

            local char  = target.Character
            local hum   = char and char:FindFirstChildOfClass("Humanoid")
            local root  = char and char:FindFirstChild("HumanoidRootPart")

            -- Hide if no character or exceeds max distance
            local dist = root and (root.Position - myPos).Magnitude or math.huge
            local visible = char ~= nil and dist <= ESP_CFG.maxDist

            -- Team filter
            if visible and ESP_CFG.teamFilter then
                local myTeam  = player.Team
                local tgtTeam = target.Team
                if myTeam and tgtTeam and myTeam == tgtTeam then
                    visible = false
                end
            end

            obj.box.Visible       = visible
            obj.billboard.Enabled = visible

            if visible then
                -- Update adornee in case character respawned
                obj.box.Adornee   = char
                local newRoot = char:FindFirstChild("HumanoidRootPart")
                if newRoot then obj.billboard.Adornee = newRoot end

                -- Apply colour
                obj.box.Color3        = activeColor
                obj.box.SurfaceColor3 = activeColor

                -- Name
                obj.nameLabel.Visible   = ESP_CFG.showName
                obj.nameLabel.TextColor3 = activeColor

                -- Distance
                obj.distLabel.Visible = ESP_CFG.showDistance
                if ESP_CFG.showDistance then
                    obj.distLabel.Text = string.format("%.0f studs", dist)
                end

                -- Health
                obj.hpBg.Visible   = ESP_CFG.showHealth
                obj.hpText.Visible = ESP_CFG.showHealth
                if ESP_CFG.showHealth and hum then
                    local pct = math.clamp(hum.Health / math.max(hum.MaxHealth, 1), 0, 1)
                    obj.hpFill.Size = UDim2.new(pct, 0, 1, 0)
                    -- Colour: green → yellow → red
                    local r = math.floor(255 * (1 - pct))
                    local g = math.floor(255 * pct)
                    obj.hpFill.BackgroundColor3 = C(r, g, 30)
                    obj.hpText.Text = string.format("HP %d/%d", math.floor(hum.Health), math.floor(hum.MaxHealth))
                end
            end

            ::continue::
        end
    end)
end

startESPLoop()

-- Hook player join/leave/respawn
Players.PlayerAdded:Connect(function(p)
    if ESP_CFG.enabled then
        p.CharacterAdded:Connect(function()
            task.wait(0.5)
            removeESP(p)
            createESP(p)
        end)
        task.wait(0.5)
        createESP(p)
    end
end)

Players.PlayerRemoving:Connect(function(p)
    removeESP(p)
end)

-- Also hook respawns for existing players
for _, p in ipairs(Players:GetPlayers()) do
    if p ~= player then
        p.CharacterAdded:Connect(function()
            task.wait(0.5)
            removeESP(p)
            if ESP_CFG.enabled then createESP(p) end
        end)
    end
end

-- ── ESP command handler (typed in the input box) ──────────────────────────
local function handleESPCommand(prompt)
    local lower = prompt:lower():match("^%s*(.-)%s*$")

    if lower == "esp on"  or lower == "esp" then
        setESP(true)
        addLog("ESP ON", C(0, 255, 180))
        return true
    end
    if lower == "esp off" then
        setESP(false)
        addLog("ESP OFF", C(255, 160, 100))
        return true
    end
    if lower == "esp rainbow" or lower == "esp rgb" then
        ESP_CFG.rainbow = true
        addLog("ESP Rainbow/RGB enabled", C(255, 150, 255))
        return true
    end
    if lower == "esp rainbow off" or lower == "esp rgb off" then
        ESP_CFG.rainbow = false
        addLog("ESP Rainbow/RGB disabled", C(200, 200, 200))
        return true
    end
    if lower == "esp name off"   then ESP_CFG.showName     = false; addLog("ESP names hidden",    C(200,200,200)); return true end
    if lower == "esp name on"    then ESP_CFG.showName     = true;  addLog("ESP names shown",     C(200,255,200)); return true end
    if lower == "esp dist off"   then ESP_CFG.showDistance = false; addLog("ESP distance hidden", C(200,200,200)); return true end
    if lower == "esp dist on"    then ESP_CFG.showDistance = true;  addLog("ESP distance shown",  C(200,255,200)); return true end
    if lower == "esp health off" then ESP_CFG.showHealth   = false; addLog("ESP health hidden",   C(200,200,200)); return true end
    if lower == "esp health on"  then ESP_CFG.showHealth   = true;  addLog("ESP health shown",    C(200,255,200)); return true end
    if lower == "esp team on"    then ESP_CFG.teamFilter   = true;  addLog("ESP team filter ON",  C(100,200,255)); return true end
    if lower == "esp team off"   then ESP_CFG.teamFilter   = false; addLog("ESP team filter OFF", C(200,200,200)); return true end

    -- Custom colour: "esp color R G B"  e.g. "esp color 0 255 100"
    local r, g, b = lower:match("^esp colou?r%s+(%d+)%s+(%d+)%s+(%d+)")
    if r then
        ESP_CFG.color = C(tonumber(r), tonumber(g), tonumber(b))
        ESP_CFG.rainbow = false
        addLog(string.format("ESP colour → RGB(%s,%s,%s)", r, g, b), ESP_CFG.color)
        return true
    end

    return false
end

--====================================================
-- FLOATING TRIGGER BUTTON (mobile)
--====================================================
local triggerBtn
if isMobile then
    triggerBtn = Instance.new("TextButton")
    triggerBtn.Size             = UDim2.new(0, 68, 0, 68)
    triggerBtn.Position         = UDim2.new(1, -84, 0.5, -34)
    triggerBtn.BackgroundColor3 = C(0, 145, 205)
    triggerBtn.BorderSizePixel  = 0
    triggerBtn.Font             = Enum.Font.GothamBold
    triggerBtn.TextColor3       = C(255,255,255)
    triggerBtn.Text             = "🤖"
    triggerBtn.TextSize         = 30
    triggerBtn.ZIndex           = 20
    triggerBtn.Parent           = gui
    Instance.new("UICorner", triggerBtn).CornerRadius = UDim.new(0,18)
    local ts = Instance.new("UIStroke", triggerBtn)
    ts.Color = CYAN; ts.Thickness = 2.5
end

--====================================================
-- MAIN PANEL
--====================================================
local panel = Instance.new("Frame")
panel.BackgroundColor3 = DARK
panel.BorderSizePixel  = 0
panel.ClipsDescendants = true
panel.ZIndex           = 10

if isMobile then
    panel.Size     = UDim2.new(0.96, 0, 0, PANEL_H)
    panel.Position = UDim2.new(0.02, 0, 1, 10)
else
    panel.Size     = UDim2.new(0, 530, 0, PANEL_H)
    panel.Position = UDim2.new(0.5, -265, 1, -(PANEL_H + 22))
end
panel.Parent = gui
Instance.new("UICorner", panel).CornerRadius = UDim.new(0,14)
local pStroke = Instance.new("UIStroke", panel)
pStroke.Color = CYAN; pStroke.Thickness = isMobile and 2.2 or 1.5; pStroke.Transparency = 0.2

-- Panel open/close
local panelOpen = not isMobile

local function setPanelOpen(open)
    panelOpen = open
    local yOpen  = isMobile and UDim2.new(0.02,0,1,-(PANEL_H+22)) or UDim2.new(0.5,-265,1,-(PANEL_H+22))
    local yClose = isMobile and UDim2.new(0.02,0,1,10)             or UDim2.new(0.5,-265,1,10)
    TweenService:Create(panel, TweenInfo.new(0.3, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
        { Position = open and yOpen or yClose }):Play()
    if triggerBtn then triggerBtn.Text = open and "✕" or "🤖" end
end

if triggerBtn then
    triggerBtn.MouseButton1Click:Connect(function() setPanelOpen(not panelOpen) end)
end

--====================================================
-- HEADER
--====================================================
local header = Instance.new("Frame")
header.Size               = UDim2.new(1,0,0,HDR_H)
header.BackgroundColor3   = C(0,150,200)
header.BackgroundTransparency = 0.70
header.BorderSizePixel    = 0
header.ZIndex             = 11
header.Parent             = panel

local headerLbl = Instance.new("TextLabel")
headerLbl.Size             = UDim2.new(1,-120,1,0)
headerLbl.Position         = UDim2.new(0,14,0,0)
headerLbl.BackgroundTransparency = 1
headerLbl.Font             = Enum.Font.Code
headerLbl.TextColor3       = CYAN
headerLbl.TextSize         = isMobile and 16 or 14
headerLbl.TextXAlignment   = Enum.TextXAlignment.Left
headerLbl.Text             = "◈  AI AGENT"
headerLbl.ZIndex           = 12
headerLbl.Parent           = header

-- Settings button
local settingsBtn = Instance.new("TextButton")
settingsBtn.Size            = UDim2.new(0, isMobile and 48 or 32, 0, isMobile and 40 or 28)
settingsBtn.Position        = UDim2.new(1, isMobile and -100 or -78, 0, isMobile and 5 or 5)
settingsBtn.BackgroundColor3 = C(0,170,210)
settingsBtn.BackgroundTransparency = 0.45
settingsBtn.BorderSizePixel = 0
settingsBtn.Font            = Enum.Font.GothamBold
settingsBtn.TextColor3      = C(255,255,255)
settingsBtn.Text            = "⚙"
settingsBtn.TextSize        = isMobile and 20 or 15
settingsBtn.ZIndex          = 13
settingsBtn.Parent          = panel
Instance.new("UICorner", settingsBtn).CornerRadius = UDim.new(0,8)

-- Close button
local closeBtn = Instance.new("TextButton")
closeBtn.Size            = UDim2.new(0, isMobile and 48 or 30, 0, isMobile and 40 or 28)
closeBtn.Position        = UDim2.new(1, isMobile and -52 or -38, 0, isMobile and 5 or 5)
closeBtn.BackgroundColor3 = C(180, 50, 50)
closeBtn.BackgroundTransparency = 0.45
closeBtn.BorderSizePixel = 0
closeBtn.Font            = Enum.Font.GothamBold
closeBtn.TextColor3      = C(255,255,255)
closeBtn.Text            = "✕"
closeBtn.TextSize        = isMobile and 20 or 14
closeBtn.ZIndex          = 13
closeBtn.Parent          = panel
Instance.new("UICorner", closeBtn).CornerRadius = UDim.new(0,8)
closeBtn.MouseButton1Click:Connect(function() setPanelOpen(false) end)

-- Provider badge (top-right of header)
local providerBadge = Instance.new("TextLabel")
providerBadge.Size             = UDim2.new(0, 90, 0, 22)
providerBadge.Position         = UDim2.new(0, 110, 0.5, -11)
providerBadge.BackgroundColor3 = getProvider().color
providerBadge.BackgroundTransparency = 0.3
providerBadge.BorderSizePixel  = 0
providerBadge.Font             = Enum.Font.GothamBold
providerBadge.TextColor3       = C(255,255,255)
providerBadge.TextSize         = 12
providerBadge.Text             = getProvider().name
providerBadge.ZIndex           = 13
providerBadge.Parent           = header
Instance.new("UICorner", providerBadge).CornerRadius = UDim.new(0,6)

--====================================================
-- SETTINGS PANEL (overlay inside main panel)
--====================================================
local settingsFrame = Instance.new("Frame")
settingsFrame.Size             = UDim2.new(1,0,1,0)
settingsFrame.BackgroundColor3 = C(5,6,15)
settingsFrame.BackgroundTransparency = 0.05
settingsFrame.BorderSizePixel  = 0
settingsFrame.ZIndex           = 20
settingsFrame.Visible          = false
settingsFrame.Parent           = panel
Instance.new("UICorner", settingsFrame).CornerRadius = UDim.new(0,14)

-- Settings title
local setTitle = Instance.new("TextLabel")
setTitle.Size             = UDim2.new(1,-20,0,36)
setTitle.Position         = UDim2.new(0,10,0,8)
setTitle.BackgroundTransparency = 1
setTitle.Font             = Enum.Font.GothamBold
setTitle.TextColor3       = CYAN
setTitle.TextSize         = isMobile and 18 or 15
setTitle.TextXAlignment   = Enum.TextXAlignment.Left
setTitle.Text             = "⚙  Settings"
setTitle.ZIndex           = 21
setTitle.Parent           = settingsFrame

-- Close settings
local setClose = Instance.new("TextButton")
setClose.Size            = UDim2.new(0, isMobile and 44 or 28, 0, isMobile and 34 or 26)
setClose.Position        = UDim2.new(1, isMobile and -52 or -36, 0, 6)
setClose.BackgroundColor3 = C(180,50,50)
setClose.BackgroundTransparency = 0.4
setClose.BorderSizePixel = 0
setClose.Font            = Enum.Font.GothamBold
setClose.TextColor3      = C(255,255,255)
setClose.Text            = "✕"
setClose.TextSize        = isMobile and 18 or 13
setClose.ZIndex          = 22
setClose.Parent          = settingsFrame
Instance.new("UICorner", setClose).CornerRadius = UDim.new(0,7)
setClose.MouseButton1Click:Connect(function() settingsFrame.Visible = false end)

-- Provider label
local provLabel = Instance.new("TextLabel")
provLabel.Size             = UDim2.new(1,-20,0,22)
provLabel.Position         = UDim2.new(0,10,0,50)
provLabel.BackgroundTransparency = 1
provLabel.Font             = Enum.Font.Code
provLabel.TextColor3       = C(150,200,220)
provLabel.TextSize         = isMobile and 14 or 12
provLabel.TextXAlignment   = Enum.TextXAlignment.Left
provLabel.Text             = "AI PROVIDER"
provLabel.ZIndex           = 21
provLabel.Parent           = settingsFrame

-- Provider buttons row
local provRow = Instance.new("Frame")
provRow.Size             = UDim2.new(1,-20,0, isMobile and 52 or 40)
provRow.Position         = UDim2.new(0,10,0,74)
provRow.BackgroundTransparency = 1
provRow.BorderSizePixel  = 0
provRow.ZIndex           = 21
provRow.Parent           = settingsFrame

local provLayout = Instance.new("UIListLayout", provRow)
provLayout.FillDirection = Enum.FillDirection.Horizontal
provLayout.Padding       = UDim.new(0,6)
provLayout.SortOrder     = Enum.SortOrder.LayoutOrder

local provBtns = {}

local function updateProviderBtns()
    for i, btn in ipairs(provBtns) do
        local prov = PROVIDERS[i]
        btn.BackgroundColor3        = i == currentProviderIdx and prov.color or DIM
        btn.BackgroundTransparency  = i == currentProviderIdx and 0.1 or 0.3
    end
    providerBadge.Text             = getProvider().name
    providerBadge.BackgroundColor3 = getProvider().color
end

for i, prov in ipairs(PROVIDERS) do
    local btn = Instance.new("TextButton")
    btn.Size            = UDim2.new(0, isMobile and 80 or 65, 1, 0)
    btn.BackgroundColor3 = DIM
    btn.BackgroundTransparency = 0.3
    btn.BorderSizePixel = 0
    btn.Font            = Enum.Font.GothamBold
    btn.TextColor3      = C(255,255,255)
    btn.Text            = prov.name
    btn.TextSize        = isMobile and 13 or 11
    btn.ZIndex          = 22
    btn.LayoutOrder     = i
    btn.Parent          = provRow
    Instance.new("UICorner", btn).CornerRadius = UDim.new(0,8)
    table.insert(provBtns, btn)
    btn.MouseButton1Click:Connect(function()
        currentProviderIdx = i
        updateProviderBtns()
    end)
end
updateProviderBtns()

-- API Key label
local keyLabel = Instance.new("TextLabel")
keyLabel.Size             = UDim2.new(1,-20,0,22)
keyLabel.Position         = UDim2.new(0,10,0, isMobile and 140 or 124)
keyLabel.BackgroundTransparency = 1
keyLabel.Font             = Enum.Font.Code
keyLabel.TextColor3       = C(150,200,220)
keyLabel.TextSize         = isMobile and 14 or 12
keyLabel.TextXAlignment   = Enum.TextXAlignment.Left
keyLabel.Text             = "API KEY"
keyLabel.ZIndex           = 21
keyLabel.Parent           = settingsFrame

-- API Key input
local keyBox = Instance.new("TextBox")
keyBox.Size             = UDim2.new(1,-20,0, isMobile and 50 or 38)
keyBox.Position         = UDim2.new(0,10,0, isMobile and 164 or 148)
keyBox.BackgroundColor3 = C(10,14,28)
keyBox.BorderSizePixel  = 0
keyBox.Font             = Enum.Font.Code
keyBox.TextColor3       = C(200,255,200)
keyBox.PlaceholderText  = "Paste your API key here..."
keyBox.PlaceholderColor3 = C(50,80,90)
keyBox.TextSize         = isMobile and 13 or 12
keyBox.ClearTextOnFocus = false
keyBox.Text             = ""
keyBox.TextXAlignment   = Enum.TextXAlignment.Left
keyBox.ZIndex           = 22
keyBox.Parent           = settingsFrame
Instance.new("UICorner", keyBox).CornerRadius = UDim.new(0,8)
Instance.new("UIStroke", keyBox).Color = CYAN
local kp = Instance.new("UIPadding", keyBox); kp.PaddingLeft = UDim.new(0,8); kp.PaddingRight = UDim.new(0,8)

-- Key status label (shows masked key or "not set")
local keyStatus = Instance.new("TextLabel")
keyStatus.Size             = UDim2.new(1,-20,0,20)
keyStatus.Position         = UDim2.new(0,10,0, isMobile and 218 or 192)
keyStatus.BackgroundTransparency = 1
keyStatus.Font             = Enum.Font.Code
keyStatus.TextColor3       = C(100,180,100)
keyStatus.TextSize         = isMobile and 13 or 11
keyStatus.TextXAlignment   = Enum.TextXAlignment.Left
keyStatus.Text             = "No key set"
keyStatus.ZIndex           = 21
keyStatus.Parent           = settingsFrame

local function updateKeyStatus()
    if currentApiKey == "" then
        keyStatus.Text      = "⚠ No key set"
        keyStatus.TextColor3 = C(255,150,50)
    else
        local masked = currentApiKey:sub(1,8) .. "..." .. currentApiKey:sub(-4)
        keyStatus.Text      = "✓ Key set: " .. masked
        keyStatus.TextColor3 = C(80,220,100)
    end
end

-- Save key button
local saveKeyBtn = Instance.new("TextButton")
saveKeyBtn.Size            = UDim2.new(1,-20,0, isMobile and 48 or 36)
saveKeyBtn.Position        = UDim2.new(0,10,0, isMobile and 244 or 218)
saveKeyBtn.BackgroundColor3 = C(0,170,255)
saveKeyBtn.BorderSizePixel = 0
saveKeyBtn.Font            = Enum.Font.GothamBold
saveKeyBtn.TextColor3      = C(5,5,20)
saveKeyBtn.Text            = "SAVE KEY"
saveKeyBtn.TextSize        = isMobile and 16 or 13
saveKeyBtn.ZIndex          = 22
saveKeyBtn.Parent          = settingsFrame
Instance.new("UICorner", saveKeyBtn).CornerRadius = UDim.new(0,8)

saveKeyBtn.MouseButton1Click:Connect(function()
    local k = keyBox.Text:match("^%s*(.-)%s*$")
    if k ~= "" then
        currentApiKey = k
        keyBox.Text   = ""
        updateKeyStatus()
        settingsFrame.Visible = false
    end
end)

-- Open settings
settingsBtn.MouseButton1Click:Connect(function()
    settingsFrame.Visible = true
end)

--====================================================
-- LOG AREA
--====================================================
local logFrame = Instance.new("ScrollingFrame")
logFrame.Size               = UDim2.new(1,-16,0,LOG_H)
logFrame.Position           = UDim2.new(0,8,0,HDR_H+5)
logFrame.BackgroundTransparency = 1
logFrame.BorderSizePixel    = 0
logFrame.ScrollBarThickness = isMobile and 5 or 3
logFrame.ScrollBarImageColor3 = CYAN
logFrame.CanvasSize         = UDim2.new(0,0,0,0)
logFrame.AutomaticCanvasSize = Enum.AutomaticSize.Y
logFrame.ElasticBehavior    = Enum.ElasticBehavior.Always
logFrame.ZIndex             = 11
logFrame.Parent             = panel
local logLayout = Instance.new("UIListLayout", logFrame)
logLayout.SortOrder = Enum.SortOrder.LayoutOrder
logLayout.Padding   = UDim.new(0,3)

local logLines = {}
addLog = function(text, color)
    color = color or C(175,255,195)
    local lbl = Instance.new("TextLabel")
    lbl.Size              = UDim2.new(1,-10,0,0)
    lbl.AutomaticSize     = Enum.AutomaticSize.Y
    lbl.BackgroundTransparency = 1
    lbl.Font              = Enum.Font.Code
    lbl.TextColor3        = color
    lbl.TextSize          = FONT_SZ
    lbl.TextXAlignment    = Enum.TextXAlignment.Left
    lbl.TextWrapped       = true
    lbl.Text              = "> " .. text
    lbl.LayoutOrder       = #logLines + 1
    lbl.ZIndex            = 12
    lbl.Parent            = logFrame
    table.insert(logLines, lbl)
    if #logLines > 40 then logLines[1]:Destroy(); table.remove(logLines,1) end
    task.defer(function() logFrame.CanvasPosition = Vector2.new(0,math.huge) end)
end

--====================================================
-- INPUT ROW
--====================================================
local inputRow = Instance.new("Frame")
inputRow.Size             = UDim2.new(1,-16,0,INPUT_H)
inputRow.Position         = UDim2.new(0,8,1,-(INPUT_H+10))
inputRow.BackgroundTransparency = 1
inputRow.BorderSizePixel  = 0
inputRow.ZIndex           = 11
inputRow.Parent           = panel

local textBox = Instance.new("TextBox")
textBox.Size              = UDim2.new(1,-(BTN_W+10),1,0)
textBox.BackgroundColor3  = C(11,16,30)
textBox.BorderSizePixel   = 0
textBox.Font              = Enum.Font.Code
textBox.TextColor3        = C(200,255,255)
textBox.PlaceholderText   = isMobile and "Tap here & type command..." or "Type command..."
textBox.PlaceholderColor3 = C(50,90,110)
textBox.TextSize          = isMobile and 15 or 14
textBox.ClearTextOnFocus  = false
textBox.MultiLine         = false
textBox.Text              = ""
textBox.TextXAlignment    = Enum.TextXAlignment.Left
textBox.TextTruncate      = Enum.TextTruncate.AtEnd
textBox.ZIndex            = 12
textBox.Parent            = inputRow
Instance.new("UICorner", textBox).CornerRadius = UDim.new(0,10)
local tbS = Instance.new("UIStroke", textBox); tbS.Color = CYAN; tbS.Thickness = 1.5
local tbP = Instance.new("UIPadding", textBox); tbP.PaddingLeft = UDim.new(0,10); tbP.PaddingRight = UDim.new(0,6)

if isMobile then
    textBox.Focused:Connect(function()
        if not panelOpen then setPanelOpen(true) end
    end)
end

local sendBtn = Instance.new("TextButton")
sendBtn.Size            = UDim2.new(0,BTN_W,1,0)
sendBtn.Position        = UDim2.new(1,-BTN_W,0,0)
sendBtn.BackgroundColor3 = C(0,185,255)
sendBtn.Font            = Enum.Font.GothamBold
sendBtn.TextColor3      = C(4,4,20)
sendBtn.Text            = isMobile and "▶ GO" or "SEND"
sendBtn.TextSize        = isMobile and 18 or 14
sendBtn.ZIndex          = 12
sendBtn.Parent          = inputRow
Instance.new("UICorner", sendBtn).CornerRadius = UDim.new(0,10)

-- Status dot
local statusDot = Instance.new("Frame")
statusDot.Size            = UDim2.new(0, isMobile and 13 or 10, 0, isMobile and 13 or 10)
statusDot.Position        = UDim2.new(1,-16,0,18)
statusDot.BackgroundColor3 = C(0,255,120)
statusDot.BorderSizePixel  = 0
statusDot.ZIndex           = 13
statusDot.Parent           = panel
Instance.new("UICorner", statusDot).CornerRadius = UDim.new(0.5,0)

local isBusy = false
local function setStatus(busy)
    isBusy = busy
    statusDot.BackgroundColor3 = busy and C(255,200,0) or C(0,255,120)
    sendBtn.Active = not busy
    sendBtn.BackgroundTransparency = busy and 0.5 or 0
    sendBtn.Text = busy and "..." or (isMobile and "▶ GO" or "SEND")
end

task.spawn(function()
    while true do
        TweenService:Create(statusDot, TweenInfo.new(0.9, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), {BackgroundTransparency=0.45}):Play()
        task.wait(0.9)
        TweenService:Create(statusDot, TweenInfo.new(0.9, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), {BackgroundTransparency=0}):Play()
        task.wait(0.9)
    end
end)

--====================================================
-- SEND HANDLER
--====================================================
local function handleSend()
    if isBusy then return end
    if currentApiKey == "" then
        addLog("No API key! Tap ⚙ to set one.", C(255,150,50))
        settingsFrame.Visible = true
        return
    end
    local prompt = textBox.Text:match("^%s*(.-)%s*$")
    if prompt == "" then return end
    textBox.Text = ""
    textBox:ReleaseFocus()

    -- Local command interceptors (no API call)
    if handleESPCommand(prompt) then return end
    if handleChatbotCommand(prompt) then return end
    if handleQnACommand(prompt) then return end

    -- DEX: direct Lua execution from input box — "dex <code>"
    local dexCode = prompt:match("^dex%s+(.+)") or prompt:match("^DEX%s+(.+)")
    if dexCode then
        local ok, result = dexExec(dexCode)
        addLog("dex: " .. result, ok and C(180,255,220) or C(255,100,100))
        return
    end

    -- QnA mode: route to conversational AI instead of action pipeline
    if qnaEnabled then
        setStatus(true)
        addLog("[QnA] " .. prompt, C(255, 220, 120))
        addLog("Thinking...", C(200, 200, 100))
        askQnA(prompt,
            function(answer)
                if logLines[#logLines] then
                    logLines[#logLines].Text      = "> " .. answer
                    logLines[#logLines].TextColor3 = C(255, 245, 180)
                end
                setStatus(false)
            end,
            function(err)
                if logLines[#logLines] then
                    logLines[#logLines].Text       = "> ERROR"
                    logLines[#logLines].TextColor3 = C(255,80,80)
                end
                addLog(err, C(255,80,80))
                setStatus(false)
            end)
        return
    end

    setStatus(true)
    addLog("["..getProvider().name.."] " .. prompt, C(100,200,255))

    -- Show different status hint for chat questions vs action commands
    local isChatQ = isChatQuestion(prompt)
    addLog(isChatQ and "Looking at chat..." or "Translating...", C(255,220,80))

    askAI(prompt,
        function(actions)
            -- For chat answers the action list is empty — update the status line
            if #actions == 0 then
                if logLines[#logLines] then
                    logLines[#logLines].Text      = "> Done"
                    logLines[#logLines].TextColor3 = C(180,255,180)
                end
            else
                if logLines[#logLines] then
                    logLines[#logLines].Text      = "> Agent: " .. #actions .. " action(s)"
                    logLines[#logLines].TextColor3 = C(180,255,180)
                end
                for _, act in ipairs(actions) do
                    addLog("  ▸ " .. (act.action or "?"), C(140,255,200))
                    table.insert(actionQueue, act)
                end
            end
            setStatus(false)
            runQueue()
        end,
        function(err)
            if logLines[#logLines] then
                logLines[#logLines].Text       = "> ERROR"
                logLines[#logLines].TextColor3 = C(255,80,80)
            end
            addLog(err, C(255,80,80))
            setStatus(false)
        end,
        function(reply)
            -- For chat questions: 'reply' is the plain-text answer — show it in yellow-white
            -- For action commands: 'reply' is the rewritten instruction — show it in blue if changed
            if isChatQ then
                addLog("💬 " .. reply, C(255, 240, 160))
            elseif reply ~= prompt then
                addLog("↪ " .. reply, C(180, 210, 255))
            end
        end
    )
end

sendBtn.MouseButton1Click:Connect(handleSend)
textBox.FocusLost:Connect(function(enter) if enter then handleSend() end end)

if not isMobile then
    UserInputService.InputBegan:Connect(function(input, gpe)
        if gpe then return end
        if input.KeyCode == Enum.KeyCode.Slash then
            setPanelOpen(true); textBox:CaptureFocus()
        end
    end)
end

--====================================================
-- DEX EXPLORER GUI
-- A floating window with instance tree, property panel,
-- search, and a Lua console. Opened via "dex" button.
--====================================================
local dexWin = Instance.new("Frame")
dexWin.Name              = "DexExplorer"
dexWin.Size              = UDim2.new(0, isMobile and 360 or 480, 0, isMobile and 520 or 460)
dexWin.Position          = UDim2.new(0.5, isMobile and -180 or -240, 0.5, isMobile and -260 or -230)
dexWin.BackgroundColor3  = C(5, 8, 18)
dexWin.BorderSizePixel   = 0
dexWin.Visible           = false
dexWin.ZIndex            = 50
dexWin.ClipsDescendants  = true
dexWin.Parent            = gui
Instance.new("UICorner", dexWin).CornerRadius = UDim.new(0, 12)
local dexStroke = Instance.new("UIStroke", dexWin)
dexStroke.Color = C(0, 200, 255); dexStroke.Thickness = 1.5

-- Title bar
local dexBar = Instance.new("Frame")
dexBar.Size             = UDim2.new(1,0,0, isMobile and 46 or 36)
dexBar.BackgroundColor3 = C(0, 100, 160)
dexBar.BackgroundTransparency = 0.5
dexBar.BorderSizePixel  = 0
dexBar.ZIndex           = 51
dexBar.Parent           = dexWin
Instance.new("UICorner", dexBar).CornerRadius = UDim.new(0,12)

local dexTitle = Instance.new("TextLabel")
dexTitle.Size             = UDim2.new(1,-80,1,0)
dexTitle.Position         = UDim2.new(0,12,0,0)
dexTitle.BackgroundTransparency = 1
dexTitle.Font             = Enum.Font.GothamBold
dexTitle.TextColor3       = C(0,215,255)
dexTitle.TextSize         = isMobile and 16 or 13
dexTitle.TextXAlignment   = Enum.TextXAlignment.Left
dexTitle.Text             = "◈ DEX EXPLORER"
dexTitle.ZIndex           = 52
dexTitle.Parent           = dexBar

local dexClose = Instance.new("TextButton")
dexClose.Size             = UDim2.new(0, isMobile and 44 or 28, 0, isMobile and 34 or 26)
dexClose.Position         = UDim2.new(1,-isMobile and 50 or 34, 0, isMobile and 6 or 5)
dexClose.BackgroundColor3 = C(180,50,50)
dexClose.BackgroundTransparency = 0.4
dexClose.BorderSizePixel  = 0
dexClose.Font             = Enum.Font.GothamBold
dexClose.TextColor3       = C(255,255,255)
dexClose.Text             = "✕"
dexClose.TextSize         = isMobile and 18 or 13
dexClose.ZIndex           = 52
dexClose.Parent           = dexBar
Instance.new("UICorner", dexClose).CornerRadius = UDim.new(0,6)
dexClose.MouseButton1Click:Connect(function() dexWin.Visible = false end)

local DEX_BAR_H = isMobile and 46 or 36
local DEX_H = isMobile and 520 or 460
local DEX_W = isMobile and 360 or 480

-- Tab bar: Tree | Properties | Console
local tabBar = Instance.new("Frame")
tabBar.Size             = UDim2.new(1,0,0, isMobile and 38 or 30)
tabBar.Position         = UDim2.new(0,0,0, DEX_BAR_H)
tabBar.BackgroundColor3 = C(8,12,24)
tabBar.BorderSizePixel  = 0
tabBar.ZIndex           = 51
tabBar.Parent           = dexWin
local tabLayout = Instance.new("UIListLayout", tabBar)
tabLayout.FillDirection = Enum.FillDirection.Horizontal
tabLayout.SortOrder     = Enum.SortOrder.LayoutOrder

local TAB_H   = isMobile and 38 or 30
local BODY_Y  = DEX_BAR_H + TAB_H
local BODY_H  = DEX_H - BODY_Y

local tabPages = {}
local tabBtns  = {}
local activeTab = 1

local function makeTab(name, idx)
    local btn = Instance.new("TextButton")
    btn.Size              = UDim2.new(0, isMobile and 100 or 80, 1, 0)
    btn.BackgroundColor3  = C(12,18,32)
    btn.BackgroundTransparency = 0.3
    btn.BorderSizePixel   = 0
    btn.Font              = Enum.Font.GothamBold
    btn.TextColor3        = C(140,180,200)
    btn.TextSize          = isMobile and 13 or 11
    btn.Text              = name
    btn.ZIndex            = 52
    btn.LayoutOrder       = idx
    btn.Parent            = tabBar
    Instance.new("UICorner", btn).CornerRadius = UDim.new(0,6)
    tabBtns[idx] = btn

    local page = Instance.new("Frame")
    page.Size             = UDim2.new(1,0,0, BODY_H)
    page.Position         = UDim2.new(0,0,0, BODY_Y)
    page.BackgroundTransparency = 1
    page.BorderSizePixel  = 0
    page.Visible          = idx == 1
    page.ZIndex           = 51
    page.Parent           = dexWin
    tabPages[idx] = page

    btn.MouseButton1Click:Connect(function()
        activeTab = idx
        for i, p in ipairs(tabPages)  do p.Visible = i == idx end
        for i, b in ipairs(tabBtns)   do
            b.BackgroundTransparency = i == idx and 0 or 0.3
            b.TextColor3 = i == idx and C(0,215,255) or C(140,180,200)
        end
    end)
    return page
end

local treePage  = makeTab("TREE",  1)
local propPage  = makeTab("PROPS", 2)
local conPage   = makeTab("LUA",   3)
-- Activate first tab visually
tabBtns[1].BackgroundTransparency = 0
tabBtns[1].TextColor3 = C(0,215,255)

-- ── TAB 1: TREE ─────────────────────────────────────────────────────────────
local treeSearch = Instance.new("TextBox")
treeSearch.Size             = UDim2.new(1,-12,0, isMobile and 36 or 28)
treeSearch.Position         = UDim2.new(0,6,0,6)
treeSearch.BackgroundColor3 = C(10,16,30)
treeSearch.BorderSizePixel  = 0
treeSearch.Font             = Enum.Font.Code
treeSearch.TextColor3       = C(200,240,255)
treeSearch.PlaceholderText  = "Search instances..."
treeSearch.PlaceholderColor3 = C(60,100,120)
treeSearch.TextSize         = isMobile and 13 or 12
treeSearch.ClearTextOnFocus = false
treeSearch.ZIndex           = 52
treeSearch.Parent           = treePage
Instance.new("UICorner", treeSearch).CornerRadius = UDim.new(0,8)
local tsSt = Instance.new("UIStroke", treeSearch); tsSt.Color = C(0,150,200)

local treeFrame = Instance.new("ScrollingFrame")
treeFrame.Size              = UDim2.new(1,-6,1,-(isMobile and 50 or 40))
treeFrame.Position          = UDim2.new(0,3,0, isMobile and 46 or 36)
treeFrame.BackgroundTransparency = 1
treeFrame.BorderSizePixel   = 0
treeFrame.ScrollBarThickness = isMobile and 5 or 3
treeFrame.ScrollBarImageColor3 = C(0,180,220)
treeFrame.AutomaticCanvasSize = Enum.AutomaticSize.Y
treeFrame.CanvasSize        = UDim2.new(0,0,0,0)
treeFrame.ZIndex            = 52
treeFrame.Parent            = treePage
local treeListLayout = Instance.new("UIListLayout", treeFrame)
treeListLayout.SortOrder = Enum.SortOrder.LayoutOrder
treeListLayout.Padding   = UDim.new(0,1)

local selectedInst = nil
local treeRows     = {}

local function dexSelectInst(inst)
    selectedInst = inst
    -- Switch to Props tab
    activeTab = 2
    for i, p in ipairs(tabPages) do p.Visible = i == 2 end
    for i, b in ipairs(tabBtns) do
        b.BackgroundTransparency = i == 2 and 0 or 0.3
        b.TextColor3 = i == 2 and C(0,215,255) or C(140,180,200)
    end
    -- Populate props
    for _, c in ipairs(propPage:GetChildren()) do
        if c:IsA("Frame") or c:IsA("ScrollingFrame") then c:Destroy() end
    end
    local pScroll = Instance.new("ScrollingFrame")
    pScroll.Size             = UDim2.new(1,-6,1,-8)
    pScroll.Position         = UDim2.new(0,3,0,4)
    pScroll.BackgroundTransparency = 1
    pScroll.BorderSizePixel  = 0
    pScroll.ScrollBarThickness = isMobile and 5 or 3
    pScroll.ScrollBarImageColor3 = C(0,180,220)
    pScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
    pScroll.CanvasSize       = UDim2.new(0,0,0,0)
    pScroll.ZIndex           = 52
    pScroll.Parent           = propPage
    local pLayout = Instance.new("UIListLayout", pScroll)
    pLayout.SortOrder = Enum.SortOrder.LayoutOrder
    pLayout.Padding   = UDim.new(0,2)

    -- Header
    local hdr = Instance.new("TextLabel")
    hdr.Size             = UDim2.new(1,-8,0, isMobile and 28 or 22)
    hdr.BackgroundColor3 = C(0,80,120)
    hdr.BackgroundTransparency = 0.5
    hdr.BorderSizePixel  = 0
    hdr.Font             = Enum.Font.GothamBold
    hdr.TextColor3       = C(0,215,255)
    hdr.TextSize         = isMobile and 13 or 11
    hdr.TextXAlignment   = Enum.TextXAlignment.Left
    hdr.Text             = "  " .. inst.ClassName .. " — " .. inst:GetFullName()
    hdr.TextTruncate     = Enum.TextTruncate.AtEnd
    hdr.ZIndex           = 53
    hdr.LayoutOrder      = 0
    hdr.Parent           = pScroll
    Instance.new("UICorner", hdr).CornerRadius = UDim.new(0,5)

    local props = dexGetProps(inst)
    for idx, prop in ipairs(props) do
        local row = Instance.new("Frame")
        row.Size             = UDim2.new(1,-8,0, isMobile and 30 or 24)
        row.BackgroundColor3 = idx % 2 == 0 and C(10,16,28) or C(14,20,34)
        row.BackgroundTransparency = 0.2
        row.BorderSizePixel  = 0
        row.ZIndex           = 53
        row.LayoutOrder      = idx
        row.Parent           = pScroll
        Instance.new("UICorner", row).CornerRadius = UDim.new(0,4)

        local kLbl = Instance.new("TextLabel")
        kLbl.Size            = UDim2.new(0.42,0,1,0)
        kLbl.BackgroundTransparency = 1
        kLbl.Font            = Enum.Font.Code
        kLbl.TextColor3      = C(120,200,240)
        kLbl.TextSize        = isMobile and 12 or 11
        kLbl.TextXAlignment  = Enum.TextXAlignment.Left
        kLbl.Text            = "  " .. prop.name
        kLbl.TextTruncate    = Enum.TextTruncate.AtEnd
        kLbl.ZIndex          = 54
        kLbl.Parent          = row

        local vBox = Instance.new("TextBox")
        vBox.Size            = UDim2.new(0.56,-4,0.8,0)
        vBox.Position        = UDim2.new(0.42,2,0.1,0)
        vBox.BackgroundColor3 = C(8,14,26)
        vBox.BackgroundTransparency = 0.3
        vBox.BorderSizePixel = 0
        vBox.Font            = Enum.Font.Code
        vBox.TextColor3      = C(200,240,200)
        vBox.TextSize        = isMobile and 12 or 11
        vBox.TextXAlignment  = Enum.TextXAlignment.Left
        vBox.ClearTextOnFocus = false
        vBox.Text            = prop.value
        vBox.ZIndex          = 54
        vBox.Parent          = row
        Instance.new("UICorner", vBox).CornerRadius = UDim.new(0,4)
        local propName = prop.name
        vBox.FocusLost:Connect(function(enter)
            if enter then
                local code = string.format(
                    'local inst = game:GetService("Players").LocalPlayer.Character or game'
                    .. '
local ok,res = pcall(function()'
                    .. '
  local t = game'
                    .. '
  for p in ("%s"):gmatch("[^.]+") do t = t[p] end'
                    .. '
  t.%s = %s'
                    .. '
end)'
                    .. '
return ok and "set" or res',
                    inst:GetFullName():gsub("^game%.", ""),
                    propName, vBox.Text)
                -- Simpler direct approach
                local directCode = string.format(
                    'local i = game:FindFirstChild and game'
                    .. '
local ok,e = pcall(function() %s.%s = %s end)'
                    .. '
return ok and "set ok" or tostring(e)',
                    inst:GetFullName(), propName, vBox.Text)
                local ok2, res = dexExec(directCode)
                addLog("prop " .. propName .. ": " .. res, ok2 and C(180,255,200) or C(255,120,120))
            end
        end)
    end

    -- Methods row
    local methodsLabel = Instance.new("TextLabel")
    methodsLabel.Size            = UDim2.new(1,-8,0, isMobile and 24 or 20)
    methodsLabel.BackgroundTransparency = 1
    methodsLabel.Font            = Enum.Font.GothamBold
    methodsLabel.TextColor3      = C(180,180,180)
    methodsLabel.TextSize        = isMobile and 12 or 10
    methodsLabel.TextXAlignment  = Enum.TextXAlignment.Left
    methodsLabel.Text            = "  METHODS:"
    methodsLabel.ZIndex          = 53
    methodsLabel.LayoutOrder     = 998
    methodsLabel.Parent          = pScroll

    local methods = {"Destroy","Clone","ClearAllChildren","GetChildren","GetDescendants",
                     "FindFirstChild","FindFirstChildOfClass","IsA","Remove","GetFullName"}
    local mRow = Instance.new("Frame")
    mRow.Size            = UDim2.new(1,-8,0, isMobile and 36 or 28)
    mRow.BackgroundTransparency = 1
    mRow.BorderSizePixel = 0
    mRow.ZIndex          = 53
    mRow.LayoutOrder     = 999
    mRow.Parent          = pScroll
    local mLayout = Instance.new("UIListLayout", mRow)
    mLayout.FillDirection = Enum.FillDirection.Horizontal
    mLayout.Padding       = UDim.new(0,4)

    for _, mName in ipairs(methods) do
        local mb = Instance.new("TextButton")
        mb.Size             = UDim2.new(0, isMobile and 90 or 72, 0, isMobile and 28 or 22)
        mb.BackgroundColor3 = C(0,100,140)
        mb.BackgroundTransparency = 0.4
        mb.BorderSizePixel  = 0
        mb.Font             = Enum.Font.Code
        mb.TextColor3       = C(200,240,255)
        mb.TextSize         = isMobile and 11 or 10
        mb.Text             = mName
        mb.ZIndex           = 54
        mb.Parent           = mRow
        Instance.new("UICorner", mb).CornerRadius = UDim.new(0,5)
        local capturedMethod = mName
        local capturedInst   = inst
        mb.MouseButton1Click:Connect(function()
            local code = string.format(
                "local ok,r = pcall(function() return game:GetService('Players').LocalPlayer.Character end)"
                .. "
local ok2,r2 = pcall(function() return (%s):%s() end)"
                .. "
return ok2 and tostring(r2) or r2",
                capturedInst:GetFullName(), capturedMethod)
            local ok3, res = dexExec(string.format(
                "local ok,r = pcall(function() return (%s):%s() end); return ok and tostring(r) or r",
                capturedInst:GetFullName(), capturedMethod))
            addLog(capturedMethod .. ": " .. res, ok3 and C(180,255,200) or C(255,120,120))
        end)
    end
end

local function dexPopulateTree(query)
    for _, c in ipairs(treeFrame:GetChildren()) do
        if not c:IsA("UIListLayout") then c:Destroy() end
    end
    treeRows = {}

    local roots = {game}
    local items = {}

    if query and query ~= "" then
        -- Search mode
        local q = query:lower()
        local found = dexSearch(game, function(inst)
            return inst.Name:lower():find(q, 1, true)
                or inst.ClassName:lower():find(q, 1, true)
        end)
        for _, inst in ipairs(found) do
            table.insert(items, { indent=0, name=inst.Name, class=inst.ClassName, inst=inst, hasChildren=#inst:GetChildren()>0 })
        end
    else
        -- Tree mode: show top-level services
        local services = {
            "Workspace","Players","Lighting","ReplicatedStorage",
            "StarterGui","StarterPack","SoundService","Teams",
            "ReplicatedFirst","ServerScriptService","ServerStorage"
        }
        for _, svcName in ipairs(services) do
            local ok2, svc = pcall(function() return game:GetService(svcName) end)
            if ok2 and svc then
                table.insert(items, { indent=0, name=svc.Name, class=svc.ClassName, inst=svc, hasChildren=true })
            end
        end
    end

    for rowIdx, item in ipairs(items) do
        local row = Instance.new("TextButton")
        row.Size             = UDim2.new(1,-6,0, isMobile and 30 or 24)
        row.BackgroundColor3 = rowIdx % 2 == 0 and C(10,16,28) or C(14,20,34)
        row.BackgroundTransparency = 0.15
        row.BorderSizePixel  = 0
        row.Font             = Enum.Font.Code
        row.TextColor3       = C(180,230,255)
        row.TextSize         = isMobile and 12 or 11
        row.TextXAlignment   = Enum.TextXAlignment.Left
        row.Text             = string.rep("  ", item.indent)
            .. (item.hasChildren and "▶ " or "  ")
            .. item.name .. " [" .. item.class .. "]"
        row.TextTruncate     = Enum.TextTruncate.AtEnd
        row.ZIndex           = 52
        row.LayoutOrder      = rowIdx
        row.Parent           = treeFrame
        Instance.new("UICorner", row).CornerRadius = UDim.new(0,4)
        local capturedItem = item
        row.MouseButton1Click:Connect(function()
            -- Single click: expand children inline
            if capturedItem.hasChildren then
                local children = dexListChildren(capturedItem.inst, 0, 0)
                for ci, child in ipairs(children) do
                    local childRow = Instance.new("TextButton")
                    childRow.Size            = UDim2.new(1,-6,0, isMobile and 28 or 22)
                    childRow.BackgroundColor3 = C(8,12,22)
                    childRow.BackgroundTransparency = 0.1
                    childRow.BorderSizePixel = 0
                    childRow.Font            = Enum.Font.Code
                    childRow.TextColor3      = C(150,210,240)
                    childRow.TextSize        = isMobile and 12 or 11
                    childRow.TextXAlignment  = Enum.TextXAlignment.Left
                    childRow.Text            = "    " .. (child.hasChildren and "▶ " or "  ")
                        .. child.name .. " [" .. child.class .. "]"
                    childRow.TextTruncate    = Enum.TextTruncate.AtEnd
                    childRow.ZIndex          = 52
                    childRow.LayoutOrder     = rowIdx * 1000 + ci
                    childRow.Parent          = treeFrame
                    Instance.new("UICorner", childRow).CornerRadius = UDim.new(0,4)
                    local cc = child
                    childRow.MouseButton1Click:Connect(function()
                        dexSelectInst(cc.inst)
                    end)
                end
            end
            dexSelectInst(capturedItem.inst)
        end)
        table.insert(treeRows, row)
    end
end

-- ── TAB 3: LUA CONSOLE ──────────────────────────────────────────────────────
local conInput = Instance.new("TextBox")
conInput.Size             = UDim2.new(1,-12,0, isMobile and 70 or 55)
conInput.Position         = UDim2.new(0,6,0,6)
conInput.BackgroundColor3 = C(8,14,26)
conInput.BorderSizePixel  = 0
conInput.Font             = Enum.Font.Code
conInput.TextColor3       = C(200,255,200)
conInput.PlaceholderText  = "Enter Lua code..."
conInput.PlaceholderColor3 = C(60,110,80)
conInput.TextSize         = isMobile and 13 or 12
conInput.ClearTextOnFocus = false
conInput.MultiLine        = true
conInput.ZIndex           = 52
conInput.Parent           = conPage
Instance.new("UICorner", conInput).CornerRadius = UDim.new(0,8)
local csSt = Instance.new("UIStroke", conInput); csSt.Color = C(0,160,100)

local conRunBtn = Instance.new("TextButton")
conRunBtn.Size            = UDim2.new(1,-12,0, isMobile and 40 or 30)
conRunBtn.Position        = UDim2.new(0,6,0, isMobile and 82 or 67)
conRunBtn.BackgroundColor3 = C(0,160,80)
conRunBtn.BackgroundTransparency = 0.2
conRunBtn.BorderSizePixel = 0
conRunBtn.Font            = Enum.Font.GothamBold
conRunBtn.TextColor3      = C(255,255,255)
conRunBtn.TextSize        = isMobile and 15 or 12
conRunBtn.Text            = "▶  RUN"
conRunBtn.ZIndex          = 52
conRunBtn.Parent          = conPage
Instance.new("UICorner", conRunBtn).CornerRadius = UDim.new(0,8)

local conOutFrame = Instance.new("ScrollingFrame")
local conOutY = isMobile and 130 or 104
conOutFrame.Size              = UDim2.new(1,-12,1,-(conOutY+6))
conOutFrame.Position          = UDim2.new(0,6,0,conOutY)
conOutFrame.BackgroundColor3  = C(5,10,18)
conOutFrame.BackgroundTransparency = 0.1
conOutFrame.BorderSizePixel   = 0
conOutFrame.ScrollBarThickness = isMobile and 5 or 3
conOutFrame.ScrollBarImageColor3 = C(0,180,100)
conOutFrame.AutomaticCanvasSize = Enum.AutomaticSize.Y
conOutFrame.CanvasSize        = UDim2.new(0,0,0,0)
conOutFrame.ZIndex            = 52
conOutFrame.Parent            = conPage
Instance.new("UICorner", conOutFrame).CornerRadius = UDim.new(0,8)
local conOutLayout = Instance.new("UIListLayout", conOutFrame)
conOutLayout.SortOrder = Enum.SortOrder.LayoutOrder
conOutLayout.Padding   = UDim.new(0,2)

local conLines = 0
local function conPrint(text, color)
    conLines = conLines + 1
    local lbl = Instance.new("TextLabel")
    lbl.Size             = UDim2.new(1,-8,0,0)
    lbl.AutomaticSize    = Enum.AutomaticSize.Y
    lbl.BackgroundTransparency = 1
    lbl.Font             = Enum.Font.Code
    lbl.TextColor3       = color or C(180,255,180)
    lbl.TextSize         = isMobile and 12 or 11
    lbl.TextXAlignment   = Enum.TextXAlignment.Left
    lbl.TextWrapped      = true
    lbl.Text             = text
    lbl.ZIndex           = 53
    lbl.LayoutOrder      = conLines
    lbl.Parent           = conOutFrame
    task.defer(function() conOutFrame.CanvasPosition = Vector2.new(0, math.huge) end)
end

conRunBtn.MouseButton1Click:Connect(function()
    local code = conInput.Text
    if code:match("^%s*$") then return end
    conPrint("> " .. code:gsub("\n", " "), C(100,200,255))
    local ok2, res = dexExec(code)
    conPrint(res, ok2 and C(180,255,180) or C(255,120,120))
end)

-- Search box wired
treeSearch.FocusLost:Connect(function()
    dexPopulateTree(treeSearch.Text ~= "" and treeSearch.Text or nil)
end)

-- ESP toggle button in the header bar
local espToggleBtn = Instance.new("TextButton")
espToggleBtn.Size              = UDim2.new(0, isMobile and 48 or 36, 0, isMobile and 34 or 24)
espToggleBtn.Position          = UDim2.new(0, isMobile and 58 or 44, 0.5, isMobile and -17 or -12)
espToggleBtn.BackgroundColor3  = C(60, 60, 60)
espToggleBtn.BackgroundTransparency = 0.4
espToggleBtn.BorderSizePixel   = 0
espToggleBtn.Font              = Enum.Font.GothamBold
espToggleBtn.TextColor3        = C(255,255,255)
espToggleBtn.Text              = "ESP"
espToggleBtn.TextSize          = isMobile and 13 or 10
espToggleBtn.ZIndex            = 13
espToggleBtn.Parent            = header
Instance.new("UICorner", espToggleBtn).CornerRadius = UDim.new(0,6)

local function updateEspBtn()
    if ESP_CFG.enabled then
        espToggleBtn.BackgroundColor3 = C(30, 200, 100)
        espToggleBtn.BackgroundTransparency = 0.25
    else
        espToggleBtn.BackgroundColor3 = C(60, 60, 60)
        espToggleBtn.BackgroundTransparency = 0.4
    end
end

espToggleBtn.MouseButton1Click:Connect(function()
    setESP(not ESP_CFG.enabled)
    updateEspBtn()
    addLog(ESP_CFG.enabled and "ESP ON" or "ESP OFF",
        ESP_CFG.enabled and C(0,255,180) or C(255,160,100))
end)

-- DEX open/refresh button in the header bar
local dexOpenBtn = Instance.new("TextButton")
dexOpenBtn.Size              = UDim2.new(0, isMobile and 48 or 36, 0, isMobile and 34 or 24)
dexOpenBtn.Position          = UDim2.new(0, isMobile and 4 or 4, 0.5, isMobile and -17 or -12)
dexOpenBtn.BackgroundColor3  = C(0,120,180)
dexOpenBtn.BackgroundTransparency = 0.45
dexOpenBtn.BorderSizePixel   = 0
dexOpenBtn.Font              = Enum.Font.GothamBold
dexOpenBtn.TextColor3        = C(255,255,255)
dexOpenBtn.Text              = "DEX"
dexOpenBtn.TextSize          = isMobile and 13 or 10
dexOpenBtn.ZIndex            = 13
dexOpenBtn.Parent            = header
Instance.new("UICorner", dexOpenBtn).CornerRadius = UDim.new(0,6)

dexOpenBtn.MouseButton1Click:Connect(function()
    dexWin.Visible = not dexWin.Visible
    if dexWin.Visible then
        dexPopulateTree(nil)
    end
end)

-- QnA indicator in header
local qnaIndicator = Instance.new("TextLabel")
qnaIndicator.Size             = UDim2.new(0, isMobile and 52 or 40, 0, isMobile and 18 or 14)
qnaIndicator.Position         = UDim2.new(0, isMobile and 112 or 84, 0.5, isMobile and -9 or -7)
qnaIndicator.BackgroundColor3 = C(255,180,0)
qnaIndicator.BackgroundTransparency = 0.3
qnaIndicator.BorderSizePixel  = 0
qnaIndicator.Font             = Enum.Font.GothamBold
qnaIndicator.TextColor3       = C(20,20,20)
qnaIndicator.TextSize         = isMobile and 11 or 9
qnaIndicator.Text             = "QnA"
qnaIndicator.ZIndex           = 13
qnaIndicator.Visible          = false
qnaIndicator.Parent           = header
Instance.new("UICorner", qnaIndicator).CornerRadius = UDim.new(0,4)

-- Keep QnA indicator in sync
task.spawn(function()
    while true do
        task.wait(0.5)
        if qnaIndicator and qnaIndicator.Parent then
            qnaIndicator.Visible = qnaEnabled
        end
    end
end)

-- First-run hint
addLog(isMobile and "Tap ⚙ to set your API key first!" or "Click ⚙ to set your API key first!", C(255,200,80))
addLog("Supports Claude, GPT-4o, Groq, Gemini", C(100,200,255))
addLog("ESP: toggle btn in header | type 'esp on/off' | 'esp rgb' | 'esp color R G B'", C(160,255,200))

print("🤖 AI Agent loaded — multi-provider, key via GUI")

if EUI_CLIENT_BLOCKED then return end

local addonName = ...
local DB_NAME = "EllesmereUIAutoToastDB"
local Csq = C_SocialQueue
local db
local legacyDB
local initialized = false
local groups = {}
local recent = {}
local guildGUIDs, friendGUIDs = {}, {}
local guildNames, friendNames = {}, {}
local toast, toastText, toastTitle
local HideToast

local function IsSecret(v)
    return issecretvalue and issecretvalue(v)
end

local function SafeString(v)
    if v == nil or IsSecret(v) or type(v) ~= "string" then return nil end
    return v
end

local function GetDB()
    -- EUI profile data is authoritative when the integrated module is running.
    -- The legacy account-wide table is retained only for one-time migration.
    if EllesmereUI and EllesmereUI.GetActiveProfileData then
        local profile = EllesmereUI.GetActiveProfileData()
        if profile then
            if not profile.autoToast then
                profile.autoToast = legacyDB or {}
            end
            db = profile.autoToast
        end
    end
    if not db then
        _G[DB_NAME] = _G[DB_NAME] or {}
        legacyDB = _G[DB_NAME]
        db = legacyDB
    end
    if db.enabled == nil then db.enabled = false end
    if db.guild == nil then db.guild = true end
    if db.friends == nil then db.friends = true end
    if db.toast == nil then db.toast = true end
    if db.sound == nil then db.sound = true end
    if db.chat == nil then db.chat = false end
    if type(db.cooldown) ~= "number" then db.cooldown = 300 end
    return db
end

local function RebuildRelations()
    wipe(guildGUIDs); wipe(friendGUIDs); wipe(guildNames); wipe(friendNames)
    if IsInGuild() then
        if C_GuildInfo and C_GuildInfo.GuildRoster then
            C_GuildInfo.GuildRoster()
        elseif GuildRoster then
            GuildRoster()
        end
        local n = GetNumGuildMembers and (GetNumGuildMembers() or 0) or 0
        for i = 1, n do
            local name, _, _, _, _, _, _, _, online, _, _, _, _, _, _, guid
            if GetGuildRosterInfo then
                name, _, _, _, _, _, _, _, online, _, _, _, _, _, _, guid = GetGuildRosterInfo(i)
            end
            if name and not IsSecret(name) then guildNames[name] = true end
            if online and guid and not IsSecret(guid) then guildGUIDs[guid] = true end
        end
    end
    local n = C_FriendList and C_FriendList.GetNumFriends and C_FriendList.GetNumFriends() or 0
    for i = 1, n do
        local info = C_FriendList.GetFriendInfoByIndex(i)
        local guid = info and info.guid
        local name = info and (info.name or info.fullName)
        if name and not IsSecret(name) then friendNames[name] = true end
        if guid and not IsSecret(guid) then friendGUIDs[guid] = true end
    end
end

local function Allowed(guid, name, relationshipName)
    local d = GetDB()
    local guild = d.guild and (guildGUIDs[guid] or guildNames[name])
    local friend = d.friends and (friendGUIDs[guid] or friendNames[name])
    -- When both sources are enabled, Blizzard's relationship helper is the
    -- authoritative social-queue classification. This also covers Battle.net
    -- friends whose GUID is not exposed by the Friends API.
    if d.guild and d.friends and relationshipName then return true end
    return guild or friend
end

-- Display-safe label: strips colour codes and rejects anything that still
-- carries control characters, pipe escapes or runs long (some Blizzard queue
-- helpers hand back fragments like "|Kt1|k" for premade groups). A rejected
-- label falls through to the plain queue-type name instead of showing garbage.
local function SafeLabel(v)
    local s = SafeString(v)
    if not s then return nil end
    s = s:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    if s:find("[|%c]") then return nil end
    s = s:gsub("^%s+", ""):gsub("%s+$", "")
    if s == "" or #s > 60 then return nil end
    return s
end

local function QueueName(queue)
    if type(queue) ~= "table" or not queue.eligible then return nil end
    local data = queue.queueData
    if type(data) ~= "table" then return nil end
    if data.queueType == "lfglist" and data.lfgListID and C_LFGList and C_LFGList.GetSearchResultInfo then
        local ok, info = pcall(C_LFGList.GetSearchResultInfo, data.lfgListID)
        local name = ok and info and SafeLabel(info.name)
        if name then return name end
    end
    if SocialQueueUtil_GetQueueName then
        local ok, name = pcall(SocialQueueUtil_GetQueueName, data)
        name = ok and SafeLabel(name and name:gsub("\n.+", ""))
        if name then return name end
    end
    return SafeLabel(data.queueType) or "Warteschlange"
end

local function GroupInfo(guid)
    if not Csq or not Csq.GetGroupMembers or not Csq.GetGroupQueues then return nil end
    local ok, members = pcall(Csq.GetGroupMembers, guid)
    if not ok or type(members) ~= "table" or not members[1] then return nil end
    local first = members[1]
    local memberGUID = first.guid
    if not memberGUID or IsSecret(memberGUID) then return nil end
    local memberName = SafeLabel(first.name)
    local relationshipName
    if SocialQueueUtil_GetRelationshipInfo then
        local okName, display = pcall(SocialQueueUtil_GetRelationshipInfo, memberGUID, nil, first.clubId)
        relationshipName = okName and SafeString(display)
    end
    if not Allowed(memberGUID, memberName, relationshipName) then return nil end
    local queuesOK, queues = pcall(Csq.GetGroupQueues, guid)
    if not queuesOK or type(queues) ~= "table" then return nil end
    local names = {}
    for i = 1, #queues do
        local name = QueueName(queues[i])
        if name then names[#names + 1] = name end
    end
    if #names == 0 then return nil end
    local name = relationshipName or memberName or "Gilden-/Freundesmitglied"
    return name, table.concat(names, ", "), #members
end

local function EnsureToast()
    if toast then return end
    toast = CreateFrame("Frame", "EllesmereUIAutoToastFrame", UIParent, "BackdropTemplate")
    toast:SetSize(390, 76)
    toast:SetPoint("TOP", UIParent, "TOP", 0, -120)
    toast:SetFrameStrata("DIALOG")
    toast:SetBackdrop({ bgFile="Interface\\Buttons\\WHITE8X8", edgeFile="Interface\\Buttons\\WHITE8X8", edgeSize=1, insets={left=1,right=1,top=1,bottom=1} })
    toast:SetBackdropColor(0.035, 0.055, 0.08, 0.97)
    toast:SetBackdropBorderColor(0.05, 0.83, 0.62, 0.95)
    toastTitle = toast:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    toastTitle:SetPoint("TOPLEFT", 16, -12)
    toastTitle:SetTextColor(0.05, 0.83, 0.62, 1)
    toastText = toast:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    toastText:SetPoint("TOPLEFT", toastTitle, "BOTTOMLEFT", 0, -7)
    toastText:SetPoint("RIGHT", -16, 0)
    toastText:SetJustifyH("LEFT")
    toast:Hide()
end

local function ShowToast(name, queueName, count)
    local d = GetDB()
    local suffix = count and count > 1 and (" (+" .. (count - 1) .. ")") or ""
    if d.toast then
        EnsureToast()
        toastTitle:SetText("Social Queue")
        toastText:SetText(name .. suffix .. " ist in der Warteschlange:\n" .. queueName)
        toast:SetAlpha(1); toast:Show()
        if HideToast then HideToast() end
        HideToast = C_Timer.After(8, function() if toast then toast:Hide() end end)
    end
    if d.sound then
        -- Midnight uses the parameter-table form of C_Sound.PlaySound.
        -- Keep a guarded fallback for clients that still expose PlaySound(id).
        local soundID = SOUNDKIT and SOUNDKIT.TUTORIAL_POPUP or SOUND_TUTORIAL_POPUP
        if soundID then
            if C_Sound and C_Sound.PlaySound then
                pcall(C_Sound.PlaySound, { soundID = soundID })
            elseif PlaySound then
                pcall(PlaySound, soundID)
            end
        end
    end
    if d.chat then
        local message = "|cff0cd29fAutoToast:|r " .. name .. suffix .. " -> " .. queueName
        if EllesmereUI and EllesmereUI.Print then EllesmereUI.Print(message)
        elseif DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage(message) end
    end
end

local function Signature(name, queueName, count)
    return (name or "") .. "\031" .. (queueName or "") .. "\031" .. tostring(count or 1)
end

local function Process(guid, force)
    local name, queueName, count = GroupInfo(guid)
    if not name then return end
    local sig = Signature(name, queueName, count)
    local old = groups[guid]
    groups[guid] = sig
    if not initialized or old == sig then return end
    local now = GetTime()
    if recent[sig] and now - recent[sig] < (GetDB().cooldown or 300) then return end
    recent[sig] = now
    ShowToast(name, queueName, count)
end

local function RefreshAll()
    RebuildRelations()
    if not Csq or not Csq.GetAllGroups then return end
    local ok, all = pcall(Csq.GetAllGroups)
    if not ok or type(all) ~= "table" then return end
    for _, guid in pairs(all) do Process(guid, false) end
    initialized = true
end

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:RegisterEvent("SOCIAL_QUEUE_UPDATE")
eventFrame:RegisterEvent("GUILD_ROSTER_UPDATE")
eventFrame:RegisterEvent("FRIENDLIST_UPDATE")
eventFrame:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" and arg1 == addonName then GetDB() return end
    if event == "PLAYER_LOGIN" then
        GetDB()
        C_Timer.After(1, RefreshAll)
        return
    end
    if event == "GUILD_ROSTER_UPDATE" or event == "FRIENDLIST_UPDATE" then
        RebuildRelations(); return
    end
    if not GetDB().enabled then return end
    if event == "SOCIAL_QUEUE_UPDATE" and arg1 then Process(arg1, true) else RefreshAll() end
end)

_G._EUI_AutoToast_DB = GetDB

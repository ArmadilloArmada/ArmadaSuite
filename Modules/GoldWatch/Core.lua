local ADDON_NAME = "ArmadaSuite"

local addon = {}
local db
local ui = {}
local ROW_HEIGHT = 56
local ROW_GAP = 6

local session = nil
local pendingRefresh = false

local Refresh
local CreateUI
local RefreshTracker

local function Now()
    return GetServerTime()
end

local function RowStep()
    return ROW_HEIGHT + ROW_GAP
end

local function Message(text)
    print("|cffd4af37GoldWatch:|r " .. text)
end

local function Trim(text)
    return strtrim(text or "")
end

local function FormatGold(copper)
    if copper <= 0 then return "0g" end
    local gold = math.floor(copper / 10000)
    local silver = math.floor((copper % 10000) / 100)
    if gold >= 1000 then
        return string.format("%dg", gold)
    elseif gold > 0 then
        return string.format("%dg %ds", gold, silver)
    end
    return string.format("%ds", silver)
end

local function FormatGoldPerHour(copper, seconds)
    if seconds < 10 then return "---" end
    local perHour = math.floor((copper / seconds) * 3600)
    return FormatGold(perHour) .. "/hr"
end

local function FormatDuration(seconds)
    seconds = math.max(0, seconds)
    local h = math.floor(seconds / 3600)
    local m = math.floor((seconds % 3600) / 60)
    local s = seconds % 60
    if h > 0 then
        return string.format("%d:%02d:%02d", h, m, s)
    end
    return string.format("%d:%02d", m, s)
end

local function DetectActivity()
    local instanceName, instanceType, _, _, _, _, _, instanceId = GetInstanceInfo()

    if instanceType == "party" or instanceType == "raid" then
        return instanceName or "Dungeon", instanceType
    end

    if instanceType == "scenario" then
        return instanceName or "Delve", "delve"
    end

    local mapId = C_Map.GetBestMapForUnit("player")
    if mapId then
        local quests = C_QuestLog.GetQuestsOnMap(mapId)
        if quests then
            for _, q in ipairs(quests) do
                if C_QuestLog.IsWorldQuest(q.questID) and C_QuestLog.IsOnQuest(q.questID) then
                    return GetZoneText() or "World Quests", "worldquest"
                end
            end
        end
    end

    return GetZoneText() or "Unknown", "outdoor"
end

local function EnsureDB()
    GoldWatchDB = GoldWatchDB or {}
    db = GoldWatchDB
    db.history = db.history or {}
    db.position = db.position or { point = "CENTER", x = 0, y = 0 }
    db.trackerPosition = db.trackerPosition or { point = "CENTER", x = 400, y = 0 }
    db.activeTab = db.activeTab or "live"
    db.trackerShown = db.trackerShown ~= false
    db.maxHistory = db.maxHistory or 50
end

local function NewSession()
    local activity, activityType = DetectActivity()
    session = {
        activity = activity,
        activityType = activityType,
        startedAt = Now(),
        gold = 0,
        loot = 0,
        vendor = 0,
        quest = 0,
        mail = 0,
    }
    Message("Session started — " .. activity)
    RefreshTracker()
    Refresh()
end

local function StopSession()
    if not session then
        Message("No active session.")
        return
    end

    local duration = Now() - session.startedAt
    if duration < 10 or session.gold <= 0 then
        Message("Session too short or no gold earned — not saved.")
        session = nil
        RefreshTracker()
        Refresh()
        return
    end

    local record = {
        activity = session.activity,
        activityType = session.activityType,
        gold = session.gold,
        loot = session.loot,
        vendor = session.vendor,
        quest = session.quest,
        mail = session.mail,
        duration = duration,
        endedAt = Now(),
    }

    table.insert(db.history, 1, record)
    while #db.history > db.maxHistory do
        table.remove(db.history)
    end

    Message("Session saved — " .. session.activity .. " — " .. FormatGold(session.gold) .. " in " .. FormatDuration(duration))
    session = nil
    RefreshTracker()
    Refresh()
end

local function AddGold(amount, source)
    if not session or amount <= 0 then return end
    session.gold = session.gold + amount
    if source == "loot" then
        session.loot = session.loot + amount
    elseif source == "vendor" then
        session.vendor = session.vendor + amount
    elseif source == "quest" then
        session.quest = session.quest + amount
    elseif source == "mail" then
        session.mail = session.mail + amount
    end
    RefreshTracker()
end

-- Money tracking
local lastMoney = 0

local function OnMoneyChanged()
    local current = GetMoney()
    local diff = current - lastMoney
    lastMoney = current
    if diff > 0 and session then
        -- We attribute via specific events; this is a fallback catch-all
    end
end

-- Event handlers
local function OnLootSlotCleared(slot)
    if not session then return end
    -- Gold loot is caught via PLAYER_MONEY delta during LOOT_CLOSED
end

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("PLAYER_MONEY")
eventFrame:RegisterEvent("LOOT_OPENED")
eventFrame:RegisterEvent("LOOT_CLOSED")
eventFrame:RegisterEvent("MERCHANT_CLOSED")
eventFrame:RegisterEvent("QUEST_TURNED_IN")
eventFrame:RegisterEvent("MAIL_INBOX_UPDATE")
eventFrame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
eventFrame:RegisterEvent("ZONE_CHANGED")

local lootOpenMoney = 0
local merchantOpenMoney = 0
local mailOpenMoney = 0

eventFrame:SetScript("OnEvent", function(self, event, arg1, arg2)
    if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
        EnsureDB()
    elseif event == "PLAYER_LOGIN" then
        lastMoney = GetMoney()
    elseif event == "PLAYER_ENTERING_WORLD" then
        if not db then EnsureDB() end
        lastMoney = GetMoney()
    elseif event == "LOOT_OPENED" then
        lootOpenMoney = GetMoney()
    elseif event == "LOOT_CLOSED" then
        local diff = GetMoney() - lootOpenMoney
        if diff > 0 then
            AddGold(diff, "loot")
        end
        lastMoney = GetMoney()
    elseif event == "MERCHANT_CLOSED" then
        local diff = GetMoney() - merchantOpenMoney
        if diff > 0 then
            AddGold(diff, "vendor")
        end
        lastMoney = GetMoney()
    elseif event == "PLAYER_MONEY" then
        local current = GetMoney()
        if merchantOpenMoney == 0 and lootOpenMoney == 0 then
            -- track for merchant open baseline
        end
        merchantOpenMoney = 0
        lastMoney = current
    elseif event == "QUEST_TURNED_IN" then
        C_Timer.After(0.3, function()
            local diff = GetMoney() - lastMoney
            if diff > 0 then
                AddGold(diff, "quest")
                lastMoney = GetMoney()
            end
        end)
    elseif event == "MAIL_INBOX_UPDATE" then
        C_Timer.After(0.3, function()
            local diff = GetMoney() - lastMoney
            if diff > 0 then
                AddGold(diff, "mail")
                lastMoney = GetMoney()
            end
        end)
    elseif event == "ZONE_CHANGED_NEW_AREA" or event == "ZONE_CHANGED" then
        if session then
            local newActivity, newType = DetectActivity()
            if newActivity ~= session.activity then
                session.activity = newActivity
                session.activityType = newType
                RefreshTracker()
                Refresh()
            end
        end
    end

    -- Keep merchant baseline fresh
    if event == "PLAYER_MONEY" then
        merchantOpenMoney = GetMoney()
    end
end)

-- Tracker widget
RefreshTracker = function()
    if not ui.tracker then return end

    if not db.trackerShown then
        ui.tracker:Hide()
        return
    end

    ui.tracker:Show()

    if not session then
        ui.tracker.status:SetText("|cffaaaaaaNo session|r")
        ui.tracker.gold:SetText("")
        ui.tracker.rate:SetText("")
        ui.tracker:SetHeight(36)
        return
    end

    local elapsed = Now() - session.startedAt
    ui.tracker.status:SetText("|cffd4af37" .. session.activity .. "|r")
    ui.tracker.gold:SetText(FormatGold(session.gold))
    ui.tracker.rate:SetText(FormatGoldPerHour(session.gold, elapsed))
    ui.tracker.timer:SetText(FormatDuration(elapsed))
    ui.tracker:SetHeight(62)
end

local function CreateTracker()
    if ui.tracker then return end

    local frame = CreateFrame("Frame", "GoldWatchTracker", UIParent, "BackdropTemplate")
    frame:SetSize(180, 62)
    frame:SetPoint(db.trackerPosition.point, UIParent, db.trackerPosition.point, db.trackerPosition.x, db.trackerPosition.y)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetClampedToScreen(true)
    frame:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    frame:SetBackdropColor(0.03, 0.03, 0.04, 0.88)
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, _, x, y = self:GetPoint(1)
        db.trackerPosition.point = point
        db.trackerPosition.x = x
        db.trackerPosition.y = y
    end)
    frame:SetScript("OnMouseUp", function(_, button)
        if button == "RightButton" then
            db.trackerShown = false
            RefreshTracker()
        else
            if not ui.frame then CreateUI() end
            Refresh()
            ui.frame:Show()
        end
    end)

    frame.status = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    frame.status:SetPoint("TOPLEFT", 8, -8)
    frame.status:SetPoint("RIGHT", -8, -8)
    frame.status:SetJustifyH("LEFT")

    frame.gold = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    frame.gold:SetPoint("TOPLEFT", 8, -24)
    frame.gold:SetTextColor(1, 0.82, 0.1)

    frame.rate = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    frame.rate:SetPoint("TOPRIGHT", -8, -26)
    frame.rate:SetJustifyH("RIGHT")
    frame.rate:SetTextColor(0.6, 1, 0.6)

    frame.timer = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    frame.timer:SetPoint("BOTTOMLEFT", 8, 8)

    -- Pulse timer
    frame:SetScript("OnUpdate", function(self, elapsed)
        self._tick = (self._tick or 0) + elapsed
        if self._tick >= 1 then
            self._tick = 0
            RefreshTracker()
        end
    end)

    ui.tracker = frame
    RefreshTracker()
end

-- Main UI rows
local function ClearRows()
    ui.rows = ui.rows or {}
    for _, row in ipairs(ui.rows) do
        row:Hide()
    end
end

local function EnsureRow(index)
    ui.rows = ui.rows or {}
    local row = ui.rows[index]
    if not row then
        row = CreateFrame("Button", nil, ui.content, "BackdropTemplate")
        row:SetHeight(ROW_HEIGHT)
        row:SetBackdrop({
            bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 12,
            insets = { left = 3, right = 3, top = 3, bottom = 3 },
        })
        row:SetBackdropColor(0.03, 0.04, 0.05, 0.86)
        row:SetBackdropBorderColor(0.18, 0.23, 0.28, 0.95)
        row.accent = row:CreateTexture(nil, "ARTWORK")
        row.accent:SetPoint("TOPLEFT", 4, -5)
        row.accent:SetPoint("BOTTOMLEFT", 4, 5)
        row.accent:SetWidth(3)
        row.accent:SetColorTexture(0.84, 0.69, 0.22, 0.95)
        row.left = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        row.left:SetPoint("TOPLEFT", 14, -9)
        row.left:SetPoint("RIGHT", -165, 0)
        row.left:SetJustifyH("LEFT")
        row.right = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.right:SetPoint("TOPRIGHT", -12, -9)
        row.right:SetJustifyH("RIGHT")
        row.sub = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        row.sub:SetPoint("BOTTOMLEFT", 14, 9)
        row.sub:SetPoint("RIGHT", -12, 0)
        row.sub:SetJustifyH("LEFT")
        row.bg = row:CreateTexture(nil, "BACKGROUND")
        row.bg:SetAllPoints()
        row.bg:SetColorTexture(0, 0, 0, 0)
        ui.rows[index] = row
    end
    row:ClearAllPoints()
    row:SetHeight(ROW_HEIGHT)
    row:SetPoint("TOPLEFT", 4, -((index - 1) * RowStep()))
    row:SetPoint("RIGHT", -4, 0)
    row:SetBackdropColor(0.03, 0.04, 0.05, 0.86)
    row:SetBackdropBorderColor(0.18, 0.23, 0.28, 0.95)
    row:SetScript("OnClick", nil)
    row:SetScript("OnEnter", nil)
    row:SetScript("OnLeave", nil)
    row.left:SetTextColor(1, 0.82, 0.1)
    row.right:SetTextColor(1, 1, 1)
    row.sub:SetTextColor(0.62, 0.68, 0.74)
    row:EnableMouse(true)
    row:SetScript("OnEnter", function(self)
        self:SetBackdropColor(0.07, 0.09, 0.11, 0.92)
        self:SetBackdropBorderColor(0.84, 0.69, 0.22, 0.8)
    end)
    row:SetScript("OnLeave", function(self)
        self:SetBackdropColor(0.03, 0.04, 0.05, 0.86)
        self:SetBackdropBorderColor(0.18, 0.23, 0.28, 0.95)
    end)
    row:Show()
    return row
end

local function RenderLive()
    if not session then
        local row = EnsureRow(1)
        row.left:SetText("No active session.")
        row.right:SetText("")
        row.sub:SetText("Use /gw start or click Start Session.")
        return 2
    end

    local elapsed = Now() - session.startedAt
    local rows = {
        { "Activity",  session.activity,                          session.activityType or "" },
        { "Duration",  FormatDuration(elapsed),                   "Time elapsed" },
        { "Gold/hr",   FormatGoldPerHour(session.gold, elapsed),  "Estimated rate" },
        { "Total",     FormatGold(session.gold),                  "This session" },
        { "Loot",      FormatGold(session.loot),                  "From mob drops" },
        { "Vendor",    FormatGold(session.vendor),                "From selling items" },
        { "Quests",    FormatGold(session.quest),                 "From quest rewards" },
        { "Mail",      FormatGold(session.mail),                  "From mailbox" },
    }

    for index, data in ipairs(rows) do
        local row = EnsureRow(index)
        row.left:SetText(data[1])
        row.right:SetText(data[2])
        row.right:SetTextColor(1, 0.82, 0.1)
        row.sub:SetText(data[3])
    end

    return #rows + 1
end

local function RenderHistory()
    if #db.history == 0 then
        local row = EnsureRow(1)
        row.left:SetText("No sessions recorded yet.")
        row.right:SetText("")
        row.sub:SetText("Complete a session to see history.")
        return 2
    end

    for index, record in ipairs(db.history) do
        local row = EnsureRow(index)
        row.left:SetText(record.activity)
        row.right:SetText(FormatGoldPerHour(record.gold, record.duration))
        row.right:SetTextColor(0.6, 1, 0.6)
        row.sub:SetText(FormatGold(record.gold) .. "  |  " .. FormatDuration(record.duration) .. "  |  Loot " .. FormatGold(record.loot) .. "  Vendor " .. FormatGold(record.vendor))
    end

    return #db.history + 1
end

local function RenderSettings()
    local rows = {
        { "Tracker", db.trackerShown and "Shown" or "Hidden", "Click to toggle the compact tracker", function()
            db.trackerShown = not db.trackerShown
            RefreshTracker()
        end },
        { "Clear History", "Clear", "Click twice within 8s to confirm", function()
            local now = Now()
            if ui._pendingClear and now - ui._pendingClear <= 8 then
                db.history = {}
                ui._pendingClear = nil
                Message("History cleared.")
            else
                ui._pendingClear = now
                Message("Click Clear History again within 8 seconds to confirm.")
            end
        end },
    }

    for index, data in ipairs(rows) do
        local row = EnsureRow(index)
        row.left:SetText(data[1])
        row.right:SetText(data[2])
        row.right:SetTextColor(0.72, 0.9, 1)
        row.sub:SetText(data[3])
        row:EnableMouse(true)
        row:SetScript("OnClick", function()
            data[4]()
            Refresh()
        end)
    end

    return #rows + 1
end

local function SetTab(tab)
    db.activeTab = tab
    Refresh()
end

local function UpdateTabs()
    if not ui.tabs then return end
    for tab, button in pairs(ui.tabs) do
        local active = db.activeTab == tab
        button:SetButtonState(active and "PUSHED" or "NORMAL", active)
        if button:GetFontString() then
            if active then
                button:GetFontString():SetTextColor(0.84, 0.69, 0.22)
            else
                button:GetFontString():SetTextColor(0.86, 0.82, 0.68)
            end
        end
    end
end

Refresh = function()
    if not ui.frame or not ui.frame:IsShown() then return end

    ClearRows()
    UpdateTabs()

    local rowIndex
    if db.activeTab == "history" then
        rowIndex = RenderHistory()
    elseif db.activeTab == "settings" then
        rowIndex = RenderSettings()
    else
        rowIndex = RenderLive()
    end

    ui.content:SetHeight(math.max((rowIndex - 1) * RowStep(), ui.frame.scroll:GetHeight()))

    local statusText
    if session then
        local elapsed = Now() - session.startedAt
        statusText = session.activity .. "  —  " .. FormatGold(session.gold) .. "  —  " .. FormatGoldPerHour(session.gold, elapsed)
    else
        statusText = "No active session. Use /gw start or the button below."
    end
    ui.frame.summary:SetText(statusText)
end

CreateUI = function()
    local frame = CreateFrame("Frame", "GoldWatchFrame", UIParent, "BackdropTemplate")
    frame:SetSize(660, 540)
    frame:SetPoint(db.position.point, UIParent, db.position.point, db.position.x, db.position.y)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetClampedToScreen(true)
    frame:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    frame:SetBackdropColor(0.015, 0.018, 0.022, 0.96)
    frame:SetBackdropBorderColor(0.35, 0.29, 0.12, 1)
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, _, x, y = self:GetPoint(1)
        db.position.point = point
        db.position.x = x
        db.position.y = y
    end)

    frame.header = frame:CreateTexture(nil, "BACKGROUND")
    frame.header:SetPoint("TOPLEFT", 5, -5)
    frame.header:SetPoint("TOPRIGHT", -5, -5)
    frame.header:SetHeight(76)
    frame.header:SetColorTexture(0.12, 0.08, 0.02, 0.82)

    frame.headerLine = frame:CreateTexture(nil, "ARTWORK")
    frame.headerLine:SetPoint("TOPLEFT", 16, -76)
    frame.headerLine:SetPoint("TOPRIGHT", -16, -76)
    frame.headerLine:SetHeight(1)
    frame.headerLine:SetColorTexture(0.84, 0.69, 0.22, 0.55)

    frame.title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    frame.title:SetPoint("TOPLEFT", 18, -16)
    frame.title:SetText("|cffd4af37GoldWatch|r")

    frame.subtitle = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    frame.subtitle:SetPoint("TOPLEFT", 18, -38)
    frame.subtitle:SetText("Session income and gold-per-hour tracker")

    frame.close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    frame.close:SetPoint("TOPRIGHT", -8, -8)
    frame.close:SetScript("OnClick", function()
        frame:Hide()
    end)

    ui.tabs = {}
    local tabDefs = {
        { "live", "Live" },
        { "history", "History" },
        { "settings", "Settings" },
    }
    local prev
    for _, tab in ipairs(tabDefs) do
        local button = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
        button:SetSize(96, 22)
        if prev then
            button:SetPoint("LEFT", prev, "RIGHT", 5, 0)
        else
            button:SetPoint("TOPLEFT", 18, -58)
        end
        button:SetText(tab[2])
        button:SetScript("OnClick", function() SetTab(tab[1]) end)
        ui.tabs[tab[1]] = button
        prev = button
    end

    frame.summary = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    frame.summary:SetPoint("TOPLEFT", 18, -94)
    frame.summary:SetPoint("RIGHT", -18, -94)
    frame.summary:SetJustifyH("LEFT")

    frame.scroll = CreateFrame("ScrollFrame", "GoldWatchScrollFrame", frame, "UIPanelScrollFrameTemplate")
    frame.scroll:SetPoint("TOPLEFT", 14, -120)
    frame.scroll:SetPoint("BOTTOMRIGHT", -32, 56)

    ui.content = CreateFrame("Frame", nil, frame.scroll)
    ui.content:SetSize(600, 340)
    frame.scroll:SetScrollChild(ui.content)
    frame.scroll:SetScript("OnSizeChanged", function(_, width, height)
        ui.content:SetWidth(width)
        ui.content:SetHeight(math.max(ui.content:GetHeight(), height))
    end)

    -- Start / Stop buttons
    frame.startBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    frame.startBtn:SetSize(110, 26)
    frame.startBtn:SetPoint("BOTTOMLEFT", 18, 17)
    frame.startBtn:SetText("Start Session")
    frame.startBtn:SetScript("OnClick", function()
        if session then
            Message("Session already running. Use /gw stop first.")
        else
            NewSession()
            Refresh()
        end
    end)

    frame.stopBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    frame.stopBtn:SetSize(110, 26)
    frame.stopBtn:SetPoint("LEFT", frame.startBtn, "RIGHT", 8, 0)
    frame.stopBtn:SetText("Stop & Save")
    frame.stopBtn:SetScript("OnClick", function()
        StopSession()
        Refresh()
    end)

    -- Live refresh ticker
    frame:SetScript("OnUpdate", function(self, elapsed)
        self._tick = (self._tick or 0) + elapsed
        if self._tick >= 1 then
            self._tick = 0
            if db.activeTab == "live" and session then
                Refresh()
            end
        end
    end)

    ui.frame = frame
    frame:Hide()
end

local function ToggleUI()
    if not ui.frame then CreateUI() end
    if ui.frame:IsShown() then
        ui.frame:Hide()
    else
        Refresh()
        ui.frame:Show()
    end
end

local function PrintHelp()
    Message("/gw — Toggle the window.")
    Message("/gw start — Start a new session.")
    Message("/gw stop — Stop and save the current session.")
    Message("/gw tracker — Toggle the compact tracker.")
end

SLASH_GOLDWATCH1 = "/gw"
SLASH_GOLDWATCH2 = "/goldwatch"
SlashCmdList.GOLDWATCH = function(message)
    message = Trim(message)
    local lower = string.lower(message)

    if lower == "start" then
        if session then
            Message("Session already running.")
        else
            NewSession()
        end
    elseif lower == "stop" then
        StopSession()
    elseif lower == "tracker" then
        db.trackerShown = not db.trackerShown
        RefreshTracker()
        Message(db.trackerShown and "Tracker shown." or "Tracker hidden.")
    elseif lower == "help" then
        PrintHelp()
    else
        ToggleUI()
    end
end

EventUtil.ContinueOnAddOnLoaded(ADDON_NAME, function()
    EnsureDB()
    lastMoney = GetMoney()
    CreateTracker()
    Message("Loaded. Type /gw to open or /gw start to begin tracking.")
end)

-- Armada Addons hub registration
C_Timer.After(0, function()
    if ArmadaAddons and ArmadaAddons.Register then
        ArmadaAddons.Register({
            name = "GoldWatch",
            version = "1.0.0",
            desc = "Farm spot tracker with auto activity detection and gold/hr.",
            color = { 1, 0.82, 0.1 },
            open = function()
                ToggleUI()
            end,
        })
    end
end)

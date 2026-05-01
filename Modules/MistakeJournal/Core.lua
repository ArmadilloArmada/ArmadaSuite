local ADDON_NAME = "ArmadaSuite"

local TAGS = {
    "Positioning",
    "Missed defensive",
    "Missed interrupt",
    "Mechanic unknown",
    "Greed",
    "Healer out of range",
    "Other",
}

local INTERRUPT_SPELLS = {
    [1766] = true,   -- Kick
    [2139] = true,   -- Counterspell
    [6552] = true,   -- Pummel
    [19647] = true,  -- Spell Lock
    [47528] = true,  -- Mind Freeze
    [57994] = true,  -- Wind Shear
    [96231] = true,  -- Rebuke
    [106839] = true, -- Skull Bash
    [116705] = true, -- Spear Hand Strike
    [132409] = true, -- Spell Lock command demon
    [147362] = true, -- Counter Shot
    [183752] = true, -- Disrupt
    [187707] = true, -- Muzzle
    [212619] = true, -- Call Felhunter
    [231665] = true, -- Avengers Shield interrupt aura cases
    [351338] = true, -- Quell
}

local DAMAGE_EVENTS = {
    SWING_DAMAGE = true,
    RANGE_DAMAGE = true,
    SPELL_DAMAGE = true,
    SPELL_PERIODIC_DAMAGE = true,
    SPELL_BUILDING_DAMAGE = true,
    ENVIRONMENTAL_DAMAGE = true,
}

local addon = {}
local db
local ui = {}
local playerGUID
local currentEncounter
local pendingDeathPopup
local pendingRefresh = false
local lastDeathAt = 0
local lastSpikeAt = 0
local pendingReset

local recentDamage = {}
local recentCasts = {}
local pendingInterrupts = {}
local session = {
    deaths = 0,
    spikes = 0,
    interrupts = 0,
    failedInterrupts = 0,
    markers = 0,
    startedAt = time(),
}

local Refresh
local CreateUI
local ShowDeathPopup
local ToggleUI
local ROW_HEIGHT = 56
local ROW_GAP = 6
local function CreateSimpleButton(parent, text)
    local button = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    button:SetSize(96, 22)
    button:SetText(text or "")
    return button
end

local function CreateCloseButton(parent, onClick)
    local button = CreateFrame("Button", nil, parent)
    button:SetSize(20, 20)
    button:SetNormalTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Up")
    button:SetPushedTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Down")
    button:SetHighlightTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Highlight")
    if onClick then button:SetScript("OnClick", onClick) end
    return button
end

local function RowStep()
    return ROW_HEIGHT + ROW_GAP
end

local function UpdateMinimapButton() end
local function CreateMinimapButton() end


local function Now()
    return GetServerTime()
end

local function Message(text)
    print("|cffdd7777Mistake Journal:|r " .. text)
end

local function Trim(text)
    return strtrim(text or "")
end

local function CharacterKey()
    return (UnitName("player") or "Unknown") .. "-" .. (GetRealmName() or "Unknown")
end

local function CurrentSpec()
    if not GetSpecialization or not GetSpecializationInfo then
        return "Unknown"
    end

    local specIndex = GetSpecialization()
    if not specIndex then
        return "Unknown"
    end

    local _, specName = GetSpecializationInfo(specIndex)
    return specName or "Unknown"
end

local function CurrentZone()
    local instanceName, instanceType = GetInstanceInfo()
    if instanceName and instanceName ~= "" then
        return instanceName, instanceType
    end
    return GetZoneText() or "Unknown", "world"
end

local function FormatClock(timestamp)
    return date("%m/%d %H:%M", timestamp or Now())
end

local function DurationText(seconds)
    seconds = math.max(0, seconds or 0)
    local minutes = math.floor(seconds / 60)
    local remaining = seconds % 60
    return tostring(minutes) .. "m " .. tostring(remaining) .. "s"
end

local function EnsureDB()
    MistakeJournalDB = MistakeJournalDB or {}
    db = MistakeJournalDB
    db.deaths = db.deaths or {}
    db.spikes = db.spikes or {}
    db.interrupts = db.interrupts or {}
    db.markers = db.markers or {}
    db.settings = db.settings or {}
    if db.settings.popup == nil then db.settings.popup = false end
    db.settings.spikePercent = db.settings.spikePercent or 35
    db.settings.maxRecords = db.settings.maxRecords or 250
    db.position = db.position or { point = "CENTER", x = 0, y = 0 }
    db.activeTab = db.activeTab or "deaths"
    db.focusNote = db.focusNote or ""
    db.lastSession = db.lastSession or {
        deaths = 0,
        spikes = 0,
        interrupts = 0,
        failedInterrupts = 0,
        markers = 0,
        duration = 0,
        endedAt = 0,
        note = "",
    }
end

local function SaveSessionHistory()
    if session.deaths == 0 and session.spikes == 0 and session.interrupts == 0 and session.failedInterrupts == 0 and session.markers == 0 then
        return
    end

    db.lastSession = {
        deaths = session.deaths,
        spikes = session.spikes,
        interrupts = session.interrupts,
        failedInterrupts = session.failedInterrupts,
        markers = session.markers,
        duration = math.max(0, Now() - session.startedAt),
        endedAt = Now(),
        note = db.focusNote or "",
    }
end

local function Prune(list)
    local maxRecords = db.settings.maxRecords or 250
    while #list > maxRecords do
        table.remove(list, 1)
    end
end

local function PushRecent(list, value, maxItems)
    list[#list + 1] = value
    while #list > maxItems do
        table.remove(list, 1)
    end
end

local function CopyRecentEvents(list, secondsBack, maxItems)
    local copied = {}
    local cutoff = Now() - secondsBack

    for index = #list, 1, -1 do
        local item = list[index]
        if item.timestamp and item.timestamp >= cutoff then
            table.insert(copied, 1, item)
            if #copied >= maxItems then
                break
            end
        end
    end

    return copied
end

local function BuildContext()
    local zone, instanceType = CurrentZone()
    return {
        character = CharacterKey(),
        spec = CurrentSpec(),
        level = UnitLevel("player") or 0,
        zone = zone,
        instanceType = instanceType,
        encounter = currentEncounter and currentEncounter.name or nil,
        timestamp = Now(),
    }
end

local function DamageAmountFromEvent(subevent, ...)
    if subevent == "SWING_DAMAGE" then
        local amount, overkill, school = ...
        return amount or 0, "Melee", school
    elseif subevent == "ENVIRONMENTAL_DAMAGE" then
        local environmentalType, amount = ...
        return amount or 0, environmentalType or "Environment", nil
    end

    local spellId, spellName, spellSchool, amount = ...
    return amount or 0, spellName or ("Spell " .. tostring(spellId or "?")), spellSchool
end

local function AddDamageEvent(timestamp, sourceName, subevent, amount, ability)
    local maxHealth = UnitHealthMax("player") or 1
    local percent = maxHealth > 0 and math.floor((amount / maxHealth) * 100 + 0.5) or 0

    PushRecent(recentDamage, {
        timestamp = timestamp,
        source = sourceName or "Unknown",
        event = subevent,
        amount = amount,
        percent = percent,
        ability = ability or "Unknown",
    }, 40)
end

local function LogSpike(timestamp, sourceName, subevent, amount, ability)
    local maxHealth = UnitHealthMax("player") or 1
    if maxHealth <= 0 then
        return
    end

    local percent = (amount / maxHealth) * 100
    local threshold = db.settings.spikePercent or 35
    if percent < threshold then
        return
    end

    if Now() - lastSpikeAt < 6 then
        return
    end

    local context = BuildContext()
    context.source = sourceName or "Unknown"
    context.event = subevent
    context.amount = amount
    context.percent = math.floor(percent + 0.5)
    context.ability = ability or "Unknown"
    context.note = ""
    context.tag = "Damage spike"

    db.spikes[#db.spikes + 1] = context
    lastSpikeAt = Now()
    session.spikes = session.spikes + 1
    Prune(db.spikes)
end

local function LogPlayerCast(timestamp, spellName)
    PushRecent(recentCasts, {
        timestamp = timestamp,
        spell = spellName or "Unknown",
    }, 20)
end

local function ResolvePendingInterrupt(spellId, success)
    for index = #pendingInterrupts, 1, -1 do
        local item = pendingInterrupts[index]
        if item.spellId == spellId and Now() - item.timestamp <= 3 then
            item.success = success
            return table.remove(pendingInterrupts, index)
        end
    end
end

local function LogInterruptAttempt(item, success, extra)
    local context = BuildContext()
    context.spell = item.spellName or "Interrupt"
    context.success = success == true
    context.target = extra and extra.target or item.target or "Unknown"
    context.interruptedSpell = extra and extra.interruptedSpell or nil

    db.interrupts[#db.interrupts + 1] = context
    if context.success then
        session.interrupts = session.interrupts + 1
    else
        session.failedInterrupts = session.failedInterrupts + 1
    end
    Prune(db.interrupts)
end

local function FlushExpiredInterrupts()
    for index = #pendingInterrupts, 1, -1 do
        local item = pendingInterrupts[index]
        if Now() - item.timestamp > 2 then
            table.remove(pendingInterrupts, index)
            LogInterruptAttempt(item, false)
        end
    end
end

local function AddDeathRecord(source)
    local now = Now()
    if now - lastDeathAt < 5 then
        return
    end
    lastDeathAt = now

    local context = BuildContext()
    context.id = tostring(now) .. "-" .. tostring(#db.deaths + 1)
    context.source = source or "PLAYER_DEAD"
    context.damage = CopyRecentEvents(recentDamage, 14, 10)
    context.casts = CopyRecentEvents(recentCasts, 18, 6)
    context.tag = "Untagged"
    context.note = ""
    context.manual = false

    db.deaths[#db.deaths + 1] = context
    session.deaths = session.deaths + 1
    Prune(db.deaths)

    if db.settings.popup then
        pendingDeathPopup = context
        Message("Death recorded. Open /mj to add a note after combat.")
    else
        Message("Death recorded. Open /mj to add a note.")
    end

    Refresh()
end

local function AddMarker(note)
    local context = BuildContext()
    context.note = Trim(note)
    context.note = context.note ~= "" and context.note or "Manual marker"
    db.markers[#db.markers + 1] = context
    session.markers = session.markers + 1
    Prune(db.markers)
    Refresh()
    Message("Marker added.")
end

local function CountTags()
    local counts = {}
    local topTag = "None"
    local topCount = 0

    for _, death in ipairs(db.deaths) do
        local tag = death.tag or "Untagged"
        counts[tag] = (counts[tag] or 0) + 1
        if counts[tag] > topCount then
            topTag = tag
            topCount = counts[tag]
        end
    end

    return counts, topTag, topCount
end

local function ExportSummary()
    local _, topTag, topCount = CountTags()
    Message("Summary export:")
    print("MistakeJournal session deaths=" .. session.deaths .. " spikes=" .. session.spikes .. " interrupts=" .. session.interrupts .. " failed=" .. session.failedInterrupts .. " markers=" .. session.markers .. " focus='" .. (db.focusNote ~= "" and db.focusNote or "None") .. "'")
    print("Last session deaths=" .. db.lastSession.deaths .. " spikes=" .. db.lastSession.spikes .. " interrupts=" .. db.lastSession.interrupts .. " failed=" .. db.lastSession.failedInterrupts .. " markers=" .. db.lastSession.markers .. " duration='" .. DurationText(db.lastSession.duration) .. "' note='" .. (db.lastSession.note ~= "" and db.lastSession.note or "None") .. "'")
    print("Saved deaths=" .. #db.deaths .. " spikes=" .. #db.spikes .. " interrupts=" .. #db.interrupts .. " markers=" .. #db.markers .. " topTag=" .. topTag .. "(" .. topCount .. ")")
end

local function ClearSession()
    SaveSessionHistory()
    session.deaths = 0
    session.spikes = 0
    session.interrupts = 0
    session.failedInterrupts = 0
    session.markers = 0
    session.startedAt = Now()
    Refresh()
    Message("Session counters cleared.")
end

local function ResetAll()
    if not pendingReset or Now() - pendingReset > 8 then
        pendingReset = Now()
        Message("Run /mj reset confirm within 8 seconds to clear all saved records.")
        return
    end

    db.deaths = {}
    db.spikes = {}
    db.interrupts = {}
    db.markers = {}
    pendingReset = nil
    ClearSession()
    Message("All saved records cleared.")
end

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
        row.accent:SetColorTexture(1, 0.34, 0.26, 0.95)
        row.left = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        row.left:SetPoint("TOPLEFT", 14, -9)
        row.left:SetPoint("RIGHT", -145, 0)
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
        row.bg:SetColorTexture(1, 1, 1, 0)
        ui.rows[index] = row
    end

    row:ClearAllPoints()
    row:SetHeight(ROW_HEIGHT)
    row:SetPoint("TOPLEFT", 4, -((index - 1) * RowStep()))
    row:SetPoint("RIGHT", -4, 0)
    row:SetScript("OnClick", nil)
    row:SetScript("OnEnter", nil)
    row:SetScript("OnLeave", nil)
    row:SetBackdropColor(0.03, 0.04, 0.05, 0.86)
    row:SetBackdropBorderColor(0.18, 0.23, 0.28, 0.95)
    row.bg:SetColorTexture(0, 0, 0, 0)
    row.left:SetTextColor(1, 0.82, 0.1)
    row.right:SetTextColor(1, 1, 1)
    row.sub:SetTextColor(0.62, 0.68, 0.74)
    row:EnableMouse(true)
    row:SetScript("OnEnter", function(self)
        self:SetBackdropColor(0.07, 0.09, 0.11, 0.92)
        self:SetBackdropBorderColor(1, 0.34, 0.26, 0.8)
    end)
    row:SetScript("OnLeave", function(self)
        self:SetBackdropColor(0.03, 0.04, 0.05, 0.86)
        self:SetBackdropBorderColor(0.18, 0.23, 0.28, 0.95)
    end)
    row:Show()
    return row
end

local function DeathSummary(death)
    local topDamage = death.damage and death.damage[#death.damage]
    if topDamage then
        return topDamage.ability .. " from " .. topDamage.source .. " for " .. topDamage.amount .. " (" .. topDamage.percent .. "%)"
    end
    return "No recent damage captured."
end

local function SetDeathTag(death, tag)
    death.tag = tag
    Refresh()
end

local function RenderDeaths()
    local rowIndex = 1
    for index = #db.deaths, 1, -1 do
        local death = db.deaths[index]
        local row = EnsureRow(rowIndex)
        row.left:SetText(FormatClock(death.timestamp) .. "  " .. (death.encounter or death.zone or "Unknown"))
        row.right:SetText(death.tag or "Untagged")
        row.sub:SetText(DeathSummary(death))
        row:SetScript("OnClick", function()
            ShowDeathPopup(death)
        end)
        rowIndex = rowIndex + 1
    end
    return rowIndex
end

local function RenderSpikes()
    local rowIndex = 1
    for index = #db.spikes, 1, -1 do
        local spike = db.spikes[index]
        local row = EnsureRow(rowIndex)
        row.left:SetText(FormatClock(spike.timestamp) .. "  " .. spike.ability)
        row.right:SetText(spike.percent .. "%")
        row.sub:SetText((spike.source or "Unknown") .. " in " .. (spike.encounter or spike.zone or "Unknown") .. " for " .. spike.amount)
        rowIndex = rowIndex + 1
    end
    return rowIndex
end

local function RenderInterrupts()
    local rowIndex = 1
    for index = #db.interrupts, 1, -1 do
        local interrupt = db.interrupts[index]
        local row = EnsureRow(rowIndex)
        row.left:SetText(FormatClock(interrupt.timestamp) .. "  " .. interrupt.spell)
        row.right:SetText(interrupt.success and "Success" or "Likely missed")
        row.right:SetTextColor(interrupt.success and 0.25 or 1, interrupt.success and 1 or 0.35, 0.25)
        row.sub:SetText((interrupt.target or "Unknown") .. (interrupt.interruptedSpell and (" - stopped " .. interrupt.interruptedSpell) or ""))
        rowIndex = rowIndex + 1
    end
    return rowIndex
end

local function RenderMarkers()
    local rowIndex = 1
    for index = #db.markers, 1, -1 do
        local marker = db.markers[index]
        local row = EnsureRow(rowIndex)
        row.left:SetText(FormatClock(marker.timestamp) .. "  " .. (marker.encounter or marker.zone or "Marker"))
        row.right:SetText(marker.spec or "")
        row.sub:SetText(marker.note or "")
        rowIndex = rowIndex + 1
    end
    return rowIndex
end

local function RenderSession()
    local rows = {
        { "Session focus", db.focusNote ~= "" and db.focusNote or "None", "Current self-review focus" },
        { "Session duration", DurationText(Now() - session.startedAt), "Time since session began" },
        { "Session deaths", tostring(session.deaths), "Recorded this session" },
        { "Session spikes", tostring(session.spikes), "Health spikes this session" },
        { "Session interrupts", tostring(session.interrupts) .. " / " .. tostring(session.failedInterrupts), "Interrupts success / likely missed" },
        { "Saved death records", tostring(#db.deaths), "All-time saved deaths" },
        { "Last session summary", tostring(db.lastSession.deaths or 0) .. " deaths, " .. tostring(db.lastSession.spikes or 0) .. " spikes", "Previous session totals" },
        { "Last session duration", DurationText(db.lastSession.duration or 0), "Previous session length" },
        { "Last session note", db.lastSession.note ~= "" and db.lastSession.note or "None", "Previous session focus note" },
    }

    for index, data in ipairs(rows) do
        local row = EnsureRow(index)
        row.left:SetText(data[1])
        row.right:SetText(data[2])
        row.sub:SetText(data[3])
    end

    return #rows + 1
end

local function RenderStats()
    local counts, topTag, topCount = CountTags()
    local rows = {
        { "All deaths", tostring(#db.deaths), "Saved death records" },
        { "All spikes", tostring(#db.spikes), "Saved damage spike records" },
        { "All interrupts", tostring(#db.interrupts), "Saved interrupt records" },
        { "Most common tag", topTag, tostring(topCount) .. " deaths" },
        { "Positioning", tostring(counts["Positioning"] or 0), "Tagged death count" },
        { "Missed defensive", tostring(counts["Missed defensive"] or 0), "Tagged death count" },
        { "Greed", tostring(counts["Greed"] or 0), "Tagged death count" },
    }

    for index, data in ipairs(rows) do
        local row = EnsureRow(index)
        row.left:SetText(data[1])
        row.right:SetText(data[2])
        row.sub:SetText(data[3])
    end

    return #rows + 1
end

local function RenderSettings()
    local rows = {
        { "Post-death popup", db.settings.popup and "On" or "Off", "Click to toggle", function()
            db.settings.popup = not db.settings.popup
        end },
        { "Spike threshold", tostring(db.settings.spikePercent) .. "%", "Click to cycle 25 / 35 / 50", function()
            if db.settings.spikePercent == 25 then
                db.settings.spikePercent = 35
            elseif db.settings.spikePercent == 35 then
                db.settings.spikePercent = 50
            else
                db.settings.spikePercent = 25
            end
        end },
        { "Export summary", "Print", "Click to print a compact summary", ExportSummary },
        { "Clear session", "Clear", "Click to clear session counters", ClearSession },
    }

    for index, data in ipairs(rows) do
        local row = EnsureRow(index)
        row.left:SetText(data[1])
        row.right:SetText(data[2])
        row.sub:SetText(data[3])
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
    if not ui.tabs then
        return
    end

    for tab, button in pairs(ui.tabs) do
        local active = db.activeTab == tab
        button:SetButtonState(active and "PUSHED" or "NORMAL", active)
        if button:GetFontString() then
            if active then
                button:GetFontString():SetTextColor(1, 0.34, 0.26)
            else
                button:GetFontString():SetTextColor(0.86, 0.82, 0.68)
            end
        end
    end
end

CreateUI = function()
    local frame = CreateFrame("Frame", "MistakeJournalFrame", UIParent, "BackdropTemplate")
    frame:SetSize(760, 560)
    frame:SetPoint(db.position.point, UIParent, db.position.point, db.position.x, db.position.y)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetClampedToScreen(true)
    frame:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true,
        tileSize = 16,
        edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    frame:SetBackdropColor(0.015, 0.018, 0.022, 0.96)
    frame:SetBackdropBorderColor(0.42, 0.16, 0.13, 1)
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
    frame.header:SetColorTexture(0.12, 0.03, 0.03, 0.82)

    frame.headerLine = frame:CreateTexture(nil, "ARTWORK")
    frame.headerLine:SetPoint("TOPLEFT", 16, -76)
    frame.headerLine:SetPoint("TOPRIGHT", -16, -76)
    frame.headerLine:SetHeight(1)
    frame.headerLine:SetColorTexture(1, 0.34, 0.26, 0.55)

    frame.title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    frame.title:SetPoint("TOPLEFT", 18, -16)
    frame.title:SetText("|cffff5742Mistake|r Journal")

    frame.subtitle = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    frame.subtitle:SetPoint("TOPLEFT", 18, -38)
    frame.subtitle:SetText("Combat review, deaths, spikes, interrupts, and session notes")

    frame.close = CreateCloseButton(frame, function() frame:Hide() end)
    frame.close:SetPoint("TOPRIGHT", -8, -8)

    ui.tabs = {}
    local tabs = {
        { "deaths", "Deaths" },
        { "spikes", "Spikes" },
        { "interrupts", "Interrupts" },
        { "markers", "Markers" },
        { "session", "Session" },
        { "stats", "Stats" },
        { "settings", "Settings" },
    }

    local previous
    for _, tab in ipairs(tabs) do
        local button = CreateSimpleButton(frame, tab[2])
        button:SetSize(96, 22)
        if previous then
            button:SetPoint("LEFT", previous, "RIGHT", 5, 0)
        else
            button:SetPoint("TOPLEFT", 18, -58)
        end
        button:SetScript("OnClick", function()
            SetTab(tab[1])
        end)
        ui.tabs[tab[1]] = button
        previous = button
    end

    frame.summary = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    frame.summary:SetPoint("TOPLEFT", 18, -94)
    frame.summary:SetPoint("RIGHT", -18, -94)
    frame.summary:SetJustifyH("LEFT")

    frame.scroll = CreateFrame("ScrollFrame", "MistakeJournalScrollFrame", frame, "UIPanelScrollFrameTemplate,BackdropTemplate")
    frame.scroll:SetPoint("TOPLEFT", 14, -120)
    frame.scroll:SetPoint("BOTTOMRIGHT", -38, 24)
    frame.scroll:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true,
        tileSize = 16,
        edgeSize = 16,
        insets = { left = 6, right = 6, top = 6, bottom = 6 },
    })
    frame.scroll:SetBackdropColor(0, 0, 0, 0)
    frame.scroll:SetBackdropBorderColor(0, 0, 0, 0)

    ui.content = CreateFrame("Frame", nil, frame.scroll)
    ui.content:SetSize(690, 390)
    frame.scroll:SetScrollChild(ui.content)
    frame.scroll:SetScript("OnSizeChanged", function(_, width, height)
        ui.content:SetWidth(width)
        ui.content:SetHeight(math.max(ui.content:GetHeight(), height))
    end)

    ui.frame = frame
    frame:Hide()
end

local function SavePopupNote(death)
    if not ui.popup then
        return
    end
    death.note = ui.popup.note:GetText() or ""
    Refresh()
    ui.popup:Hide()
    Message("Death note saved.")
end

ShowDeathPopup = function(death)
    if not death then
        return
    end

    if InCombatLockdown() then
        pendingDeathPopup = death
        return
    end

    if not ui.popup then
        local popup = CreateFrame("Frame", "MistakeJournalDeathPopup", UIParent, "BackdropTemplate")
        popup:SetSize(520, 360)
        popup:SetPoint("CENTER", UIParent, "CENTER", 0, 80)
        popup:EnableMouse(true)
        popup:SetMovable(true)
        popup:RegisterForDrag("LeftButton")
        popup:SetBackdrop({
            bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            tile = true,
            tileSize = 32,
            edgeSize = 32,
            insets = { left = 10, right = 10, top = 10, bottom = 10 },
        })
        popup:SetScript("OnDragStart", popup.StartMoving)
        popup:SetScript("OnDragStop", popup.StopMovingOrSizing)

        popup.title = popup:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        popup.title:SetPoint("TOPLEFT", 18, -16)

        popup.close = CreateCloseButton(popup, function() popup:Hide() end)
        popup.close:SetPoint("TOPRIGHT", -8, -8)

        popup.summary = popup:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        popup.summary:SetPoint("TOPLEFT", 18, -48)
        popup.summary:SetPoint("RIGHT", -18, -48)
        popup.summary:SetJustifyH("LEFT")

        popup.damage = popup:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        popup.damage:SetPoint("TOPLEFT", 18, -78)
        popup.damage:SetPoint("RIGHT", -18, -78)
        popup.damage:SetJustifyH("LEFT")

        popup.tagButtons = {}
        local previous
        for index, tag in ipairs(TAGS) do
            local button = CreateSimpleButton(popup, tag)
            button:SetSize(112, 22)
            if index == 1 then
                button:SetPoint("TOPLEFT", 18, -150)
            elseif (index - 1) % 4 == 0 then
                button:SetPoint("TOPLEFT", 18, -150 - math.floor((index - 1) / 4) * 26)
            else
                button:SetPoint("LEFT", previous, "RIGHT", 6, 0)
            end
            button:SetScript("OnClick", function()
                if popup.death then
                    SetDeathTag(popup.death, tag)
                    popup.selected:SetText("Tag: " .. tag)
                end
            end)
            popup.tagButtons[tag] = button
            previous = button
        end

        popup.selected = popup:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        popup.selected:SetPoint("TOPLEFT", 18, -206)

        popup.note = CreateFrame("EditBox", nil, popup, "BackdropTemplate")
        popup.note:SetFontObject("GameFontNormalSmall")
        popup.note:SetSize(360, 24)
        popup.note:SetPoint("TOPLEFT", 18, -234)
        popup.note:SetAutoFocus(false)
        popup.note:SetBackdrop({
            bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            tile = true,
            tileSize = 16,
            edgeSize = 16,
            insets = { left = 4, right = 4, top = 4, bottom = 4 },
        })
        popup.note:SetBackdropColor(0, 0, 0, 0.5)
        popup.note:SetTextInsets(6, 6, 4, 4)

        popup.save = CreateSimpleButton(popup, "Save")
        popup.save:SetSize(86, 22)
        popup.save:SetPoint("LEFT", popup.note, "RIGHT", 12, 0)
        popup.save:SetScript("OnClick", function()
            SavePopupNote(popup.death)
        end)

        ui.popup = popup
    end

    local popup = ui.popup
    popup.death = death
    popup.title:SetText("Death Review")
    popup.summary:SetText((death.encounter or death.zone or "Unknown") .. "  |  " .. FormatClock(death.timestamp) .. "  |  " .. (death.spec or "Unknown"))

    local lines = {}
    for _, damage in ipairs(death.damage or {}) do
        lines[#lines + 1] = damage.ability .. " - " .. damage.amount .. " (" .. damage.percent .. "%)"
    end
    popup.damage:SetText(#lines > 0 and table.concat(lines, "\n") or "No recent damage captured.")
    popup.selected:SetText("Tag: " .. (death.tag or "Untagged"))
    popup.note:SetText(death.note or "")
    popup:Show()
end

Refresh = function()
    if InCombatLockdown() then
        pendingRefresh = true
        return
    end

    if not ui.frame or not ui.frame:IsShown() then
        return
    end

    ClearRows()
    UpdateTabs()

    local rowIndex
    if db.activeTab == "spikes" then
        rowIndex = RenderSpikes()
    elseif db.activeTab == "interrupts" then
        rowIndex = RenderInterrupts()
    elseif db.activeTab == "markers" then
        rowIndex = RenderMarkers()
    elseif db.activeTab == "session" then
        rowIndex = RenderSession()
    elseif db.activeTab == "stats" then
        rowIndex = RenderStats()
    elseif db.activeTab == "settings" then
        rowIndex = RenderSettings()
    else
        rowIndex = RenderDeaths()
    end

    ui.content:SetHeight(math.max((rowIndex - 1) * RowStep(), ui.frame.scroll:GetHeight()))
    ui.frame.summary:SetText("Session: " .. session.deaths .. " deaths, " .. session.spikes .. " spikes, " .. session.interrupts .. " interrupts, " .. session.failedInterrupts .. " likely missed.")
end

ToggleUI = function()
    if InCombatLockdown() then
        Message("Cannot open Mistake Journal during combat.")
        return
    end

    if not ui.frame then
        CreateUI()
    end
    if ui.frame:IsShown() then
        ui.frame:Hide()
    else
        Refresh()
        ui.frame:Show()
    end
end

local function HandleCombatLog()
    FlushExpiredInterrupts()

    local timestamp, subevent, _, sourceGUID, sourceName, _, _, destGUID, destName, _, _, arg1, arg2, arg3, arg4, arg5, arg6 = CombatLogGetCurrentEventInfo()
    if not playerGUID then
        playerGUID = UnitGUID("player")
    end

    if DAMAGE_EVENTS[subevent] and destGUID == playerGUID then
        local amount, ability = DamageAmountFromEvent(subevent, arg1, arg2, arg3, arg4, arg5, arg6)
        AddDamageEvent(timestamp, sourceName, subevent, amount, ability)
        LogSpike(timestamp, sourceName, subevent, amount, ability)
    elseif subevent == "SPELL_CAST_SUCCESS" and sourceGUID == playerGUID then
        local spellId, spellName = arg1, arg2
        LogPlayerCast(timestamp, spellName)
        if INTERRUPT_SPELLS[spellId] then
            pendingInterrupts[#pendingInterrupts + 1] = {
                timestamp = Now(),
                spellId = spellId,
                spellName = spellName,
                target = destName,
            }
        end
    elseif subevent == "SPELL_INTERRUPT" and sourceGUID == playerGUID then
        local spellId, spellName, _, extraSpellId, extraSpellName = arg1, arg2, arg3, arg4, arg5
        local item = ResolvePendingInterrupt(spellId, true) or {
            timestamp = Now(),
            spellId = spellId,
            spellName = spellName,
            target = destName,
        }
        LogInterruptAttempt(item, true, {
            target = destName,
            interruptedSpell = extraSpellName or tostring(extraSpellId or ""),
        })
    elseif subevent == "UNIT_DIED" and destGUID == playerGUID then
        AddDeathRecord("UNIT_DIED")
    end
end

local function SetFocusNote(note)
    db.focusNote = Trim(note)
    Message("Session focus set: " .. (db.focusNote ~= "" and db.focusNote or "None"))
    Refresh()
end

local function PrintHelp()
    Message("/mj - Toggle the journal.")
    Message("/mj mark note text - Add a manual marker.")
    Message("/mj focus note text - Set a session focus note.")
    Message("/mj minimap - Minimap button was removed; use /armada.")
    Message("/mj export - Print a compact summary.")
    Message("/mj clear session - Clear session counters.")
    Message("/mj reset - Start all-record reset confirmation.")
    Message("/mj reset confirm - Confirm all-record reset.")
end

SLASH_MISTAKEJOURNAL1 = "/mj"
SLASH_MISTAKEJOURNAL2 = "/mistakejournal"
SlashCmdList.MISTAKEJOURNAL = function(message)
    message = Trim(message)
    local lower = string.lower(message)

    if lower == "help" then
        PrintHelp()
    elseif lower == "export" then
        ExportSummary()
    elseif lower == "clear session" then
        ClearSession()
    elseif lower == "reset" then
        ResetAll()
    elseif lower == "reset confirm" then
        ResetAll()
    elseif string.sub(lower, 1, 5) == "mark " then
        AddMarker(string.sub(message, 6))
    elseif lower == "mark" then
        AddMarker("Manual marker")
    elseif lower == "minimap" then
        Message("Minimap button removed. Use /armada to open the suite.")
    elseif lower == "debug" then
        Message("activeTab=" .. tostring(db.activeTab) .. " focusNote=" .. tostring(db.focusNote ~= ""))
    elseif lower == "launcher" then
        Message("Launcher support is disabled. Use /mj or /armada.")
    elseif string.sub(lower, 1, 6) == "focus " then
        SetFocusNote(string.sub(message, 7))
    elseif lower == "focus" then
        SetFocusNote("")
    else
        ToggleUI()
    end
end

local function OnEvent(event, ...)
    local arg1, arg2 = ...
    if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
        EnsureDB()
    elseif event == "PLAYER_LOGIN" then
        playerGUID = UnitGUID("player")
        if not db then EnsureDB() end
        Message("Loaded. Type /mj to open.")
    elseif event == "PLAYER_ENTERING_WORLD" then
        if not db then EnsureDB() end
    elseif event == "COMBAT_LOG_EVENT_UNFILTERED" then
        HandleCombatLog()
    elseif event == "ENCOUNTER_START" then
        currentEncounter = { id = arg1, name = arg2 }
    elseif event == "ENCOUNTER_END" then
        currentEncounter = nil
    elseif event == "PLAYER_REGEN_DISABLED" then
        -- combat started
    elseif event == "PLAYER_REGEN_ENABLED" then
        FlushExpiredInterrupts()
        if pendingDeathPopup then
            ShowDeathPopup(pendingDeathPopup)
            pendingDeathPopup = nil
        end
        if pendingRefresh then
            pendingRefresh = false
            Refresh()
        end
    end
end

EventUtil.ContinueOnAddOnLoaded(ADDON_NAME, function()
    EnsureDB()
    playerGUID = UnitGUID("player")
    Message("Loaded. Type /mj to open.")
end)

EventRegistry:RegisterCallback("PLAYER_ENTERING_WORLD", function()
    if not db then EnsureDB() end
end, addon)

local combatEvents = {
    "COMBAT_LOG_EVENT_UNFILTERED",
    "ENCOUNTER_START",
    "ENCOUNTER_END",
    "PLAYER_REGEN_DISABLED",
    "PLAYER_REGEN_ENABLED",
}
for _, event in ipairs(combatEvents) do
    EventRegistry:RegisterCallback(event, function(_, event2, ...) OnEvent(event2 or event, ...) end, addon)
end

-- Armada Addons hub registration
C_Timer.After(0, function()
    if ArmadaAddons and ArmadaAddons.Register then
        ArmadaAddons.Register({
            name = "Mistake Journal",
            version = "1.0.0",
            desc = "Review deaths, damage spikes, and interrupt attempts.",
            color = { 1, 0.45, 0.45 },
            open = function()
                ToggleUI()
            end,
        })
    end
end)

local ADDON_NAME = "ArmadaSuite"

local db
local ui = {}
local ROW_HEIGHT = 56
local ROW_GAP = 6

local SLOTS = {
    { id = 1,  name = "Head" },
    { id = 2,  name = "Neck" },
    { id = 3,  name = "Shoulder" },
    { id = 5,  name = "Chest" },
    { id = 6,  name = "Waist" },
    { id = 7,  name = "Legs" },
    { id = 8,  name = "Feet" },
    { id = 9,  name = "Wrist" },
    { id = 10, name = "Hands" },
    { id = 11, name = "Ring 1" },
    { id = 12, name = "Ring 2" },
    { id = 13, name = "Trinket 1" },
    { id = 14, name = "Trinket 2" },
    { id = 15, name = "Back" },
    { id = 16, name = "Main Hand" },
    { id = 17, name = "Off Hand" },
}

local STATS = {
    { id = 7,  name = "Stamina", unitStat = 3 },
    { id = 36, name = "Haste", rating = "CR_HASTE_MELEE", ratingIndex = 18 },
    { id = 32, name = "Crit", rating = "CR_CRIT_MELEE", ratingIndex = 9 },
    { id = 49, name = "Mastery", rating = "CR_MASTERY", ratingIndex = 26 },
    { id = 40, name = "Versatility", rating = "CR_VERSATILITY_DAMAGE_DONE", ratingIndex = 29 },
}

local Refresh
local CreateUI
local SetRowAccent

local function Now()
    return GetServerTime()
end

local function Message(text)
    print("|cff88ccffGearSnapshot:|r " .. text)
end

local function Trim(text)
    return strtrim(text or "")
end

local function CharacterKey()
    return (UnitName("player") or "Unknown") .. "-" .. (GetRealmName() or "Unknown")
end

local function FormatDate(timestamp)
    return date("%m/%d/%y %H:%M", timestamp or Now())
end

local function FormatDay(timestamp)
    return date("%Y-%m-%d", timestamp or Now())
end

local function DiffText(value)
    if value > 0 then return "+" .. value end
    return tostring(value)
end

local function RowStep()
    return ROW_HEIGHT + ROW_GAP
end

local function SafeNumber(value)
    local ok, number = pcall(function()
        return (value or 0) + 0
    end)
    return ok and number or 0
end

local function GetAverageIlvl()
    local total, count = 0, 0
    for _, slot in ipairs(SLOTS) do
        local link = GetInventoryItemLink("player", slot.id)
        if link then
            local _, _, _, ilvl = GetItemInfo(link)
            if ilvl and ilvl > 0 then
                total = total + ilvl
                count = count + 1
            end
        end
    end
    if count == 0 then return 0 end
    return math.floor((total / count) + 0.5)
end

local function CaptureGear()
    local gear = {}
    for _, slot in ipairs(SLOTS) do
        local link = GetInventoryItemLink("player", slot.id)
        if link then
            local _, _, _, ilvl, _, _, _, _, _, _, _, _, _, _, _, _, _ = GetItemInfo(link)
            gear[slot.id] = {
                name = slot.name,
                link = link,
                ilvl = ilvl or 0,
            }
        end
    end
    return gear
end

local function CaptureStats()
    local stats = {}
    for _, stat in ipairs(STATS) do
        if stat.unitStat then
            local base, posBuff, negBuff = UnitStat("player", stat.unitStat)
            local ok, value = pcall(function()
                return (base or 0) + (posBuff or 0) + (negBuff or 0)
            end)
            stats[stat.id] = {
                name = stat.name,
                value = SafeNumber(ok and value or 0),
            }
        else
            local ratingIndex = (stat.rating and _G[stat.rating]) or stat.ratingIndex
            local rating = 0
            if GetCombatRating and ratingIndex and ratingIndex >= 1 and ratingIndex <= 32 then
                rating = GetCombatRating(ratingIndex) or 0
            end
            stats[stat.id] = {
                name = stat.name,
                value = SafeNumber(rating),
            }
        end
    end
    return stats
end

local function TakeSnapshot(label, kind, silent)
    local key = CharacterKey()
    db.characters[key] = db.characters[key] or { snapshots = {} }

    local _, classFile = UnitClass("player")
    local specIndex = GetSpecialization and GetSpecialization()
    local specName = "Unknown"
    if specIndex and GetSpecializationInfo then
        local _
        _, specName = GetSpecializationInfo(specIndex)
    end

    local timestamp = Now()
    local cleanLabel = Trim(label)
    if cleanLabel == "" and kind == "login" then
        cleanLabel = "Login " .. FormatDate(timestamp)
    elseif cleanLabel == "" and kind == "logout" then
        cleanLabel = "Logout " .. FormatDate(timestamp)
    end

    local snapshot = {
        timestamp = timestamp,
        label = cleanLabel ~= "" and cleanLabel or FormatDate(timestamp),
        kind = kind or "manual",
        ilvl = GetAverageIlvl(),
        gear = CaptureGear(),
        stats = CaptureStats(),
        level = UnitLevel("player") or 0,
        class = classFile,
        spec = specName or "Unknown",
        zone = GetZoneText() or "Unknown",
    }

    table.insert(db.characters[key].snapshots, 1, snapshot)

    -- Auto login/logout tracking creates more history than manual snapshots.
    while #db.characters[key].snapshots > 60 do
        table.remove(db.characters[key].snapshots)
    end

    db.characters[key].name = UnitName("player") or "Unknown"
    db.characters[key].realm = GetRealmName() or "Unknown"
    db.characters[key].class = classFile

    if not silent then
        Message("Snapshot saved - " .. snapshot.ilvl .. " ilvl")
    end
    Refresh()
    return snapshot
end

local function FindTodayFirstLoginSnapshot(char)
    if not char or not char.snapshots then return nil end
    local today = FormatDay()
    for index = #char.snapshots, 1, -1 do
        local snap = char.snapshots[index]
        if snap and snap.kind == "login" and FormatDay(snap.timestamp) == today then
            return snap
        end
    end
    return nil
end

local function BuildStatGainSummary(firstSnap, latestSnap)
    local gains = {}
    for _, stat in ipairs(STATS) do
        local oldValue = SafeNumber(firstSnap.stats and firstSnap.stats[stat.id] and firstSnap.stats[stat.id].value or 0)
        local newValue = SafeNumber(latestSnap.stats and latestSnap.stats[stat.id] and latestSnap.stats[stat.id].value or 0)
        local diff = newValue - oldValue
        if diff > 0 then
            gains[#gains + 1] = "+" .. diff .. " " .. string.lower(stat.name)
        end
        if #gains == 2 then break end
    end
    if #gains == 0 then return "" end
    return " and " .. table.concat(gains, ", ")
end

local function PrintDailyProgress()
    local key = CharacterKey()
    local char = db.characters[key]
    local latest = char and char.snapshots and char.snapshots[1]
    local firstLogin = FindTodayFirstLoginSnapshot(char)
    if not latest or not firstLogin then return end

    local ilvlDiff = latest.ilvl - firstLogin.ilvl
    Message("Today you gained " .. DiffText(ilvlDiff) .. " ilvl" .. BuildStatGainSummary(firstLogin, latest) .. ".")
end

local function EnsureDB()
    GearSnapshotDB = GearSnapshotDB or {}
    db = GearSnapshotDB
    db.characters = db.characters or {}
    db.position = db.position or { point = "CENTER", x = 0, y = 0 }
    db.activeTab = db.activeTab or "snapshots"
    db.selectedChar = db.selectedChar or nil
    db.compareA = db.compareA or nil
    db.compareB = db.compareB or nil
end

-- UI helpers
local function ClearRows()
    ui.rows = ui.rows or {}
    for _, row in ipairs(ui.rows) do row:Hide() end
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
        row.accent:SetColorTexture(0.53, 0.8, 1, 0.95)
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
    if row.bar then row.bar:Hide() end
    if row.barBg then row.barBg:Hide() end
    row.right:SetTextColor(1, 1, 1)
    row.left:SetTextColor(1, 0.82, 0.1)
    row.sub:SetTextColor(0.62, 0.68, 0.74)
    SetRowAccent(row, 0.53, 0.8, 1)
    row:EnableMouse(true)
    row:SetScript("OnEnter", function(self)
        self:SetBackdropColor(0.07, 0.09, 0.11, 0.92)
        self:SetBackdropBorderColor(0.53, 0.8, 1, 0.8)
    end)
    row:SetScript("OnLeave", function(self)
        self:SetBackdropColor(0.03, 0.04, 0.05, 0.86)
        self:SetBackdropBorderColor(0.18, 0.23, 0.28, 0.95)
    end)
    row:Show()
    return row
end

local function IlvlColor(ilvl)
    if ilvl >= 600 then return 1, 0.5, 0 end
    if ilvl >= 550 then return 0.6, 0.4, 1 end
    if ilvl >= 500 then return 0.1, 0.4, 0.9 end
    if ilvl >= 450 then return 0.1, 0.8, 0.1 end
    return 1, 1, 1
end

local function SnapshotKindLabel(kind)
    if kind == "login" then return "Login" end
    if kind == "logout" then return "Logout" end
    return "Snapshot"
end

SetRowAccent = function(row, r, g, b)
    if row.accent then
        row.accent:SetColorTexture(r, g, b, 0.95)
    end
end

local function SortedCharKeys()
    local currentKey = CharacterKey()
    local keys = {}
    for key in pairs(db.characters) do
        keys[#keys + 1] = key
    end
    table.sort(keys, function(a, b)
        if a == currentKey then return true end
        if b == currentKey then return false end
        return a < b
    end)
    return keys
end

local function RenderSnapshots()
    local key = db.selectedChar or CharacterKey()
    local char = db.characters[key]

    if not char or not char.snapshots or #char.snapshots == 0 then
        local row = EnsureRow(1)
        row.left:SetText("No snapshots yet.")
        row.right:SetText("")
        row.sub:SetText("Use /gs snap or click Take Snapshot.")
        return 2
    end

    for index, snap in ipairs(char.snapshots) do
        local row = EnsureRow(index)
        local r, g, b = IlvlColor(snap.ilvl)
        SetRowAccent(row, r, g, b)
        row.left:SetText(snap.label or FormatDate(snap.timestamp))
        row.right:SetText((snap.ilvl or 0) .. " ilvl")
        row.right:SetTextColor(r, g, b)
        row.sub:SetText(SnapshotKindLabel(snap.kind) .. "  |  " .. FormatDate(snap.timestamp) .. "  |  " .. (snap.spec or "Unknown") .. "  |  " .. (snap.zone or "Unknown"))
        row:SetScript("OnClick", function()
            db.compareA = { key = key, index = index }
            Message("Snapshot A set to: " .. snap.label .. " — click another to compare.")
            if db.compareA and db.compareB and db.compareA.key == db.compareB.key and db.compareA.index ~= db.compareB.index then
                db.activeTab = "compare"
            end
            Refresh()
        end)
    end

    return #char.snapshots + 1
end

local function RenderCharacters()
    local keys = SortedCharKeys()
    if #keys == 0 then
        local row = EnsureRow(1)
        row.left:SetText("No characters recorded yet.")
        row.right:SetText("")
        row.sub:SetText("Take a snapshot to get started.")
        return 2
    end

    for index, key in ipairs(keys) do
        local char = db.characters[key]
        local snapCount = char.snapshots and #char.snapshots or 0
        local latest = char.snapshots and char.snapshots[1]
        local row = EnsureRow(index)
        local r, g, b = 1, 1, 1
        if latest then
            r, g, b = IlvlColor(latest.ilvl)
        end

        row.left:SetText((char.name or key) .. " — " .. (char.realm or ""))
        SetRowAccent(row, r, g, b)
        row.left:SetText((char.name or key) .. " - " .. (char.realm or ""))
        row.right:SetText(latest and (latest.ilvl .. " ilvl") or "No data")
        row.right:SetTextColor(r, g, b)
        row.sub:SetText(snapCount .. " snapshot" .. (snapCount == 1 and "" or "s") .. (latest and ("  |  Last: " .. FormatDate(latest.timestamp)) or ""))
        row:SetScript("OnClick", function()
            db.selectedChar = key
            db.activeTab = "snapshots"
            Refresh()
        end)
    end

    return #keys + 1
end

local function RenderCompare()
    if not db.compareA or not db.compareB then
        local row = EnsureRow(1)
        row.left:SetText("Select two snapshots to compare.")
        row.right:SetText("")
        row.sub:SetText("Click a snapshot to set A, then click another to set B.")
        return 2
    end

    local charA = db.characters[db.compareA.key]
    local charB = db.characters[db.compareB.key]
    if not charA or not charB then return 2 end

    local snapA = charA.snapshots[db.compareA.index]
    local snapB = charB.snapshots[db.compareB.index]
    if not snapA or not snapB then return 2 end

    local rowIndex = 1

    -- Header
    local header = EnsureRow(rowIndex)
    header.left:SetText("Stat")
    header.right:SetText(snapA.label .. "  →  " .. snapB.label)
    header.right:SetTextColor(1, 0.82, 0.1)
    header.sub:SetText(FormatDate(snapA.timestamp) .. "  →  " .. FormatDate(snapB.timestamp))
    rowIndex = rowIndex + 1

    -- ilvl diff
    local ilvlRow = EnsureRow(rowIndex)
    local diff = snapB.ilvl - snapA.ilvl
    local diffText = diff > 0 and ("|cff44ff44+" .. diff .. "|r") or diff < 0 and ("|cffff4444" .. diff .. "|r") or "|cffaaaaaa0|r"
    ilvlRow.left:SetText("Item Level")
    ilvlRow.right:SetText(snapA.ilvl .. "  →  " .. snapB.ilvl .. "  (" .. diffText .. ")")
    ilvlRow.right:SetTextColor(1, 1, 1)
    ilvlRow.sub:SetText("Average equipped ilvl")
    rowIndex = rowIndex + 1

    -- Stat diffs
    for _, stat in ipairs(STATS) do
        local valA = SafeNumber(snapA.stats and snapA.stats[stat.id] and snapA.stats[stat.id].value or 0)
        local valB = SafeNumber(snapB.stats and snapB.stats[stat.id] and snapB.stats[stat.id].value or 0)
        local statDiff = valB - valA
        local statDiffText = statDiff > 0 and ("|cff44ff44+" .. statDiff .. "|r") or statDiff < 0 and ("|cffff4444" .. statDiff .. "|r") or "|cffaaaaaa0|r"
        local row = EnsureRow(rowIndex)
        row.left:SetText(stat.name)
        row.right:SetText(valA .. "  →  " .. valB .. "  (" .. statDiffText .. ")")
        row.right:SetTextColor(1, 1, 1)
        row.sub:SetText("")
        rowIndex = rowIndex + 1
    end

    return rowIndex
end

local function RenderProgress()
    local key = db.selectedChar or CharacterKey()
    local char = db.characters[key]

    if not char or not char.snapshots or #char.snapshots == 0 then
        local row = EnsureRow(1)
        row.left:SetText("No progression yet.")
        row.right:SetText("")
        row.sub:SetText("Login, logout, or take a snapshot to start the timeline.")
        return 2
    end

    local newestIndex = 1
    local oldestIndex = math.min(#char.snapshots, 16)
    local minIlvl, maxIlvl
    for index = newestIndex, oldestIndex do
        local ilvl = char.snapshots[index].ilvl or 0
        minIlvl = minIlvl and math.min(minIlvl, ilvl) or ilvl
        maxIlvl = maxIlvl and math.max(maxIlvl, ilvl) or ilvl
    end

    local rowIndex = 1
    local firstLogin = FindTodayFirstLoginSnapshot(char)
    local latest = char.snapshots[1]
    if firstLogin and latest then
        local dailyRow = EnsureRow(rowIndex)
        local ilvlDiff = latest.ilvl - firstLogin.ilvl
        SetRowAccent(dailyRow, 0.2, 0.9, 0.45)
        dailyRow.left:SetText("Today")
        dailyRow.right:SetText(DiffText(ilvlDiff) .. " ilvl")
        dailyRow.sub:SetText("Since first login: " .. firstLogin.label .. BuildStatGainSummary(firstLogin, latest))
        rowIndex = rowIndex + 1
    end

    local range = math.max((maxIlvl or 0) - (minIlvl or 0), 1)
    local graphWidth = math.max((ui.content:GetWidth() or 560) - 210, 220)

    for index = oldestIndex, newestIndex, -1 do
        local snap = char.snapshots[index]
        local row = EnsureRow(rowIndex)
        local r, g, b = IlvlColor(snap.ilvl or 0)
        SetRowAccent(row, r, g, b)
        local percent = ((snap.ilvl or 0) - (minIlvl or 0)) / range
        local width = math.max(18, math.floor(graphWidth * percent))
        if maxIlvl == minIlvl then
            width = math.floor(graphWidth * 0.75)
        end

        if not row.barBg then
            row.barBg = row:CreateTexture(nil, "ARTWORK")
            row.barBg:SetHeight(12)
            row.bar = row:CreateTexture(nil, "OVERLAY")
            row.bar:SetHeight(12)
        end

        row.left:SetText((snap.ilvl or 0) .. " ilvl")
        row.right:SetText(SnapshotKindLabel(snap.kind))
        row.right:SetTextColor(r, g, b)
        row.sub:SetText(FormatDate(snap.timestamp) .. "  |  " .. (snap.label or ""))

        row.barBg:ClearAllPoints()
        row.barBg:SetPoint("LEFT", 96, -2)
        row.barBg:SetWidth(graphWidth)
        row.barBg:SetColorTexture(1, 1, 1, 0.08)
        row.barBg:Show()

        row.bar:ClearAllPoints()
        row.bar:SetPoint("LEFT", row.barBg, "LEFT", 0, 0)
        row.bar:SetWidth(width)
        row.bar:SetColorTexture(r, g, b, 0.9)
        row.bar:Show()

        rowIndex = rowIndex + 1
    end

    return rowIndex
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
                button:GetFontString():SetTextColor(0.53, 0.8, 1)
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
    if db.activeTab == "characters" then
        rowIndex = RenderCharacters()
    elseif db.activeTab == "compare" then
        rowIndex = RenderCompare()
    elseif db.activeTab == "progress" then
        rowIndex = RenderProgress()
    else
        rowIndex = RenderSnapshots()
    end

    ui.content:SetHeight(math.max((rowIndex - 1) * RowStep(), ui.frame.scroll:GetHeight()))

    -- Update summary
    local key = db.selectedChar or CharacterKey()
    local char = db.characters[key]
    local latest = char and char.snapshots and char.snapshots[1]
    if latest then
        ui.frame.summary:SetText((char.name or key) .. "  —  " .. latest.ilvl .. " ilvl  —  " .. latest.spec)
    else
        ui.frame.summary:SetText("No snapshot taken yet.")
    end
    if latest then
        ui.frame.summary:SetText((char.name or key) .. "  |  " .. latest.ilvl .. " ilvl  |  " .. (latest.spec or "Unknown") .. "  |  " .. SnapshotKindLabel(latest.kind) .. " " .. FormatDate(latest.timestamp))
    end
end

CreateUI = function()
    local frame = CreateFrame("Frame", "GearSnapshotFrame", UIParent, "BackdropTemplate")
    frame:SetSize(660, 560)
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
    frame:SetBackdropBorderColor(0.2, 0.35, 0.45, 1)
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
    frame.header:SetColorTexture(0.02, 0.08, 0.11, 0.82)

    frame.headerLine = frame:CreateTexture(nil, "ARTWORK")
    frame.headerLine:SetPoint("TOPLEFT", 16, -76)
    frame.headerLine:SetPoint("TOPRIGHT", -16, -76)
    frame.headerLine:SetHeight(1)
    frame.headerLine:SetColorTexture(0.53, 0.8, 1, 0.55)

    frame.title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    frame.title:SetPoint("TOPLEFT", 18, -16)
    frame.title:SetText("|cff88ccffGear|rSnapshot")

    frame.subtitle = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    frame.subtitle:SetPoint("TOPLEFT", 18, -38)
    frame.subtitle:SetText("Automatic login/logout progression tracker")

    frame.close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    frame.close:SetPoint("TOPRIGHT", -8, -8)
    frame.close:SetScript("OnClick", function()
        frame:Hide()
    end)

    -- Tabs
    ui.tabs = {}
    local tabDefs = {
        { "snapshots",   "Snapshots" },
        { "progress",    "Progress" },
        { "characters",  "Characters" },
        { "compare",     "Compare" },
    }
    local prev
    for _, tab in ipairs(tabDefs) do
        local btn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
        btn:SetSize(110, 22)
        if prev then
            btn:SetPoint("LEFT", prev, "RIGHT", 5, 0)
        else
            btn:SetPoint("TOPLEFT", 18, -58)
        end
        btn:SetText(tab[2])
        btn:SetScript("OnClick", function() SetTab(tab[1]) end)
        ui.tabs[tab[1]] = btn
        prev = btn
    end

    frame.summary = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    frame.summary:SetPoint("TOPLEFT", 18, -94)
    frame.summary:SetPoint("RIGHT", -18, -94)
    frame.summary:SetJustifyH("LEFT")

    frame.scroll = CreateFrame("ScrollFrame", "GearSnapshotScrollFrame", frame, "UIPanelScrollFrameTemplate")
    frame.scroll:SetPoint("TOPLEFT", 14, -120)
    frame.scroll:SetPoint("BOTTOMRIGHT", -32, 56)

    ui.content = CreateFrame("Frame", nil, frame.scroll)
    ui.content:SetSize(600, 360)
    frame.scroll:SetScrollChild(ui.content)
    frame.scroll:SetScript("OnSizeChanged", function(_, w, h)
        ui.content:SetWidth(w)
        ui.content:SetHeight(math.max(ui.content:GetHeight(), h))
    end)

    -- Snap button
    frame.snapBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    frame.snapBtn:SetSize(130, 26)
    frame.snapBtn:SetPoint("BOTTOMLEFT", 18, 17)
    frame.snapBtn:SetText("Take Snapshot")
    frame.snapBtn:SetScript("OnClick", function()
        TakeSnapshot("")
        db.activeTab = "snapshots"
        db.selectedChar = CharacterKey()
        Refresh()
    end)

    -- Compare B button
    frame.compareBBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    frame.compareBBtn:SetSize(130, 26)
    frame.compareBBtn:SetPoint("LEFT", frame.snapBtn, "RIGHT", 8, 0)
    frame.compareBBtn:SetText("Set Compare B")
    frame.compareBBtn:SetScript("OnClick", function()
        if db.compareA then
            -- Set B to the currently hovered/selected snapshot
            local key = db.selectedChar or CharacterKey()
            local char = db.characters[key]
            if char and char.snapshots and #char.snapshots > 1 then
                db.compareB = { key = key, index = 2 }
                db.activeTab = "compare"
                Refresh()
                Message("Compare B set. Switch to Compare tab.")
            else
                Message("Need at least 2 snapshots to compare.")
            end
        else
            Message("Click a snapshot first to set Compare A.")
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
        db.selectedChar = db.selectedChar or CharacterKey()
        Refresh()
        ui.frame:Show()
    end
end

local function PrintHelp()
    Message("/gs — Toggle the window.")
    Message("/gs snap — Take a snapshot of current gear.")
    Message("/gs snap My Label — Take a labeled snapshot.")
end

SLASH_GEARSNAPSHOT1 = "/gs"
SLASH_GEARSNAPSHOT2 = "/gearsnapshot"
SlashCmdList.GEARSNAPSHOT = function(message)
    message = Trim(message)
    local lower = string.lower(message)

    if lower == "help" then
        PrintHelp()
    elseif lower == "snap" or string.sub(lower, 1, 5) == "snap " then
        local label = string.sub(message, 6)
        TakeSnapshot(label)
        db.selectedChar = CharacterKey()
        db.activeTab = "snapshots"
    else
        ToggleUI()
    end
end

EventUtil.ContinueOnAddOnLoaded(ADDON_NAME, function()
    EnsureDB()
    C_Timer.After(2, function()
        TakeSnapshot("", "login", true)
        PrintDailyProgress()
    end)
end)

EventRegistry:RegisterCallback("PLAYER_ENTERING_WORLD", function()
    if not db then EnsureDB() end
end, {})

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("PLAYER_LOGOUT")
eventFrame:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_LOGOUT" then
        if not db then EnsureDB() end
        TakeSnapshot("", "logout", true)
    end
end)

-- Armada Addons hub registration
C_Timer.After(0, function()
    if ArmadaAddons and ArmadaAddons.Register then
        ArmadaAddons.Register({
            name    = "GearSnapshot",
            version = "1.0.0",
            desc    = "Track gear and ilvl progression over time across all alts.",
            color   = { 0.53, 0.8, 1 },
            open    = function()
                ToggleUI()
            end,
        })
    end
end)

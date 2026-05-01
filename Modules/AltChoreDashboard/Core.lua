local ADDON_NAME = "ArmadaSuite"

local DEFAULT_TASKS = {
    { id = "vault", label = "Great Vault", reset = "weekly", scope = "character", priority = true, max = 1, note = "" },
    { id = "raid", label = "Raid Lockout", reset = "weekly", scope = "character", priority = false, max = 1, note = "" },
    { id = "mythic", label = "Mythic+ Key", reset = "weekly", scope = "character", priority = true, max = 1, note = "" },
    { id = "professions", label = "Profession Weeklies", reset = "weekly", scope = "character", priority = false, max = 1, note = "" },
    { id = "delves", label = "Delves / Outdoor", reset = "weekly", scope = "character", priority = false, max = 8, note = "" },
    { id = "currency", label = "Currency Cap", reset = "weekly", scope = "character", priority = false, max = 1, note = "" },
}

local DAILY_DEFAULT_TASKS = {
    { id = "daily_profession", label = "Profession Cooldown", reset = "daily", scope = "character", priority = false, max = 1, note = "" },
    { id = "daily_world", label = "Daily Outdoor Chore", reset = "daily", scope = "character", priority = false, max = 1, note = "" },
    { id = "daily_account", label = "Account Daily Check", reset = "daily", scope = "account", priority = false, max = 1, note = "" },
}

local TABS = {
    { id = "overview", label = "Overview" },
    { id = "today", label = "Today" },
    { id = "weekly", label = "Weekly" },
    { id = "tasks", label = "Tasks" },
    { id = "planner", label = "Planner" },
    { id = "settings", label = "Settings" },
}

local FILTERS = {
    { id = "all", label = "All" },
    { id = "daily", label = "Daily" },
    { id = "weekly", label = "Weekly" },
    { id = "incomplete", label = "Open" },
    { id = "current", label = "Current" },
}

local CLASS_COLORS = CUSTOM_CLASS_COLORS or RAID_CLASS_COLORS or {}
local addon = {}
local db
local ui = {}
local pendingDelete = {}

local Refresh
local RefreshTracker
local CreateUI
local CreateTracker

local function Now()
    return GetServerTime()
end

local function Message(text)
    print("|cff7cc5ffAlt Chore Dashboard:|r " .. text)
end

local function Trim(text)
    return strtrim(text or "")
end

local function Clamp(value, minValue, maxValue)
    value = tonumber(value) or minValue
    if value < minValue then
        return minValue
    elseif value > maxValue then
        return maxValue
    end
    return math.floor(value)
end


local function CopyTask(task)
    return {
        id = task.id,
        label = task.label,
        reset = task.reset,
        scope = task.scope,
        priority = task.priority,
        max = task.max,
        note = task.note,
    }
end

local function CopyDefaults()
    local tasks = {}
    for index, task in ipairs(DEFAULT_TASKS) do
        tasks[index] = CopyTask(task)
    end
    for _, task in ipairs(DAILY_DEFAULT_TASKS) do
        tasks[#tasks + 1] = CopyTask(task)
    end
    return tasks
end

local function FindTask(taskId)
    for index, task in ipairs(db.tasks) do
        if task.id == taskId then
            return task, index
        end
    end
end

local function IsDefaultTask(taskId)
    for _, task in ipairs(DEFAULT_TASKS) do
        if task.id == taskId then
            return true
        end
    end
    for _, task in ipairs(DAILY_DEFAULT_TASKS) do
        if task.id == taskId then
            return true
        end
    end
    return false
end

local function GetCharacterKey()
    local name = UnitName("player") or "Unknown"
    local realm = GetRealmName() or "Unknown"
    return name .. "-" .. realm
end

local function GetCharacterDisplayName(key)
    local character = db.characters[key]
    if character and character.name and character.realm then
        return character.name .. " - " .. character.realm
    end
    return key
end

local function GetShortCharacterName(key)
    local character = db.characters[key]
    return character and character.name or key
end

local function GetDailyResetKey()
    local serverTime = Now()

    if C_DateAndTime and C_DateAndTime.GetSecondsUntilDailyReset then
        local secondsUntilReset = C_DateAndTime.GetSecondsUntilDailyReset()
        if type(secondsUntilReset) == "number" and secondsUntilReset > 0 then
            local previousReset = serverTime - (24 * 60 * 60 - secondsUntilReset)
            return date("!%Y-%m-%d", previousReset)
        end
    end

    return date("!%Y-%m-%d", serverTime)
end

local function GetWeeklyResetKey()
    local serverTime = Now()

    if C_DateAndTime and C_DateAndTime.GetSecondsUntilWeeklyReset then
        local secondsUntilReset = C_DateAndTime.GetSecondsUntilWeeklyReset()
        if type(secondsUntilReset) == "number" and secondsUntilReset > 0 then
            local previousReset = serverTime - (7 * 24 * 60 * 60 - secondsUntilReset)
            return date("!%Y-%m-%d", previousReset)
        end
    end

    return date("!%Y-W%W", serverTime)
end

local function EnsureTaskShape(task)
    if task.weekly ~= nil and task.reset == nil then
        task.reset = task.weekly and "weekly" or "daily"
        task.weekly = nil
    end
    if task.reset ~= "daily" and task.reset ~= "weekly" then
        task.reset = "weekly"
    end
    if task.scope ~= "account" then
        task.scope = "character"
    end
    task.priority = task.priority == true
    task.max = Clamp(task.max or 1, 1, 999)
    task.note = task.note or ""
end

local function EnsureTaskIds()
    db.nextTaskId = db.nextTaskId or 1

    for _, task in ipairs(db.tasks) do
        EnsureTaskShape(task)
        if not task.id then
            task.id = "custom" .. db.nextTaskId
            db.nextTaskId = db.nextTaskId + 1
        end
    end
end

local function EnsureDB()
    AltChoreDashboardDB = AltChoreDashboardDB or {}
    db = AltChoreDashboardDB
    db.characters = db.characters or {}
    db.accountTasks = db.accountTasks or {}
    db.tasks = db.tasks or CopyDefaults()
    db.position = db.position or { point = "CENTER", x = 0, y = 0 }
    db.trackerPosition = db.trackerPosition or { point = "CENTER", x = 360, y = 0 }
    db.collapsed = db.collapsed or {}
    db.dailyResetKey = db.dailyResetKey or GetDailyResetKey()
    db.weeklyResetKey = db.weeklyResetKey or GetWeeklyResetKey()
    db.minimap = db.minimap or { angle = 225, hide = false }
    db.activeTab = db.activeTab or "overview"
    db.filter = db.filter or "all"
    db.trackerShown = db.trackerShown ~= false
    db.showLoginSummary = db.showLoginSummary ~= false
    EnsureTaskIds()
end

local function EnsureCharacter()
    local key = GetCharacterKey()
    local _, classFile = UnitClass("player")

    db.characters[key] = db.characters[key] or { tasks = {} }
    db.characters[key].name = UnitName("player") or "Unknown"
    db.characters[key].realm = GetRealmName() or "Unknown"
    db.characters[key].class = classFile
    db.characters[key].level = UnitLevel("player") or 0
    db.characters[key].lastSeen = Now()
    db.characters[key].tasks = db.characters[key].tasks or {}

    return key
end

local function GetStateTable(characterKey, task)
    local bucket
    if task.scope == "account" then
        bucket = db.accountTasks
    else
        local character = db.characters[characterKey]
        if not character then
            return { progress = 0, done = false }
        end
        character.tasks = character.tasks or {}
        bucket = character.tasks
    end

    local state = bucket[task.id]
    if type(state) == "table" then
        state.progress = Clamp(state.progress or (state.done and task.max or 0), 0, task.max)
        state.done = state.progress >= task.max or state.done == true
        if state.done and state.progress < task.max then
            state.progress = task.max
        end
        bucket[task.id] = state
        return state
    end

    state = {
        progress = state == true and task.max or 0,
        done = state == true,
    }
    bucket[task.id] = state
    return state
end

local function IsTaskDone(characterKey, task)
    local state = GetStateTable(characterKey, task)
    return state.done == true or state.progress >= task.max
end

local function SetTaskProgress(characterKey, task, progress)
    local state = GetStateTable(characterKey, task)
    state.progress = Clamp(progress, 0, task.max)
    state.done = state.progress >= task.max
end

local function SetTaskDone(characterKey, task, done)
    local state = GetStateTable(characterKey, task)
    state.done = done == true
    state.progress = state.done and task.max or 0
end

local function ResetTasks(resetType)
    for _, task in ipairs(db.tasks) do
        if task.reset == resetType then
            if task.scope == "account" then
                db.accountTasks[task.id] = { progress = 0, done = false }
            else
                for _, character in pairs(db.characters) do
                    character.tasks = character.tasks or {}
                    character.tasks[task.id] = { progress = 0, done = false }
                end
            end
        end
    end
end

local function ResetTasksIfNeeded()
    local dailyKey = GetDailyResetKey()
    if db.dailyResetKey ~= dailyKey then
        ResetTasks("daily")
        db.dailyResetKey = dailyKey
    end

    local weeklyKey = GetWeeklyResetKey()
    if db.weeklyResetKey ~= weeklyKey then
        ResetTasks("weekly")
        db.weeklyResetKey = weeklyKey
    end
end

local function CountDone(characterKey, resetType)
    local done = 0
    local total = 0

    for _, task in ipairs(db.tasks) do
        if not task.hidden and (not resetType or task.reset == resetType) then
            total = total + 1
            if IsTaskDone(characterKey, task) then
                done = done + 1
            end
        end
    end

    return done, total
end

local function GetOpenTaskCount(characterKey, resetType)
    local done, total = CountDone(characterKey, resetType)
    return total - done, total
end

local function SortCharacterKeys()
    local currentKey = GetCharacterKey()
    local keys = {}

    for key in pairs(db.characters) do
        keys[#keys + 1] = key
    end

    table.sort(keys, function(left, right)
        if left == currentKey then
            return true
        elseif right == currentKey then
            return false
        end

        local leftCharacter = db.characters[left]
        local rightCharacter = db.characters[right]
        local leftName = leftCharacter and leftCharacter.name or left
        local rightName = rightCharacter and rightCharacter.name or right
        return leftName < rightName
    end)

    return keys
end

local function ClassColorText(text, classFile)
    local color = classFile and CLASS_COLORS[classFile]
    if not color then
        return text
    end

    return string.format(
        "|cff%02x%02x%02x%s|r",
        math.floor(color.r * 255 + 0.5),
        math.floor(color.g * 255 + 0.5),
        math.floor(color.b * 255 + 0.5),
        text
    )
end

local function ProgressColor(done, total)
    if total == 0 then
        return 0.72, 0.72, 0.72
    elseif done == total then
        return 0.25, 1.0, 0.35
    elseif done == 0 then
        return 1.0, 0.35, 0.25
    end

    return 1.0, 0.82, 0.25
end

local function ResetLabel(resetType)
    return resetType == "daily" and "Daily" or "Weekly"
end

local function ScopeLabel(scope)
    return scope == "account" and "Account" or "Character"
end

local function TaskProgressText(characterKey, task)
    local state = GetStateTable(characterKey, task)
    if task.max > 1 then
        return state.progress .. " / " .. task.max
    end
    return IsTaskDone(characterKey, task) and "Done" or "Open"
end

local function AddTask(label, resetType, scope, priority, maxValue, note)
    label = Trim(label)
    if label == "" then
        Message("Type a task name first.")
        return
    end

    db.nextTaskId = (db.nextTaskId or 1) + 1
    db.tasks[#db.tasks + 1] = {
        id = "custom" .. db.nextTaskId,
        label = label,
        reset = resetType == "daily" and "daily" or "weekly",
        scope = scope == "account" and "account" or "character",
        priority = priority == true,
        max = Clamp(maxValue or 1, 1, 999),
        note = Trim(note),
    }

    Refresh()
    RefreshTracker()
    Message("Added " .. label .. ".")
end

local function RestoreDefaultTasks()
    local existing = {}
    local restored = 0

    for _, task in ipairs(db.tasks) do
        if task.id then
            existing[task.id] = task
        end
    end

    for _, defaultTask in ipairs(DEFAULT_TASKS) do
        local task = existing[defaultTask.id]
        if task then
            task.hidden = nil
            EnsureTaskShape(task)
        else
            db.tasks[#db.tasks + 1] = CopyTask(defaultTask)
            restored = restored + 1
        end
    end

    EnsureTaskIds()
    Refresh()
    RefreshTracker()

    if restored == 0 then
        Message("Default weekly tasks are visible again.")
    else
        Message("Restored " .. restored .. " default weekly tasks.")
    end
end

local function RestoreDailyDefaultTasks()
    local existing = {}
    local restored = 0

    for _, task in ipairs(db.tasks) do
        if task.id then
            existing[task.id] = task
        end
    end

    for _, defaultTask in ipairs(DAILY_DEFAULT_TASKS) do
        local task = existing[defaultTask.id]
        if task then
            task.hidden = nil
            EnsureTaskShape(task)
        else
            db.tasks[#db.tasks + 1] = CopyTask(defaultTask)
            restored = restored + 1
        end
    end

    EnsureTaskIds()
    Refresh()
    RefreshTracker()

    if restored == 0 then
        Message("Default daily tasks are visible again.")
    else
        Message("Restored " .. restored .. " default daily tasks.")
    end
end

local function RemoveTask(taskId)
    local removedLabel
    local removedTask
    local removedStates
    local removedAccountState

    for index, task in ipairs(db.tasks) do
        if task.id == taskId then
            if IsDefaultTask(taskId) then
                task.hidden = true
                removedLabel = task.label
                break
            end

            removedLabel = task.label
            removedTask = CopyTask(task)
            removedStates = {}
            for characterKey, character in pairs(db.characters) do
                if character.tasks and character.tasks[taskId] then
                    removedStates[characterKey] = character.tasks[taskId]
                end
            end
            removedAccountState = db.accountTasks[taskId]
            table.remove(db.tasks, index)
            break
        end
    end

    if not removedLabel then
        return
    end

    if not IsDefaultTask(taskId) then
        db.accountTasks[taskId] = nil
        for _, character in pairs(db.characters) do
            if character.tasks then
                character.tasks[taskId] = nil
            end
        end
    end

    db.lastDeletedTask = {
        task = removedTask,
        states = removedStates,
        accountState = removedAccountState,
        hiddenDefaultId = IsDefaultTask(taskId) and taskId or nil,
    }

    Refresh()
    RefreshTracker()
    Message("Removed " .. removedLabel .. ". Use /acd undo to restore it.")
end

local function RequestRemoveTask(taskId)
    local task = FindTask(taskId)
    if not task then
        return
    end

    local now = Now()
    if pendingDelete[taskId] and now - pendingDelete[taskId] <= 8 then
        pendingDelete[taskId] = nil
        RemoveTask(taskId)
        return
    end

    pendingDelete[taskId] = now
    Message("Click delete again within 8 seconds to remove " .. task.label .. ".")
end

local function UndoLastDelete()
    local deleted = db.lastDeletedTask
    if not deleted then
        Message("Nothing to undo.")
        return
    end

    if deleted.hiddenDefaultId then
        local task = FindTask(deleted.hiddenDefaultId)
        if task then
            task.hidden = nil
        end
    elseif deleted.task then
        db.tasks[#db.tasks + 1] = deleted.task
        if deleted.accountState then
            db.accountTasks[deleted.task.id] = deleted.accountState
        end
        for characterKey, state in pairs(deleted.states or {}) do
            if db.characters[characterKey] then
                db.characters[characterKey].tasks = db.characters[characterKey].tasks or {}
                db.characters[characterKey].tasks[deleted.task.id] = state
            end
        end
    end

    db.lastDeletedTask = nil
    Refresh()
    RefreshTracker()
    Message("Restored the last deleted task.")
end

local function EscapeField(value)
    value = tostring(value or "")
    value = string.gsub(value, "\\", "\\\\")
    value = string.gsub(value, "|", "\\p")
    value = string.gsub(value, ";", "\\s")
    value = string.gsub(value, "\n", "\\n")
    return value
end

local function UnescapeField(value)
    value = tostring(value or "")
    value = string.gsub(value, "\\n", "\n")
    value = string.gsub(value, "\\s", ";")
    value = string.gsub(value, "\\p", "|")
    value = string.gsub(value, "\\\\", "\\")
    return value
end

local function Split(text, delimiter)
    local fields = {}
    local startIndex = 1
    local delimiterIndex = string.find(text, delimiter, startIndex, true)

    while delimiterIndex do
        fields[#fields + 1] = string.sub(text, startIndex, delimiterIndex - 1)
        startIndex = delimiterIndex + string.len(delimiter)
        delimiterIndex = string.find(text, delimiter, startIndex, true)
    end

    fields[#fields + 1] = string.sub(text, startIndex)
    return fields
end

local function ExportTasks()
    local parts = { "ACD1" }
    for _, task in ipairs(db.tasks) do
        if not task.hidden then
            parts[#parts + 1] = table.concat({
                EscapeField(task.id),
                EscapeField(task.label),
                EscapeField(task.reset),
                EscapeField(task.scope),
                task.priority and "1" or "0",
                tostring(task.max or 1),
                EscapeField(task.note),
            }, "|")
        end
    end

    local exportText = table.concat(parts, ";")
    db.lastExport = exportText
    Message("Task export string:")
    print(exportText)
end

local function ImportTasks(importText)
    importText = Trim(importText)
    if importText == "" then
        Message("Paste an export string after /acd import.")
        return
    end

    local sections = Split(importText, ";")

    if sections[1] ~= "ACD1" then
        Message("That import string is not recognized.")
        return
    end

    local imported = {}
    for index = 2, #sections do
        local fields = Split(sections[index], "|")
        if #fields >= 6 then
            imported[#imported + 1] = {
                id = UnescapeField(fields[1]),
                label = UnescapeField(fields[2]),
                reset = UnescapeField(fields[3]),
                scope = UnescapeField(fields[4]),
                priority = fields[5] == "1",
                max = Clamp(fields[6], 1, 999),
                note = UnescapeField(fields[7] or ""),
            }
        end
    end

    if #imported == 0 then
        Message("No tasks were found in that import string.")
        return
    end

    db.tasks = imported
    EnsureTaskIds()
    Refresh()
    RefreshTracker()
    Message("Imported " .. #imported .. " tasks.")
end

local function TaskMatchesFilter(characterKey, task)
    if task.hidden then
        return false
    end

    if db.activeTab == "today" and task.reset ~= "daily" then
        return false
    elseif db.activeTab == "weekly" and task.reset ~= "weekly" then
        return false
    end

    if db.filter == "daily" then
        return task.reset == "daily"
    elseif db.filter == "weekly" then
        return task.reset == "weekly"
    elseif db.filter == "incomplete" then
        return not IsTaskDone(characterKey, task)
    elseif db.filter == "current" then
        return characterKey == GetCharacterKey()
    end

    return true
end

local function ManualReset(resetType)
    ResetTasks(resetType)
    if resetType == "daily" then
        db.dailyResetKey = GetDailyResetKey()
    else
        db.weeklyResetKey = GetWeeklyResetKey()
    end

    Refresh()
    RefreshTracker()
    Message(ResetLabel(resetType) .. " tasks reset.")
end

local function GetPlannerItems(limit)
    local items = {}
    local currentKey = GetCharacterKey()

    for _, characterKey in ipairs(SortCharacterKeys()) do
        for _, task in ipairs(db.tasks) do
            if task.hidden then
                -- Hidden default tasks can be restored with /acd defaults.
            elseif task.scope == "account" and characterKey ~= currentKey then
                -- Account tasks share one state, so the planner only needs one copy.
            elseif not IsTaskDone(characterKey, task) then
                items[#items + 1] = {
                    characterKey = characterKey,
                    task = task,
                    score = (task.priority and 0 or 10) + (task.reset == "daily" and 0 or 2),
                }
            end
        end
    end

    table.sort(items, function(left, right)
        if left.score ~= right.score then
            return left.score < right.score
        end
        if left.characterKey ~= right.characterKey then
            return left.characterKey < right.characterKey
        end
        return left.task.label < right.task.label
    end)

    while limit and #items > limit do
        table.remove(items)
    end

    return items
end

local function ClearRows(pool)
    pool = pool or ui.rows
    if not pool then
        return
    end
    for _, row in ipairs(pool) do
        row:Hide()
    end
end

local function PrepareFrame(frame)
    frame:SetScript("OnClick", nil)
    frame:SetScript("OnEnter", nil)
    frame:SetScript("OnLeave", nil)
    frame:EnableMouse(false)
end

local function EnsureTextRow(parent, rowIndex)
    ui.rows = ui.rows or {}
    local row = ui.rows[rowIndex]
    if not row then
        row = CreateFrame("Button", nil, parent)
        row:SetHeight(28)
        row.bg = row:CreateTexture(nil, "BACKGROUND")
        row.bg:SetAllPoints()
        row.bg:SetColorTexture(1, 1, 1, 0)
        row.left = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        row.left:SetPoint("LEFT", 10, 0)
        row.left:SetJustifyH("LEFT")
        row.right = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.right:SetPoint("RIGHT", -10, 0)
        row.right:SetJustifyH("RIGHT")
        row.sub = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        row.sub:SetPoint("LEFT", 10, -9)
        row.sub:SetPoint("RIGHT", -10, -9)
        row.sub:SetJustifyH("LEFT")
        row.check = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
        row.check:SetSize(24, 24)
        row.check:SetPoint("LEFT", 4, 0)
        row.minus = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
        row.minus:SetSize(22, 20)
        row.minus:SetText("-")
        row.minus:SetPoint("RIGHT", -82, 0)
        row.plus = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
        row.plus:SetSize(22, 20)
        row.plus:SetText("+")
        row.plus:SetPoint("RIGHT", -56, 0)
        row.remove = CreateFrame("Button", nil, row, "UIPanelCloseButton")
        row.remove:SetSize(20, 20)
        row.remove:SetPoint("RIGHT", -4, 0)
        ui.rows[rowIndex] = row
    end

    row:SetParent(parent)
    row:ClearAllPoints()
    row:SetPoint("TOPLEFT", 0, -((rowIndex - 1) * 38))
    row:SetPoint("RIGHT", 0, 0)
    row:SetHeight(38)
    PrepareFrame(row)
    row.bg:SetColorTexture(0.03, 0.04, 0.05, rowIndex % 2 == 0 and 0.82 or 0.7)
    row.left:ClearAllPoints()
    row.left:SetPoint("LEFT", 10, 5)
    row.left:SetPoint("RIGHT", -88, 5)
    row.right:ClearAllPoints()
    row.right:SetPoint("RIGHT", -10, 5)
    row.right:SetWidth(80)
    row.right:SetJustifyH("RIGHT")
    row.right:Show()
    row.sub:Show()
    row.check:Hide()
    row.minus:Hide()
    row.plus:Hide()
    row.remove:Hide()
    row:Show()
    return row
end

local function CreateCharacterCard(parent, rowIndex, characterKey)
    local row = EnsureTextRow(parent, rowIndex)
    local character = db.characters[characterKey]
    local dailyDone, dailyTotal = CountDone(characterKey, "daily")
    local weeklyDone, weeklyTotal = CountDone(characterKey, "weekly")
    local allDone, allTotal = CountDone(characterKey)
    local r, g, b = ProgressColor(allDone, allTotal)

    row.left:SetText(ClassColorText(GetCharacterDisplayName(characterKey), character and character.class))
    row.right:SetText(allDone .. " / " .. allTotal)
    row.right:SetTextColor(r, g, b)
    row.sub:SetText("Daily " .. dailyDone .. "/" .. dailyTotal .. "   Weekly " .. weeklyDone .. "/" .. weeklyTotal .. "   Level " .. (character and character.level or "?"))
    row:EnableMouse(true)
    row:SetScript("OnClick", function()
        db.activeTab = "tasks"
        db.filter = characterKey == GetCharacterKey() and "current" or "all"
        Refresh()
    end)
end

local function CreateTaskRow(parent, rowIndex, characterKey, task, showCharacter)
    local row = EnsureTextRow(parent, rowIndex)
    local state = GetStateTable(characterKey, task)
    local done = IsTaskDone(characterKey, task)
    local title = task.priority and "! " or ""

    if showCharacter then
        title = title .. GetShortCharacterName(characterKey) .. ": "
    end
    title = title .. task.label

    row.left:ClearAllPoints()
    row.left:SetPoint("LEFT", row.check, "RIGHT", 0, 5)
    row.left:SetPoint("RIGHT", -168, 5)
    row.right:ClearAllPoints()
    row.right:SetPoint("RIGHT", -112, 5)
    row.right:SetWidth(54)
    row.right:SetJustifyH("RIGHT")
    row.left:SetText(title)
    row.right:SetText(TaskProgressText(characterKey, task))
    row.right:SetTextColor(ProgressColor(done and 1 or 0, 1))
    row.sub:SetText(ResetLabel(task.reset) .. " | " .. ScopeLabel(task.scope) .. (task.note ~= "" and " | " .. task.note or ""))
    row.check:Show()
    row.check:SetChecked(done)
    row.check:SetScript("OnClick", function(self)
        SetTaskDone(characterKey, task, self:GetChecked())
        Refresh()
        RefreshTracker()
    end)

    if task.max > 1 then
        row.minus:Show()
        row.plus:Show()
        row.minus:SetScript("OnClick", function()
            SetTaskProgress(characterKey, task, state.progress - 1)
            Refresh()
            RefreshTracker()
        end)
        row.plus:SetScript("OnClick", function()
            SetTaskProgress(characterKey, task, state.progress + 1)
            Refresh()
            RefreshTracker()
        end)
    end

    row.remove:Show()
    row.remove:SetScript("OnClick", function()
        RequestRemoveTask(task.id)
    end)
end

local function CreatePlannerRow(parent, rowIndex, item)
    local row = EnsureTextRow(parent, rowIndex)
    local task = item.task
    row.left:SetText((task.priority and "! " or "") .. GetShortCharacterName(item.characterKey) .. ": " .. task.label)
    row.right:SetText(TaskProgressText(item.characterKey, task))
    row.right:SetTextColor(1, 0.82, 0.25)
    row.sub:SetText(ResetLabel(task.reset) .. " | " .. ScopeLabel(task.scope) .. (task.note ~= "" and " | " .. task.note or ""))
    row:EnableMouse(true)
    row:SetScript("OnClick", function()
        SetTaskProgress(item.characterKey, task, GetStateTable(item.characterKey, task).progress + 1)
        Refresh()
        RefreshTracker()
    end)
end

local function RenderOverview()
    local rowIndex = 1
    for _, characterKey in ipairs(SortCharacterKeys()) do
        CreateCharacterCard(ui.frame.content, rowIndex, characterKey)
        rowIndex = rowIndex + 1
    end
    return rowIndex
end

local function RenderTaskList(resetType)
    local rowIndex = 1
    local currentKey = GetCharacterKey()
    for _, characterKey in ipairs(SortCharacterKeys()) do
        for _, task in ipairs(db.tasks) do
            if task.scope == "account" and characterKey ~= currentKey then
                -- Account tasks share one state, so show them once in list views.
            elseif (not resetType or task.reset == resetType) and TaskMatchesFilter(characterKey, task) then
                CreateTaskRow(ui.frame.content, rowIndex, characterKey, task, true)
                rowIndex = rowIndex + 1
            end
        end
    end
    return rowIndex
end

local function RenderPlanner()
    local rowIndex = 1
    for _, item in ipairs(GetPlannerItems(18)) do
        CreatePlannerRow(ui.frame.content, rowIndex, item)
        rowIndex = rowIndex + 1
    end
    return rowIndex
end

local function RenderSettings()
    local rowIndex = 1
    local rows = {
        { label = "Tracker", value = db.trackerShown and "Shown" or "Hidden", click = function()
            db.trackerShown = not db.trackerShown
            RefreshTracker()
        end },
        { label = "Login Summary", value = db.showLoginSummary and "On" or "Off", click = function()
            db.showLoginSummary = not db.showLoginSummary
        end },
        { label = "Default Weeklies", value = "Restore", click = function()
            RestoreDefaultTasks()
        end },
        { label = "Default Dailies", value = "Restore", click = function()
            RestoreDailyDefaultTasks()
        end },
        { label = "Task Export", value = "Print", click = function()
            ExportTasks()
        end },
        { label = "Undo Delete", value = "Restore", click = function()
            UndoLastDelete()
        end },
    }

    for _, setting in ipairs(rows) do
        local row = EnsureTextRow(ui.frame.content, rowIndex)
        row.left:SetText(setting.label)
        row.right:SetText(setting.value)
        row.right:SetTextColor(0.72, 0.9, 1)
        row.sub:SetText("Click to toggle.")
        row:EnableMouse(true)
        row:SetScript("OnClick", function()
            setting.click()
            Refresh()
        end)
        rowIndex = rowIndex + 1
    end

    return rowIndex
end

local function SetTab(tabId)
    db.activeTab = tabId
    Refresh()
end

local function SetFilter(filterId)
    db.filter = filterId
    Refresh()
end

local function UpdateTabButtons()
    if not ui.frame or not ui.frame.tabs then
        return
    end

    for _, tab in ipairs(TABS) do
        local button = ui.frame.tabs[tab.id]
        local active = db.activeTab == tab.id
        button:SetButtonState(active and "PUSHED" or "NORMAL", active)
        if button:GetFontString() then
            button:GetFontString():SetTextColor(active and 0.53 or 0.86, active and 0.8 or 0.82, active and 1 or 0.68)
        end
    end

    local showFilters = db.activeTab == "tasks" or db.activeTab == "today" or db.activeTab == "weekly"
    for _, filter in ipairs(FILTERS) do
        local button = ui.frame.filters[filter.id]
        if showFilters then
            button:Show()
            local active = db.filter == filter.id
            button:SetButtonState(active and "PUSHED" or "NORMAL", active)
            if button:GetFontString() then
                button:GetFontString():SetTextColor(active and 0.53 or 0.86, active and 0.8 or 0.82, active and 1 or 0.68)
            end
        else
            button:Hide()
        end
    end
end

local function UpdateMinimapButton() end

local function CreateMinimapButton() end

CreateTracker = function()
    if ui.tracker then
        return
    end

    local frame = CreateFrame("Frame", "AltChoreDashboardTracker", UIParent, "BackdropTemplate")
    frame:SetSize(190, 36)
    frame:SetPoint(db.trackerPosition.point, UIParent, db.trackerPosition.point, db.trackerPosition.x, db.trackerPosition.y)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetClampedToScreen(true)
    frame:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true,
        tileSize = 16,
        edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    frame:SetBackdropColor(0.03, 0.03, 0.04, 0.86)
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
            if not ui.frame then
                CreateUI()
            end
            Refresh()
            ui.frame:Show()
        end
    end)

    frame.title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    frame.title:SetPoint("TOPLEFT", 8, -7)
    frame.title:SetText("Alt Chores")

    ui.tracker = frame
    ui.trackerRows = {}
end

local function EnsureTrackerRow(index)
    local row = ui.trackerRows[index]
    if not row then
        row = CreateFrame("Button", nil, ui.tracker)
        row:SetHeight(18)
        row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.name:SetPoint("LEFT", 8, 0)
        row.name:SetJustifyH("LEFT")
        row.progress = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.progress:SetPoint("RIGHT", -8, 0)
        row:SetScript("OnClick", function()
            if not ui.frame then
                CreateUI()
            end
            db.activeTab = "overview"
            Refresh()
            ui.frame:Show()
        end)
        ui.trackerRows[index] = row
    end

    row:ClearAllPoints()
    row:SetPoint("TOPLEFT", 0, -22 - ((index - 1) * 18))
    row:SetPoint("RIGHT", 0, 0)
    row:Show()
    return row
end

RefreshTracker = function()
    if not ui.tracker then
        return
    end

    if not db.trackerShown then
        ui.tracker:Hide()
        return
    end

    ui.tracker:Show()
    ClearRows(ui.trackerRows)

    local keys = SortCharacterKeys()
    local visible = math.min(#keys, 8)
    ui.tracker:SetHeight(28 + visible * 18)

    for index = 1, visible do
        local key = keys[index]
        local done, total = CountDone(key)
        local r, g, b = ProgressColor(done, total)
        local row = EnsureTrackerRow(index)
        row.name:SetText(GetShortCharacterName(key))
        row.progress:SetText(done == total and "DONE" or (done .. "/" .. total))
        row.progress:SetTextColor(r, g, b)
    end
end

CreateUI = function()
    local frame = CreateFrame("Frame", "AltChoreDashboardFrame", UIParent, "BackdropTemplate")
    frame:SetSize(620, 520)
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
    frame.header:SetHeight(96)
    frame.header:SetColorTexture(0.02, 0.08, 0.11, 0.82)

    frame.headerLine = frame:CreateTexture(nil, "ARTWORK")
    frame.headerLine:SetPoint("TOPLEFT", 16, -98)
    frame.headerLine:SetPoint("TOPRIGHT", -16, -98)
    frame.headerLine:SetHeight(1)
    frame.headerLine:SetColorTexture(0.53, 0.8, 1, 0.55)

    frame.title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    frame.title:SetPoint("TOPLEFT", 18, -16)
    frame.title:SetText("|cff88ccffAlt Chore|r Dashboard")

    frame.subtitle = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    frame.subtitle:SetPoint("TOPLEFT", 18, -38)
    frame.subtitle:SetText("Daily, weekly, and account chore tracking across alts")

    frame.close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    frame.close:SetPoint("TOPRIGHT", -8, -8)
    frame.close:SetScript("OnClick", function()
        frame:Hide()
    end)

    frame.resetDaily = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    frame.resetDaily:SetSize(96, 22)
    frame.resetDaily:SetPoint("TOPRIGHT", frame.close, "BOTTOMRIGHT", -106, -2)
    frame.resetDaily:SetText("Reset Daily")
    frame.resetDaily:SetScript("OnClick", function() ManualReset("daily") end)

    frame.resetWeekly = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    frame.resetWeekly:SetSize(96, 22)
    frame.resetWeekly:SetPoint("LEFT", frame.resetDaily, "RIGHT", 6, 0)
    frame.resetWeekly:SetText("Reset Weekly")
    frame.resetWeekly:SetScript("OnClick", function() ManualReset("weekly") end)

    frame.summary = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    frame.summary:SetPoint("TOPLEFT", 18, -108)
    frame.summary:SetPoint("RIGHT", -18, -108)
    frame.summary:SetJustifyH("LEFT")

    frame.tabs = {}
    local previousTab
    for _, tab in ipairs(TABS) do
        local button = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
        button:SetSize(86, 22)
        if previousTab then
            button:SetPoint("LEFT", previousTab, "RIGHT", 5, 0)
        else
            button:SetPoint("TOPLEFT", 18, -62)
        end
        button:SetText(tab.label)
        button:SetScript("OnClick", function() SetTab(tab.id) end)
        frame.tabs[tab.id] = button
        previousTab = button
    end

    frame.filters = {}
    local previousFilter
    for _, filter in ipairs(FILTERS) do
        local button = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
        button:SetSize(74, 20)
        if previousFilter then
            button:SetPoint("LEFT", previousFilter, "RIGHT", 5, 0)
        else
            button:SetPoint("TOPLEFT", 18, -88)
        end
        button:SetText(filter.label)
        button:SetScript("OnClick", function() SetFilter(filter.id) end)
        frame.filters[filter.id] = button
        previousFilter = button
    end

    frame.scroll = CreateFrame("ScrollFrame", "AltChoreDashboardScrollFrame", frame, "UIPanelScrollFrameTemplate")
    frame.scroll:SetPoint("TOPLEFT", 14, -136)
    frame.scroll:SetPoint("BOTTOMRIGHT", -32, 118)

    frame.content = CreateFrame("Frame", nil, frame.scroll)
    frame.content:SetSize(548, 260)
    frame.scroll:SetScrollChild(frame.content)
    frame.scroll:SetScript("OnSizeChanged", function(_, width, height)
        frame.content:SetWidth(width)
        frame.content:SetHeight(math.max(frame.content:GetHeight(), height))
    end)

    frame.editorLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    frame.editorLabel:SetPoint("BOTTOMLEFT", 20, 86)
    frame.editorLabel:SetText("New task")

    frame.editBox = CreateFrame("EditBox", nil, frame, "InputBoxTemplate")
    frame.editBox:SetSize(230, 24)
    frame.editBox:SetPoint("LEFT", frame.editorLabel, "RIGHT", 12, 0)
    frame.editBox:SetAutoFocus(false)

    frame.maxBox = CreateFrame("EditBox", nil, frame, "InputBoxTemplate")
    frame.maxBox:SetSize(42, 24)
    frame.maxBox:SetPoint("LEFT", frame.editBox, "RIGHT", 12, 0)
    frame.maxBox:SetAutoFocus(false)
    frame.maxBox:SetNumeric(true)
    frame.maxBox:SetText("1")

    frame.dailyCheck = CreateFrame("CheckButton", nil, frame, "UICheckButtonTemplate")
    frame.dailyCheck:SetSize(24, 24)
    frame.dailyCheck:SetPoint("BOTTOMLEFT", 20, 54)
    frame.dailyLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    frame.dailyLabel:SetPoint("LEFT", frame.dailyCheck, "RIGHT", 0, 0)
    frame.dailyLabel:SetText("Daily")

    frame.accountCheck = CreateFrame("CheckButton", nil, frame, "UICheckButtonTemplate")
    frame.accountCheck:SetSize(24, 24)
    frame.accountCheck:SetPoint("LEFT", frame.dailyLabel, "RIGHT", 16, 0)
    frame.accountLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    frame.accountLabel:SetPoint("LEFT", frame.accountCheck, "RIGHT", 0, 0)
    frame.accountLabel:SetText("Account")

    frame.priorityCheck = CreateFrame("CheckButton", nil, frame, "UICheckButtonTemplate")
    frame.priorityCheck:SetSize(24, 24)
    frame.priorityCheck:SetPoint("LEFT", frame.accountLabel, "RIGHT", 16, 0)
    frame.priorityLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    frame.priorityLabel:SetPoint("LEFT", frame.priorityCheck, "RIGHT", 0, 0)
    frame.priorityLabel:SetText("Priority")

    frame.noteBox = CreateFrame("EditBox", nil, frame, "InputBoxTemplate")
    frame.noteBox:SetSize(250, 24)
    frame.noteBox:SetPoint("BOTTOMLEFT", 20, 24)
    frame.noteBox:SetAutoFocus(false)

    frame.add = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    frame.add:SetSize(86, 22)
    frame.add:SetPoint("LEFT", frame.noteBox, "RIGHT", 12, 0)
    frame.add:SetText("Add")
    frame.add:SetScript("OnClick", function()
        AddTask(
            frame.editBox:GetText(),
            frame.dailyCheck:GetChecked() and "daily" or "weekly",
            frame.accountCheck:GetChecked() and "account" or "character",
            frame.priorityCheck:GetChecked(),
            frame.maxBox:GetText(),
            frame.noteBox:GetText()
        )
        frame.editBox:SetText("")
        frame.noteBox:SetText("")
        frame.maxBox:SetText("1")
    end)

    ui.frame = frame
    frame:Hide()
end

Refresh = function()
    if not ui.frame then
        return
    end

    ResetTasksIfNeeded()
    EnsureCharacter()
    ClearRows(ui.rows)
    UpdateTabButtons()

    local currentKey = GetCharacterKey()
    local dailyOpen = GetOpenTaskCount(currentKey, "daily")
    local weeklyOpen = GetOpenTaskCount(currentKey, "weekly")
    local rowIndex

    if db.activeTab == "overview" then
        rowIndex = RenderOverview()
    elseif db.activeTab == "today" then
        rowIndex = RenderTaskList("daily")
    elseif db.activeTab == "weekly" then
        rowIndex = RenderTaskList("weekly")
    elseif db.activeTab == "planner" then
        rowIndex = RenderPlanner()
    elseif db.activeTab == "settings" then
        rowIndex = RenderSettings()
    else
        rowIndex = RenderTaskList()
    end

    ui.frame.content:SetHeight(math.max((rowIndex - 1) * 38, ui.frame.scroll:GetHeight()))
    ui.frame.summary:SetText(dailyOpen .. " daily and " .. weeklyOpen .. " weekly chores open on " .. GetShortCharacterName(currentKey) .. ".")
end

local function ToggleDashboard()
    if not ui.frame then
        CreateUI()
    end

    if ui.frame:IsShown() then
        ui.frame:Hide()
        return
    end

    Refresh()
    ui.frame:Show()
end

local function PrintHelp()
    Message("/acd - Toggle the dashboard.")
    Message("/acd tracker - Show or hide the compact tracker.")
    Message("/acd add weekly Task Name - Add a weekly task.")
    Message("/acd add daily Task Name - Add a daily task.")
    Message("/acd reset daily - Clear daily tasks.")
    Message("/acd reset weekly - Clear weekly tasks.")
    Message("/acd defaults - Restore the default weekly task list.")
    Message("/acd dailies - Restore starter daily tasks.")
    Message("/acd undo - Restore the last deleted task.")
    Message("/acd export - Print a task setup backup string.")
    Message("/acd import <string> - Replace tasks with an exported setup.")
    Message("/acd minimap - Minimap button was removed; use /armada.")
end

SLASH_ALTCHOREDASHBOARD1 = "/acd"
SLASH_ALTCHOREDASHBOARD2 = "/altchore"
SlashCmdList.ALTCHOREDASHBOARD = function(message)
    message = Trim(message)
    local lower = string.lower(message)

    if lower == "help" then
        PrintHelp()
    elseif lower == "tracker" then
        db.trackerShown = not db.trackerShown
        RefreshTracker()
        Message(db.trackerShown and "Tracker shown." or "Tracker hidden.")
    elseif lower == "reset" or lower == "reset weekly" then
        ManualReset("weekly")
    elseif lower == "reset daily" then
        ManualReset("daily")
    elseif lower == "defaults" or lower == "restore defaults" then
        RestoreDefaultTasks()
    elseif lower == "dailies" or lower == "daily defaults" then
        RestoreDailyDefaultTasks()
    elseif lower == "undo" then
        UndoLastDelete()
    elseif lower == "export" then
        ExportTasks()
    elseif string.sub(lower, 1, 7) == "import " then
        ImportTasks(string.sub(message, 8))
    elseif lower == "minimap" then
        Message("Minimap button removed. Use /armada to open the suite.")
    elseif lower == "debug" then
        if db then
            Message("trackerShown=" .. tostring(db.trackerShown) .. " activeTab=" .. tostring(db.activeTab))
        else
            Message("db is nil - ADDON_LOADED never fired")
        end
    elseif string.sub(lower, 1, 10) == "add daily " then
        AddTask(string.sub(message, 11), "daily", "character", false, 1, "")
    elseif string.sub(lower, 1, 11) == "add weekly " then
        AddTask(string.sub(message, 12), "weekly", "character", false, 1, "")
    else
        ToggleDashboard()
    end
end

local function PrintLoginSummary()
    if not db.showLoginSummary then
        return
    end

    local currentKey = GetCharacterKey()
    local dailyOpen = GetOpenTaskCount(currentKey, "daily")
    local weeklyOpen = GetOpenTaskCount(currentKey, "weekly")
    local planner = GetPlannerItems(1)
    Message(dailyOpen .. " daily and " .. weeklyOpen .. " weekly chores open on this character.")
    if planner[1] then
        Message("Next up: " .. GetShortCharacterName(planner[1].characterKey) .. " - " .. planner[1].task.label .. ".")
    end
end

local function OnEvent(event, arg1)
    if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
        EnsureDB()
    elseif event == "PLAYER_LOGIN" then
        EnsureCharacter()
        ResetTasksIfNeeded()
        CreateTracker()
        RefreshTracker()
        PrintLoginSummary()
    elseif event == "PLAYER_ENTERING_WORLD" then
        if not db then EnsureDB() end
    elseif event == "PLAYER_LEVEL_UP" then
        EnsureCharacter()
        Refresh()
        RefreshTracker()
    end
end

EventUtil.ContinueOnAddOnLoaded(ADDON_NAME, function()
    EnsureDB()
    EnsureCharacter()
    ResetTasksIfNeeded()
    CreateTracker()
    RefreshTracker()
    PrintLoginSummary()
end)

EventRegistry:RegisterCallback("PLAYER_ENTERING_WORLD", function()
    if not db then EnsureDB() end
end, addon)

EventRegistry:RegisterCallback("PLAYER_LEVEL_UP", function()
    EnsureCharacter()
    Refresh()
    RefreshTracker()
end, addon)

-- Armada Addons hub registration
C_Timer.After(0, function()
    if ArmadaAddons and ArmadaAddons.Register then
        ArmadaAddons.Register({
            name = "Alt Chore Dashboard",
            version = "0.4.0",
            desc = "Track daily and weekly chores across all your alts.",
            color = { 0.48, 0.78, 1 },
            open = function()
                ToggleDashboard()
            end,
        })
    end
end)

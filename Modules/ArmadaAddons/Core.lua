--[[
@armada-addon-system
@version 1.0.0
@author Armada Studios

SYSTEM: ArmadaAddons Hub Registration
PURPOSE: Every new addon built by Armada Studios MUST register itself with ArmadaAddons
         so it appears as a card in the hub UI automatically.

RULE: When creating or editing any Armada Studios WoW addon, always append the
      registration block below at the bottom of Core.lua after all events.
      Never skip this step. Never hardcode addon lists inside ArmadaAddons.

REGISTRATION BLOCK (copy this, do not modify the structure):

    C_Timer.After(0, function()
        if ArmadaAddons and ArmadaAddons.Register then
            ArmadaAddons.Register({
                name    = "Your Addon Name",
                version = "1.0.0",
                desc    = "One line description of what it does.",
                color   = { r, g, b },
                open    = function()
                    ToggleUI()
                end,
            })
        end
    end)

COLORS:
    Gold   { 1, 0.82, 0.1 }
    Blue   { 0.48, 0.78, 1 }
    Red    { 1, 0.45, 0.45 }
    Green  { 0.4, 1, 0.4 }
    Purple { 0.78, 0.48, 1 }

SAFETY: If ArmadaAddons is not installed the block is silently ignored.
--]]

local ADDON_NAME = "ArmadaSuite"

local db
local ui = {}

ArmadaAddons = ArmadaAddons or {}
ArmadaAddons.registry = ArmadaAddons.registry or {}

function ArmadaAddons.Register(entry)
    if not entry or not entry.name then return end
    for _, existing in ipairs(ArmadaAddons.registry) do
        if existing.name == entry.name then return end
    end
    ArmadaAddons.registry[#ArmadaAddons.registry + 1] = entry
    if ui.frame then
        ui.frame:Hide()
        ui.frame = nil
        CreateUI()
    end
end

local function EnsureDB()
    ArmadaAddonsDB = ArmadaAddonsDB or {}
    db = ArmadaAddonsDB
    db.position = db.position or { point = "CENTER", x = 0, y = 0 }
    db.position.w = db.position.w or 460
    db.position.h = db.position.h or frameHeight
    db.hubPosition = db.hubPosition or { point = "TOPRIGHT", x = -220, y = -180 }
    db.hubScale = db.hubScale or 1.0
    db.hubLocked = db.hubLocked or false
    db.hubHidden = db.hubHidden or false
    db.frameOpacity = db.frameOpacity or 0.95
    db.loginMessage = db.loginMessage ~= false
    db.activeTab = db.activeTab or "addons"
end

local Refresh

local function ApplyHubScale()
    if ui.hubButton then
        ui.hubButton:SetScale(db.hubScale)
    end
end

local function ApplyFrameOpacity()
    if ui.frame then
        ui.frame:SetAlpha(db.frameOpacity)
    end
end

local function ToggleUI()
    if not ui.frame then return end
    if ui.frame:IsShown() then
        ui.frame:Hide()
    else
        ui.frame:Show()
    end
end

local function CreateHubButton()
    if ui.hubButton then return end

    local button = CreateFrame("Button", "ArmadaAddonsHubButton", UIParent)
    button:SetSize(48, 48)
    button:SetFrameStrata("MEDIUM")
    button:SetMovable(true)
    button:SetClampedToScreen(true)
    button:EnableMouse(true)
    button:RegisterForDrag("LeftButton")
    button:SetPoint(db.hubPosition.point, UIParent, db.hubPosition.point, db.hubPosition.x, db.hubPosition.y)
    button:SetScale(db.hubScale)

    button.ring = button:CreateTexture(nil, "BACKGROUND")
    button.ring:SetColorTexture(0.85, 0.65, 0.05, 1)
    button.ring:SetSize(48, 48)
    button.ring:SetPoint("CENTER", 0, 0)

    button.inner = button:CreateTexture(nil, "BORDER")
    button.inner:SetColorTexture(0.08, 0.06, 0.02, 1)
    button.inner:SetSize(40, 40)
    button.inner:SetPoint("CENTER", 0, 0)

    button.label = button:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    button.label:SetPoint("CENTER", 0, 0)
    button.label:SetText("|cffffcc00A|r")

    button.glow = button:CreateTexture(nil, "HIGHLIGHT")
    button.glow:SetColorTexture(1, 0.9, 0.3, 0.25)
    button.glow:SetAllPoints(button)

    button:SetScript("OnClick", ToggleUI)
    button:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("|cffffcc00Armada Suite|r")
        GameTooltip:AddLine("Click to open the suite.", 1, 1, 1)
        if not db.hubLocked then
            GameTooltip:AddLine("Drag to move.", 0.7, 0.7, 0.7)
        end
        GameTooltip:Show()
    end)
    button:SetScript("OnLeave", function() GameTooltip:Hide() end)
    button:SetScript("OnDragStart", function(self)
        if not db.hubLocked then self:StartMoving() end
    end)
    button:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, _, x, y = self:GetPoint(1)
        db.hubPosition.point = point
        db.hubPosition.x = x
        db.hubPosition.y = y
    end)

    if db.hubHidden then button:Hide() end
    ui.hubButton = button
end

local function SetTab(tab)
    db.activeTab = tab
    Refresh()
end

local function UpdateTabButtons()
    if not ui.tabs then return end
    for tab, button in pairs(ui.tabs) do
        local active = db.activeTab == tab
        button:SetButtonState(active and "PUSHED" or "NORMAL", active)
        if button:GetFontString() then
            if active then
                button:GetFontString():SetTextColor(1, 0.8, 0.1)
            else
                button:GetFontString():SetTextColor(0.86, 0.82, 0.68)
            end
        end
    end
end

local function RenderAddons()
    local registry = ArmadaAddons.registry
    local CARD_HEIGHT = 80

    if #registry == 0 then
        local empty = ui.addonContainer:CreateFontString(nil, "OVERLAY", "GameFontDisable")
        empty:SetPoint("CENTER", ui.addonContainer, "CENTER", 0, 0)
        empty:SetText("No addons registered yet.")
        return
    end

    for index, entry in ipairs(registry) do
        local color = entry.color or { 1, 1, 1 }

        local card = CreateFrame("Frame", nil, ui.addonContainer, "BackdropTemplate")
        card:SetSize(428, CARD_HEIGHT)
        card:SetPoint("TOPLEFT", 0, -((index - 1) * (CARD_HEIGHT + 10)))
        card:SetBackdrop({
            bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 12,
            insets = { left = 3, right = 3, top = 3, bottom = 3 },
        })
        card:SetBackdropColor(0.03, 0.04, 0.05, 0.88)
        card:SetBackdropBorderColor(0.18, 0.23, 0.28, 0.95)

        local bar = card:CreateTexture(nil, "ARTWORK")
        bar:SetSize(4, CARD_HEIGHT - 8)
        bar:SetPoint("LEFT", 6, 0)
        bar:SetColorTexture(color[1], color[2], color[3], 1)

        local nameText = card:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        nameText:SetPoint("TOPLEFT", 18, -12)
        nameText:SetText(string.format("|cff%02x%02x%02x%s|r",
            math.floor(color[1] * 255),
            math.floor(color[2] * 255),
            math.floor(color[3] * 255),
            entry.name))

        local version = card:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        version:SetPoint("TOPLEFT", 18, -28)
        version:SetText("v" .. (entry.version or "1.0.0"))

        local desc = card:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        desc:SetPoint("TOPLEFT", 18, -44)
        desc:SetPoint("RIGHT", -110, -44)
        desc:SetJustifyH("LEFT")
        desc:SetText(entry.desc or "")

        local btn = CreateFrame("Button", nil, card, "UIPanelButtonTemplate")
        btn:SetSize(90, 26)
        btn:SetPoint("RIGHT", -10, 0)
        btn:SetText("Open")
        btn:SetScript("OnClick", function()
            ui.frame:Hide()
            if entry.open then entry.open() end
        end)
    end
end

local function RenderSettings()
    local rows = {
        {
            label = "Hub Button",
            value = db.hubHidden and "Hidden" or "Shown",
            sub = "Toggle the floating hub button",
            click = function()
                db.hubHidden = not db.hubHidden
                if ui.hubButton then
                    if db.hubHidden then ui.hubButton:Hide() else ui.hubButton:Show() end
                end
            end,
        },
        {
            label = "Lock Button Position",
            value = db.hubLocked and "Locked" or "Unlocked",
            sub = "Prevent accidental dragging",
            click = function()
                db.hubLocked = not db.hubLocked
            end,
        },
        {
            label = "Button Size",
            value = db.hubScale == 0.75 and "Small" or db.hubScale == 1.0 and "Medium" or "Large",
            sub = "Cycle: Small (0.75x) → Medium (1x) → Large (1.5x)",
            click = function()
                if db.hubScale == 0.75 then
                    db.hubScale = 1.0
                elseif db.hubScale == 1.0 then
                    db.hubScale = 1.5
                else
                    db.hubScale = 0.75
                end
                ApplyHubScale()
            end,
        },
        {
            label = "Window Opacity",
            value = math.floor(db.frameOpacity * 100) .. "%",
            sub = "Cycle: 60% → 80% → 95% → 100%",
            click = function()
                if db.frameOpacity < 0.65 then
                    db.frameOpacity = 0.80
                elseif db.frameOpacity < 0.85 then
                    db.frameOpacity = 0.95
                elseif db.frameOpacity < 0.98 then
                    db.frameOpacity = 1.0
                else
                    db.frameOpacity = 0.60
                end
                ApplyFrameOpacity()
            end,
        },
        {
            label = "Login Message",
            value = db.loginMessage and "On" or "Off",
            sub = "Show /armada reminder on login",
            click = function()
                db.loginMessage = not db.loginMessage
            end,
        },
        {
            label = "Reset Button Position",
            value = "Reset",
            sub = "Move hub button back to default position",
            click = function()
                db.hubPosition = { point = "TOPRIGHT", x = -220, y = -180 }
                if ui.hubButton then
                    ui.hubButton:ClearAllPoints()
                    ui.hubButton:SetPoint(db.hubPosition.point, UIParent, db.hubPosition.point, db.hubPosition.x, db.hubPosition.y)
                end
            end,
        },
    }

    for index, data in ipairs(rows) do
        local row = CreateFrame("Button", nil, ui.settingsContainer, "BackdropTemplate")
        row:SetSize(428, 52)
        row:SetPoint("TOPLEFT", 0, -((index - 1) * 58))
        row:SetBackdrop({
            bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 12,
            insets = { left = 3, right = 3, top = 3, bottom = 3 },
        })
        row:SetBackdropColor(0.03, 0.04, 0.05, 0.86)
        row:SetBackdropBorderColor(0.18, 0.23, 0.28, 0.95)

        local bg = row:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(0, 0, 0, 0)

        local left = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        left:SetPoint("TOPLEFT", 8, -8)
        left:SetPoint("RIGHT", -120, -8)
        left:SetJustifyH("LEFT")
        left:SetText(data.label)

        local right = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        right:SetPoint("TOPRIGHT", -8, -8)
        right:SetJustifyH("RIGHT")
        right:SetTextColor(0.72, 0.9, 1)
        right:SetText(data.value)

        local sub = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        sub:SetPoint("BOTTOMLEFT", 8, 8)
        sub:SetText(data.sub)

        row:SetScript("OnClick", function()
            data.click()
            ui.frame:Hide()
            ui.frame = nil
            CreateUI()
            ui.frame:Show()
        end)
        row:SetScript("OnEnter", function(self)
            self:SetBackdropColor(0.07, 0.09, 0.11, 0.92)
            self:SetBackdropBorderColor(1, 0.8, 0.1, 0.8)
        end)
        row:SetScript("OnLeave", function(self)
            self:SetBackdropColor(0.03, 0.04, 0.05, 0.86)
            self:SetBackdropBorderColor(0.18, 0.23, 0.28, 0.95)
        end)
    end
end

Refresh = function()
    UpdateTabButtons()
    if ui.addonContainer then ui.addonContainer:Hide() end
    if ui.settingsContainer then ui.settingsContainer:Hide() end
    if db.activeTab == "settings" then
        if ui.settingsContainer then ui.settingsContainer:Show() end
    else
        if ui.addonContainer then ui.addonContainer:Show() end
    end
end

function CreateUI()
    local registry = ArmadaAddons.registry
    local CARD_HEIGHT = 80
    local CARD_GAP = 10
    local PADDING = 14
    local HEADER_HEIGHT = 90  -- title + subtitle + tabs
    local addonCount = math.max(#registry, 1)
    local addonHeight = addonCount * CARD_HEIGHT + (addonCount - 1) * CARD_GAP
    local settingsHeight = 6 * 58
    local contentHeight = math.max(addonHeight, settingsHeight)
    local frameHeight = HEADER_HEIGHT + contentHeight + PADDING * 2

    local frame = CreateFrame("Frame", "ArmadaAddonsFrame", UIParent, "BackdropTemplate")
    frame:SetSize(db.position.w or 460, db.position.h or frameHeight)
    frame:SetPoint(db.position.point, UIParent, db.position.point, db.position.x, db.position.y)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetClampedToScreen(true)
    frame:SetAlpha(db.frameOpacity)
    frame:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    frame:SetBackdropColor(0.015, 0.018, 0.022, 0.96)
    frame:SetBackdropBorderColor(0.42, 0.34, 0.08, 1)
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, _, x, y = self:GetPoint(1)
        db.position.point = point
        db.position.x = x
        db.position.y = y
    end)

    -- Resize grip
    frame:SetResizable(true)
    frame:SetResizeBounds(300, 200, 800, 1000)
    local grip = CreateFrame("Button", nil, frame)
    grip:SetSize(16, 16)
    grip:SetPoint("BOTTOMRIGHT", -4, 4)
    grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    grip:SetScript("OnMouseDown", function() frame:StartSizing("BOTTOMRIGHT") end)
    grip:SetScript("OnMouseUp", function()
        frame:StopMovingOrSizing()
        local w, h = frame:GetSize()
        db.position.w = w
        db.position.h = h
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
    frame.headerLine:SetColorTexture(1, 0.8, 0.1, 0.55)

    frame.title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    frame.title:SetPoint("TOPLEFT", 18, -16)
    frame.title:SetText("|cffffcc00Armada|r Suite")

    frame.subtitle = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    frame.subtitle:SetPoint("TOPLEFT", 18, -36)
    frame.subtitle:SetText("Armada Studios  —  " .. #registry .. " addon" .. (#registry == 1 and "" or "s") .. " registered")

    frame.close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    frame.close:SetPoint("TOPRIGHT", -8, -8)
    frame.close:SetScript("OnClick", function()
        frame:Hide()
    end)

    -- Tabs
    ui.tabs = {}
    local tabDefs = { { "addons", "Addons" }, { "settings", "Settings" } }
    local prev
    for _, tab in ipairs(tabDefs) do
        local btn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
        btn:SetSize(100, 22)
        if prev then
            btn:SetPoint("LEFT", prev, "RIGHT", 5, 0)
        else
            btn:SetPoint("TOPLEFT", 18, -56)
        end
        btn:SetText(tab[2])
        btn:SetScript("OnClick", function() SetTab(tab[1]) end)
        ui.tabs[tab[1]] = btn
        prev = btn
    end

    -- Content area (no scroll needed, frame is resizable)
    local content = CreateFrame("Frame", nil, frame)
    content:SetPoint("TOPLEFT", 14, -86)
    content:SetPoint("BOTTOMRIGHT", -14, 14)

    -- Addon cards container
    ui.addonContainer = CreateFrame("Frame", nil, content)
    ui.addonContainer:SetPoint("TOPLEFT", 0, 0)
    ui.addonContainer:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT", 0, 0)

    ui.settingsContainer = CreateFrame("Frame", nil, content)
    ui.settingsContainer:SetPoint("TOPLEFT", 0, 0)
    ui.settingsContainer:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT", 0, 0)

    RenderAddons()
    RenderSettings()

    ui.frame = frame
    frame:Hide()

    Refresh()
end

SLASH_ARMADAADDONS1 = "/armada"
SLASH_ARMADAADDONS2 = "/aa"
SlashCmdList.ARMADAADDONS = function(msg)
    msg = strtrim(msg or "")
    if string.lower(msg) == "show" then
        db.hubHidden = false
        if ui.hubButton then ui.hubButton:Show() end
        print("|cffffcc00Armada Suite:|r Hub button shown.")
    else
        ToggleUI()
    end
end

EventUtil.ContinueOnAddOnLoaded(ADDON_NAME, function()
    EnsureDB()
    C_Timer.After(0, function()
        CreateUI()
        CreateHubButton()
        if db.loginMessage then
            print("|cffffcc00Armada Suite:|r Type |cffffff00/armada|r to open the suite.")
        end
    end)
end)

EventRegistry:RegisterCallback("PLAYER_ENTERING_WORLD", function()
    if not db then EnsureDB() end
    if not ui.hubButton then CreateHubButton() end
end, {})

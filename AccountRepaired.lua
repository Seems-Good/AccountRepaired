--------------------------------------------------
-- Account Repaired  v@project-version@
--------------------------------------------------
local _, addonTable = ...
local L = addonTable.L

AccountRepaired = AccountRepaired or {}
local AR = AccountRepaired

--------------------------------------------------
-- SavedVariables
--------------------------------------------------
AccountRepairedDB      = AccountRepairedDB or {}
AccountRepairedPopupDB = AccountRepairedPopupDB or {}

local DB = AccountRepairedPopupDB
if DB.width        == nil then DB.width        = 540     end
if DB.height       == nil then DB.height       = 340     end
if DB.point        == nil then DB.point        = "CENTER" end
if DB.x            == nil then DB.x            = 0       end
if DB.y            == nil then DB.y            = 0       end
if DB.period       == nil then DB.period       = "all"   end
if DB.includeGuild == nil then DB.includeGuild = true    end
if DB.collapsed    == nil then DB.collapsed    = false   end

local function GetLayoutDB()
    if AccountPlayed and type(AccountPlayedPopupDB) == "table" then
        return AccountPlayedPopupDB
    end
    return DB
end

--------------------------------------------------
-- Constants
--------------------------------------------------
local DATA_RETENTION_SECONDS = 365 * 2 * 86400
local REPAIR_DELTA_TOLERANCE = 1.05
local COLLAPSED_H            = 82
local MIN_W, MIN_H           = 440, 240
local MAX_W, MAX_H           = 740, 480

local PERIOD_SECONDS = { day=86400, week=604800, month=2592000, all=0 }
local PERIOD_ORDER   = { "day", "week", "month", "all" }

local ARMOR_COLORS = {
    Cloth   = { r=0.78, g=0.78, b=0.85 },
    Leather = { r=0.85, g=0.60, b=0.20 },
    Mail    = { r=0.35, g=0.65, b=0.95 },
    Plate   = { r=0.75, g=0.40, b=1.00 },
    Unknown = { r=0.65, g=0.65, b=0.65 },
}
local ARMOR_TYPE_NAMES  = { "Cloth", "Leather", "Mail", "Plate", "Unknown" }
local ARMOR_SLOTS       = { 1, 3, 5, 7, 8 }
local ARMOR_TYPES_VALID = { Cloth=true, Leather=true, Mail=true, Plate=true }

local CHAT_CHANNELS = {
    { key="SAY",     label="Say",          color={1.0, 1.0, 1.0} },
    { key="PARTY",   label="Party",        color={0.5, 0.5, 1.0} },
    { key="RAID",    label="Raid",         color={1.0, 0.5, 0.0} },
    { key="GUILD",   label="Guild",        color={0.3, 1.0, 0.3} },
    { key="OFFICER", label="Officer",      color={0.3, 0.8, 0.3} },
    { key="NONE",    label="None (print)", color={0.6, 0.6, 0.6} },
}

local CPANEL_W=240; local CPANEL_ROW_H=22; local CPANEL_HEADER_H=28; local CPANEL_PAD=6

--------------------------------------------------
-- State
--------------------------------------------------
AR.mainFrame      = CreateFrame("Frame")
AR.popupFrame     = nil
AR.popupRows      = {}
AR.charPanel      = nil
AR.charPanelArmor = nil
AR.currentPeriod  = DB.period
AR.collapsed      = DB.collapsed

local inMerchant          = false
local lastMoney           = 0
local repairPending       = false
local snappedRepairCost   = 0
local repairWasGuildAvail = false
local pendingArmorDetect  = false

--------------------------------------------------
-- Character identity
--------------------------------------------------
local function GetCharInfo()
    local realm = (GetNormalizedRealmName and GetNormalizedRealmName()) or GetRealmName()
    return realm, UnitName("player")
end
local function GetCharKey(realm, name) return realm.."-"..name end
local function KeyToName(key) return key:match("%-([^%-]+)$") or key end

--------------------------------------------------
-- Armor detection
--------------------------------------------------
local function DetectArmorType()
    local counts = {}; local allReady = true
    for _, slotID in ipairs(ARMOR_SLOTS) do
        local itemID = GetInventoryItemID("player", slotID)
        if itemID then
            local _, _, _, _, _, _, sub = GetItemInfo(itemID)
            if sub then
                if ARMOR_TYPES_VALID[sub] then counts[sub] = (counts[sub] or 0) + 1 end
            else
                allReady = false
            end
        end
    end
    local best, bestN = "Unknown", 0
    for sub, n in pairs(counts) do if n > bestN then best, bestN = sub, n end end
    return best, allReady
end

local function RefreshCharArmorType()
    local realm, name  = GetCharInfo()
    local charKey      = GetCharKey(realm, name)
    local _, classFile = UnitClass("player")
    local armorType, allReady = DetectArmorType()
    if not AccountRepairedDB[charKey] then
        AccountRepairedDB[charKey] = { class=classFile or "UNKNOWN", armorType=armorType, repairs={} }
    end
    local cd = AccountRepairedDB[charKey]
    cd.class = classFile or cd.class or "UNKNOWN"
    if armorType ~= "Unknown" then cd.armorType = armorType end
    cd.armorType = cd.armorType or "Unknown"
    if not allReady then pendingArmorDetect = true end
end

--------------------------------------------------
-- Gold formatting
--------------------------------------------------
local function FormatGoldFull(copper)
    copper = math.floor(tonumber(copper) or 0)
    if copper <= 0 then return "|cffAAAAAA0g|r" end
    local g=math.floor(copper/10000); local s=math.floor((copper%10000)/100); local c=copper%100
    if     g > 0 then return string.format("|cffFFD700%d|rg |cffC0C0C0%d|rs |cffCD7F32%d|rc", g, s, c)
    elseif s > 0 then return string.format("|cffC0C0C0%d|rs |cffCD7F32%d|rc", s, c)
    else              return string.format("|cffCD7F32%d|rc", c) end
end

local function FormatGoldShort(copper)
    copper = math.floor(tonumber(copper) or 0)
    if copper <= 0 then return "|cffAAAAAA0g|r" end
    local gv = copper / 10000
    if gv >= 1000 then return string.format("|cffFFD700%.1fk|r", gv/1000)
    elseif gv >= 1 then return string.format("|cffFFD700%.1f|rg", gv) end
    local sv = copper / 100
    if sv >= 1 then return string.format("|cffC0C0C0%.1f|rs", sv) end
    return string.format("|cffCD7F32%d|rc", copper)
end

local function FormatGoldPlain(copper)
    copper = math.floor(tonumber(copper) or 0)
    if copper <= 0 then return "0g" end
    local g=math.floor(copper/10000); local s=math.floor((copper%10000)/100); local c=copper%100
    if g > 0 then return string.format("%dg %ds %dc", g, s, c)
    elseif s > 0 then return string.format("%ds %dc", s, c)
    else return string.format("%dc", c) end
end

--------------------------------------------------
-- Period helpers
--------------------------------------------------
local function GetPeriodStart(period)
    if period == "all" or not PERIOD_SECONDS[period] then return 0 end
    return time() - PERIOD_SECONDS[period]
end

local PERIOD_LABELS -- populated after L is available (same frame, so fine)
local function GetPeriodLabel(period)
    if not PERIOD_LABELS then
        PERIOD_LABELS = { day=L["PERIOD_DAY"], week=L["PERIOD_WEEK"], month=L["PERIOD_MONTH"], all=L["PERIOD_ALL"] }
    end
    return PERIOD_LABELS[period] or period
end

--------------------------------------------------
-- Data aggregation
--------------------------------------------------
local function GetCharRepairsInPeriod(cd, periodStart)
    local total = 0
    if not (cd and cd.repairs) then return 0 end
    local inclGuild = DB.includeGuild ~= false
    for _, e in ipairs(cd.repairs) do
        if (e.t or 0) >= periodStart and (not e.guild or inclGuild) then
            total = total + (e.g or 0)
        end
    end
    return total
end

local function GetArmorTypeTotals(period)
    local totals, acct = {}, 0
    local ps = GetPeriodStart(period)
    for _, cd in pairs(AccountRepairedDB) do
        if type(cd) == "table" and cd.repairs then
            local at  = cd.armorType or "Unknown"
            local amt = GetCharRepairsInPeriod(cd, ps)
            if amt > 0 then totals[at] = (totals[at] or 0) + amt; acct = acct + amt end
        end
    end
    return totals, acct
end

local function GetCharactersByArmorType(armorType, period)
    local chars = {}; local ps = GetPeriodStart(period)
    for charKey, cd in pairs(AccountRepairedDB) do
        if type(cd) == "table" and (cd.armorType or "Unknown") == armorType then
            local amt = GetCharRepairsInPeriod(cd, ps)
            if amt > 0 then
                table.insert(chars, { key=charKey, name=KeyToName(charKey), class=cd.class or "UNKNOWN", armorType=armorType, gold=amt })
            end
        end
    end
    table.sort(chars, function(a,b) return a.gold > b.gold end)
    return chars
end

local function GetCurrentCharAllPeriods()
    local realm, name = GetCharInfo()
    local cd = AccountRepairedDB[GetCharKey(realm, name)]
    local stats = { day=0, week=0, month=0, all=0 }
    local inclGuild = DB.includeGuild ~= false
    if cd and cd.repairs then
        local now = time()
        for _, e in ipairs(cd.repairs) do
            local t, g = e.t or 0, e.g or 0
            if not e.guild or inclGuild then
                stats.all = stats.all + g
                if t >= now-86400   then stats.day   = stats.day   + g end
                if t >= now-604800  then stats.week  = stats.week  + g end
                if t >= now-2592000 then stats.month = stats.month + g end
            end
        end
    end
    return stats, cd
end

--------------------------------------------------
-- Chat sharing
--------------------------------------------------
local function SendRepairBreakdown(armorType, channel)
    local chars = GetCharactersByArmorType(armorType, AR.currentPeriod)
    if #chars == 0 then return end
    local header = (L["ARMOR_"..armorType] or armorType).." ("..GetPeriodLabel(AR.currentPeriod).."):"
    if channel == "NONE" then
        print("|cff00ff00"..header.."|r")
        for _, ch in ipairs(chars) do
            local cc = RAID_CLASS_COLORS[ch.class] or {r=1,g=1,b=1}
            print(string.format("  |cff%02x%02x%02x%s|r - %s", cc.r*255, cc.g*255, cc.b*255, ch.name, FormatGoldFull(ch.gold)))
        end
    else
        local parts = { header }
        for _, ch in ipairs(chars) do parts[#parts+1] = ch.name.." "..FormatGoldPlain(ch.gold) end
        SendChatMessage(table.concat(parts, " "), channel)
    end
end

--------------------------------------------------
-- Record repair
--------------------------------------------------
local function RecordRepair(copper, isGuild)
    if copper <= 0 then return end
    local realm, name  = GetCharInfo()
    local charKey      = GetCharKey(realm, name)
    local _, classFile = UnitClass("player")
    local armorType    = DetectArmorType()
    if not AccountRepairedDB[charKey] then
        AccountRepairedDB[charKey] = { class=classFile or "UNKNOWN", armorType=armorType, repairs={} }
    end
    local cd = AccountRepairedDB[charKey]
    cd.class = classFile or cd.class or "UNKNOWN"
    if armorType ~= "Unknown" then cd.armorType = armorType end
    cd.armorType = cd.armorType or "Unknown"

    local entry = { t=time(), g=copper }
    if isGuild then entry.guild = true end
    table.insert(cd.repairs, entry)

    -- O(n) retention prune
    local cutoff = time() - DATA_RETENTION_SECONDS
    local repairs = cd.repairs; local firstOK = 1
    while firstOK <= #repairs and (repairs[firstOK].t or 0) < cutoff do firstOK = firstOK+1 end
    if firstOK > 1 then
        local keep = #repairs - firstOK + 1
        table.move(repairs, firstOK, #repairs, 1)
        for i = keep+1, #repairs do repairs[i] = nil end
    end

    if AR.popupFrame and AR.popupFrame:IsShown() then AR.popupFrame:UpdateDisplay() end
end

--------------------------------------------------
-- Merchant snapshot helper
--------------------------------------------------
local function SnapshotRepairState()
    snappedRepairCost   = GetRepairAllCost() or 0
    repairWasGuildAvail = (CanGuildBankRepair and CanGuildBankRepair()) and true or false
end

--------------------------------------------------
-- Events
--------------------------------------------------
AR.mainFrame:RegisterEvent("PLAYER_LOGIN")
AR.mainFrame:RegisterEvent("MERCHANT_SHOW")
AR.mainFrame:RegisterEvent("MERCHANT_CLOSED")
AR.mainFrame:RegisterEvent("PLAYER_MONEY")
AR.mainFrame:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
AR.mainFrame:RegisterEvent("ITEM_DATA_LOAD_RESULT")

AR.mainFrame:SetScript("OnEvent", function(self, event, ...)
    if event == "PLAYER_LOGIN" then
        C_Timer.After(2, RefreshCharArmorType)
        C_Timer.After(3, function()
            local stats = GetCurrentCharAllPeriods()
            print(string.format("%s  %s|cffFFD700%s|r  %s|cffFFD700%s|r  |cff888888/arepaired|r",
                L["FORMAT_NAME"], L["LOGIN_TODAY"], FormatGoldShort(stats.day),
                L["LOGIN_WEEK"],  FormatGoldShort(stats.week)))
        end)
        -- Attempt AP button injection after addons have all loaded
        C_Timer.After(1, AR.TryInjectAccountPlayedButton)

    elseif event == "ITEM_DATA_LOAD_RESULT" then
        if pendingArmorDetect then pendingArmorDetect = false; RefreshCharArmorType() end

    elseif event == "MERCHANT_SHOW" then
        inMerchant=true; lastMoney=GetMoney(); repairPending=false; SnapshotRepairState()

    elseif event == "MERCHANT_CLOSED" then
        inMerchant=false; repairPending=false; snappedRepairCost=0; repairWasGuildAvail=false

    elseif event == "PLAYER_EQUIPMENT_CHANGED" then
        if inMerchant then SnapshotRepairState() end

    elseif event == "PLAYER_MONEY" then
        if inMerchant and repairPending then
            local cur = GetMoney(); local delta = lastMoney - cur
            local personalCost, guildCost = delta, 0
            if snappedRepairCost > 0 then
                if delta <= 0 then
                    personalCost = 0; guildCost = repairWasGuildAvail and snappedRepairCost or 0
                elseif delta > snappedRepairCost * REPAIR_DELTA_TOLERANCE then
                    personalCost = snappedRepairCost
                elseif repairWasGuildAvail and delta < snappedRepairCost then
                    guildCost = snappedRepairCost - delta
                end
            end
            if personalCost > 0 then RecordRepair(personalCost, false) end
            if guildCost    > 0 then RecordRepair(guildCost,    true)  end
            repairPending=false; lastMoney=cur; SnapshotRepairState()
        elseif inMerchant then
            lastMoney = GetMoney()
            if not repairPending then snappedRepairCost = GetRepairAllCost() or 0 end
        end
    end
end)

hooksecurefunc("RepairAllItems", function()
    if inMerchant then
        repairPending       = true
        repairWasGuildAvail = (CanGuildBankRepair and CanGuildBankRepair()) and true or false
        snappedRepairCost   = GetRepairAllCost() or 0
    end
end)

--------------------------------------------------
-- Delete character
--------------------------------------------------
StaticPopupDialogs["ACCOUNTREPAIRED_CONFIRM_DELETE"] = {
    text          = "",
    button1       = DELETE,
    button2       = CANCEL,
    OnAccept      = function(self, data)
        if not (data and data.foundKey) then return end
        AccountRepairedDB[data.foundKey] = nil
        print("|cff00ff00"..string.format(L["CMD_DELETE_SUCCESS"], data.foundKey).."|r")
        if AR.popupFrame and AR.popupFrame:IsShown() then AR.popupFrame:UpdateDisplay() end
    end,
    timeout=0, whileDead=true, hideOnEscape=true, preferredIndex=3,
}

local function ConfirmDeleteKey(foundKey)
    StaticPopupDialogs["ACCOUNTREPAIRED_CONFIRM_DELETE"].text = string.format(L["CMD_DELETE_CONFIRM"], foundKey)
    StaticPopup_Show("ACCOUNTREPAIRED_CONFIRM_DELETE", nil, nil, { foundKey=foundKey })
end

local function DeleteCharacter(input)
    input = (input or ""):match("^%s*(.-)%s*$")
    local charName, realmName = input:match("^([^%-]+)%-(.+)$")
    if not charName then print("|cffff9900"..L["CMD_DELETE_USAGE"].."|r"); return end
    local target = (realmName.."-"..charName):lower()
    local found
    for k in pairs(AccountRepairedDB) do if k:lower() == target then found=k; break end end
    if found then ConfirmDeleteKey(found)
    else print("|cffff0000"..string.format(L["CMD_DELETE_NOT_FOUND"], input).."|r") end
end

SLASH_ACCOUNTREPAIREDDELETE1 = "/ardelete"
SlashCmdList.ACCOUNTREPAIREDDELETE = DeleteCharacter

--------------------------------------------------
-- Channel picker (lazy, created once)
--------------------------------------------------
local function GetOrCreateChannelPicker()
    if AR.channelPicker then return AR.channelPicker end

    local BTN_H=22; local PAD=6; local HEADER_H=24; local PICKER_W=150
    local totalH = HEADER_H + PAD + (#CHAT_CHANNELS + 1) * BTN_H + PAD * 2

    local p = CreateFrame("Frame", "AccountRepairedChannelPicker", UIParent, "BackdropTemplate")
    p:SetSize(PICKER_W, totalH)
    p:SetFrameStrata("TOOLTIP"); p:SetFrameLevel(200); p:SetClampedToScreen(true)
    p:SetBackdrop({ bgFile="Interface\\ChatFrame\\ChatFrameBackground", edgeFile="Interface\\DialogFrame\\UI-DialogBox-Border",
        tile=true, tileSize=32, edgeSize=24, insets={left=8,right=8,top=8,bottom=8} })
    p:SetBackdropColor(0.05, 0.05, 0.05, 0.96)

    local title = p:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    title:SetPoint("TOPLEFT", p, "TOPLEFT", 10, -8); title:SetPoint("TOPRIGHT", p, "TOPRIGHT", -10, -8)
    title:SetJustifyH("CENTER"); title:SetText("Send to\226\128\166"); title:SetTextColor(0.75, 0.75, 0.75)

    local function AddDivider(yOff)
        local sep = p:CreateTexture(nil, "ARTWORK"); sep:SetHeight(1)
        sep:SetPoint("TOPLEFT", p, "TOPLEFT", 10, yOff); sep:SetPoint("TOPRIGHT", p, "TOPRIGHT", -10, yOff)
        sep:SetColorTexture(0.4, 0.4, 0.4, 0.6)
    end
    AddDivider(-(HEADER_H-2))

    local function AddPickerButton(yOff, label, r, g, b, onClick)
        local btn = CreateFrame("Button", nil, p)
        btn:SetHeight(BTN_H)
        btn:SetPoint("TOPLEFT", p, "TOPLEFT", 10, yOff); btn:SetPoint("TOPRIGHT", p, "TOPRIGHT", -10, yOff)
        local hl = btn:CreateTexture(nil, "BACKGROUND"); hl:SetAllPoints(); hl:SetColorTexture(r, g, b, 0)
        local lbl = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"); lbl:SetAllPoints()
        lbl:SetJustifyH("CENTER"); lbl:SetText(label); lbl:SetTextColor(r, g, b)
        btn:SetScript("OnEnter", function() hl:SetColorTexture(r, g, b, 0.18) end)
        btn:SetScript("OnLeave", function() hl:SetColorTexture(r, g, b, 0)    end)
        btn:SetScript("OnClick", onClick)
        return btn
    end

    for i, chan in ipairs(CHAT_CHANNELS) do
        local yOff = -(HEADER_H + PAD + (i-1) * BTN_H)
        if chan.key == "NONE" then AddDivider(yOff+1) end
        local cr, cg, cb = chan.color[1], chan.color[2], chan.color[3]
        AddPickerButton(yOff, chan.label, cr, cg, cb, function()
            PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
            if p.pendingArmorType then SendRepairBreakdown(p.pendingArmorType, chan.key) end
            p:Hide()
        end)
    end

    local cancelY = -(HEADER_H + PAD + #CHAT_CHANNELS * BTN_H + PAD)
    AddDivider(cancelY + 1)
    AddPickerButton(cancelY, "|cffff6060"..CANCEL.."|r", 0.8, 0.2, 0.2, function()
        PlaySound(SOUNDKIT.IG_MAINMENU_CLOSE); p:Hide()
    end)

    p:EnableKeyboard(true)
    p:SetScript("OnKeyDown", function(self, key) if key == "ESCAPE" then self:Hide() end end)
    p:Hide()
    AR.channelPicker = p
    table.insert(UISpecialFrames, "AccountRepairedChannelPicker")
    return p
end

--------------------------------------------------
-- Bar row (one per armor type)
--------------------------------------------------
local function CreateBarRow(parent, width, height)
    local row = CreateFrame("Button", nil, parent)
    row:SetSize(width, height); row:EnableMouse(true); row:RegisterForClicks("LeftButtonUp", "RightButtonUp")

    row.highlight = row:CreateTexture(nil, "BACKGROUND"); row.highlight:SetAllPoints()
    row.highlight:SetColorTexture(1, 1, 1, 0.1); row.highlight:Hide()

    row.labelText = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    row.labelText:SetPoint("LEFT", 0, 0); row.labelText:SetWidth(80); row.labelText:SetJustifyH("LEFT")

    row.bar = CreateFrame("StatusBar", nil, row)
    row.bar:SetPoint("LEFT", row.labelText, "RIGHT", 6, 0)
    row.bar:SetPoint("RIGHT", row, "RIGHT", -160, 0)
    row.bar:SetHeight(height-6); row.bar:SetMinMaxValues(0,1); row.bar:SetValue(0)
    row.bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
    row.bar.bg = row.bar:CreateTexture(nil, "BACKGROUND"); row.bar.bg:SetAllPoints(); row.bar.bg:SetColorTexture(0,0,0,0.4)

    row.pctText = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    row.pctText:SetPoint("LEFT", row.bar, "RIGHT", 8, 0); row.pctText:SetWidth(52); row.pctText:SetJustifyH("RIGHT")

    row.goldText = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    row.goldText:SetPoint("LEFT", row.pctText, "RIGHT", 6, 0); row.goldText:SetWidth(102); row.goldText:SetJustifyH("LEFT")

    row:SetScript("OnEnter", function(self)
        self.highlight:Show()
        if not self.armorType then return end
        local chars = GetCharactersByArmorType(self.armorType, AR.currentPeriod)
        if #chars == 0 then return end
        local col = ARMOR_COLORS[self.armorType] or ARMOR_COLORS.Unknown
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(L["ARMOR_"..self.armorType] or self.armorType, col.r, col.g, col.b)
        GameTooltip:AddLine(" ")
        for _, ch in ipairs(chars) do
            local cc = RAID_CLASS_COLORS[ch.class] or {r=1,g=1,b=1}
            GameTooltip:AddDoubleLine(ch.name, FormatGoldFull(ch.gold), cc.r, cc.g, cc.b, 1, 1, 1)
        end
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine(L["CLICK_TO_SHARE"]   or "Click to share in chat",     0.5, 0.5, 0.5)
        GameTooltip:AddLine(L["RCLICK_CHAR_LIST"] or "Right-click for characters", 0.5, 0.5, 0.5)
        GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function(self) self.highlight:Hide(); GameTooltip:Hide() end)
    row:SetScript("OnClick", function(self, button)
        if not self.armorType then return end
        GameTooltip:Hide(); PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
        if button == "RightButton" then
            AR.ShowCharPanel(self.armorType, false, self)
        else
            local picker = GetOrCreateChannelPicker()
            picker.pendingArmorType = self.armorType
            picker:ClearAllPoints(); picker:SetPoint("TOPLEFT", self, "BOTTOMLEFT", 0, -4)
            if picker:GetBottom() and picker:GetBottom() < 0 then
                picker:ClearAllPoints(); picker:SetPoint("BOTTOMLEFT", self, "TOPLEFT", 0, 4)
            end
            picker:Show()
        end
    end)
    return row
end

--------------------------------------------------
-- Character panel (right-click drill-down)
--------------------------------------------------
local function CreateCharPanel()
    if AR.charPanel then return AR.charPanel end
    local p = CreateFrame("Frame", "AccountRepairedCharPanel", UIParent, "BackdropTemplate")
    p:SetWidth(CPANEL_W); p:SetHeight(CPANEL_HEADER_H + CPANEL_PAD)
    p:SetFrameStrata("DIALOG"); p:SetFrameLevel(110); p:SetClampedToScreen(true)
    p:SetBackdrop({ bgFile="Interface\\ChatFrame\\ChatFrameBackground", edgeFile="Interface\\DialogFrame\\UI-DialogBox-Border",
        tile=true, tileSize=32, edgeSize=24, insets={left=8,right=8,top=8,bottom=8} })
    p:SetBackdropColor(0.05, 0.05, 0.05, 0.92)

    p.titleText = p:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    p.titleText:SetPoint("TOPLEFT", p, "TOPLEFT", 12, -10); p.titleText:SetPoint("TOPRIGHT", p, "TOPRIGHT", -26, -10)
    p.titleText:SetJustifyH("LEFT")

    local closeBtn = CreateFrame("Button", nil, p, "UIPanelCloseButton")
    closeBtn:SetSize(20,20); closeBtn:SetPoint("TOPRIGHT", p, "TOPRIGHT", -2, -2)
    closeBtn:SetScript("OnClick", function() p:Hide(); AR.charPanelArmor = nil end)

    local div = p:CreateTexture(nil, "ARTWORK"); div:SetHeight(1)
    div:SetPoint("TOPLEFT", p, "TOPLEFT", 10, -(CPANEL_HEADER_H-2))
    div:SetPoint("TOPRIGHT", p, "TOPRIGHT", -10, -(CPANEL_HEADER_H-2))
    div:SetColorTexture(0.4, 0.4, 0.4, 0.8)

    p.charRows = {}
    for i = 1, 20 do
        local yOff = -(CPANEL_HEADER_H + CPANEL_PAD + (i-1) * CPANEL_ROW_H)
        local row  = CreateFrame("Frame", nil, p)
        row:SetHeight(CPANEL_ROW_H)
        row:SetPoint("TOPLEFT",  p, "TOPLEFT",  10, yOff)
        row:SetPoint("TOPRIGHT", p, "TOPRIGHT", -10, yOff)

        row.bg = row:CreateTexture(nil, "BACKGROUND"); row.bg:SetAllPoints(); row.bg:SetColorTexture(1,1,1,0)

        row.nameText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        row.nameText:SetPoint("LEFT", row, "LEFT", 0, 0); row.nameText:SetPoint("RIGHT", row, "RIGHT", -120, 0)
        row.nameText:SetJustifyH("LEFT"); row.nameText:SetWordWrap(false)

        row.goldText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        row.goldText:SetPoint("RIGHT", row, "RIGHT", -52, 0); row.goldText:SetWidth(80)
        row.goldText:SetJustifyH("RIGHT"); row.goldText:SetTextColor(0.85, 0.85, 0.85)

        local trashBtn = CreateFrame("Button", nil, row)
        trashBtn:SetSize(44,18); trashBtn:SetPoint("RIGHT", row, "RIGHT", 0, 0)
        local trashLbl = trashBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"); trashLbl:SetAllPoints()
        trashLbl:SetText("|cffff4040"..DELETE.."|r"); trashLbl:SetJustifyH("CENTER")
        trashBtn:SetWidth(trashLbl:GetStringWidth()+8)
        trashBtn:SetScript("OnEnter", function()
            row.bg:SetColorTexture(1,0.25,0.25,0.15)
            GameTooltip:SetOwner(trashBtn, "ANCHOR_RIGHT"); GameTooltip:SetText(L["CHAR_PANEL_REMOVE_TIP"],1,0.35,0.35); GameTooltip:Show()
        end)
        trashBtn:SetScript("OnLeave", function() row.bg:SetColorTexture(1,1,1,0); GameTooltip:Hide() end)
        trashBtn:SetScript("OnClick", function() if row.charKey then ConfirmDeleteKey(row.charKey) end end)
        row.trashBtn = trashBtn
        row:Hide()
        p.charRows[i] = row
    end

    p:Hide(); AR.charPanel = p
    table.insert(UISpecialFrames, "AccountRepairedCharPanel")
    return p
end

function AR.ShowCharPanel(armorType, forceShow, anchorRow)
    local p = CreateCharPanel()
    if not forceShow and AR.charPanelArmor == armorType and p:IsShown() then
        p:Hide(); AR.charPanelArmor = nil; return
    end
    local chars = GetCharactersByArmorType(armorType, AR.currentPeriod)
    if #chars == 0 then p:Hide(); AR.charPanelArmor = nil; return end
    AR.charPanelArmor = armorType

    if anchorRow then
        p:ClearAllPoints(); p:SetPoint("TOPLEFT", anchorRow, "TOPRIGHT", 6, 0)
    elseif not p:IsShown() then
        p:ClearAllPoints()
        p:SetPoint("TOPLEFT", AR.popupFrame and AR.popupFrame:IsShown() and AR.popupFrame or UIParent,
            AR.popupFrame and AR.popupFrame:IsShown() and "TOPRIGHT" or "CENTER", AR.popupFrame and 4 or 0, 0)
    end

    local col = ARMOR_COLORS[armorType] or ARMOR_COLORS.Unknown
    p.titleText:SetText(L["ARMOR_"..armorType] or armorType); p.titleText:SetTextColor(col.r, col.g, col.b)

    for i, row in ipairs(p.charRows) do
        local ch = chars[i]
        if ch then
            local cc = RAID_CLASS_COLORS[ch.class] or {r=1,g=1,b=1}
            row.nameText:SetText(ch.name); row.nameText:SetTextColor(cc.r, cc.g, cc.b)
            row.goldText:SetText(FormatGoldShort(ch.gold)); row.charKey = ch.key; row:Show()
        else
            row.charKey = nil; row:Hide()
        end
    end
    p:SetHeight(CPANEL_HEADER_H + CPANEL_PAD + #chars * CPANEL_ROW_H + CPANEL_PAD); p:Show()
end

--------------------------------------------------
-- Scroll bar helper
--------------------------------------------------
local function UpdateScrollBar(frame)
    local sf = frame.scrollFrame
    local sb = sf and (sf.ScrollBar or sf.scrollBar)
    if not sb then return end
    if sf:GetVerticalScrollRange() > 0 then sb:Show() else sb:Hide(); sf:SetVerticalScroll(0) end
end

--------------------------------------------------
-- Period tab bar
--------------------------------------------------
local function CreatePeriodTabs(parent, onSelect)
    local tabs = {}; local tabW=72; local tabH=22; local pad=4
    local container = CreateFrame("Frame", nil, parent)
    container:SetSize(#PERIOD_ORDER*(tabW+pad)-pad, tabH)

    for i, period in ipairs(PERIOD_ORDER) do
        local tab = CreateFrame("Button", nil, container, "BackdropTemplate")
        tab:SetSize(tabW, tabH); tab:SetPoint("LEFT", container, "LEFT", (i-1)*(tabW+pad), 0)
        tab:SetBackdrop({ bgFile="Interface\\ChatFrame\\ChatFrameBackground", edgeFile="Interface\\Tooltips\\UI-Tooltip-Border",
            tile=true, tileSize=16, edgeSize=12, insets={left=3,right=3,top=3,bottom=3} })
        tab.label = tab:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"); tab.label:SetAllPoints()
        tab.label:SetJustifyH("CENTER"); tab.label:SetText(GetPeriodLabel(period)); tab.period = period

        function tab:UpdateState()
            if self.period == AR.currentPeriod then
                self:SetBackdropColor(0.25,0.75,0.25,0.4); self.label:SetTextColor(0.2,1.0,0.2)
            else
                self:SetBackdropColor(0.1,0.1,0.1,0.7); self.label:SetTextColor(0.8,0.8,0.8)
            end
        end
        tab:SetScript("OnClick", function(self)
            AR.currentPeriod = self.period; DB.period = self.period
            PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON); onSelect(self.period)
            for _, t in ipairs(tabs) do t:UpdateState() end
        end)
        tab:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_TOP"); GameTooltip:AddLine(GetPeriodLabel(self.period),1,1,1); GameTooltip:Show()
        end)
        tab:SetScript("OnLeave", function() GameTooltip:Hide() end)
        tab:UpdateState(); tabs[i] = tab
    end
    return container, tabs
end

--------------------------------------------------
-- Main popup window
--------------------------------------------------
local function CreatePopup()
    if AR.popupFrame then return AR.popupFrame end

    local layoutDB = GetLayoutDB()
    local f = CreateFrame("Frame", "AccountRepairedPopup", UIParent, "BackdropTemplate")
    f:SetSize(layoutDB.width or DB.width, layoutDB.height or DB.height)
    if layoutDB.point then
        f:SetPoint(layoutDB.point, UIParent, layoutDB.point, layoutDB.x or 0, layoutDB.y or 0)
    else
        f:SetPoint("CENTER")
    end
    f:SetFrameStrata("DIALOG"); f:SetFrameLevel(100); f:SetClampedToScreen(true)
    f:SetMovable(true); f:EnableMouse(true); f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local pt,_,_,x,y = self:GetPoint(); DB.point=pt; DB.x=x; DB.y=y
    end)
    f:SetResizable(true)
    if f.SetResizeBounds then f:SetResizeBounds(MIN_W,MIN_H,MAX_W,MAX_H)
    elseif f.SetMinResize then f:SetMinResize(MIN_W,MIN_H); f:SetMaxResize(MAX_W,MAX_H) end
    f:SetBackdrop({ bgFile="Interface\\ChatFrame\\ChatFrameBackground", edgeFile="Interface\\DialogFrame\\UI-DialogBox-Border",
        tile=true, tileSize=32, edgeSize=32, insets={left=11,right=12,top=12,bottom=11} })
    f:SetBackdropColor(0,0,0,0.55)

    -- Resize grip
    local br = CreateFrame("Button", nil, f); br:SetSize(16,16); br:SetPoint("BOTTOMRIGHT",-6,6)
    br:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    br:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    br:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    br:SetScript("OnMouseDown", function(self) self:GetParent():StartSizing("BOTTOMRIGHT") end)
    br:SetScript("OnMouseUp",   function(self) self:GetParent():StopMovingOrSizing() end)
    f.resizeGrip = br

    -- Title
    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    f.title:SetPoint("TOP", f, "TOP", 0, -12); f.title:SetText(L["WINDOW_TITLE"])

    -- Close button
    local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT",-10,-10)
    closeBtn:SetScript("OnClick", function() PlaySound(SOUNDKIT.IG_MAINMENU_CLOSE); f:Hide() end)

    -- Collapse button [-]/[+]
    local colBtn = CreateFrame("Button", nil, f, "BackdropTemplate"); colBtn:SetSize(20,20)
    colBtn:SetPoint("RIGHT", closeBtn, "LEFT", -4, 0)
    colBtn:SetBackdrop({ bgFile="Interface\\ChatFrame\\ChatFrameBackground", edgeFile="Interface\\Tooltips\\UI-Tooltip-Border",
        tile=true, tileSize=16, edgeSize=10, insets={left=3,right=3,top=3,bottom=3} })
    colBtn:SetBackdropColor(0.10,0.10,0.10,0.85); colBtn:SetBackdropBorderColor(0.55,0.55,0.55,0.85)
    colBtn.label = colBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"); colBtn.label:SetAllPoints()
    colBtn.label:SetJustifyH("CENTER"); colBtn.label:SetJustifyV("MIDDLE")
    colBtn.label:SetText(AR.collapsed and "+" or "-")
    colBtn:SetScript("OnEnter", function(self)
        self:SetBackdropColor(0.20,0.20,0.20,0.95)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:AddLine(AR.collapsed and L["EXPAND_WINDOW"] or L["COLLAPSE_WINDOW"], 1,1,1); GameTooltip:Show()
    end)
    colBtn:SetScript("OnLeave", function(self) self:SetBackdropColor(0.10,0.10,0.10,0.85); GameTooltip:Hide() end)
    colBtn:SetScript("OnClick", function() PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON); f:SetCollapsed(not AR.collapsed) end)
    f.collapseBtn = colBtn

    f:SetScript("OnHide", function() if AR.charPanel then AR.charPanel:Hide() end; AR.charPanelArmor=nil end)
    table.insert(UISpecialFrames, "AccountRepairedPopup")

    -- Guild checkbox
    local guildCB = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
    guildCB:SetSize(24,24); guildCB:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -10)
    guildCB:SetChecked(DB.includeGuild ~= false)
    f.guildCBLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.guildCBLabel:SetPoint("LEFT", guildCB, "RIGHT", 2, 0); f.guildCBLabel:SetText(L["INCLUDE_GUILD_REPAIRS"])
    f.guildCBLabel:SetTextColor(0.8,0.8,0.8)
    guildCB:SetScript("OnClick", function(self)
        local checked = self:GetChecked(); DB.includeGuild = checked and true or false
        PlaySound(checked and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_OFF)
        f:UpdateDisplay()
    end)
    guildCB:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT"); GameTooltip:AddLine(L["INCLUDE_GUILD_REPAIRS"],1,1,1)
        GameTooltip:AddLine(L["GUILD_REPAIRS_TIP"],0.8,0.8,0.8,true); GameTooltip:Show()
    end)
    guildCB:SetScript("OnLeave", function() GameTooltip:Hide() end)
    f.guildCB = guildCB

    -- Period tabs
    local tabContainer, tabRefs = CreatePeriodTabs(f, function() f:UpdateDisplay() end)
    tabContainer:SetPoint("TOP", f.title, "BOTTOM", 0, -8)
    f.tabs = tabContainer; f.tabRefs = tabRefs

    -- Character strip
    local strip = CreateFrame("Frame", nil, f, "BackdropTemplate")
    strip:SetPoint("TOPLEFT",  f, "TOPLEFT",  14, -76)
    strip:SetPoint("TOPRIGHT", f, "TOPRIGHT", -14, -76)
    strip:SetHeight(36)
    strip:SetBackdrop({ bgFile="Interface\\ChatFrame\\ChatFrameBackground", edgeFile="Interface\\Tooltips\\UI-Tooltip-Border",
        tile=true, tileSize=16, edgeSize=10, insets={left=3,right=3,top=3,bottom=3} })
    strip:SetBackdropColor(0.08,0.08,0.08,0.80)
    strip.nameText = strip:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    strip.nameText:SetPoint("LEFT", strip, "LEFT", 10, 0); strip.nameText:SetWidth(160); strip.nameText:SetJustifyH("LEFT")
    strip.statsText = strip:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    strip.statsText:SetPoint("LEFT", strip.nameText, "RIGHT", 8, 0); strip.statsText:SetPoint("RIGHT", strip, "RIGHT", -8, 0)
    strip.statsText:SetJustifyH("LEFT"); strip.statsText:SetTextColor(0.85,0.85,0.85)
    f.charStrip = strip

    -- Scroll frame
    local sf = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
    sf:SetPoint("TOPLEFT",  f, "TOPLEFT",  14, -120)
    sf:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -30, 50)
    sf:EnableMouseWheel(true)
    sf:SetScript("OnMouseWheel", function(self, delta)
        local new = math.max(0, math.min(self:GetVerticalScroll() - delta*20, self:GetVerticalScrollRange()))
        self:SetVerticalScroll(new)
    end)
    local content = CreateFrame("Frame", nil, sf); content:SetSize(1,1); sf:SetScrollChild(content)
    f.scrollFrame = sf; f.content = content

    -- Account total
    f.totalRow = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    f.totalRow:SetPoint("BOTTOMLEFT", 15, 18); f.totalRow:SetTextColor(1,1,1)

    -- AccountPlayed companion button (inside AR window — closes AR, opens AP)
    local apBtn = CreateFrame("Button", nil, f, "BackdropTemplate"); apBtn:SetSize(120,20)
    apBtn:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -15, 16)
    apBtn:SetBackdrop({ bgFile="Interface\\ChatFrame\\ChatFrameBackground", edgeFile="Interface\\Tooltips\\UI-Tooltip-Border",
        tile=true, tileSize=16, edgeSize=10, insets={left=3,right=3,top=3,bottom=3} })
    apBtn:SetBackdropColor(0.05,0.05,0.05,0.85); apBtn:SetBackdropBorderColor(0.4,0.7,1.0,0.9)
    local apLbl = apBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"); apLbl:SetAllPoints()
    apLbl:SetJustifyH("CENTER"); apLbl:SetText("|cff6699FFAccount Played|r")
    apBtn:SetScript("OnEnter", function(self)
        self:SetBackdropBorderColor(0.6,0.85,1.0,1.0); self:SetBackdropColor(0.02,0.08,0.18,0.95)
        GameTooltip:SetOwner(self,"ANCHOR_TOP"); GameTooltip:AddLine("Account Played",0.6,0.85,1.0)
        GameTooltip:AddLine("Switch to account played statistics",0.8,0.8,0.8); GameTooltip:Show()
    end)
    apBtn:SetScript("OnLeave", function(self)
        self:SetBackdropBorderColor(0.4,0.7,1.0,0.9); self:SetBackdropColor(0.05,0.05,0.05,0.85); GameTooltip:Hide()
    end)
    apBtn:SetScript("OnClick", function()
        PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON); f:Hide()
        if AccountPlayed and AccountPlayed.ToggleClassWindow then AccountPlayed.ToggleClassWindow() end
    end)
    apBtn:Hide(); f.apBtn = apBtn

    -- Bar rows
    for i = 1, #ARMOR_TYPE_NAMES do
        local row = CreateBarRow(content, f:GetWidth()-60, 26)
        row:SetPoint("TOPLEFT", 0, -(i-1)*26); row:Hide(); AR.popupRows[i] = row
    end

    -- Resize handler
    f:SetScript("OnSizeChanged", function(self, w, h)
        if AR.collapsed then return end
        w = math.max(MIN_W, math.min(w, MAX_W)); h = math.max(MIN_H, math.min(h, MAX_H))
        DB.width = self:GetWidth(); DB.height = self:GetHeight()
        local cw = self.scrollFrame:GetWidth(); self.content:SetWidth(cw)
        for _, row in ipairs(AR.popupRows) do row:SetWidth(cw) end
        UpdateScrollBar(self)
    end)

    -- Collapse/expand
    local collapsible = {}

    f.SetCollapsed = function(self, collapsed)
        AR.collapsed = collapsed; DB.collapsed = collapsed

        if #collapsible == 0 then
            collapsible = { self.title, self.guildCB, self.guildCBLabel, self.tabs, self.scrollFrame, self.resizeGrip }
        end

        for _, w in ipairs(collapsible) do
            if collapsed then w:Hide() else w:Show() end
        end

        self.charStrip:ClearAllPoints()
        if collapsed then
            self.charStrip:SetPoint("TOPLEFT",  self, "TOPLEFT",  14, -10)
            self.charStrip:SetPoint("TOPRIGHT", self, "TOPRIGHT", -14, -10)
            self:SetResizable(false); self:SetHeight(COLLAPSED_H)
        else
            self.charStrip:SetPoint("TOPLEFT",  self, "TOPLEFT",  14, -76)
            self.charStrip:SetPoint("TOPRIGHT", self, "TOPRIGHT", -14, -76)
            self:SetResizable(true)
            if self.SetResizeBounds then self:SetResizeBounds(MIN_W,MIN_H,MAX_W,MAX_H)
            elseif self.SetMinResize then self:SetMinResize(MIN_W,MIN_H); self:SetMaxResize(MAX_W,MAX_H) end
            self:SetHeight(DB.height or 340)
        end
        self.collapseBtn.label:SetText(collapsed and "+" or "-")
    end

    -- UpdateDisplay
    f.UpdateDisplay = function(self)
        -- AccountPlayed button visibility
        if AccountPlayed and AccountPlayed.ToggleClassWindow then self.apBtn:Show() else self.apBtn:Hide() end

        -- Tabs
        for _, tab in ipairs(self.tabRefs) do tab:UpdateState() end

        -- Guild checkbox
        self.guildCB:SetChecked(DB.includeGuild ~= false)

        -- Character strip
        local realm, name  = GetCharInfo()
        local _, classFile = UnitClass("player")
        local cc           = (classFile and RAID_CLASS_COLORS[classFile]) or {r=1,g=1,b=1}
        local stats, cd    = GetCurrentCharAllPeriods()
        local armorSuffix  = cd and ("|cffAAAAAA (".. (L["ARMOR_"..(cd.armorType or "Unknown")] or "?") ..")|r") or ""

        self.charStrip.nameText:SetText(string.format("|cff%02x%02x%02x%s|r%s", cc.r*255, cc.g*255, cc.b*255, name, armorSuffix))

        local function PL(key)
            local lbl = GetPeriodLabel(key)
            return key == AR.currentPeriod and ("|cff33ff33"..lbl.."|r") or lbl
        end
        self.charStrip.statsText:SetText(string.format("%s: %s   %s: %s   %s: %s   %s: %s",
            PL("day"),FormatGoldShort(stats.day), PL("week"),FormatGoldShort(stats.week),
            PL("month"),FormatGoldShort(stats.month), PL("all"),FormatGoldShort(stats.all)))

        -- Bars (skipped when collapsed)
        local totals, acct = GetArmorTypeTotals(AR.currentPeriod)
        if not AR.collapsed then
            if acct == 0 then
                AR.popupRows[1].labelText:SetText(L["NO_DATA"]); AR.popupRows[1].bar:SetValue(0)
                AR.popupRows[1].pctText:SetText(""); AR.popupRows[1].goldText:SetText(""); AR.popupRows[1].armorType=nil
                AR.popupRows[1]:Show()
                for i=2,#AR.popupRows do AR.popupRows[i]:Hide() end
                self.content:SetHeight(26); self.totalRow:SetText(L["TOTAL"]..FormatGoldFull(0))
                UpdateScrollBar(self)
            else
                local sorted = {}
                for _, at in ipairs(ARMOR_TYPE_NAMES) do
                    if (totals[at] or 0) > 0 then table.insert(sorted, {armorType=at, gold=totals[at]}) end
                end
                for at, gold in pairs(totals) do
                    local seen = false
                    for _, s in ipairs(sorted) do if s.armorType==at then seen=true; break end end
                    if not seen then table.insert(sorted, {armorType=at, gold=gold}) end
                end
                table.sort(sorted, function(a,b) return a.gold > b.gold end)
                local top = sorted[1].gold

                for i, row in ipairs(AR.popupRows) do
                    local e = sorted[i]
                    if e then
                        local col = ARMOR_COLORS[e.armorType] or ARMOR_COLORS.Unknown
                        row.armorType = e.armorType
                        row.labelText:SetText(L["ARMOR_"..e.armorType] or e.armorType)
                        row.labelText:SetTextColor(col.r, col.g, col.b)
                        row.bar:SetValue(e.gold/top); row.bar:SetStatusBarColor(col.r, col.g, col.b)
                        row.pctText:SetText(string.format("%.1f%%", e.gold/acct*100))
                        row.goldText:SetText("- "..FormatGoldShort(e.gold)); row:Show()
                    else
                        row.armorType=nil; row:Hide()
                    end
                end
                self.content:SetHeight(#sorted*26); UpdateScrollBar(self)
                self.totalRow:SetText(L["TOTAL"]..FormatGoldFull(acct))
                if AR.charPanel and AR.charPanel:IsShown() and AR.charPanelArmor then
                    AR.ShowCharPanel(AR.charPanelArmor, true)
                end
            end
        else
            self.totalRow:SetText(L["TOTAL"]..FormatGoldFull(acct))
        end
    end

    f:Hide(); AR.popupFrame = f
    return f
end

local function UpdatePopup()
    local f  = CreatePopup()
    local pt = DB.point or "CENTER"
    f:ClearAllPoints()
    f:SetPoint(pt, UIParent, pt, DB.x or 0, DB.y or 0)
    if AR.collapsed then
        f:SetCollapsed(true)
    else
        local layoutDB = GetLayoutDB()
        f:SetSize(layoutDB.width or DB.width, layoutDB.height or DB.height)
        f:SetCollapsed(false)
    end
    f:UpdateDisplay(); f:Show()
end

--------------------------------------------------
-- Toggle
--------------------------------------------------
AR.ToggleWindow = function()
    if AR.popupFrame and AR.popupFrame:IsShown() then
        PlaySound(SOUNDKIT.IG_MAINMENU_CLOSE); AR.popupFrame:Hide()
    else
        PlaySound(SOUNDKIT.IG_MAINMENU_OPEN); UpdatePopup()
    end
end

--------------------------------------------------
-- Account Played → Account Repaired companion button
-- Injected into AccountPlayedPopup from our side only.
-- AccountPlayed's frame name is "AccountPlayedPopup"
-- (set via CreateFrame("Frame","AccountPlayedPopup",...))
-- and its toggle lives at AccountPlayed.ToggleClassWindow.
--------------------------------------------------
local _apHooked = false

AR.TryInjectAccountPlayedButton = function()
    -- Account Played not loaded — nothing to do
    if not (AccountPlayed and AccountPlayed.ToggleClassWindow) then return end
    -- Already set up
    if _apHooked then return end
    _apHooked = true

    local function InjectButton()
        -- The frame is named "AccountPlayedPopup" in AccountPlayed.lua
        local apf = _G["AccountPlayedPopup"]
        if not apf or apf._arRepairedBtn then return end  -- not yet created, or already injected

        local btn = CreateFrame("Button", nil, apf, "BackdropTemplate")
        btn:SetSize(120, 20)
        btn:SetPoint("CENTER", apf, "BOTTOM", -10, 26)
        btn:SetBackdrop({
            bgFile   = "Interface\\ChatFrame\\ChatFrameBackground",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile=true, tileSize=16, edgeSize=10,
            insets={left=3, right=3, top=3, bottom=3},
        })
        btn:SetBackdropColor(0.05, 0.05, 0.05, 0.85)
        btn:SetBackdropBorderColor(1.0, 0.55, 0.1, 0.9)  -- amber to differentiate from AP's own blue button

        local lbl = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        lbl:SetAllPoints(); lbl:SetJustifyH("CENTER")
        lbl:SetText("|cffFFAA33Account Repaired|r")

        btn:SetScript("OnEnter", function(self)
            self:SetBackdropBorderColor(1.0, 0.75, 0.3, 1.0)
            self:SetBackdropColor(0.12, 0.07, 0.01, 0.95)
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:AddLine("Account Repaired", 1.0, 0.67, 0.2)
            GameTooltip:AddLine("Switch to repair cost statistics", 0.8, 0.8, 0.8)
            GameTooltip:Show()
        end)
        btn:SetScript("OnLeave", function(self)
            self:SetBackdropBorderColor(1.0, 0.55, 0.1, 0.9)
            self:SetBackdropColor(0.05, 0.05, 0.05, 0.85)
            GameTooltip:Hide()
        end)
        btn:SetScript("OnClick", function()
            PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
            -- Close Account Played, open Account Repaired
            if AccountPlayed and AccountPlayed.ToggleClassWindow then
                AccountPlayed.ToggleClassWindow()
            end
            AR.ToggleWindow()
        end)

        apf._arRepairedBtn = btn  -- guard against double-injection
    end

    -- Hook ToggleClassWindow so we inject as soon as the frame is first created.
    -- AccountPlayedPopup is lazily created on first toggle, so it may not exist yet.
    hooksecurefunc(AccountPlayed, "ToggleClassWindow", function()
        -- Run after the original function so the frame definitely exists now
        C_Timer.After(0, InjectButton)
    end)

    -- If the AP window is already open right now (e.g. user had it open before
    -- Account Repaired finished loading), inject immediately.
    InjectButton()
end

--------------------------------------------------
-- Debug command
--------------------------------------------------
SLASH_ACCOUNTREPAIREDDEBUG1 = "/ardebug"
SlashCmdList.ACCOUNTREPAIREDDEBUG = function()
    print("|cffff0000"..L["DEBUG_HEADER"].."|r")
    for charKey, data in pairs(AccountRepairedDB) do
        if type(data) == "table" then
            local tot, guild = 0, 0
            for _, e in ipairs(data.repairs or {}) do
                if e.guild then guild=guild+(e.g or 0) else tot=tot+(e.g or 0) end
            end
            print(string.format(" |cffffff00- %s [%s/%s] : %s personal / %s guild (%d repairs)|r",
                charKey, data.class or "?", data.armorType or "?",
                FormatGoldFull(tot), FormatGoldFull(guild), #(data.repairs or {})))
        end
    end
end

--------------------------------------------------
-- Slash commands
--------------------------------------------------
SLASH_ACCOUNTREPAIRED1 = "/arepaired"
SlashCmdList.ACCOUNTREPAIRED = function(input)
    input = ((input or ""):match("^%s*(.-)%s*$")):lower()
    if input == "show" or input == "" then
        AR.ToggleWindow()
    else
        print(L["FORMAT_NAME"].."  /arepaired  |cff888888"..L["CMD_HELP_SHOW_DESC"].."|r")
        print("  |cffffff00/ardelete CharName-RealmName|r  |cff888888"..L["CMD_DELETE_USAGE_SHORT"].."|r")
        print("  |cffffff00/ardebug|r  |cff888888"..L["CMD_HELP_DEBUG_DESC"].."|r")
    end
end

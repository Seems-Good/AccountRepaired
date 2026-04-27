--------------------------------------------------
--
-- Account Repaired – Main Module  v@project-version@
-- 
--------------------------------------------------
local _, addonTable = ...
local L = addonTable.L

AccountRepaired = AccountRepaired or {}
local AR = AccountRepaired

--------------------------------------------------
-- SavedVariables  (must NOT be local)
--------------------------------------------------
AccountRepairedDB      = AccountRepairedDB or {}
AccountRepairedPopupDB = AccountRepairedPopupDB or {
    width        = 540,
    height       = 340,
    point        = "CENTER",
    x            = 0,
    y            = 0,
    period       = "all",
    includeGuild = true,
    collapsed    = false,
}
-- Back-fill defaults for existing saved databases
if AccountRepairedPopupDB.includeGuild == nil then
    AccountRepairedPopupDB.includeGuild = true
end
if AccountRepairedPopupDB.collapsed == nil then
    AccountRepairedPopupDB.collapsed = false
end

--------------------------------------------------
-- Layout DB helper
-- If AccountPlayed is installed we piggyback on its
-- popup layout table so both windows share position
-- and size seamlessly.  Falls back to our own DB
-- safely when AccountPlayed is absent.
-- NOTE: This block is intentionally unchanged from
--       0.3.3 to preserve AccountPlayed integration.
--------------------------------------------------
local function GetLayoutDB()
    if AccountPlayed and type(AccountPlayedPopupDB) == "table" then
        return AccountPlayedPopupDB
    end
    return AccountRepairedPopupDB
end

--------------------------------------------------
-- Constants
--------------------------------------------------

-- How long to keep repair entries (2 years in seconds)
local DATA_RETENTION_SECONDS = 365 * 2 * 86400

local PERIOD_SECONDS = {
    day   = 86400,
    week  = 604800,
    month = 2592000,   -- 30 days
    all   = 0,
}
local PERIOD_ORDER = { "day", "week", "month", "all" }

-- Armor type visual colours (mirrors RAID_CLASS_COLORS style)
local ARMOR_COLORS = {
    Cloth   = { r = 0.78, g = 0.78, b = 0.85 },
    Leather = { r = 0.85, g = 0.60, b = 0.20 },
    Mail    = { r = 0.35, g = 0.65, b = 0.95 },
    Plate   = { r = 0.75, g = 0.40, b = 1.00 },
    Unknown = { r = 0.65, g = 0.65, b = 0.65 },
}
local ARMOR_TYPE_NAMES = { "Cloth", "Leather", "Mail", "Plate", "Unknown" }

-- Inventory slots checked to detect armor type (Head, Shoulder, Chest, Legs, Feet)
local ARMOR_SLOTS = { 1, 3, 5, 7, 8 }
local ARMOR_TYPES_VALID = { Cloth = true, Leather = true, Mail = true, Plate = true }

-- FIX (audit): tolerance multiplier used when validating a money delta
-- against the pre-repair cost snapshot.  A delta > snapshot * this value
-- means something other than the repair also changed player money in the
-- same PLAYER_MONEY event (e.g. the player simultaneously bought an item).
-- 1.05 = allow up to 5% variance to cover floating-point/currency rounding.
local REPAIR_DELTA_TOLERANCE = 1.05

-- Height of the window when collapsed (char strip + footer only)
local COLLAPSED_H = 82

--------------------------------------------------
-- Panel layout constants
--------------------------------------------------
local CPANEL_W        = 240
local CPANEL_ROW_H    = 22
local CPANEL_HEADER_H = 28
local CPANEL_PAD      = 6

--------------------------------------------------
-- State
--------------------------------------------------
AR.mainFrame        = CreateFrame("Frame")
AR.popupFrame       = nil
AR.popupRows        = {}
AR.charPanel        = nil
AR.charPanelArmor   = nil   -- which armor type is currently pinned in the panel
AR.currentPeriod    = AccountRepairedPopupDB.period or "all"
AR.collapsed        = AccountRepairedPopupDB.collapsed or false

local inMerchant        = false
local lastMoney         = 0
local repairPending     = false
local snappedRepairCost = 0   -- GetRepairAllCost() cached before RepairAllItems fires

-- FIX (audit): track item IDs whose GetItemInfo() returned nil so we can
-- retry when ITEM_DATA_LOAD_RESULT fires.
local pendingArmorDetect = false

--------------------------------------------------
-- Helpers – Character identity
--------------------------------------------------

local function GetCharInfo()
    local name  = UnitName("player")
    local realm = (GetNormalizedRealmName and GetNormalizedRealmName()) or GetRealmName()
    return realm, name
end

local function GetCharKey(realm, name)
    return realm .. "-" .. name
end

-- "RealmName-CharName" → "CharName"  (handles hyphenated realm names)
local function KeyToName(key)
    return key:match("%-([^%-]+)$") or key
end

--------------------------------------------------
-- Helpers – Armor type detection
--
-- FIX (audit): DetectArmorType() now returns a second boolean indicating
-- whether every sampled slot had loaded item data.  Callers that care
-- about reliability can use this to schedule a retry.
--------------------------------------------------

local function DetectArmorType()
    local counts   = {}
    local allReady = true   -- becomes false if any GetItemInfo() returned nil

    for _, slotID in ipairs(ARMOR_SLOTS) do
        local itemID = GetInventoryItemID("player", slotID)
        if itemID then
            local _, _, _, _, _, _, subType = GetItemInfo(itemID)
            if subType then
                if ARMOR_TYPES_VALID[subType] then
                    counts[subType] = (counts[subType] or 0) + 1
                end
            else
                -- Item data not in client cache yet
                allReady = false
            end
        end
    end

    local best, bestCount = "Unknown", 0
    for subType, count in pairs(counts) do
        if count > bestCount then
            best, bestCount = subType, count
        end
    end
    return best, allReady
end

-- FIX (audit): Ensure a character's DB row exists (creating it if needed)
-- and update its armorType.  Used by both the login refresh and the
-- ITEM_DATA_LOAD_RESULT retry so the logic is not duplicated.
local function RefreshCharArmorType()
    local realm, name   = GetCharInfo()
    local charKey       = GetCharKey(realm, name)
    local _, classFile  = UnitClass("player")
    local armorType, allReady = DetectArmorType()

    -- Always ensure the row exists for the current character so the
    -- 2-second post-login refresh never silently skips a new character.
    if not AccountRepairedDB[charKey] then
        AccountRepairedDB[charKey] = {
            class     = classFile or "UNKNOWN",
            armorType = armorType,
            repairs   = {},
        }
    end

    local charData = AccountRepairedDB[charKey]
    charData.class = classFile or charData.class or "UNKNOWN"
    if armorType ~= "Unknown" then
        charData.armorType = armorType
    end
    charData.armorType = charData.armorType or "Unknown"

    -- If some item data was still missing, ask for a retry via
    -- ITEM_DATA_LOAD_RESULT (registered below in the event handler).
    if not allReady then
        pendingArmorDetect = true
    end
end

--------------------------------------------------
-- Helpers – Gold formatting
--------------------------------------------------

local function FormatGoldFull(copper)
    copper = math.floor(tonumber(copper) or 0)
    if copper <= 0 then return "|cffAAAAAA0g|r" end
    local gold   = math.floor(copper / 10000)
    local silver = math.floor((copper % 10000) / 100)
    local cop    = copper % 100
    if gold > 0 then
        return string.format("|cffFFD700%d|rg |cffC0C0C0%d|rs |cffCD7F32%d|rc", gold, silver, cop)
    elseif silver > 0 then
        return string.format("|cffC0C0C0%d|rs |cffCD7F32%d|rc", silver, cop)
    else
        return string.format("|cffCD7F32%d|rc", cop)
    end
end

-- Compact: "1,234g" or "56s" or "12c"
local function FormatGoldShort(copper)
    copper = math.floor(tonumber(copper) or 0)
    if copper <= 0 then return "|cffAAAAAA0g|r" end
    local goldVal = copper / 10000
    if goldVal >= 1000 then
        return string.format("|cffFFD700%.1fk|r", goldVal / 1000)
    elseif goldVal >= 1 then
        return string.format("|cffFFD700%.1f|rg", goldVal)
    end
    local silverVal = copper / 100
    if silverVal >= 1 then
        return string.format("|cffC0C0C0%.1f|rs", silverVal)
    end
    return string.format("|cffCD7F32%d|rc", copper)
end

--------------------------------------------------
-- Helpers – Period filtering
--------------------------------------------------

local function GetPeriodStart(period)
    if period == "all" or not PERIOD_SECONDS[period] then return 0 end
    return time() - PERIOD_SECONDS[period]
end

local function GetPeriodLabel(period)
    local labels = {
        day   = L["PERIOD_DAY"],
        week  = L["PERIOD_WEEK"],
        month = L["PERIOD_MONTH"],
        all   = L["PERIOD_ALL"],
    }
    return labels[period] or period
end

--------------------------------------------------
-- Data aggregation
--------------------------------------------------

local function GetCharRepairsInPeriod(charData, periodStart)
    local total = 0
    if not charData or not charData.repairs then return 0 end
    local includeGuild = AccountRepairedPopupDB.includeGuild ~= false
    for _, entry in ipairs(charData.repairs) do
        if (entry.t or 0) >= periodStart then
            if not entry.guild or includeGuild then
                total = total + (entry.g or 0)
            end
        end
    end
    return total
end

local function GetArmorTypeTotals(period)
    local totals       = {}
    local accountTotal = 0
    local periodStart  = GetPeriodStart(period)

    for _, charData in pairs(AccountRepairedDB) do
        if type(charData) == "table" and charData.repairs then
            local armorType = charData.armorType or "Unknown"
            local amount    = GetCharRepairsInPeriod(charData, periodStart)
            if amount > 0 then
                totals[armorType]  = (totals[armorType] or 0) + amount
                accountTotal       = accountTotal + amount
            end
        end
    end
    return totals, accountTotal
end

local function GetCharactersByArmorType(armorType, period)
    local chars       = {}
    local periodStart = GetPeriodStart(period)

    for charKey, charData in pairs(AccountRepairedDB) do
        if type(charData) == "table" and (charData.armorType or "Unknown") == armorType then
            local amount = GetCharRepairsInPeriod(charData, periodStart)
            if amount > 0 then
                table.insert(chars, {
                    key       = charKey,
                    name      = KeyToName(charKey),
                    class     = charData.class or "UNKNOWN",
                    armorType = armorType,
                    gold      = amount,
                })
            end
        end
    end
    table.sort(chars, function(a, b) return a.gold > b.gold end)
    return chars
end

local function GetCurrentCharAllPeriods()
    local realm, name = GetCharInfo()
    local charData    = AccountRepairedDB[GetCharKey(realm, name)]
    local stats = { day = 0, week = 0, month = 0, all = 0 }
    local includeGuild = AccountRepairedPopupDB.includeGuild ~= false

    if charData and charData.repairs then
        local now = time()
        for _, entry in ipairs(charData.repairs) do
            local t = entry.t or 0
            local g = entry.g or 0
            if not entry.guild or includeGuild then
                stats.all   = stats.all + g
                if t >= now - 86400   then stats.day   = stats.day   + g end
                if t >= now - 604800  then stats.week  = stats.week  + g end
                if t >= now - 2592000 then stats.month = stats.month + g end
            end
        end
    end
    return stats, charData
end

--------------------------------------------------
-- Core: Record a repair event
--
-- FIX (audit): isGuild parameter is now meaningfully used.
--   Guild repairs are passed as isGuild=true by the detection logic in
--   the PLAYER_MONEY handler below.
--
-- FIX (audit): O(n^2) prune replaced with a single-pass cutoff scan
--   followed by one table.move call, which is O(n) total.
--------------------------------------------------

local function RecordRepair(copper, isGuild)
    if copper <= 0 then return end

    local realm, name = GetCharInfo()
    local charKey     = GetCharKey(realm, name)
    local _, classFile = UnitClass("player")
    local armorType   = DetectArmorType()   -- second return value not needed here

    if not AccountRepairedDB[charKey] then
        AccountRepairedDB[charKey] = {
            class     = classFile or "UNKNOWN",
            armorType = armorType,
            repairs   = {},
        }
    end

    local charData = AccountRepairedDB[charKey]
    charData.class = classFile or charData.class or "UNKNOWN"
    if armorType ~= "Unknown" then
        charData.armorType = armorType
    end
    charData.armorType = charData.armorType or "Unknown"

    local entry = { t = time(), g = copper }
    if isGuild then entry.guild = true end
    table.insert(charData.repairs, entry)

    -- FIX (audit): O(n) prune – find the first index still within retention
    -- window, then remove everything before it in a single table.move call.
    local cutoff   = time() - DATA_RETENTION_SECONDS
    local repairs  = charData.repairs
    local firstOK  = 1
    while firstOK <= #repairs and (repairs[firstOK].t or 0) < cutoff do
        firstOK = firstOK + 1
    end
    if firstOK > 1 then
        -- Shift valid entries to the front; shrink the table.
        local keepCount = #repairs - firstOK + 1
        table.move(repairs, firstOK, #repairs, 1)
        for i = keepCount + 1, #repairs do
            repairs[i] = nil
        end
    end

    -- Refresh popup if it is open
    if AR.popupFrame and AR.popupFrame:IsShown() then
        AR.popupFrame:UpdateDisplay()
    end
end

--------------------------------------------------
-- Guild repair detection helpers
--
-- FIX (audit): Guild repairs were never detected or recorded in 0.3.3.
-- Strategy:
--   1. On MERCHANT_SHOW, snapshot both player money AND the guild bank
--      repair availability flag + the full repair cost.
--   2. When RepairAllItems() is hooked, snapshot money again (pre-repair)
--      and note whether CanGuildBankRepair() is true.
--   3. In PLAYER_MONEY, compute the personal money delta.
--      - If the delta equals snappedRepairCost (within tolerance) →
--        purely personal repair; record as normal.
--      - If the delta is LESS than snappedRepairCost AND guild bank repair
--        was available → the guild covered the remainder; record both
--        parts with the correct flag.
--      - If delta is 0 → the guild covered everything; record the full
--        snapped cost as guild.
--   This correctly handles mixed personal+guild and guild-only repairs
--   without requiring any additional WoW API hooks.
--------------------------------------------------

-- Cached state set when RepairAllItems() fires
local repairWasGuildAvail   = false   -- CanGuildBankRepair() at repair time

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
-- FIX (audit): register for item data load so armor detection can retry
-- when GetItemInfo() returned nil during login or equipment scan.
AR.mainFrame:RegisterEvent("ITEM_DATA_LOAD_RESULT")

AR.mainFrame:SetScript("OnEvent", function(self, event, ...)
    if event == "PLAYER_LOGIN" then
        -- Re-detect armor type on login (items are loaded by now after a short delay).
        -- FIX (audit): RefreshCharArmorType() also creates the DB row when it
        -- doesn't exist yet, so brand-new characters are no longer skipped.
        C_Timer.After(2, function()
            RefreshCharArmorType()
        end)

    elseif event == "ITEM_DATA_LOAD_RESULT" then
        -- FIX (audit): if a previous DetectArmorType() call missed item data,
        -- retry now that new item info has arrived.
        if pendingArmorDetect then
            pendingArmorDetect = false
            RefreshCharArmorType()
        end

    elseif event == "MERCHANT_SHOW" then
        inMerchant        = true
        lastMoney         = GetMoney()
        repairPending     = false
        SnapshotRepairState()

    elseif event == "MERCHANT_CLOSED" then
        inMerchant          = false
        repairPending       = false
        snappedRepairCost   = 0
        repairWasGuildAvail = false

    elseif event == "PLAYER_EQUIPMENT_CHANGED" then
        -- Keep repair-cost snapshot fresh if gear changes while at a vendor
        if inMerchant then
            SnapshotRepairState()
        end

    elseif event == "PLAYER_MONEY" then
        if inMerchant and repairPending then
            local currentMoney = GetMoney()
            local delta        = lastMoney - currentMoney   -- positive = player paid

            -- FIX (audit): validate delta against the pre-repair snapshot.
            -- If delta wildly exceeds what a full self-repair should cost, the
            -- player also bought something in the same money event.  In that
            -- case we use the snapshot as the authoritative repair cost instead
            -- of the raw delta to avoid inflating repair records.
            --
            -- Edge cases handled:
            --   delta == 0                 → guild paid everything
            --   0 < delta < snapshot       → guild covered the difference
            --   delta ≈ snapshot           → personal repair (normal case)
            --   delta > snapshot * tolerance → mixed buy+repair; use snapshot
            local personalCost = delta
            local guildCost    = 0

            if snappedRepairCost > 0 then
                if delta <= 0 then
                    -- Guild covered the entire repair; player lost no money.
                    personalCost = 0
                    guildCost    = repairWasGuildAvail and snappedRepairCost or 0
                elseif delta > snappedRepairCost * REPAIR_DELTA_TOLERANCE then
                    -- Player bought something at the same time.  Trust the
                    -- snapshot for repair cost, not the inflated delta.
                    personalCost = snappedRepairCost
                    guildCost    = 0
                elseif repairWasGuildAvail and delta < snappedRepairCost then
                    -- Guild covered the portion the player didn't pay.
                    personalCost = delta
                    guildCost    = snappedRepairCost - delta
                end
                -- else: delta ≈ snappedRepairCost → pure personal, already set
            end

            if personalCost > 0 then RecordRepair(personalCost, false) end
            if guildCost    > 0 then RecordRepair(guildCost,    true)  end

            repairPending       = false
            lastMoney           = currentMoney
            -- Refresh snapshot so a second repair at the same visit starts clean.
            SnapshotRepairState()

        elseif inMerchant then
            -- Keep lastMoney current between non-repair money changes
            -- (e.g. the player bought something) so the NEXT repair delta
            -- is accurate.
            lastMoney = GetMoney()
            -- Also refresh repair cost in case the vendor's prices changed.
            if not repairPending then
                snappedRepairCost = GetRepairAllCost() or 0
            end
        end
    end
end)

-- Hook RepairAllItems so we know a repair action was initiated.
-- FIX (audit): We also snapshot guild availability here because it is the
-- moment immediately before the repair fires and gives us the most accurate
-- picture of who will be paying.
hooksecurefunc("RepairAllItems", function()
    if inMerchant then
        repairPending       = true
        repairWasGuildAvail = (CanGuildBankRepair and CanGuildBankRepair()) and true or false
        -- Re-snapshot the cost in case gear changed since MERCHANT_SHOW.
        snappedRepairCost   = GetRepairAllCost() or 0
    end
end)

--------------------------------------------------
-- Delete character helpers
--------------------------------------------------

StaticPopupDialogs["ACCOUNTREPAIRED_CONFIRM_DELETE"] = {
    text          = "",
    button1       = DELETE,
    button2       = CANCEL,
    OnAccept      = function(self, data)
        if not data or not data.foundKey then return end
        AccountRepairedDB[data.foundKey] = nil
        print("|cff00ff00" .. string.format(L["CMD_DELETE_SUCCESS"], data.foundKey) .. "|r")
        if AR.popupFrame and AR.popupFrame:IsShown() then
            AR.popupFrame:UpdateDisplay()
        end
    end,
    timeout      = 0,
    whileDead    = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

local function ConfirmDeleteKey(foundKey)
    StaticPopupDialogs["ACCOUNTREPAIRED_CONFIRM_DELETE"].text =
        string.format(L["CMD_DELETE_CONFIRM"], foundKey)
    StaticPopup_Show("ACCOUNTREPAIRED_CONFIRM_DELETE", nil, nil, { foundKey = foundKey })
end

local function DeleteCharacter(input)
    input = (input or ""):match("^%s*(.-)%s*$")
    if input == "" then
        print("|cffff9900" .. L["CMD_DELETE_USAGE"] .. "|r")
        return
    end
    local charName, realmName = input:match("^([^%-]+)%-(.+)$")
    if not charName or not realmName then
        print("|cffff9900" .. L["CMD_DELETE_USAGE"] .. "|r")
        return
    end
    local targetKey   = realmName .. "-" .. charName
    local lowerTarget = targetKey:lower()
    local foundKey    = nil
    for dbKey in pairs(AccountRepairedDB) do
        if dbKey:lower() == lowerTarget then foundKey = dbKey; break end
    end
    if not foundKey then
        print("|cffff0000" .. string.format(L["CMD_DELETE_NOT_FOUND"], input) .. "|r")
        return
    end
    ConfirmDeleteKey(foundKey)
end

SLASH_ACCOUNTREPAIREDDELETE1 = "/ardelete"
SlashCmdList.ACCOUNTREPAIREDDELETE = DeleteCharacter

--------------------------------------------------
-- Character Management Panel
-- (mirrors AccountPlayed's charPanel pattern)
--------------------------------------------------

local function CreateCharPanel()
    if AR.charPanel then return AR.charPanel end

    local p = CreateFrame("Frame", "AccountRepairedCharPanel", UIParent, "BackdropTemplate")
    p:SetWidth(CPANEL_W)
    p:SetHeight(CPANEL_HEADER_H + CPANEL_PAD)
    p:SetFrameStrata("DIALOG")
    p:SetFrameLevel(110)
    p:SetClampedToScreen(true)

    p:SetBackdrop({
        bgFile   = "Interface\\ChatFrame\\ChatFrameBackground",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 24,
        insets = { left = 8, right = 8, top = 8, bottom = 8 },
    })
    p:SetBackdropColor(0.05, 0.05, 0.05, 0.92)

    p.titleText = p:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    p.titleText:SetPoint("TOPLEFT",  p, "TOPLEFT",  12, -10)
    p.titleText:SetPoint("TOPRIGHT", p, "TOPRIGHT", -26, -10)
    p.titleText:SetJustifyH("LEFT")

    local closeBtn = CreateFrame("Button", nil, p, "UIPanelCloseButton")
    closeBtn:SetSize(20, 20)
    closeBtn:SetPoint("TOPRIGHT", p, "TOPRIGHT", -2, -2)
    closeBtn:SetScript("OnClick", function()
        p:Hide()
        AR.charPanelArmor = nil
    end)

    local div = p:CreateTexture(nil, "ARTWORK")
    div:SetHeight(1)
    div:SetPoint("TOPLEFT",  p, "TOPLEFT",  10, -(CPANEL_HEADER_H - 2))
    div:SetPoint("TOPRIGHT", p, "TOPRIGHT", -10, -(CPANEL_HEADER_H - 2))
    div:SetColorTexture(0.4, 0.4, 0.4, 0.8)

    p.charRows = {}
    for i = 1, 20 do
        local yOff = -(CPANEL_HEADER_H + CPANEL_PAD + (i - 1) * CPANEL_ROW_H)
        local row  = CreateFrame("Frame", nil, p)
        row:SetHeight(CPANEL_ROW_H)
        row:SetPoint("TOPLEFT",  p, "TOPLEFT",  10, yOff)
        row:SetPoint("TOPRIGHT", p, "TOPRIGHT", -10, yOff)

        row.bg = row:CreateTexture(nil, "BACKGROUND")
        row.bg:SetAllPoints()
        row.bg:SetColorTexture(1, 1, 1, 0)

        -- Character name (coloured by class)
        row.nameText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        row.nameText:SetPoint("LEFT", row, "LEFT", 0, 0)
        row.nameText:SetPoint("RIGHT", row, "RIGHT", -120, 0)
        row.nameText:SetJustifyH("LEFT")
        row.nameText:SetWordWrap(false)

        -- Gold spent
        row.goldText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        row.goldText:SetPoint("RIGHT", row, "RIGHT", -52, 0)
        row.goldText:SetWidth(80)
        row.goldText:SetJustifyH("RIGHT")
        row.goldText:SetTextColor(0.85, 0.85, 0.85)

        -- Delete button
        local trashBtn = CreateFrame("Button", nil, row)
        trashBtn:SetSize(44, 18)
        trashBtn:SetPoint("RIGHT", row, "RIGHT", 0, 0)

        local trashLabel = trashBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        trashLabel:SetAllPoints()
        trashLabel:SetText("|cffff4040" .. DELETE .. "|r")
        trashLabel:SetJustifyH("CENTER")
        trashBtn:SetWidth(trashLabel:GetStringWidth() + 8)

        trashBtn:SetScript("OnEnter", function()
            row.bg:SetColorTexture(1, 0.25, 0.25, 0.15)
            GameTooltip:SetOwner(trashBtn, "ANCHOR_RIGHT")
            GameTooltip:SetText(L["CHAR_PANEL_REMOVE_TIP"], 1, 0.35, 0.35)
            GameTooltip:Show()
        end)
        trashBtn:SetScript("OnLeave", function()
            row.bg:SetColorTexture(1, 1, 1, 0)
            GameTooltip:Hide()
        end)
        trashBtn:SetScript("OnClick", function()
            if row.charKey then ConfirmDeleteKey(row.charKey) end
        end)

        row.trashBtn = trashBtn
        row:Hide()
        p.charRows[i] = row
    end

    p:Hide()
    AR.charPanel = p
    table.insert(UISpecialFrames, "AccountRepairedCharPanel")
    return p
end

function AR.ShowCharPanel(armorType, forceShow, anchorRow)
    local p = CreateCharPanel()

    if not forceShow and AR.charPanelArmor == armorType and p:IsShown() then
        p:Hide(); AR.charPanelArmor = nil; return
    end

    local chars = GetCharactersByArmorType(armorType, AR.currentPeriod)
    if #chars == 0 then
        p:Hide(); AR.charPanelArmor = nil; return
    end

    AR.charPanelArmor = armorType

    if anchorRow then
        p:ClearAllPoints()
        p:SetPoint("TOPLEFT", anchorRow, "TOPRIGHT", 6, 0)
    elseif not p:IsShown() then
        p:ClearAllPoints()
        if AR.popupFrame and AR.popupFrame:IsShown() then
            p:SetPoint("TOPLEFT", AR.popupFrame, "TOPRIGHT", 4, 0)
        else
            p:SetPoint("CENTER")
        end
    end

    local color      = ARMOR_COLORS[armorType] or ARMOR_COLORS.Unknown
    local armorLabel = L["ARMOR_" .. armorType] or armorType
    p.titleText:SetText(armorLabel)
    p.titleText:SetTextColor(color.r, color.g, color.b)

    for i, row in ipairs(p.charRows) do
        local char = chars[i]
        if char then
            local classColor = RAID_CLASS_COLORS[char.class] or { r = 1, g = 1, b = 1 }
            row.nameText:SetText(char.name)
            row.nameText:SetTextColor(classColor.r, classColor.g, classColor.b)
            row.goldText:SetText(FormatGoldShort(char.gold))
            row.charKey = char.key
            row:Show()
        else
            row.charKey = nil; row:Hide()
        end
    end

    p:SetHeight(CPANEL_HEADER_H + CPANEL_PAD + #chars * CPANEL_ROW_H + CPANEL_PAD)
    p:Show()
end

--------------------------------------------------
-- Main popup – bar row factory
--
-- FIX (audit): Removed the dead row.valueText widget.  The right-hand
-- column now uses only row.pctText (fixed-width percentage) and
-- row.goldText (gold value), which were already the only two widgets
-- written to by UpdateDisplay().  Removing valueText eliminates the
-- potential horizontal overlap with pctText.
--------------------------------------------------

local function CreateBarRow(parent, width, height)
    local row = CreateFrame("Button", nil, parent)
    row:SetSize(width, height)
    row:EnableMouse(true)
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")

    row.highlight = row:CreateTexture(nil, "BACKGROUND")
    row.highlight:SetAllPoints()
    row.highlight:SetColorTexture(1, 1, 1, 0.1)
    row.highlight:Hide()

    -- Armor type label (left)
    row.labelText = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    row.labelText:SetPoint("LEFT", 0, 0)
    row.labelText:SetWidth(80)
    row.labelText:SetJustifyH("LEFT")

    -- Progress bar
    row.bar = CreateFrame("StatusBar", nil, row)
    row.bar:SetPoint("LEFT", row.labelText, "RIGHT", 6, 0)
    row.bar:SetPoint("RIGHT", row, "RIGHT", -160, 0)
    row.bar:SetHeight(height - 6)
    row.bar:SetMinMaxValues(0, 1)
    row.bar:SetValue(0)
    row.bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")

    row.bar.bg = row.bar:CreateTexture(nil, "BACKGROUND")
    row.bar.bg:SetAllPoints()
    row.bar.bg:SetColorTexture(0, 0, 0, 0.4)

    -- Right-aligned percentage label in its own fixed-width column.
    -- NOTE: row.valueText has been removed (was created but never written to).
    row.pctText = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    row.pctText:SetPoint("LEFT", row.bar, "RIGHT", 8, 0)
    row.pctText:SetWidth(52)
    row.pctText:SetJustifyH("RIGHT")

    -- Gold value label, anchored after the fixed-width pct column.
    row.goldText = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    row.goldText:SetPoint("LEFT", row.pctText, "RIGHT", 6, 0)
    row.goldText:SetWidth(102)
    row.goldText:SetJustifyH("LEFT")

    row:SetScript("OnEnter", function(self)
        self.highlight:Show()
        if self.armorType then
            local chars = GetCharactersByArmorType(self.armorType, AR.currentPeriod)
            if #chars > 0 then
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                local color      = ARMOR_COLORS[self.armorType] or ARMOR_COLORS.Unknown
                local armorLabel = L["ARMOR_" .. self.armorType] or self.armorType
                GameTooltip:AddLine(armorLabel, color.r, color.g, color.b)
                GameTooltip:AddLine(" ")
                for _, char in ipairs(chars) do
                    local classColor = RAID_CLASS_COLORS[char.class] or { r = 1, g = 1, b = 1 }
                    GameTooltip:AddDoubleLine(
                        char.name, FormatGoldFull(char.gold),
                        classColor.r, classColor.g, classColor.b,
                        1, 1, 1
                    )
                end
                GameTooltip:AddLine(" ")
                GameTooltip:AddLine(L["CLICK_TO_PRINT"],        0.5, 0.5, 0.5)
                GameTooltip:AddLine(L["CHAR_PANEL_RIGHT_CLICK"], 0.5, 0.5, 0.5)
                GameTooltip:Show()
            end
        end
    end)

    row:SetScript("OnLeave", function(self)
        self.highlight:Hide()
        GameTooltip:Hide()
    end)

    row:SetScript("OnClick", function(self, button)
        if not self.armorType then return end
        if button == "RightButton" then
            GameTooltip:Hide()
            PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
            AR.ShowCharPanel(self.armorType, false, self)
        else
            -- Left-click: print breakdown to chat
            local chars = GetCharactersByArmorType(self.armorType, AR.currentPeriod)
            if #chars > 0 then
                PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
                local armorLabel  = L["ARMOR_" .. self.armorType] or self.armorType
                local periodLabel = GetPeriodLabel(AR.currentPeriod)
                print("|cff00ff00" .. armorLabel .. " (" .. periodLabel .. "):|r")
                for _, char in ipairs(chars) do
                    local classColor = RAID_CLASS_COLORS[char.class] or { r = 1, g = 1, b = 1 }
                    print(string.format("  |cff%02x%02x%02x%s|r - %s",
                        classColor.r * 255, classColor.g * 255, classColor.b * 255,
                        char.name, FormatGoldFull(char.gold)))
                end
            end
        end
    end)

    return row
end

--------------------------------------------------
-- Main popup – scroll helper
--------------------------------------------------

local function UpdateScrollBarVisibility(frame)
    local sf = frame.scrollFrame
    local sb = sf and (sf.ScrollBar or sf.scrollBar)
    if not sb then return end
    if sf:GetVerticalScrollRange() > 0 then
        sb:Show()
    else
        sb:Hide()
        sf:SetVerticalScroll(0)
    end
end

--------------------------------------------------
-- Main popup – period tab buttons
--------------------------------------------------

local function CreatePeriodTabs(parent, onSelect)
    local tabs   = {}
    local tabW   = 72
    local tabH   = 22
    local pad    = 4
    local totalW = (#PERIOD_ORDER * tabW) + ((#PERIOD_ORDER - 1) * pad)

    -- Container (centred at top of content area)
    local container = CreateFrame("Frame", nil, parent)
    container:SetSize(totalW, tabH)

    for i, period in ipairs(PERIOD_ORDER) do
        local tab = CreateFrame("Button", nil, container, "BackdropTemplate")
        tab:SetSize(tabW, tabH)
        tab:SetPoint("LEFT", container, "LEFT", (i - 1) * (tabW + pad), 0)

        tab:SetBackdrop({
            bgFile   = "Interface\\ChatFrame\\ChatFrameBackground",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 12,
            insets = { left = 3, right = 3, top = 3, bottom = 3 },
        })

        tab.label = tab:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        tab.label:SetAllPoints()
        tab.label:SetJustifyH("CENTER")
        tab.label:SetText(GetPeriodLabel(period))

        tab.period = period

        tab:SetScript("OnClick", function(self)
            AR.currentPeriod = self.period
            AccountRepairedPopupDB.period = self.period
            PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
            onSelect(self.period)
            -- Refresh tab highlight states
            for _, t in ipairs(tabs) do t:UpdateState() end
        end)

        tab:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:AddLine(GetPeriodLabel(self.period), 1, 1, 1)
            GameTooltip:Show()
        end)
        tab:SetScript("OnLeave", function() GameTooltip:Hide() end)

        function tab:UpdateState()
            local active = (self.period == AR.currentPeriod)
            if active then
                self:SetBackdropColor(0.25, 0.75, 0.25, 0.4)
                self.label:SetTextColor(0.2, 1.0, 0.2)
            else
                self:SetBackdropColor(0.1, 0.1, 0.1, 0.7)
                self.label:SetTextColor(0.8, 0.8, 0.8)
            end
        end
        tab:UpdateState()

        tabs[i] = tab
    end

    return container, tabs
end

--------------------------------------------------
-- Main popup – window
--------------------------------------------------

local function CreatePopup()
    if AR.popupFrame then return AR.popupFrame end

    local layoutDB = GetLayoutDB()
    local START_W  = layoutDB.width  or 540
    local START_H  = layoutDB.height or 340
    local MIN_W, MIN_H = 440, 240
    local MAX_W, MAX_H = 740, 480

    local f = CreateFrame("Frame", "AccountRepairedPopup", UIParent, "BackdropTemplate")
    f:SetSize(START_W, START_H)

    if layoutDB.point then
        f:SetPoint(layoutDB.point, UIParent, layoutDB.point,
                   layoutDB.x or 0, layoutDB.y or 0)
    else
        f:SetPoint("CENTER")
    end

    f:SetFrameStrata("DIALOG")
    f:SetFrameLevel(100)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, _, x, y = self:GetPoint()
        -- Always write our own position – never touch AccountPlayed's DB.
        AccountRepairedPopupDB.point = point
        AccountRepairedPopupDB.x     = x
        AccountRepairedPopupDB.y     = y
    end)

    f:SetResizable(true)
    if f.SetResizeBounds then
        f:SetResizeBounds(MIN_W, MIN_H, MAX_W, MAX_H)
    elseif f.SetMinResize then
        f:SetMinResize(MIN_W, MIN_H)
        f:SetMaxResize(MAX_W, MAX_H)
    end
    f:SetClampedToScreen(true)

    -- Resize grip
    local br = CreateFrame("Button", nil, f)
    br:SetSize(16, 16)
    br:SetPoint("BOTTOMRIGHT", -6, 6)
    br:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    br:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    br:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    br:SetScript("OnMouseDown", function(self) self:GetParent():StartSizing("BOTTOMRIGHT") end)
    br:SetScript("OnMouseUp",   function(self) self:GetParent():StopMovingOrSizing() end)
    f.resizeGrip = br   -- stored so SetCollapsed can show/hide it

    f:SetBackdrop({
        bgFile   = "Interface\\ChatFrame\\ChatFrameBackground",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 },
    })
    f:SetBackdropColor(0, 0, 0, 0.55)

    -- Title
    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    f.title:SetPoint("TOP", f, "TOP", 0, -12)
    f.title:SetText(L["WINDOW_TITLE"])

    -- Close button  [X]
    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -10, -10)
    close:SetScript("OnClick", function()
        PlaySound(SOUNDKIT.IG_MAINMENU_CLOSE)
        f:Hide()
    end)

    --------------------------------------------------
    -- Collapse / expand button  [-] / [+]
    -- Sits immediately to the left of the close [X].
    --------------------------------------------------
    local collapseBtn = CreateFrame("Button", nil, f, "BackdropTemplate")
    collapseBtn:SetSize(20, 20)
    collapseBtn:SetPoint("RIGHT", close, "LEFT", -4, 0)

    collapseBtn:SetBackdrop({
        bgFile   = "Interface\\ChatFrame\\ChatFrameBackground",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 10,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    collapseBtn:SetBackdropColor(0.10, 0.10, 0.10, 0.85)
    collapseBtn:SetBackdropBorderColor(0.55, 0.55, 0.55, 0.85)

    collapseBtn.label = collapseBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    collapseBtn.label:SetAllPoints()
    collapseBtn.label:SetJustifyH("CENTER")
    collapseBtn.label:SetJustifyV("MIDDLE")
    collapseBtn.label:SetText(AR.collapsed and "+" or "-")

    collapseBtn:SetScript("OnEnter", function(self)
        self:SetBackdropColor(0.20, 0.20, 0.20, 0.95)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        if AR.collapsed then
            GameTooltip:AddLine(L["EXPAND_WINDOW"]   or "Expand window",   1, 1, 1)
        else
            GameTooltip:AddLine(L["COLLAPSE_WINDOW"] or "Collapse window", 1, 1, 1)
        end
        GameTooltip:Show()
    end)
    collapseBtn:SetScript("OnLeave", function(self)
        self:SetBackdropColor(0.10, 0.10, 0.10, 0.85)
        GameTooltip:Hide()
    end)
    collapseBtn:SetScript("OnClick", function()
        PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
        f:SetCollapsed(not AR.collapsed)
    end)

    f.collapseBtn = collapseBtn

    f:SetScript("OnHide", function()
        if AR.charPanel then AR.charPanel:Hide() end
        AR.charPanelArmor = nil
    end)

    table.insert(UISpecialFrames, "AccountRepairedPopup")

    --------------------------------------------------
    -- Guild repair checkbox (top-left)
    --------------------------------------------------
    local guildCB = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
    guildCB:SetSize(24, 24)
    guildCB:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -10)
    guildCB:SetChecked(AccountRepairedPopupDB.includeGuild ~= false)

    local guildCBLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    guildCBLabel:SetPoint("LEFT", guildCB, "RIGHT", 2, 0)
    guildCBLabel:SetText(L["INCLUDE_GUILD_REPAIRS"])
    guildCBLabel:SetTextColor(0.8, 0.8, 0.8)

    guildCB:SetScript("OnClick", function(self)
        local checked = self:GetChecked()
        AccountRepairedPopupDB.includeGuild = checked and true or false
        PlaySound(checked and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON
                            or SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_OFF)
        if f.UpdateDisplay then f:UpdateDisplay() end
    end)

    guildCB:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(L["INCLUDE_GUILD_REPAIRS"], 1, 1, 1)
        GameTooltip:AddLine(L["GUILD_REPAIRS_TIP"], 0.8, 0.8, 0.8, true)
        GameTooltip:Show()
    end)
    guildCB:SetScript("OnLeave", function() GameTooltip:Hide() end)

    f.guildCB      = guildCB
    f.guildCBLabel = guildCBLabel   -- stored so SetCollapsed can show/hide it

    --------------------------------------------------
    -- Period tab bar (anchored below title)
    --------------------------------------------------
    local function OnPeriodSelect(period)
        AR.currentPeriod = period
        if f.UpdateDisplay then f:UpdateDisplay() end
    end

    local tabContainer, tabRefs = CreatePeriodTabs(f, OnPeriodSelect)
    tabContainer:SetPoint("TOP", f.title, "BOTTOM", 0, -8)
    f.tabs    = tabContainer
    f.tabRefs = tabRefs

    --------------------------------------------------
    -- Current-character summary strip
    -- Shows: "CharName (ArmorType)  Today: Xg  Week: Xg  Month: Xg  Total: Xg"
    -- IMPROVE (audit): the label for the currently active period is
    -- highlighted in green so the user can tell which window the bars reflect.
    --------------------------------------------------
    local charStrip = CreateFrame("Frame", nil, f, "BackdropTemplate")
    charStrip:SetPoint("TOPLEFT",  f, "TOPLEFT",  14, -76)
    charStrip:SetPoint("TOPRIGHT", f, "TOPRIGHT", -14, -76)
    charStrip:SetHeight(36)
    charStrip:SetBackdrop({
        bgFile   = "Interface\\ChatFrame\\ChatFrameBackground",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 10,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    charStrip:SetBackdropColor(0.08, 0.08, 0.08, 0.80)

    charStrip.nameText = charStrip:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    charStrip.nameText:SetPoint("LEFT", charStrip, "LEFT", 10, 0)
    charStrip.nameText:SetWidth(160)
    charStrip.nameText:SetJustifyH("LEFT")

    charStrip.statsText = charStrip:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    charStrip.statsText:SetPoint("LEFT",  charStrip.nameText, "RIGHT", 8, 0)
    charStrip.statsText:SetPoint("RIGHT", charStrip, "RIGHT", -8, 0)
    charStrip.statsText:SetJustifyH("LEFT")
    charStrip.statsText:SetTextColor(0.85, 0.85, 0.85)

    f.charStrip = charStrip

    --------------------------------------------------
    -- Scroll frame for armor-type bars
    --------------------------------------------------
    local scrollFrame = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT",  f, "TOPLEFT",  14, -120)
    scrollFrame:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -30, 50)
    f.scrollFrame = scrollFrame

    local content = CreateFrame("Frame", nil, scrollFrame)
    content:SetSize(1, 1)
    scrollFrame:SetScrollChild(content)
    f.content = content

    scrollFrame:EnableMouseWheel(true)
    scrollFrame:SetScript("OnMouseWheel", function(self, delta)
        local step = 20
        local new  = self:GetVerticalScroll() - delta * step
        new = math.max(0, math.min(new, self:GetVerticalScrollRange()))
        self:SetVerticalScroll(new)
    end)

    -- Account total line (bottom-left) – white text
    f.totalRow = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    f.totalRow:SetPoint("BOTTOMLEFT", 15, 18)
    f.totalRow:SetTextColor(1, 1, 1)

    --------------------------------------------------
    -- "Account Played" companion button (bottom-right)
    -- NOTE: This entire block is intentionally unchanged from 0.3.3.
    --       All AccountPlayed integration is preserved exactly as-is.
    --------------------------------------------------
    local apBtn = CreateFrame("Button", nil, f, "BackdropTemplate")
    apBtn:SetSize(120, 20)
    apBtn:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -15, 16)
    apBtn:SetBackdrop({
        bgFile   = "Interface\\ChatFrame\\ChatFrameBackground",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 10,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    apBtn:SetBackdropColor(0.05, 0.05, 0.05, 0.85)
    apBtn:SetBackdropBorderColor(0.4, 0.7, 1.0, 0.9)

    local apBtnLabel = apBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    apBtnLabel:SetAllPoints()
    apBtnLabel:SetJustifyH("CENTER")
    apBtnLabel:SetText("|cff6699FFAccount Played|r")

    apBtn:SetScript("OnEnter", function(self)
        self:SetBackdropBorderColor(0.6, 0.85, 1.0, 1.0)
        self:SetBackdropColor(0.02, 0.08, 0.18, 0.95)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine("Account Played", 0.6, 0.85, 1.0)
        GameTooltip:AddLine("Switch to account played statistics", 0.8, 0.8, 0.8)
        GameTooltip:Show()
    end)
    apBtn:SetScript("OnLeave", function(self)
        self:SetBackdropBorderColor(0.4, 0.7, 1.0, 0.9)
        self:SetBackdropColor(0.05, 0.05, 0.05, 0.85)
        GameTooltip:Hide()
    end)
    apBtn:SetScript("OnClick", function()
        PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
        f:Hide()   -- OnHide handles charPanel cleanup
        if AccountPlayed and AccountPlayed.ToggleClassWindow then
            AccountPlayed.ToggleClassWindow()
        end
    end)

    apBtn:Hide()
    f.apBtn = apBtn

    -- Create bar rows (one per armor type, max 5)
    local rowH = 26
    for i = 1, #ARMOR_TYPE_NAMES do
        local row = CreateBarRow(content, START_W - 60, rowH)
        row:SetPoint("TOPLEFT", 0, -(i - 1) * rowH)
        row:Hide()
        AR.popupRows[i] = row
    end

    --------------------------------------------------
    -- Resize handler
    -- Guard: skip all logic while in collapsed mode so the COLLAPSED_H
    -- is never accidentally saved over the user's preferred full height.
    --------------------------------------------------
    f:SetScript("OnSizeChanged", function(self, w, h)
        if AR.collapsed then return end   -- collapsed mode: ignore size events

        if w < MIN_W then self:SetWidth(MIN_W)  end
        if h < MIN_H then self:SetHeight(MIN_H) end
        if w > MAX_W then self:SetWidth(MAX_W)  end
        if h > MAX_H then self:SetHeight(MAX_H) end

        -- Always write our own size – never touch AccountPlayed's DB.
        AccountRepairedPopupDB.width  = self:GetWidth()
        AccountRepairedPopupDB.height = self:GetHeight()

        local cw = self.scrollFrame:GetWidth()
        self.content:SetWidth(cw)
        for _, row in ipairs(AR.popupRows) do row:SetWidth(cw) end
        UpdateScrollBarVisibility(self)
    end)

    --------------------------------------------------
    -- SetCollapsed  (NEW in v0.4.1)
    --
    -- collapsed = true  → shrink to char strip + footer
    -- collapsed = false → restore to full bar-chart view
    --
    -- Persists state to AccountRepairedPopupDB.collapsed.
    -- Does NOT touch AccountPlayedPopupDB (integration preserved).
    --------------------------------------------------
    f.SetCollapsed = function(self, collapsed)
        AR.collapsed = collapsed
        AccountRepairedPopupDB.collapsed = collapsed

        if collapsed then
            -- ── Hide full-view elements ──────────────────────────────────
            self.title:Hide()
            self.guildCB:Hide()
            self.guildCBLabel:Hide()
            self.tabs:Hide()
            self.scrollFrame:Hide()
            self.resizeGrip:Hide()

            -- ── Move charStrip to just below the top buttons ─────────────
            self.charStrip:ClearAllPoints()
            self.charStrip:SetPoint("TOPLEFT",  self, "TOPLEFT",  14, -10)
            self.charStrip:SetPoint("TOPRIGHT", self, "TOPRIGHT", -14, -10)

            -- ── Shrink frame; disable resize so grip can't re-expand it ──
            self:SetResizable(false)
            self:SetHeight(COLLAPSED_H)

            -- ── Update button glyph ──────────────────────────────────────
            self.collapseBtn.label:SetText("+")

        else
            -- ── Restore full-view elements ───────────────────────────────
            self.title:Show()
            self.guildCB:Show()
            self.guildCBLabel:Show()
            self.tabs:Show()
            self.scrollFrame:Show()
            self.resizeGrip:Show()

            -- ── Restore charStrip to its original anchored position ──────
            self.charStrip:ClearAllPoints()
            self.charStrip:SetPoint("TOPLEFT",  self, "TOPLEFT",  14, -76)
            self.charStrip:SetPoint("TOPRIGHT", self, "TOPRIGHT", -14, -76)

            -- ── Re-enable resize and restore saved height ─────────────────
            self:SetResizable(true)
            if self.SetResizeBounds then
                self:SetResizeBounds(MIN_W, MIN_H, MAX_W, MAX_H)
            elseif self.SetMinResize then
                self:SetMinResize(MIN_W, MIN_H)
                self:SetMaxResize(MAX_W, MAX_H)
            end
            -- AccountRepairedPopupDB.height is kept current by OnSizeChanged
            -- (which is guarded against collapsed mode), so this is safe.
            self:SetHeight(AccountRepairedPopupDB.height or START_H)

            -- ── Update button glyph ──────────────────────────────────────
            self.collapseBtn.label:SetText("-")
        end
    end

    --------------------------------------------------
    -- UpdateDisplay
    --------------------------------------------------
    f.UpdateDisplay = function(self)
        -- ── Account Played companion button ───────────────────────────────
        -- NOTE: unchanged from 0.3.3; AccountPlayed integration preserved.
        if self.apBtn then
            if AccountPlayed and AccountPlayed.ToggleClassWindow then
                self.apBtn:Show()
            else
                self.apBtn:Hide()
            end
        end

        -- ── Refresh tab highlight states ──────────────────────────────────
        if self.tabRefs then
            for _, tab in ipairs(self.tabRefs) do tab:UpdateState() end
        end

        -- ── Sync guild checkbox to DB (handles external DB changes) ───────
        if self.guildCB then
            self.guildCB:SetChecked(AccountRepairedPopupDB.includeGuild ~= false)
        end

        -- ── Current-character strip ───────────────────────────────────────
        local realm, name  = GetCharInfo()
        local _, classFile = UnitClass("player")
        local classColor   = (classFile and RAID_CLASS_COLORS[classFile]) or { r=1, g=1, b=1 }

        local stats, charData = GetCurrentCharAllPeriods()

        local armorLabel = ""
        if charData then
            armorLabel = " (" .. (L["ARMOR_" .. (charData.armorType or "Unknown")] or "?") .. ")"
        end
        self.charStrip.nameText:SetText(string.format("|cff%02x%02x%02x%s|r%s",
            classColor.r * 255, classColor.g * 255, classColor.b * 255,
            name, "|cffAAAAAA" .. armorLabel .. "|r"))

        -- IMPROVE (audit): bold/green the currently-active period label.
        local function PeriodLabel(key)
            if key == AR.currentPeriod then
                return "|cff33ff33" .. GetPeriodLabel(key) .. "|r"
            end
            return GetPeriodLabel(key)
        end

        self.charStrip.statsText:SetText(string.format(
            "%s: %s   %s: %s   %s: %s   %s: %s",
            PeriodLabel("day"),   FormatGoldShort(stats.day),
            PeriodLabel("week"),  FormatGoldShort(stats.week),
            PeriodLabel("month"), FormatGoldShort(stats.month),
            PeriodLabel("all"),   FormatGoldShort(stats.all)
        ))

        -- ── Armor type bars (skip in collapsed mode) ──────────────────────
        if not AR.collapsed then
            local totals, accountTotal = GetArmorTypeTotals(AR.currentPeriod)

            if accountTotal == 0 then
                AR.popupRows[1].labelText:SetText(L["NO_DATA"])
                AR.popupRows[1].bar:SetValue(0)
                AR.popupRows[1].pctText:SetText("")
                AR.popupRows[1].goldText:SetText("")
                AR.popupRows[1].armorType = nil
                AR.popupRows[1]:Show()
                for i = 2, #AR.popupRows do AR.popupRows[i]:Hide() end
                self.content:SetHeight(26)
                self.totalRow:SetText(L["TOTAL"] .. FormatGoldFull(0))
                UpdateScrollBarVisibility(self)
            else
                -- Sort armor types by gold spent descending
                local sorted = {}
                for _, armorType in ipairs(ARMOR_TYPE_NAMES) do
                    if (totals[armorType] or 0) > 0 then
                        table.insert(sorted, { armorType = armorType, gold = totals[armorType] })
                    end
                end
                -- Include any types not in ARMOR_TYPE_NAMES (safety net)
                for armorType, gold in pairs(totals) do
                    local found = false
                    for _, s in ipairs(sorted) do if s.armorType == armorType then found = true; break end end
                    if not found then table.insert(sorted, { armorType = armorType, gold = gold }) end
                end
                table.sort(sorted, function(a, b) return a.gold > b.gold end)

                local topGold = sorted[1].gold

                for i, row in ipairs(AR.popupRows) do
                    local entry = sorted[i]
                    if entry then
                        local pct    = entry.gold / accountTotal
                        local barPct = entry.gold / topGold
                        local color  = ARMOR_COLORS[entry.armorType] or ARMOR_COLORS.Unknown
                        local label  = L["ARMOR_" .. entry.armorType] or entry.armorType

                        row.armorType = entry.armorType
                        row.labelText:SetText(label)
                        row.labelText:SetTextColor(color.r, color.g, color.b)
                        row.bar:SetValue(barPct)
                        row.bar:SetStatusBarColor(color.r, color.g, color.b)
                        row.pctText:SetText(string.format("%.1f%%", pct * 100))
                        row.goldText:SetText("- " .. FormatGoldShort(entry.gold))
                        row:Show()
                    else
                        row.armorType = nil
                        row:Hide()
                    end
                end

                self.content:SetHeight(#sorted * 26)
                UpdateScrollBarVisibility(self)
                self.totalRow:SetText(L["TOTAL"] .. FormatGoldFull(accountTotal))

                -- Refresh char panel if pinned
                if AR.charPanel and AR.charPanel:IsShown() and AR.charPanelArmor then
                    AR.ShowCharPanel(AR.charPanelArmor, true)
                end
            end
        else
            -- Collapsed: still update the account total footer
            local _, accountTotal = GetArmorTypeTotals(AR.currentPeriod)
            self.totalRow:SetText(L["TOTAL"] .. FormatGoldFull(accountTotal))
        end
    end

    f:Hide()
    AR.popupFrame = f
    return f
end

local function UpdatePopup()
    local f = CreatePopup()

    -- Re-read layout every time we open so changes made in AccountPlayed
    -- (size, position) are picked up without a reload.
    -- NOTE: unchanged from 0.3.3; AccountPlayed integration preserved.
    local layoutDB = GetLayoutDB()

    -- Apply collapsed state BEFORE setting size so we don't flash at the
    -- wrong height.  SetCollapsed handles its own height internally.
    if AR.collapsed then
        -- Restore position only (SetCollapsed will set height)
        f:ClearAllPoints()
        local pt = AccountRepairedPopupDB.point
        if pt then
            f:SetPoint(pt, UIParent, pt,
                AccountRepairedPopupDB.x or 0,
                AccountRepairedPopupDB.y or 0)
        else
            f:SetPoint("CENTER")
        end
        f:SetCollapsed(true)
    else
        local w = layoutDB.width  or AccountRepairedPopupDB.width  or 540
        local h = layoutDB.height or AccountRepairedPopupDB.height or 340
        f:SetSize(w, h)

        f:ClearAllPoints()
        local pt = layoutDB.point or AccountRepairedPopupDB.point
        if pt then
            f:SetPoint(pt, UIParent, pt, layoutDB.x or 0, layoutDB.y or 0)
        else
            f:SetPoint("CENTER")
        end
        f:SetCollapsed(false)
    end

    f:UpdateDisplay()
    f:Show()
end

--------------------------------------------------
-- Toggle
--------------------------------------------------

AR.ToggleWindow = function()
    if AR.popupFrame and AR.popupFrame:IsShown() then
        PlaySound(SOUNDKIT.IG_MAINMENU_CLOSE)
        AR.popupFrame:Hide()
    else
        PlaySound(SOUNDKIT.IG_MAINMENU_OPEN)
        UpdatePopup()
    end
end

--------------------------------------------------
-- Debug command
--------------------------------------------------

SLASH_ACCOUNTREPAIREDDEBUG1 = "/ardebug"
SlashCmdList.ACCOUNTREPAIREDDEBUG = function()
    print("|cffff0000" .. L["DEBUG_HEADER"] .. "|r")
    for charKey, data in pairs(AccountRepairedDB) do
        if type(data) == "table" then
            local total      = 0
            local guildTotal = 0
            for _, entry in ipairs(data.repairs or {}) do
                if entry.guild then
                    guildTotal = guildTotal + (entry.g or 0)
                else
                    total = total + (entry.g or 0)
                end
            end
            print(string.format(" |cffffff00- %s [%s/%s] : %s personal / %s guild (%d repairs)|r",
                charKey, data.class or "?", data.armorType or "?",
                FormatGoldFull(total), FormatGoldFull(guildTotal),
                #(data.repairs or {})))
        end
    end
end

--------------------------------------------------
-- Slash commands  /arepaired show | minimap | reset
--------------------------------------------------

SLASH_ACCOUNTREPAIRED1 = "/arepaired"
SlashCmdList.ACCOUNTREPAIRED = function(input)
    input = ((input or ""):match("^%s*(.-)%s*$")):lower()
    if input == "show" then
        AR.ToggleWindow()
    elseif input == "minimap" then
        local btn = _G["AccountRepaired_MinimapButton"]
        if btn then
            if not AccountRepairedMinimapDB.hidden then
                AccountRepairedMinimapDB.hidden = true
                UIFrameFadeRemoveFrame(btn)
                btn:SetAlpha(0); btn:EnableMouse(false); btn:Hide()
                print("|cff00ff00Account Repaired:|r " .. L["MSG_MINIMAP_HIDDEN"])
            else
                AccountRepairedMinimapDB.hidden = false
                btn:EnableMouse(true); btn:Show(); btn:SetAlpha(1)
                print("|cff00ff00Account Repaired:|r " .. L["MSG_MINIMAP_SHOWN"])
            end
        elseif AccountRepairedMinimapDB and AccountRepairedMinimapDB.hidden then
            AccountRepairedMinimapDB.hidden = false
            if AR.CreateMinimapButton then AR.CreateMinimapButton() end
            print("|cff00ff00Account Repaired:|r " .. L["MSG_MINIMAP_SHOWN"])
        end
    elseif input == "reset" then
        if AR.ResetMinimapButton then
            AR.ResetMinimapButton()
        else
            print("|cff00ff00Account Repaired:|r " .. L["MSG_MINIMAP_NOT_INIT"])
        end
    else
        print("|cff00ff00Account Repaired:|r " .. L["CMD_HELP_HEADER"])
        print("  |cffffff00/arepaired show|r     - " .. L["CMD_HELP_SHOW_DESC"])
        print("  |cffffff00/arepaired minimap|r  - " .. L["CMD_HELP_MINIMAP_DESC"])
        print("  |cffffff00/arepaired reset|r    - " .. L["CMD_HELP_RESET_DESC"])
        print("  |cffffff00/ardelete CharName-RealmName|r")
    end
end

--------------------------------------------------
-- LibDataBroker plugin
--------------------------------------------------

local ldb = LibStub("LibDataBroker-1.1"):NewDataObject("AccountRepaired", {
    type = "data source",
    text = "AccountRepaired",
    icon = "Interface\\Icons\\INV_Misc_Coin_01",
    OnTooltipShow = function(tooltip)
        tooltip:AddLine("|cffffffffAccount Repaired|r")
        local _, accountTotal = GetArmorTypeTotals(AR.currentPeriod)
        tooltip:AddLine("Total repairs: " .. FormatGoldFull(accountTotal))
        tooltip:AddLine("Click to toggle window")
    end,
    OnClick = function(_, button)
        if button == "LeftButton" then AR.ToggleWindow() end
    end,
})

--------------------------------------------------
-- Persist minimap hidden state
-- NOTE: unchanged from 0.3.3.
--------------------------------------------------

local persistFrame = CreateFrame("Frame")
persistFrame:RegisterEvent("PLAYER_LOGIN")
persistFrame:SetScript("OnEvent", function(self)
    C_Timer.After(0, function()
        if AccountRepairedMinimapDB and AccountRepairedMinimapDB.hidden then
            local btn = _G["AccountRepaired_MinimapButton"]
            if btn then btn:EnableMouse(false); btn:Hide() end
        end
    end)
    self:UnregisterEvent("PLAYER_LOGIN")
end)

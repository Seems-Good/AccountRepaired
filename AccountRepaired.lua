--------------------------------------------------
-- Account Repaired v@project-version@
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
local DB

local MIN_W = 440
local MAX_W = 680

-- Fixed window height — not saved, not resizable vertically
local FIXED_H = 260

local function InitDB()
    AccountRepairedDB      = AccountRepairedDB      or {}
    AccountRepairedPopupDB = AccountRepairedPopupDB or {}
    DB = AccountRepairedPopupDB

    -- Migrate: clear any previously saved height
    DB.height = nil

    if DB.width  == nil then DB.width  = 540      end
    if DB.point  == nil then DB.point  = "CENTER" end
    if DB.x      == nil then DB.x      = 0        end
    if DB.y      == nil then DB.y      = 0        end
    if DB.period == nil then DB.period = "all"    end

    -- Clamp saved width to valid range
    DB.width = math.max(MIN_W, math.min(DB.width, MAX_W))

    AR.currentPeriod = DB.period
end

--------------------------------------------------
-- Constants
--------------------------------------------------
local DATA_RETENTION_SECONDS = 365 * 2 * 86400

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
  --{ key="OFFICER", label="Officer",      color={0.3, 0.8, 0.3} },
  { key="NONE",    label="None (print)", color={0.6, 0.6, 0.6} },
}

local CPANEL_W        = 240
local CPANEL_ROW_H    = 22
local CPANEL_HEADER_H = 28
local CPANEL_PAD      = 6
local BAR_ROW_H       = 26

local POPUP_STRIP_Y = -68
local POPUP_BARS_Y  = -112

--------------------------------------------------
-- State
--------------------------------------------------
AR.mainFrame      = CreateFrame("Frame")
AR.popupFrame     = nil
AR.popupRows      = {}
AR.charPanel      = nil
AR.charPanelArmor = nil
AR.currentPeriod  = "all"

local inMerchant         = false
local pendingArmorDetect = false

--------------------------------------------------
-- Repair state machine
--------------------------------------------------
local repair = {
  phase        = "IDLE",
  moneyBefore  = 0,
}

local function ResetRepairState()
  repair.phase       = "IDLE"
  repair.moneyBefore = 0
end

--------------------------------------------------
-- Character identity
--------------------------------------------------
local function GetCharInfo()
  local realm = (GetNormalizedRealmName and GetNormalizedRealmName()) or GetRealmName()
  return realm, UnitName("player")
end

local function GetCharKey(realm, name)
  return realm .. "-" .. name
end

local function KeyToName(key)
  return key:match("%-([^%-]+)$") or key
end

--------------------------------------------------
-- Armor detection
--------------------------------------------------
local function DetectArmorType()
  local counts   = {}
  local allReady = true
  for _, slotID in ipairs(ARMOR_SLOTS) do
    local itemID = GetInventoryItemID("player", slotID)
    if itemID then
      local _, _, _, _, _, _, sub = GetItemInfo(itemID)
      if sub then
        if ARMOR_TYPES_VALID[sub] then
          counts[sub] = (counts[sub] or 0) + 1
        end
      else
        allReady = false
      end
    end
  end
  local best, bestN = "Unknown", 0
  for sub, n in pairs(counts) do
    if n > bestN then best, bestN = sub, n end
  end
  return best, allReady
end

local function RefreshCharArmorType()
  local realm, name = GetCharInfo()
  local charKey = GetCharKey(realm, name)
  local _, classFile = UnitClass("player")
  local armorType, allReady = DetectArmorType()
  local cd = AccountRepairedDB[charKey]
  if not cd then
    AccountRepairedDB[charKey] = { class=classFile or "UNKNOWN", armorType=armorType, repairs={} }
    cd = AccountRepairedDB[charKey]
  end
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
  local g = math.floor(copper / 10000)
  local s = math.floor((copper % 10000) / 100)
  local c = copper % 100
  if g > 0 then
    return string.format("|cffFFD700%d|rg |cffC0C0C0%d|rs |cffCD7F32%d|rc", g, s, c)
  elseif s > 0 then
    return string.format("|cffC0C0C0%d|rs |cffCD7F32%d|rc", s, c)
  else
    return string.format("|cffCD7F32%d|rc", c)
  end
end

local function FormatGoldShort(copper)
  copper = math.floor(tonumber(copper) or 0)
  if copper <= 0 then return "|cffAAAAAA0g|r" end
  local gv = copper / 10000
  if gv >= 1000 then
    return string.format("|cffFFD700%.1fk|r", gv / 1000)
  elseif gv >= 1 then
    return string.format("|cffFFD700%.1f|rg", gv)
  end
  local sv = copper / 100
  if sv >= 1 then
    return string.format("|cffC0C0C0%.1f|rs", sv)
  end
  return string.format("|cffCD7F32%d|rc", copper)
end

local function FormatGoldRounded(copper)
  copper = math.floor(tonumber(copper) or 0)
  if copper <= 0 then return "|cffAAAAAA0g|r" end
  local gv = copper / 10000
  if gv >= 1 then
    if gv >= 1000 then
      return string.format("|cffFFD700%d|rk", math.floor(gv / 1000 + 0.5))
    else
      local rounded_k = math.floor(gv / 1000 + 0.5)
      if gv >= 1000 - 50 then
        return string.format("|cffFFD700%d|rk", rounded_k)
      end
      if gv >= 100 then
        local r = math.floor(gv / 100 + 0.5) * 100
        if r >= 1000 then
          return string.format("|cffFFD700%d|rk", r / 1000)
        end
        return string.format("|cffFFD700%d|rg", r)
      end
      return string.format("|cffFFD700%d|rg", math.floor(gv + 0.5))
    end
  end
  local sv = copper / 100
  if sv >= 1 then return string.format("|cffC0C0C0%d|rs", math.floor(sv)) end
  return string.format("|cffCD7F32%d|rc", copper)
end

local function FormatGoldPlain(copper)
  copper = math.floor(tonumber(copper) or 0)
  if copper <= 0 then return "0g" end
  local g = math.floor(copper / 10000)
  local s = math.floor((copper % 10000) / 100)
  local c = copper % 100
  if g > 0 then
    return string.format("%dg %ds %dc", g, s, c)
  elseif s > 0 then
    return string.format("%ds %dc", s, c)
  else
    return string.format("%dc", c)
  end
end

--------------------------------------------------
-- Period helpers
--------------------------------------------------
local function GetDayResetTimestamp()
  local secsUntilReset = GetQuestResetTime() or 86400
  return time() + secsUntilReset - 86400
end

local function GetPeriodStart(period)
  if period == "all" or not PERIOD_SECONDS[period] then return 0 end
  if period == "day" then return GetDayResetTimestamp() end
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

local function GetPeriodContextLabel(period)
  if period == "day" then
    local secsUntilReset = GetQuestResetTime() or 0
    local secsSinceReset = math.max(0, math.min(86400 - secsUntilReset, 86400))
    local h = math.floor(secsSinceReset / 3600)
    local m = math.floor((secsSinceReset % 3600) / 60)
    if h > 0 then
      return string.format("last reset %dh %dm ago", h, m)
    else
      return string.format("last reset %dm ago", m)
    end
  elseif period == "week"  then return "last 7 days"
  elseif period == "month" then return "last 30 days"
  elseif period == "all"   then return "all time (last 2 years)"
  end
  return period
end

--------------------------------------------------
-- Data aggregation
--------------------------------------------------
local function GetCharRepairsInPeriod(cd, periodStart)
  local total = 0
  if not (cd and cd.repairs) then return 0 end
  for _, e in ipairs(cd.repairs) do
    if (e.t or 0) >= periodStart then
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
      if amt > 0 then
        totals[at] = (totals[at] or 0) + amt
        acct = acct + amt
      end
    end
  end
  return totals, acct
end

local function GetCharactersByArmorType(armorType, period)
  local chars = {}
  local ps = GetPeriodStart(period)
  for charKey, cd in pairs(AccountRepairedDB) do
    if type(cd) == "table" and (cd.armorType or "Unknown") == armorType then
      local amt = GetCharRepairsInPeriod(cd, ps)
      if amt > 0 then
        table.insert(chars, {
          key       = charKey,
          name      = KeyToName(charKey),
          class     = cd.class or "UNKNOWN",
          armorType = armorType,
          gold      = amt,
        })
      end
    end
  end
  table.sort(chars, function(a, b) return a.gold > b.gold end)
  return chars
end

local function GetCurrentCharAllPeriods()
  local realm, name = GetCharInfo()
  local cd = AccountRepairedDB[GetCharKey(realm, name)]
  local stats = { day=0, week=0, month=0, all=0 }
  if cd and cd.repairs then
    local now      = time()
    local dayStart = GetDayResetTimestamp()
    for _, e in ipairs(cd.repairs) do
      local t, g = e.t or 0, e.g or 0
      stats.all = stats.all + g
      if t >= dayStart      then stats.day   = stats.day   + g end
      if t >= now - 604800  then stats.week  = stats.week  + g end
      if t >= now - 2592000 then stats.month = stats.month + g end
    end
  end
  return stats, cd
end

--------------------------------------------------
-- Record repair
--------------------------------------------------
local function RecordRepair(copper, source)
  if copper <= 0 then return end
  local realm, name = GetCharInfo()
  local charKey = GetCharKey(realm, name)
  local _, classFile = UnitClass("player")
  local armorType = DetectArmorType()

  local cd = AccountRepairedDB[charKey]
  if not cd then
    AccountRepairedDB[charKey] = { class=classFile or "UNKNOWN", armorType=armorType, repairs={} }
    cd = AccountRepairedDB[charKey]
  end
  cd.class = classFile or cd.class or "UNKNOWN"
  if armorType ~= "Unknown" then cd.armorType = armorType end
  cd.armorType = cd.armorType or "Unknown"

  table.insert(cd.repairs, { t=time(), g=copper })

  local cutoff  = time() - DATA_RETENTION_SECONDS
  local repairs = cd.repairs
  local firstOK = 1
  while firstOK <= #repairs and (repairs[firstOK].t or 0) < cutoff do
    firstOK = firstOK + 1
  end
  if firstOK > 1 then
    local keep = #repairs - firstOK + 1
    table.move(repairs, firstOK, #repairs, 1)
    for i = keep + 1, #repairs do repairs[i] = nil end
  end

  local fundTag = (source == "guild") and "|cff33ff33[Guild]|r " or ""
  print(string.format("%s Repaired %sfor %s",
    L["FORMAT_NAME"], fundTag, FormatGoldFull(copper)))

  if AR.popupFrame and AR.popupFrame:IsShown() then
    AR.popupFrame:UpdateDisplay()
  end
  if AR.RefreshAPStrip then AR.RefreshAPStrip() end
end

--------------------------------------------------
-- Repair hook handlers
--------------------------------------------------
hooksecurefunc("RepairAllItems", function(useGuildFunds)
  if not inMerchant then return end

  if useGuildFunds then
    local cost = GetRepairAllCost()
    if cost and cost > 0 then
      RecordRepair(cost, "guild")
    end
    return
  end

  local cost = GetRepairAllCost()
  if not cost or cost <= 0 then return end
  repair.phase       = "WAITING_MONEY"
  repair.moneyBefore = GetMoney()
end)

if RepairItem then
  hooksecurefunc("RepairItem", function(_, useGuildFunds)
    if not inMerchant  then return end
    if useGuildFunds   then return end
    repair.phase       = "WAITING_MONEY"
    repair.moneyBefore = GetMoney()
  end)
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
    InitDB()
    C_Timer.After(2, RefreshCharArmorType)
    C_Timer.After(3, function()
      local stats = GetCurrentCharAllPeriods()
      print(string.format("%s %s|cffFFD700%s|r %s|cffFFD700%s|r |cffffA500/arepaired|r",
        L["FORMAT_NAME"], L["LOGIN_TODAY"], FormatGoldShort(stats.day),
        L["LOGIN_WEEK"], FormatGoldShort(stats.week)))
    end)
    C_Timer.After(1, AR.TryInjectAccountPlayedButton)

  elseif event == "ITEM_DATA_LOAD_RESULT" then
    if pendingArmorDetect then
      pendingArmorDetect = false
      RefreshCharArmorType()
    end

  elseif event == "MERCHANT_SHOW" then
    inMerchant = true
    ResetRepairState()

  elseif event == "MERCHANT_CLOSED" then
    inMerchant = false
    ResetRepairState()

  elseif event == "PLAYER_EQUIPMENT_CHANGED" then
    C_Timer.After(0.5, RefreshCharArmorType)

  elseif event == "PLAYER_MONEY" then
    if inMerchant and repair.phase == "WAITING_MONEY" then
      local delta = repair.moneyBefore - GetMoney()
      if delta > 0 then
        RecordRepair(delta, "personal")
      end
      ResetRepairState()
    end

    if AR.popupFrame and AR.popupFrame:IsShown() then
      AR.popupFrame:UpdateDisplay()
    end
  end
end)

--------------------------------------------------
-- Delete character
--------------------------------------------------
StaticPopupDialogs["ACCOUNTREPAIRED_CONFIRM_DELETE"] = {
  text     = "",
  button1  = DELETE,
  button2  = CANCEL,
  OnAccept = function(self, data)
    if not (data and data.foundKey) then return end
    AccountRepairedDB[data.foundKey] = nil
    print("|cff00ff00" .. string.format(L["CMD_DELETE_SUCCESS"], data.foundKey) .. "|r")
    if AR.popupFrame and AR.popupFrame:IsShown() then
      AR.popupFrame:UpdateDisplay()
    end
  end,
  timeout        = 0,
  whileDead      = true,
  hideOnEscape   = true,
  preferredIndex = 3,
}

local function ConfirmDeleteKey(foundKey)
  StaticPopupDialogs["ACCOUNTREPAIRED_CONFIRM_DELETE"].text =
    string.format(L["CMD_DELETE_CONFIRM"], foundKey)
  StaticPopup_Show("ACCOUNTREPAIRED_CONFIRM_DELETE", nil, nil, { foundKey=foundKey })
end

local function DeleteCharacter(input)
  input = (input or ""):match("^%s*(.-)%s*$")
  local charName, realmName = input:match("^([^%-]+)%-(.+)$")
  if not charName then
    print("|cffff9900" .. L["CMD_DELETE_USAGE"] .. "|r")
    return
  end
  local target = (realmName .. "-" .. charName):lower()
  local found
  for k in pairs(AccountRepairedDB) do
    if k:lower() == target then found = k; break end
  end
  if found then
    ConfirmDeleteKey(found)
  else
    print("|cffff0000" .. string.format(L["CMD_DELETE_NOT_FOUND"], input) .. "|r")
  end
end

SLASH_ACCOUNTREPAIREDDELETE1 = "/ardelete"
SlashCmdList.ACCOUNTREPAIREDDELETE = DeleteCharacter

--------------------------------------------------
-- Chat sharing
--------------------------------------------------

-- Returns the trailing phrase used in shared messages, e.g. "in Last 7 Days"
local function GetPeriodTailLabel(period)
  if period == "day"   then return "Today" end
  if period == "week"  then return "in Last 7 Days" end
  if period == "month" then return "in Last 30 Days" end
  return "Total Repair Bill"   -- "all"
end

-- New format (one line per character):
--   chat : Account Repaired: Name (ArmorType) Xg Xs Xc in Last 7 Days
--   print: Account Repaired: Name (ArmorType) Xg Xs Xc in Last 7 Days  (with class colour on name)
local function SendRepairBreakdown(armorType, channel)
  local chars = GetCharactersByArmorType(armorType, AR.currentPeriod)
  if #chars == 0 then return end

  local armorLabel = L["ARMOR_" .. armorType] or armorType
  local tail       = GetPeriodTailLabel(AR.currentPeriod)

  if channel == "NONE" then
    for _, ch in ipairs(chars) do
      local cc = RAID_CLASS_COLORS[ch.class] or { r=1, g=1, b=1 }
      print(string.format(
        "|cffAAAAAAAAccount Repaired:|r |cff%02x%02x%02x%s|r |cffAAAAAA(%s)|r [%s] %s",
        cc.r * 255, cc.g * 255, cc.b * 255,
        ch.name, armorLabel, FormatGoldFull(ch.gold), tail))
    end
  else
    for _, ch in ipairs(chars) do
      SendChatMessage(string.format(
        "Account Repaired: %s (%s): %s %s",
        ch.name, armorLabel, FormatGoldPlain(ch.gold), tail),
        channel)
    end
  end
end

--------------------------------------------------
-- Channel picker (lazy, created once)
--------------------------------------------------
local function GetOrCreateChannelPicker()
  if AR.channelPicker then return AR.channelPicker end

  local BTN_H    = 22
  local PAD      = 6
  local HEADER_H = 24
  local PICKER_W = 150
  local totalH   = HEADER_H + PAD + (#CHAT_CHANNELS + 1) * BTN_H + PAD * 2

  local p = CreateFrame("Frame", "AccountRepairedChannelPicker", UIParent, "BackdropTemplate")
  p:SetSize(PICKER_W, totalH)
  p:SetFrameStrata("TOOLTIP")
  p:SetFrameLevel(200)
  p:SetClampedToScreen(true)
  p:SetBackdrop({
    bgFile   = "Interface\\ChatFrame\\ChatFrameBackground",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile=true, tileSize=32, edgeSize=24,
    insets={ left=8, right=8, top=8, bottom=8 },
  })
  p:SetBackdropColor(0.05, 0.05, 0.05, 0.96)

  local title = p:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  title:SetPoint("TOPLEFT",  p, "TOPLEFT",  10, -8)
  title:SetPoint("TOPRIGHT", p, "TOPRIGHT", -10, -8)
  title:SetJustifyH("CENTER")
  title:SetText("Send to")
  title:SetTextColor(0.75, 0.75, 0.75)

  local function AddDivider(yOff)
    local sep = p:CreateTexture(nil, "ARTWORK")
    sep:SetHeight(1)
    sep:SetPoint("TOPLEFT",  p, "TOPLEFT",  10, yOff)
    sep:SetPoint("TOPRIGHT", p, "TOPRIGHT", -10, yOff)
    sep:SetColorTexture(0.4, 0.4, 0.4, 0.6)
  end
  AddDivider(-(HEADER_H - 2))

  local function AddPickerButton(yOff, label, r, g, b, onClick)
    local btn = CreateFrame("Button", nil, p)
    btn:SetHeight(BTN_H)
    btn:SetPoint("TOPLEFT",  p, "TOPLEFT",  10, yOff)
    btn:SetPoint("TOPRIGHT", p, "TOPRIGHT", -10, yOff)
    local hl = btn:CreateTexture(nil, "BACKGROUND")
    hl:SetAllPoints()
    hl:SetColorTexture(r, g, b, 0)
    local lbl = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    lbl:SetAllPoints()
    lbl:SetJustifyH("CENTER")
    lbl:SetText(label)
    lbl:SetTextColor(r, g, b)
    btn:SetScript("OnEnter", function() hl:SetColorTexture(r, g, b, 0.18) end)
    btn:SetScript("OnLeave", function() hl:SetColorTexture(r, g, b, 0)    end)
    btn:SetScript("OnClick", onClick)
    return btn
  end

  local function HidePicker()
    p.pendingArmorType = nil
    p:Hide()
  end

  for i, chan in ipairs(CHAT_CHANNELS) do
    local yOff = -(HEADER_H + PAD + (i - 1) * BTN_H)
    if chan.key == "NONE" then AddDivider(yOff + 1) end
    local cr, cg, cb = chan.color[1], chan.color[2], chan.color[3]
    AddPickerButton(yOff, chan.label, cr, cg, cb, function()
      PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
      if p.pendingArmorType then
        SendRepairBreakdown(p.pendingArmorType, chan.key)
      end
      HidePicker()
    end)
  end

  local cancelY = -(HEADER_H + PAD + #CHAT_CHANNELS * BTN_H + PAD)
  AddDivider(cancelY + 1)
  AddPickerButton(cancelY, "|cffff6060" .. CANCEL .. "|r", 0.8, 0.2, 0.2, function()
    PlaySound(SOUNDKIT.IG_MAINMENU_CLOSE)
    HidePicker()
  end)

  p:EnableKeyboard(true)
  p:SetScript("OnKeyDown", function(self, key)
    if key == "ESCAPE" then HidePicker() end
  end)
  p:Hide()
  AR.channelPicker = p
  table.insert(UISpecialFrames, "AccountRepairedChannelPicker")
  return p
end

local function ShowChannelPicker(anchorRow, armorType)
  local picker = GetOrCreateChannelPicker()
  picker.pendingArmorType = armorType
  picker:ClearAllPoints()
  picker:SetPoint("TOPLEFT", anchorRow, "BOTTOMLEFT", 0, -4)
  picker:Show()
  if picker:GetBottom() and picker:GetBottom() < 0 then
    picker:ClearAllPoints()
    picker:SetPoint("BOTTOMLEFT", anchorRow, "TOPLEFT", 0, 4)
  end
end

--------------------------------------------------
-- Bar row
--------------------------------------------------
local function CreateBarRow(parent, width)
  local row = CreateFrame("Button", nil, parent)
  row:SetSize(width, BAR_ROW_H)
  row:EnableMouse(true)
  row:RegisterForClicks("LeftButtonUp", "RightButtonUp")

  row.highlight = row:CreateTexture(nil, "BACKGROUND")
  row.highlight:SetAllPoints()
  row.highlight:SetColorTexture(1, 1, 1, 0.1)
  row.highlight:Hide()

  row.labelText = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  row.labelText:SetPoint("LEFT", 0, 0)
  row.labelText:SetWidth(80)
  row.labelText:SetJustifyH("LEFT")

  row.bar = CreateFrame("StatusBar", nil, row)
  row.bar:SetPoint("LEFT", row.labelText, "RIGHT", 6, 0)
  row.bar:SetPoint("RIGHT", row, "RIGHT", -160, 0)
  row.bar:SetHeight(BAR_ROW_H - 6)
  row.bar:SetMinMaxValues(0, 1)
  row.bar:SetValue(0)
  row.bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
  row.bar.bg = row.bar:CreateTexture(nil, "BACKGROUND")
  row.bar.bg:SetAllPoints()
  row.bar.bg:SetColorTexture(0, 0, 0, 0.4)

  row.pctText = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  row.pctText:SetPoint("LEFT", row.bar, "RIGHT", 8, 0)
  row.pctText:SetWidth(52)
  row.pctText:SetJustifyH("RIGHT")

  row.goldText = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  row.goldText:SetPoint("LEFT", row.pctText, "RIGHT", 6, 0)
  row.goldText:SetWidth(102)
  row.goldText:SetJustifyH("LEFT")

  row:SetScript("OnEnter", function(self)
    self.highlight:Show()
    if not self.armorType then return end
    local chars = GetCharactersByArmorType(self.armorType, AR.currentPeriod)
    if #chars == 0 then GameTooltip:Hide(); return end
    local col = ARMOR_COLORS[self.armorType] or ARMOR_COLORS.Unknown
    local periodCtx = GetPeriodContextLabel(AR.currentPeriod)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:AddLine(
      string.format("%s |cff888888(%s)|r", L["ARMOR_" .. self.armorType] or self.armorType, periodCtx),
      col.r, col.g, col.b)
    GameTooltip:AddLine(" ")
    for _, ch in ipairs(chars) do
      local cc = RAID_CLASS_COLORS[ch.class] or { r=1, g=1, b=1 }
      GameTooltip:AddDoubleLine(ch.name, FormatGoldFull(ch.gold),
        cc.r, cc.g, cc.b, 1, 1, 1)
    end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine(L["CLICK_TO_SHARE"] or "Click to share in chat",   0.5, 0.5, 0.5)
    GameTooltip:AddLine(L["RCLICK_CHAR_LIST"] or "Right-click for details", 0.5, 0.5, 0.5)
    GameTooltip:Show()
  end)

  row:SetScript("OnLeave", function(self)
    self.highlight:Hide()
    GameTooltip:Hide()
  end)

  row:SetScript("OnClick", function(self, button)
    if not self.armorType then return end
    GameTooltip:Hide()
    PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
    if button == "RightButton" then
      AR.ShowCharPanel(self.armorType, false, self)
    else
      ShowChannelPicker(self, self.armorType)
    end
  end)

  return row
end

--------------------------------------------------
-- Character list panel
--------------------------------------------------
local function CreateListPanel(name)
  local p = CreateFrame("Frame", name, UIParent, "BackdropTemplate")
  p:SetWidth(CPANEL_W)
  p:SetHeight(CPANEL_HEADER_H + CPANEL_PAD)
  p:SetFrameStrata("DIALOG")
  p:SetFrameLevel(110)
  p:SetClampedToScreen(true)
  p:SetBackdrop({
    bgFile   = "Interface\\ChatFrame\\ChatFrameBackground",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile=true, tileSize=32, edgeSize=24,
    insets={ left=8, right=8, top=8, bottom=8 },
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
    if p == AR.charPanel then AR.charPanelArmor = nil end
  end)

  local div = p:CreateTexture(nil, "ARTWORK")
  div:SetHeight(1)
  div:SetPoint("TOPLEFT",  p, "TOPLEFT",  10, -(CPANEL_HEADER_H - 2))
  div:SetPoint("TOPRIGHT", p, "TOPRIGHT", -10, -(CPANEL_HEADER_H - 2))
  div:SetColorTexture(0.4, 0.4, 0.4, 0.8)

  p.rows = {}
  for i = 1, 20 do
    local yOff = -(CPANEL_HEADER_H + CPANEL_PAD + (i - 1) * CPANEL_ROW_H)
    local row = CreateFrame("Frame", nil, p)
    row:SetHeight(CPANEL_ROW_H)
    row:SetPoint("TOPLEFT",  p, "TOPLEFT",  10, yOff)
    row:SetPoint("TOPRIGHT", p, "TOPRIGHT", -10, yOff)

    row.bg = row:CreateTexture(nil, "BACKGROUND")
    row.bg:SetAllPoints()
    row.bg:SetColorTexture(1, 1, 1, 0)

    row.nameText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.nameText:SetPoint("LEFT",  row, "LEFT",   0, 0)
    row.nameText:SetPoint("RIGHT", row, "RIGHT", -120, 0)
    row.nameText:SetJustifyH("LEFT")
    row.nameText:SetWordWrap(false)

    row.goldText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.goldText:SetPoint("RIGHT", row, "RIGHT", -52, 0)
    row.goldText:SetWidth(80)
    row.goldText:SetJustifyH("RIGHT")
    row.goldText:SetTextColor(0.85, 0.85, 0.85)

    local trashBtn = CreateFrame("Button", nil, row)
    trashBtn:SetSize(44, 18)
    trashBtn:SetPoint("RIGHT", row, "RIGHT", 0, 0)
    local trashLbl = trashBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    trashLbl:SetAllPoints()
    trashLbl:SetText("|cffff4040" .. DELETE .. "|r")
    trashLbl:SetJustifyH("CENTER")
    trashBtn:SetWidth(trashLbl:GetStringWidth() + 8)
    row.trashBtn = trashBtn

    row:Hide()
    p.rows[i] = row
  end

  p:Hide()
  table.insert(UISpecialFrames, name)
  return p
end

local function CreateCharPanel()
  if AR.charPanel then return AR.charPanel end
  local p = CreateListPanel("AccountRepairedCharPanel")

  for _, row in ipairs(p.rows) do
    row.trashBtn:SetScript("OnEnter", function()
      row.bg:SetColorTexture(1, 0.25, 0.25, 0.15)
      GameTooltip:SetOwner(row.trashBtn, "ANCHOR_RIGHT")
      GameTooltip:SetText(L["CHAR_PANEL_REMOVE_TIP"], 1, 0.35, 0.35)
      GameTooltip:Show()
    end)
    row.trashBtn:SetScript("OnLeave", function()
      row.bg:SetColorTexture(1, 1, 1, 0)
      GameTooltip:Hide()
    end)
    row.trashBtn:SetScript("OnClick", function()
      if row.charKey then ConfirmDeleteKey(row.charKey) end
    end)
  end

  AR.charPanel = p
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
    local anchor = (AR.popupFrame and AR.popupFrame:IsShown()) and AR.popupFrame or UIParent
    local pt     = AR.popupFrame and AR.popupFrame:IsShown() and "TOPRIGHT" or "CENTER"
    p:SetPoint("TOPLEFT", anchor, pt, AR.popupFrame and 4 or 0, 0)
  end

  local col = ARMOR_COLORS[armorType] or ARMOR_COLORS.Unknown
  p.titleText:SetText(L["ARMOR_" .. armorType] or armorType)
  p.titleText:SetTextColor(col.r, col.g, col.b)

  for i, row in ipairs(p.rows) do
    local ch = chars[i]
    if ch then
      local cc = RAID_CLASS_COLORS[ch.class] or { r=1, g=1, b=1 }
      row.nameText:SetText(ch.name)
      row.nameText:SetTextColor(cc.r, cc.g, cc.b)
      row.goldText:SetText(FormatGoldShort(ch.gold))
      row.charKey = ch.key
      row:Show()
    else
      row.charKey = nil
      row:Hide()
    end
  end
  p:SetHeight(CPANEL_HEADER_H + CPANEL_PAD + #chars * CPANEL_ROW_H + CPANEL_PAD)
  p:Show()
end

--------------------------------------------------
-- Period tab bar
--------------------------------------------------
local function CreatePeriodTabs(parent, onSelect)
  local tabs = {}
  local tabW, tabH, pad = 76, 24, 6
  local container = CreateFrame("Frame", nil, parent)
  container:SetSize(#PERIOD_ORDER * (tabW + pad) - pad, tabH)

  for i, period in ipairs(PERIOD_ORDER) do
    local tab = CreateFrame("Button", nil, container, "BackdropTemplate")
    tab:SetSize(tabW, tabH)
    tab:SetPoint("LEFT", container, "LEFT", (i - 1) * (tabW + pad), 0)
    tab:SetBackdrop({
      bgFile   = "Interface\\ChatFrame\\ChatFrameBackground",
      edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
      tile=true, tileSize=16, edgeSize=12,
      insets={ left=4, right=4, top=4, bottom=4 },
    })
    tab.label = tab:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    tab.label:SetAllPoints()
    tab.label:SetJustifyH("CENTER")
    tab.label:SetText(GetPeriodLabel(period))
    tab.period = period

    function tab:UpdateState()
      if self.period == AR.currentPeriod then
        self:SetBackdropColor(0.25, 0.75, 0.25, 0.4)
        self.label:SetTextColor(0.2, 1.0, 0.2)
      else
        self:SetBackdropColor(0.1, 0.1, 0.1, 0.7)
        self.label:SetTextColor(0.8, 0.8, 0.8)
      end
    end

    tab:SetScript("OnClick", function(self)
      AR.currentPeriod = self.period
      AccountRepairedPopupDB.period = self.period
      PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
      onSelect(self.period)
      for _, t in ipairs(tabs) do t:UpdateState() end
    end)

    tab:SetScript("OnEnter", function(self)
      GameTooltip:SetOwner(self, "ANCHOR_TOP")
      GameTooltip:AddLine(GetPeriodLabel(self.period), 1, 1, 1)
      GameTooltip:AddLine(GetPeriodContextLabel(self.period), 0.6, 0.6, 0.6)
      GameTooltip:Show()
    end)

    tab:SetScript("OnLeave", function() GameTooltip:Hide() end)

    tab:UpdateState()
    tabs[i] = tab
  end

  return container, tabs
end

--------------------------------------------------
-- Main popup window
--------------------------------------------------
local function CreatePopup()
  if AR.popupFrame then return AR.popupFrame end

  local f = CreateFrame("Frame", "AccountRepairedPopup", UIParent, "BackdropTemplate")
  f:SetSize(DB.width, FIXED_H)
  f:SetPoint(DB.point, UIParent, DB.point, DB.x, DB.y)
  f:SetFrameStrata("DIALOG")
  f:SetFrameLevel(100)
  f:SetClampedToScreen(true)
  f:SetMovable(true)
  f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", f.StartMoving)
  f:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local pt, _, _, x, y = self:GetPoint()
    DB.point = pt; DB.x = x; DB.y = y
  end)
  -- Width-only resizing
  f:SetResizable(true)
  if f.SetResizeBounds then
    f:SetResizeBounds(MIN_W, FIXED_H, MAX_W, FIXED_H)
  elseif f.SetMinResize then
    f:SetMinResize(MIN_W, FIXED_H)
    f:SetMaxResize(MAX_W, FIXED_H)
  end
  f:SetBackdrop({
    bgFile   = "Interface\\ChatFrame\\ChatFrameBackground",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile=true, tileSize=32, edgeSize=32,
    insets={ left=11, right=12, top=12, bottom=11 },
  })
  f:SetBackdropColor(0, 0, 0, 0.55)

  f.title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
  f.title:SetPoint("TOP", f, "TOP", 0, -12)
  f.title:SetText(L["WINDOW_TITLE"])

  local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
  closeBtn:SetPoint("TOPRIGHT", -10, -10)
  closeBtn:SetScript("OnClick", function()
    PlaySound(SOUNDKIT.IG_MAINMENU_CLOSE)
    f:Hide()
  end)

  f:SetScript("OnHide", function()
    if AR.charPanel then AR.charPanel:Hide() end
    AR.charPanelArmor = nil
  end)
  table.insert(UISpecialFrames, "AccountRepairedPopup")

  -- Right-edge drag grip for width-only resizing
  local br = CreateFrame("Frame", nil, f)
  br:SetSize(16, 16)
  br:SetPoint("BOTTOMRIGHT", -6, 6)
  br:EnableMouse(true)
  local brTex = br:CreateTexture(nil, "OVERLAY")
  brTex:SetAllPoints()
  brTex:SetTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
  local brHiTex = br:CreateTexture(nil, "HIGHLIGHT")
  brHiTex:SetAllPoints()
  brHiTex:SetTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
  br:SetScript("OnMouseDown", function(self, btn)
    if btn == "LeftButton" then f:StartSizing("RIGHT") end
  end)
  br:SetScript("OnMouseUp", function()
    f:StopMovingOrSizing()
    -- Clamp width, restore fixed height
    DB.width = math.max(MIN_W, math.min(f:GetWidth(), MAX_W))
    f:SetSize(DB.width, FIXED_H)
    -- Re-layout bar rows to match new content width
    local cw = f.content:GetWidth()
    for _, row in ipairs(AR.popupRows) do row:SetWidth(cw) end
  end)
  f.resizeGrip = br

  -- Width changes update bar row widths; height is always clamped back to FIXED_H
  f:SetScript("OnSizeChanged", function(self, w, h)
    if h ~= FIXED_H then self:SetHeight(FIXED_H) end
    local cw = w - 44
    if self.content then self.content:SetWidth(cw) end
    for _, row in ipairs(AR.popupRows) do row:SetWidth(cw) end
  end)

  local tabContainer, tabRefs = CreatePeriodTabs(f, function()
    f:UpdateDisplay()
  end)
  tabContainer:SetPoint("TOP", f.title, "BOTTOM", 0, -8)
  f.tabs    = tabContainer
  f.tabRefs = tabRefs

  -- Current-character strip
  local strip = CreateFrame("Frame", nil, f, "BackdropTemplate")
  strip:SetPoint("TOPLEFT",  f, "TOPLEFT",  14, POPUP_STRIP_Y)
  strip:SetPoint("TOPRIGHT", f, "TOPRIGHT", -14, POPUP_STRIP_Y)
  strip:SetHeight(36)
  strip:SetBackdrop({
    bgFile   = "Interface\\ChatFrame\\ChatFrameBackground",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile=true, tileSize=16, edgeSize=10,
    insets={ left=3, right=3, top=3, bottom=3 },
  })
  strip:SetBackdropColor(0.08, 0.08, 0.08, 0.80)
  strip.nameText = strip:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  strip.nameText:SetPoint("LEFT", strip, "LEFT", 10, 0)
  strip.nameText:SetWidth(160)
  strip.nameText:SetJustifyH("LEFT")
  strip.statsText = strip:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  strip.statsText:SetPoint("LEFT",  strip.nameText, "RIGHT", 8, 0)
  strip.statsText:SetPoint("RIGHT", strip, "RIGHT", -8, 0)
  strip.statsText:SetJustifyH("LEFT")
  strip.statsText:SetTextColor(0.85, 0.85, 0.85)
  f.charStrip = strip

  -- Plain content frame (no scroll frame)
  local content = CreateFrame("Frame", nil, f)
  content:SetPoint("TOPLEFT",     f, "TOPLEFT",     14, POPUP_BARS_Y)
  content:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -14, 50)
  f.content = content

  -- Total label
  f.totalRow = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  f.totalRow:SetPoint("BOTTOMLEFT", 15, 18)
  f.totalRow:SetTextColor(1, 1, 1)

  -- Account Played companion button
  local apBtn = CreateFrame("Button", nil, f, "BackdropTemplate")
  apBtn:SetSize(120, 20)
  apBtn:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -15, 16)
  apBtn:SetBackdrop({
    bgFile   = "Interface\\ChatFrame\\ChatFrameBackground",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile=true, tileSize=16, edgeSize=10,
    insets={ left=3, right=3, top=3, bottom=3 },
  })
  apBtn:SetBackdropColor(0.05, 0.05, 0.05, 0.85)
  apBtn:SetBackdropBorderColor(0.4, 0.7, 1.0, 0.9)
  local apLbl = apBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  apLbl:SetAllPoints(); apLbl:SetJustifyH("CENTER")
  apLbl:SetText("|cff6699FFAccount Played|r")
  apBtn:SetScript("OnEnter", function(self)
    self:SetBackdropBorderColor(0.6, 0.85, 1.0, 1.0)
    self:SetBackdropColor(0.02, 0.08, 0.18, 0.95)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:AddLine("Account Played", 0.4, 0.70, 1.0)
    GameTooltip:AddLine("Switch to account played statistics", 0.65, 0.65, 0.65)

    local AP = LibStub and LibStub("AccountPlayed-1.0", true)
    if AP then
      local apTotal = AP:GetAccountTotal()
      local apChars = AP:GetAllCharacters()
      local totalDays = math.floor(apTotal / 86400 + 0.5)
      GameTooltip:AddLine(" ")
      GameTooltip:AddDoubleLine(
        string.format("|cffAAAAAATotal:|r %dd", totalDays),
        string.format("|cffAAAAAA%d chars tracked|r", #apChars),
        1, 1, 1, 0.65, 0.65, 0.65)
      for i = 1, math.min(3, #apChars) do
        local ch = apChars[i]
        local cc = RAID_CLASS_COLORS[ch.class] or { r=1, g=1, b=1 }
        GameTooltip:AddDoubleLine(
          string.format("|cff%02x%02x%02x%s|r",
            cc.r * 255, cc.g * 255, cc.b * 255, ch.name),
          AP:FormatTime(ch.time),
          1, 1, 1, 0.85, 0.85, 0.85)
      end
    end

    GameTooltip:Show()
  end)
  apBtn:SetScript("OnLeave", function(self)
    self:SetBackdropBorderColor(0.4, 0.7, 1.0, 0.9)
    self:SetBackdropColor(0.05, 0.05, 0.05, 0.85)
    GameTooltip:Hide()
  end)
  apBtn:SetScript("OnClick", function()
    PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
    f:Hide()
    if AccountPlayed and AccountPlayed.ToggleClassWindow then
      AccountPlayed.ToggleClassWindow()
    end
    C_Timer.After(0.05, function()
      if AR.RefreshAPStrip then AR.RefreshAPStrip() end
    end)
  end)
  apBtn:Hide()
  f.apBtn = apBtn

  -- Pre-create bar rows parented directly to content (no scroll child)
  for i = 1, #ARMOR_TYPE_NAMES do
    local row = CreateBarRow(content, content:GetWidth())
    row:SetPoint("TOPLEFT", 0, -(i - 1) * BAR_ROW_H)
    row:Hide()
    AR.popupRows[i] = row
  end

  f.UpdateDisplay = function(self)
    if AccountPlayed and AccountPlayed.ToggleClassWindow then
      self.apBtn:Show()
    else
      self.apBtn:Hide()
    end

    for _, tab in ipairs(self.tabRefs) do tab:UpdateState() end

    local realm, name = GetCharInfo()
    local _, classFile = UnitClass("player")
    local cc = (classFile and RAID_CLASS_COLORS[classFile]) or { r=1, g=1, b=1 }
    local stats, cd = GetCurrentCharAllPeriods()
    local armorSuffix = cd and
      ("|cffAAAAAA (" .. (L["ARMOR_" .. (cd.armorType or "Unknown")] or "?") .. ")|r") or ""
    self.charStrip.nameText:SetText(string.format("|cff%02x%02x%02x%s|r%s",
      cc.r * 255, cc.g * 255, cc.b * 255, name, armorSuffix))

    local function PL(key)
      local lbl = GetPeriodLabel(key)
      return key == AR.currentPeriod and ("|cff33ff33" .. lbl .. "|r") or lbl
    end
    self.charStrip.statsText:SetText(string.format(
      "%s: %s  %s: %s  %s: %s  %s: %s",
      PL("day"),   FormatGoldRounded(stats.day),
      PL("week"),  FormatGoldRounded(stats.week),
      PL("month"), FormatGoldRounded(stats.month),
      PL("all"),   FormatGoldRounded(stats.all)))

    local totals, acct = GetArmorTypeTotals(AR.currentPeriod)

    if acct == 0 then
      AR.popupRows[1].labelText:SetText("No Repairs Yet")
      AR.popupRows[1].bar:SetValue(0)
      AR.popupRows[1].pctText:SetText("")
      AR.popupRows[1].goldText:SetText("")
      AR.popupRows[1].armorType = nil
      AR.popupRows[1]:Show()
      for i = 2, #AR.popupRows do AR.popupRows[i]:Hide() end
      self.totalRow:SetText(L["TOTAL"] .. FormatGoldFull(0))
      return
    end

    local sorted = {}
    for _, at in ipairs(ARMOR_TYPE_NAMES) do
      if (totals[at] or 0) > 0 then
        table.insert(sorted, { armorType=at, gold=totals[at] })
      end
    end
    table.sort(sorted, function(a, b) return a.gold > b.gold end)
    local top = sorted[1].gold

    for i, row in ipairs(AR.popupRows) do
      local e = sorted[i]
      if e then
        local col = ARMOR_COLORS[e.armorType] or ARMOR_COLORS.Unknown
        row.armorType = e.armorType
        row.labelText:SetText(L["ARMOR_" .. e.armorType] or e.armorType)
        row.labelText:SetTextColor(col.r, col.g, col.b)
        row.bar:SetValue(e.gold / top)
        row.bar:SetStatusBarColor(col.r, col.g, col.b)
        row.pctText:SetText(string.format("%.1f%%", e.gold / acct * 100))
        row.goldText:SetText("- " .. FormatGoldRounded(e.gold))
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", 0, -(i - 1) * BAR_ROW_H)
        row:Show()
      else
        row.armorType = nil
        row:Hide()
      end
    end

    self.totalRow:SetText(L["TOTAL"] .. FormatGoldFull(acct))

    if AR.charPanel and AR.charPanel:IsShown() and AR.charPanelArmor then
      AR.ShowCharPanel(AR.charPanelArmor, true)
    end
  end

  f:Hide()
  AR.popupFrame = f
  return f
end

local function UpdatePopup()
  local f = CreatePopup()
  f:ClearAllPoints()
  f:SetPoint(DB.point, UIParent, DB.point, DB.x, DB.y)
  f:SetSize(DB.width, FIXED_H)
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
-- Account Played companion injection
--------------------------------------------------
local _apHooked = false

local function RefreshAPStrip() end
AR.RefreshAPStrip = RefreshAPStrip

AR.TryInjectAccountPlayedButton = function()
  if not (AccountPlayed and AccountPlayed.ToggleClassWindow) then return end
  if _apHooked then return end
  _apHooked = true

  local function InjectStrip()
    local apf = _G["AccountPlayedPopup"]
    if not apf or apf._arStrip then return end

    local btn = CreateFrame("Button", nil, apf, "BackdropTemplate")
    btn:SetSize(128, 20)
    btn:SetPoint("BOTTOM", apf, "BOTTOM", 0, 14)
    btn:SetBackdrop({
      bgFile   = "Interface\\ChatFrame\\ChatFrameBackground",
      edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
      tile=true, tileSize=16, edgeSize=10,
      insets={ left=3, right=3, top=3, bottom=3 },
    })
    btn:SetBackdropColor(0.06, 0.04, 0.01, 0.90)
    btn:SetBackdropBorderColor(1.0, 0.55, 0.1, 0.85)

    local lbl = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    lbl:SetAllPoints()
    lbl:SetJustifyH("CENTER")
    lbl:SetWordWrap(false)
    lbl:SetText("|cffFFAA33Account Repaired|r")

    btn:SetScript("OnEnter", function(self)
      self:SetBackdropBorderColor(1.0, 0.75, 0.3, 1.0)
      self:SetBackdropColor(0.14, 0.08, 0.01, 0.95)

      local stats = GetCurrentCharAllPeriods()
      local _, acctTotal = GetArmorTypeTotals("all")

      GameTooltip:SetOwner(self, "ANCHOR_TOP")
      GameTooltip:AddLine("Account Repaired", 1.0, 0.67, 0.2)
      GameTooltip:AddLine("Repair cost tracker - click to open", 0.65, 0.65, 0.65)
      GameTooltip:AddLine(" ")
      GameTooltip:AddLine(string.format(
        "|cffAAAAAAToday:|r %s  |cffAAAAAAWeek:|r %s  |cffAAAAAAMonth:|r %s",
        FormatGoldRounded(stats.day),
        FormatGoldRounded(stats.week),
        FormatGoldRounded(stats.month)), 1, 1, 1)

      GameTooltip:Show()
    end)

    btn:SetScript("OnLeave", function(self)
      self:SetBackdropBorderColor(1.0, 0.55, 0.1, 0.85)
      self:SetBackdropColor(0.06, 0.04, 0.01, 0.90)
      GameTooltip:Hide()
    end)

    btn:SetScript("OnClick", function()
      PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
      apf:Hide()
      AR.ToggleWindow()
    end)

    apf._arStrip = btn
  end

  hooksecurefunc(AccountPlayed, "ToggleClassWindow", function()
    C_Timer.After(0, function()
      InjectStrip()
      RefreshAPStrip()
    end)
  end)
  InjectStrip()
end

--------------------------------------------------
-- Debug command
--------------------------------------------------
SLASH_ACCOUNTREPAIREDDEBUG1 = "/ardebug"
SlashCmdList.ACCOUNTREPAIREDDEBUG = function()
  print("|cffff0000" .. L["DEBUG_HEADER"] .. "|r")
  for charKey, data in pairs(AccountRepairedDB) do
    if type(data) == "table" then
      local total = 0
      for _, e in ipairs(data.repairs or {}) do
        total = total + (e.g or 0)
      end
      print(string.format(
        " |cffffff00- %s [%s/%s] : %s (%d repairs)|r",
        charKey, data.class or "?", data.armorType or "?",
        FormatGoldFull(total), #(data.repairs or {})))
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
    print(L["FORMAT_NAME"] .. " /arepaired |cff888888" .. L["CMD_HELP_SHOW_DESC"] .. "|r")
    print(" |cffffff00/ardelete CharName-RealmName|r |cff888888" .. L["CMD_DELETE_USAGE_SHORT"] .. "|r")
    print(" |cffffff00/ardebug|r |cff888888" .. L["CMD_HELP_DEBUG_DESC"] .. "|r")
  end
end

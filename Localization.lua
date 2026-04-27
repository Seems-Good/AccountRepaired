--------------------------------------------------
-- Account Repaired – Localization (English base)
--------------------------------------------------
local _, addonTable = ...
addonTable.L = {}
local L = addonTable.L

--------------------------------------------------
-- Addon identity / chat formatting
--------------------------------------------------
local VERSION   = "@project-version@"
local COLOR_BLUE = "|cff00ccff"
local COLOR_GRAY = "|cff888888"

L["FORMAT_NAME"] = COLOR_BLUE .. "AccountRepaired|r" .. COLOR_GRAY .. "-(" .. VERSION .. ")|r"

-- Window
L["WINDOW_TITLE"]        = "Account Repaired"
L["TOTAL"]               = "Account Total: "
L["NO_DATA"]             = "No repair data yet. Visit a vendor and repair!"
L["CURRENT_CHAR_HEADER"] = "Current Character"
L["COLLAPSE_WINDOW"]     = "Collapse window"
L["EXPAND_WINDOW"]       = "Expand window"

-- Periods
L["PERIOD_DAY"]   = "Today"
L["PERIOD_WEEK"]  = "Week"
L["PERIOD_MONTH"] = "Month"
L["PERIOD_ALL"]   = "All Time"

-- Armor types
L["ARMOR_Cloth"]   = "Cloth"
L["ARMOR_Leather"] = "Leather"
L["ARMOR_Mail"]    = "Mail"
L["ARMOR_Plate"]   = "Plate"
L["ARMOR_Unknown"] = "Other"

-- Gold formatting
L["GOLD_ABBREV"]   = "g"
L["SILVER_ABBREV"] = "s"
L["COPPER_ABBREV"] = "c"

-- Char panel
L["CHAR_PANEL_REMOVE_TIP"]  = "Remove this character's data"
L["CHAR_PANEL_RIGHT_CLICK"] = "Right-click to manage characters"

-- Bar row tooltips
L["CLICK_TO_SHARE"]   = "Left-click to share in chat"
L["RCLICK_CHAR_LIST"] = "Right-click for character list"

-- Guild repair toggle
L["INCLUDE_GUILD_REPAIRS"] = "Guild Repairs"
L["GUILD_REPAIRS_TIP"]     = "Include repairs paid from the guild bank."

-- Login message
-- Shown once on PLAYER_LOGIN:
--   AccountRepaired-(v0.4.x)  Today: 1.2g  Week: 8.5g  /arepaired
L["LOGIN_TODAY"] = "Today: "
L["LOGIN_WEEK"]  = "Week: "
L["LOGIN_HINT"]  = "Type "   -- precedes the /arepaired hint

-- Commands
L["CMD_HELP_HEADER"]        = "Commands:"
L["CMD_HELP_SHOW_DESC"]     = "Toggle the repair tracking window"
L["CMD_HELP_DEBUG_DESC"]    = "Dump all character repair data to chat"
L["CMD_DELETE_USAGE"]       = "Usage: /ardelete CharName-RealmName"
L["CMD_DELETE_USAGE_SHORT"] = "Delete a character's repair history"
L["CMD_DELETE_CONFIRM"]     = "Delete repair data for %s?"
L["CMD_DELETE_SUCCESS"]     = "Deleted repair data for %s."
L["CMD_DELETE_NOT_FOUND"]   = "Character not found: %s"

-- Notifications
L["MSG_REPAIR_RECORDED"] = "Repair recorded: %s"
L["DB_CORRUPTED"]        = "AccountRepairedDB was corrupted and has been reset."

-- Debug
L["DEBUG_HEADER"] = "AccountRepaired – Character Data:"

-- Tooltips
L["TOOLTIP_CLICK_TOGGLE"] = "Click to toggle the repair window"

-- Misc
L["UNKNOWN"] = "Unknown"

-- ── Locale override example (zhCN) ──────────────────────────────────────────
-- local locale = GetLocale()
-- if locale == "zhCN" then
--     L["WINDOW_TITLE"]          = "账号修复记录"
--     L["INCLUDE_GUILD_REPAIRS"] = "公会修理"
--     L["GUILD_REPAIRS_TIP"]     = "包含由公会银行支付的修理费用。"
--     L["LOGIN_TODAY"]           = "今日: "
--     L["LOGIN_WEEK"]            = "本周: "
-- end

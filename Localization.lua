--------------------------------------------------
-- Account Repaired – Localization (English base)
-- v0.4.0: Added INCLUDE_GUILD_REPAIRS and GUILD_REPAIRS_TIP keys
--         that were referenced in code but absent from this file.
--------------------------------------------------
local _, addonTable = ...
addonTable.L = {}
local L = addonTable.L

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
L["CLICK_TO_PRINT"]         = "Left-click to print breakdown"

-- Guild repair toggle
-- but were never defined here, making them untranslatable.
L["INCLUDE_GUILD_REPAIRS"] = "Guild Repairs"
L["GUILD_REPAIRS_TIP"]     = "Include repairs paid from the guild bank."

-- Commands
L["CMD_HELP_HEADER"]       = "Commands:"
L["CMD_HELP_SHOW_DESC"]    = "Toggle the repair tracking window"
L["CMD_HELP_MINIMAP_DESC"] = "Toggle the minimap button"
L["CMD_HELP_RESET_DESC"]   = "Reset minimap button position"
L["CMD_DELETE_USAGE"]      = "Usage: /ardelete CharName-RealmName"
L["CMD_DELETE_CONFIRM"]    = "Delete repair data for %s?"
L["CMD_DELETE_SUCCESS"]    = "Deleted repair data for %s."
L["CMD_DELETE_NOT_FOUND"]  = "Character not found: %s"

-- Notifications
L["MSG_REPAIR_RECORDED"]  = "Repair recorded: %s"
L["MSG_MINIMAP_HIDDEN"]   = "Minimap button hidden. Type /arepaired minimap to show."
L["MSG_MINIMAP_SHOWN"]    = "Minimap button shown."
L["MSG_MINIMAP_NOT_INIT"] = "Minimap button not yet initialized."
L["DB_CORRUPTED"]         = "AccountRepairedDB was corrupted and has been reset."

-- Debug
L["DEBUG_HEADER"] = "AccountRepaired – Character Data:"

-- Tooltips
L["TOOLTIP_CLICK_TOGGLE"] = "Click to toggle the repair window"

-- Misc
L["UNKNOWN"] = "Unknown"

-- ── Locale override example (zhCN) ──────────────────────────────────────────
-- local locale = GetLocale()
-- if locale == "zhCN" then
--     L["WINDOW_TITLE"]            = "账号修复记录"
--     L["INCLUDE_GUILD_REPAIRS"]   = "公会修理"
--     L["GUILD_REPAIRS_TIP"]       = "包含由公会银行支付的修理费用。\n切换后图表立即更新。"
-- end

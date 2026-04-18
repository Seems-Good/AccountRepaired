--------------------------------------------------
-- Account Repaired - AccountPlayed Integration
--
-- Instead of a minimap button, this module injects
-- popup window.  Zero changes are needed to
-- AccountPlayed itself — we hook everything from here.
--
-- Slash commands from AccountRepaired.lua still work:
--   /arepaired show
--   /ardelete CharName-RealmName
--   /ardebug
--
--------------------------------------------------
local _, addonTable = ...
local L = addonTable.L

local AR = AccountRepaired

--------------------------------------------------
-- Button injection into AccountPlayedPopup
--------------------------------------------------

local BTN_W, BTN_H = 120, 20

local function BuildAPButton(apFrame)
    if apFrame.accountRepairedBtn then return end   -- already injected

    local btn = CreateFrame("Button", nil, apFrame, "BackdropTemplate")
    btn:SetSize(BTN_W, BTN_H)

    -- Bottom-center of the AccountPlayed window, sitting above the border
    btn:SetPoint("BOTTOM", apFrame, "BOTTOM", 0, 16)

    btn:SetBackdrop({
        bgFile   = "Interface\\ChatFrame\\ChatFrameBackground",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 10,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    btn:SetBackdropColor(0.05, 0.05, 0.05, 0.85)
    btn:SetBackdropBorderColor(0.8, 0.65, 0.1, 0.9)   -- gold border

    local label = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetAllPoints()
    label:SetJustifyH("CENTER")
    label:SetText("|cffFFD700Account Repaired|r")

    btn:SetScript("OnEnter", function(self)
        self:SetBackdropBorderColor(1.0, 0.85, 0.2, 1.0)
        self:SetBackdropColor(0.15, 0.13, 0.02, 0.95)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine("Account Repaired", 1, 0.82, 0)
        GameTooltip:AddLine("Track gold spent on repairs", 0.8, 0.8, 0.8)
        GameTooltip:Show()
    end)

    btn:SetScript("OnLeave", function(self)
        self:SetBackdropBorderColor(0.8, 0.65, 0.1, 0.9)
        self:SetBackdropColor(0.05, 0.05, 0.05, 0.85)
        GameTooltip:Hide()
    end)

    -- Click: close AccountPlayed, open AccountRepaired
    btn:SetScript("OnClick", function()
        PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
        if apFrame:IsShown() then
            apFrame:Hide()   -- AP's own OnHide handles charPanel cleanup
        end
        AR.ToggleWindow()
    end)

    apFrame.accountRepairedBtn = btn
end

--------------------------------------------------
-- Hook AccountPlayed's window without touching it
--------------------------------------------------
-- AccountPlayedPopup is created lazily on first /aplayed show.
-- hooksecurefunc fires AFTER the original function, so by the time
-- our callback runs the popup frame already exists and is visible.

local function TryHookAccountPlayed()
    if not AccountPlayed or not AccountPlayed.ToggleClassWindow then
        return   -- AccountPlayed not installed; nothing to do
    end

    hooksecurefunc(AccountPlayed, "ToggleClassWindow", function()
        local apFrame = _G["AccountPlayedPopup"]
        if apFrame then BuildAPButton(apFrame) end
    end)

    -- Handle the edge case where AP popup already exists on load
    local apFrame = _G["AccountPlayedPopup"]
    if apFrame then BuildAPButton(apFrame) end
end

--------------------------------------------------
-- Boot
--------------------------------------------------
local bootFrame = CreateFrame("Frame")
bootFrame:RegisterEvent("PLAYER_LOGIN")
bootFrame:SetScript("OnEvent", function(self)
    -- Wait one frame so all addons' PLAYER_LOGIN handlers finish first
    C_Timer.After(0, TryHookAccountPlayed)
    self:UnregisterEvent("PLAYER_LOGIN")
end)

--------------------------------------------------
-- Public stubs so /arepaired minimap and /arepaired reset
-- don't throw errors — they just print a friendly message.
--------------------------------------------------
AR.CreateMinimapButton = function() end
AR.ResetMinimapButton  = function()
    print("|cff00ff00Account Repaired:|r No minimap button — use |cffffff00/arepaired show|r or the button inside the Account Played window.")
end

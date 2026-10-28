if EUI_CLIENT_BLOCKED then return end -- pre-12.1 client failsafe (EllesmereUI_ClientGate.lua)
-------------------------------------------------------------------------------
--  EllesmereUIBags_Offline.lua
--  Offline Bank: a copy of every character's bags, character bank and the
--  warband bank, saved account-wide so the viewer (EllesmereUIBags_OfflineView
--  .lua) can show them anywhere, plus item counts in item tooltips.
--
--  Store: EllesmereUIBagsInventoryDB (its own SavedVariables, kept out of the
--  profiles so exports and profile sync never carry inventories).
--    chars[key] = { name, realm, class, level, bagsTime, bankTime,
--                   bags = { container... }, bank = { container... } }
--    warband    = { time, tabs = { container... } }
--    container  = { size, name?, icon?, links = { [slot] = link },
--                   counts = { [slot] = count } } (counts only above 1)
--  key = "Name-Realm" (EllesmereUI.RealmGroupName), the gold ledger's key.
--
--  Reads only: bags are copied after BAG_UPDATE_DELAYED, the banks while a
--  banker is open. Nothing is saved, hooked or listened to while both the
--  Offline Bank and Tooltip Item Counts options are off.
-------------------------------------------------------------------------------
local EUI = EllesmereUI
local ns = select(2, ...)
if EUI.IS_FOREVER then return end  -- retail bank tabs only

local _emptyP = {}
local function BP() return (EUI._bagsDB and EUI._bagsDB.profile) or _emptyP end

local Offline = {}
ns.Offline = Offline

function Offline.Enabled() return BP().bagOfflineBank ~= false end
function Offline.CountsEnabled() return BP().bagTooltipCounts ~= false end
local function Active() return Offline.Enabled() or Offline.CountsEnabled() end

-------------------------------------------------------------------------------
--  Store
-------------------------------------------------------------------------------
local rev = 0          -- bumped on every write; the tooltip index follows it
local listeners = {}

function Offline.Store()
    local db = _G.EllesmereUIBagsInventoryDB
    if type(db) ~= "table" then
        db = {}
        _G.EllesmereUIBagsInventoryDB = db
    end
    if type(db.chars) ~= "table" then db.chars = {} end
    if type(db.warband) ~= "table" then db.warband = { tabs = {} } end
    if type(db.warband.tabs) ~= "table" then db.warband.tabs = {} end
    return db
end

function Offline.CurrentKey()
    local name, realm = UnitName("player"), EUI.RealmGroupName()
    if not name or not realm then return nil end
    return name .. "-" .. realm
end

function Offline.Char(key) return key and Offline.Store().chars[key] end
function Offline.Warband() return Offline.Store().warband end
function Offline.Rev() return rev end

-- something changed: the viewer and the tooltip index catch up
local function Changed(what)
    rev = rev + 1
    for _, fn in ipairs(listeners) do fn(what) end
end
function Offline.OnChange(fn) listeners[#listeners + 1] = fn end

function Offline.Forget(key)
    if not key or key == Offline.CurrentKey() then return end
    Offline.Store().chars[key] = nil
    Changed("forget")
end

-- characters for the picker: realm, then name; the current one flagged
function Offline.Characters()
    local list, me = {}, Offline.CurrentKey()
    for key, c in pairs(Offline.Store().chars) do
        if type(c) == "table" then
            list[#list + 1] = { key = key, name = c.name or key, realm = c.realm or "", class = c.class, current = key == me }
        end
    end
    table.sort(list, function(a, b)
        if a.realm ~= b.realm then return a.realm < b.realm end
        return a.name < b.name
    end)
    return list
end

local function MyEntry()
    local key = Offline.CurrentKey()
    if not key then return nil end
    local chars = Offline.Store().chars
    local c = chars[key]
    if not c then c = {}; chars[key] = c end
    local _, class = UnitClass("player")
    c.name, c.realm, c.class, c.level = UnitName("player"), EUI.RealmGroupName(), class, UnitLevel("player")
    return c
end

-- one container's contents; nil when the game reports no slots
local function ReadContainer(bagID)
    local size = C_Container.GetContainerNumSlots(bagID) or 0
    if size <= 0 then return nil end
    local links, counts = {}, {}
    for slot = 1, size do
        local info = C_Container.GetContainerItemInfo(bagID, slot)
        local link = info and (info.hyperlink or C_Container.GetContainerItemLink(bagID, slot))
        if link then
            links[slot] = link
            if (info.stackCount or 1) > 1 then counts[slot] = info.stackCount end
        end
    end
    return { size = size, links = links, counts = counts }
end

-------------------------------------------------------------------------------
--  Snapshots
-------------------------------------------------------------------------------
local BAGS = { 0, 1, 2, 3, 4, 5 }
local CHAR_BANK, WARBAND_BANK = {}, {}
for i = 1, 6 do
    local id = Enum.BagIndex["CharacterBankTab_" .. i]
    if id then CHAR_BANK[#CHAR_BANK + 1] = id end
end
for i = 1, 5 do
    local id = Enum.BagIndex["AccountBankTab_" .. i]
    if id then WARBAND_BANK[#WARBAND_BANK + 1] = id end
end
local BANK_BAG = {}
for _, id in ipairs(CHAR_BANK) do BANK_BAG[id] = "bank" end
for _, id in ipairs(WARBAND_BANK) do BANK_BAG[id] = "warband" end

local function SaveBags()
    local c = MyEntry()
    if not c then return end
    local bags = {}
    for _, bag in ipairs(BAGS) do bags[#bags + 1] = ReadContainer(bag) or false end
    c.bags, c.bagsTime = bags, time()
    Changed("bags")
end

-- bank tabs with their names and icons; nil when nothing is readable yet
local function ReadTabs(bagIDs, bankType)
    local meta = C_Bank and C_Bank.FetchPurchasedBankTabData and C_Bank.FetchPurchasedBankTabData(bankType)
    local tabs, any = {}, false
    for i, bagID in ipairs(bagIDs) do
        local t = ReadContainer(bagID)
        if t then
            any = true
            local m = meta and meta[i]
            t.name = m and m.name
            t.icon = m and m.icon
            tabs[#tabs + 1] = t
        end
    end
    return any and tabs or nil
end

local atBank, atCharBank = false, false

local function SaveBanks()
    if not atBank then return end
    local changed = false
    if atCharBank then
        local tabs = ReadTabs(CHAR_BANK, Enum.BankType.Character)
        local c = tabs and MyEntry()
        if c then c.bank, c.bankTime, changed = tabs, time(), true end
    end
    local locked = C_Bank and C_Bank.FetchBankLockedReason and C_Bank.FetchBankLockedReason(Enum.BankType.Account)
    if locked == nil then
        local tabs = ReadTabs(WARBAND_BANK, Enum.BankType.Account)
        if tabs then
            local w = Offline.Store().warband
            w.tabs, w.time, changed = tabs, time(), true
        end
    end
    if changed then Changed("bank") end
end

-- a burst of updates saves once
local pendingBags, pendingBank = false, false
local function Flush()
    if pendingBags then pendingBags = false; SaveBags() end
    if pendingBank then pendingBank = false; SaveBanks() end
end
local flushQueued = false
local function Queue(bags, bank)
    if bags then pendingBags = true end
    if bank then pendingBank = true end
    if flushQueued then return end
    flushQueued = true
    C_Timer.After(0.5, function() flushQueued = false; Flush() end)
end

-------------------------------------------------------------------------------
--  Events (registered only while an option needs them)
-------------------------------------------------------------------------------
local PIT = Enum.PlayerInteractionType
local ev = CreateFrame("Frame")
ev:SetScript("OnEvent", function(_, event, arg)
    if event == "BAG_UPDATE_DELAYED" then
        Queue(true, atBank)
    elseif event == "BAG_UPDATE" then
        if atBank and BANK_BAG[arg] then Queue(false, true) end
    elseif event == "PLAYER_INTERACTION_MANAGER_FRAME_SHOW" then
        if arg == PIT.Banker or arg == PIT.AccountBanker then
            atBank, atCharBank = true, arg == PIT.Banker
            Queue(false, true)
        end
    elseif event == "PLAYER_INTERACTION_MANAGER_FRAME_HIDE" then
        if arg == PIT.Banker or arg == PIT.AccountBanker then
            Flush()  -- before the contents go unreadable
            atBank, atCharBank = false, false
        end
    elseif event == "PLAYERBANKSLOTS_CHANGED" or event == "PLAYER_ACCOUNT_BANK_TAB_SLOTS_CHANGED"
        or event == "BANK_TABS_CHANGED" then
        if atBank then Queue(false, true) end
    end
end)
local EVENTS = { "BAG_UPDATE_DELAYED", "BAG_UPDATE", "PLAYER_INTERACTION_MANAGER_FRAME_SHOW",
    "PLAYER_INTERACTION_MANAGER_FRAME_HIDE", "PLAYERBANKSLOTS_CHANGED",
    "PLAYER_ACCOUNT_BANK_TAB_SLOTS_CHANGED", "BANK_TABS_CHANGED" }
local listening = false
function Offline.Sync()
    local on = Active()
    if on == listening then return end
    listening = on
    for _, e in ipairs(EVENTS) do
        if on then pcall(ev.RegisterEvent, ev, e) else ev:UnregisterEvent(e) end
    end
    if on then Queue(true, false) end
    if Offline.SyncTooltip then Offline.SyncTooltip() end
    if Offline.SyncButton then Offline.SyncButton() end
end

-------------------------------------------------------------------------------
--  Tooltip item counts
-------------------------------------------------------------------------------
-- the item id behind a link (cages count as the pet cage item)
local function LinkID(link)
    local kind, id = link:match("|H(%a+):(%d+)")
    if kind == "battlepet" then return 82800 end
    return tonumber(id)
end
Offline.LinkID = LinkID

local index, indexRev  -- itemID -> { [key] = { bags, bank } }, warband[itemID]

local function AddContainers(list, into, field, owner)
    if type(list) ~= "table" then return end
    for _, t in ipairs(list) do
        if type(t) == "table" and type(t.links) == "table" then
            for slot, link in pairs(t.links) do
                local id = LinkID(link)
                if id then
                    local n = (t.counts and t.counts[slot]) or 1
                    local row = into[id]
                    if not row then row = {}; into[id] = row end
                    if owner then
                        local e = row[owner]
                        if not e then e = { bags = 0, bank = 0 }; row[owner] = e end
                        e[field] = e[field] + n
                    else
                        row.n = (row.n or 0) + n
                    end
                end
            end
        end
    end
end

local function Index()
    if index and indexRev == rev then return index end
    local chars, war = {}, {}
    local db = Offline.Store()
    for key, c in pairs(db.chars) do
        if type(c) == "table" then
            AddContainers(c.bags, chars, "bags", key)
            AddContainers(c.bank, chars, "bank", key)
        end
    end
    AddContainers(db.warband.tabs, war)
    index, indexRev = { chars = chars, warband = war }, rev
    return index
end

local function ClassHex(class)
    local c = class and C_ClassColor and C_ClassColor.GetClassColor(class)
    return c and c:GenerateHexColorMarkup() or "|cffffffff"
end

local function OnItemTooltip(tooltip, data)
    if not (listening and Offline.CountsEnabled()) then return end
    if tooltip ~= GameTooltip and tooltip ~= ItemRefTooltip then return end
    if tooltip:IsForbidden() then return end
    local id = data and data.id
    if type(id) ~= "number" or (issecretvalue and issecretvalue(id)) then return end
    local idx = Index()
    local row, war = idx.chars[id], idx.warband[id]
    if not row and not war then return end

    local db, lines, total = Offline.Store(), {}, 0
    for key, e in pairs(row or {}) do
        local c = db.chars[key]
        if c and (e.bags + e.bank) > 0 then
            lines[#lines + 1] = { c, e }
            total = total + e.bags + e.bank
        end
    end
    table.sort(lines, function(a, b) return (a[2].bags + a[2].bank) > (b[2].bags + b[2].bank) end)
    tooltip:AddLine(" ")
    for _, l in ipairs(lines) do
        local c, e = l[1], l[2]
        local parts = {}
        if e.bags > 0 then parts[#parts + 1] = EllesmereUI.L("Bags") .. " " .. e.bags end
        if e.bank > 0 then parts[#parts + 1] = EllesmereUI.L("Bank") .. " " .. e.bank end
        tooltip:AddDoubleLine(ClassHex(c.class) .. (c.name or "?") .. "|r", table.concat(parts, "  "), 1, 1, 1, 0.8, 0.8, 0.8)
    end
    if war and war.n then
        total = total + war.n
        tooltip:AddDoubleLine(EllesmereUI.L("Warband Bank"), war.n, 0.4, 0.78, 1, 0.8, 0.8, 0.8)
    end
    if #lines + (war and 1 or 0) > 1 then
        tooltip:AddDoubleLine(EllesmereUI.L("Total"), total, 1, 0.82, 0, 1, 1, 1)
    end
end

-- the post call can't be removed: it returns at once while off
local hooked = false
function Offline.SyncTooltip()
    if hooked or not (listening and Offline.CountsEnabled()) then return end
    if not (TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall) then return end
    hooked = true
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, OnItemTooltip)
end

-------------------------------------------------------------------------------
--  Login
-------------------------------------------------------------------------------
local boot = CreateFrame("Frame")
boot:RegisterEvent("PLAYER_LOGIN")
boot:SetScript("OnEvent", function(self)
    self:UnregisterEvent("PLAYER_LOGIN")
    Offline.Store()
    Offline.Sync()
end)

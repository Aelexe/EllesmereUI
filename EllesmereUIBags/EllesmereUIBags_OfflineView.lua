if EUI_CLIENT_BLOCKED then return end -- pre-12.1 client failsafe (EllesmereUI_ClientGate.lua)
-------------------------------------------------------------------------------
--  EllesmereUIBags_OfflineView.lua
--  Offline Bank view inside the bags window: Bank in the bags sidebar (the
--  selection -3, EUI_Bags_Sidebar.lua) shows any saved character's bank, or
--  the warband bank, from anywhere (data from EllesmereUIBags_Offline.lua).
--
--  The view is a panel over the bags' item area (FinishRefresh in
--  EUI_Bags_Refresh.lua calls ns.OfflinePanel after every refresh; the bags
--  paint no items while Bank is selected). Its item buttons are plain display
--  buttons: they never touch a real bag slot, so the view is safe at any time,
--  combat included. Hover for the item tooltip; Shift-click links, Ctrl-click
--  previews (HandleModifiedItemClick). The bags search box filters it too.
-------------------------------------------------------------------------------
local EUI = EllesmereUI
local ns = select(2, ...)
local Offline = ns.Offline
local I = ns._bagsInternals
if not (Offline and I) then return end  -- WoW Forever, or a bags file failed to load

local GetItemInfo, GetItemInfoInstant = C_Item.GetItemInfo, C_Item.GetItemInfoInstant
local _emptyP = {}
local function BP() return (EUI._bagsDB and EUI._bagsDB.profile) or _emptyP end

local SLOT_SIZE, SPACING = 34, 4
local BAR_H, PAD = 30, 10
local ITEM_CLASS_WEAPON, ITEM_CLASS_ARMOR = Enum.ItemClass.Weapon, Enum.ItemClass.Armor
local BANK_VIEW = -3
ns.OFFLINE_BANK_VIEW = BANK_VIEW

local function GetFont() return EUI.GetFontPath("bags") end
local function SetFont(fs, size)
    EUI.PrimeFontShadow(fs, true)
    fs:SetFont(GetFont(), size, EUI.GetFontOutlineFlag("bags"))
end

-- what's showing
local viewKey             -- character key
local viewTab = "bank"    -- "bank" | "warband"

local panel, bar, scroll, child
local slots, heads, tabs = {}, {}, {}

local function Hex(class)
    local c = class and C_ClassColor and C_ClassColor.GetClassColor(class)
    return c and c:GenerateHexColorMarkup() or "|cffffffff"
end

-- "3 days ago" style age of a saved copy
local function Age(t)
    if type(t) ~= "number" then return nil end
    local s = math.max(time() - t, 0)
    if s < 60 then return EllesmereUI.L("just now") end
    return EllesmereUI.Lf("%1$s ago", SecondsToTime(s, false, false, 1))
end

-- the bags search, lower-cased ("" when empty)
local function Query()
    local box = EUI_Bags._searchBox
    return box and (box:GetText() or ""):lower() or ""
end

local Paint  -- forward

local function Repaint()
    if scroll then scroll:SetVerticalScroll(0) end
    Paint()
end

-------------------------------------------------------------------------------
--  The panel: a bar (character, Bank / Warband, gold and saved time) over a
--  scrolling grid
-------------------------------------------------------------------------------
local function TabButton(text, key)
    local b = CreateFrame("Button", nil, bar)
    b:SetHeight(BAR_H)
    b.text = b:CreateFontString(nil, "OVERLAY")
    SetFont(b.text, 12)
    b.text:SetPoint("CENTER")
    b.text:SetText(text)
    b:SetWidth(b.text:GetStringWidth() + 16)
    b.line = b:CreateTexture(nil, "OVERLAY")
    b.line:SetPoint("BOTTOMLEFT", 6, 0)
    b.line:SetPoint("BOTTOMRIGHT", -6, 0)
    b.line:SetHeight(2)
    b.key = key
    b:SetScript("OnClick", function() viewTab = key; Repaint() end)
    b:SetScript("OnEnter", function(self) if viewTab ~= self.key then self.text:SetTextColor(1, 1, 1) end end)
    b:SetScript("OnLeave", function(self) if viewTab ~= self.key then self.text:SetTextColor(0.6, 0.6, 0.6) end end)
    return b
end

local function PaintTabs()
    local r, g, b = 0.05, 0.82, 0.62
    if EUI.GetAccentColor then r, g, b = EUI.GetAccentColor() end
    for _, t in ipairs(tabs) do
        local on = t.key == viewTab
        t.text:SetTextColor(on and 1 or 0.6, on and 1 or 0.6, on and 1 or 0.6)
        t.line:SetColorTexture(r, g, b, 1)
        t.line:SetShown(on)
    end
end

-- the character picker: realms as titles, characters as radios, forget at the end
local function OpenPicker(owner)
    if not (MenuUtil and MenuUtil.CreateContextMenu) then return end
    MenuUtil.CreateContextMenu(owner, function(_, root)
        local realm
        for _, c in ipairs(Offline.Characters()) do
            if c.realm ~= realm then
                realm = c.realm
                root:CreateTitle(realm)
            end
            root:CreateRadio(Hex(c.class) .. c.name .. "|r", function() return viewKey == c.key end, function()
                viewKey = c.key
                Repaint()
            end)
        end
        local c = Offline.Char(viewKey)
        if c and viewKey ~= Offline.CurrentKey() then
            root:CreateDivider()
            root:CreateButton(EllesmereUI.Lf("Forget %1$s", c.name or viewKey), function()
                Offline.Forget(viewKey)
                viewKey = Offline.CurrentKey()
                Repaint()
            end)
        end
    end)
end

local function Build()
    if panel then return end
    -- above the pinned item buttons (window level + 9) so the bags never show through
    panel = CreateFrame("Frame", nil, EUI_Bags)
    panel:SetFrameLevel(EUI_Bags:GetFrameLevel() + 40)
    panel:EnableMouse(true)
    panel:Hide()
    local bg = panel:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetTexture("Interface\\AddOns\\EllesmereUI\\media\\modern_blizz.png")
    local shade = panel:CreateTexture(nil, "BACKGROUND", nil, 1)
    shade:SetAllPoints()
    shade:SetColorTexture(0, 0, 0, 0.25)

    bar = CreateFrame("Frame", nil, panel)
    bar:SetPoint("TOPLEFT")
    bar:SetPoint("TOPRIGHT")
    bar:SetHeight(BAR_H)
    local bbg = bar:CreateTexture(nil, "BACKGROUND", nil, 2)
    bbg:SetAllPoints()
    bbg:SetColorTexture(0, 0, 0, 0.25)
    local px = (EUI.PP and EUI.PP.mult) or 1
    local sep = bar:CreateTexture(nil, "ARTWORK")
    sep:SetHeight(px)
    sep:SetPoint("BOTTOMLEFT")
    sep:SetPoint("BOTTOMRIGHT")
    sep:SetColorTexture(0.15, 0.15, 0.15, 1)

    local who = CreateFrame("Button", nil, bar)
    who:SetHeight(BAR_H)
    who:SetPoint("LEFT", 4, 0)
    who.text = who:CreateFontString(nil, "OVERLAY")
    SetFont(who.text, 12)
    who.text:SetPoint("LEFT", 6, 0)
    who.arrow = who:CreateTexture(nil, "OVERLAY")
    who.arrow:SetTexture("Interface\\AddOns\\EllesmereUI\\media\\icons\\eui-arrow-down3.png")
    who.arrow:SetSize(10, 10)
    who.arrow:SetPoint("LEFT", who.text, "RIGHT", 5, 0)
    who.arrow:SetAlpha(0.7)
    who:SetScript("OnClick", function(self) OpenPicker(self) end)
    who:SetScript("OnEnter", function(self)
        self.arrow:SetAlpha(1)
        EUI.ShowWidgetTooltip(self, EllesmereUI.L("Choose a character"))
    end)
    who:SetScript("OnLeave", function(self)
        self.arrow:SetAlpha(0.7)
        EUI.HideWidgetTooltip()
    end)
    bar.who = who

    local prev = who
    for _, d in ipairs({ { EllesmereUI.L("Bank"), "bank" }, { EllesmereUI.L("Warband"), "warband" } }) do
        local t = TabButton(d[1], d[2])
        t:SetPoint("LEFT", prev, "RIGHT", prev == who and 8 or 0, 0)
        tabs[#tabs + 1] = t
        prev = t
    end

    bar.info = bar:CreateFontString(nil, "OVERLAY")
    SetFont(bar.info, 11)
    bar.info:SetPoint("RIGHT", -10, 0)
    bar.info:SetTextColor(0.6, 0.6, 0.6)
    bar.info:SetJustifyH("RIGHT")

    scroll = CreateFrame("ScrollFrame", nil, panel)
    scroll:SetPoint("TOPLEFT", 0, -BAR_H)
    scroll:SetPoint("BOTTOMRIGHT")
    scroll:EnableMouseWheel(true)
    child = CreateFrame("Frame", nil, scroll)
    child:SetSize(1, 1)
    scroll:SetScrollChild(child)
    scroll:SetScript("OnMouseWheel", function(self, delta)
        local max = math.max(child:GetHeight() - self:GetHeight(), 0)
        self:SetVerticalScroll(math.min(math.max(self:GetVerticalScroll() - delta * (SLOT_SIZE + SPACING) * 2, 0), max))
    end)
    panel.empty = panel:CreateFontString(nil, "OVERLAY")
    SetFont(panel.empty, 12)
    panel.empty:SetPoint("TOPLEFT", scroll, "TOPLEFT", PAD + 6, -PAD - 4)
    panel.empty:SetPoint("RIGHT", scroll, "RIGHT", -PAD, 0)
    panel.empty:SetJustifyH("LEFT")
    panel.empty:SetTextColor(0.6, 0.6, 0.6)

    panel:SetScript("OnHide", function() GameTooltip:Hide() end)
    -- the bags search filters this view too
    if EUI_Bags._searchBox then
        EUI_Bags._searchBox:HookScript("OnTextChanged", function() if panel:IsShown() then Repaint() end end)
    end
end

-------------------------------------------------------------------------------
--  Item buttons (display only)
-------------------------------------------------------------------------------
local function SlotOnEnter(self)
    if not self.link then return end
    ns.SetInsetBorderColor(self, 1, 1, 1, 1)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetHyperlink(self.link)
    GameTooltip:Show()
end
local function SlotOnLeave(self)
    ns.SetInsetBorderColor(self, self._r, self._g, self._b, 1)
    GameTooltip:Hide()
end
local function SlotOnClick(self)
    if self.link then HandleModifiedItemClick(self.link) end
end

local function Slot(i)
    local b = slots[i]
    if b then return b end
    b = CreateFrame("Button", nil, child)
    b:SetSize(SLOT_SIZE, SLOT_SIZE)
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetAllPoints()
    b.Count = b:CreateFontString(nil, "OVERLAY")
    b.Count:SetPoint("BOTTOMRIGHT", -2, 2)
    b.Level = b:CreateFontString(nil, "OVERLAY")
    b.Level:SetPoint("TOPLEFT", 1, -1)
    local hl = b:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 1, 1, 0.08)
    ns.CreateInsetBorder(b)
    b:SetScript("OnEnter", SlotOnEnter)
    b:SetScript("OnLeave", SlotOnLeave)
    b:SetScript("OnClick", SlotOnClick)
    slots[i] = b
    return b
end

local function Head(i)
    local f = heads[i]
    if f then return f end
    f = CreateFrame("Frame", nil, child)
    f:SetHeight(20)
    f.label = f:CreateFontString(nil, "OVERLAY")
    f.label:SetPoint("LEFT")
    f.label:SetTextColor(0.7, 0.7, 0.7)
    local px = (EUI.PP and EUI.PP.mult) or 1
    f.line = f:CreateTexture(nil, "ARTWORK")
    f.line:SetHeight(px)
    f.line:SetPoint("LEFT", f.label, "RIGHT", 6, 0)
    f.line:SetPoint("RIGHT", -SPACING, 0)
    f.line:SetColorTexture(0.7, 0.7, 0.7, 0.2)
    heads[i] = f
    return f
end

-------------------------------------------------------------------------------
--  Content
-------------------------------------------------------------------------------
-- the containers behind the current view, and when they were saved
local function Containers()
    if viewTab == "warband" then
        local w = Offline.Warband()
        return w.tabs, w.time
    end
    local c = Offline.Char(viewKey)
    if not c then return nil end
    return c.bank, c.bankTime
end

local waiting = false  -- item data asked for; one repaint when it lands

-- the saved items as display entries
local function Collect(list, query)
    local items, used, total = {}, 0, 0
    for _, t in ipairs(type(list) == "table" and list or {}) do
        if type(t) == "table" then
            total = total + (t.size or 0)
            for slot, link in pairs(type(t.links) == "table" and t.links or {}) do
                used = used + 1
                local name = link:match("%[(.-)%]") or ""
                if query == "" or name:lower():find(query, 1, true) then
                    local id = Offline.LinkID(link)
                    local _, _, q, _, _, _, _, _, _, icon = GetItemInfo(link)
                    if q == nil then
                        waiting = true
                        if id then C_Item.RequestLoadItemDataByID(id) end
                    end
                    local _, _, _, _, instIcon, classID = GetItemInfoInstant(link)
                    items[#items + 1] = {
                        link = link, id = id, name = name, q = q or 1, icon = icon or instIcon,
                        n = (t.counts and t.counts[slot]) or 1,
                        gear = classID == ITEM_CLASS_WEAPON or classID == ITEM_CLASS_ARMOR,
                    }
                end
            end
        end
    end
    return items, used, total
end

-- category per item, the bags' own order; disabled categories go to the catch-all
local function Group(items)
    local mgr = _G.EUI_CategoryManager
    local cats = mgr and mgr:GetCategories()
    if not cats then return { { name = EllesmereUI.L("Items"), items = items } } end
    local disabled = BP().bagDisabledCategories or _emptyP
    local catchAll
    for i, cat in ipairs(cats) do if cat.isCatchAll then catchAll = i end end
    local by = {}
    for _, it in ipairs(items) do
        local idx = mgr:ClassifyItem(it.link, it.id, nil, nil, it.q) or catchAll or #cats
        local cat = cats[idx]
        if cat and cat._defaultName and disabled[cat._defaultName] and catchAll then idx = catchAll end
        local g = by[idx]
        if not g then g = { idx = idx, name = cats[idx] and cats[idx].name or EllesmereUI.L("Items"), items = {} }; by[idx] = g end
        g.items[#g.items + 1] = it
    end
    local groups = {}
    for _, g in pairs(by) do groups[#groups + 1] = g end
    table.sort(groups, function(a, b) return a.idx < b.idx end)
    for _, g in ipairs(groups) do
        table.sort(g.items, function(a, b)
            if a.q ~= b.q then return a.q > b.q end
            if a.name ~= b.name then return a.name < b.name end
            return a.link < b.link
        end)
    end
    return groups
end

local function PaintSlot(b, it)
    local z = BP().bagItemIconZoom or 0.08
    b.link = it.link
    b.icon:SetTexture(it.icon or 134400)
    b.icon:SetTexCoord(z, 1 - z, z, 1 - z)
    EUI.ApplyIconTextFont(b.Count, GetFont(), BP().bagCountFontSize or 11, "bags")
    b.Count:SetText(it.n > 1 and it.n or "")
    b.Level:SetFont(GetFont(), BP().itemlevelFontSize or 12, (EUI.SlugFlag and EUI.SlugFlag("OUTLINE, SLUG")) or "OUTLINE")
    local lvl = it.gear and BP().showItemlevelInBags ~= false and C_Item.GetDetailedItemLevelInfo(it.link)
    if lvl and lvl > 1 then
        b.Level:SetText(lvl)
        b.Level:SetTextColor(1, 1, 1)
    else
        b.Level:SetText("")
    end
    b._r, b._g, b._b = ns.QualityBorderColor(it.q)
    if it.q <= 1 and BP().bagQualityBorder ~= false then b._r, b._g, b._b = 0.25, 0.25, 0.25 end
    ns.SetInsetBorderColor(b, b._r, b._g, b._b, 1)
    b:Show()
end

Paint = function()
    if not (panel and panel:IsShown()) then return end
    if not Offline.Char(viewKey) then viewKey = Offline.CurrentKey() end
    local c = Offline.Char(viewKey)
    bar.who.text:SetText(c and (Hex(c.class) .. (c.name or viewKey) .. "|r") or (UnitName("player") or ""))
    bar.who:SetWidth(bar.who.text:GetStringWidth() + 28)
    PaintTabs()

    local width = panel:GetWidth()
    local cols = math.max(math.floor((width - PAD * 2 - 10) / (SLOT_SIZE + SPACING)), 1)
    local gridW = cols * (SLOT_SIZE + SPACING)
    child:SetWidth(math.max(width, 1))
    local titleSize = BP().bagCatTitleSize or 11

    waiting = false
    local query = Query()
    local list, saved = Containers()
    local items, used, total = Collect(list, query)
    local y, shown, nh = -6, 0, 0
    if list then
        for _, g in ipairs(Group(items)) do
            nh = nh + 1
            local h = Head(nh)
            SetFont(h.label, titleSize)
            h:ClearAllPoints()
            h:SetPoint("TOPLEFT", PAD + 5, y)
            h:SetWidth(gridW)
            h.label:SetText(g.name .. " (" .. #g.items .. ")")
            h:Show()
            y = y - 22
            for i, it in ipairs(g.items) do
                shown = shown + 1
                local b = Slot(shown)
                b:ClearAllPoints()
                b:SetPoint("TOPLEFT", PAD + 5 + ((i - 1) % cols) * (SLOT_SIZE + SPACING),
                    y - math.floor((i - 1) / cols) * (SLOT_SIZE + SPACING))
                PaintSlot(b, it)
            end
            y = y - math.ceil(#g.items / cols) * (SLOT_SIZE + SPACING) - 6
        end
    end
    for i = shown + 1, #slots do slots[i]:Hide() end
    for i = nh + 1, #heads do heads[i]:Hide() end
    child:SetHeight(math.max(-y, 1))

    -- nothing saved yet: say how to fill it
    local empty
    if not list then
        if viewTab == "warband" then
            empty = EllesmereUI.L("The warband bank hasn't been saved yet. Open it once at a banker.")
        else
            empty = EllesmereUI.L("This character's bank hasn't been saved yet. Visit a banker on this character.")
        end
    elseif shown == 0 then
        empty = query ~= "" and EllesmereUI.L("No items match your search.") or EllesmereUI.L("No Items")
    end
    panel.empty:SetText(empty or "")
    panel.empty:SetShown(empty ~= nil)

    -- gold and when it was saved, right of the tabs; slots in the bags header
    local GL = EUI.GetGoldLedger and EUI.GetGoldLedger()
    local gold
    if viewTab == "warband" then
        gold = GL and GL.WarbandMoney()
    elseif GL then
        local e = GL.Data().chars[viewKey]
        gold = e and e.money
        if viewKey == Offline.CurrentKey() then gold = GL.Money() end
    end
    local parts = {}
    local age = Age(saved)
    if age then parts[#parts + 1] = EllesmereUI.Lf("Saved %1$s", age) end
    if type(gold) == "number" then parts[#parts + 1] = GetMoneyString(gold, true) end
    bar.info:SetText(table.concat(parts, "    "))
    local hdr = EUI_Bags.Header
    if hdr and hdr.itemCount then
        hdr.itemCount:SetText(list and EllesmereUI.Lf("%d / %d Items", used, total) or "")
    end
end

-- item data landing, or the store changing under the open view
local repaint = false
local function Soon()
    if repaint then return end
    repaint = true
    C_Timer.After(0.2, function() repaint = false; Paint() end)
end
local ev = CreateFrame("Frame")
ev:SetScript("OnEvent", function() if waiting then Soon() end end)
Offline.OnChange(function() if panel and panel:IsShown() then Soon() end end)

-------------------------------------------------------------------------------
--  Hooked into the bags refresh
-------------------------------------------------------------------------------
-- after every bags refresh (FinishRefresh): over the item area while Bank is
-- selected, hidden otherwise. sidebarW: the sidebar's current width.
function ns.OfflinePanel(selected, sidebarW)
    if not (selected and Offline.Enabled()) then
        if panel then panel:Hide() end
        ev:UnregisterEvent("GET_ITEM_INFO_RECEIVED")
        return
    end
    Build()
    panel:ClearAllPoints()
    panel:SetPoint("TOPLEFT", EUI_Bags, "TOPLEFT", sidebarW or 0, -((EUI_Bags.Header and EUI_Bags.Header:GetHeight() or 35) + 1))
    if EUI_Bags.Footer then
        panel:SetPoint("BOTTOMRIGHT", EUI_Bags.Footer, "TOPRIGHT", -1, 0)
    else
        panel:SetPoint("BOTTOMRIGHT", EUI_Bags, "BOTTOMRIGHT", -1, 30)
    end
    panel:SetFrameLevel(EUI_Bags:GetFrameLevel() + 40)
    viewKey = viewKey or Offline.CurrentKey()
    panel:Show()
    ev:RegisterEvent("GET_ITEM_INFO_RECEIVED")
    Paint()
end

-- the option toggled: off leaves the Bank view for All Items
function Offline.SyncButton()
    if not (EUI_Bags and EUI_Bags.RefreshInventory) then return end
    if not Offline.Enabled() and ns.GetSelection() == BANK_VIEW then I.SetSelectedCategoryIndex(0) end
    if EUI_Bags:IsVisible() then EUI_Bags:RefreshInventory() end
end

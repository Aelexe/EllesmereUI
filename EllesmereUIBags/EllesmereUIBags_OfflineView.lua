if EUI_CLIENT_BLOCKED then return end -- pre-12.1 client failsafe (EllesmereUI_ClientGate.lua)
-------------------------------------------------------------------------------
--  EllesmereUIBags_OfflineView.lua
--  Offline Bank viewer: any saved character's bags or bank, or the warband
--  bank, from anywhere (data from EllesmereUIBags_Offline.lua). Looks like the
--  bank window, but its item buttons are plain display buttons: they never
--  touch a real bag slot, so the window is safe to open at any time, combat
--  included. Hover for the item tooltip; Shift-click links, Ctrl-click
--  previews (HandleModifiedItemClick).
--
--  Opened from the Bank icon in the bags header (EUI_Bags:SyncHeaderIcons);
--  at a banker the live bank window is the one that shows.
-------------------------------------------------------------------------------
local EUI = EllesmereUI
local ns = select(2, ...)
local Offline = ns.Offline
if not Offline then return end  -- WoW Forever, or the store failed to load


local GetItemInfo, GetItemInfoInstant = C_Item.GetItemInfo, C_Item.GetItemInfoInstant
local _emptyP = {}
local function BP() return (EUI._bagsDB and EUI._bagsDB.profile) or _emptyP end

local SLOT_SIZE, SPACING = 34, 4
local HEADER_H, FOOTER_H, PAD = 35, 28, 10
local ITEM_CLASS_WEAPON, ITEM_CLASS_ARMOR = Enum.ItemClass.Weapon, Enum.ItemClass.Armor

local function GetFont() return EUI.GetFontPath("bags") end
-- an atlas when the client has it, else the fallback texture (or nothing)
local function Atlas(tex, name, fallback)
    if C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(name) then
        tex:SetAtlas(name)
    elseif fallback then
        tex:SetTexture(fallback)
    else
        tex:Hide()
    end
end
local function SetFont(fs, size)
    EUI.PrimeFontShadow(fs, true)
    fs:SetFont(GetFont(), size, EUI.GetFontOutlineFlag("bags"))
end
local function Columns() return BP().bankColumns or 14 end
local function Height() return BP().bankHeight or 500 end

-- what's showing
local viewKey     -- character key
local viewTab = "bank"  -- "bags" | "bank" | "warband"
local query = ""

-------------------------------------------------------------------------------
--  Window
-------------------------------------------------------------------------------
local win, header, scroll, child, footer
local slots, heads = {}, {}

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

local Refresh  -- forward

local function TabButton(text, key)
    local b = CreateFrame("Button", nil, header)
    b:SetHeight(HEADER_H)
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
    b:SetScript("OnClick", function()
        viewTab = key
        if scroll then scroll:SetVerticalScroll(0) end
        Refresh()
    end)
    b:SetScript("OnEnter", function(self) if viewTab ~= self.key then self.text:SetTextColor(1, 1, 1) end end)
    b:SetScript("OnLeave", function(self) if viewTab ~= self.key then self.text:SetTextColor(0.6, 0.6, 0.6) end end)
    return b
end

local tabs = {}
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
                if scroll then scroll:SetVerticalScroll(0) end
                Refresh()
            end)
        end
        local c = Offline.Char(viewKey)
        if c and viewKey ~= Offline.CurrentKey() then
            root:CreateDivider()
            root:CreateButton(EllesmereUI.Lf("Forget %1$s", c.name or viewKey), function()
                Offline.Forget(viewKey)
                viewKey = Offline.CurrentKey()
                Refresh()
            end)
        end
    end)
end

local function SavePosition()
    local point, _, rel, x, y = win:GetPoint(1)
    BP().bagOfflinePos = { point, rel, x, y }
end

local function Build()
    if win then return end
    win = CreateFrame("Frame", "EUI_BagsOfflineFrame", UIParent)
    win:SetToplevel(true)
    local strata = ns.BagFrameStrata and ns.BagFrameStrata() or "MEDIUM"
    win:SetFrameStrata(strata)
    win:SetFrameLevel(strata == "HIGH" and 50 or 1)
    win:EnableMouse(true)
    win:SetMovable(true)
    win:SetClampedToScreen(true)
    win:Hide()
    if EUI.RegisterEscapeClose then EUI.RegisterEscapeClose(win) end

    local bg = win:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetTexture("Interface\\AddOns\\EllesmereUI\\media\\modern_blizz.png")
    local shade = win:CreateTexture(nil, "BACKGROUND", nil, 1)
    shade:SetAllPoints()
    shade:SetColorTexture(0, 0, 0, 0.25)
    EUI.MakeBorder(win, 1, 1, 1, 0.15, EUI.PP)

    -- header: character picker, the three views, search, close
    header = CreateFrame("Frame", nil, win)
    header:SetPoint("TOPLEFT")
    header:SetPoint("TOPRIGHT")
    header:SetHeight(HEADER_H)
    header:EnableMouse(true)
    header:RegisterForDrag("LeftButton")
    header:SetScript("OnDragStart", function() win:StartMoving() end)
    header:SetScript("OnDragStop", function() win:StopMovingOrSizing(); SavePosition() end)
    local hbg = header:CreateTexture(nil, "BACKGROUND", nil, 1)
    hbg:SetAllPoints()
    hbg:SetColorTexture(0, 0, 0, 0.5)
    local px = (EUI.PP and EUI.PP.mult) or 1
    local sep = header:CreateTexture(nil, "ARTWORK")
    sep:SetHeight(px)
    sep:SetPoint("BOTTOMLEFT")
    sep:SetPoint("BOTTOMRIGHT")
    sep:SetColorTexture(0.15, 0.15, 0.15, 1)

    local who = CreateFrame("Button", nil, header)
    who:SetHeight(HEADER_H)
    who:SetPoint("LEFT", 2, 0)
    who.text = who:CreateFontString(nil, "OVERLAY")
    SetFont(who.text, 13)
    who.text:SetPoint("LEFT", 6, 0)
    who.arrow = who:CreateTexture(nil, "OVERLAY")
    Atlas(who.arrow, "common-dropdown-a-button-open")
    who.arrow:SetSize(12, 12)
    who.arrow:SetPoint("LEFT", who.text, "RIGHT", 4, -1)
    who:SetScript("OnClick", function(self) OpenPicker(self) end)
    who:SetScript("OnEnter", function(self) EUI.ShowWidgetTooltip(self, EllesmereUI.L("Choose a character")) end)
    who:SetScript("OnLeave", function() EUI.HideWidgetTooltip() end)
    header.who = who

    local prev = who
    for _, d in ipairs({ { EllesmereUI.L("Bags"), "bags" }, { EllesmereUI.L("Bank"), "bank" }, { EllesmereUI.L("Warband"), "warband" } }) do
        local t = TabButton(d[1], d[2])
        t:SetPoint("LEFT", prev, "RIGHT", prev == who and 8 or 0, 0)
        tabs[#tabs + 1] = t
        prev = t
    end

    local close = CreateFrame("Button", nil, header)
    close:SetSize(12, 12)
    close:SetPoint("RIGHT", -9, 0)
    close.icon = close:CreateTexture(nil, "OVERLAY")
    close.icon:SetAllPoints()
    close.icon:SetTexture("Interface\\AddOns\\EllesmereUI\\media\\icons\\eui-close.png")
    close.icon:SetAlpha(0.7)
    close:SetScript("OnEnter", function() close.icon:SetAlpha(0.9) end)
    close:SetScript("OnLeave", function() close.icon:SetAlpha(0.7) end)
    close:SetScript("OnClick", function() win:Hide() end)

    -- search: matches the item names in the saved links (no game filter needed)
    local search = CreateFrame("EditBox", nil, header)
    search:SetSize(140, 22)
    search:SetPoint("RIGHT", close, "LEFT", -14, 0)
    search:SetFont(GetFont(), 12, "")
    search:SetAutoFocus(false)
    search:SetTextInsets(5, 22, 0, 0)
    local sbg = search:CreateTexture(nil, "BACKGROUND")
    sbg:SetAllPoints()
    sbg:SetColorTexture(0.02, 0.02, 0.02, 1)
    if EUI.PanelPP then EUI.PanelPP.CreateBorder(search, 0.25, 0.25, 0.25, 1, 1, "OVERLAY", 7) end
    local hint = search:CreateFontString(nil, "OVERLAY")
    SetFont(hint, 11)
    hint:SetPoint("LEFT", 5, 0)
    hint:SetText(EllesmereUI.L("Search..."))
    hint:SetTextColor(0.4, 0.4, 0.4)
    search:SetScript("OnEscapePressed", function(self) self:SetText(""); self:ClearFocus() end)
    search:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    search:SetScript("OnTextChanged", function(self)
        local text = self:GetText() or ""
        hint:SetShown(text == "")
        local q = text:lower()
        if q ~= query then
            query = q
            Refresh()
        end
    end)

    -- body
    scroll = CreateFrame("ScrollFrame", nil, win)
    scroll:SetPoint("TOPLEFT", 0, -HEADER_H)
    scroll:SetPoint("BOTTOMRIGHT", 0, FOOTER_H)
    scroll:EnableMouseWheel(true)
    child = CreateFrame("Frame", nil, scroll)
    child:SetSize(1, 1)
    scroll:SetScrollChild(child)
    scroll:SetScript("OnMouseWheel", function(self, delta)
        local max = math.max(child:GetHeight() - self:GetHeight(), 0)
        local v = math.min(math.max(self:GetVerticalScroll() - delta * (SLOT_SIZE + SPACING) * 2, 0), max)
        self:SetVerticalScroll(v)
    end)
    win.empty = win:CreateFontString(nil, "OVERLAY")
    SetFont(win.empty, 12)
    win.empty:SetPoint("TOPLEFT", scroll, "TOPLEFT", PAD + 6, -PAD - 4)
    win.empty:SetPoint("RIGHT", scroll, "RIGHT", -PAD, 0)
    win.empty:SetJustifyH("LEFT")
    win.empty:SetTextColor(0.6, 0.6, 0.6)

    -- footer: gold left, slots and when it was saved right
    footer = CreateFrame("Frame", nil, win)
    footer:SetPoint("BOTTOMLEFT")
    footer:SetPoint("BOTTOMRIGHT")
    footer:SetHeight(FOOTER_H)
    local fbg = footer:CreateTexture(nil, "BACKGROUND", nil, 1)
    fbg:SetAllPoints()
    fbg:SetColorTexture(0, 0, 0, 0.35)
    footer.gold = footer:CreateFontString(nil, "OVERLAY")
    SetFont(footer.gold, 11)
    footer.gold:SetPoint("LEFT", 8, 0)
    footer.info = footer:CreateFontString(nil, "OVERLAY")
    SetFont(footer.info, 11)
    footer.info:SetPoint("RIGHT", -8, 0)
    footer.info:SetTextColor(0.6, 0.6, 0.6)

    win:SetScript("OnHide", function() GameTooltip:Hide() end)
    local pos = BP().bagOfflinePos
    if type(pos) == "table" and pos[1] then
        win:SetPoint(pos[1], UIParent, pos[2] or pos[1], pos[3] or 0, pos[4] or 0)
    else
        win:SetPoint("CENTER", -200, 60)
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
    SetFont(f.label, 11)
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
    if viewTab == "bags" then return c.bags, c.bagsTime end
    return c.bank, c.bankTime
end

local waiting = false  -- item data asked for; one repaint when it lands

-- the saved items as display entries, grouped by bags category
local function Collect(list)
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

local function Paint(b, it)
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

Refresh = function()
    if not (win and win:IsShown()) then return end
    if not Offline.Char(viewKey) then viewKey = Offline.CurrentKey() end
    local c = Offline.Char(viewKey)
    header.who.text:SetText(c and (Hex(c.class) .. (c.name or viewKey) .. "|r") or (UnitName("player") or ""))
    header.who:SetWidth(header.who.text:GetStringWidth() + 28)
    PaintTabs()

    local cols = Columns()
    local gridW = cols * (SLOT_SIZE + SPACING)
    win:SetSize(gridW + PAD * 2 + 10, Height())
    child:SetWidth(gridW + PAD * 2)

    waiting = false
    local list, saved = Containers()
    local items, used, total = Collect(list)
    local y, shown, nh = -6, 0, 0
    if list then
        for _, g in ipairs(Group(items)) do
            nh = nh + 1
            local h = Head(nh)
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
                Paint(b, it)
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
        elseif viewTab == "bank" then
            empty = EllesmereUI.L("This character's bank hasn't been saved yet. Visit a banker on this character.")
        else
            empty = EllesmereUI.L("This character's bags haven't been saved yet.")
        end
    elseif shown == 0 then
        empty = query ~= "" and EllesmereUI.L("No items match your search.") or EllesmereUI.L("No Items")
    end
    win.empty:SetText(empty or "")
    win.empty:SetShown(empty ~= nil)

    -- footer
    local gold
    if viewTab == "warband" then
        local GL = EUI.GetGoldLedger and EUI.GetGoldLedger()
        gold = GL and GL.WarbandMoney()
    else
        local GL = EUI.GetGoldLedger and EUI.GetGoldLedger()
        local e = GL and GL.Data().chars[viewKey]
        gold = e and e.money
        if viewKey == Offline.CurrentKey() and GL then gold = GL.Money() end
    end
    footer.gold:SetText(type(gold) == "number" and GetMoneyString(gold, true) or "")
    local parts = {}
    if list then parts[#parts + 1] = used .. "/" .. total end
    local age = Age(saved)
    if age then parts[#parts + 1] = EllesmereUI.Lf("Saved %1$s", age) end
    footer.info:SetText(table.concat(parts, "   "))
end

-- item data landing, or the store changing under the open view
local repaint = false
local function Soon()
    if repaint then return end
    repaint = true
    C_Timer.After(0.2, function() repaint = false; Refresh() end)
end
local ev = CreateFrame("Frame")
ev:SetScript("OnEvent", function() if waiting then Soon() end end)
Offline.OnChange(function() if win and win:IsShown() then Soon() end end)

-------------------------------------------------------------------------------
--  Opening it
-------------------------------------------------------------------------------
function Offline.Show(tab, key)
    if not Offline.Enabled() then return end
    Build()
    viewTab = tab or viewTab
    viewKey = key or viewKey or Offline.CurrentKey()
    win:Show()
    win:Raise()
    ev:RegisterEvent("GET_ITEM_INFO_RECEIVED")
    Refresh()
end

function Offline.Toggle(tab)
    if win and win:IsShown() then win:Hide() else Offline.Show(tab) end
end

-- the Bank icon in the bags header, after Show Bags (EUI_Bags:SyncHeaderIcons)
local function BuildIcon()
    local b = CreateFrame("Button", nil, EUI_Bags._bagsBtn:GetParent())
    b:SetSize(24, 24)
    b.icon = b:CreateTexture(nil, "OVERLAY")
    Atlas(b.icon, "Banker", "Interface\\Icons\\INV_Misc_Coin_02")
    b.icon:SetSize(20, 20)
    b.icon:SetPoint("CENTER")
    b.icon:SetAlpha(0.9)
    b:SetScript("OnEnter", function(self)
        self.icon:SetAlpha(1)
        EUI.ShowWidgetTooltip(self, EllesmereUI.L("Bank, other characters and the warband bank, from anywhere."))
    end)
    b:SetScript("OnLeave", function(self)
        self.icon:SetAlpha(0.9)
        EUI.HideWidgetTooltip()
    end)
    b:SetScript("OnClick", function()
        EUI.HideWidgetTooltip()
        -- at a banker the live bank is the real one
        local bank = _G.EUI_BankFrame
        if bank and bank:IsShown() then return end
        Offline.Toggle("bank")
    end)
    EUI_Bags._offlineBtn = b
end

function ns.SyncOfflineIcon(prev, gap)
    local on = Offline.Enabled()
    if on and not EUI_Bags._offlineBtn and EUI_Bags._bagsBtn then BuildIcon() end
    local b = EUI_Bags._offlineBtn
    if not b then return nil end
    b:ClearAllPoints()
    b:SetPoint("RIGHT", prev, "LEFT", -gap, 0)
    b:SetShown(on)
    if not on and win then win:Hide() end
    return on and b or nil
end

-- the option toggled: the icon follows
function Offline.SyncButton()
    if EUI_Bags and EUI_Bags._bagsBtn and EUI_Bags.SyncHeaderIcons then EUI_Bags:SyncHeaderIcons() end
end

-- /euibank opens it too
SLASH_EUIOFFLINEBANK1 = "/euibank"
SlashCmdList.EUIOFFLINEBANK = function() Offline.Toggle("bank") end

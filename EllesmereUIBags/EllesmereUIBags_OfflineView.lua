if EUI_CLIENT_BLOCKED then return end -- pre-12.1 client failsafe (EllesmereUI_ClientGate.lua)
-------------------------------------------------------------------------------
--  EllesmereUIBags_OfflineView.lua
--  Offline Bank views (data from EllesmereUIBags_Offline.lua):
--    * bags: the title reads "Name's Inventory" and drops down a list of
--      saved characters; picking another one shows their bags, and the
--      sidebar categories count and filter their items. Bank in the bags
--      sidebar (the selection -3, EUI_Bags_Sidebar.lua) shows the picked
--      character's bank, or the warband bank.
--    * bank window: the title reads "Name's Bank" with the same list;
--      picking another character shows their saved bank over the live one.
--
--  Each view is a panel over its window's item area (bags: FinishRefresh in
--  EUI_Bags_Refresh.lua calls ns.OfflinePanel after every refresh and paints
--  no items under it; bank: after EUI_Bank:RefreshBank). Its item buttons are
--  plain display buttons: they never touch a real bag slot, so the views are
--  safe at any time, combat included. Hover for the item tooltip; Shift-click
--  links, Ctrl-click previews (HandleModifiedItemClick). The window's search
--  box filters it too.
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

-------------------------------------------------------------------------------
--  Views: one per window. v.key is another character picked in its title
--  (nil = this one); v.mode is what the panel shows ("bags" | "bank" | nil).
-------------------------------------------------------------------------------
local bagsView = { win = EUI_Bags, word = "%1$s's Inventory", plain = "Inventory", viewTab = "bank", slots = {}, heads = {}, tabs = {} }
local bankView = { win = _G.EUI_BankFrame, word = "%1$s's Bank", plain = "Bank", viewTab = "bank", slots = {}, heads = {}, tabs = {} }
local views = { bagsView, bankView }
local moneyN = 0

local function ShownKey(v) return v.key or Offline.CurrentKey() end

-- drop a pick that no longer resolves (option off, forgotten, source changed)
local function AltKey(v)
    if not v.key then return nil end
    if not Offline.Enabled() or v.key == Offline.CurrentKey() or not Offline.Char(v.key) then
        v.key = nil
        return nil
    end
    return v.key
end

-- another character's bags are showing in the bags (nil while it's this character)
function ns.OfflineAlt() return AltKey(bagsView) end

-- the window's search, lower-cased ("" when empty)
local function Query(v)
    local box = v.win and v.win._searchBox
    return box and (box:GetText() or ""):lower() or ""
end

local Paint, SyncBank  -- forward

local function Repaint(v)
    if v.scroll then v.scroll:SetVerticalScroll(0) end
    Paint(v)
end

-- the window rebuilds around a new pick
local function Rebuild(v)
    if v.scroll then v.scroll:SetVerticalScroll(0) end
    if v == bagsView then
        if EUI_Bags:IsVisible() and EUI_Bags.RefreshInventory then EUI_Bags:RefreshInventory() end
    else
        SyncBank()
    end
end

-------------------------------------------------------------------------------
--  The title: "Name's Inventory" / "Name's Bank", a dropdown of saved characters
-------------------------------------------------------------------------------
-- realms as titles, characters as radios, forget at the end
local function OpenPicker(v, owner)
    if not (MenuUtil and MenuUtil.CreateContextMenu) then return end
    MenuUtil.CreateContextMenu(owner, function(_, root)
        local realm
        for _, c in ipairs(Offline.Characters()) do
            if c.realm ~= realm then
                realm = c.realm
                root:CreateTitle(realm)
            end
            root:CreateRadio(Hex(c.class) .. c.name .. "|r", function() return ShownKey(v) == c.key end, function()
                v.key = not c.current and c.key or nil
                Rebuild(v)
            end)
        end
        local c = v.key and Offline.Char(v.key)
        if c and Offline.CanForget(v.key) then
            root:CreateDivider()
            root:CreateButton(EllesmereUI.Lf("Forget %1$s", c.name or v.key), function()
                Offline.Forget(v.key)
                v.key = nil
                Rebuild(v)
            end)
        end
    end)
end

-- title: the window's title FontString; count: the item count beside it
local function SyncTitle(v, title, count)
    if not (title and count) then return end
    local on = Offline.Enabled()
    if on and not v.titleBtn then
        local b = CreateFrame("Button", nil, title:GetParent())
        b:SetPoint("TOPLEFT", title, "TOPLEFT", -4, 4)
        b:SetPoint("BOTTOMLEFT", title, "BOTTOMLEFT", -4, -4)
        b.arrow = b:CreateTexture(nil, "OVERLAY")
        b.arrow:SetTexture("Interface\\AddOns\\EllesmereUI\\media\\icons\\eui-arrow-down3.png")
        b.arrow:SetSize(10, 10)
        b.arrow:SetPoint("LEFT", title, "RIGHT", 5, 0)
        b.arrow:SetAlpha(0.7)
        b:SetScript("OnClick", function(self) OpenPicker(v, self) end)
        b:SetScript("OnEnter", function(self)
            self.arrow:SetAlpha(1)
            EUI.ShowWidgetTooltip(self, EllesmereUI.L("Choose a character"))
        end)
        b:SetScript("OnLeave", function(self)
            self.arrow:SetAlpha(0.7)
            EUI.HideWidgetTooltip()
        end)
        v.titleBtn = b
    end
    if v.titleBtn then v.titleBtn:SetShown(on) end
    count:ClearAllPoints()
    if on then
        local c = Offline.Char(ShownKey(v))
        local name = (c and c.name) or UnitName("player") or ""
        local class = (c and c.class) or select(2, UnitClass("player"))
        title:SetText(EllesmereUI.Lf(v.word, Hex(class) .. name .. "|r"))
        v.titleBtn:SetWidth(title:GetStringWidth() + 23)
        count:SetPoint("LEFT", v.titleBtn.arrow, "RIGHT", 8, 0)
    else
        title:SetText(EllesmereUI.L(v.plain))
        count:SetPoint("LEFT", title, "RIGHT", 8, 0)
    end
end

-- closing a window goes back to this character
EUI_Bags:HookScript("OnHide", function() bagsView.key = nil end)

-------------------------------------------------------------------------------
--  The panel: a bar (Bank / Warband, saved time, gold) over a scrolling grid
-------------------------------------------------------------------------------
local function TabButton(v, text, key)
    local b = CreateFrame("Button", nil, v.bar)
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
    b:SetScript("OnClick", function() v.viewTab = key; Repaint(v) end)
    b:SetScript("OnEnter", function(self) if v.viewTab ~= self.key then self.text:SetTextColor(1, 1, 1) end end)
    b:SetScript("OnLeave", function(self) if v.viewTab ~= self.key then self.text:SetTextColor(0.6, 0.6, 0.6) end end)
    return b
end

local function PaintTabs(v)
    local r, g, b = 0.05, 0.82, 0.62
    if EUI.GetAccentColor then r, g, b = EUI.GetAccentColor() end
    for _, t in ipairs(v.tabs) do
        local on = t.key == v.viewTab
        t.text:SetTextColor(on and 1 or 0.6, on and 1 or 0.6, on and 1 or 0.6)
        t.line:SetColorTexture(r, g, b, 1)
        t.line:SetShown(on)
        t:SetShown(v.mode == "bank")
    end
end

local function Build(v)
    if v.panel then return end
    local win = v.win
    -- above the window's item buttons so they never show through
    local panel = CreateFrame("Frame", nil, win)
    panel:SetFrameLevel(win:GetFrameLevel() + 40)
    panel:EnableMouse(true)
    panel:Hide()
    local bg = panel:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetTexture("Interface\\AddOns\\EllesmereUI\\media\\modern_blizz.png")
    local shade = panel:CreateTexture(nil, "BACKGROUND", nil, 1)
    shade:SetAllPoints()
    shade:SetColorTexture(0, 0, 0, 0.25)
    v.panel = panel

    local bar = CreateFrame("Frame", nil, panel)
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
    v.bar = bar

    local prev
    for _, d in ipairs({ { EllesmereUI.L("Bank"), "bank" }, { EllesmereUI.L("Warband"), "warband" } }) do
        local t = TabButton(v, d[1], d[2])
        if prev then t:SetPoint("LEFT", prev, "RIGHT", 0, 0) else t:SetPoint("LEFT", 6, 0) end
        v.tabs[#v.tabs + 1] = t
        prev = t
    end

    -- gold the way the bags footer shows it (SmallMoneyFrameTemplate, 11pt)
    moneyN = moneyN + 1
    local name = "EUI_OfflineMoneyFrame" .. moneyN
    local money = CreateFrame("Frame", name, bar, "SmallMoneyFrameTemplate")
    MoneyFrame_SetType(money, "STATIC")
    for _, suffix in ipairs({ "GoldButton", "SilverButton", "CopperButton" }) do
        local btn = _G[name .. suffix]
        local txt = btn and btn:GetFontString()
        if txt then SetFont(txt, 11) end
    end
    for _, c in pairs({ money:GetChildren() }) do c:EnableMouse(false) end
    v.money, v.moneyName = money, name

    v.info = bar:CreateFontString(nil, "OVERLAY")
    SetFont(v.info, 11)
    v.info:SetTextColor(0.6, 0.6, 0.6)
    v.info:SetJustifyH("RIGHT")

    local scroll = CreateFrame("ScrollFrame", nil, panel)
    scroll:SetPoint("TOPLEFT", 0, -BAR_H)
    scroll:SetPoint("BOTTOMRIGHT")
    scroll:EnableMouseWheel(true)
    local child = CreateFrame("Frame", nil, scroll)
    child:SetSize(1, 1)
    scroll:SetScrollChild(child)
    scroll:SetScript("OnMouseWheel", function(self, delta)
        local max = math.max(child:GetHeight() - self:GetHeight(), 0)
        self:SetVerticalScroll(math.min(math.max(self:GetVerticalScroll() - delta * (SLOT_SIZE + SPACING) * 2, 0), max))
    end)
    v.scroll, v.child = scroll, child
    v.empty = panel:CreateFontString(nil, "OVERLAY")
    SetFont(v.empty, 12)
    v.empty:SetPoint("TOPLEFT", scroll, "TOPLEFT", PAD + 6, -PAD - 4)
    v.empty:SetPoint("RIGHT", scroll, "RIGHT", -PAD, 0)
    v.empty:SetJustifyH("LEFT")
    v.empty:SetTextColor(0.6, 0.6, 0.6)

    panel:SetScript("OnHide", function() GameTooltip:Hide() end)
    -- the window's search filters this view too
    if win._searchBox then
        win._searchBox:HookScript("OnTextChanged", function() if panel:IsShown() then Repaint(v) end end)
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

local function Slot(v, i)
    local b = v.slots[i]
    if b then return b end
    b = CreateFrame("Button", nil, v.child)
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
    v.slots[i] = b
    return b
end

local function Head(v, i)
    local f = v.heads[i]
    if f then return f end
    f = CreateFrame("Frame", nil, v.child)
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
    v.heads[i] = f
    return f
end

-------------------------------------------------------------------------------
--  Content
-------------------------------------------------------------------------------
-- the containers behind the view, and when they were saved
local function Containers(v)
    if v.mode == "bank" and v.viewTab == "warband" then
        local w = Offline.Warband()
        return w.tabs, w.time
    end
    local c = Offline.Char(ShownKey(v))
    if not c then return nil end
    if v.mode == "bags" then return c.bags, c.bagsTime end
    return c.bank, c.bankTime
end

local waiting = false  -- item data asked for; one repaint when it lands

-- the bags' category for an item; disabled categories go to the catch-all
local function Classify(link, id, q)
    local mgr = _G.EUI_CategoryManager
    local cats = mgr and mgr:GetCategories()
    if not cats then return 0 end
    local catchAll
    for i, cat in ipairs(cats) do if cat.isCatchAll then catchAll = i end end
    local idx = mgr:ClassifyItem(link, id, nil, nil, q) or catchAll or #cats
    local cat = cats[idx]
    local disabled = BP().bagDisabledCategories or _emptyP
    if cat and cat._defaultName and disabled[cat._defaultName] and catchAll then idx = catchAll end
    return idx
end

-- the saved items as display entries; only the categories in filter when given
local function Collect(list, query, filter)
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
                    local cat = Classify(link, id, q or 1)
                    if not filter or filter[cat] then
                        local _, _, _, _, instIcon, classID = GetItemInfoInstant(link)
                        items[#items + 1] = {
                            link = link, id = id, name = name, q = q or 1, icon = icon or instIcon, cat = cat,
                            n = (t.counts and t.counts[slot]) or 1,
                            gear = classID == ITEM_CLASS_WEAPON or classID == ITEM_CLASS_ARMOR,
                        }
                    end
                end
            end
        end
    end
    return items, used, total
end

-- the sidebar's counts for the picked character's bags (EUI_Bags_Refresh.lua)
function ns.OfflineCounts()
    local c = Offline.Char(bagsView.key)
    local counts, total = {}, 0
    for _, it in ipairs((Collect(c and c.bags, ""))) do
        counts[it.cat] = (counts[it.cat] or 0) + 1
        total = total + 1
    end
    return counts, total
end

-- the bags sidebar selection as a category filter (nil = everything)
local function Filter(v)
    if v.mode ~= "bags" then return nil end
    local sel, group = ns.GetSelection()
    local mgr = _G.EUI_CategoryManager
    if group and mgr then
        local f = {}
        for _, mi in ipairs(mgr:GetGroupMembers(group) or {}) do f[mi] = true end
        return f
    end
    if sel and sel > 0 then return { [sel] = true } end
end

-- groups in the bags' own category order
local function Group(items)
    local cats = _G.EUI_CategoryManager and _G.EUI_CategoryManager:GetCategories() or {}
    local by = {}
    for _, it in ipairs(items) do
        local g = by[it.cat]
        if not g then g = { idx = it.cat, name = cats[it.cat] and cats[it.cat].name or EllesmereUI.L("Items"), items = {} }; by[it.cat] = g end
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

-- the bar's gold: its right edge on the window's own gold readout
local function PaintGold(v, gold)
    local money, bar = v.money, v.bar
    money:ClearAllPoints()
    local ref = v.goldRef and v.goldRef()
    local dx = -10
    if ref and ref:IsShown() and ref:GetRight() and bar:GetRight() then dx = ref:GetRight() - bar:GetRight() end
    money:SetPoint("RIGHT", bar, "RIGHT", dx, 0)
    if type(gold) == "number" then
        MoneyFrame_Update(v.moneyName, gold)
        -- whole gold with separators, as the bags footer shows it
        local goldBtn = _G[v.moneyName .. "GoldButton"]
        local txt = goldBtn and goldBtn:GetFontString()
        if txt and gold >= 10000 then txt:SetText(BreakUpLargeNumbers(math.floor(gold / 10000))) end
        money:Show()
    else
        money:Hide()
    end
    v.info:ClearAllPoints()
    if money:IsShown() then
        v.info:SetPoint("RIGHT", money, "LEFT", -14, 0)
    else
        v.info:SetPoint("RIGHT", bar, "RIGHT", dx, 0)
    end
end

Paint = function(v)
    if not (v.panel and v.panel:IsShown()) then return end
    PaintTabs(v)

    local width = v.panel:GetWidth()
    local cols = math.max(math.floor((width - PAD * 2 - 10) / (SLOT_SIZE + SPACING)), 1)
    local gridW = cols * (SLOT_SIZE + SPACING)
    v.child:SetWidth(math.max(width, 1))
    local titleSize = BP().bagCatTitleSize or 11

    waiting = false
    local query = Query(v)
    local filter = Filter(v)
    local list, saved = Containers(v)
    local items, used, total = Collect(list, query, filter)
    local y, shown, nh = -6, 0, 0
    if list then
        for _, g in ipairs(Group(items)) do
            nh = nh + 1
            local h = Head(v, nh)
            SetFont(h.label, titleSize)
            h:ClearAllPoints()
            h:SetPoint("TOPLEFT", PAD + 5, y)
            h:SetWidth(gridW)
            h.label:SetText(g.name .. " (" .. #g.items .. ")")
            h:Show()
            y = y - 22
            for i, it in ipairs(g.items) do
                shown = shown + 1
                local b = Slot(v, shown)
                b:ClearAllPoints()
                b:SetPoint("TOPLEFT", PAD + 5 + ((i - 1) % cols) * (SLOT_SIZE + SPACING),
                    y - math.floor((i - 1) / cols) * (SLOT_SIZE + SPACING))
                PaintSlot(b, it)
            end
            y = y - math.ceil(#g.items / cols) * (SLOT_SIZE + SPACING) - 6
        end
    end
    for i = shown + 1, #v.slots do v.slots[i]:Hide() end
    for i = nh + 1, #v.heads do v.heads[i]:Hide() end
    v.child:SetHeight(math.max(-y, 1))

    -- nothing saved yet: say how to fill it
    local empty
    if not list then
        if v.mode == "bags" then
            empty = EllesmereUI.L("This character's bags haven't been saved yet. Log in on this character once.")
        elseif v.viewTab == "warband" then
            empty = EllesmereUI.L("The warband bank hasn't been saved yet. Open it once at a banker.")
        else
            empty = EllesmereUI.L("This character's bank hasn't been saved yet. Visit a banker on this character.")
        end
    elseif shown == 0 then
        empty = query ~= "" and EllesmereUI.L("No items match your search.") or EllesmereUI.L("No Items")
    end
    v.empty:SetText(empty or "")
    v.empty:SetShown(empty ~= nil)

    -- saved time and gold on the bar; slots in the window header
    local key = ShownKey(v)
    local warband = v.mode == "bank" and v.viewTab == "warband"
    local GL = EUI.GetGoldLedger and EUI.GetGoldLedger()
    local gold
    if Offline.UsingSyndicator() then
        local src = warband and Offline.Warband() or Offline.Char(key)
        gold = src and src.money
    elseif warband then
        gold = GL and GL.WarbandMoney()
    elseif GL then
        local e = GL.Data().chars[key]
        gold = e and e.money
        if key == Offline.CurrentKey() then gold = GL.Money() end
    end
    local age = Age(saved)
    v.info:SetText(age and EllesmereUI.Lf("Saved %1$s", age) or "")
    PaintGold(v, gold)

    local text = ""
    if list and filter then
        text = EllesmereUI.Lf("%d Items", shown)
    elseif list then
        text = EllesmereUI.Lf("%d / %d Items", used, total)
    end
    v.countText = text
    local count = v.count and v.count()
    if count then
        v.painting = true
        count:SetText(text)
        v.painting = false
    end
end

-- item data landing, or the store changing under an open view
local function Soon(v)
    if v.repaint then return end
    v.repaint = true
    C_Timer.After(0.2, function()
        v.repaint = false
        -- another character's sidebar counts come from the same items
        if v == bagsView and AltKey(v) and EUI_Bags:IsVisible() and EUI_Bags.RefreshInventory then
            EUI_Bags:RefreshInventory()
        else
            Paint(v)
        end
    end)
end
local ev = CreateFrame("Frame")
ev:SetScript("OnEvent", function()
    if not waiting then return end
    for _, v in ipairs(views) do if v.panel and v.panel:IsShown() then Soon(v) end end
end)
local function SyncEvents()
    for _, v in ipairs(views) do
        if v.panel and v.panel:IsShown() then ev:RegisterEvent("GET_ITEM_INFO_RECEIVED"); return end
    end
    ev:UnregisterEvent("GET_ITEM_INFO_RECEIVED")
end
Offline.OnChange(function()
    for _, v in ipairs(views) do if v.panel and v.panel:IsShown() then Soon(v) end end
end)

-- show the panel over a window's item area, or hide it
local function Place(v, mode, left, top, bottom)
    v.mode = mode
    if not mode then
        if v.panel then v.panel:Hide() end
        SyncEvents()
        return
    end
    Build(v)
    local win = v.win
    v.panel:ClearAllPoints()
    v.panel:SetPoint("TOPLEFT", win, "TOPLEFT", left, -top)
    v.panel:SetPoint("BOTTOMRIGHT", win, "BOTTOMRIGHT", -1, bottom)
    v.panel:SetFrameLevel(win:GetFrameLevel() + 40)
    v.panel:Show()
    SyncEvents()
    Paint(v)
end

-------------------------------------------------------------------------------
--  Bags: hooked into the bags refresh
-------------------------------------------------------------------------------
bagsView.count = function() return EUI_Bags.Header and EUI_Bags.Header.itemCount end
bagsView.goldRef = function() return EUI_Bags.Money end

-- after every bags refresh (FinishRefresh): over the item area while Bank is
-- selected or another character is picked, hidden otherwise. sidebarW: the
-- sidebar's current width.
function ns.OfflinePanel(sidebarW)
    local hdr = EUI_Bags.Header
    SyncTitle(bagsView, hdr and hdr.title, hdr and hdr.itemCount)
    local mode
    if ns.GetSelection() == BANK_VIEW and Offline.Enabled() then
        mode = "bank"
    elseif AltKey(bagsView) then
        mode = "bags"
    end
    local top = (hdr and hdr:GetHeight() or 35) + 1
    local bottom = EUI_Bags.Footer and EUI_Bags.Footer:GetHeight() or 30
    Place(bagsView, mode, sidebarW or 0, top, bottom)
end

-------------------------------------------------------------------------------
--  Bank window: another character's bank over the live one
-------------------------------------------------------------------------------
local EUI_Bank = bankView.win
if EUI_Bank then
    bankView.count = function() return EUI_Bank._headerItemCount end
    bankView.goldRef = function() return EUI_Bank._warbandGoldText end

    SyncBank = function()
        if not EUI_Bank:IsShown() then return end
        SyncTitle(bankView, EUI_Bank._headerTitle, EUI_Bank._headerItemCount)
        -- between the window's header and footer, sidebar included
        local sf = EUI_Bank._scrollFrame
        local _, _, _, _, top = sf:GetPoint(1)
        local _, _, _, _, bottom = sf:GetPoint(2)
        Place(bankView, AltKey(bankView) and "bank" or nil, 1, -(top or -30) + 1, bottom or 30)
    end

    if EUI_Bank.RefreshBank then hooksecurefunc(EUI_Bank, "RefreshBank", SyncBank) end
    EUI_Bank:HookScript("OnShow", SyncBank)
    EUI_Bank:HookScript("OnHide", function()
        bankView.key = nil
        Place(bankView, nil)
    end)
    -- the live bank resets the slot count while another character's shows
    if EUI_Bank._headerItemCount then
        hooksecurefunc(EUI_Bank._headerItemCount, "SetText", function(fs)
            if bankView.painting or bankView.mode ~= "bank" or not bankView.countText then return end
            bankView.painting = true
            fs:SetText(bankView.countText)
            bankView.painting = false
        end)
    end
else
    SyncBank = function() end
end

-- the option toggled: off leaves the Bank view for All Items and goes back to this character
function Offline.SyncButton()
    if not (EUI_Bags and EUI_Bags.RefreshInventory) then return end
    if not Offline.Enabled() then
        bagsView.key, bankView.key = nil, nil
        if ns.GetSelection() == BANK_VIEW then I.SetSelectedCategoryIndex(0) end
    end
    if EUI_Bags:IsVisible() then EUI_Bags:RefreshInventory() end
    SyncBank()
end

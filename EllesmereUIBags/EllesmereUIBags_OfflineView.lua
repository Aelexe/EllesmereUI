if EUI_CLIENT_BLOCKED then return end -- pre-12.1 client failsafe (EllesmereUI_ClientGate.lua)
-------------------------------------------------------------------------------
--  EllesmereUIBags_OfflineView.lua
--  offline bank views (data from EllesmereUIBags_Offline.lua):
--    * bags: an alt button, then "Name's Inventory". picking an alt shows
--      their bags and the sidebar counts/filters their stuff. bank in the
--      bags sidebar (selection -3) shows their bank or the warbank.
--    * bank window: same button and "Name's Bank". an alt's bank shows over
--      the live one, with their tabs over the live sidebar.
--
--  each view is a see-through panel over the window's items, which just fade
--  out underneath (alpha only, the secure buttons never move). the bags call
--  ns.OfflinePanel after every refresh, the bank hooks RefreshBank. our item
--  buttons are display only and never touch a real slot, so it's all safe in
--  combat. hover for tooltips, shift-click links, ctrl-click previews, and the
--  window's search filters it too.
-------------------------------------------------------------------------------
local EUI = EllesmereUI
local ns = select(2, ...)
local Offline = ns.Offline
local I = ns._bagsInternals
if not (Offline and I) then return end  -- wow forever, or a bags file didn't load

local GetItemInfo, GetItemInfoInstant = C_Item.GetItemInfo, C_Item.GetItemInfoInstant
local _emptyP = {}
local function BP() return (EUI._bagsDB and EUI._bagsDB.profile) or _emptyP end

local SLOT_SIZE, SPACING = 34, 4
local BAR_H, PAD = 24, 10  -- same height as the sidebar header
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

-- how old a save is, "3 days ago" style
local function Age(t)
    if type(t) ~= "number" then return nil end
    local s = math.max(time() - t, 0)
    if s < 60 then return EllesmereUI.L("just now") end
    return EllesmereUI.Lf("%1$s ago", SecondsToTime(s, false, false, 1))
end

-------------------------------------------------------------------------------
--  views: one per window. v.key is the picked alt (nil = this character),
--  v.mode is what the panel shows ("bags" | "bank" | nil).
-------------------------------------------------------------------------------
-- title text per window (functions so they read the current locale)
local bagsView = { win = EUI_Bags, viewTab = "bank", slots = {}, heads = {}, tabs = {},
    plain = function() return EllesmereUI.L("Inventory") end,
    word = function(name) return EllesmereUI.Lf("%1$s's Inventory", name) end }
local bankView = { win = _G.EUI_BankFrame, viewTab = "bank", slots = {}, heads = {}, tabs = {},
    plain = function() return EllesmereUI.L("Bank") end,
    word = function(name) return EllesmereUI.Lf("%1$s's Bank", name) end }
local views = { bagsView, bankView }
local moneyN = 0

local function ShownKey(v) return v.key or Offline.CurrentKey() end

-- v.viewTab: "bank" | "warband" (all tabs, by category), "onebank" |
-- "onewarband" (all tabs, one block) or "bank:2" | "warband:1" (one tab)
local function TabKind(v)
    local key = v.viewTab
    local one = key:sub(1, 3) == "one"
    if one then key = key:sub(4) end
    local kind, i = key:match("^(%a+):?(%d*)$")
    return kind or "bank", tonumber(i), one
end

-- drop a pick that doesn't resolve anymore (option off, forgotten, source changed)
local function AltKey(v)
    if not v.key then return nil end
    if not Offline.Enabled() or v.key == Offline.CurrentKey() or not Offline.Char(v.key) then
        v.key = nil
        return nil
    end
    return v.key
end

-- the alt whose bags are showing (nil if it's this character)
function ns.OfflineAlt() return AltKey(bagsView) end

-- the window's search, lower-cased ("" when empty)
local function Query(v)
    local box = v.win and v.win._searchBox
    return box and (box:GetText() or ""):lower() or ""
end

local Paint, PaintSide, SyncBank  -- forward

local function Repaint(v)
    if v.scroll then v.scroll:SetVerticalScroll(0) end
    Paint(v)
end

-- rebuild the window around a new pick
local function Rebuild(v)
    if v.scroll then v.scroll:SetVerticalScroll(0) end
    if v == bagsView then
        if EUI_Bags:IsVisible() and EUI_Bags.RefreshInventory then EUI_Bags:RefreshInventory() end
    else
        SyncBank()
    end
end

-------------------------------------------------------------------------------
--  the title: an alt button, then "Name's Inventory" (or "Name's Bank") for
--  whoever's showing.
-------------------------------------------------------------------------------
-- realm headers (only with more than one realm), then forget
local function OpenPicker(v, owner)
    if not EUI.ShowContextMenu then return end
    local items, realm = {}, nil
    local chars, realms = Offline.Characters(), {}
    for _, c in ipairs(chars) do realms[c.realm] = true end
    local manyRealms = next(realms) ~= nil and next(realms, next(realms)) ~= nil
    local function Off() return true end
    local shown = ShownKey(v)
    for _, c in ipairs(chars) do
        if manyRealms and c.realm ~= realm then
            realm = c.realm
            items[#items + 1] = { text = realm, noLoc = true, isDisabled = Off }
        end
        items[#items + 1] = { text = Hex(c.class) .. c.name .. "|r", noLoc = true, isActive = shown == c.key,
            onClick = function()
                v.key = not c.current and c.key or nil
                Rebuild(v)
            end }
    end
    if #chars < 2 then
        items[#items + 1] = { text = EllesmereUI.L("No other characters saved yet."), noLoc = true, isDisabled = Off }
    end
    local c = v.key and Offline.Char(v.key)
    if c and Offline.CanForget(v.key) then
        items[#items + 1] = "---"
        items[#items + 1] = { text = EllesmereUI.Lf("Forget %1$s", c.name or v.key), noLoc = true, onClick = function()
            Offline.Forget(v.key)
            v.key = nil
            Rebuild(v)
        end }
    end
    EUI.ShowContextMenu(owner, items, { below = true, fontKey = "bags" })
end

-- title: the window's title font string, count: the item count next to it
local function SyncTitle(v, title, count)
    if not (title and count) then return end
    local on = Offline.Enabled()
    if on and not v.pick then
        local hdr = title:GetParent()
        -- small square button with the person icon
        local b = CreateFrame("Button", nil, hdr)
        b:SetSize(20, 20)
        b.bg = b:CreateTexture(nil, "BACKGROUND")
        b.bg:SetAllPoints()
        b.bg:SetColorTexture(1, 1, 1, 0.06)
        if EUI.MakeBorder then EUI.MakeBorder(b, 1, 1, 1, 0.15, EUI.PP) end
        b.arrow = b:CreateTexture(nil, "OVERLAY")
        b.arrow:SetTexture("Interface\\AddOns\\EllesmereUI\\media\\icons\\eui-person.png")
        b.arrow:SetSize(14, 14)
        b.arrow:SetPoint("CENTER")
        b.arrow:SetAlpha(0.8)
        b:SetScript("OnClick", function(self) OpenPicker(v, self) end)
        b:SetScript("OnEnter", function(self)
            self.arrow:SetAlpha(1)
            self.bg:SetColorTexture(1, 1, 1, 0.14)
            EUI.ShowWidgetTooltip(self, EllesmereUI.L("Choose an alt"))
        end)
        b:SetScript("OnLeave", function(self)
            self.arrow:SetAlpha(0.8)
            self.bg:SetColorTexture(1, 1, 1, 0.06)
            EUI.HideWidgetTooltip()
        end)
        v.pick = { btn = b }
    end
    count:ClearAllPoints()
    local p = v.pick
    -- the button takes the title's spot (bags shift it for the sidebar arrow), the title goes after
    local pt, rel, relPt, x, y = title:GetPoint(1)
    if p and rel ~= p.btn then p.base = { pt, rel, relPt, x, y } end
    if p then p.btn:SetShown(on) end
    if not on then
        if p and p.base then
            title:ClearAllPoints()
            title:SetPoint(unpack(p.base))
        end
        title:SetText(v.plain())
        count:SetPoint("LEFT", title, "RIGHT", 8, 0)
        return
    end
    local c = Offline.Char(ShownKey(v))
    local name = (c and c.name) or UnitName("player") or ""
    local class = (c and c.class) or select(2, UnitClass("player"))
    title:SetText(v.word(Hex(class) .. name .. "|r"))
    p.btn:ClearAllPoints()
    p.btn:SetPoint("LEFT", p.base[2], p.base[3], p.base[4], p.base[5])
    title:ClearAllPoints()
    title:SetPoint("LEFT", p.btn, "RIGHT", 8, 0)
    count:SetPoint("LEFT", title, "RIGHT", 8, 0)
end

-- closing a window goes back to this character
EUI_Bags:HookScript("OnHide", function() bagsView.key = nil end)

-------------------------------------------------------------------------------
--  the panel: a bar (bank/warband, saved time, gold) over a scrolling grid
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
    local kind = TabKind(v)
    for _, t in ipairs(v.tabs) do
        local on = t.key == kind
        t.text:SetTextColor(on and 1 or 0.6, on and 1 or 0.6, on and 1 or 0.6)
        t.line:SetColorTexture(r, g, b, 1)
        t.line:SetShown(on)
        -- the bank window lists the tabs in its sidebar instead
        t:SetShown(v.mode == "bank" and not v.side)
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

    -- gold looks like the bags footer's (SmallMoneyFrameTemplate, 11pt)
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
--  item buttons (display only)
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
--  content
-------------------------------------------------------------------------------
-- the containers behind the view, and when they were saved
local function Containers(v)
    local list, saved
    local kind, i = TabKind(v)
    if v.mode == "bank" and kind == "warband" then
        local w = Offline.Warband()
        list, saved = w.tabs, w.time
    else
        local c = Offline.Char(ShownKey(v))
        if not c then return nil end
        if v.mode == "bags" then return c.bags, c.bagsTime end
        list, saved = c.bank, c.bankTime
    end
    -- one tab picked in the bank window's sidebar
    if i and v.mode == "bank" and type(list) == "table" then
        if not list[i] then return list, saved end
        return { list[i] }, saved
    end
    return list, saved
end

local waiting = false  -- item data asked for; one repaint when it lands

-- every saved item as a display entry with its bags category; one pass per
-- list, store rev and frame, so the sidebar counts and the paint share it
local pass = {}
local function Classified(list)
    local now = GetTime()
    if pass.list == list and pass.rev == Offline.Rev() and pass.time == now then
        return pass.items, pass.used, pass.total
    end
    local items, used, total = {}, 0, 0
    local mgr = _G.EUI_CategoryManager
    local cats = mgr and mgr:GetCategories()
    -- the catch-all once, not per item; disabled categories land in it
    local catchAll
    for i, cat in ipairs(cats or {}) do if cat.isCatchAll then catchAll = i end end
    local disabled = BP().bagDisabledCategories or _emptyP
    for _, t in ipairs(type(list) == "table" and list or {}) do
        if type(t) == "table" then
            total = total + (t.size or 0)
            for slot, link in pairs(type(t.links) == "table" and t.links or {}) do
                used = used + 1
                local id = Offline.LinkID(link)
                local _, _, q, _, _, _, _, _, _, icon = GetItemInfo(link)
                if q == nil then
                    waiting = true
                    if id then C_Item.RequestLoadItemDataByID(id) end
                end
                local idx = 0
                if cats then
                    idx = mgr:ClassifyItem(link, id, nil, nil, q or 1) or catchAll or #cats
                    local cat = cats[idx]
                    if catchAll and cat and cat._defaultName and disabled[cat._defaultName] then idx = catchAll end
                end
                local name = link:match("%[(.-)%]") or ""
                local _, _, _, _, instIcon, classID = GetItemInfoInstant(link)
                items[#items + 1] = {
                    link = link, id = id, name = name, lower = name:lower(), q = q or 1,
                    icon = icon or instIcon, cat = idx, n = (t.counts and t.counts[slot]) or 1,
                    gear = classID == ITEM_CLASS_WEAPON or classID == ITEM_CLASS_ARMOR,
                }
            end
        end
    end
    pass.list, pass.rev, pass.time = list, Offline.Rev(), now
    pass.items, pass.used, pass.total = items, used, total
    return items, used, total
end

-- the classified items, cut down to the search and the filter's categories
local function Collect(list, query, filter)
    local all, used, total = Classified(list)
    if query == "" and not filter then return all, used, total end
    local items = {}
    for _, it in ipairs(all) do
        if (query == "" or it.lower:find(query, 1, true)) and (not filter or filter[it.cat]) then
            items[#items + 1] = it
        end
    end
    return items, used, total
end

-- sidebar counts for the alt's bags
function ns.OfflineCounts()
    local c = Offline.Char(bagsView.key)
    local counts, total = {}, 0
    for _, it in ipairs((Classified(c and c.bags))) do
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
        local groups = Group(items)
        -- onebank / onewarbank: everything in one block, no headers
        if v.mode == "bank" and select(3, TabKind(v)) then
            local all = {}
            for _, g in ipairs(groups) do
                for _, it in ipairs(g.items) do all[#all + 1] = it end
            end
            groups = { { items = all } }
        end
        for _, g in ipairs(groups) do
            if g.name then
                nh = nh + 1
                local h = Head(v, nh)
                SetFont(h.label, titleSize)
                h:ClearAllPoints()
                h:SetPoint("TOPLEFT", PAD + 5, y)
                h:SetWidth(gridW)
                h.label:SetText(g.name .. " (" .. #g.items .. ")")
                h:Show()
                y = y - 22
            end
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

    -- nothing saved yet, so say how to fill it
    local empty
    if not list then
        if v.mode == "bags" then
            empty = EllesmereUI.L("This character's bags haven't been saved yet. Log in on this character once.")
        elseif TabKind(v) == "warband" then
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
    local warband = v.mode == "bank" and TabKind(v) == "warband"
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
    if v.side then PaintSide(v) end
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
        -- an alt's sidebar counts come from these same items
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
-- this character's own bags never show in a panel (they're live), so their
-- saves don't repaint anything
Offline.OnChange(function(what)
    if what == "bags" then return end
    for _, v in ipairs(views) do if v.panel and v.panel:IsShown() then Soon(v) end end
end)

-- the window's own content under the panel: faded out, never hidden or moved
local function Cover(v, on)
    if v.covered == on then return end
    v.covered = on
    for _, f in pairs(v.under and v.under() or {}) do f:SetAlpha(on and 0 or 1) end
end

-- show the panel over a window's item area, or hide it
local function Place(v, mode, left, top, bottom)
    v.mode = mode
    Cover(v, mode ~= nil)
    if v.side then v.side:SetShown(mode ~= nil) end
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
--  bags: hooked into the bags refresh
-------------------------------------------------------------------------------
bagsView.count = function() return EUI_Bags.Header and EUI_Bags.Header.itemCount end
bagsView.under = function() return { EUI_Bags._scrollFrame, EUI_Bags._scrollTrack } end
bagsView.goldRef = function() return EUI_Bags.Money end

-- runs after every bags refresh: covers the items while bank is picked or an
-- alt is showing, hidden otherwise. sidebarW is the sidebar's width.
function ns.OfflinePanel(sidebarW)
    local hdr = EUI_Bags.Header
    -- off: nothing to do unless it was on earlier and needs tidying up
    if not Offline.Enabled() then
        if bagsView.pick or bagsView.mode then
            SyncTitle(bagsView, hdr and hdr.title, hdr and hdr.itemCount)
            Place(bagsView, nil)
        end
        return
    end
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
--  bank window: an alt's bank over the live one
-------------------------------------------------------------------------------
local EUI_Bank = bankView.win
if EUI_Bank then
    bankView.count = function() return EUI_Bank._headerItemCount end
    bankView.goldRef = function() return EUI_Bank._warbandGoldText end
    bankView.under = function() return { EUI_Bank._scrollFrame, EUI_Bank._scrollTrack, EUI_Bank._sidebarSF } end

    -- the alt's tabs over the live sidebar list (header and arrow stay live), styled the same
    local ROW_H, ROW_PAD, ICON = 26, 2, 18
    local rows = {}
    local function Row(i)
        if rows[i] then return rows[i] end
        local b = CreateFrame("Button", nil, bankView.side)
        b:SetHeight(ROW_H)
        local px = (EUI.PP and EUI.PP.mult) or 1
        b.ind = b:CreateTexture(nil, "OVERLAY")
        b.ind:SetWidth(px * 2)
        b.ind:SetPoint("TOPLEFT")
        b.ind:SetPoint("BOTTOMLEFT")
        b.bg = b:CreateTexture(nil, "BACKGROUND", nil, 2)
        b.bg:SetAllPoints()
        b.icon = b:CreateTexture(nil, "ARTWORK")
        b.icon:SetSize(ICON, ICON)
        b.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        b.label = b:CreateFontString(nil, "OVERLAY")
        SetFont(b.label, 11)
        b.label:SetJustifyH("LEFT")
        b.label:SetWordWrap(false)
        b.label:SetPoint("LEFT", b.icon, "RIGHT", 6, 0)
        b.label:SetPoint("RIGHT", b, "RIGHT", -30, 0)
        b.count = b:CreateFontString(nil, "OVERLAY")
        SetFont(b.count, 10)
        b.count:SetJustifyH("RIGHT")
        b.count:SetTextColor(0.5, 0.5, 0.5)
        b.count:SetPoint("RIGHT", -6, 0)
        b:SetScript("OnClick", function(self)
            bankView.viewTab = self.key
            Repaint(bankView)
        end)
        b:SetScript("OnEnter", function(self)
            if not self.on then self.bg:SetColorTexture(1, 1, 1, 0.06) end
            if BP().bankSidebarCollapsed then EUI.ShowWidgetTooltip(self, self.name .. " (" .. self.n .. ")") end
        end)
        b:SetScript("OnLeave", function(self)
            if not self.on then self.bg:SetColorTexture(1, 1, 1, 0) end
            EUI.HideWidgetTooltip()
        end)
        rows[i] = b
        return b
    end

    local function Used(t)
        local n = 0
        for _ in pairs(type(t) == "table" and type(t.links) == "table" and t.links or {}) do n = n + 1 end
        return n
    end

    PaintSide = function(v)
        local side = v.side
        local c = Offline.Char(ShownKey(v))
        local entries = {}
        -- same layout as the live sidebar: all (tabs nested under it) and one, per kind
        local oneFirst = ns.BankDefaultsToOne and ns.BankDefaultsToOne()
        local function Add(kind, all, one, icon, oneIcon, tabs, bagKey)
            local total = 0
            for _, t in ipairs(tabs or {}) do total = total + Used(t) end
            local function All()
                entries[#entries + 1] = { key = kind, name = all, icon = icon, n = total }
                if BP().bankHideTabsInSidebar and BP().bankCategorySidebar then return end
                for i, t in ipairs(tabs or {}) do
                    if type(t) == "table" then
                        local bagID = Enum.BagIndex[bagKey .. i]
                        entries[#entries + 1] = { key = kind .. ":" .. i, nested = true,
                            name = (t.name and t.name ~= "") and t.name or EllesmereUI.Lf("Tab %1$d", i),
                            icon = ns.BankTabIcon and ns.BankTabIcon(bagID, t.icon) or t.icon or icon, n = Used(t) }
                    end
                end
            end
            local function One() entries[#entries + 1] = { key = "one" .. kind, name = one, icon = oneIcon, n = total } end
            local first = #entries + 1
            if oneFirst then One(); All() else All(); One() end
            -- the warbank's views sit apart from the bank's
            if first > 1 then entries[first].split = true end
        end
        Add("bank", EllesmereUI.L("All Bank Tabs"), EllesmereUI.L("OneBank"), 413587, 1542860, c and c.bank, "CharacterBankTab_")
        Add("warband", EllesmereUI.L("All Warbank Tabs"), EllesmereUI.L("OneWarbank"), 1542854, 1542854, Offline.Warband().tabs, "AccountBankTab_")

        local collapsed = BP().bankSidebarCollapsed
        local w = side:GetWidth()
        local r, g, b = 0.05, 0.82, 0.62
        if EUI.GetAccentColor then r, g, b = EUI.GetAccentColor() end
        local y = 0
        local px = (EUI.PP and EUI.PP.mult) or 1
        if not side._div then
            side._div = side:CreateTexture(nil, "ARTWORK")
            side._div:SetColorTexture(0.2, 0.2, 0.2, 1)
        end
        side._div:Hide()
        for i, e in ipairs(entries) do
            -- a divider like the live sidebar's
            if e.split then
                y = y - 4
                local inset = math.floor(w * 0.08)
                side._div:ClearAllPoints()
                side._div:SetHeight(px)
                side._div:SetPoint("TOPLEFT", side, "TOPLEFT", inset, y)
                side._div:SetPoint("TOPRIGHT", side, "TOPRIGHT", -inset, y)
                side._div:Show()
                y = y - px - 4
            end
            local row = Row(i)
            row.key, row.name, row.n = e.key, e.name, e.n
            row.on = e.key == v.viewTab
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", side, "TOPLEFT", 0, y)
            row:SetWidth(w)
            row.icon:ClearAllPoints()
            if collapsed then
                row.icon:SetPoint("CENTER")
            else
                row.icon:SetPoint("LEFT", 8 + (e.nested and 10 or 0), 0)
            end
            row.icon:SetTexture(EllesmereUI.ClientIcon and EllesmereUI.ClientIcon(e.icon) or e.icon)
            row.icon:SetAlpha(row.on and 1 or 0.75)
            row.label:SetShown(not collapsed)
            row.count:SetShown(not collapsed)
            row.label:SetText(e.name)
            row.label:SetTextColor(1, 1, 1, row.on and 1 or 0.75)
            row.count:SetText(e.n)
            row.ind:SetColorTexture(r, g, b, 1)
            row.ind:SetShown(row.on)
            row.bg:SetColorTexture(r, g, b, row.on and 0.1 or 0)
            if not row.on then row.bg:SetColorTexture(1, 1, 1, 0) end
            row:Show()
            y = y - ROW_H - ROW_PAD
        end
        for i = #entries + 1, #rows do rows[i]:Hide() end
    end

    SyncBank = function()
        if not EUI_Bank:IsShown() then return end
        if not Offline.Enabled() then
            if bankView.pick or bankView.mode then
                SyncTitle(bankView, EUI_Bank._headerTitle, EUI_Bank._headerItemCount)
                Place(bankView, nil)
            end
            return
        end
        SyncTitle(bankView, EUI_Bank._headerTitle, EUI_Bank._headerItemCount)
        local sf, list = EUI_Bank._scrollFrame, EUI_Bank._sidebarSF
        if not bankView.side and list then
            bankView.side = CreateFrame("Frame", nil, EUI_Bank)
            bankView.side:EnableMouse(true)
            bankView.side:Hide()
        end
        if bankView.side then
            bankView.side:ClearAllPoints()
            bankView.side:SetPoint("TOPLEFT", list, "TOPLEFT")
            bankView.side:SetPoint("BOTTOMRIGHT", list, "BOTTOMRIGHT")
            bankView.side:SetFrameLevel(EUI_Bank:GetFrameLevel() + 40)
        end
        -- between the window's header and footer, right of the sidebar
        local _, _, _, left, top = sf:GetPoint(1)
        local _, _, _, _, bottom = sf:GetPoint(2)
        Place(bankView, AltKey(bankView) and "bank" or nil, left or 0, -(top or -30), bottom or 30)
    end

    if EUI_Bank.RefreshBank then hooksecurefunc(EUI_Bank, "RefreshBank", SyncBank) end
    EUI_Bank:HookScript("OnShow", SyncBank)
    EUI_Bank:HookScript("OnHide", function()
        bankView.key, bankView.viewTab = nil, "bank"
        if bankView.mode then Place(bankView, nil) end
    end)
    -- the live bank keeps resetting the slot count while an alt's showing
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

-- option toggled off: leave the bank view for all items and go back to this character
function Offline.SyncButton()
    if not (EUI_Bags and EUI_Bags.RefreshInventory) then return end
    if not Offline.Enabled() then
        bagsView.key, bankView.key = nil, nil
        if ns.GetSelection() == BANK_VIEW then I.SetSelectedCategoryIndex(0) end
    end
    if EUI_Bags:IsVisible() then EUI_Bags:RefreshInventory() end
    SyncBank()
end

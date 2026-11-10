-- AttuneSight for Synastria / WoW 3.3.5a
-- Synastria 3.3.5a: show a non-invasive marker for BoE equipment for which
-- NO affix / forge variant has been attuned on the account.
-- Original BoE equipment stays eligible after it becomes soulbound.
-- No changes to Bagnon, inventory, items, or the underlying forge visuals.

local controller = CreateFrame('Frame')
local enabled, showEdge, apiReady = true, true, false
local markerStyle = 1 -- 1: badge, 2: ribbon, 3: dot
local markerSize = 16 -- default badge marker size; other styles scale proportionally
local markerCorner = 'TR' -- TR, TL, BR, BL, C
-- Separate RGBA colors for marker symbol and inner outline.  Keeping the
-- original dark badge/ribbon backgrounds prevents custom colors from vanishing.
local markerColor = {1, 1, 1, 1}
local outlineColor = {0.12, 0.95, 0.86, 0.72}
local attuneEventRegistered = false
local pendingScan, scanTimer = true, 0
local hookShows = setmetatable({}, {__mode = 'k'})
local settingsLoaded = false
local accountCache = {}
-- Item quality/equipment slots and template binding tags are stable by item ID.
-- Cache those only; per-slot tooltip fallbacks and account attunement progress
-- remain live. Negative item-info results expire quickly as the cache warms.
local equipmentCache, boeTemplateCache = {}, {}
local equipmentCacheSize, boeTemplateCacheSize = 0, 0
local visuals = setmetatable({}, {__mode = 'k'})
-- Capture actual Bagnon buttons through its own item-update callback.
-- The addon can reuse ContainerFrame buttons or create BagnonItemSlotN buttons.
local bagnonButtons = setmetatable({}, {__mode = 'k'})
local bagnonHookInstalled = false
local guildHookInstalled = false
local guildButtons = setmetatable({}, {__mode = 'k'})
local bankOpen, guildOpen = false, false
local itemFrameHookInstalled = false
local bagnonFrames = setmetatable({}, {__mode = 'k'})
-- Adapter registry: register actual item buttons, not global UI frame scans.
local omniButtons = setmetatable({}, {__mode = 'k'})
local externalButtons = setmetatable({}, {__mode = 'k'})
local omniBagHook, omniGuildHook = false, false

local scanTip = CreateFrame('GameTooltip', 'AttuneSightScanTooltip', UIParent, 'GameTooltipTemplate')
scanTip:SetOwner(UIParent, 'ANCHOR_NONE')

local function Inform(message)
    DEFAULT_CHAT_FRAME:AddMessage('|cffae83ffAttuneSight:|r ' .. message)
end

local function Positive(value)
    return value == true or (type(value) == 'number' and value > 0)
end

local function ItemId(link)
    return type(link) == 'string' and tonumber(string.match(link, 'item:(%d+)')) or nil
end

local function SafeCall(name, ...)
    local func = _G[name]
    if type(func) ~= 'function' then return nil end
    local ok, value = pcall(func, ...)
    if ok then return value end
    return nil
end

local function IsOriginallyBoE(source, bag, slot, itemId)
    local known = boeTemplateCache[itemId]
    if known ~= nil then return known end
    -- The item-template tag survives soulbinding. This is the primary test
    -- for inventory, personal bank, and guild bank alike.
    if type(GetItemTagsCustom) == 'function' and bit and bit.band then
        local ok, _, tags2, tags3 = pcall(GetItemTagsCustom, itemId)
        if ok and type(tags3) == 'number' then
            local originalBoE = bit.band(tags3, 1) ~= 0
            local originalBoP = type(tags2) == 'number' and bit.band(tags2, 128) ~= 0
            if originalBoE or originalBoP then
                if boeTemplateCacheSize >= 1024 then
                    wipe(boeTemplateCache)
                    boeTemplateCacheSize = 0
                end
                boeTemplateCache[itemId] = originalBoE
                boeTemplateCacheSize = boeTemplateCacheSize + 1
                return originalBoE
            end
        end
    end
    -- Only use live tooltips, not stored/offline bank item links.
    scanTip:SetOwner(UIParent, 'ANCHOR_NONE')
    scanTip:ClearLines()
    if source == 'guild' then
        if type(scanTip.SetGuildBankItem) ~= 'function' then return false end
        scanTip:SetGuildBankItem(bag, slot)
    elseif source == 'bankmain' then
        if type(BankButtonIDToInvSlotID) ~= 'function' then return false end
        scanTip:SetInventoryItem('player', BankButtonIDToInvSlotID(slot))
    else
        scanTip:SetBagItem(bag, slot)
    end
    for index = 2, scanTip:NumLines() do
        local region = _G['AttuneSightScanTooltipTextLeft' .. index]
        local value = region and region:GetText()
        if value == ITEM_BIND_ON_EQUIP then return true end
    end
    return false
end

local function IsSoulbound(bag, slot)
    -- Booleans and numeric 0/1 are both normalized safely.
    local result = SafeCall('Custom_IsContainerItemSoulbound', bag, slot)
    return Positive(result)
end

local function NewAccountAttune(itemId)
    -- Store both confirmed outcomes, but expire negative answers rapidly: the
    -- custom API may update account eligibility after a login or server sync.
    local now = GetTime()
    local old = accountCache[itemId]
    if old and now < old.untilTime then return old.value end

    local eligibleFn = _G.IsAttunableBySomeone
    local variantFn = _G.HasAttunedAnyVariantOfItem
    if type(eligibleFn) ~= 'function' or type(variantFn) ~= 'function' then return false end
    local okEligible, eligible = pcall(eligibleFn, itemId)
    if not okEligible then return false end
    local okVariant, already = pcall(variantFn, itemId)
    if not okVariant then return false end
    local value = Positive(eligible) and not Positive(already)
    accountCache[itemId] = {value = value, untilTime = now + (value and 30 or 5)}
    return value
end

local function Equipment(itemId)
    local now = GetTime()
    local cached = equipmentCache[itemId]
    if cached and now < cached.expires then return cached.eligible end
    local name, quality, equipLoc
    if type(GetItemInfoCustom) == 'function' then
        local ok, n, link, q, ilvl, minLevel, class, subClass, stack, loc = pcall(GetItemInfoCustom, itemId)
        if ok then name, quality, equipLoc = n, q, loc end
    end
    if not name or quality == nil or not equipLoc then
        local n, link, q, ilvl, minLevel, class, subClass, stack, loc = GetItemInfo(itemId)
        if n then name, quality, equipLoc = n, q, loc end
    end
    -- Uncommon quality and higher; equipped items only.
    local eligible = name ~= nil and type(quality) == 'number'
        and quality >= 2 and equipLoc ~= nil and equipLoc ~= ''
        and equipLoc ~= 'INVTYPE_BAG' and equipLoc ~= 'INVTYPE_QUIVER'
    if equipmentCacheSize >= 1024 then
        wipe(equipmentCache)
        equipmentCacheSize = 0
    end
    equipmentCache[itemId] = {eligible = eligible, expires = now + (name and 300 or 2)}
    equipmentCacheSize = equipmentCacheSize + 1
    return eligible
end

local function Qualifies(source, bag, slot)
    if not apiReady or type(slot) ~= 'number' or slot < 1 then return false end
    local link
    if source == 'guild' then
        if not guildOpen or not GetCurrentGuildBankTab or bag ~= GetCurrentGuildBankTab() then return false end
        link = GetGuildBankItemLink(bag, slot)
    elseif source == 'bankmain' then
        if not bankOpen then return false end
        link = GetInventoryItemLink('player', BankButtonIDToInvSlotID(slot))
    else
        if type(bag) ~= 'number' then return false end
        if bag == -1 then return false end -- bank main is handled separately
        if bag >= 5 and not bankOpen then return false end
        if bag < 0 or bag > 11 then return false end
        link = GetContainerItemLink(bag, slot)
    end
    local itemId = ItemId(link)
    if not itemId or not Equipment(itemId) then return false end
    if not IsOriginallyBoE(source, bag, slot, itemId) then return false end
    return NewAccountAttune(itemId)
end

-- Use an actual client texture for colored fills.  In the WotLK client,
-- passing raw RGBA components to SetTexture is not a reliable way to create
-- a solid fill: it may produce an uncolored/missing region.  This stock
-- ChatFrame texture exists in the 3.3.5 client and can be vertex-tinted.
local SOLID_TEXTURE = 'Interface\\ChatFrame\\ChatFrameBackground'
local function PaintSolid(texture, r, g, b, a)
    texture:SetTexture(SOLID_TEXTURE)
    texture:SetTexCoord(0, 1, 0, 1)
    texture:SetVertexColor(r, g, b)
    texture:SetAlpha(a or 1)
    texture:SetBlendMode('BLEND')
end

local BASE_TEXTURES = {
    'Interface\\AddOns\\AttuneSight\\Textures\\BadgeBase',
    'Interface\\AddOns\\AttuneSight\\Textures\\RibbonBase',
    'Interface\\AddOns\\AttuneSight\\Textures\\DotBase',
}
local TINT_TEXTURES = {
    'Interface\\AddOns\\AttuneSight\\Textures\\BadgeTint',
    'Interface\\AddOns\\AttuneSight\\Textures\\RibbonTint',
    'Interface\\AddOns\\AttuneSight\\Textures\\DotTint',
}
local STYLE_SIZES = {16, 17, 13}
local CORNER_ANCHORS = {TR='TOPRIGHT', TL='TOPLEFT', BR='BOTTOMRIGHT', BL='BOTTOMLEFT', C='CENTER'}
local function MarkerCornerAnchor()
    return CORNER_ANCHORS[markerCorner] or 'TOPRIGHT'
end
local function PositionMarker(marker, parent, offset)
    marker:ClearAllPoints()
    local point=MarkerCornerAnchor()
    if point == 'CENTER' then
        marker:SetPoint('CENTER', parent, 'CENTER', 0, 0)
        return
    end
    local x=(point=='TOPRIGHT' or point=='BOTTOMRIGHT') and -(offset or 1) or (offset or 1)
    local y=(point=='TOPRIGHT' or point=='TOPLEFT') and -1 or 1
    marker:SetPoint(point,parent,point,x,y)
end
local function ApplyRibbonOrientation(texture)
    -- Ribbon artwork is drawn for the TOPRIGHT corner. Mirror the art,
    -- rather than merely changing its anchor, for the other corners.
    if markerStyle ~= 2 then
        texture:SetTexCoord(0, 1, 0, 1)
    elseif markerCorner == 'TL' then
        texture:SetTexCoord(1, 0, 0, 1)
    elseif markerCorner == 'BR' then
        texture:SetTexCoord(0, 1, 1, 0)
    elseif markerCorner == 'BL' then
        texture:SetTexCoord(1, 0, 1, 0)
    else
        texture:SetTexCoord(0, 1, 0, 1)
    end
end
local function ApplyMarker(base, tint)
    local size = markerSize * STYLE_SIZES[markerStyle] / 16
    base:SetTexture(BASE_TEXTURES[markerStyle])
    base:SetSize(size, size)
    base:SetVertexColor(1, 1, 1)
    base:SetAlpha(1)
    tint:SetTexture(TINT_TEXTURES[markerStyle])
    tint:SetSize(size, size)
    tint:SetVertexColor(markerColor[1], markerColor[2], markerColor[3])
    tint:SetAlpha(markerColor[4])
    ApplyRibbonOrientation(base)
    ApplyRibbonOrientation(tint)
end
local function CopyColor(c)
    return {c[1], c[2], c[3], c[4]}
end
local function ValidColor(value, default)
    if type(value) ~= 'table' then return CopyColor(default) end
    local result = {}
    for i=1,4 do
        if type(value[i]) ~= 'number' or value[i] ~= value[i]
          or value[i] < 0 or value[i] > 1 then return CopyColor(default) end
        result[i] = value[i]
    end
    return result
end

local function NewVisual(button)
    local visual = visuals[button]
    if visual then return visual end

    -- Parent to the actual inventory button, not UIParent.  Bagnon hides
    -- item buttons immediately when its bags close; their children then
    -- hide with them, without waiting for the next scan tick.  This also
    -- keeps the overlay positioned during Bagnon frame movement/recycling.
    local overlay = CreateFrame('Frame', nil, button)
    overlay:SetAllPoints(button)
    overlay:SetFrameStrata(button:GetFrameStrata())
    overlay:SetFrameLevel(button:GetFrameLevel() + 12)
    overlay:EnableMouse(false)

    local marker = overlay:CreateTexture(nil, 'OVERLAY')
    local markerTint = overlay:CreateTexture(nil, 'OVERLAY')
    ApplyMarker(marker, markerTint)
    markerTint:SetPoint('TOPRIGHT', marker, 'TOPRIGHT')
    PositionMarker(marker, overlay, 2)

    local edges = {}
    for i = 1, 4 do
        local edge = overlay:CreateTexture(nil, 'OVERLAY')
        PaintSolid(edge, 1, 1, 1, 0.72)
        edges[i] = edge
    end
    -- Thin inset inner edge, distinct from the original forge border.
    edges[1]:SetPoint('TOPLEFT', overlay, 'TOPLEFT', 3, -3)
    edges[1]:SetPoint('TOPRIGHT', overlay, 'TOPRIGHT', -3, -3)
    edges[1]:SetHeight(1)
    edges[2]:SetPoint('BOTTOMLEFT', overlay, 'BOTTOMLEFT', 3, 3)
    edges[2]:SetPoint('BOTTOMRIGHT', overlay, 'BOTTOMRIGHT', -3, 3)
    edges[2]:SetHeight(1)
    edges[3]:SetPoint('TOPLEFT', overlay, 'TOPLEFT', 3, -3)
    edges[3]:SetPoint('BOTTOMLEFT', overlay, 'BOTTOMLEFT', 3, 3)
    edges[3]:SetWidth(1)
    edges[4]:SetPoint('TOPRIGHT', overlay, 'TOPRIGHT', -3, -3)
    edges[4]:SetPoint('BOTTOMRIGHT', overlay, 'BOTTOMRIGHT', -3, 3)
    edges[4]:SetWidth(1)

    overlay:Hide()
    visual = {overlay = overlay, marker = marker, markerTint = markerTint, edges = edges}
    visuals[button] = visual
    return visual
end

local function Update(button, source, bag, slot, cached)
    if not button then return end
    local highlighted = enabled and button:IsVisible() and not cached
        and type(bag) == 'number'
        and type(slot) == 'number' and Qualifies(source, bag, slot)
    -- Only allocate marker textures when an item actually qualifies.
    -- Hidden/recycled Bagnon buttons still have their previous marker cleared.
    local visual = visuals[button]
    if not highlighted and not visual then return end
    if highlighted and not visual then visual = NewVisual(button) end
    if highlighted then
        -- Track the slot's current draw layer as Bagnon recycles buttons.
        visual.overlay:SetFrameStrata(button:GetFrameStrata())
        visual.overlay:SetFrameLevel(button:GetFrameLevel() + 12)
        visual.overlay:Show()
        -- Synastria uses the top-right for its bounty icon. If that icon is
        -- present, keep AttuneSight's diamond to its immediate left.
        local buttonName = button:GetName()
        local bounty = buttonName and _G[buttonName .. 'BountyTex']
        visual.overlay:ClearAllPoints()
        visual.overlay:SetAllPoints(button)
        ApplyMarker(visual.marker, visual.markerTint)
        visual.marker:ClearAllPoints()
        local offset = (bounty and bounty:IsShown()) and 14 or 1
        if markerStyle == 2 then offset = offset + 1 end
        PositionMarker(visual.marker, visual.overlay, offset)
        visual.markerTint:Show()
        visual.marker:Show()
    else
        visual.markerTint:Hide()
        visual.marker:Hide()
        visual.overlay:Hide()
    end
    for _, edge in ipairs(visual.edges) do
        edge:SetVertexColor(outlineColor[1], outlineColor[2], outlineColor[3])
        edge:SetAlpha(outlineColor[4])
        if highlighted and showEdge then edge:Show() else edge:Hide() end
    end
end

local WatchShow
-- Optional, minimal adapter interface for other inventory addons. No
-- dependency on AttuneSight is required: it safely checks whether loaded.
-- Register only visible/live item buttons; callbacks are evaluated on refresh.
-- source: 'container' (bags 0-4 or bank bags 5-11), 'bankmain', 'guild'.
_G.AttuneSight_RegisterButton = function(button, getLocation)
    if not button or type(getLocation) ~= 'function' then return false end
    externalButtons[button] = getLocation
    WatchShow(button)
    pendingScan = true
    return true
end
_G.AttuneSight_UnregisterButton = function(button)
    if not button then return end
    externalButtons[button] = nil
    local visual = visuals[button]
    if visual then visual.overlay:Hide() end
end

local function UpdateOmni(button)
    if not button then return end
    local source, bag, slot
    if type(button.gbTab) == 'number' and type(button.gbSlot) == 'number' then
        source, bag, slot = 'guild', button.gbTab, button.gbSlot
    else
        bag, slot = button.bagID, button.slotID
        source = bag == -1 and 'bankmain' or 'container'
    end
    -- Omni's own offline/item-pool buttons can be hidden or detached.
    -- Qualifies() also requires an active bank session for bank sources.
    Update(button, source, bag, slot, false)
end

local function InstallOmniHooks()
    local omni = _G.OmniInventory
    if not omni or type(hooksecurefunc) ~= 'function' then return end
    local item = omni.ItemButton
    if not omniBagHook and item and type(item.SetItem) == 'function' then
        local ok = pcall(hooksecurefunc, item, 'SetItem', function(_, button)
            if not button then return end
            omniButtons[button] = true
            WatchShow(button)
            UpdateOmni(button)
        end)
        if ok then omniBagHook = true end
    end
    -- Omni guild slots are anonymous buttons, not Blizzard GuildBankColumn
    -- frames. The decoration method receives each actual button after render.
    if not omniGuildHook and item and type(item.UpdateGuildBankSlotDecorations) == 'function' then
        local ok = pcall(hooksecurefunc, item, 'UpdateGuildBankSlotDecorations', function(_, button)
            if not button then return end
            omniButtons[button] = true
            WatchShow(button)
            UpdateOmni(button)
        end)
        if ok then omniGuildHook = true end
    end
end

WatchShow = function(button)
    if hookShows[button] or not button.HookScript then return end
    hookShows[button] = true
    button:HookScript('OnShow', function() pendingScan = true end)
end

local function UpdateBagnon(button)
    WatchShow(button)
    local bag = button:GetBag()
    local cached = false
    if type(button.IsCached) == 'function' then
        local ok, answer = pcall(button.IsCached, button)
        cached = not ok or answer == true
    end
    -- Bagnon's bag view reuses Blizzard slot frames in some configurations.
    local source = bag == -1 and 'bankmain' or 'container'
    Update(button, source, bag, button:GetID(), cached)
end

-- Bagnon populates/reuses its slots independently of Blizzard container updates.
-- Hooking the class method gives us the real active button, even when its name
-- does not match a fixed pattern or Bagnon pools a Blizzard-created button.
local function InstallBagnonHook()
    if bagnonHookInstalled then return end
    local bagnon = _G.Bagnon
    local slotClass = bagnon and bagnon.ItemSlot
    if not slotClass or type(slotClass.Update) ~= 'function' then return end
    if type(hooksecurefunc) ~= 'function' then return end

    local ok = pcall(hooksecurefunc, slotClass, 'Update', function(button)
        if not button or not button.GetBag then return end
        bagnonButtons[button] = true
        -- Runs after Bagnon's own Update, so its item border/texture is set.
        UpdateBagnon(button)
    end)
    if ok then bagnonHookInstalled = true end
end

-- Bagnon guild bank uses an entirely separate item-slot class.
local function UpdateGuildBagnon(button)
    if not button or type(button.GetSlot) ~= 'function' then return end
    WatchShow(button)
    local tab, slot = button:GetSlot()
    Update(button, 'guild', tab, slot, not guildOpen or (button.IsCached and button:IsCached()))
end

local function InstallGuildBagnonHook()
    if guildHookInstalled then return end
    local cls = _G.Bagnon and _G.Bagnon.GuildItemSlot
    if not cls or type(cls.Update) ~= 'function' or type(hooksecurefunc) ~= 'function' then return end
    local ok = pcall(hooksecurefunc, cls, 'Update', function(button)
        if not button then return end
        guildButtons[button] = true
        UpdateGuildBagnon(button)
    end)
    if ok then guildHookInstalled = true end
end

-- The Bagnon slot pool contains hidden buttons. Track the actual active
-- ItemFrame layout, rather than treating a slot's bag/slot ID as proof that
-- its button is currently displayed.
local function InstallItemFrameHooks()
    if itemFrameHookInstalled then return end
    local cls = _G.Bagnon and _G.Bagnon.ItemFrame
    if not cls or type(cls.Layout) ~= 'function' then return end
    if type(hooksecurefunc) ~= 'function' then return end
    local ok = pcall(hooksecurefunc, cls, 'Layout', function(frame)
        if frame then
            bagnonFrames[frame] = true
            pendingScan = true
        end
    end)
    if ok then itemFrameHookInstalled = true end
end

local function ScanItemFrame(frame, visited)
    if not frame or not frame.IsVisible or not frame:IsVisible() then return end
    local slots = frame.itemSlots
    if type(slots) ~= 'table' then return end
    for _, button in pairs(slots) do
        if button and button.IsVisible and type(button.GetBag) == 'function' then
            bagnonButtons[button] = true
            if not visited[button] then visited[button] = true; UpdateBagnon(button) end
        end
    end
end

local function Scan()
    if not enabled then
        for _, visual in pairs(visuals) do
            visual.overlay:Hide()
            visual.marker:Hide()
            for _, edge in ipairs(visual.edges) do edge:Hide() end
        end
        return
    end
    InstallBagnonHook()
    InstallItemFrameHooks()
    InstallGuildBagnonHook()
    InstallOmniHooks()
    local visited = {}
    -- Iterate Bagnon's own active layout, which excludes recycled buttons.
    for frame in pairs(bagnonFrames) do ScanItemFrame(frame, visited) end
    -- Known Bagnon slot objects are tracked directly, including recycled
    -- Blizzard buttons that are renamed or bound to another bag/character.
    for button in pairs(bagnonButtons) do
        if not visited[button] and type(button.GetBag) == 'function' then
            visited[button] = true
            UpdateBagnon(button)
        end
    end
    -- Bagnon's separate guild item button pool.
    for button in pairs(guildButtons) do
        if not visited[button] then visited[button] = true; UpdateGuildBagnon(button) end
    end
    -- OmniInventory buttons are tracked by its real rendering methods,
    -- including anonymous guild-bank buttons and pooled grid/flow slots.
    for button in pairs(omniButtons) do
        if not visited[button] then
            visited[button] = true
            UpdateOmni(button)
        end
    end
    -- Third-party opt-in adapter: callback returns source, bag/tab, slot,
    -- cached. Never inspect offline bank contents or unregistered UI frames.
    for button, getLocation in pairs(externalButtons) do
        if not visited[button] then
            visited[button] = true
            local ok, source, bag, slot, cached = pcall(getLocation, button)
            if ok and (source == 'container' or source == 'bankmain' or source == 'guild') then
                Update(button, source, bag, slot, cached == true)
            else
                local visual = visuals[button]
                if visual then visual.overlay:Hide() end
            end
        end
    end
    -- Blizzard default personal bank uses BankFrameItem buttons.
    for index = 1, (NUM_BANKGENERIC_SLOTS or 28) do
        local button = _G['BankFrameItem' .. index]
        if button and not visited[button] then
            visited[button] = true
            Update(button, 'bankmain', -1, button:GetID(), false)
        end
    end
    -- Blizzard default guild bank (7 columns, 14 rows), current tab only.
    if guildOpen and GetCurrentGuildBankTab then
        local tab = GetCurrentGuildBankTab()
        for col = 1, 7 do
            for row = 1, 14 do
                local button = _G['GuildBankColumn' .. col .. 'Button' .. row]
                if button and not visited[button] then
                    visited[button] = true
                    Update(button, 'guild', tab, (col - 1) * 14 + row, false)
                end
            end
        end
    end
    -- Default Blizzard bags: inspect displayed frames only. Hidden buttons
    -- have child overlays that hide automatically, and OnShow requests a scan.
    -- Reparented Bagnon buttons are covered by the hooks and tracked tables.
    for frame = 1, (NUM_CONTAINER_FRAMES or 13) do
        local container = _G['ContainerFrame' .. frame]
        if container and container:IsShown() then
            for index = 1, (MAX_CONTAINER_ITEMS or 36) do
                local button = _G['ContainerFrame' .. frame .. 'Item' .. index]
                if button and not visited[button] then
                    visited[button] = true
                    if type(button.GetBag) == 'function' then
                        UpdateBagnon(button)
                    else
                        local parent = button:GetParent()
                        local bag = parent and parent:GetID()
                        if type(bag) == 'number' and bag >= 0 and bag <= 11 then
                            -- Blizzard button IDs already represent actual slots.
                            Update(button, 'container', bag, button:GetID(), false)
                        else
                            Update(button, 'container', -1, -1, false)
                        end
                    end
                end
            end
        end
    end
end

local function Initialize()
    if not apiReady then
        local ready = SafeCall('GetCustomGameData', 41, 0)
        if ready == nil or ready == 0 then return end
        apiReady = true
    end
    -- Only SYNASTRIA_ITEM_ATTUNED is verified in the extracted client bridge.
    -- Custom item-button-change and _EX events are not documented for this build.
    -- BAG_UPDATE and a throttled refresh remain our fallback for UI changes.
    if not attuneEventRegistered and type(RegisterForCustomEvent) == 'function' then
        local ok = pcall(RegisterForCustomEvent, 'SYNASTRIA_ITEM_ATTUNED', function()
            wipe(accountCache)
            pendingScan = true
            scanTimer = 0.12 -- scan next OnUpdate frame; don't alter in-flight UI callbacks
        end)
        if ok then attuneEventRegistered = true end
    end
    InstallBagnonHook()
    InstallItemFrameHooks()
    InstallGuildBagnonHook()
    InstallOmniHooks()
end

-- SafeInvoke accepts only the name of a global zero-argument function.
_G.AttuneSightInitialize = Initialize
-- Native Wrath of the Lich King Interface > AddOns settings.
-- Uses Blizzard UI widgets; inventory addons are optional.
-- The main AttuneSight category shows appearance settings; Tools is its only child.
local settingsPanel = CreateFrame('Frame', 'AttuneSightOptionsPanel', UIParent)
settingsPanel.name = 'AttuneSight'
local toolsPanel = CreateFrame('Frame', 'AttuneSightToolsPanel', UIParent)
toolsPanel.name = 'Tools'
toolsPanel.parent = 'AttuneSight'
local optionsTitle = settingsPanel:CreateFontString(nil, 'ARTWORK', 'GameFontNormalLarge')
optionsTitle:SetPoint('TOPLEFT', 18, -18)
optionsTitle:SetText('AttuneSight')
local sample = CreateFrame('Frame', nil, settingsPanel)
sample:SetSize(66, 66)
sample:SetPoint('TOPLEFT', 22, -76)
local sampleIcon = sample:CreateTexture(nil, 'BACKGROUND')
sampleIcon:SetAllPoints(sample)
sampleIcon:SetTexture('Interface\\Icons\\INV_Chest_Chain_05')
local sampleEdges = {}
for i=1,4 do
    local t = sample:CreateTexture(nil, 'BORDER')
    PaintSolid(t, 0.05, 0.91, 0.18, 1)
    sampleEdges[i] = t
end
sampleEdges[1]:SetPoint('TOPLEFT'); sampleEdges[1]:SetPoint('TOPRIGHT'); sampleEdges[1]:SetHeight(3)
sampleEdges[2]:SetPoint('BOTTOMLEFT'); sampleEdges[2]:SetPoint('BOTTOMRIGHT'); sampleEdges[2]:SetHeight(3)
sampleEdges[3]:SetPoint('TOPLEFT'); sampleEdges[3]:SetPoint('BOTTOMLEFT'); sampleEdges[3]:SetWidth(3)
sampleEdges[4]:SetPoint('TOPRIGHT'); sampleEdges[4]:SetPoint('BOTTOMRIGHT'); sampleEdges[4]:SetWidth(3)
local previewMark = sample:CreateTexture(nil, 'OVERLAY')
local previewTint = sample:CreateTexture(nil, 'OVERLAY')
previewMark:SetPoint('TOPRIGHT', sample, 'TOPRIGHT', -1, -1)
previewTint:SetPoint('TOPRIGHT', previewMark, 'TOPRIGHT')
local previewEdges = {}
for i=1,4 do
    local t=sample:CreateTexture(nil, 'OVERLAY')
    PaintSolid(t, 1, 1, 1, 0.85)
    previewEdges[i]=t
end
previewEdges[1]:SetPoint('TOPLEFT', sample, 'TOPLEFT', 5,-5)
previewEdges[1]:SetPoint('TOPRIGHT', sample, 'TOPRIGHT', -5,-5)
previewEdges[1]:SetHeight(2)
previewEdges[2]:SetPoint('BOTTOMLEFT', sample, 'BOTTOMLEFT', 5,5)
previewEdges[2]:SetPoint('BOTTOMRIGHT', sample, 'BOTTOMRIGHT', -5,5)
previewEdges[2]:SetHeight(2)
previewEdges[3]:SetPoint('TOPLEFT', sample, 'TOPLEFT', 5,-5)
previewEdges[3]:SetPoint('BOTTOMLEFT', sample, 'BOTTOMLEFT', 5,5)
previewEdges[3]:SetWidth(2)
previewEdges[4]:SetPoint('TOPRIGHT', sample, 'TOPRIGHT', -5,-5)
previewEdges[4]:SetPoint('BOTTOMRIGHT', sample, 'BOTTOMRIGHT', -5,5)
previewEdges[4]:SetWidth(2)
local previewCaption = settingsPanel:CreateFontString(nil, 'ARTWORK', 'GameFontHighlightSmall')
previewCaption:SetPoint('TOPLEFT', sample, 'BOTTOMLEFT', 0,-8)
previewCaption:SetText('Example item')

local previewStyleName = settingsPanel:CreateFontString(nil,'ARTWORK','GameFontNormal')
previewStyleName:SetPoint('TOPLEFT', 120, -84)
local previewDescription = settingsPanel:CreateFontString(nil,'ARTWORK','GameFontHighlight')
previewDescription:SetPoint('TOPLEFT', previewStyleName, 'BOTTOMLEFT', 0,-8)
previewDescription:SetWidth(390)
previewDescription:SetJustifyH('LEFT')

local styleNames = {'Diamond badge', 'Corner ribbon', 'White dot'}
local styleDescriptions = {
    'Bright diamond on a dark circular badge, clearly separated from item borders.',
    'Corner flag with a contrasting diamond.',
    'Small white dot with a contrasting dark outline.',
}
local styleButtons={}
local function RefreshOptionsPreview()
    ApplyMarker(previewMark, previewTint)
    PositionMarker(previewMark, sample, 1)
    for _, edge in ipairs(previewEdges) do
        edge:SetVertexColor(outlineColor[1], outlineColor[2], outlineColor[3])
        edge:SetAlpha(outlineColor[4])
        if showEdge then edge:Show() else edge:Hide() end
    end
    previewStyleName:SetText(styleNames[markerStyle])
    previewDescription:SetText(styleDescriptions[markerStyle])
    for i,radio in ipairs(styleButtons) do radio:SetChecked(i == markerStyle) end
    local cornerMenu = _G.AttuneSightCornerDropDown
    if cornerMenu and UIDropDownMenu_SetSelectedValue then
        UIDropDownMenu_SetSelectedValue(cornerMenu, markerCorner)
        UIDropDownMenu_SetText(cornerMenu, ({TR='Top right', TL='Top left', BR='Bottom right', BL='Bottom left', C='Center'})[markerCorner])
    end
end
local function RefreshMarkers()
    -- Coalesce rapid slider/color-picker changes into one next-frame scan.
    -- The 0.12-second throttle still governs event-driven bag refreshes.
    pendingScan = true
    scanTimer = 0.12
end
local function SelectMarkerStyle(index)
    markerStyle=index
    -- The ribbon needs a corner; never leave it floating in the center.
    if index == 2 and markerCorner == 'C' then
        markerCorner = 'TR'
        if settingsLoaded then AttuneSightDB.markerCorner = markerCorner end
    end
    if settingsLoaded then AttuneSightDB.markerStyle=index end
    RefreshOptionsPreview()
    RefreshMarkers()
end
local styleHeading = settingsPanel:CreateFontString(nil,'ARTWORK','GameFontNormal')
styleHeading:SetPoint('TOPLEFT', 22,-185)
styleHeading:SetText('Marker style')
for i=1,3 do
    local radio=CreateFrame('CheckButton',nil,settingsPanel,'UIRadioButtonTemplate')
    radio:SetPoint('TOPLEFT',22,-210 - (i-1)*29)
    local text=radio:CreateFontString(nil,'ARTWORK','GameFontHighlight')
    text:SetPoint('LEFT',radio,'RIGHT',5,0)
    text:SetText(styleNames[i])
    radio:SetScript('OnClick',function() SelectMarkerStyle(i) end)
    styleButtons[i]=radio
end
-- Native WotLK color picker; independent RGBA per symbol and outline.
-- The picker uses opacity = 1 - alpha, whereas texture:SetAlpha uses alpha.
local colorSwatches = {}
local function UpdateSwatches()
    for key, swatch in pairs(colorSwatches) do
        local c = key == 'marker' and markerColor or outlineColor
        swatch.swatchTexture:SetVertexColor(c[1], c[2], c[3])
        swatch.swatchTexture:SetAlpha(c[4])
    end
end
local function ApplyColorChange(key, color)
    if key == 'marker' then markerColor = color else outlineColor = color end
    if settingsLoaded then
        if key == 'marker' then AttuneSightDB.markerColor = CopyColor(color)
        else AttuneSightDB.outlineColor = CopyColor(color) end
    end
    UpdateSwatches()
    RefreshOptionsPreview()
    RefreshMarkers()
end
local function OpenColorPicker(key)
    if not ColorPickerFrame then return end
    local current = CopyColor(key == 'marker' and markerColor or outlineColor)
    local function ReadPicker()
        local r,g,b = ColorPickerFrame:GetColorRGB()
        local alpha = current[4]
        if OpacitySliderFrame then alpha = 1 - OpacitySliderFrame:GetValue() end
        return {r,g,b,math.max(0,math.min(1,alpha))}
    end
    ColorPickerFrame:Hide()
    ColorPickerFrame.hasOpacity = true
    ColorPickerFrame.opacity = 1 - current[4]
    ColorPickerFrame.func = function() ApplyColorChange(key, ReadPicker()) end
    ColorPickerFrame.opacityFunc = function() ApplyColorChange(key, ReadPicker()) end
    ColorPickerFrame.cancelFunc = function(previous)
        -- Do not depend on the client's historical previous-color format.
        ApplyColorChange(key, CopyColor(current))
    end
    ColorPickerFrame:SetColorRGB(current[1],current[2],current[3])
    ColorPickerFrame:Show()
end
local function AddColorControl(key, title, x, y)
    local label = settingsPanel:CreateFontString(nil, 'ARTWORK', 'GameFontNormal')
    label:SetPoint('TOPLEFT',x,y)
    label:SetText(title)
    local button = CreateFrame('Button', nil, settingsPanel, 'UIPanelButtonTemplate')
    button:SetSize(135,25)
    button:SetPoint('TOPLEFT',x,y-24)
    button:SetText('Choose color...')
    button:SetScript('OnClick', function() OpenColorPicker(key) end)
    local swatch = CreateFrame('Frame',nil,settingsPanel)
    swatch:SetSize(24,24)
    swatch:SetPoint('LEFT',button,'RIGHT',9,0)
    local t=swatch:CreateTexture(nil,'ARTWORK')
    PaintSolid(t,1,1,1,1)
    t:SetAllPoints(swatch)
    swatch.swatchTexture=t
    colorSwatches[key]=swatch
end
AddColorControl('marker','Marker symbol color',315,-185)
AddColorControl('outline','Inner outline color',315,-258)
local enableCheckbox=CreateFrame('CheckButton',nil,settingsPanel,'UICheckButtonTemplate')
enableCheckbox:SetPoint('TOPLEFT',18,-42)
local enableText=enableCheckbox:CreateFontString(nil,'ARTWORK','GameFontHighlight')
enableText:SetPoint('LEFT',enableCheckbox,'RIGHT',4,0)
enableText:SetText('Enable item markers')
enableCheckbox:SetScript('OnClick',function(self)
    enabled = self:GetChecked() == 1 or self:GetChecked() == true
    if settingsLoaded then AttuneSightDB.enabled=enabled end
    RefreshMarkers()
end)
local edgeCheckbox=CreateFrame('CheckButton',nil,settingsPanel,'UICheckButtonTemplate')
edgeCheckbox:SetPoint('LEFT',enableCheckbox,'RIGHT',185,0)
local edgeText=edgeCheckbox:CreateFontString(nil,'ARTWORK','GameFontHighlight')
edgeText:SetPoint('LEFT',edgeCheckbox,'RIGHT',4,0)
edgeText:SetText('Show inner outline')
edgeCheckbox:SetScript('OnClick',function(self)
    showEdge = self:GetChecked() == 1 or self:GetChecked() == true
    if settingsLoaded then AttuneSightDB.showEdge=showEdge end
    RefreshOptionsPreview()
    RefreshMarkers()
end)

-- Live size and corner controls. The marker stays a child of its slot.
local sizeHeading=settingsPanel:CreateFontString(nil,'ARTWORK','GameFontNormal')
sizeHeading:SetPoint('TOPLEFT',22,-315)
sizeHeading:SetText('Marker size')
local sizeValue=settingsPanel:CreateFontString(nil,'ARTWORK','GameFontHighlightSmall')
sizeValue:SetPoint('LEFT',sizeHeading,'RIGHT',12,0)
local sizeSlider=CreateFrame('Slider','AttuneSightMarkerSizeSlider',settingsPanel,'OptionsSliderTemplate')
sizeSlider:SetWidth(165)
sizeSlider:SetPoint('TOPLEFT',32,-347)
sizeSlider:SetMinMaxValues(10,50)
sizeSlider:SetValueStep(1)
_G[sizeSlider:GetName()..'Low']:SetText('10')
_G[sizeSlider:GetName()..'High']:SetText('50')
_G[sizeSlider:GetName()..'Text']:SetText('')
sizeSlider:SetScript('OnValueChanged',function(self,value)
    markerSize=math.floor(value+0.5)
    sizeValue:SetText(tostring(markerSize)..' px')
    if settingsLoaded then AttuneSightDB.markerSize=markerSize end
    RefreshOptionsPreview()
    RefreshMarkers()
end)
local cornerLabel=settingsPanel:CreateFontString(nil,'ARTWORK','GameFontNormal')
cornerLabel:SetPoint('TOPLEFT',315,-315)
cornerLabel:SetText('Marker corner')
local cornerNames={TR='Top right',TL='Top left',BR='Bottom right',BL='Bottom left',C='Center'}
local cornerOrder={'TR','TL','BR','BL','C'}
local cornerDropDown=CreateFrame('Frame','AttuneSightCornerDropDown',settingsPanel,'UIDropDownMenuTemplate')
cornerDropDown:SetPoint('TOPLEFT',308,-333)
local function SetCorner(value)
    if value == 'C' and markerStyle == 2 then return end
    markerCorner=value
    if settingsLoaded then AttuneSightDB.markerCorner=value end
    UIDropDownMenu_SetSelectedValue(cornerDropDown, value)
    UIDropDownMenu_SetText(cornerDropDown, cornerNames[value])
    RefreshOptionsPreview()
    RefreshMarkers()
end
UIDropDownMenu_SetWidth(cornerDropDown, 104)
UIDropDownMenu_Initialize(cornerDropDown, function(self, level)
    local info = UIDropDownMenu_CreateInfo()
    for _, value in ipairs(cornerOrder) do
        if not (markerStyle == 2 and value == 'C') then
            local choice = value
            info.text = cornerNames[choice]
            info.value = choice
            info.func = function() SetCorner(choice) end
            info.checked = (markerCorner == choice)
            UIDropDownMenu_AddButton(info, level)
        end
    end
end)
local toolsTitle=toolsPanel:CreateFontString(nil,'ARTWORK','GameFontNormalLarge')
toolsTitle:SetPoint('TOPLEFT',16,-16)
toolsTitle:SetText('AttuneSight Tools')
local toolsSubtitle=toolsPanel:CreateFontString(nil,'ARTWORK','GameFontHighlight')
toolsSubtitle:SetPoint('TOPLEFT',toolsTitle,'BOTTOMLEFT',0,-10)
toolsSubtitle:SetText('Maintenance and diagnostics for AttuneSight.')

local refreshButton=CreateFrame('Button',nil,toolsPanel,'UIPanelButtonTemplate')
refreshButton:SetSize(185, 24)
refreshButton:SetPoint('TOPLEFT',22,-72)
refreshButton:SetText('Refresh attunement data')
refreshButton:SetScript('OnClick',function()
    wipe(accountCache)
    RefreshMarkers()
    Inform('Attunement data refreshed.')
end)

local toolsExplain=toolsPanel:CreateFontString(nil,'ARTWORK','GameFontHighlightSmall')
toolsExplain:SetPoint('TOPLEFT',22,-104)
toolsExplain:SetWidth(560)
toolsExplain:SetJustifyH('LEFT')
toolsExplain:SetText('Use refresh after attuning items or when testing. Diagnostics print results in chat so you can paste them back here if something behaves unexpectedly.')

local diagnosticLabel=toolsPanel:CreateFontString(nil,'ARTWORK','GameFontNormal')
diagnosticLabel:SetPoint('TOPLEFT',22,-146)
diagnosticLabel:SetText('Diagnostics (item ID)')
local diagnosticInput=CreateFrame('EditBox',nil,toolsPanel,'InputBoxTemplate')
diagnosticInput:SetSize(105,22)
diagnosticInput:SetPoint('TOPLEFT',24,-169)
diagnosticInput:SetAutoFocus(false)
diagnosticInput:SetNumeric(true)
diagnosticInput:SetScript('OnEscapePressed',function(self) self:ClearFocus() end)
local checkButton=CreateFrame('Button',nil,toolsPanel,'UIPanelButtonTemplate')
checkButton:SetSize(92,23)
checkButton:SetPoint('LEFT',diagnosticInput,'RIGHT',15,0)
checkButton:SetText('Check item')
local uiButton=CreateFrame('Button',nil,toolsPanel,'UIPanelButtonTemplate')
uiButton:SetSize(100,23)
uiButton:SetPoint('LEFT',checkButton,'RIGHT',8,0)
uiButton:SetText('Check UI')
local function RunDiagnostic(mode)
    local id = tonumber(diagnosticInput:GetText())
    if not id or id < 1 then Inform('Enter a valid item ID.') return end
    diagnosticInput:ClearFocus()
    if SlashCmdList and SlashCmdList.ATTUNESIGHT then
        SlashCmdList.ATTUNESIGHT(mode .. ' ' .. id)
    end
end
checkButton:SetScript('OnClick',function() RunDiagnostic('check') end)
uiButton:SetScript('OnClick',function() RunDiagnostic('ui') end)

local quickHelp=toolsPanel:CreateFontString(nil,'ARTWORK','GameFontHighlightSmall')
quickHelp:SetPoint('TOPLEFT',22,-208)
quickHelp:SetWidth(560)
quickHelp:SetJustifyH('LEFT')
quickHelp:SetText('Chat commands still work: /attunesight on, /attunesight off, /attunesight edge, /attunesight style 1-3, /attunesight refresh, /attunesight check ITEMID, /attunesight ui ITEMID, /attunesight options')
settingsPanel:SetScript('OnShow',function()
    enableCheckbox:SetChecked(enabled)
    edgeCheckbox:SetChecked(showEdge)
    UpdateSwatches()
    sizeSlider:SetValue(markerSize)
    sizeValue:SetText(tostring(markerSize)..' px')
    UIDropDownMenu_SetSelectedValue(cornerDropDown, markerCorner)
    UIDropDownMenu_SetText(cornerDropDown, cornerNames[markerCorner])
    RefreshOptionsPreview()
end)
if type(InterfaceOptions_AddCategory) == 'function' then
    InterfaceOptions_AddCategory(settingsPanel)
    InterfaceOptions_AddCategory(toolsPanel)
end
controller:RegisterEvent('PLAYER_LOGIN')
controller:RegisterEvent('PLAYER_ENTERING_WORLD')
controller:RegisterEvent('BAG_UPDATE')
controller:RegisterEvent('ADDON_LOADED')
controller:RegisterEvent('BANKFRAME_OPENED')
controller:RegisterEvent('BANKFRAME_CLOSED')
controller:RegisterEvent('PLAYERBANKSLOTS_CHANGED')
controller:RegisterEvent('PLAYERBANKBAGSLOTS_CHANGED')
controller:RegisterEvent('GUILDBANKFRAME_OPENED')
controller:RegisterEvent('GUILDBANKFRAME_CLOSED')
controller:RegisterEvent('GUILDBANKBAGSLOTS_CHANGED')
controller:RegisterEvent('GUILDBANK_UPDATE_TABS')
controller:SetScript('OnEvent', function(_, event, addonName)
    if event == 'BANKFRAME_OPENED' then bankOpen = true end
    if event == 'BANKFRAME_CLOSED' then bankOpen = false end
    if event == 'GUILDBANKFRAME_OPENED' then guildOpen = true end
    if event == 'GUILDBANKFRAME_CLOSED' then guildOpen = false end
    if event == 'ADDON_LOADED' and addonName == 'AttuneSight' then
        AttuneSightDB = type(AttuneSightDB) == 'table' and AttuneSightDB or {}
        if type(AttuneSightDB.enabled) == 'boolean' then enabled = AttuneSightDB.enabled end
        if type(AttuneSightDB.showEdge) == 'boolean' then showEdge = AttuneSightDB.showEdge end
        if type(AttuneSightDB.markerStyle) == 'number'
            and AttuneSightDB.markerStyle >= 1 and AttuneSightDB.markerStyle <= 3 then
            markerStyle = AttuneSightDB.markerStyle
        end
        -- Migrate previous white/teal preference only on first use.
        local previous = AttuneSightDB.accentColor
        local markerDefault = previous == 2 and {0.12, 0.95, 0.86, 1} or {1, 1, 1, 1}
        local edgeDefault = previous == 1 and {1, 1, 1, 0.72} or {0.12, 0.95, 0.86, 0.72}
        markerColor = ValidColor(AttuneSightDB.markerColor, markerDefault)
        outlineColor = ValidColor(AttuneSightDB.outlineColor, edgeDefault)
        AttuneSightDB.markerColor = CopyColor(markerColor)
        AttuneSightDB.outlineColor = CopyColor(outlineColor)
        local savedSize=tonumber(AttuneSightDB.markerSize)
        if savedSize then markerSize=math.max(10,math.min(50,math.floor(savedSize))) end
        if cornerNames[AttuneSightDB.markerCorner] then markerCorner=AttuneSightDB.markerCorner end
        if markerStyle == 2 and markerCorner == 'C' then
            markerCorner = 'TR'
            AttuneSightDB.markerCorner = markerCorner
        end
        settingsLoaded = true
    end
    if event == 'ADDON_LOADED' then
        InstallBagnonHook()
        InstallItemFrameHooks()
        InstallGuildBagnonHook()
        InstallOmniHooks()
    end
    if event == 'PLAYER_LOGIN' or event == 'PLAYER_ENTERING_WORLD' then
        bankOpen, guildOpen = false, false
        wipe(accountCache)
        if type(SynastriaSafeInvoke) == 'function' then
            pcall(SynastriaSafeInvoke, 'AttuneSightInitialize')
        else
            Initialize()
        end
    end
    pendingScan = true
end)
controller:SetScript('OnUpdate', function(_, dt)
    scanTimer = scanTimer + dt
    if scanTimer < 0.12 then return end
    scanTimer = 0
    if not apiReady then Initialize() end
    if not pendingScan then return end
    pendingScan = false
    Scan()
end)

-- Diagnostic: /attunesight check ITEMID (does not change items or settings).
-- Reports the precise gate rejecting an item so the custom server API's
-- return conventions can be checked against the in-game tooltip.
local function ExplainVisual(itemId)
    local hits, visible, marked, bagnonHits = 0, 0, 0, 0
    local visibleTracked, matchedTracked = 0, 0
    local actualDisplayed, displayedMarked = 0, 0
    local function IsMatching(button)
        if not button or not button.GetBag then return false end
        local ok, bag = pcall(button.GetBag, button)
        if not ok or type(bag) ~= 'number' or bag < 0 or bag > 4 then return false end
        local slot = button:GetID()
        return type(slot) == 'number' and ItemId(GetContainerItemLink(bag, slot)) == itemId
    end
    for button, visual in pairs(visuals) do
        local matching = IsMatching(button)
        if not matching and not button.GetBag then
            local parent = button:GetParent()
            local bag = parent and parent:GetID()
            if type(bag) == 'number' and bag >= 0 and bag <= 4 then
                local slot = button:GetID()
                matching = ItemId(GetContainerItemLink(bag, slot)) == itemId
            end
        end
        if matching then
            hits = hits + 1
            if button:IsVisible() then visible = visible + 1 end
            if visual.marker:IsShown() then marked = marked + 1 end
            if type(button.GetBag) == 'function' then bagnonHits = bagnonHits + 1 end
        end
    end
    for button in pairs(bagnonButtons) do
        if button:IsVisible() then
            visibleTracked = visibleTracked + 1
            if IsMatching(button) then matchedTracked = matchedTracked + 1 end
        end
    end
    for frame in pairs(bagnonFrames) do
        if frame:IsVisible() and type(frame.itemSlots) == 'table' then
            for _, button in pairs(frame.itemSlots) do
                if button:IsVisible() and IsMatching(button) then
                    actualDisplayed = actualDisplayed + 1
                    local v = visuals[button]
                    if v and v.marker:IsShown() then displayedMarked = displayedMarked + 1 end
                end
            end
        end
    end
    Inform('UI '..itemId..' (bag-slot diagnostic): overlayButtons='..hits..', visible='..visible..', markersShown='..marked..', BagnonHook='..tostring(bagnonHookInstalled)..', trackedBagnon='..bagnonHits)
    Inform('  activeFrames='..tostring(itemFrameHookInstalled)..', visibleTracked='..visibleTracked..', matchingTracked='..matchedTracked..', visibleLayoutMatches='..actualDisplayed..', layoutMarkers='..displayedMarked)
    for button, visual in pairs(visuals) do
        if IsMatching(button) and button:IsVisible() then
            Inform('  rendering: parent='..(visual.overlay:GetParent() == button and 'button' or 'other')..', overlayShown='..tostring(visual.overlay:IsShown())..', strata='..tostring(visual.overlay:GetFrameStrata())..', markerStyle='..styleNames[markerStyle])
            break
        end
    end
end

local function ExplainItem(itemId)
    if not apiReady then Inform('Check: Synastria API is not initialized yet.'); return end
    local found = false
    for bag = 0, 4 do
        for slot = 1, GetContainerNumSlots(bag) do
            local link = GetContainerItemLink(bag, slot)
            if ItemId(link) == itemId then
                found = true
                local equip = Equipment(itemId)
                local soul = IsSoulbound(bag, slot)
                local boe = IsOriginallyBoE('container', bag, slot, itemId)
                local eligible = SafeCall('IsAttunableBySomeone', itemId)
                local checker = _G.HasAttunedAnyVariantOfItem
                local checkOK, anyAttuned = false, nil
                if type(checker) == 'function' then
                    checkOK, anyAttuned = pcall(checker, itemId)
                end
                local tags3
                if type(GetItemTagsCustom) == 'function' then
                    local ok, _, _, result = pcall(GetItemTagsCustom, itemId)
                    if ok then tags3 = result end
                end
                local function Show(v)
                    if v == nil then return 'nil' end
                    return tostring(v)
                end
                Inform('Check '..itemId..' bag '..bag..' slot '..slot..': equip='..Show(equip)..', currentlySoulbound='..Show(soul)..', originallyBoE='..Show(boe))
                Inform('  eligible='..Show(eligible)..', anyVariantAttuned='..Show(anyAttuned)..', checkOK='..Show(checkOK)..', tags3='..Show(tags3))
                if equip and boe and Positive(eligible) and checkOK and not Positive(anyAttuned) then
                    Inform('  Result: qualifies. If no marker is visible, use /attunesight ui '..itemId..'.')
                else
                    Inform('  Result: excluded. Original BoE must be established; current soulbinding is allowed.')
                end
            end
        end
    end
    if not found then Inform('Check: item '..itemId..' not found in current character bags (0-4).') end
end


-- WoW 3.3.5 only selects addon categories with rendered list buttons.
-- When the target is off-screen, scrolling first avoids reopening the
-- previously selected page. This matches Gear Mover's tested navigation.
local function OpenOptionsCategory(panel)
    if not panel or type(InterfaceOptionsFrame_OpenToCategory) ~= 'function' then return false end
    local categories = _G.INTERFACEOPTIONS_ADDONCATEGORIES
    local found, visibleIndex = false, 0
    if type(categories) == 'table' then
        for _, category in ipairs(categories) do
            if not category.hidden then
                if category == panel then found = true; break end
                visibleIndex = visibleIndex + 1
            end
        end
    end
    if not found then return false end

    if _G.InterfaceOptionsFrame and not InterfaceOptionsFrame:IsShown()
        and type(_G.InterfaceOptionsFrame_Show) == 'function' then
        InterfaceOptionsFrame_Show()
    end
    if _G.InterfaceOptionsFrameTab2 then InterfaceOptionsFrameTab2:Click() end
    if type(_G.InterfaceAddOnsList_Update) == 'function' then
        InterfaceAddOnsList_Update()
    end
    if type(_G.FauxScrollFrame_SetOffset) == 'function'
        and _G.InterfaceOptionsFrameAddOnsList then
        FauxScrollFrame_SetOffset(InterfaceOptionsFrameAddOnsList, math.max(0, visibleIndex - 1))
        if type(_G.InterfaceAddOnsList_Update) == 'function' then InterfaceAddOnsList_Update() end
    end
    local ok, err = pcall(InterfaceOptionsFrame_OpenToCategory, panel)
    if not ok then
        Inform('Settings navigation failed: ' .. tostring(err))
        return false
    end
    if _G.InterfaceOptionsFramePanelContainer
        and InterfaceOptionsFramePanelContainer.displayedPanel ~= panel
        and type(_G.InterfaceOptionsList_DisplayPanel) == 'function' then
        InterfaceOptionsList_DisplayPanel(panel)
    end
    return not _G.InterfaceOptionsFramePanelContainer
        or InterfaceOptionsFramePanelContainer.displayedPanel == panel
end

SLASH_ATTUNESIGHT1 = '/attunesight'
SLASH_ATTUNESIGHT2 = '/asight'
SLASH_ATTUNESIGHT3 = '/as'
SlashCmdList.ATTUNESIGHT = function(input)
    local cmd = string.lower(string.match(input or '', '^%s*(.-)%s*$'))
    if cmd == 'on' then enabled = true
    elseif cmd == 'off' then enabled = false
    elseif cmd == 'edge' then showEdge = not showEdge
    elseif string.match(cmd, '^style%s+[123]$') then
        SelectMarkerStyle(tonumber(string.match(cmd, '[123]')))
        Inform('Marker style: ' .. styleNames[markerStyle] .. '.')
        return
    elseif cmd == '' or cmd == 'options' then
        if not OpenOptionsCategory(settingsPanel) then
            Inform('Unable to select AttuneSight settings; open Interface > AddOns > AttuneSight manually.')
        end
        return
    elseif cmd == 'refresh' then wipe(accountCache)
    elseif string.match(cmd, '^ui%s+%d+$') then
        local id = tonumber(string.match(cmd, '%d+'))
        -- UI diagnostics need a current synchronous view.
        pendingScan = false
        Scan()
        ExplainVisual(id)
        return
    elseif string.match(cmd, '^check%s+%d+$') then
        local id = tonumber(string.match(cmd, '%d+'))
        ExplainItem(id)
        return
    else
        Inform('Commands: /attunesight options, on, off, edge, style 1-3, refresh, check ITEMID, ui ITEMID')
        return
    end
    RefreshMarkers()
    if settingsLoaded and (cmd == 'on' or cmd == 'off' or cmd == 'edge') then
        AttuneSightDB.enabled = enabled
        AttuneSightDB.showEdge = showEdge
    end
    if cmd == 'edge' then Inform('Subtle edge highlight ' .. (showEdge and 'on' or 'off') .. '.')
    elseif cmd == 'refresh' then Inform('Attunement data refreshed.')
    else Inform(enabled and 'Markers enabled.' or 'Markers disabled.') end
end

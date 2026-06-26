local ADDON, ns = ...
local json = ns.JSON

local CI = LibStub and LibStub("LibClassicInspector", true)
local cbHost = {}

local PREFIX = "|cff66ccffSSA|r: "
local function say(text)
    DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. text)
end

local db

local refreshDisplay, updateOverlay

local function inRaid()
    if IsInRaid then return IsInRaid() end
    return (GetNumRaidMembers and GetNumRaidMembers() or 0) > 0
end

local function inGroup()
    if IsInGroup then return IsInGroup() end
    if GetNumGroupMembers and GetNumGroupMembers() > 0 then return true end
    return (GetNumPartyMembers and GetNumPartyMembers() or 0) > 0
end

local function isActive()
    if not db or not db.enabled then return false end
    if db.raidOnly and not inRaid() then return false end
    return true
end

local function resolveChannel()
    local chan = db.announceChannel or "AUTO"
    if chan == "AUTO" then
        if inRaid() then return "RAID" end
        if inGroup() then return "PARTY" end
        return "PRIVATE"
    end
    if (chan == "RAID" or chan == "RAID_WARNING") and not inRaid() then
        return inGroup() and "PARTY" or "PRIVATE"
    end
    return chan
end

local function sendAnnounce(text)
    local chan = resolveChannel()
    if chan == "NONE" then return end
    if chan == "PRIVATE" then say(text) return end
    if chan then SendChatMessage(text, chan) end
end

local function groupUnits()
    local units = {}
    if inRaid() then
        for i = 1, GetNumGroupMembers() do units[#units + 1] = "raid" .. i end
    elseif inGroup() then
        for i = 1, GetNumGroupMembers() - 1 do units[#units + 1] = "party" .. i end
        units[#units + 1] = "player"
    else
        units[#units + 1] = "player"
    end
    return units
end

local function norm(s)
    return (s or ""):lower():gsub("[^a-z]", "")
end

local function stripDigits(s)
    return (s or ""):gsub("%d+$", "")
end

local function specMatches(assigned, actual)
    local a, b = norm(assigned), norm(actual)
    if a == "" or b == "" then return true end
    return a == b or a:find(b, 1, true) ~= nil or b:find(a, 1, true) ~= nil
end

local function dominantSpec(isInspect)
    if not GetTalentTabInfo then return nil end
    local numTabs = (GetNumTalentTabs and GetNumTalentTabs(isInspect)) or 3
    local bestName, bestPoints = nil, -1
    for i = 1, (numTabs or 3) do
        local name, _, pointsSpent = GetTalentTabInfo(i, isInspect)
        pointsSpent = pointsSpent or 0
        if name and pointsSpent > bestPoints then
            bestName, bestPoints = name, pointsSpent
        end
    end
    return bestName, bestPoints
end

local function expectedSpecFor(name)
    if not name then return nil end
    local key = name:lower()
    if db.overrides and db.overrides[key] then return db.overrides[key], true end
    local e = db.roster and db.roster[key]
    if e then return e.spec, false end
    return nil
end

local announced = {}
local observed = {}

local trackOrder = {}
local trackData = {}

local function recordChange(name, from, to, assigned)
    local key = name:lower()
    local prev = trackData[key]
    if not prev then trackOrder[#trackOrder + 1] = key end
    trackData[key] = {
        name = name, from = from, to = to, assigned = assigned,
        time = date("%H:%M:%S"),
        count = (prev and prev.count or 0) + 1,
    }
    if refreshDisplay then refreshDisplay() end
end

local SSA_SOUND = (SOUNDKIT and SOUNDKIT.RAID_WARNING) or 8959

local function notifyDeviation(name, expectedSpec, actualSpec)
    if not isActive() then return end
    local msg = string.format("%s signed up as %s but is playing %s",
        name, stripDigits(expectedSpec), actualSpec)

    sendAnnounce(msg)

    if db.notifyWarningText and RaidNotice_AddMessage and RaidWarningFrame then
        RaidNotice_AddMessage(RaidWarningFrame, msg, ChatTypeInfo and ChatTypeInfo["RAID_WARNING"])
    end
    if db.notifySound then pcall(PlaySound, SSA_SOUND, "Master") end
    if updateOverlay then updateOverlay() end
end

local function reportSpec(displayName, assignedSpec, actualSpec)
    local key = displayName:lower()
    if specMatches(assignedSpec, actualSpec) then
        announced[key] = nil
        return
    end
    if announced[key] == norm(actualSpec) then return end
    announced[key] = norm(actualSpec)
    recordChange(displayName, stripDigits(assignedSpec), actualSpec, assignedSpec)
    notifyDeviation(displayName, assignedSpec, actualSpec)
end

local function afterDelay(seconds, fn)
    if C_Timer and C_Timer.After then C_Timer.After(seconds, fn) else fn() end
end

local function unitSpecName(unit)
    if CI then
        local idx = CI:GetSpecialization(unit)
        if not idx then return nil end
        local _, class = UnitClass(unit)
        if not class then return nil end
        return CI:GetSpecializationName(class, idx)
    end
    if unit == "player" then return (dominantSpec(false)) end
    return nil
end

local function checkSelfAgainstRoster()
    local me = UnitName("player")
    local exp = expectedSpecFor(me)
    if exp then
        local actual = unitSpecName("player")
        if actual then reportSpec(me, exp, actual) end
    end
end

local function evaluateUnit(unit, name)
    if not isActive() then return end
    if not (unit and name) then return end
    if UnitIsUnit(unit, "player") then return end
    local actual = unitSpecName(unit)
    if not actual then return end
    local exp = expectedSpecFor(name)
    if exp then
        reportSpec(name, exp, actual)
    else
        local key = name:lower()
        local prev = observed[key]
        if prev and prev ~= actual then
            recordChange(name, prev, actual, nil)
            sendAnnounce(string.format("%s switched spec: %s -> %s", name, prev, actual))
        end
        observed[key] = actual
    end
end

local function startScan()
    if not isActive() then return end
    if not CI then return end
    for _, u in ipairs(groupUnits()) do
        if u ~= "player" and UnitExists(u) and not UnitIsUnit(u, "player") then
            local cached = select(1, CI:GetLastCacheTime(u))
            if cached and cached > 0 then
                evaluateUnit(u, UnitName(u))
            end
            CI:DoInspect(u)
        end
    end
end

local pendingSelf = false

local function checkSelfSwitch(initialOnly)
    pendingSelf = false
    local newSpec = unitSpecName("player")
    if not newSpec then return end
    local oldSpec = db.lastSpec
    if not initialOnly and oldSpec and oldSpec ~= newSpec then
        local me = UnitName("player") or "Someone"
        recordChange(me, oldSpec, newSpec, nil)
        sendAnnounce(string.format("%s switched spec: %s -> %s", me, oldSpec, newSpec))
    end
    db.lastSpec = newSpec
end

local function onTalentChange()
    if not isActive() then return end
    local me = UnitName("player")
    if me and expectedSpecFor(me) then
        checkSelfAgainstRoster()
    else
        if pendingSelf then return end
        pendingSelf = true
        afterDelay(1.5, function() checkSelfSwitch(false) end)
    end
end

local function checkSelf()
    if not isActive() then return end
    local me = UnitName("player")
    if me and expectedSpecFor(me) then
        checkSelfAgainstRoster()
    else
        checkSelfSwitch(false)
    end
end

local function buildRoster(text)
    local data, err = json.decode(text)
    if not data then return nil, "JSON parse failed: " .. tostring(err) end
    if type(data) ~= "table" or type(data.signUps) ~= "table" then
        return nil, "no signUps[] found -- is this a Raid-Helper export?"
    end
    local roster, count = {}, 0
    for _, s in ipairs(data.signUps) do
        if type(s) == "table" and s.name and s.specName then
            roster[s.name:lower()] = { name = s.name, spec = s.specName, class = s.className }
            count = count + 1
        end
    end
    if count == 0 then return nil, "found signUps but none had a spec." end
    return roster, count
end

local function doImport(text)
    local roster, countOrErr = buildRoster(text)
    if not roster then
        say("|cffff5555import failed|r: " .. tostring(countOrErr))
        return
    end
    db.roster = roster
    wipe(announced)
    wipe(observed)
    wipe(db.hidden)
    say(string.format("imported |cff00ff00%d|r signups. Use |cffffff00/ssa roster|r to see matches, |cffffff00/ssa scan|r to check now.", countOrErr))
end

local importFrame
local function showImportFrame()
    if not importFrame then
        local f = CreateFrame("Frame", "SSAImportFrame", UIParent, "BasicFrameTemplateWithInset")
        f:SetSize(520, 420)
        f:SetPoint("CENTER")
        f:SetMovable(true)
        f:EnableMouse(true)
        f:RegisterForDrag("LeftButton")
        f:SetScript("OnDragStart", f.StartMoving)
        f:SetScript("OnDragStop", f.StopMovingOrSizing)
        f:SetFrameStrata("DIALOG")

        local title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        title:SetPoint("TOP", 0, -5)
        title:SetText("Paste Raid-Helper JSON, then Import")

        local scroll = CreateFrame("ScrollFrame", "SSAImportScroll", f, "UIPanelScrollFrameTemplate")
        scroll:SetPoint("TOPLEFT", 12, -30)
        scroll:SetPoint("BOTTOMRIGHT", -32, 44)

        local edit = CreateFrame("EditBox", "SSAImportEdit", scroll)
        edit:SetMultiLine(true)
        edit:SetFontObject(ChatFontNormal)
        edit:SetWidth(460)
        edit:SetAutoFocus(false)
        edit:SetMaxLetters(0)
        edit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
        scroll:SetScrollChild(edit)
        f.edit = edit

        local importBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
        importBtn:SetSize(110, 24)
        importBtn:SetPoint("BOTTOMLEFT", 12, 12)
        importBtn:SetText("Import")
        importBtn:SetScript("OnClick", function()
            doImport(edit:GetText())
            f:Hide()
        end)

        local clearBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
        clearBtn:SetSize(110, 24)
        clearBtn:SetPoint("LEFT", importBtn, "RIGHT", 8, 0)
        clearBtn:SetText("Clear text")
        clearBtn:SetScript("OnClick", function() edit:SetText("") edit:SetFocus() end)

        importFrame = f
    end
    importFrame.edit:SetText("")
    importFrame:Show()
    importFrame.edit:SetFocus()
end

local function printRoster()
    if not db.roster then
        say("no roster loaded.")
        return
    end
    local present = {}
    for _, u in ipairs(groupUnits()) do
        local nm = UnitExists(u) and UnitName(u)
        if nm then present[nm:lower()] = true end
    end
    local total, matched = 0, 0
    for _, e in pairs(db.roster) do
        total = total + 1
        if present[e.name:lower()] then matched = matched + 1 end
    end
    say(string.format("roster: |cff00ff00%d|r signups, |cff00ff00%d|r currently in your group.", total, matched))
    if inGroup() then
        for _, e in pairs(db.roster) do
            if not present[e.name:lower()] then
                say(string.format("  |cff999999no match in group:|r %s (%s)", e.name, stripDigits(e.spec)))
            end
        end
    end
end

local displayFrame
local memberRows = {}

local CLASS_TOKENS = {
    WARRIOR = true, PALADIN = true, HUNTER = true, ROGUE = true, PRIEST = true,
    SHAMAN = true, MAGE = true, WARLOCK = true, DRUID = true, DEATHKNIGHT = true,
}

local function classToken(name)
    if not name then return nil end
    local t = name:upper():gsub("%s+", "")
    return CLASS_TOKENS[t] and t or nil
end

local function classColorStr(token)
    local colors = CUSTOM_CLASS_COLORS or RAID_CLASS_COLORS
    local c = token and colors and colors[token]
    if c then return string.format("|cff%02x%02x%02x", c.r * 255, c.g * 255, c.b * 255) end
    return "|cffffffff"
end

local SPEC_CLASS = {
    arms = "WARRIOR", fury = "WARRIOR", protection = "WARRIOR",
    holy1 = "PALADIN", protection1 = "PALADIN", retribution = "PALADIN",
    beastmastery = "HUNTER", marksmanship = "HUNTER", survival = "HUNTER",
    assassination = "ROGUE", combat = "ROGUE", subtlety = "ROGUE",
    discipline = "PRIEST", holy = "PRIEST", shadow = "PRIEST", smite = "PRIEST",
    elemental = "SHAMAN", enhancement = "SHAMAN", restoration1 = "SHAMAN",
    arcane = "MAGE", fire = "MAGE", frost = "MAGE",
    affliction = "WARLOCK", demonology = "WARLOCK", destruction = "WARLOCK",
    balance = "DRUID", dreamstate = "DRUID", feral = "DRUID",
    restoration = "DRUID", guardian = "DRUID",
}

local function classFromSpec(specName)
    return specName and SPEC_CLASS[specName:lower()] or nil
end

local function rosterClassToken(e)
    return classToken(e.className) or classFromSpec(e.spec)
end

local function gatherMembers()
    local list, seen = {}, {}
    local meLower = (UnitName("player") or ""):lower()
    for _, u in ipairs(groupUnits()) do
        if UnitExists(u) then
            local nm = UnitName(u)
            if nm and not seen[nm:lower()] then
                seen[nm:lower()] = true
                local _, class = UnitClass(u)
                list[#list + 1] = { name = nm, class = class, unit = u, present = true }
            end
        end
    end
    if db.showExpected and db.roster then
        for key, e in pairs(db.roster) do
            if not seen[key] and not db.hidden[key] then
                seen[key] = true
                list[#list + 1] = { name = e.name, class = rosterClassToken(e), unit = nil, present = false }
            end
        end
    end
    for _, m in ipairs(list) do
        local exp, isOverride = expectedSpecFor(m.name)
        m.expected = exp and stripDigits(exp) or nil
        m.override = isOverride
        if m.unit then
            m.actual = unitSpecName(m.unit)
        elseif m.name:lower() == meLower then
            m.actual = unitSpecName("player")
        end
    end
    table.sort(list, function(a, b)
        if a.present ~= b.present then return a.present end
        return a.name < b.name
    end)
    return list
end

local specMenu = CreateFrame("Frame", "SSASpecMenu", UIParent, "UIDropDownMenuTemplate")
local menuMember
local function specMenuInit(_, level)
    local m = menuMember
    if not m then return end
    local info
    if m.class and CI then
        for i = 1, 3 do
            local sName = CI:GetSpecializationName(m.class, i)
            if sName then
                info = UIDropDownMenu_CreateInfo()
                info.text = sName
                info.notCheckable = true
                info.func = function()
                    db.overrides[m.name:lower()] = sName
                    wipe(announced)
                    CloseDropDownMenus()
                    refreshDisplay()
                end
                UIDropDownMenu_AddButton(info, level)
            end
        end
    else
        info = UIDropDownMenu_CreateInfo()
        info.text = "|cff999999unknown class|r"
        info.notCheckable = true
        info.disabled = true
        UIDropDownMenu_AddButton(info, level)
    end
    info = UIDropDownMenu_CreateInfo()
    info.text = "Clear assignment"
    info.notCheckable = true
    info.func = function()
        db.overrides[m.name:lower()] = nil
        CloseDropDownMenus()
        refreshDisplay()
    end
    UIDropDownMenu_AddButton(info, level)
end
UIDropDownMenu_Initialize(specMenu, specMenuInit, "MENU")

local function removeMember(name)
    if not name then return end
    local key = name:lower()
    if db.roster then db.roster[key] = nil end
    db.overrides[key] = nil
    db.hidden[key] = true
    wipe(announced)
    refreshDisplay()
end

local CLASS_LIST = { "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "SHAMAN", "MAGE", "WARLOCK", "DRUID" }
local function classDisplayName(token)
    return (LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[token]) or token
end

local nameDialog, dialogClass, dialogEditKey

local function nameDialogApply()
    local newName = strtrim(nameDialog.edit:GetText() or "")
    if newName == "" then return end
    local nk = newName:lower()
    db.roster = db.roster or {}
    if dialogEditKey and dialogEditKey ~= nk then
        if db.roster[dialogEditKey] then db.roster[nk] = db.roster[dialogEditKey] end
        db.roster[dialogEditKey] = nil
        if db.overrides[dialogEditKey] then
            db.overrides[nk] = db.overrides[dialogEditKey]
            db.overrides[dialogEditKey] = nil
        end
        db.hidden[dialogEditKey] = nil
    end
    local entry = db.roster[nk] or { manual = true }
    entry.name = newName
    if dialogClass then entry.className = dialogClass end
    db.roster[nk] = entry
    db.hidden[nk] = nil
    if not dialogEditKey then db.showExpected = true end
    wipe(announced)
    nameDialog:Hide()
    if displayFrame and displayFrame.expectedCheck then
        displayFrame.expectedCheck:SetChecked(db.showExpected)
    end
    refreshDisplay()
end

local function buildNameDialog()
    local f = CreateFrame("Frame", "SSANameDialog", UIParent, "BasicFrameTemplateWithInset")
    f:SetSize(300, 160)
    f:SetPoint("CENTER")
    f:SetFrameStrata("FULLSCREEN_DIALOG")
    f:SetMovable(true); f:EnableMouse(true); f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetClampedToScreen(true)

    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.title:SetPoint("TOP", 0, -5)
    f.title:SetText("Add member")

    local nameLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    nameLabel:SetPoint("TOPLEFT", 16, -34)
    nameLabel:SetText("Character name")

    local edit = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
    edit:SetSize(160, 20)
    edit:SetPoint("TOPLEFT", 20, -50)
    edit:SetAutoFocus(false)
    edit:SetScript("OnEnterPressed", nameDialogApply)
    edit:SetScript("OnEscapePressed", function() f:Hide() end)
    f.edit = edit

    local classLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    classLabel:SetPoint("TOPLEFT", 16, -78)
    classLabel:SetText("Class")

    local dd = CreateFrame("Frame", "SSANameDialogClass", f, "UIDropDownMenuTemplate")
    dd:SetPoint("TOPLEFT", 2, -92)
    UIDropDownMenu_SetWidth(dd, 150)
    UIDropDownMenu_Initialize(dd, function(_, level)
        for _, tok in ipairs(CLASS_LIST) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = classDisplayName(tok)
            info.checked = (dialogClass == tok)
            info.func = function()
                dialogClass = tok
                UIDropDownMenu_SetText(dd, classDisplayName(tok))
                CloseDropDownMenus()
            end
            UIDropDownMenu_AddButton(info, level)
        end
    end)
    f.classDD = dd

    local ok = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    ok:SetSize(80, 22); ok:SetPoint("BOTTOMRIGHT", -12, 10); ok:SetText("Save")
    ok:SetScript("OnClick", nameDialogApply)

    local cancel = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    cancel:SetSize(80, 22); cancel:SetPoint("RIGHT", ok, "LEFT", -6, 0); cancel:SetText("Cancel")
    cancel:SetScript("OnClick", function() f:Hide() end)

    nameDialog = f
end

local function openNameDialog(mode, member)
    if mode == "edit" and member and member.present then
        say("can't rename a player who's in the group -- use Set to change their expected spec.")
        return
    end
    if not nameDialog then buildNameDialog() end
    if mode == "edit" and member then
        dialogEditKey = member.name:lower()
        dialogClass = member.class
        nameDialog.title:SetText("Edit member")
        nameDialog.edit:SetText(member.name)
    else
        dialogEditKey = nil
        dialogClass = nil
        nameDialog.title:SetText("Add member")
        nameDialog.edit:SetText("")
    end
    UIDropDownMenu_SetText(nameDialog.classDD, dialogClass and classDisplayName(dialogClass) or "Pick class")
    nameDialog:Show()
    nameDialog.edit:SetFocus()
end

local function acquireRow(parent, i)
    local r = memberRows[i]
    if not r then
        r = CreateFrame("Frame", nil, parent)
        r:SetHeight(20)
        r.icon = r:CreateTexture(nil, "ARTWORK")
        r.icon:SetSize(18, 18)
        r.icon:SetPoint("LEFT", 0, 0)
        r.name = r:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        r.name:SetPoint("LEFT", r.icon, "RIGHT", 4, 0)
        r.name:SetWidth(104); r.name:SetJustifyH("LEFT")
        r.nameBtn = CreateFrame("Button", nil, r)
        r.nameBtn:SetAllPoints(r.name)
        r.nameBtn:SetScript("OnClick", function(self)
            local m = self:GetParent().member
            if m and not m.present then openNameDialog("edit", m) end
        end)
        r.nameBtn:SetScript("OnEnter", function(self)
            local m = self:GetParent().member
            if not (m and not m.present) then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText("Click to edit name / class", nil, nil, nil, nil, true)
            GameTooltip:Show()
        end)
        r.nameBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
        r.expected = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        r.expected:SetPoint("LEFT", r.name, "RIGHT", 2, 0)
        r.expected:SetWidth(92); r.expected:SetJustifyH("LEFT")
        r.expectedBtn = CreateFrame("Button", nil, r)
        r.expectedBtn:SetAllPoints(r.expected)
        r.expectedBtn:SetScript("OnClick", function(self)
            menuMember = self:GetParent().member
            ToggleDropDownMenu(1, nil, specMenu, self, 0, 0)
        end)
        r.expectedBtn:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText("Click to set expected spec", nil, nil, nil, nil, true)
            GameTooltip:Show()
        end)
        r.expectedBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
        r.actual = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        r.actual:SetPoint("LEFT", r.expected, "RIGHT", 2, 0)
        r.actual:SetWidth(92); r.actual:SetJustifyH("LEFT")

        r.del = CreateFrame("Button", nil, r, "UIPanelCloseButton")
        r.del:SetSize(22, 22)
        r.del:SetPoint("RIGHT", r, "RIGHT", 2, 0)
        r.del:SetScript("OnClick", function(self)
            local m = self:GetParent().member
            if m then removeMember(m.name) end
        end)

        memberRows[i] = r
    end
    r:SetParent(parent)
    return r
end

local offspecOverlay

local function gatherOffspec()
    local out = {}
    for _, u in ipairs(groupUnits()) do
        if UnitExists(u) then
            local nm = UnitName(u)
            local exp = nm and expectedSpecFor(nm)
            if exp then
                local actual = unitSpecName(u)
                if actual and not specMatches(exp, actual) then
                    out[#out + 1] = { name = nm, expected = stripDigits(exp), actual = actual }
                end
            end
        end
    end
    return out
end

local function buildOverlay()
    local f = CreateFrame("Frame", "SSAOverlay", UIParent, "BackdropTemplate")
    f:SetSize(220, 40)
    local p = db.overlayPos
    f:SetPoint(p and p.point or "TOP", UIParent, p and p.point or "TOP", p and p.x or 0, p and p.y or -140)
    if f.SetBackdrop then
        f:SetBackdrop({
            bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 12,
            insets = { left = 3, right = 3, top = 3, bottom = 3 },
        })
        f:SetBackdropColor(0, 0, 0, 0.7)
        f:SetBackdropBorderColor(1, 0.2, 0.2, 0.8)
    end
    f:SetMovable(true); f:EnableMouse(true); f:RegisterForDrag("LeftButton")
    f:SetClampedToScreen(true)
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, _, x, y = self:GetPoint()
        db.overlayPos = { point = point, x = x, y = y }
    end)
    local t = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    t:SetPoint("TOPLEFT", 8, -8)
    t:SetPoint("RIGHT", -8, 0)
    t:SetJustifyH("LEFT")
    f.text = t
    offspecOverlay = f
end

updateOverlay = function()
    if not db or not db.overlay or not isActive() then
        if offspecOverlay then offspecOverlay:Hide() end
        return
    end
    local off = gatherOffspec()
    if #off == 0 then
        if offspecOverlay then offspecOverlay:Hide() end
        return
    end
    if not offspecOverlay then buildOverlay() end
    local lines = {}
    for _, o in ipairs(off) do
        lines[#lines + 1] = string.format("|cffff5555%s|r %s |cffaaaaaa(want %s)|r", o.name, o.actual, o.expected)
    end
    offspecOverlay.text:SetText("|cffff2020Off-spec:|r\n" .. table.concat(lines, "\n"))
    offspecOverlay:SetHeight((offspecOverlay.text:GetStringHeight() or 12) + 16)
    offspecOverlay:Show()
end

refreshDisplay = function()
    updateOverlay()
    if not displayFrame or not displayFrame:IsShown() then return end
    local content = displayFrame.content
    if displayFrame.scroll then content:SetWidth(displayFrame.scroll:GetWidth()) end
    local members = gatherMembers()
    local y = 0
    for i, m in ipairs(members) do
        local r = acquireRow(content, i)
        r.member = m
        r.nameBtn:SetShown(not m.present)
        r:ClearAllPoints()
        r:SetPoint("TOPLEFT", 0, -y)
        r:SetPoint("RIGHT", content, "RIGHT", 0, 0)

        if m.class and CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[m.class] then
            r.icon:SetTexture("Interface\\GLUES\\CHARACTERCREATE\\UI-CHARACTERCREATE-CLASSES")
            r.icon:SetTexCoord(unpack(CLASS_ICON_TCOORDS[m.class]))
            r.icon:Show()
        else
            r.icon:Hide()
        end

        if m.present then
            r.name:SetText(classColorStr(m.class) .. m.name .. "|r")
        else
            r.name:SetText("|cff777777" .. m.name .. " (away)|r")
        end

        if m.expected then
            r.expected:SetText((m.override and "|cff66ccff*" or "|cffdddddd") .. m.expected .. "|r")
        else
            r.expected:SetText("|cff6699cc<set spec>|r")
        end

        if m.actual then
            local color = "|cffffffff"
            if m.expected then
                color = specMatches(m.expected, m.actual) and "|cff33ff33" or "|cffff3333"
            end
            r.actual:SetText(color .. m.actual .. "|r")
        else
            r.actual:SetText(m.present and "|cff777777...|r" or "|cff555555-|r")
        end

        r:Show()
        y = y + 21
    end
    for i = #members + 1, #memberRows do memberRows[i]:Hide() end
    content:SetHeight(math.max(y, 10))
    if displayFrame.empty then displayFrame.empty:SetShown(#members == 0) end

    local off = 0
    for _, m in ipairs(members) do
        if m.expected and m.actual and not specMatches(m.expected, m.actual) then
            off = off + 1
        end
    end
    if displayFrame.title then
        local t = string.format("Spec Board  |cffaaaaaa(%d)|r", #members)
        if off > 0 then t = t .. string.format("   |cffff5555%d off-spec|r", off) end
        displayFrame.title:SetText(t)
    end
end

local function showDisplay()
    if not displayFrame then
        local f = CreateFrame("Frame", "SSADisplayFrame", UIParent, "BasicFrameTemplateWithInset")
        f:SetSize(420, 400)
        f:SetPoint("CENTER", 300, 0)
        f:SetMovable(true)
        f:EnableMouse(true)
        f:RegisterForDrag("LeftButton")
        f:SetScript("OnDragStart", f.StartMoving)
        f:SetScript("OnDragStop", f.StopMovingOrSizing)
        f:SetClampedToScreen(true)

        local title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        title:SetPoint("TOP", 0, -5)
        title:SetText("Spec Board")
        f.title = title

        f:SetResizable(true)
        if f.SetResizeBounds then
            f:SetResizeBounds(340, 200, 760, 800)
        else
            if f.SetMinResize then f:SetMinResize(340, 200) end
            if f.SetMaxResize then f:SetMaxResize(760, 800) end
        end
        local grip = CreateFrame("Button", nil, f)
        grip:SetSize(16, 16)
        grip:SetPoint("BOTTOMRIGHT", -3, 3)
        grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
        grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
        grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
        grip:SetScript("OnMouseDown", function() f:StartSizing("BOTTOMRIGHT") end)
        grip:SetScript("OnMouseUp", function()
            f:StopMovingOrSizing()
            db.board.w, db.board.h = f:GetWidth(), f:GetHeight()
            refreshDisplay()
        end)
        f:SetScript("OnSizeChanged", function() refreshDisplay() end)

        local cb = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
        cb:SetSize(22, 22)
        cb:SetPoint("TOPLEFT", 10, -26)
        local cbl = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        cbl:SetPoint("LEFT", cb, "RIGHT", 1, 0)
        cbl:SetText("Show expected (not in group)")
        cb:SetScript("OnClick", function(self)
            db.showExpected = self:GetChecked() and true or false
            refreshDisplay()
        end)
        f.expectedCheck = cb

        local scanBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
        scanBtn:SetSize(64, 20)
        scanBtn:SetPoint("TOPRIGHT", -28, -24)
        scanBtn:SetText("Scan")
        scanBtn:SetScript("OnClick", function()
            checkSelf(); startScan(); refreshDisplay()
        end)

        local addBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
        addBtn:SetSize(54, 20)
        addBtn:SetPoint("RIGHT", scanBtn, "LEFT", -4, 0)
        addBtn:SetText("Add")
        addBtn:SetScript("OnClick", function() openNameDialog("add") end)

        local hName = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        hName:SetPoint("TOPLEFT", 34, -52); hName:SetText("Member")
        local hExp = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        hExp:SetPoint("TOPLEFT", 140, -52); hExp:SetText("Expected")
        local hAct = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        hAct:SetPoint("TOPLEFT", 236, -52); hAct:SetText("Actual")

        local scroll = CreateFrame("ScrollFrame", "SSADisplayScroll", f, "UIPanelScrollFrameTemplate")
        scroll:SetPoint("TOPLEFT", 12, -66)
        scroll:SetPoint("BOTTOMRIGHT", -30, 12)
        local content = CreateFrame("Frame", nil, scroll)
        content:SetSize(366, 10)
        scroll:SetScrollChild(content)
        f.content = content
        f.scroll = scroll

        local empty = content:CreateFontString(nil, "OVERLAY", "GameFontDisableLeft")
        empty:SetPoint("TOPLEFT", 2, -2)
        empty:SetWidth(360); empty:SetJustifyH("LEFT")
        empty:SetText("No members. Join a group, import a roster, or tick 'Show expected'.")
        f.empty = empty

        f:SetScript("OnShow", function()
            f.expectedCheck:SetChecked(db.showExpected)
            refreshDisplay()
        end)
        displayFrame = f
    end
    if db.board and db.board.w then
        displayFrame:SetSize(db.board.w, db.board.h)
    end
    displayFrame.expectedCheck:SetChecked(db.showExpected)
    displayFrame:Show()
    refreshDisplay()
end

local optionsPanel, settingsCategory

local function openOptions()
    if settingsCategory and Settings and Settings.OpenToCategory then
        Settings.OpenToCategory(settingsCategory:GetID())
    elseif InterfaceOptionsFrame_OpenToCategory then
        InterfaceOptionsFrame_OpenToCategory(optionsPanel)
        InterfaceOptionsFrame_OpenToCategory(optionsPanel)
    else
        say("couldn't find the options menu API; use the slash commands instead.")
    end
end

local function setEnabled(v)
    db.enabled = v and true or false
    if db.enabled then
        checkSelf()
        startScan()
    end
    if updateOverlay then updateOverlay() end
    if refreshDisplay then refreshDisplay() end
    say(db.enabled and "|cff00ff00enabled|r -- watching for off-spec players."
                    or "|cffff5555disabled|r -- no scanning, warnings, or overlay.")
end

local function buildOptionsPanel()
    local panel = CreateFrame("Frame", "SSAOptionsPanel", UIParent)
    panel.name = "Spec Switch Announce"
    local refreshers = {}

    local scroll = CreateFrame("ScrollFrame", "SSAOptScroll", panel, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 8, -8)
    scroll:SetPoint("BOTTOMRIGHT", -28, 8)
    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(560, 10)
    scroll:SetScrollChild(content)
    scroll:EnableMouseWheel(true)
    scroll:SetScript("OnMouseWheel", function(self, delta)
        local newv = self:GetVerticalScroll() - delta * 36
        newv = math.max(0, math.min(newv, self:GetVerticalScrollRange()))
        self:SetVerticalScroll(newv)
    end)

    local CONTENT_W = 560
    local y = 12

    local function addTitle(text)
        local h = content:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
        h:SetPoint("TOPLEFT", content, "TOPLEFT", 10, -y)
        h:SetText(text)
        y = y + 28
    end

    local function addHeader(text)
        y = y + 6
        local h = content:CreateFontString(nil, "ARTWORK", "GameFontNormal")
        h:SetPoint("TOPLEFT", content, "TOPLEFT", 10, -y)
        h:SetText("|cffffd100" .. text .. "|r")
        y = y + 22
    end

    local function descHeight(fs, text, width)
        local h = fs:GetStringHeight()
        if h and h > 4 then return h end
        local cpl = math.max(20, math.floor((width or 520) / 6))
        return math.max(1, math.ceil(#text / cpl)) * 12
    end

    local function addPara(text, indent, width)
        local d = content:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        d:SetPoint("TOPLEFT", content, "TOPLEFT", indent or 12, -y)
        d:SetWidth(width or 524)
        d:SetJustifyH("LEFT")
        d:SetText("|cffbbbbbb" .. text .. "|r")
        y = y + descHeight(d, text, width or 524) + 6
        return d
    end

    local function addCheck(label, getFn, setFn, desc)
        local cb = CreateFrame("CheckButton", nil, content, "UICheckButtonTemplate")
        cb:SetPoint("TOPLEFT", content, "TOPLEFT", 12, -y)
        local fs = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        fs:SetPoint("LEFT", cb, "RIGHT", 2, 0)
        fs:SetText(label)
        cb:SetScript("OnClick", function(self) setFn(self:GetChecked() and true or false) end)
        refreshers[#refreshers + 1] = function() cb:SetChecked(getFn()) end
        y = y + 22
        if desc then addPara(desc, 40, 496) end
        y = y + 4
        return cb
    end

    local function addButton(label, onClick, desc)
        local b = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
        b:SetSize(150, 22)
        b:SetPoint("TOPLEFT", content, "TOPLEFT", 14, -y)
        b:SetText(label)
        b:SetScript("OnClick", onClick)
        local rowH = 26
        if desc then
            local d = content:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
            d:SetPoint("TOPLEFT", content, "TOPLEFT", 176, -y - 2)
            d:SetWidth(360); d:SetJustifyH("LEFT")
            d:SetText("|cffbbbbbb" .. desc .. "|r")
            rowH = math.max(rowH, descHeight(d, desc, 360) + 8)
        end
        y = y + rowH
    end

    addTitle("Spec Switch Announce")
    addPara("Warns you when a raider is playing a different talent spec than they signed up for on "
        .. "Raid-Helper. IMPORTANT: only YOU need this addon -- it inspects players near you "
        .. "(about 28 yards), so people who are far away will appear once they get close.", 10, 540)

    addCheck("Enable Spec Switch Announce", function() return db.enabled end, setEnabled,
        "Master on/off switch. When OFF, the addon does nothing -- no scanning, warnings, or "
        .. "overlay. Everything below only works while this is ON.")

    addCheck("Only run while I'm in a raid", function() return db.raidOnly end,
        function(v)
            db.raidOnly = v
            if updateOverlay then updateOverlay() end
            if refreshDisplay then refreshDisplay() end
        end,
        "When ON, scanning, warnings, and the off-spec overlay only happen while you are in a raid, "
        .. "so it stays quiet in 5-man parties or solo without turning the addon off. You can still "
        .. "open the spec board at any time.")

    local status = content:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    status:SetPoint("TOPLEFT", content, "TOPLEFT", 10, -y)
    status:SetWidth(540); status:SetJustifyH("LEFT")
    y = y + 34

    addHeader("Step 1 - Load your roster")
    addButton("Import roster...", showImportFrame,
        "Paste your Raid-Helper signup (the JSON export from the event's '...' menu). This tells "
        .. "the addon who is supposed to play which spec.")
    addButton("Show spec board", showDisplay,
        "Opens the window listing everyone with their expected spec and what they are actually "
        .. "playing. Green = correct, red = wrong spec.")

    addHeader("Step 2 - How it checks people")
    addCheck("Keep checking the group automatically", function() return db.autoScan end,
        function(v) db.autoScan = v end,
        "Re-inspects nearby group members every ~45 seconds so the board stays current. Recommended: ON.")
    addCheck("Check everyone when a ready check starts", function() return db.scanOnReadyCheck end,
        function(v) db.scanOnReadyCheck = v end,
        "When anyone starts a ready check, instantly inspect the whole group. People are usually "
        .. "stacked then, so it's a great final check before a pull.")
    addCheck("Also list signed-up players who aren't here yet", function() return db.showExpected end,
        function(v) db.showExpected = v; if refreshDisplay then refreshDisplay() end end,
        "On the spec board, also show people from your roster who haven't joined the group, so you "
        .. "can set them up before raid.")
    addButton("Check now", function()
        checkSelf()
        startScan()
        say(inGroup() and "scanning group..." or ("solo -- your current spec is " .. (unitSpecName("player") or "?") .. "."))
    end, "Inspect everyone in your group right now.")
    addButton("Roster status", printRoster,
        "Prints how many signups are loaded and who currently matches a player in your group.")

    addHeader("Step 3 - How you get warned about off-spec players")
    addPara("Pick any combination below. A warning fires once when someone is detected on the wrong spec.", 12, 524)

    local CHANNELS = {
        { "AUTO", "Auto (raid, or party)" },
        { "RAID_WARNING", "Raid warning (/rw)" },
        { "RAID", "Raid chat (/r)" },
        { "PARTY", "Party chat (/p)" },
        { "SAY", "Say (/s)" },
        { "YELL", "Yell (/y)" },
        { "PRIVATE", "Only me (private)" },
        { "NONE", "Don't post to chat" },
    }
    local function chanText(v)
        for _, c in ipairs(CHANNELS) do if c[1] == v then return c[2] end end
        return v
    end
    local clabel = content:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    clabel:SetPoint("TOPLEFT", content, "TOPLEFT", 14, -y - 4)
    clabel:SetText("Post the warning in:")
    local chanDD = CreateFrame("Frame", "SSAOptChannel", content, "UIDropDownMenuTemplate")
    chanDD:SetPoint("TOPLEFT", content, "TOPLEFT", 140, -y)
    UIDropDownMenu_SetWidth(chanDD, 150)
    UIDropDownMenu_Initialize(chanDD, function(_, level)
        for _, c in ipairs(CHANNELS) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = c[2]
            info.checked = (db.announceChannel or "AUTO") == c[1]
            info.func = function()
                db.announceChannel = c[1]
                UIDropDownMenu_SetText(chanDD, c[2])
                CloseDropDownMenus()
            end
            UIDropDownMenu_AddButton(info, level)
        end
    end)
    refreshers[#refreshers + 1] = function()
        UIDropDownMenu_SetText(chanDD, chanText(db.announceChannel or "AUTO"))
    end
    y = y + 32
    addPara("Where the warning is posted. 'Only me (private)' prints to your own chat box and posts "
        .. "nothing to the group -- use it to test by yourself. Note: Raid warning (/rw) only works "
        .. "if you are the raid leader or an assistant.", 16, 520)

    addCheck("Play a warning sound", function() return db.notifySound end,
        function(v) db.notifySound = v end,
        "Plays the raid-warning sound when someone is on the wrong spec.")
    addCheck("Flash big text across my screen", function() return db.notifyWarningText end,
        function(v) db.notifyWarningText = v end,
        "Shows the warning across the middle of your screen, like a raid warning.")
    addCheck("Show a movable off-spec list on screen", function() return db.overlay end,
        function(v) db.overlay = v; if updateOverlay then updateOverlay() end end,
        "A small box listing everyone currently on the wrong spec. Drag it anywhere. It only counts "
        .. "players who are in your group.")

    addHeader("Extras")
    addButton("Announce my spec", function()
        local cur = unitSpecName("player") or "Unknown"
        local me = UnitName("player") or "Someone"
        sendAnnounce(string.format("%s switched spec: %s -> %s", me, db.lastSpec or cur, cur))
    end, "Posts your own current spec to chat now (uses the channel above). A quick way to confirm it works.")
    addButton("Who am I", function()
        local me = UnitName("player")
        local cur = unitSpecName("player") or "Unknown"
        local entry = db.roster and db.roster[me:lower()]
        say(string.format("you are %s, current spec %s.", me, cur))
        if entry then
            say("  signed up as: " .. stripDigits(entry.spec))
        elseif db.roster then
            say("  not found in roster (name may differ from your Discord nickname).")
        end
    end, "Prints your character name, current spec, and what you signed up as.")
    addButton("Reset warnings", function()
        wipe(trackOrder) wipe(trackData) wipe(observed) wipe(announced)
        if refreshDisplay then refreshDisplay() end
        say("tracking list cleared.")
    end, "Forgets who has already been warned about, so current off-spec players get re-announced.")
    addButton("Clear roster", function()
        db.roster = nil wipe(announced) wipe(observed)
        say("roster cleared.")
    end, "Forgets the imported signup completely.")

    content:SetHeight(y + 16)

    local function refresh()
        if scroll:GetWidth() and scroll:GetWidth() > 50 then content:SetWidth(scroll:GetWidth()) end
        local me = UnitName("player") or "?"
        local cur = unitSpecName("player") or "?"
        local rosterCount = 0
        if db.roster then for _ in pairs(db.roster) do rosterCount = rosterCount + 1 end end
        status:SetText(string.format(
            "You are |cffffffff%s|r  |  Your spec: |cffffffff%s|r  |  Roster loaded: |cffffffff%s|r signups",
            me, cur, rosterCount > 0 and rosterCount or "none (import one)"))
        for _, fn in ipairs(refreshers) do fn() end
    end
    panel:SetScript("OnShow", refresh)

    return panel
end

local function registerOptions()
    optionsPanel = buildOptionsPanel()
    if Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory then
        local category = Settings.RegisterCanvasLayoutCategory(optionsPanel, optionsPanel.name)
        Settings.RegisterAddOnCategory(category)
        settingsCategory = category
    elseif InterfaceOptions_AddCategory then
        InterfaceOptions_AddCategory(optionsPanel)
    end
end

local function dumpDebug()
    local function has(n) return _G[n] and "yes" or "|cffff5555MISSING|r" end
    say("--- debug ---")
    say("GetNumTalentTabs=" .. has("GetNumTalentTabs") .. "  GetTalentTabInfo=" .. has("GetTalentTabInfo"))
    say("GetActiveTalentGroup=" .. has("GetActiveTalentGroup") .. "  GetNumTalentGroups=" .. has("GetNumTalentGroups"))
    say("GetSpecialization=" .. has("GetSpecialization") .. "  GetSpecializationInfo=" .. has("GetSpecializationInfo"))
    local n = GetNumTalentTabs and GetNumTalentTabs() or nil
    say("num talent tabs = " .. tostring(n))
    if GetTalentTabInfo then
        for i = 1, (n or 3) do
            local ok, name, _, pts = pcall(GetTalentTabInfo, i)
            if ok then
                say(string.format("  tab %d: %s  pts=%s", i, tostring(name), tostring(pts)))
            else
                say(string.format("  tab %d: |cffff5555error|r %s", i, tostring(name)))
            end
        end
    end
    if GetActiveTalentGroup then say("active talent group = " .. tostring(GetActiveTalentGroup())) end
    say("legacy dominantSpec() = " .. tostring((dominantSpec(false))))
    say("LibClassicInspector = " .. (CI and "|cff00ff00loaded|r" or "|cffff5555MISSING|r"))
    if CI then
        local idx, pts = CI:GetSpecialization("player")
        local _, class = UnitClass("player")
        say(string.format("CI player: class=%s specIndex=%s points=%s -> %s",
            tostring(class), tostring(idx), tostring(pts), tostring(unitSpecName("player"))))
    end
    local me = UnitName("player")
    local entry = db.roster and me and db.roster[me:lower()]
    if entry then say("your signup = " .. tostring(entry.spec)) end
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("CHARACTER_POINTS_CHANGED")
frame:RegisterEvent("GROUP_ROSTER_UPDATE")
frame:RegisterEvent("READY_CHECK")
pcall(frame.RegisterEvent, frame, "PLAYER_TALENT_UPDATE")
pcall(frame.RegisterEvent, frame, "ACTIVE_TALENT_GROUP_CHANGED")

if CI then
    CI.RegisterCallback(cbHost, "TALENTS_READY", function(_, guid, _isInspect, unit)
        if guid == UnitGUID("player") then
            checkSelf()
        else
            local u = unit or (CI.PlayerGUIDToUnitToken and CI:PlayerGUIDToUnitToken(guid))
            if u then evaluateUnit(u, UnitName(u)) end
        end
        if refreshDisplay then refreshDisplay() end
    end)
end

local autoTicker, selfTicker
frame:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 == ADDON then
            SpecSwitchAnnounceDB = SpecSwitchAnnounceDB or {}
            db = SpecSwitchAnnounceDB
            if db.enabled == nil then db.enabled = true end
            if db.raidOnly == nil then db.raidOnly = false end
            if db.autoScan == nil then db.autoScan = true end
            if db.showExpected == nil then db.showExpected = false end
            if db.announceChannel == nil then db.announceChannel = "AUTO" end
            if db.notifySound == nil then db.notifySound = false end
            if db.notifyWarningText == nil then db.notifyWarningText = false end
            if db.overlay == nil then db.overlay = false end
            if db.scanOnReadyCheck == nil then db.scanOnReadyCheck = true end
            db.overrides = db.overrides or {}
            db.hidden = db.hidden or {}
            db.board = db.board or {}
            registerOptions()
        end

    elseif event == "PLAYER_ENTERING_WORLD" then
        afterDelay(2, function() checkSelfSwitch(true) end)
        if not autoTicker and C_Timer and C_Timer.NewTicker then
            autoTicker = C_Timer.NewTicker(45, function()
                if isActive() and db.autoScan and inGroup() then
                    startScan()
                end
            end)
        end
        if not selfTicker and C_Timer and C_Timer.NewTicker then
            selfTicker = C_Timer.NewTicker(5, function()
                if db then checkSelf() end
                if refreshDisplay then refreshDisplay() end
            end)
        end

    elseif event == "GROUP_ROSTER_UPDATE" then
        if refreshDisplay then refreshDisplay() end
        if db and db.autoScan and inGroup() then startScan() end

    elseif event == "READY_CHECK" then
        if isActive() and db.scanOnReadyCheck then
            checkSelf()
            startScan()
            if refreshDisplay then refreshDisplay() end
        end

    else
        onTalentChange()
    end
end)

SLASH_SPECSWITCHANNOUNCE1 = "/ssa"
SLASH_SPECSWITCHANNOUNCE2 = "/specswitch"
SlashCmdList["SPECSWITCHANNOUNCE"] = function(msg)
    msg = (msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")

    if msg == "config" or msg == "options" then
        openOptions()

    elseif msg == "enable" or msg == "on" then
        setEnabled(true)

    elseif msg == "disable" or msg == "off" then
        setEnabled(false)

    elseif msg == "toggle" then
        setEnabled(not db.enabled)

    elseif msg == "debug" then
        dumpDebug()

    elseif msg == "import" then
        showImportFrame()

    elseif msg == "show" then
        showDisplay()

    elseif msg == "hide" then
        if displayFrame then displayFrame:Hide() end

    elseif msg == "reset" then
        wipe(trackOrder)
        wipe(trackData)
        wipe(observed)
        wipe(announced)
        if refreshDisplay then refreshDisplay() end
        say("tracking list cleared.")

    elseif msg == "scan" then
        checkSelf()
        startScan()
        if inGroup() then
            say("scanning group...")
        else
            say("solo -- your current spec is " .. (unitSpecName("player") or "?") .. ".")
        end

    elseif msg == "roster" then
        printRoster()

    elseif msg == "clear" then
        db.roster = nil
        wipe(announced)
        wipe(observed)
        say("roster cleared (now in self-switch fallback mode).")

    elseif msg == "auto" then
        db.autoScan = not db.autoScan
        say("auto-scan " .. (db.autoScan and "ON (every ~45s)." or "OFF."))

    elseif msg == "whoami" then
        local me = UnitName("player")
        local cur = unitSpecName("player") or "Unknown"
        local entry = db.roster and db.roster[me:lower()]
        say(string.format("you are %s, current spec %s.", me, cur))
        if entry then
            say(string.format("  signed up as: %s", stripDigits(entry.spec)))
        elseif db.roster then
            say("  not found in roster (name may differ from your Discord nickname).")
        end

    elseif msg == "fire" then
        local cur = unitSpecName("player") or "Unknown"
        local me = UnitName("player") or "Someone"
        sendAnnounce(string.format("%s switched spec: %s -> %s", me, db.lastSpec or cur, cur))

    else
        say("commands:")
        say("  |cffffff00/ssa enable|r / |cffffff00disable|r  turn the addon on/off")
        say("  |cffffff00/ssa config|r  open the options panel")
        say("  |cffffff00/ssa show|r / |cffffff00hide|r  the spec-change window")
        say("  |cffffff00/ssa import|r  paste a Raid-Helper JSON signup")
        say("  |cffffff00/ssa scan|r    check the group now")
        say("  |cffffff00/ssa reset|r   clear the tracking list")
        say("  |cffffff00/ssa roster|r  show signups + who matches in group")
        say("  |cffffff00/ssa whoami|r  your name / spec / signup")
        say("  |cffffff00/ssa auto|r    toggle auto-scan (" .. (db.autoScan and "ON" or "OFF") .. ")")
        say("  |cffffff00/ssa fire|r    announce your own spec now")
        say("  |cffffff00/ssa clear|r   forget the roster")
    end
end

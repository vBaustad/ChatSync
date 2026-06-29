-- ChatSync - save your chat window layout (tabs, channels, message types, colors,
-- sizes) as account-wide profiles and reuse them on other characters. A brand-new
-- character automatically gets your default profile; existing characters are left
-- alone unless you apply a profile by hand.
--
-- Chat windows are stored per-character by the game, so this reads the layout with
-- the GetChatWindow* APIs and replays it with the Blizzard FCF_* / ChatFrame_* APIs.
-- Those calls are wrapped in pcall so an odd window can never break login.

local ADDON = ...

local PREFIX = "|cff66ccffChatSync|r: "

-- Ping sounds come from two sources, merged in the picker:
--   1. Built-in SoundKit IDs - always available; we keep only the ones that exist in this client
--      (some SOUNDKIT constants are nil in Classic Era) and play them with PlaySound.
--   2. LibSharedMedia-3.0's "sound" registry, if the lib is present - picks up sounds registered
--      by other addons / sound packs and plays by file path (PlaySoundFile), which sidesteps the
--      SoundKit-nil problem entirely.
-- The choice is saved as a string key: a built-in short key ("tell", ...) or "lsm:<media name>".
-- An unknown key falls back to the first available sound, so a missing lib never breaks playback.
local LSM = LibStub and LibStub("LibSharedMedia-3.0", true)

local SK = SOUNDKIT or {}
local CANDIDATE_SOUNDS = {
    { "tell",   "Whisper chime", SK.TELL_MESSAGE },
    { "blip",   "Tech blip",     SK.UI_BNET_TOAST },   -- the Battle.net "bloop" - electronic/techy
    { "ping",   "Map ping",      SK.MAP_PING },
    { "bell",   "Ready check",   SK.READY_CHECK },
    { "raid",   "Raid warning",  SK.RAID_WARNING },
    { "invite", "Invite ding",   SK.IG_PLAYER_INVITE },
    { "horn",   "PvP queue",     SK.PVP_THROUGH_QUEUE },
    { "murloc", "Murloc",        SK.MURLOC_AGGRO },
}
local BUILTIN_SOUNDS = {}
for _, s in ipairs(CANDIDATE_SOUNDS) do
    if s[3] then BUILTIN_SOUNDS[#BUILTIN_SOUNDS + 1] = { key = s[1], label = s[2], kit = s[3] } end
end

-- The ordered list shown in the picker: built-ins first, then LibSharedMedia sounds (deduped by
-- label, "None" skipped). Rebuilt on demand so newly-registered LSM sounds appear.
local function SoundList()
    local out, seen = {}, {}
    for _, s in ipairs(BUILTIN_SOUNDS) do out[#out + 1] = s; seen[s.label] = true end
    if LSM then
        for _, name in ipairs(LSM:List("sound")) do
            if name ~= "None" and not seen[name] then
                out[#out + 1] = { key = "lsm:" .. name, label = name, file = LSM:Fetch("sound", name) }
                seen[name] = true
            end
        end
    end
    return out
end

local function FindSound(key)
    local list = SoundList()
    for _, s in ipairs(list) do if s.key == key then return s end end
    return list[1]
end

-- Play a specific sound by key (picker hover/select preview + incoming messages).
local function PlaySoundKey(key)
    local s = FindSound(key)
    if not s then return end
    if s.file then PlaySoundFile(s.file, "Master")
    elseif s.kit then PlaySound(s.kit, "Master") end
end

-- Label for the current selection (shown on the dropdown).
local function CurrentSoundLabel()
    local s = FindSound((ChatSyncDB and ChatSyncDB.pingSound) or "tell")
    return s and s.label or "Whisper chime"
end

-- Play the currently-selected ping sound (incoming messages + toggle preview).
local function PlayPing()
    PlaySoundKey((ChatSyncDB and ChatSyncDB.pingSound) or "tell")
end
local function msg(text) print(PREFIX .. text) end
local BMC_URL = "buymeacoffee.com/vbaustad"

local NUMWIN = NUM_CHAT_WINDOWS or 10
local SNAP_VERSION = 2   -- 2 = snapshot includes window size/position; 1/nil = older, no geometry

-- Auto-save state. suppressAutoSave is true during our own Apply() and until login
-- settles, so applying a profile / the login chat init can't trigger a save.
local suppressAutoSave = true
local autoSaveTimer

local function CharKey()
    return (UnitName("player") or "?") .. "-" .. (GetRealmName() or "?")
end

-- ---------------------------------------------------------------------------
-- Capture: read the current character's chat window layout into a snapshot.
-- ---------------------------------------------------------------------------
local function Capture()
    local snap = { windows = {} }
    for i = 1, NUMWIN do
        local name, fontSize, r, g, b, alpha, shown, locked, docked, uninteractable = GetChatWindowInfo(i)
        if name and name ~= "" then
            local w = {
                name = name, fontSize = fontSize,
                r = r, g = g, b = b, alpha = alpha,
                shown = shown and true or false,
                locked = locked and true or false,
                docked = docked and true or false,           -- docked is a position id or nil
                uninteractable = uninteractable and true or false,
                messages = {}, channels = {},
            }
            for _, m in ipairs({ GetChatWindowMessages(i) }) do
                if type(m) == "string" and m ~= "" then w.messages[#w.messages + 1] = m end
            end
            -- GetChatWindowChannels returns name, number pairs - keep the names.
            local chs = { GetChatWindowChannels(i) }
            for j = 1, #chs, 2 do
                local cname = chs[j]
                if type(cname) == "string" and cname ~= "" then w.channels[#w.channels + 1] = cname end
            end
            -- Geometry: capture for the main frame (ChatFrame1 = the dock anchor; the
            -- whole dock moves/sizes with it) and for any floating window. Other docked
            -- tabs just follow the anchor, so they don't need their own.
            local cf = _G["ChatFrame" .. i]
            if cf and (i == 1 or not w.docked) then
                local p, _, rp, x, y = cf:GetPoint()
                if p then w.point = { p, rp, x, y } end
                w.width, w.height = cf:GetWidth(), cf:GetHeight()
            end
            snap.windows[#snap.windows + 1] = w
        end
    end
    snap.count = #snap.windows
    snap.v = SNAP_VERSION
    return snap
end

-- A profile saved by an older version (before size/position support) is "stale".
local function IsStale(snap) return snap and (snap.v or 1) < SNAP_VERSION end

-- ---------------------------------------------------------------------------
-- Apply: rebuild the chat windows on this character from a snapshot.
-- ---------------------------------------------------------------------------
local function Apply(snap)
    if not snap or not snap.windows or #snap.windows == 0 then return false end
    local prevSuppress = suppressAutoSave
    suppressAutoSave = true                     -- our own FCF calls must not auto-save
    local n = #snap.windows
    for i = 1, n do
        local w = snap.windows[i]
        -- Chat frame objects (ChatFrame1..N) always exist; a window only counts as
        -- "active" once it has a name. If this slot isn't active yet, open it - that
        -- lands on the lowest free index, which is this one when we build in order.
        local curName = GetChatWindowInfo(i)
        if (not curName or curName == "") and FCF_OpenNewWindow then
            pcall(FCF_OpenNewWindow, w.name)   -- creates + docks the next available window
        end
        local cf = _G["ChatFrame" .. i]
        if cf then
            pcall(FCF_SetWindowName, cf, w.name)
            if w.r then pcall(FCF_SetWindowColor, cf, w.r, w.g, w.b) end
            if w.alpha then pcall(FCF_SetWindowAlpha, cf, w.alpha) end
            if w.fontSize and w.fontSize > 0 then pcall(FCF_SetChatWindowFontSize, nil, cf, w.fontSize) end

            -- Message types (Say / Guild / Whisper / ...): clear then re-add.
            pcall(ChatFrame_RemoveAllMessageGroups, cf)
            for _, m in ipairs(w.messages) do pcall(ChatFrame_AddMessageGroup, cf, m) end

            -- Channels: clear then re-add (ChatFrame_AddChannel re-joins as needed).
            pcall(ChatFrame_RemoveAllChannels, cf)
            for _, c in ipairs(w.channels) do pcall(ChatFrame_AddChannel, cf, c) end

            -- Size & position. ChatFrame1 is the dock anchor - moving/sizing it moves the
            -- whole dock. Other docked tabs follow it; floating tabs get their own geometry.
            if i == 1 then
                if w.point then
                    cf:SetUserPlaced(true); cf:ClearAllPoints()
                    pcall(cf.SetPoint, cf, w.point[1], UIParent, w.point[2], w.point[3], w.point[4])
                end
                if w.width and w.height then pcall(cf.SetSize, cf, w.width, w.height) end
            elseif w.docked then
                pcall(FCF_DockFrame, cf)
            else
                pcall(FCF_UnDockFrame, cf)
                if w.point then
                    cf:SetUserPlaced(true); cf:ClearAllPoints()
                    pcall(cf.SetPoint, cf, w.point[1], UIParent, w.point[2], w.point[3], w.point[4])
                end
                if w.width and w.height then pcall(cf.SetSize, cf, w.width, w.height) end
                if w.shown then cf:Show() else cf:Hide() end
            end
        end
    end
    -- Let Blizzard persist the new positions/dimensions to the character's layout.
    for i = 1, n do
        local cf = _G["ChatFrame" .. i]
        if cf then pcall(FCF_SavePositionAndDimensions, cf) end
    end
    suppressAutoSave = prevSuppress
    return true
end

-- ---------------------------------------------------------------------------
-- Profiles (account-wide saved variables)
-- ---------------------------------------------------------------------------
local function DB()
    ChatSyncDB = ChatSyncDB or {}
    ChatSyncDB.profiles = ChatSyncDB.profiles or {}
    ChatSyncDB.seen = ChatSyncDB.seen or {}
    ChatSyncDB.bindings = ChatSyncDB.bindings or {}        -- [charKey] = profile it keeps updated
    ChatSyncDB.onNewChar = ChatSyncDB.onNewChar or "ask"   -- "ask" | "auto" | "off"
    if ChatSyncDB.minimapShown == nil then ChatSyncDB.minimapShown = true end
    ChatSyncDB.minimapAngle = ChatSyncDB.minimapAngle or 200
    if ChatSyncDB.autoSave == nil then ChatSyncDB.autoSave = true end
    -- Chat message pings. Whisper pings ON by default (low-frequency, important); guild/party
    -- stay off to avoid spam. pingSound = a sound key (built-in or "lsm:<name>").
    ChatSyncDB.ping = ChatSyncDB.ping or { whisper = true, guild = false, party = false }
    ChatSyncDB.ping.channels = ChatSyncDB.ping.channels or {}   -- [custom channel base name] = true
    ChatSyncDB.pingSound = ChatSyncDB.pingSound or "blip"   -- "Tech blip" (falls back if nil here)
    return ChatSyncDB
end

-- Forward declarations: these are defined later but referenced by earlier functions.
local RefreshRows, EnsureMinimap

-- Auto-save: when the player actually changes a chat window (move/resize/dock/rename/
-- color/channel/...), re-save it into the profile this character is bound to. Driven
-- by post-hooks on the relevant Blizzard functions - it only runs when something
-- changed (not on a timer), debounced so a burst of changes saves once.
local function ScheduleAutoSave()
    if suppressAutoSave then return end
    local db = DB()
    if not db.autoSave then return end
    local bound = db.bindings[CharKey()]
    if not bound or not db.profiles[bound] then return end
    if autoSaveTimer then autoSaveTimer:Cancel() end
    autoSaveTimer = C_Timer.NewTimer(1.5, function()
        autoSaveTimer = nil
        if suppressAutoSave then return end
        local d = DB()
        local b = d.bindings[CharKey()]
        if d.autoSave and b and d.profiles[b] then
            d.profiles[b] = Capture()
            if RefreshRows then RefreshRows() end
        end
    end)
end
for _, fn in ipairs({
    "FCF_SavePositionAndDimensions", "FCF_DockFrame", "FCF_UnDockFrame", "FCF_Close",
    "FCF_OpenNewWindow", "FCF_SetWindowName", "FCF_SetWindowColor", "FCF_SetWindowAlpha",
    "FCF_SetChatWindowFontSize", "ChatFrame_AddChannel", "ChatFrame_RemoveChannel",
    "ChatFrame_RemoveAllChannels", "ChatFrame_AddMessageGroup", "ChatFrame_RemoveMessageGroup",
    "ChatFrame_RemoveAllMessageGroups",
}) do
    if type(_G[fn]) == "function" then hooksecurefunc(fn, ScheduleAutoSave) end
end

local function DoSaveProfile(name)
    local db = DB()
    db.profiles[name] = Capture()
    db.bindings[CharKey()] = name             -- this character now keeps the profile current (logout re-save)
    if not db.default then db.default = name end
    local def = (db.default == name) and " (now the default for new characters)" or ""
    msg(("saved profile |cffffd100%s|r - %d windows%s."):format(name, db.profiles[name].count or 0, def))
    if RefreshRows then RefreshRows() end
end

local function SaveProfile(name)
    if not name or name == "" then msg("usage: /chatsync save <name>"); return end
    if DB().profiles[name] then
        StaticPopup_Show("CHATSYNC_OVERWRITE", name, nil, name)   -- confirm overwrite
    else
        DoSaveProfile(name)
    end
end

local function ApplyProfile(name)
    local db = DB()
    name = name or db.default
    if not name then msg("no profile to apply - save one first with /chatsync save <name>"); return end
    local snap = db.profiles[name]
    if not snap then msg(("no profile named |cffffd100%s|r. /chatsync list to see them."):format(name)); return end
    if Apply(snap) then
        msg(("applied profile |cffffd100%s|r. If anything looks off, /reload to settle it."):format(name))
    else
        msg("nothing to apply (empty profile).")
    end
end

local function ListProfiles()
    local db = DB()
    local any = false
    msg("profiles:")
    for name, snap in pairs(db.profiles) do
        any = true
        local star = (name == db.default) and " |cff66ff66(default)|r" or ""
        print(("   |cffffd100%s|r - %d windows%s"):format(name, snap.count or 0, star))
    end
    if not any then print("   (none yet - /chatsync save <name> on the character whose chat you like)") end
end

local function SetDefault(name)
    local db = DB()
    if not name or not db.profiles[name] then msg("usage: /chatsync default <name of an existing profile>"); return end
    db.default = name
    msg(("default for new characters is now |cffffd100%s|r."):format(name))
end

local function DoDeleteProfile(name)
    local db = DB()
    db.profiles[name] = nil
    if db.default == name then db.default = next(db.profiles) end
    for k, v in pairs(db.bindings) do if v == name then db.bindings[k] = nil end end
    msg(("deleted profile |cffffd100%s|r."):format(name))
    if RefreshRows then RefreshRows() end
end

local function DeleteProfile(name)
    local db = DB()
    if not name or not db.profiles[name] then msg("usage: /chatsync delete <name>"); return end
    StaticPopup_Show("CHATSYNC_DELETE", name, nil, name)   -- confirm delete
end

-- Confirmation popups (avoid accidental overwrite / deletion). The profile name is
-- passed as the dialog's data and handed to OnAccept.
StaticPopupDialogs["CHATSYNC_OVERWRITE"] = {
    text = "Chat Sync: overwrite the profile \"%s\" with this character's current chat layout?",
    button1 = YES, button2 = NO,
    OnAccept = function(_, data) DoSaveProfile(data) end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}
StaticPopupDialogs["CHATSYNC_DELETE"] = {
    text = "Chat Sync: delete the profile \"%s\"? This can't be undone.",
    button1 = YES, button2 = NO,
    OnAccept = function(_, data) DoDeleteProfile(data) end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}
StaticPopupDialogs["CHATSYNC_UPDATE_STALE"] = {
    text = "Chat Sync: your profile \"%s\" is missing window size & position (it was saved by an older version)."
        .. "\n\nUpdate it now from THIS character's current chat layout?",
    button1 = "Update", button2 = "Not now",
    OnAccept = function(_, data) DoSaveProfile(data) end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}
StaticPopupDialogs["CHATSYNC_NEWNAME"] = {
    text = "Chat Sync: name a profile to save this character's chat layout as:",
    button1 = "Save", button2 = CANCEL,
    hasEditBox = true, editBoxWidth = 200,
    OnAccept = function(self)
        local eb = self.EditBox or self.editBox
        local n = eb and strtrim(eb:GetText() or "") or ""
        if n ~= "" then SaveProfile(n) end
    end,
    EditBoxOnEnterPressed = function(self)
        local p = self:GetParent()
        local eb = p.EditBox or p.editBox
        local n = eb and strtrim(eb:GetText() or "") or ""
        if n ~= "" then SaveProfile(n) end
        p:Hide()
    end,
    EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}
StaticPopupDialogs["CHATSYNC_BMC"] = {
    text = "Thanks for using Chat Sync!\nCopy the link below if you'd like to buy me a coffee.",
    button1 = CLOSE,
    hasEditBox = true, editBoxWidth = 260,
    OnShow = function(self)
        local eb = self.EditBox or self.editBox
        if not eb then return end
        eb:SetText(BMC_URL); eb:HighlightText(); eb:SetFocus()
    end,
    EditBoxOnEnterPressed = function(self) self:GetParent():Hide() end,
    EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

local function Help()
    msg("commands:")
    print("   |cffffd100/chatsync save <name>|r - save this character's chat layout")
    print("   |cffffd100/chatsync apply <name>|r - apply a profile to this character")
    print("   |cffffd100/chatsync default <name>|r - which profile new characters get")
    print("   |cffffd100/chatsync list|r - list saved profiles")
    print("   |cffffd100/chatsync delete <name>|r - remove a profile")
    print("   |cffffd100/chatsync welcome|r - preview the new-character chooser popup")
    print("   |cffffd100/cs|r is a short alias for all of the above")
end

-- ---------------------------------------------------------------------------
-- Settings page (Interface Options -> AddOns -> Chat Sync). No UIDropDownMenu -
-- it taints the Group Finder; we use plain buttons and an edit box instead.
-- ---------------------------------------------------------------------------
local panel, optCategory, emptyText, updateBtn
local rowPool = {}

-- Label the big "save" button by binding state: update the bound profile, or (if this
-- character isn't a source yet) prompt for a new profile name.
local function RefreshUpdateBtn()
    if not updateBtn then return end
    local db = DB()
    local bound = db.bindings[CharKey()]
    if bound and db.profiles[bound] then
        updateBtn._bound = bound
        updateBtn:SetText("Save changes to \"" .. bound .. "\"")
    else
        updateBtn._bound = nil
        updateBtn:SetText("Save this character's chat as a profile")
    end
end

local function RegisterPage(p, label)
    if Settings and Settings.RegisterCanvasLayoutCategory then
        local cat = Settings.RegisterCanvasLayoutCategory(p, label)
        cat.ID = label
        Settings.RegisterAddOnCategory(cat)
        optCategory = cat
    elseif InterfaceOptions_AddCategory then
        InterfaceOptions_AddCategory(p)
    end
end

function RefreshRows()
    if not panel then return end
    local db = DB()
    local key = CharKey()
    local names = {}
    for n in pairs(db.profiles) do names[#names + 1] = n end
    table.sort(names)
    for _, r in ipairs(rowPool) do r:Hide() end
    for i, n in ipairs(names) do
        local r = rowPool[i]
        if not r then
            r = CreateFrame("Frame", nil, panel)
            r:SetSize(540, 24)
            r.label = r:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
            r.label:SetPoint("LEFT", 6, 0); r.label:SetWidth(196); r.label:SetJustifyH("LEFT")
            r.label:SetWordWrap(false)   -- one line; long name+tags truncate instead of overflowing the row
            -- Uniform, evenly-spaced action buttons (aligned across every row).
            r.apply = CreateFrame("Button", nil, r, "UIPanelButtonTemplate")
            r.apply:SetSize(74, 20); r.apply:SetText("Apply"); r.apply:SetPoint("LEFT", 210, 0)
            r.def = CreateFrame("Button", nil, r, "UIPanelButtonTemplate")
            r.def:SetSize(74, 20); r.def:SetText("Default"); r.def:SetPoint("LEFT", r.apply, "RIGHT", 8, 0)
            r.src = CreateFrame("Button", nil, r, "UIPanelButtonTemplate")
            r.src:SetSize(74, 20); r.src:SetPoint("LEFT", r.def, "RIGHT", 8, 0)
            r.del = CreateFrame("Button", nil, r, "UIPanelButtonTemplate")
            r.del:SetSize(74, 20); r.del:SetText("Delete"); r.del:SetPoint("LEFT", r.src, "RIGHT", 8, 0)
            rowPool[i] = r
        end
        local mark = ""
        if n == db.default then mark = mark .. "  |cff66ff66(default)|r" end
        if db.bindings[key] == n then mark = mark .. "  |cff66ccff(syncs here)|r" end
        if IsStale(db.profiles[n]) then mark = mark .. "  |cffff8800(re-save for size/pos)|r" end
        r:ClearAllPoints(); r:SetPoint("TOPLEFT", 16, -220 - (i - 1) * 26)
        r.label:SetText(n .. mark)
        r.apply:SetScript("OnClick", function() ApplyProfile(n) end)
        r.def:SetScript("OnClick", function() SetDefault(n); RefreshRows() end)
        r.src:SetText(db.bindings[key] == n and "Unsync" or "Sync here")
        r.src:SetScript("OnClick", function()
            db.bindings[key] = (db.bindings[key] == n) and nil or n
            RefreshRows()
        end)
        r.del:SetScript("OnClick", function() DeleteProfile(n) end)   -- popup confirms, then refreshes
        r:Show()
    end
    if emptyText then emptyText:SetShown(#names == 0) end
    -- Park the "Chat message pings" group just below the (variable-length) profile list.
    if panel.pingGroup then
        panel.pingGroup:ClearAllPoints()
        panel.pingGroup:SetPoint("TOPLEFT", 16, -220 - math.max(#names, 1) * 26 - 6)
    end
    RefreshUpdateBtn()
end

-- A taint-safe look-alike of a settings dropdown. We never use UIDropDownMenu_* (it taints the
-- LFG browse), so this is a recessed field: the current value on the left, a down-arrow on the
-- right, and a hover glow. Set the shown value via dd.Text:SetText(...); attach OnClick to open.
local function MakeDropdown(parent, width)
    local dd = CreateFrame("Button", nil, parent, "BackdropTemplate")
    dd:SetSize(width, 24)
    dd:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    dd:SetBackdropColor(0.09, 0.09, 0.11, 0.95)
    dd:SetBackdropBorderColor(0.45, 0.40, 0.32, 1)
    local arrow = dd:CreateTexture(nil, "ARTWORK")
    arrow:SetTexture("Interface\\ChatFrame\\UI-ChatIcon-ScrollDown-Up")
    arrow:SetSize(16, 16); arrow:SetPoint("RIGHT", -4, 0)
    dd.Text = dd:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    dd.Text:SetPoint("LEFT", 8, 0); dd.Text:SetPoint("RIGHT", arrow, "LEFT", -2, 0); dd.Text:SetJustifyH("LEFT")
    dd:SetScript("OnEnter", function(self) self:SetBackdropBorderColor(0.85, 0.75, 0.45, 1) end)
    dd:SetScript("OnLeave", function(self) self:SetBackdropBorderColor(0.45, 0.40, 0.32, 1) end)
    return dd
end

local function BuildOptions()
    if panel then return end
    panel = CreateFrame("Frame")
    panel.name = "Chat Sync"

    local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16); title:SetText("Chat Sync")

    local sub = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    sub:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6); sub:SetWidth(540); sub:SetJustifyH("LEFT")
    sub:SetText("Save a character's chat window layout as a profile, then apply it on other characters.")

    -- Prominent one-click save: updates the profile this character feeds (or, if it
    -- doesn't feed one yet, prompts for a name).
    updateBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    updateBtn:SetSize(300, 26); updateBtn:SetPoint("TOPLEFT", 16, -72)
    updateBtn:SetScript("OnClick", function(self)
        if self._bound then DoSaveProfile(self._bound) else StaticPopup_Show("CHATSYNC_NEWNAME") end
    end)
    RefreshUpdateBtn()

    -- What happens on a brand-new character (Ask = popup chooser / Auto / Do nothing).
    local modeNames = { ask = "Ask me (pick a profile)", auto = "Auto-apply default", off = "Do nothing" }
    local modeOrder = { "ask", "auto", "off" }
    local modeBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    modeBtn:SetSize(300, 26); modeBtn:SetPoint("TOPLEFT", 16, -106)
    local function modeText() modeBtn:SetText("New character: " .. (modeNames[DB().onNewChar or "ask"])) end
    modeBtn:SetScript("OnClick", function()
        local db = DB(); local cur = db.onNewChar or "ask"; local idx = 1
        for i, m in ipairs(modeOrder) do if m == cur then idx = i end end
        db.onNewChar = modeOrder[(idx % #modeOrder) + 1]; modeText()
    end)
    modeText()

    local mmCheck = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
    mmCheck:SetSize(24, 24); mmCheck:SetPoint("TOPLEFT", 360, -72)
    local mmLbl = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    mmLbl:SetPoint("LEFT", mmCheck, "RIGHT", 2, 0); mmLbl:SetText("Minimap button")
    mmCheck:SetChecked(DB().minimapShown ~= false)
    mmCheck:SetScript("OnClick", function(self)
        DB().minimapShown = self:GetChecked() and true or false
        if EnsureMinimap then EnsureMinimap() end
    end)

    local asCheck = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
    asCheck:SetSize(24, 24); asCheck:SetPoint("TOPLEFT", 360, -104)
    local asLbl = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    asLbl:SetPoint("LEFT", asCheck, "RIGHT", 2, 0); asLbl:SetText("Auto-save my changes")
    asCheck:SetChecked(DB().autoSave ~= false)
    asCheck:SetScript("OnClick", function(self) DB().autoSave = self:GetChecked() and true or false end)

    -- ----- Chat message pings: its own group, placed below the profile list by RefreshRows
    -- (the list grows, so the section can't have a fixed Y). -----
    local pingGroup = CreateFrame("Frame", nil, panel)
    pingGroup:SetSize(540, 80)
    panel.pingGroup = pingGroup

    local pingHdr = pingGroup:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    pingHdr:SetPoint("TOPLEFT", 0, 0); pingHdr:SetText("|cffffd100Chat message pings|r")

    -- Sound select: a taint-safe dropdown opening a scrollable list (hover a row to preview).
    -- Rebuilt on open since the LibSharedMedia catalog can grow; mouse-wheel scrolls long lists.
    local soundBtn = MakeDropdown(pingGroup, 180)
    soundBtn:SetPoint("TOPLEFT", 4, -22)
    local function refreshSoundBtn() soundBtn.Text:SetText("Sound: " .. CurrentSoundLabel()) end
    refreshSoundBtn()
    local pop, soundContent, soundRows = nil, nil, {}
    local ROWH, MAXROWS = 18, 12
    local function refreshSoundPop()
        local list = SoundList()
        for _, r in ipairs(soundRows) do r:Hide() end
        for i, s in ipairs(list) do
            local r = soundRows[i]
            if not r then
                r = CreateFrame("Button", nil, soundContent)
                r:SetHeight(ROWH)
                r.hl = r:CreateTexture(nil, "BACKGROUND"); r.hl:SetAllPoints(); r.hl:SetColorTexture(1, 1, 1, 0.12); r.hl:Hide()
                -- Speaker icon: click to preview the sound WITHOUT selecting it (it's a child
                -- button, so it consumes the click and the row's OnClick doesn't fire).
                r.play = CreateFrame("Button", nil, r)
                r.play:SetSize(15, 15); r.play:SetPoint("RIGHT", -5, 0)
                local sp = r.play:CreateTexture(nil, "ARTWORK"); sp:SetAllPoints()
                sp:SetTexture("Interface\\Common\\VoiceChat-Speaker")
                r.play:SetScript("OnEnter", function() sp:SetVertexColor(1, 0.85, 0.3) end)
                r.play:SetScript("OnLeave", function() sp:SetVertexColor(1, 1, 1) end)
                r.play:SetScript("OnClick", function() PlaySoundKey(r._key) end)
                r.fs = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                r.fs:SetPoint("LEFT", 6, 0); r.fs:SetPoint("RIGHT", r.play, "LEFT", -4, 0); r.fs:SetJustifyH("LEFT")
                r:SetScript("OnEnter", function(self) self.hl:Show() end)
                r:SetScript("OnLeave", function(self) self.hl:Hide() end)
                r:SetScript("OnClick", function(self) DB().pingSound = self._key; refreshSoundBtn(); pop:Hide() end)
                soundRows[i] = r
            end
            r._key = s.key; r.fs:SetText(s.label)
            r:ClearAllPoints()
            r:SetPoint("TOPLEFT", 0, -(i - 1) * ROWH); r:SetPoint("RIGHT", soundContent, "RIGHT", 0, 0)
            r:Show()
        end
        local n = #list
        soundContent:SetSize(186, math.max(1, n) * ROWH)
        pop._sf:SetVerticalScroll(0)
        pop:SetHeight(math.min(n, MAXROWS) * ROWH + 8)
    end
    soundBtn:SetScript("OnClick", function()
        if pop and pop:IsShown() then pop:Hide(); return end
        if not pop then
            pop = CreateFrame("Frame", "ChatSyncSoundPopup", pingGroup, "BackdropTemplate")
            pop:SetFrameStrata("TOOLTIP"); pop:SetWidth(196)   -- TOOLTIP so it sits above the Settings window
            pop:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8",
                edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", tile = false, edgeSize = 12,
                insets = { left = 3, right = 3, top = 3, bottom = 3 } })
            pop:SetBackdropColor(0.06, 0.06, 0.08, 1)   -- fully opaque
            tinsert(UISpecialFrames, "ChatSyncSoundPopup")   -- Escape closes
            local sf = CreateFrame("ScrollFrame", nil, pop)
            sf:SetPoint("TOPLEFT", 5, -4); sf:SetPoint("BOTTOMRIGHT", -5, 4)
            soundContent = CreateFrame("Frame", nil, sf)
            soundContent:SetSize(186, 10); sf:SetScrollChild(soundContent)
            sf:EnableMouseWheel(true)
            sf:SetScript("OnMouseWheel", function(self, delta)
                local maxS = math.max(0, soundContent:GetHeight() - self:GetHeight())
                self:SetVerticalScroll(math.min(maxS, math.max(0, self:GetVerticalScroll() - delta * ROWH * 2)))
            end)
            pop._sf = sf
        end
        refreshSoundPop()
        pop:ClearAllPoints(); pop:SetPoint("TOPLEFT", soundBtn, "BOTTOMLEFT", 0, -2); pop:Show()
    end)

    -- Which incoming channels ping (all off by default; previews the sound when enabled).
    local function pingToggle(x, key, label)
        local cb = CreateFrame("CheckButton", nil, pingGroup, "UICheckButtonTemplate")
        cb:SetSize(24, 24); cb:SetPoint("TOPLEFT", x, -22)
        local l = pingGroup:CreateFontString(nil, "ARTWORK", "GameFontNormal")
        l:SetPoint("LEFT", cb, "RIGHT", 2, 0); l:SetText(label)
        cb:SetChecked(DB().ping and DB().ping[key] == true)
        cb:SetScript("OnClick", function(self)
            DB().ping[key] = self:GetChecked() and true or false
            if DB().ping[key] then PlayPing() end
        end)
    end
    pingToggle(200, "whisper", "Whisper")
    pingToggle(300, "guild",   "Guild")
    pingToggle(380, "party",   "Party")

    -- Custom channels: a multi-select dropdown of the channels you're currently in (rebuilt
    -- each time it opens, since you join/leave channels). Stored by base name.
    local chanBtn = MakeDropdown(pingGroup, 180)
    chanBtn:SetPoint("TOPLEFT", 4, -50)
    local function chanCount() local n = 0; for _ in pairs(DB().ping.channels or {}) do n = n + 1 end; return n end
    local function refreshChanBtn()
        local n = chanCount()
        chanBtn.Text:SetText(n > 0 and ("Custom channels: " .. n) or "Custom channels...")
    end
    refreshChanBtn()
    local chanPop, chanRows = nil, {}
    local function refreshChanPop()
        local list = { GetChannelList() }   -- id, name, disabled, id, name, disabled, ...
        local names = {}
        for i = 2, #list, 3 do
            local nm = list[i]
            if type(nm) == "string" and nm ~= "" then names[#names + 1] = nm end
        end
        for _, r in ipairs(chanRows) do r:Hide() end
        chanPop.empty:SetShown(#names == 0)
        for i, nm in ipairs(names) do
            local r = chanRows[i]
            if not r then
                r = CreateFrame("CheckButton", nil, chanPop, "UICheckButtonTemplate")
                r:SetSize(22, 22)
                r.lbl = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                r.lbl:SetPoint("LEFT", r, "RIGHT", 2, 0); r.lbl:SetJustifyH("LEFT")
                chanRows[i] = r
            end
            r._name = nm; r.lbl:SetText(nm)
            r:SetChecked(DB().ping.channels[nm] == true)
            r:SetScript("OnClick", function(self)
                DB().ping.channels[self._name] = self:GetChecked() and true or nil
                refreshChanBtn()
            end)
            r:ClearAllPoints(); r:SetPoint("TOPLEFT", 6, -4 - (i - 1) * 22); r:Show()
        end
        chanPop:SetSize(220, math.max(1, #names) * 22 + 10)
    end
    chanBtn:SetScript("OnClick", function()
        if chanPop and chanPop:IsShown() then chanPop:Hide(); return end
        if not chanPop then
            chanPop = CreateFrame("Frame", "ChatSyncChanPopup", pingGroup, "BackdropTemplate")
            chanPop:SetFrameStrata("TOOLTIP")
            chanPop:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8",
                edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", tile = false, edgeSize = 12,
                insets = { left = 3, right = 3, top = 3, bottom = 3 } })
            chanPop:SetBackdropColor(0.06, 0.06, 0.08, 1)   -- fully opaque
            chanPop.empty = chanPop:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
            chanPop.empty:SetPoint("TOPLEFT", 8, -8); chanPop.empty:SetText("Not in any custom channels.")
            tinsert(UISpecialFrames, "ChatSyncChanPopup")
        end
        refreshChanPop()
        chanPop:ClearAllPoints(); chanPop:SetPoint("TOPLEFT", chanBtn, "BOTTOMLEFT", 0, -2); chanPop:Show()
    end)

    local saveLbl = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    saveLbl:SetPoint("TOPLEFT", 16, -142); saveLbl:SetText("Or save as a new profile:")

    local eb = CreateFrame("EditBox", nil, panel, "InputBoxTemplate")
    eb:SetSize(180, 22); eb:SetPoint("TOPLEFT", 20, -164); eb:SetAutoFocus(false); eb:SetMaxLetters(32)

    local saveBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    saveBtn:SetSize(80, 22); saveBtn:SetPoint("LEFT", eb, "RIGHT", 8, 0); saveBtn:SetText("Save")
    local function doSave()
        local n = strtrim(eb:GetText() or "")
        if n ~= "" then SaveProfile(n); eb:SetText(""); eb:ClearFocus(); RefreshRows() end
    end
    saveBtn:SetScript("OnClick", doSave)
    eb:SetScript("OnEnterPressed", doSave)
    eb:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

    local listHdr = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    listHdr:SetPoint("TOPLEFT", 16, -200)
    listHdr:SetText("|cffffd100Profiles|r   |cff888888(Sync here = keep this profile updated from this character)|r")

    emptyText = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    emptyText:SetPoint("TOPLEFT", 20, -222)
    emptyText:SetText("No profiles yet - use the button above, or type a name and Save.")

    -- "Buy me a coffee" support link (WoW can't open URLs, so it pops a copyable link).
    local coffee = CreateFrame("Button", nil, panel)
    coffee:SetSize(24, 24); coffee:SetPoint("BOTTOMLEFT", 16, 14)
    local ctex = coffee:CreateTexture(nil, "ARTWORK")
    ctex:SetAllPoints(); ctex:SetTexture("Interface\\AddOns\\ChatSync\\bmc-logo"); ctex:SetAlpha(0.7)
    local clbl = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    clbl:SetPoint("LEFT", coffee, "RIGHT", 6, 0); clbl:SetText("|cff888888if you want to support|r")
    coffee:SetScript("OnEnter", function(self)
        ctex:SetAlpha(1); clbl:SetText("|cffffc840if you want to support|r")
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Buy me a coffee", 1, 0.85, 0.2)
        GameTooltip:AddLine(BMC_URL, 0.7, 0.7, 0.7)
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Click to copy the link.", 0.5, 0.5, 0.5)
        GameTooltip:Show()
    end)
    coffee:SetScript("OnLeave", function()
        ctex:SetAlpha(0.7); clbl:SetText("|cff888888if you want to support|r"); GameTooltip:Hide()
    end)
    coffee:SetScript("OnClick", function() StaticPopup_Show("CHATSYNC_BMC") end)

    RegisterPage(panel, "Chat Sync")
    panel:SetScript("OnShow", RefreshRows)
end

local function OpenOptions()
    BuildOptions()
    if Settings and Settings.OpenToCategory and optCategory then
        Settings.OpenToCategory(optCategory.ID or optCategory:GetID())
    elseif InterfaceOptionsFrame_OpenToCategory and panel then
        InterfaceOptionsFrame_OpenToCategory(panel)   -- call twice (Blizzard scroll-to bug)
        InterfaceOptionsFrame_OpenToCategory(panel)
    end
end
HC_OpenChatSyncOptions = OpenOptions

-- ---------------------------------------------------------------------------
-- New-character chooser: a small popup to pick which profile to apply. Shown on
-- a fresh character when the "New character" setting is "ask". Esc / Skip = leave
-- the default chat alone.
-- ---------------------------------------------------------------------------
local chooser, chooserPool = nil, {}
local function ShowChooser()
    local db = DB()
    local names = {}
    for n in pairs(db.profiles) do names[#names + 1] = n end
    table.sort(names)
    if #names == 0 then return end

    if not chooser then
        chooser = CreateFrame("Frame", "ChatSyncChooser", UIParent, "BackdropTemplate")
        chooser:SetFrameStrata("DIALOG")
        chooser:SetPoint("CENTER", 0, 180)
        chooser:SetClampedToScreen(true)
        chooser:EnableMouse(true); chooser:SetMovable(true)
        chooser:RegisterForDrag("LeftButton")
        chooser:SetScript("OnDragStart", chooser.StartMoving)
        chooser:SetScript("OnDragStop", chooser.StopMovingOrSizing)
        chooser:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8X8",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 16,
            insets = { left = 4, right = 4, top = 4, bottom = 4 },
        })
        chooser:SetBackdropColor(0.05, 0.05, 0.07, 0.95)
        chooser:SetBackdropBorderColor(0.35, 0.6, 0.95, 1)
        chooser.title = chooser:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        chooser.title:SetPoint("TOP", 0, -14); chooser.title:SetText("|cff66ccffChat Sync|r")
        chooser.sub = chooser:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        chooser.sub:SetPoint("TOP", 0, -40); chooser.sub:SetWidth(252)
        chooser.sub:SetText("New character - pick a chat layout to use:")
        chooser.skip = CreateFrame("Button", nil, chooser, "UIPanelButtonTemplate")
        chooser.skip:SetSize(248, 22); chooser.skip:SetText("Keep default chat (skip)")
        chooser.skip:SetScript("OnClick", function() chooser:Hide() end)
        tinsert(UISpecialFrames, "ChatSyncChooser")   -- Esc = skip
    end

    for _, b in ipairs(chooserPool) do b:Hide() end
    local top = -66
    for i, n in ipairs(names) do
        local b = chooserPool[i]
        if not b then
            b = CreateFrame("Button", nil, chooser, "UIPanelButtonTemplate")
            b:SetSize(248, 24)
            chooserPool[i] = b
        end
        b:ClearAllPoints(); b:SetPoint("TOP", 0, top - (i - 1) * 28)
        b:SetText(n .. ((n == db.default) and "  |cff66ff66(default)|r" or ""))
        b:SetScript("OnClick", function() chooser:Hide(); ApplyProfile(n) end)
        b:Show()
    end
    chooser.skip:ClearAllPoints(); chooser.skip:SetPoint("TOP", 0, top - #names * 28 - 4)
    chooser:SetSize(290, 66 + #names * 28 + 22 + 18)
    chooser:Show()
end

-- ---------------------------------------------------------------------------
-- Minimap button (dependency-free; draggable around the ring). Left-click opens
-- settings, right-click pops the profile chooser.
-- ---------------------------------------------------------------------------
local minimapBtn
local function PositionMinimap()
    if not minimapBtn then return end
    local angle = math.rad(DB().minimapAngle or 200)
    -- Hug the minimap ring; scales with the minimap's actual size so the button
    -- doesn't drift off the edge when the minimap is resized.
    local r = (Minimap:GetWidth() / 2) + 5
    minimapBtn:ClearAllPoints()
    minimapBtn:SetPoint("CENTER", Minimap, "CENTER", r * math.cos(angle), r * math.sin(angle))
end
function EnsureMinimap()
    if not Minimap then return end
    if not minimapBtn then
        minimapBtn = CreateFrame("Button", "ChatSyncMinimapButton", Minimap)
        minimapBtn:SetSize(31, 31); minimapBtn:SetFrameStrata("MEDIUM"); minimapBtn:SetFrameLevel(8)
        minimapBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        minimapBtn:RegisterForDrag("LeftButton")
        local icon = minimapBtn:CreateTexture(nil, "BACKGROUND")
        icon:SetTexture("Interface\\AddOns\\ChatSync\\ChatSync")
        icon:SetSize(17, 17); icon:SetPoint("TOPLEFT", 7, -6); icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        local border = minimapBtn:CreateTexture(nil, "OVERLAY")
        border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
        border:SetSize(53, 53); border:SetPoint("TOPLEFT")
        -- Hover glow, matching Blizzard's own minimap buttons.
        minimapBtn:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
        minimapBtn:SetScript("OnDragStart", function(self)
            self:SetScript("OnUpdate", function()
                local mx, my = Minimap:GetCenter()
                local px, py = GetCursorPosition()
                local s = Minimap:GetEffectiveScale()
                DB().minimapAngle = math.deg(math.atan2(py / s - my, px / s - mx))
                PositionMinimap()
            end)
        end)
        minimapBtn:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
        minimapBtn:SetScript("OnClick", function(_, button)
            if button == "RightButton" then
                if next(DB().profiles) then ShowChooser() else OpenOptions() end
            else
                OpenOptions()
            end
        end)
        minimapBtn:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_LEFT")
            GameTooltip:AddLine("Chat Sync")
            GameTooltip:AddLine("Left-click: settings", 0.8, 0.8, 0.8)
            GameTooltip:AddLine("Right-click: pick a profile", 0.8, 0.8, 0.8)
            GameTooltip:Show()
        end)
        minimapBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end
    PositionMinimap()
    minimapBtn:SetShown(DB().minimapShown ~= false)
end

-- ---------------------------------------------------------------------------
-- "What's New": a one-time heads-up after an update, re-openable via /cs news.
-- Bump NEWS_KEY whenever there's fresh content to surface; it shows once per key.
-- ---------------------------------------------------------------------------
local NEWS_KEY = "pings-1"
local NEWS_LINES = {
    "|cffffd100Chat message pings|r - hear a sound when a message comes in.",
    " ",
    "Find |cffffd100Chat message pings|r at the bottom of the settings (|cffffd100/cs|r):",
    "  - Pick a |cffffd100sound|r and click the speaker to preview it.",
    "  - Ping on |cffffd100Whisper / Guild / Party|r, or tick specific |cffffd100custom channels|r.",
    " ",
    "Whispers ping by default. Your own messages never ping, and you can turn any of it off in the same place.",
}
local newsFrame
local function ShowNews()
    if not newsFrame then
        newsFrame = CreateFrame("Frame", "ChatSyncNews", UIParent, "BackdropTemplate")
        newsFrame:SetWidth(470); newsFrame:SetPoint("CENTER", 0, 140); newsFrame:SetFrameStrata("DIALOG")
        newsFrame:SetBackdrop({ bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border", tile = true, tileSize = 32, edgeSize = 32,
            insets = { left = 11, right = 12, top = 12, bottom = 11 } })
        newsFrame:EnableMouse(true); newsFrame:SetMovable(true); newsFrame:RegisterForDrag("LeftButton")
        newsFrame:SetScript("OnDragStart", newsFrame.StartMoving)
        newsFrame:SetScript("OnDragStop", newsFrame.StopMovingOrSizing)
        tinsert(UISpecialFrames, "ChatSyncNews")   -- Escape closes

        local title = newsFrame:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
        title:SetPoint("TOP", 0, -18); title:SetText("|cff66ccffChat Sync|r - What's New")

        local body = newsFrame:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        body:SetPoint("TOPLEFT", 28, -54); body:SetWidth(414)
        body:SetJustifyH("LEFT"); body:SetSpacing(4)
        body:SetText(table.concat(NEWS_LINES, "\n"))

        -- Size the frame to the (wrapped) text, then sit the buttons just below it - so the
        -- copy can never run through the buttons regardless of how lines wrap.
        local h = math.max(60, body:GetStringHeight() or 60)
        newsFrame:SetHeight(54 + h + 22 + 24 + 20)

        local openBtn = CreateFrame("Button", nil, newsFrame, "UIPanelButtonTemplate")
        openBtn:SetSize(140, 24); openBtn:SetText("Open settings")
        openBtn:SetPoint("TOPRIGHT", body, "BOTTOM", -8, -22)
        openBtn:SetScript("OnClick", function() newsFrame:Hide(); OpenOptions() end)
        local okBtn = CreateFrame("Button", nil, newsFrame, "UIPanelButtonTemplate")
        okBtn:SetSize(140, 24); okBtn:SetText("Got it")
        okBtn:SetPoint("TOPLEFT", body, "BOTTOM", 8, -22)
        okBtn:SetScript("OnClick", function() newsFrame:Hide() end)
    end
    newsFrame:Show()
end

SLASH_CHATSYNC1 = "/chatsync"
SLASH_CHATSYNC2 = "/csync"
SLASH_CHATSYNC3 = "/cs"
SlashCmdList["CHATSYNC"] = function(input)
    local cmd, rest = (input or ""):match("^(%S*)%s*(.-)%s*$")
    cmd = (cmd or ""):lower()
    if cmd == "save" then SaveProfile(rest)
    elseif cmd == "apply" then ApplyProfile(rest ~= "" and rest or nil)
    elseif cmd == "default" then SetDefault(rest ~= "" and rest or nil)
    elseif cmd == "list" then ListProfiles()
    elseif cmd == "delete" or cmd == "remove" then DeleteProfile(rest)
    elseif cmd == "welcome" or cmd == "chooser" or cmd == "preview" then
        if next(DB().profiles) then ShowChooser() else msg("no profiles to choose from yet - save one first.") end
    elseif cmd == "news" or cmd == "whatsnew" then ShowNews()
    elseif cmd == "help" then Help()
    else OpenOptions() end   -- bare /chatsync opens the settings page
end

-- ---------------------------------------------------------------------------
-- New-character auto-apply: first time we see a character AND it looks freshly
-- created (level 1), apply the default profile. Existing characters (already seen,
-- or above level 1) are never auto-touched.
-- ---------------------------------------------------------------------------
-- Incoming chat events that can trigger a ping, mapped to their toggle key. _INFORM events
-- (your own outgoing whispers) are deliberately not registered.
local PING_EVENT = {
    CHAT_MSG_WHISPER = "whisper", CHAT_MSG_BN_WHISPER = "whisper",
    CHAT_MSG_GUILD = "guild",
    CHAT_MSG_PARTY = "party", CHAT_MSG_PARTY_LEADER = "party",
    CHAT_MSG_RAID = "party",   CHAT_MSG_RAID_LEADER = "party",
}
-- True unless `sender` is you (guild/party/channel events fire for your own messages too).
local function NotSelf(sender)
    local me = UnitName("player")
    return not (sender and me and Ambiguate(sender, "short") == me)
end
local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("PLAYER_LOGOUT")
f:RegisterEvent("CHAT_MSG_CHANNEL")
for ev in pairs(PING_EVENT) do f:RegisterEvent(ev) end
f:SetScript("OnEvent", function(_, event, ...)
    local ptype = PING_EVENT[event]
    if ptype then
        if ChatSyncDB and ChatSyncDB.ping and ChatSyncDB.ping[ptype] and NotSelf(select(2, ...)) then PlayPing() end
        return
    end
    if event == "CHAT_MSG_CHANNEL" then
        local chans = ChatSyncDB and ChatSyncDB.ping and ChatSyncDB.ping.channels
        local chan = select(9, ...)   -- channel base name (the number varies per character)
        if chans and chan and chans[chan] and NotSelf(select(2, ...)) then PlayPing() end
        return
    end
    if event == "PLAYER_LOGOUT" then
        -- Keep a bound profile current: re-save this character's layout into it.
        local db = ChatSyncDB
        local bound = db and db.bindings and db.bindings[CharKey()]
        if bound and db.profiles[bound] then db.profiles[bound] = Capture() end
        return
    end
    BuildOptions()                        -- register the settings page in the AddOns list
    EnsureMinimap()                       -- minimap button
    if C_Timer and C_Timer.After then C_Timer.After(5, function() suppressAutoSave = false end) end
    local db = DB()
    -- One-time "What's New" heads-up after an update (shown once per NEWS_KEY).
    if db.lastNews ~= NEWS_KEY then
        db.lastNews = NEWS_KEY
        if C_Timer and C_Timer.After then C_Timer.After(4, ShowNews) end
    end
    local key = CharKey()
    if db.seen[key] then
        -- Known character: if a profile predates size/position support, pop a prompt
        -- (not just a settings marker) offering to re-save it from this character.
        local staleName
        for nm, snap in pairs(db.profiles) do if IsStale(snap) then staleName = nm; break end end
        if staleName and C_Timer and C_Timer.After then
            C_Timer.After(2.5, function()
                if DB().profiles[staleName] and IsStale(DB().profiles[staleName]) then
                    StaticPopup_Show("CHATSYNC_UPDATE_STALE", staleName, nil, staleName)
                end
            end)
        end
        return
    end
    db.seen[key] = true
    -- Only act on a freshly-created character (level 1) that has profiles to offer.
    if (UnitLevel("player") or 1) > 1 or not next(db.profiles) then return end
    local mode = db.onNewChar or "ask"
    -- Wait for the default chat system to finish loading, then act.
    if mode == "ask" then
        C_Timer.After(2, ShowChooser)                 -- popup: pick a profile (or skip)
    elseif mode == "auto" and db.default and db.profiles[db.default] then
        C_Timer.After(2, function()
            if Apply(db.profiles[db.default]) then
                msg(("new character - applied your |cffffd100%s|r chat layout."):format(db.default))
            end
        end)
    end
end)

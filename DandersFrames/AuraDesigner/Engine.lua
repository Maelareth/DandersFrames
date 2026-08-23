local addonName, DF = ...

-- ============================================================
-- AURA DESIGNER - ENGINE
-- Runtime loop that reads per-aura config, queries the adapter
-- for active auras, and dispatches to indicator renderers.
--
-- Called from the frame update cycle (UpdateAuras) when the
-- Aura Designer is enabled for a frame's mode.
-- ============================================================

local wipe = table.wipe



DF.AuraDesigner = DF.AuraDesigner or {}

local Engine = {}
DF.AuraDesigner.Engine = Engine

local Adapter   -- Set during init
local SoundEngine -- Set during init (AuraDesigner/SoundEngine.lua)

-- ============================================================
-- SPEC RESOLUTION
-- ============================================================

function Engine:ResolveSpec(adDB)
    if adDB.spec == "auto" then
        if not Adapter then
            Adapter = DF.AuraDesigner.Adapter
        end
        if not Adapter then return nil end
        return Adapter:GetPlayerSpec()
    end
    return adDB.spec
end

-- ============================================================
-- HIDE ALL INDICATORS
-- Called when Aura Designer is disabled or unit doesn't exist.
-- ============================================================

function Engine:ClearFrame(frame)
    -- Tear down any native-factory AD containers (12.1 path) hung off this frame.
    if DF.AuraDesigner.Factory then
        DF.AuraDesigner.Factory:ClearFrame(frame)
    end
    -- Stop sound engine when AD is disabled
    if not SoundEngine then
        SoundEngine = DF.AuraDesigner.SoundEngine
    end
    if SoundEngine then
        SoundEngine:StopAll()
    end
    -- Clear active instance IDs so buff bar dedup doesn't stale-filter
    if frame.dfAD_activeInstanceIDs then
        wipe(frame.dfAD_activeInstanceIDs)
    end
end

-- ============================================================
-- FORCE REFRESH ALL AD-ENABLED FRAMES
-- Re-runs UpdateFrame on every visible AD frame so changed
-- global defaults (fonts, sizes, etc.) take effect immediately.
-- ============================================================

function Engine:ForceRefreshAllFrames()
    local Factory = DF.AuraDesigner and DF.AuraDesigner.Factory
    local function TryUpdate(frame)
        if not frame then return end
        if DF:IsAuraDesignerEnabled(frame) then
            -- Live 12.1 path: re-sync the factory containers immediately so an
            -- editor change applies now, not one aura event late.
            if frame:IsVisible() and Factory and DF.UseFactoryForAD
                and DF:UseFactoryForAD(frame, DF:GetFrameDB(frame)) then
                Factory:SyncFrame(frame)
            end
        else
            -- AD is OFF for this frame's mode (toggled off, or a profile swap to
            -- an AD-off profile) -- tear down any leftover indicators so they
            -- don't linger on screen until the next /reload.
            Engine:ClearFrame(frame)
        end
    end

    if DF.IteratePartyFrames then
        DF:IteratePartyFrames(TryUpdate)
    end
    if DF.IterateRaidFrames then
        DF:IterateRaidFrames(TryUpdate)
    end
    -- ☠ THROUGH THE SHARED WALKER, NOT A HAND-ROLLED HEADER LOOP — this walked
    -- PinnedFrames.headers only, so an Aura Designer edit never reached a pinned BOSS
    -- frame, and neither did the AD-off teardown. (Audit 2026-08-17.)
    if DF.IteratePinnedFrames then
        DF.IteratePinnedFrames(TryUpdate)
    end

    -- The native factory buff row derives its Aura-Designer dedup set from the AD
    -- config at build time, so an AD config change must re-drive the buff row for
    -- the derived exclusion to follow (sig-gated, cheap when unchanged).
    if DF.InvalidateAuraLayout then
        DF:InvalidateAuraLayout()
    end

    -- Refresh the test previews too when the editor is used with test mode open.
    if (DF.testMode or DF.raidTestMode) and DF.UpdateAllTestAuraDesigner then
        DF:UpdateAllTestAuraDesigner()
        -- ⚠ NO Indicator Info rebuild here, deliberately. One was added at this line
        -- and it fixed only the editor's own actions: the designer PRESET bar changes
        -- every indicator on screen without going through this function at all, so the
        -- marks stayed stale exactly where they were first reported. The rebuild now
        -- hangs off Factory:SyncFrame / Factory:ClearFrame — the mutation itself, which
        -- every path reaches by definition. Do not re-add a caller-side hook here; it
        -- would double-fire the one below and still not cover anything new.
    end
end

-- ============================================================
-- POWER INFUSION HELPER -- SCAFFOLDING (slices 1, 1b, 1c, 2)
-- ============================================================
-- THROWAWAY. Drives the gate for testing; slice 3's recipe and settings panel replace all of
-- it. No user-facing surface.
--
-- The gate itself lives in AuraContainer (recordCandidateFilters). This file only decides
-- WHEN it is shut and broadcasts the edge. That split is the point: config is never touched,
-- so a rebuild produces something already gated rather than something we correct.
--
-- Superseded design, for the record: a per-container map swap plus a re-assert after every
-- rebuild. It worked, and it was a race we would have had to keep winning against every
-- rebuild path added later. Watched failing 2026-08-23 -- clobber recorded in combat,
-- rendered at combat end.
-- ============================================================

-- The spell whose cooldown drives the gate. Power Infusion by default, but the mechanism is
-- not priest-specific: any "I have a strong thing ready" cooldown works, which is why this is
-- a value rather than a constant. `/dfpi gate <name or id>` sets it.
local PI_SPELL_ID = 10060       -- Power Infusion

-- The spell the test effects watch. Power Word: Shield: single-target, ~15s, re-castable, so
-- every cast is a FRESH application.
-- ⚠ Two earlier choices failed for reasons worth remembering: Power Word: Fortitude is
-- GROUP-WIDE (one cast covers everyone, leaving no fresh target) and 1h long (cannot wait for
-- it to drop). A test buff must be re-triggerable at will -- check duration, target scope and
-- re-castability before choosing one.
local PIH_WATCH_ID = 21562      -- Power Word: Fortitude. PERMANENT and group-wide, which is
                                -- right for VISUAL tests (the border must survive a 2-minute
                                -- cooldown wait) and wrong for SOUND tests (needs fresh
                                -- applications). Shield (17) is the inverse. ⚠ The right test
                                -- spell depends on what is being measured -- got this wrong in
                                -- both directions on this feature.

local pihGateOpen = true        -- true = show (gate spell ready), false = dark (on cooldown)

-- ☠ MANUAL OVERRIDE. The slash driver and the watcher both write this state; without a notion
-- of who is driving, the watcher stamps over a hand-set gate on the very next global cooldown
-- -- which reads exactly like an external overwrite and is not one. Cost us a round.
-- nil = watcher drives; true/false = held by hand until `/dfpi auto`.
local pihManual = nil

-- The helper sound choice. ⚠ SILENT UNTIL CHOSEN -- nil registers nothing. Real home is the
-- helper's own settings section; this is the scaffolding stand-in.
local pihSoundCfg = nil

-- ═══ THE HELPER'S FILTER ═══
-- Slice 3's recipe will build this properly and seed the real curated cooldown set; this is
-- the same shape at one-spell scale so ownership could be proven before the card exists.
-- The sentinel is what makes an effect OURS. Everything else in the filter is ordinary.
local PIH_FILTER_NAME = "PI Helper (test)"

local function pihFindFilter()
    local R = DF.FilterRegistry
    if not (R and R.ReadStore) then return nil end
    local store = R:ReadStore()
    for id, f in pairs((store and store.customFilters) or {}) do
        if f and f.name == PIH_FILTER_NAME then return id, f end
    end
    return nil
end

function Engine:PIH_EnsureFilter()
    local R = DF.FilterRegistry
    if not (R and R.CreateCustomFilter) then return nil, "FilterRegistry unavailable" end
    local id = pihFindFilter()
    local created = false
    if not id then
        id = R:CreateCustomFilter(PIH_FILTER_NAME)
        created = true
    end
    if not id then return nil, "could not create filter" end
    local sentinel = DF.AuraContainer and DF.AuraContainer.GetHelperSentinel
        and DF.AuraContainer.GetHelperSentinel()
    -- AddSpellToCustom buckets by itself: a known id lands in `spells` snapped to canonical,
    -- an unknown one stays in `rawIDs` -- exactly where the sentinel must live, and where
    -- GetCustomFilter's re-bucketing leaves it because SpellDB has no record for it.
    R:AddSpellToCustom(id, PIH_WATCH_ID)
    if sentinel then R:AddSpellToCustom(id, sentinel) end
    return id, created and "created" or "already existed", sentinel
end

-- Wipe and rebuild the filter IN PLACE. ☠ Never delete-and-recreate: the id is what any Aura
-- Designer effect references (`@custom:cfN`), so a fresh id would leave every effect built on
-- it dangling.
function Engine:PIH_RepairFilter()
    local R = DF.FilterRegistry
    local id = pihFindFilter()
    if not id then return Engine:PIH_EnsureFilter() end
    local f = R:GetCustomFilter(id)
    if not f then return nil, "filter id present but unreadable" end
    wipe(f.spells)
    wipe(f.rawIDs)
    local sentinel = DF.AuraContainer and DF.AuraContainer.GetHelperSentinel
        and DF.AuraContainer.GetHelperSentinel()
    R:AddSpellToCustom(id, PIH_WATCH_ID)
    if sentinel then R:AddSpellToCustom(id, sentinel) end
    return id, "repaired in place", sentinel
end

local function pihFilterContents(id)
    local R = DF.FilterRegistry
    local f = id and R and R.GetCustomFilter and R:GetCustomFilter(id)
    if not f then return "(unreadable)", "(unreadable)" end
    local s, r = {}, {}
    for sid in pairs(f.spells or {}) do s[#s + 1] = tostring(sid) end
    for rid in pairs(f.rawIDs or {}) do r[#r + 1] = tostring(rid) end
    table.sort(s); table.sort(r)
    return (#s > 0 and table.concat(s, ", ") or "(none)"),
           (#r > 0 and table.concat(r, ", ") or "(none)")
end

-- Resolve the helper filter's spell map, for the sound registrations.
local function pihResolvedMap()
    local R = DF.FilterRegistry
    local id = pihFindFilter()
    if not (id and R and R.ResolveSelection) then return nil end
    local res = R:ResolveSelection({ customs = { [id] = true } })
    return (res and res.kind == "include") and res.map or nil
end

-- Arm or disarm helper sound on every AD frame. Mirrors the visual gate: closed = silent.
local function pihSoundsArmed(armed)
    local Factory = DF.AuraDesigner and DF.AuraDesigner.Factory
    if not (Factory and Factory.SetHelperSoundsArmed) then return 0, {}, 0 end
    local map = armed and pihResolvedMap() or nil
    local n, reasons, frames = 0, {}, 0
    local function visit(frame)
        if frame and DF:IsAuraDesignerEnabled(frame) then
            frames = frames + 1
            local got, why = Factory:SetHelperSoundsArmed(frame, armed, map, pihSoundCfg)
            n = n + (got or 0)
            why = why or "?"
            reasons[why] = (reasons[why] or 0) + 1
        end
    end
    if DF.IteratePartyFrames  then DF:IteratePartyFrames(visit)  end
    if DF.IterateRaidFrames   then DF:IterateRaidFrames(visit)   end
    if DF.IteratePinnedFrames then DF.IteratePinnedFrames(visit) end
    return n, reasons, frames
end

-- Flip the gate. ☠ No early return on an unchanged state: our variable records INTENT, never
-- what any container is carrying, and the two are allowed to differ -- a rebuild restores the
-- live map in config while this still reads "dark". An early return made `/dfpi off` decline
-- to act while the border was lit.
-- ☠☠ NOTHING FIRES WHEN A COOLDOWN QUIETLY EXPIRES. `SPELL_UPDATE_COOLDOWN` fires when
-- cooldowns START or change, not when one runs out on its own. Watched 2026-08-23: the gate
-- shut on a Dispersion cast, Dispersion's cooldown ended, and the border stayed dark until the
-- player cast something unrelated -- which fired the event as a side effect of the GCD.
--
-- Earlier tests hid this because the player was casting throughout, so the reopen always had
-- an event to ride on. It is the exact mirror of the GCD bug above: that was an event firing
-- when it should not matter, this is no event firing when it should.
--
-- So while the gate is DARK we poll. Only while dark, one boolean read per tick, and it stops
-- itself the moment the spell is ready -- so the cost is a couple of reads per second during a
-- cooldown and nothing at all the rest of the time.
-- Reads ONE field. `isActive` is plain in combat; startTime / duration / modRate all seal, so
-- nothing here compares a secret and nothing can throw on one.
--
-- ☠☠ BUT `isActive` CANNOT TELL A REAL COOLDOWN FROM THE GLOBAL COOLDOWN. Casting ANY spell
-- makes EVERY spell report active for the duration of the GCD. Watched 2026-08-23: with the
-- gate pointed at Dispersion, casting Power Word: Shield made Dispersion read unready and the
-- gate shut. With Power Infusion the flaw is masked -- its cooldown is minutes long, so the
-- GCD flicker hides inside a real cooldown -- but it is still there: every spell the player
-- casts would blink the helper off for a moment.
--
-- ⇒ SO THIS IS ONLY EVER USED FOR "IS IT READY AGAIN", NEVER FOR "HAS IT JUST GONE DOWN".
-- Opening on `not isActive` is safe: the GCD lapsing and the real cooldown ending both mean
-- genuinely ready. Shutting is driven by the CAST instead -- see the watcher below.
local function pihReadReady()
    local info = C_Spell and C_Spell.GetSpellCooldown and C_Spell.GetSpellCooldown(PI_SPELL_ID)
    if not info then return true end
    return info.isActive ~= true
end

local pihReadyTicker

local function pihStopTicker()
    if pihReadyTicker then pihReadyTicker:Cancel(); pihReadyTicker = nil end
end

local function pihSet(dark)
    pihGateOpen = not dark
    local n = 0
    if DF.AuraContainer and DF.AuraContainer.SetHelperGate then
        n = DF.AuraContainer.SetHelperGate(dark)
    end
    -- Sound rides the SAME edge as the visuals. It is not a container, so the gate cannot
    -- reach it -- without this it would keep announcing while we are silent.
    pihSoundsArmed(not dark)

    if dark then
        if not pihReadyTicker and C_Timer and C_Timer.NewTicker then
            pihReadyTicker = C_Timer.NewTicker(0.5, function()
                -- Held by hand: never fight the user's own /dfpi off.
                if pihManual ~= nil then return end
                if pihReadReady() then
                    pihStopTicker()
                    if not pihGateOpen then pihSet(false) end
                end
            end)
        end
    else
        pihStopTicker()
    end
    return n
end

function Engine:PIH_SetGateOpen(open) return pihSet(not open) end

-- Point the gate at a different cooldown. Called by the settings panel; `/dfpi gate` uses the
-- same path. ☠ Re-derives immediately: a saved setting that was never pushed is a setting that
-- does not apply until something else happens to re-derive it.
function Engine:PIH_SetGateSpell(spellID)
    spellID = tonumber(spellID)
    if not spellID then return false end
    PI_SPELL_ID = spellID
    local ready = pihReadReady()
    pihSet(not ready)
    return true
end

function Engine:PIH_GetGateSpell() return PI_SPELL_ID end

-- ☠ THE GATE CAN BE SWITCHED OFF ENTIRELY. "Hide while Power Infusion is on cooldown" is the
-- whole point of the helper, so it defaults on -- but someone who just wants to see burst
-- windows can turn it off, and then the helper never hides.
--
-- Off means FORCE OPEN and stay there: the watcher stops driving, so a cooldown starting or
-- ending changes nothing. Not "ignore the events" -- the gate is genuinely open, which is what
-- the setting says.
local pihGateEnabled = true

function Engine:PIH_SetGateEnabled(on)
    pihGateEnabled = on and true or false
    if not pihGateEnabled then
        pihManual = nil
        pihSet(false)          -- open, and nothing will shut it
    else
        local ready = pihReadReady()
        pihSet(not ready)      -- resume from the real cooldown state
    end
    return pihGateEnabled
end

function Engine:PIH_IsGateEnabled() return pihGateEnabled end

-- ☠ THE RESIDENT HALF READS THE SAVED SETTINGS ITSELF. The panel that writes them lives in
-- the load-on-demand options addon, so anything that only applied when the panel was open
-- would silently not apply to a player who never opens their settings -- which is most of
-- them, most of the time. §1b's whole point.
--
-- Reads the party preset: the helper is per-preset (§2), and a party/raid split sharing one
-- preset shares the helper, which is the addon's model for every other effect.
function Engine:PIH_ApplySaved()
    local adDB = DF.GetModeBaseAuraDesigner and DF:GetModeBaseAuraDesigner("party")
    local s = adDB and adDB.pihelper
    if not s then return false end

    if DF.AuraContainer and DF.AuraContainer.SetHelperExcludedRoles then
        local any = false
        for _ in pairs(s.roles or {}) do any = true break end
        DF.AuraContainer.SetHelperExcludedRoles(any and s.roles or nil)
    end
    Engine:PIH_SetGateEnabled(s.gateEnabled ~= false)
    return true
end


-- ☠ SHUT ON THE CAST, OPEN ON THE COOLDOWN CLEARING.
-- §4b originally specified "read isActive, edge-detect, done" and explicitly REJECTED watching
-- the cast, on the grounds that predicting a cooldown's LENGTH would be a second source of
-- truth that could drift. That reasoning still stands and is not what this does: nothing here
-- predicts a duration. The cast is used only as the unambiguous "it has just gone down"
-- signal, and the cooldown itself still decides when it comes back.
--
-- Rejected alternative: only shut if the spell still reads unready after ~1.6s (longer than
-- any GCD). Simpler, no new events -- and it breaks under sustained casting, where the GCD
-- never lapses and therefore looks exactly like a real cooldown.
local pihWatcher = CreateFrame("Frame")
pihWatcher:RegisterEvent("SPELL_UPDATE_COOLDOWN")
pihWatcher:RegisterEvent("PLAYER_ENTERING_WORLD")
pihWatcher:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
pihWatcher:SetScript("OnEvent", function(_, event, unit, _, spellID)
    if not pihGateEnabled then return end   -- switched off: nothing shuts or opens it
    if pihManual ~= nil then return end

    if event == "UNIT_SPELLCAST_SUCCEEDED" then
        -- The only thing that shuts the gate. Our own cast of the gate spell, nothing else.
        if unit ~= "player" or spellID ~= PI_SPELL_ID then return end
        if not pihGateOpen then return end
        local n = pihSet(true)
        DF:Debug("AURADESIGNER", "PIH gate -> DARK on cast (%d container%s)", n, n == 1 and "" or "s")
        return
    end

    if event == "PLAYER_ENTERING_WORLD" then
        Engine:PIH_ApplySaved()   -- saved settings, before any gate decision
        -- ☠ THE ONE PLACE isActive MAY SHUT THE GATE. On load we never saw the cast, so a
        -- reload mid-cooldown would otherwise leave the helper showing for the rest of it.
        -- Safe here specifically because nothing is being cast at this instant, so a true
        -- reading is a real cooldown rather than a GCD.
        local ready = pihReadReady()
        if ready ~= pihGateOpen then pihSet(not ready) end
        return
    end

    -- SPELL_UPDATE_COOLDOWN: OPENING ONLY. Fires on every global cooldown, so it must never be
    -- allowed to shut anything -- that is the bug this whole block exists for.
    local ready = pihReadReady()
    if not ready then return end
    if pihGateOpen then return end
    local n = pihSet(false)
    DF:Debug("AURADESIGNER", "PIH gate -> OPEN, cooldown cleared (%d container%s)",
        n, n == 1 and "" or "s")
end)

SLASH_DFPI1 = "/dfpi"
SlashCmdList["DFPI"] = function(msg)
    -- ☠ LOWERCASE THE COMMAND, NEVER THE ARGUMENT. This lowercased the whole line once, so a
    -- sound name like "BugSack: Fatality" arrived as "bugsack: fatality" and LibSharedMedia --
    -- which is case-sensitive -- resolved it to nothing. The name was fine; we broke it.
    local raw = (msg or ""):gsub("^%s+", ""):gsub("%s+$", "")
    msg = raw:lower()

    if msg == "off" or msg == "dark" then
        pihManual = false
        DF:Out("PI Helper", "gate DARK (held by hand)")
            :Field("containers re-pushed", pihSet(true))
            :Line("watcher suspended -- /dfpi auto to hand it back", "neutral")
        return
    end

    if msg == "on" or msg == "open" then
        pihManual = true
        DF:Out("PI Helper", "gate OPEN (held by hand)")
            :Field("containers re-pushed", pihSet(false))
            :Line("watcher suspended -- /dfpi auto to hand it back", "neutral")
        return
    end

    if msg == "auto" then
        pihManual = nil
        local ready = pihReadReady()
        DF:Out("PI Helper", "watcher resumed")
            :Field("gate", ready and "OPEN" or "DARK")
            :Field("containers re-pushed", pihSet(not ready))
        return
    end

    if msg == "setup" or msg == "repair" then
        local id, how, sentinel
        if msg == "repair" then id, how, sentinel = Engine:PIH_RepairFilter()
        else                    id, how, sentinel = Engine:PIH_EnsureFilter() end
        if not id then
            DF:Err("PI Helper: " .. tostring(how))
            return
        end
        -- Same staleness as /dfpi watch: a rebuilt filter does not reach live containers on its own.
        if DF.InvalidateAuraLayout then DF:InvalidateAuraLayout() end
        if DF.UpdateAllFrames then DF:UpdateAllFrames() end
        if Engine.ForceRefreshAllFrames then Engine:ForceRefreshAllFrames() end
        local known, raw2 = pihFilterContents(id)
        DF:Out("PI Helper", "filter " .. tostring(how))
            :Field("filter", PIH_FILTER_NAME)
            :Field("id", id)
            :Field("known spells", known)
            :Field("raw ids", raw2, "good")
            :Line("the sentinel MUST appear under raw ids -- that is what makes it ours", "neutral")
        return
    end

    -- ☠ FROM `raw`, NOT `msg`: spell names have capitals and spaces.
    local garg = raw:match("^[Gg][Aa][Tt][Ee]%s+(.+)$")
    if garg then
        -- C_Spell.GetSpellInfo accepts a name OR an id and answers with the resolved spellID
        -- -- the same call ClickCasting/Bindings.lua:183 leans on. One path covers both.
        local info = C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(garg)
        local gid = info and info.spellID or tonumber(garg)
        if not gid then
            DF:Err(("PI Helper: no spell called '%s' -- check the spelling, or pass an id"):format(garg))
            return
        end
        PI_SPELL_ID = gid
        local ready = pihReadReady()
        local n = pihSet(not ready)
        DF:Out("PI Helper", "gate spell changed")
            :Field("you typed", garg)
            :Field("resolved to", ("%d  %s"):format(gid, tostring((info and info.name) or "?")),
                   info and "good" or "warn")
            :Field("ready now", tostring(ready))
            :Field("containers re-pushed", n)
            :Line("watcher now follows this spell's cooldown", "neutral")
        return
    end

    local wid = tonumber(msg:match("^watch%s+(%d+)$"))
    if wid then
        PIH_WATCH_ID = wid
        local _, how = Engine:PIH_RepairFilter()
        -- ☠ REBUILDING THE FILTER IS NOT ENOUGH. Live containers were built from the OLD
        -- resolved map and keep using it until something re-syncs them -- so the effect went
        -- on watching the previous spell and showed nothing, which reads exactly like a
        -- broken gate. Only a /reload fixed it. Same refresh chain AddPickedSpell runs after
        -- a structural change.
        if DF.InvalidateAuraLayout then DF:InvalidateAuraLayout() end
        if DF.UpdateAllFrames then DF:UpdateAllFrames() end
        if Engine.ForceRefreshAllFrames then Engine:ForceRefreshAllFrames() end
        local n, reasons = pihSoundsArmed(pihGateOpen)
        local out = DF:Out("PI Helper", "watched spell changed")
            :Field("spell id", wid)
            :Field("name", tostring((C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(wid)) or "?"))
            :Field("filter", tostring(how))
            :Field("sound registrations", n, n > 0 and "good" or "warn")
        for why, count in pairs(reasons or {}) do out:Field("  " .. why, count) end
        return
    end

    local rl = raw:match("^[Rr][Oo][Ll][Ee][Ss]%s+(.+)$")
    if rl then
        local roles, names = nil, {}
        if rl:lower() ~= "off" and rl:lower() ~= "none" then
            roles = {}
            for w in rl:gmatch("[^%s,]+") do
                local k = w:upper()
                if k == "TANK" or k == "HEALER" or k == "DAMAGER" then
                    roles[k] = true; names[#names + 1] = k
                end
            end
            if not next(roles) then roles = nil end
        end
        local n = DF.AuraContainer.SetHelperExcludedRoles(roles)
        DF:Out("PI Helper", "role exclusion")
            :Field("excluded", #names > 0 and table.concat(names, ", ") or "nobody")
            :Field("containers re-pushed", n)
            :Line("unknown/unassigned roles are NEVER excluded -- fails open by design", "neutral")
        return
    end

    local snd = raw:match("^[Ss][Oo][Uu][Nn][Dd]%s+(.+)$")
    if snd then
        if snd:lower() == "off" or snd:lower() == "none" then
            pihSoundCfg = nil
            pihSoundsArmed(false)
            DF:Out("PI Helper", "sound cleared"):Line("silent until chosen", "neutral")
        else
            pihSoundCfg = { soundLSMKey = snd }
            local n, reasons, frames = pihSoundsArmed(pihGateOpen)
            local out = DF:Out("PI Helper", "sound set")
                :Field("LSM key", snd)
                :Field("resolves to", tostring(DF:GetSoundPath(snd) or "NOTHING -- bad name"),
                       DF:GetSoundPath(snd) and "good" or "bad")
                :Field("AD frames visited", frames)
                :Field("registrations", n, n > 0 and "good" or "bad")
            for why, count in pairs(reasons or {}) do out:Field("  " .. why, count) end
        end
        return
    end

    local nrw = msg:match("^narrow%s+(%a+)$")
    if nrw then
        local Factory = DF.AuraDesigner and DF.AuraDesigner.Factory
        Factory._helperSoundNarrow = (nrw ~= "off")
        local n, reasons = pihSoundsArmed(pihGateOpen)
        local out = DF:Out("PI Helper", "class narrowing " .. (Factory._helperSoundNarrow and "ON" or "OFF"))
            :Field("registrations", n, n > 0 and "good" or "bad")
        for why, count in pairs(reasons or {}) do out:Field("  " .. why, count) end
        return
    end

    if msg == "sounds" then
        local LSM = LibStub and LibStub("LibSharedMedia-3.0", true)
        if not LSM then DF:Err("PI Helper: LibSharedMedia not available"); return end
        local list = LSM:List("sound") or {}
        local out = DF:Out("PI Helper", "available sound names")
        for i = 1, math.min(#list, 30) do out:Line(list[i]) end
        if #list > 30 then out:Line(("... and %d more"):format(#list - 30), "neutral") end
        return
    end

    if msg == "who" then
        local out = DF:Out("PI Helper", "units and roles")
        local n = 0
        local function visit(frame)
            local u = frame and frame.unit
            if not (u and UnitExists(u)) then return end
            n = n + 1
            local role = DF.GetUnitRole and DF:GetUnitRole(u)
            local rawRole = UnitGroupRolesAssigned and UnitGroupRolesAssigned(u)
            if issecretvalue and issecretvalue(rawRole) then rawRole = "SECRET" end
            local _, cls = UnitClass(u)
            out:Line(("%s  %s  class=%s  role=%s  raw=%s"):format(
                u, tostring(UnitName(u)), tostring(cls),
                tostring(role or "nil"), tostring(rawRole or "nil")),
                (role and role ~= "NONE") and "good" or "warn")
        end
        if DF.IteratePartyFrames  then DF:IteratePartyFrames(visit)  end
        if DF.IterateRaidFrames   then DF:IterateRaidFrames(visit)   end
        if DF.IteratePinnedFrames then DF.IteratePinnedFrames(visit) end
        if n == 0 then out:Line("no units on any frame", "bad") end
        out:Line("role=nil or NONE means role exclusion CANNOT apply (fails open)", "neutral")
        return
    end

    if msg == "rebuild" then
        -- ☠ THE HAZARD PROBE, AND NOW THE REGRESSION TEST. Under the first design this
        -- restored the live map and the border came back at the next flush. Under the
        -- chokepoint design the rebuild is expected and harmless: the fresh config carries the
        -- live map, and the funnel gates it on the way out regardless. The border must now
        -- stay dark -- in combat AND after it ends.
        local touched, frames = 0, 0
        local Factory = DF.AuraDesigner and DF.AuraDesigner.Factory
        local function visit(frame)
            if not (frame and DF:IsAuraDesignerEnabled(frame)) then return end
            local bd = frame.dfADFactory and frame.dfADFactory.border
            if bd then
                for _, entry in pairs(bd) do
                    if entry then
                        entry.structSig, entry.tuningSig, entry.coSig = nil, nil, nil
                        touched = touched + 1
                    end
                end
            end
            if Factory then Factory:SyncFrame(frame); frames = frames + 1 end
        end
        if DF.IteratePartyFrames  then DF:IteratePartyFrames(visit)  end
        if DF.IterateRaidFrames   then DF:IterateRaidFrames(visit)   end
        if DF.IteratePinnedFrames then DF.IteratePinnedFrames(visit) end
        -- ☠ COMBAT STATE STAMPED AT EVERY OBSERVATION POINT. An earlier reading of "the border
        -- relit while still in combat" was taken by judgement rather than measurement, and was
        -- wrong -- combat had lapsed between commands. The log is the timeline now.
        local function stamp(tag)
            DF:Out("PI Helper", "combat stamp " .. tag)
                :Field("in combat", InCombatLockdown() and "YES" or "no",
                       InCombatLockdown() and "good" or "warn")
                :Field("gate intends", pihGateOpen and "OPEN" or "DARK")
        end
        DF:Out("PI Helper", "forced rebuild (regression probe)")
            :Field("in combat AT PROBE", InCombatLockdown() and "YES" or "no",
                   InCombatLockdown() and "good" or "warn")
            :Field("gate", pihGateOpen and "OPEN" or "DARK")
            :Field("border entries invalidated", touched)
            :Field("frames re-synced", frames)
            :Line(pihGateOpen and "gate is OPEN -- this proves nothing; close it first"
                              or "border must STAY DARK now, in combat and after", "neutral")
        if C_Timer and C_Timer.After then
            C_Timer.After(0.5, function() stamp("+0.5s") end)
            C_Timer.After(3,   function() stamp("+3s")   end)
        end
        return
    end

    local dark, rolesSet = false, false
    if DF.AuraContainer and DF.AuraContainer.GetHelperGate then
        dark, rolesSet = DF.AuraContainer.GetHelperGate()
    end
    DF:Out("PI Helper", "status")
        :Field("gate intends", pihGateOpen and "OPEN" or "DARK")
        :Field("chokepoint says", dark and "DARK" or "OPEN",
               dark == (not pihGateOpen) and "good" or "bad")
        :Field("gate spell", ("%d (%s)"):format(PI_SPELL_ID,
               tostring((C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(PI_SPELL_ID)) or "?")))
        :Field("gate spell ready", tostring(pihReadReady()))
        :Field("watched spell", PIH_WATCH_ID)
        :Field("driven by", pihManual ~= nil and "HAND (watcher suspended)" or "watcher")
        :Field("sound", pihSoundCfg and (pihSoundCfg.soundLSMKey or "custom") or "silent (none chosen)")
        :Field("roles excluded", (function()
            local r = DF.AuraContainer and DF.AuraContainer.GetHelperExcludedRoles
                and DF.AuraContainer.GetHelperExcludedRoles()
            if not r then return "nobody" end
            local t = {}; for k in pairs(r) do t[#t + 1] = k end; table.sort(t)
            return table.concat(t, ", ")
        end)())
        :Hints("/dfpi setup", "/dfpi sounds", "/dfpi sound <name>", "/dfpi narrow off",
               "/dfpi gate <name or id>", "/dfpi watch <id>", "/dfpi roles tank healer",
               "/dfpi who", "/dfpi off", "/dfpi on", "/dfpi auto", "/dfpi rebuild")
end

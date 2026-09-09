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

-- Hot-path globals, cached once: the cooldown watcher and its ticker read these on every
-- event and every tick, all fight long.
local C_Spell = C_Spell
local C_Timer = C_Timer
local issecretvalue = issecretvalue



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
-- POWER INFUSION HELPER -- THE GATE
-- ============================================================
-- Decides WHEN the helper's marks go dark, and broadcasts the edge. The settings panel and the
-- recipe live on the Options side (AuraDesigner/UI/Cards.lua); this is the resident half, and
-- it must work with the settings panel never having been opened.
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

-- The spell whose cooldown drives the gate. Power Infusion, and the panel offers no way to
-- change it: "which spell hides this" is a question about plumbing rather than about the
-- feature, and nobody asked for it. Left as a value rather than a constant because the
-- mechanism is not priest-specific -- any "I have a strong thing ready" cooldown works -- so a
-- picker could return without the engine changing.
local PI_SPELL_ID = 10060       -- Power Infusion

local pihGateOpen = true        -- true = show (gate spell ready), false = dark (on cooldown)

-- ☠ MANUAL OVERRIDE. The slash driver and the watcher both write this state; without a notion
-- of who is driving, the watcher stamps over a hand-set gate on the very next global cooldown
-- -- which reads exactly like an external overwrite and is not one. Cost us a round.
-- nil = watcher drives; true/false = held by hand until `/df debug pi auto`.
local pihManual = nil

-- The helper sound choice, written by the settings panel through PIH_SetSound and restored on
-- login by PIH_ApplySaved. ⚠ SILENT UNTIL CHOSEN -- nil registers nothing, because an
-- audio cue nobody asked for is the fastest way to have a feature switched off wholesale.
local pihSoundCfg = nil

-- ☠ NOT PARTY-ONLY, AND IT WAS. This read hardcoded the party preset while the settings panel
-- writes to whichever mode the Aura Designer is editing -- so a helper configured in RAID mode
-- had its gate, its role exclusions and its sound silently dropped on every load, while its
-- indicators carried on rendering from the raid pool. It would have read as the gate simply
-- not working, with nothing on screen to explain it. Caught in review, before anyone met it.
--
-- ⚠ FIRST PRESET THAT HAS A HELPER WINS, PARTY FIRST. The gate is ONE switch for the whole
-- addon, so two presets carrying different helper settings is an ambiguity no read can resolve
-- -- taking the first is a choice, not a derivation. Party first because that is where the
-- feature is used. If this ever needs to differ per mode, the gate has to become per-mode
-- first, and that is a bigger change than a better read.
local PIH_MODES = { "party", "raid" }

-- ☠ "DOES A HELPER EXIST" IS ONE QUESTION, ANSWERED FROM THE MARKS -- the same
-- derivation the panel uses, so the two halves cannot disagree. An earlier version tested for
-- the recorded list id instead, and the two definitions drifted apart in exactly one state:
-- untick every signal without pressing Remove, and the panel correctly reported the helper
-- gone while the engine kept its event registrations and its armed sound, because the list id
-- outlives the signals (the spell list is still there; nothing points at it). Field-found.
--
-- ⚠ The marks ARE the record -- effects, placed instances and icon groups all carry
-- pihSignal -- so scanning for one is the definition, not a proxy for it. Cheap: it runs on
-- settings changes and login, never in a frame update.
local function pihHasHelper(adDB)
    if type(adDB) ~= "table" then return false end
    for _, auraCfg in pairs(adDB.otherAuras or {}) do
        if type(auraCfg) == "table" then
            for _, v in pairs(auraCfg) do
                if type(v) == "table" and v.pihSignal then return true end
            end
            for _, inst in ipairs(auraCfg.indicators or {}) do
                if type(inst) == "table" and inst.pihSignal then return true end
            end
        end
    end
    for _, g in ipairs(adDB.otherLayoutGroups or {}) do
        if type(g) == "table" and g.pihSignal then return true end
    end
    return false
end

-- ⚠ FIRST PRESET THAT HAS A HELPER WINS, PARTY FIRST. The gate is ONE switch for the
-- whole addon, so two presets carrying different helper settings is an ambiguity no read can
-- resolve -- taking the first is a choice, not a derivation. Party first because that is where
-- the feature is used. A preset whose settings table survived a Remove no longer shadows one
-- that actually has a helper, because the marks decide.
-- Held between runs of the sound probe: a registration whose REMOVAL was blocked is still live,
-- and dropping its id is the exact defect being measured. nil when nothing is held.
local pihProbeLeakedID = nil

-- ☠ THE RESTRICTION STATE, READ CORRECTLY. Both probes used to pass STRINGS to
-- `C_RestrictedActions.IsAddOnRestrictionActive`, which takes an `Enum.AddOnRestrictionType`
-- value. A string is not nil, so the call returned truthy for every kind and the readout listed
-- all five as active -- in a capital city as readily as on a boss. Two runs then disagreed while
-- both claimed the same state, which is what exposed it.
-- ⚠ A LABEL THAT IS ALWAYS TRUE IS WORSE THAN NO LABEL: it does not merely fail to
-- inform, it actively certifies the wrong conclusion. The first in-combat run "passed in
-- Combat+Encounter+ChallengeMode+PvPMatch" and was very likely in none of them.
local function pihRestrictions()
    local out = {}
    local kinds = Enum and Enum.AddOnRestrictionType
    if kinds and C_RestrictedActions and C_RestrictedActions.IsAddOnRestrictionActive then
        for _, name in ipairs({ "Combat", "Encounter", "ChallengeMode", "PvPMatch" }) do
            local v = kinds[name]
            if v ~= nil then
                local ok, active = pcall(C_RestrictedActions.IsAddOnRestrictionActive, v)
                -- Secret-guard BEFORE the comparison, the rule this file already lives by.
                if ok and not (issecretvalue and issecretvalue(active)) and active == true then
                    out[#out+1] = name
                end
            end
        end
    elseif not kinds then
        out[#out+1] = "enum missing"
    end
    if InCombatLockdown and InCombatLockdown() then out[#out+1] = "Lockdown" end
    return out
end

-- ☠ WHICH PRESET THE ANSWER CAME FROM, remembered for the readout. Field report
-- 2026-09-09: "it's using the party settings even if I'm in raid". That is exactly what the loop
-- below does -- party first, whichever mode you are standing in -- and until now the readout could
-- not show it, so the behaviour was indistinguishable from a bug in the gate or the roles.
-- ⚠ A DIAGNOSTIC THAT CANNOT NAME ITS SOURCE turns a known limitation into a mystery.
local pihSettingsMode = nil

local function pihSettings()
    pihSettingsMode = nil
    if not DF.GetModeBaseAuraDesigner then return nil end
    for _, mode in ipairs(PIH_MODES) do
        local adDB = DF:GetModeBaseAuraDesigner(mode)
        local s = adDB and adDB.pihelper
        if s and pihHasHelper(adDB) then pihSettingsMode = mode; return s end
    end
    return nil
end

-- Resolve the helper filter's spell map, for the sound registrations.
-- ☠ THIS RESOLVED THE WRONG FILTER ONCE, AND THE SOUND COULD THEREFORE NEVER PLAY.
-- It looked the list up BY NAME, and the name it used belonged to a throwaway test filter that
-- only existed if a developer had built it by hand. The recipe builds "Power Infusion Helper".
-- On every real install the lookup missed, the map came back nil, `helperSoundMapFor` bailed on
-- its first line, and every registration was skipped: zero sounds, always. ⚠ AND THE TEST
-- FOR IT PASSED -- it asked whether the SETTING survived a reload, which it did perfectly. A
-- test that never asks whether a sound comes out cannot tell a working feature from an inert
-- one. Caught in review, not in the field.
--
-- ⚠ BY ID, NOT BY NAME, and there is no name fallback any more. A custom filter can be
-- renamed in the Filter Designer, so the recipe records the id it created and this reads that.
local function pihResolvedMap()
    local R = DF.FilterRegistry
    if not (R and R.ResolveSelection) then return nil end
    local s = pihSettings()
    local id = s and s.cooldownFilterID
    if not (id and R.GetCustomFilter and R:GetCustomFilter(id)) then return nil end
    local res = R:ResolveSelection({ customs = { [id] = true } })
    return (res and res.kind == "include") and res.map or nil
end

-- Arm or disarm helper sound on every AD frame. Mirrors the visual gate: closed = silent.
-- ☠ SKIPS THE RESOLVE WHEN NOTHING COULD PLAY. With no sound chosen -- the shipped
-- default -- arming would resolve the whole spell list and walk every frame just to register
-- nothing. The DISARM pass still walks: teardown is the thing that actually silences.
-- The last arm pass, remembered for the status readout: how many registrations, over how
-- many frames, and when. ☠ A field failure ("no sound in the dungeon after a reload")
-- arrived with a readout that showed every SETTING healthy -- because the readout could not
-- see the per-frame wiring. These three numbers are what would have named it in one look.
local pihLastArmCount, pihLastArmFrames, pihLastArmAt = 0, 0, nil
-- ☠ AND WHY IT REGISTERED NOTHING. SetHelperSoundsArmed already returns a reason with
-- its count -- its own comment says "a bare 0 has six different meanings and they point different
-- ways" -- and the caller below read only the count and dropped the reason on the floor. A zero
-- then meant: no sound chosen, or no spells after class narrowing, or every unit role-excluded, or
-- the list failed to resolve, or the API refused the call. Five different faults, one number,
-- indistinguishable. Field-found 2026-09-09 on a readout showing 0 registrations with the gate
-- OPEN and 50 containers gated, which should have been impossible to misread and was not.
local pihLastArmReasons = nil

local function pihSoundsArmed(armed)
    local Factory = DF.AuraDesigner and DF.AuraDesigner.Factory
    if not (Factory and Factory.SetHelperSoundsArmed) then return 0 end
    if armed and not pihSoundCfg then armed = false end
    local map = armed and pihResolvedMap() or nil
    local n, frames = 0, 0
    local reasons = {}
    local function visit(frame)
        if frame and DF:IsAuraDesignerEnabled(frame) then
            frames = frames + 1
            local got, why = Factory:SetHelperSoundsArmed(frame, armed, map, pihSoundCfg)
            n = n + (got or 0)
            -- Tally the reason whenever a frame produced nothing. Counted, not listed: forty
            -- frames saying the same thing is one fact, and printing it forty times buries it.
            if (got or 0) == 0 then
                local key = why or "no reason given"
                reasons[key] = (reasons[key] or 0) + 1
            end
        end
    end
    if DF.IteratePartyFrames  then DF:IteratePartyFrames(visit)  end
    if DF.IterateRaidFrames   then DF:IterateRaidFrames(visit)   end
    if DF.IteratePinnedFrames then DF.IteratePinnedFrames(visit) end
    pihLastArmCount, pihLastArmFrames = n, frames
    pihLastArmReasons = next(reasons) and reasons or nil
    pihLastArmAt = date and date("%H:%M:%S") or "?"
    return n
end

-- Flip the gate. ☠ No early return on an unchanged state: our variable records INTENT, never
-- what any container is carrying, and the two are allowed to differ -- a rebuild restores the
-- live map in config while this still reads "dark". An early return made "/df debug pi off" decline
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
-- Reads FLAGS ONLY. `isActive` is plain in combat and `isOnGCD` is guarded below; startTime /
-- duration / modRate all seal and none of them is touched, so nothing here compares a secret.
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
-- ⭐⭐ A REAL COOLDOWN IS `isActive` AND NOT `isOnGCD`. Danders' answer to our GCD finding
-- (2026-08-23), and it replaces the workaround rather than sitting beside it: `isActive` alone
-- reads true for EVERY spell while the global cooldown runs, so the helper blinked off whenever
-- the player cast anything. `isOnGCD` is the sibling flag that says which of the two it is, and
-- both stay readable in combat while startTime / duration / modRate seal.
--
-- Shape follows DandersCDM's `ClassifyCooldown` (Display/CooldownBar.lua), which credits
-- Ellesmere's hooks for the same discriminator -- "no duration/magnitude math, only the clean
-- bool flags". Danders pasted that function on 2026-08-24, so the branches below are checked
-- against the original rather than against a paraphrase of it.
--
-- ⚠ WE DELIBERATELY DO NOT COPY ITS DURATION FALLBACK, and the reason is our own rule. CDM
-- compares `duration` against the GCD when `isOnGCD` is missing, because CDM also serves clients
-- whose info table genuinely lacks the field. Ours never will, and Danders checked the history:
-- nobody has ever observed `isOnGCD` sealing. That branch would be one we could never exercise.
-- The `issecretvalue` GUARD stays -- a compare on a sealed value throws, so it prevents a hard
-- error rather than being dead weight -- but when it fires we resolve from charges instead.
--
-- ⚠ CHARGES, and this is where the old fail-safe hurt. With the flags readable a charge spell
-- needs no special handling: a charge in hand reads not-active (or active + isOnGCD during the
-- global), and zero charges reads active and NOT on GCD, which is exactly "genuinely on
-- cooldown". With the flags UNREADABLE, "assume on cooldown" would darken the helper while the
-- player still held a charge and could infuse right now. `currentCharges` stays non-secret and
-- answers precisely that, so it is what the unknown case resolves from.
--
-- ⚠ Latent, not live. The shipped panel has no gate-spell picker, so the gate spell is always
-- Power Infusion, which has no charges. This is correctness for a capability that exists
-- underneath, not a fix for anything a user can hit today.
--
-- ⚠ Charges also fire their own event -- SPELL_UPDATE_COOLDOWN does not cover a charge coming
-- back. SPELL_UPDATE_CHARGES is registered with the watcher below for that reason.
local function pihReadCharges(spellID)
    if not (C_Spell and C_Spell.GetSpellCharges) then return nil end
    local c = C_Spell.GetSpellCharges(spellID)
    if not c then return nil end
    local cur = c.currentCharges
    -- Secret check MUST precede everything else: even a nil test on a secret throws on 12.1.
    if issecretvalue and issecretvalue(cur) then return nil end
    if type(cur) ~= "number" then return nil end
    return cur
end

local function pihReadReady()
    local info = C_Spell and C_Spell.GetSpellCooldown and C_Spell.GetSpellCooldown(PI_SPELL_ID)
    if not info then return true end
    if info.isActive ~= true then return true end

    local gcd = info.isOnGCD
    local sealed = issecretvalue and issecretvalue(gcd)
    -- ☠ SEALED TEST FIRST. `and` evaluates left to right, so writing this as
    -- `gcd ~= nil and not sealed` runs the nil comparison BEFORE the guard that exists to
    -- prevent it -- and a comparison against a sealed value throws. The guard was decorative
    -- in exactly the branch it was written for. pihReadCharges gets the order right and says
    -- why; caught in Danders' PR review.
    if not sealed and gcd ~= nil then
        -- Active AND merely the global cooldown = not a real cooldown = still ready.
        return gcd == true
    end

    -- No usable flag. A charge in hand means usable, whatever the spell cooldown claims.
    local charges = pihReadCharges(PI_SPELL_ID)
    if charges ~= nil then return charges >= 1 end

    -- Nothing readable either way. Treat as on cooldown: the failure we can afford is a helper
    -- that hides when it did not have to, not one that marks people we cannot infuse.
    return false
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
        -- ⚠ Never under a manual hold: the tick body refuses to act while held (below),
        -- so a ticker started here would idle at 2 Hz for the rest of the session. Handing
        -- control back re-enters through pihSet and starts it then, if still dark.
        if not pihReadyTicker and pihManual == nil and C_Timer and C_Timer.NewTicker then
            pihReadyTicker = C_Timer.NewTicker(0.5, function()
                -- Held by hand: never fight a gate the user is holding themselves.
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
        -- ⚠ Re-enabling releases a manual hold too. Without this, "gate enabled" and
        -- "held by hand" could both be true at once, with the watcher suspended and nothing
        -- on screen to say so.
        pihManual = nil
        local ready = pihReadReady()
        pihSet(not ready)      -- resume from the real cooldown state
    end
    return pihGateEnabled
end

-- ☠ THE SOUND CHOICE HAS TO BE APPLIED, NOT MERELY STORED. An early version kept it
-- only in the file-local above, which dies on reload, and the login path never armed it -- a
-- player who picked a sound and logged out had picked nothing.
-- The panel saves the key with the helper's other settings; this is the one place that turns a
-- saved key into live registrations, and it is called from both the panel and the login path.
-- An empty or missing key means SILENT: no sound was ever a default, and an audio cue nobody
-- asked for is the fastest way to have a feature switched off wholesale.
function Engine:PIH_SetSound(lsmKey)
    pihSoundCfg = (type(lsmKey) == "string" and lsmKey ~= "") and { soundLSMKey = lsmKey } or nil
    -- Armed only while the gate is open: sound is not a container, so nothing the gate does to
    -- the visuals reaches it -- it needs its own edge action or it announces windows during the
    -- exact minutes the helper is meant to be silent.
    return pihSoundsArmed(pihGateOpen and pihSoundCfg ~= nil)
end

-- ☠ THE RESIDENT HALF READS THE SAVED SETTINGS ITSELF. The panel that writes them lives in
-- the load-on-demand options addon, so anything that only applied when the panel was open
-- would silently not apply to a player who never opens their settings -- which is most of
-- them, most of the time. §1b's whole point.
--
-- Reads whichever preset actually has a helper installed, party first (see pihSettings); a
-- party/raid split sharing one preset shares the helper, which is the addon's model for
-- every other effect.
--
-- ☠ ALSO THE RESET PATH. Called on login AND after a profile switch, and the new
-- profile may have no helper -- in which case everything the old one pushed must come back
-- out: roles, the gate, and above all the sound registrations, which would otherwise keep
-- playing for a helper that no longer exists anywhere.
local pihSyncWatcher   -- defined beside the watcher below; registration follows helper existence
function Engine:PIH_ApplySaved()
    local s = pihSettings()
    if not s then
        if DF.AuraContainer and DF.AuraContainer.SetHelperExcludedRoles then
            DF.AuraContainer.SetHelperExcludedRoles(nil)
        end
        pihManual = nil
        pihGateEnabled = true
        Engine:PIH_SetSound(nil)   -- tears down every live registration
        pihSet(false)              -- open; nothing is left to hide
        if pihSyncWatcher then pihSyncWatcher() end
        return false
    end

    if DF.AuraContainer and DF.AuraContainer.SetHelperExcludedRoles then
        local any = false
        for _ in pairs(s.roles or {}) do any = true break end
        DF.AuraContainer.SetHelperExcludedRoles(any and s.roles or nil)
    end
    Engine:PIH_SetGateEnabled(s.gateEnabled ~= false)
    -- After the gate, never before: SetSound arms against the gate's current state, so calling
    -- it first would arm against the state we are about to leave.
    Engine:PIH_SetSound(s.soundOn and s.soundLSMKey or nil)
    if pihSyncWatcher then pihSyncWatcher() end
    return true
end

-- Public seam for the panel: create, remove and apply all change whether a helper exists,
-- which is what decides the watcher's registrations.
function Engine:PIH_SyncWatcher() if pihSyncWatcher then pihSyncWatcher() end end


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
pihWatcher:RegisterEvent("PLAYER_ENTERING_WORLD")

-- ☠ THE OTHER EVENTS ONLY EXIST WHILE A HELPER DOES. SPELL_UPDATE_COOLDOWN fires on
-- every global cooldown for every class, and the panel is priest-gated -- a permanent
-- registration would cost most users a cooldown read per GCD in service of a feature they
-- cannot even add. Login stays permanent: it is what discovers whether a helper exists.
--
-- ⚠ CHARGES FIRE THEIR OWN EVENT. A charge returning is a spell becoming usable again,
-- and SPELL_UPDATE_COOLDOWN does not fire for it -- so a charge-based gate spell would come
-- back ready with nothing to tell us. Power Infusion has no charges today; registered because
-- the capability underneath is not priest-specific and the failure would be silent. Danders'
-- own cooldown addon registers the pair for the same reason.
--
-- ⚠ UNIT_SPELLCAST_SUCCEEDED is filtered at the C level (RegisterUnitEvent): only the
-- player's own cast can shut the gate, and unfiltered this event is every cast by every
-- tracked unit -- party, raid, pets -- all discarded one line into the handler.
--
-- GROUP_ROSTER_UPDATE is for SOUND: registrations are per unit and are otherwise only made
-- on gate edges, so anyone who joined after the last edge got no cue -- and the player's own
-- no-register guard went stale when sorting moved them to another token.
local PIH_WATCH_EVENTS = { "SPELL_UPDATE_COOLDOWN", "SPELL_UPDATE_CHARGES",
                           "UNIT_SPELLCAST_SUCCEEDED", "GROUP_ROSTER_UPDATE" }
local pihWatching = false
pihSyncWatcher = function()
    local want = pihSettings() ~= nil
    -- The container's own backstop frame follows the same fact, from the same test -- one
    -- definition of "a helper exists" driving both registrations. Called unconditionally
    -- (it is idempotent) so it self-corrects even when our own state has not moved.
    if DF.AuraContainer and DF.AuraContainer.SetHelperGateActive then
        DF.AuraContainer.SetHelperGateActive(want)
    end
    if want == pihWatching then return end
    pihWatching = want
    for _, ev in ipairs(PIH_WATCH_EVENTS) do
        if not want then
            pihWatcher:UnregisterEvent(ev)
        elseif ev == "UNIT_SPELLCAST_SUCCEEDED" and pihWatcher.RegisterUnitEvent then
            pihWatcher:RegisterUnitEvent(ev, "player")
        else
            pihWatcher:RegisterEvent(ev)
        end
    end
end

local pihRosterPending = false
pihWatcher:SetScript("OnEvent", function(_, event, unit, _, spellID)
    if event == "GROUP_ROSTER_UPDATE" then
        -- Debounced: forming a group fires this in bursts, and one re-arm covers them all.
        -- Deliberately OUTSIDE the gate-enabled/manual guards below: gate off means the
        -- helper always shows, and its sound still has to reach a late joiner.
        if pihSoundCfg and not pihRosterPending and C_Timer and C_Timer.After then
            pihRosterPending = true
            C_Timer.After(0.5, function()
                pihRosterPending = false
                pihSoundsArmed(pihGateOpen)
            end)
        end
        return
    end
    if event ~= "PLAYER_ENTERING_WORLD" then
        if not pihGateEnabled then return end   -- switched off: nothing shuts or opens it
        if pihManual ~= nil then return end
    end

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
        -- ☠ RE-CHECK THE SWITCH AFTER APPLYING, because at login the file-locals
        -- still hold their initialisers until ApplySaved loads the saved values. Without
        -- this, a saved "don't hide" was overridden by the cooldown read below: reload
        -- mid-cooldown and the helper hid anyway -- the exact opposite of the setting --
        -- for the rest of that cooldown.
        if not pihGateEnabled or pihManual ~= nil then return end
        -- ☠ THE ONE PLACE isActive MAY SHUT THE GATE. On load we never saw the cast, so a
        -- reload mid-cooldown would otherwise leave the helper showing for the rest of it.
        -- Safe here specifically because nothing is being cast at this instant, so a true
        -- reading is a real cooldown rather than a GCD.
        local ready = pihReadReady()
        if ready ~= pihGateOpen then pihSet(not ready) end
        return
    end

    -- SPELL_UPDATE_COOLDOWN / SPELL_UPDATE_CHARGES: OPENING ONLY, still.
    -- ⚠ pihReadReady can now tell a real cooldown from a global one, so this COULD shut the gate
    -- as well. It deliberately does not. The cast event shuts on an unambiguous fact -- the
    -- player pressed it -- where shutting from here would mean trusting a flag read at whatever
    -- instant a chatty event happened to fire. One shut path, one open path, and the read that
    -- was wrong before is only used where a wrong answer cannot shut anything.
    -- ⚠ Cheapest test first: this branch only ever OPENS the gate, so with the gate
    -- already open there is nothing to do and no reason to pay for a cooldown read -- and
    -- this event fires on every global cooldown, all fight long.
    if pihGateOpen then return end
    local ready = pihReadReady()
    if not ready then return end
    local n = pihSet(false)
    DF:Debug("AURADESIGNER", "PIH gate -> OPEN, cooldown cleared (%d container%s)",
        n, n == 1 and "" or "s")
end)

-- === DIAGNOSTIC COMMAND ===
-- WHAT SURVIVED, AND WHY. This began as the feature's entire control surface -- twelve
-- subcommands driving a throwaway filter, a settable gate spell, role lists, sound and a
-- rebuild probe. Every one of those is either in the settings panel now or was scaffolding for
-- a feature that did not exist yet, so it went with the rest of the test rig.
--
-- Three states stayed, and they are not scaffolding: forcing the gate open or dark is the only
-- way to watch the helper's behaviour without sitting out a real Power Infusion cooldown -- and
-- Power Infusion needs a friendly target, so without this EVERY check of the gate would need a
-- second player in the group.
--
-- Registered through DF:RegisterDebugSlash rather than as a loose SLASH_ global, so it lists
-- itself in the debug registry beside every other diagnostic instead of being reachable only by
-- already knowing it exists.
--
-- THE COMMAND IS "/df debug pi". "/dfpi" below is the REGISTRY SPELLING, not a working bind:
-- RegisterDebugSlash routes a /df-prefixed alias to DebugSlashBySub and deliberately creates no
-- SLASH_ global, because the addon retired the one-word /dfsomething forms -- they filled the
-- global slash namespace to document a spelling nobody needed twice. Same shape as /dfarena and
-- /dfpinned. During development this WAS a bare /dfpi; anyone whose fingers remember that needs
-- the long form now.
DF:RegisterDebugSlash("DFPI", "Power Infusion Helper: \"all\" runs every diagnostic; off / on / auto force the gate", false, "/dfpi")
SlashCmdList["DFPI"] = function(msg)
    msg = (msg or ""):gsub("^%s+", ""):gsub("%s+$", ""):lower()

    if msg == "off" or msg == "dark" then
        pihManual = false
        DF:Out("PI Helper", "gate DARK (held by hand)")
            :Field("containers re-pushed", pihSet(true))
            :Line("watcher suspended -- \"/df debug pi auto\" hands it back", "neutral")
        return
    end

    if msg == "on" or msg == "open" then
        pihManual = true
        DF:Out("PI Helper", "gate OPEN (held by hand)")
            :Field("containers re-pushed", pihSet(false))
            :Line("watcher suspended -- \"/df debug pi auto\" hands it back", "neutral")
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
    -- ☠ THE FOCUS PROBE. Asks ONE question the code cannot answer from a desk: does
    -- "is this unit my focus" survive the 12.1 restrictions? A per-unit narrowing ("only watch
    -- my focus") would live at the same chokepoint role exclusion already uses, so the machinery
    -- is a day's work -- but ONLY if the read it rests on is legal inside an encounter. A
    -- competitor addon carries a fallback for the focus being partly unreadable, which is
    -- evidence the direct read is not simply fine.
    --
    -- ⚠ IT MUST BE ABLE TO SAY YES. A probe that can only report absence proves nothing:
    -- if every path returned "cannot tell", an unset focus and a sealed read would look
    -- identical. So it separates "no focus set" from "focus set and readable" from "focus set
    -- and SEALED", and names the token when it resolves -- that line is the pass.
    --
    -- ⚠ AND IT MUST NOT THROW. This is the diagnostic that runs in a raid, and a
    -- readout with a crashing state is the one mistake this feature has already made once.
    -- Every unit call is pcall'd and secret-checked BEFORE any boolean use of its result.
    if msg == "focus" then
        -- Returns a plain string, never a raw API value: "yes" / "no" / "SEALED" / "ERROR".
        local function isFocus(unit)
            local ok, same = pcall(UnitIsUnit, unit, "focus")
            if not ok then return "ERROR" end
            if issecretvalue and issecretvalue(same) then return "SEALED" end
            return same and "yes" or "no"
        end
        local function readable(fn, ...)
            local ok, v = pcall(fn, ...)
            if not ok then return nil, "ERROR" end
            if issecretvalue and issecretvalue(v) then return nil, "SEALED" end
            return v, nil
        end

        local out = DF:Out("PI Helper", "focus read probe")

        -- The restriction state is the whole point of WHEN you run this, so it is printed
        -- first and read defensively -- C_RestrictedActions may not exist on every build.
        local restr = pihRestrictions()
        out:Field("restrictions", #restr > 0 and table.concat(restr, ", ") or "NONE",
                  #restr > 0 and "good" or "warn")
        if #restr == 0 then
            out:Line("out of combat -- this run proves nothing. Re-run mid-pull.", "warn")
        end

        local exists = readable(UnitExists, "focus")
        if exists ~= true then
            out:Field("focus set", "no", "bad")
                :Line("Set a focus on a group member, then run this again.", "neutral")
                :Hints("/df debug pi focus")
            return
        end
        out:Field("focus set", "yes", "good")

        local fname, fnErr = readable(UnitName, "focus")
        out:Field("focus name", fnErr or tostring(fname), fnErr and "bad" or "good")
        local fguid, fgErr = readable(UnitGUID, "focus")
        out:Field("focus GUID", fgErr or (fguid and "readable" or "nil"),
                  fgErr and "bad" or (fguid and "good" or "warn"))

        -- The scan. Every group token, so the answer covers the units the helper actually marks
        -- rather than only the one the probe happens to sit on.
        local tokens = { "player" }
        local n = (IsInRaid and IsInRaid()) and 40 or 4
        local prefix = (IsInRaid and IsInRaid()) and "raid" or "party"
        for i = 1, n do tokens[#tokens+1] = prefix .. i end

        -- ☠ TWO READS, ONE RUN. Focus narrowing and a saved player list are the same
        -- feature to a user and DIFFERENT reads to us: focus is a token comparison, a list is a
        -- NAME. `UnitName` can return a secret value (FlatRaidFrames.lua:130), so the addon's
        -- own answer everywhere else is `GetUnitName(unit, true)` -- "Name-Realm", secret-safe,
        -- and already how Pinned Frames matches units against a saved set. Probing only the
        -- focus half would greenlight one feature and leave the other guessing.
        local matched, tested, sealed, errored = nil, 0, 0, 0
        local named, nameSealed, sampleName = 0, 0, nil
        for _, unit in ipairs(tokens) do
            if readable(UnitExists, unit) == true then
                tested = tested + 1
                local r = isFocus(unit)
                if r == "yes" then matched = unit
                elseif r == "SEALED" then sealed = sealed + 1
                elseif r == "ERROR" then errored = errored + 1 end

                local nm, nmErr = readable(GetUnitName, unit, true)
                if nmErr or type(nm) ~= "string" then nameSealed = nameSealed + 1
                else
                    named = named + 1
                    if not sampleName then sampleName = nm end
                end
            end
        end

        out:Field("group units tested", tested)
            :Field("focus: sealed reads", sealed, sealed > 0 and "bad" or "good")
            :Field("focus: errored reads", errored, errored > 0 and "bad" or "good")
            :Field("names read", ("%d of %d"):format(named, tested),
                   (tested > 0 and named == tested) and "good" or "bad")
            :Field("name sample", sampleName or "NONE", sampleName and "good" or "bad")

    -- ⚠ THESE LINES ARE THE VERDICT. Anything above them is context, and the two
        -- are reported SEPARATELY: one read can survive while the other does not, and collapsing
        -- them would hide which of the two features is dead.
        if matched then
            out:Field("focus resolves to", matched, "good")
                :Line("PASS (focus) -- \"only watch my focus\" is buildable.", "good")
        elseif sealed > 0 or errored > 0 then
            out:Line("FAIL (focus) -- the read is restricted here.", "bad")
        else
            out:Line("focus is not a group member -- nothing to match. Focus a party/raid member.", "warn")
        end

        if tested > 0 and named == tested then
            out:Line("PASS (names) -- a saved \"never watch\" list is buildable.", "good")
        else
            out:Line("FAIL (names) -- names are not readable here; a saved list is not buildable.", "bad")
        end
        return
    end

    -- ☠ EVERYTHING, IN ONE GO. Four diagnostics is three commands too many when the
    -- person running them is in a raid and screenshotting the results back.
    --
    -- Carries the three BUG-CHASING diagnostics only; see the note beside the calls.
    --
    -- ⚠ IT RE-ENTERS THIS DISPATCHER rather than holding its own copy of each block.
    -- A combined command that duplicated them would drift from the individual ones the first
    -- time either was edited, and then two commands would answer the same question differently
    -- -- which is the exact failure this feature already had once, with "does a helper exist".
    --
    -- ⚠ NOT FOLDED INTO THE BARE COMMAND, deliberately. The sound probe MUTATES: it
    -- registers a real sound and removes it again. A status readout people run casually must stay
    -- read-only, so the mutating one is opt-in and stays behind a word.
    if msg == "all" then
        local run = SlashCmdList and SlashCmdList["DFPI"]
        if not run then return end
        run("")        -- status: gate, sound wiring, containers
        run("border")  -- what the engine holds for the marks
        run("sound")   -- MUTATES; its result block lands last, on a timer
        -- ⚠ THE FOCUS PROBE IS NOT IN HERE. It answers a question about a FEATURE that is
        -- parked (per-player narrowing), not about any live defect -- and it needs a setup step
        -- of its own, a focused group member, which is a chore to ask of someone mid-raid who is
        -- chasing a bug. A combined command earns its place by removing work, so it carries only
        -- the diagnostics that share the same conditions. `/df debug pi focus` still runs alone.
        return
    end

    -- ☠ THE BORDER STORE DUMP. Field report 2026-09-09: the helper's border row reads
    -- Style: Solid, Border animation: none, and the ring MARCHES anyway. The panel and the store
    -- disagreeing is the shape of nearly every real defect this feature has had, so this prints
    -- what the ENGINE holds rather than what the panel draws.
    --
    -- ⚠ EFFECT VALUE **AND** GLOBAL DEFAULT, SIDE BY SIDE, because the suspected cause is
    -- the gap between them: an unset field falls through to `adDB.defaults`, so a control that
    -- writes nil for "none" is indistinguishable from one never touched -- and inherits. Printing
    -- only the effect's own value would show a tidy nil and explain nothing.
    if msg == "border" then
        local out = DF:Out("PI Helper", "border fields as stored")
        local mode = (DF.GetCurrentMode and DF:GetCurrentMode()) or "party"
        out:Field("reading preset for mode", mode)

        local adDB = DF.GetModeBaseAuraDesigner and DF:GetModeBaseAuraDesigner(mode)
        if type(adDB) ~= "table" then
            out:Line("no Aura Designer data for this mode.", "bad")
            return
        end
        local defs = type(adDB.defaults) == "table" and adDB.defaults or nil
        out:Field("global defaults table", defs and "present" or "absent", defs and "neutral" or "warn")

        -- Walk the pool for marked effects. Same derivation pihHasHelper uses, so this cannot
        -- disagree with "does a helper exist".
        local found = 0
        for auraName, auraCfg in pairs(adDB.otherAuras or {}) do
            if type(auraCfg) == "table" then
                for typeKey, v in pairs(auraCfg) do
                    if type(v) == "table" and v.pihSignal then
                        found = found + 1
                        out:Section(("%s  [%s]"):format(tostring(typeKey), tostring(v.pihSignal)))

                        -- Every Border* key present on the effect, plus the two that decide
                        -- whether a border renders at all.
                        local keys = {}
                        for k in pairs(v) do
                            if type(k) == "string" and k:sub(1, 6) == "Border" then keys[#keys+1] = k end
                        end
                        table.sort(keys)
                        out:Item("ShowBorder", tostring(v.ShowBorder))
                        out:Item("borderMode", tostring(v.borderMode))
                        if #keys == 0 then
                            out:Item("Border* fields", "NONE STORED -- every one inherits", "warn")
                        end
                        for _, k in ipairs(keys) do
                            out:Item(k, tostring(v[k]))
                        end

                        -- ⚠ THE ANIMATION KEYS SPECIFICALLY, whether stored or not, with
                        -- what the global layer would supply. A blank effect value beside a
                        -- non-NONE default IS the bug, printed rather than argued.
                        for _, k in ipairs({ "BorderAnimationType", "BorderAnimationThickness",
                                             "BorderStyle", "BorderTexture" }) do
                            local mine = v[k]
                            local glob = defs and defs[k]
                            local tone = nil
                            if mine == nil and glob ~= nil and glob ~= "NONE" then tone = "bad" end
                            out:Item(k, ("effect=%s   global=%s"):format(tostring(mine), tostring(glob)), tone)
                        end
                    end
                end
                -- Placed instances carry their own copies; a marching ring could be on one.
                for _, inst in ipairs(auraCfg.indicators or {}) do
                    if type(inst) == "table" and inst.pihSignal then
                        found = found + 1
                        out:Section(("placed %s  [%s]"):format(tostring(inst.type or "?"), tostring(inst.pihSignal)))
                        out:Item("BorderAnimationType", tostring(inst.BorderAnimationType))
                        out:Item("BorderStyle", tostring(inst.BorderStyle))
                        out:Item("anchor", tostring(inst.anchor))
                    end
                end
            end
        end

        -- Icon groups are a third store and render their border from the GROUP's style table,
        -- not the effect's -- so a marching ring here would come from somewhere else entirely.
        for _, g in ipairs(adDB.otherLayoutGroups or {}) do
            if type(g) == "table" and g.pihSignal then
                found = found + 1
                out:Section(("layout group  [%s]"):format(tostring(g.pihSignal)))
                out:Item("name", tostring(g.name))
                out:Item("BorderAnimationType", tostring(g.BorderAnimationType))
                out:Item("maxIcons / iconSize", ("%s / %s"):format(tostring(g.maxIcons), tostring(g.iconSize)))
                out:Item("othersOnly", tostring(g.othersOnly))
            end
        end

        -- ☠ ICONS ASKED FOR vs ICONS BUILT. Field report 2026-09-09: "I had icons checked
        -- but they never showed." The tick calls PIH_SetIconsShow and DISCARDS its return -- which
        -- carries the reason it refused ("layout groups unavailable", "could not create the group",
        -- "could not build the list"). So a failed build looks exactly like a working one. Until
        -- that caller is fixed, this is how you tell them apart: what the settings ASK for, beside
        -- whether a group actually exists in the preset you are standing in.
        -- ☠ THE FOUR TICKS ARE NOT STORED THE SAME WAY, and that asymmetry IS the
        -- suspected bug. `Cooldowns` is DERIVED -- PIH_IconsShow reads whether the icon group
        -- links that list, so if the group is missing the tick simply reads back unticked and
        -- nothing looks wrong. Trinkets / potions / racials are STORED FLAGS on the settings
        -- table, set before the group work is attempted. So a failed group build leaves those
        -- three reading TICKED with nothing on screen and no error -- which is exactly the
        -- report: "I had icons checked but they never showed."
        -- ⚠ THE MISMATCH IS THE FINDING. Stored flags on one line, what the group
        -- actually links on the next; agreement is healthy, disagreement names the defect.
        local st = pihSettings()
        out:Section("icons")
        if not st then
            out:Item("settings", "none found", "warn")
        else
            local flags = {}
            if st.trinkets then flags[#flags+1] = "trinkets" end
            if st.potions  then flags[#flags+1] = "potions"  end
            if st.racials  then flags[#flags+1] = "racials"  end
            out:Item("amplifier flags stored", #flags > 0 and table.concat(flags, ", ") or "none")

            local grp, linked = nil, 0
            for _, g in ipairs(adDB.otherLayoutGroups or {}) do
                if type(g) == "table" and g.pihSignal then grp = g break end
            end
            if not grp then
                out:Item("icon group", "DOES NOT EXIST in this preset", #flags > 0 and "bad" or "warn")
                if #flags > 0 then
                    out:Line("Flags are set but no group exists -- the build failed silently, or the", "bad")
                    out:Line("group lives in the other mode's preset. Either way nothing can render.", "bad")
                end
            else
                for _ in pairs((grp.filterSelection and grp.filterSelection.customs) or {}) do
                    linked = linked + 1
                end
                local cdLinked = st.cooldownFilterID and grp.filterSelection
                    and grp.filterSelection.customs
                    and grp.filterSelection.customs[st.cooldownFilterID] and true or false
                out:Item("icon group", "exists", "good")
                out:Item("lists linked to it", tostring(linked), linked == 0 and "bad" or nil)
                out:Item("cooldown list linked", tostring(cdLinked))
                out:Item("othersOnly", tostring(grp.othersOnly), grp.othersOnly and nil or "bad")
                out:Item("maxIcons / iconSize", ("%s / %s"):format(tostring(grp.maxIcons), tostring(grp.iconSize)))
                if linked == 0 then
                    out:Line("A group linking no lists renders nothing, whatever the ticks say.", "bad")
                end
            end
        end

        if found == 0 then
            out:Line(("No helper marks in the %s preset. If the helper shows in game, it lives in"):format(mode), "bad")
            out:Line("the OTHER mode's preset -- which is the party/raid scope gap, not a border bug.", "bad")
        end
        out:Hints("/df debug pi border")
        return
    end

    -- ☠ THE SOUND-API PROBE. Answers the question the 2026-09-09 field report opened:
    -- is `C_UnitAuras.AddAuraSound` / `RemoveAuraSound` blocked only by COMBAT LOCKDOWN, or for
    -- the whole restricted period (encounter / mythic+)? That decides what the helper's sound can
    -- honestly promise -- silence that follows the gate, or a cue that admits it ignores it.
    --
    -- ⚠ WHY A PROBE AND NOT A READ OF OUR OWN CODE: the failure is INVISIBLE to pcall.
    -- ADDON_ACTION_BLOCKED is not a Lua error -- the protected call simply does nothing and
    -- `pcall` returns success. That is precisely how this shipped: `unregisterAuraSound` pcalls
    -- and discards, so a blocked removal reported nothing at all. So this probe does NOT trust a
    -- return value alone; it listens for the blocked event itself.
    --
    -- ⚠ AND IT MUST NOT LEAK. It registers one real sound to test with, so if the REMOVE
    -- is the blocked half we are holding a live registration. The id is kept in a file-local and
    -- retried at the top of the next run rather than dropped -- which is the exact mistake being
    -- diagnosed. Registered against the player's own unit for Power Infusion, which cannot land
    -- on the priest casting it during the window, so nothing is audible either way.
    if msg == "sound" then
        local out = DF:Out("PI Helper", "sound API restriction probe")
        local UA = C_UnitAuras
        local add = UA and UA.AddAuraSound
        local rem = UA and (UA.RemoveAuraSound or UA.RemoveAuraAppliedSound)
        if type(add) ~= "function" or type(rem) ~= "function" then
            out:Line("sound API not present on this build -- nothing to measure.", "bad")
            return
        end

        -- Retry anything a previous run could not release, before adding another.
        if pihProbeLeakedID ~= nil then
            pcall(rem, pihProbeLeakedID)
            out:Field("retried leaked id from last run", tostring(pihProbeLeakedID), "warn")
            pihProbeLeakedID = nil
        end

        -- WHICH state are we in? Printed first: the answer is meaningless without it.
        local states = pihRestrictions()
        local where = #states > 0 and table.concat(states, "+") or "no restrictions"
        out:Field("restrictions", where, #states > 0 and "good" or "warn")
        if #states == 0 then
            out:Line("no restrictions active -- this run is the CONTROL: both calls must pass.", "neutral")
        end

        -- The blocked event is the only honest detector. Count only our own.
        local seen = 0
        local watcher = CreateFrame("Frame")
        watcher:RegisterEvent("ADDON_ACTION_BLOCKED")
        watcher:RegisterEvent("ADDON_ACTION_FORBIDDEN")
        watcher:SetScript("OnEvent", function(_, _, who)
            if who == "DandersFrames" then seen = seen + 1 end
        end)

        -- ☠ TWO ARGUMENT FORMS, NOT ONE. The first version of this probe passed a
        -- built-in soundFileID and PASSED in full combat -- while the real path was being BLOCKED
        -- in the same conditions. The probe was not reproducing the call it was meant to measure.
        -- resolveSoundArg turns a LibSharedMedia key into a FILE PATH string and passes
        -- `soundFileName`; playing an arbitrary file is a different privilege from playing a
        -- built-in asset, and that -- not combat -- is the suspected discriminator.
        -- ⚠ SO IT TESTS BOTH, AND USES THE USER'S OWN CONFIGURED SOUND for the path form.
        -- A probe that passes an argument the real code never uses answers a question nobody asked.
        local trig = Enum and Enum.UnitAuraSoundTrigger and Enum.UnitAuraSoundTrigger.Added
        local id, addErr
        local idB, addErrB, pathUsed

        local function try(argKey, argVal)
            if trig == nil then return nil, "this build's trigger enum has no 'Added'" end
            local snd = { unitToken = "player", spellID = PI_SPELL_ID, outputChannel = "Master" }
            snd[argKey] = argVal
            local ok, res = pcall(add, trig, snd)
            if ok then return res, nil end
            return nil, tostring(res)
        end

        -- Form A: a built-in asset, by id. The control.
        id, addErr = try("soundFileID", 567458)

        -- Form B: exactly what the helper registers -- the configured sound, as a path.
        pathUsed = pihSoundCfg and (DF.GetSoundPath and DF:GetSoundPath(pihSoundCfg.soundLSMKey))
            or (pihSoundCfg and pihSoundCfg.soundFile) or nil
        if type(pathUsed) == "string" and pathUsed ~= "" then
            idB, addErrB = try("soundFileName", pathUsed)
        elseif type(pathUsed) == "number" then
            idB, addErrB = try("soundFileID", pathUsed)
        else
            addErrB = "no sound configured -- pick one in the panel and re-run"
        end

        local removeTried = false
        if id  ~= nil then removeTried = true; pcall(rem, id)  end
        if idB ~= nil then removeTried = true; pcall(rem, idB) end

        -- The blocked event lands on the next dispatch, not inline, so the verdict waits.
        C_Timer.After(0.3, function()
            watcher:UnregisterAllEvents()
            watcher:SetScript("OnEvent", nil)

            local o2 = DF:Out("PI Helper", "sound API result")
            o2:Field("restrictions", where)
                :Field("A: built-in fileID",
                       addErr or (id ~= nil and ("id " .. tostring(id)) or "NIL"),
                       (id ~= nil) and "good" or "bad")
                :Field("B: your sound, as a path",
                       addErrB or (idB ~= nil and ("id " .. tostring(idB)) or "NIL"),
                       (idB ~= nil) and "good" or "bad")
                :Field("   path tried", tostring(pathUsed))
                :Field("RemoveAuraSound attempted", removeTried and "yes" or "no (nothing to remove)")
                :Field("blocked events seen", seen, seen > 0 and "bad" or "good")

            -- ⚠ THE COMPARISON IS THE POINT. One form working while the other does not
            -- localises the fault to the ARGUMENT rather than to combat, which is the difference
            -- between "sound cannot follow the gate" and "custom media files cannot be registered".
            if id ~= nil and idB == nil then
                o2:Line("A passed, B failed -- the FILE PATH is the problem, not combat.", "bad")
                o2:Line("A built-in sound would work where your media-pack file does not.", "warn")
            elseif id == nil and idB ~= nil then
                o2:Line("B passed, A failed -- unexpected; tell me, this inverts the theory.", "warn")
            end

            -- ⚠ THE VERDICT NAMES THE STATE. "Blocked" with no state attached is exactly
            -- the shape of the finding that misled us.
            if seen == 0 and id ~= nil and idB ~= nil then
                o2:Line(("PASS in [%s] -- both calls went through."):format(where), "good")
                if #states == 0 then
                    o2:Line("Control run only. Re-run in combat, then on a raid boss, then in a key.", "warn")
                end
            elseif seen > 0 then
                o2:Line(("BLOCKED in [%s] -- the sound API is protected here."):format(where), "bad")
            else
                o2:Line(("FAILED in [%s] with no block event -- the call was rejected, not restricted."):format(where), "warn")
            end

            -- If the REMOVE was the blocked half we are still holding it. Say so, and keep it.
            if seen > 0 and (id ~= nil or idB ~= nil) then
                pihProbeLeakedID = id or idB
                o2:Line("Holding the registration -- the next run retries releasing it.", "warn")
            end
            o2:Hints("/df debug pi sound")
        end)
        return
    end

    -- INTENT AND REALITY ARE PRINTED SEPARATELY, ON PURPOSE. Our variable records what the gate
    -- was last TOLD; the chokepoint records what containers are actually being handed. They are
    -- allowed to differ -- a rebuild restores the live map in config while the gate still reads
    -- "dark" -- and a readout that collapsed them into one line would hide exactly the
    -- disagreement it exists to show.
    local dark = false
    if DF.AuraContainer and DF.AuraContainer.GetHelperGate then
        dark = DF.AuraContainer.GetHelperGate()
    end
    local out = DF:Out("PI Helper", "status")
    out:Field("gate intends", pihGateOpen and "OPEN" or "DARK")
        :Field("chokepoint says", dark and "DARK" or "OPEN",
               dark == (not pihGateOpen) and "good" or "bad")
        :Field("gate enabled", tostring(pihGateEnabled))
        -- ⚠ THE SCOPE LINE. Marks follow the mode you are in; the BEHAVIOUR below (roles,
        -- the gate switch, the sound) is read from the first preset that has a helper, party first.
        -- When those two differ the helper is obeying settings from a preset that is not on screen,
        -- and that is a limitation of the read, not a fault in anything it reports.
        :Field("settings read from", (function()
            local here = (DF.GetCurrentMode and DF:GetCurrentMode()) or "?"
            pihSettings()   -- refresh pihSettingsMode; cheap, and never in a frame update
            if not pihSettingsMode then return ("no helper found (you are in %s)"):format(here) end
            if pihSettingsMode == here then return ("%s preset (matches where you are)"):format(here) end
            return ("%s preset -- BUT YOU ARE IN %s"):format(pihSettingsMode, here)
        end)(), (function()
            local here = (DF.GetCurrentMode and DF:GetCurrentMode()) or "?"
            if not pihSettingsMode then return "warn" end
            return (pihSettingsMode == here) and "good" or "bad"
        end)())
        :Field("gate spell", ("%d (%s)"):format(PI_SPELL_ID,
               tostring((C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(PI_SPELL_ID)) or "?")))
        :Field("gate spell ready", tostring(pihReadReady()))
        :Field("driven by", pihManual ~= nil and "HAND (watcher suspended)" or "watcher")
        :Field("sound", pihSoundCfg and (pihSoundCfg.soundLSMKey or "custom") or "silent (none chosen)")
        -- RESOLVE IT HERE. A LibSharedMedia pack may register a sound whose NAME contains an
        -- inline texture escape -- SharedMedia_Causese ships one carrying the Power Infusion
        -- icon. Picked from the dropdown it works perfectly: the key is stored verbatim and
        -- resolved to a file path long before anything reaches the sound API, so the escape
        -- never travels. Printing the resolved path is how you tell a bad choice from a silent
        -- one without playing it.
        :Field("sound resolves to", (function()
            if not pihSoundCfg then return "n/a" end
            local p = DF.GetSoundPath and DF:GetSoundPath(pihSoundCfg.soundLSMKey)
            return tostring(p or pihSoundCfg.soundFile or "NOTHING -- will not play")
        end)(), (function()
            if not pihSoundCfg then return "neutral" end
            local p = DF.GetSoundPath and DF:GetSoundPath(pihSoundCfg.soundLSMKey)
            return (p or pihSoundCfg.soundFile) and "good" or "bad"
        end)())
        :Field("roles excluded", (function()
            local r = DF.AuraContainer and DF.AuraContainer.GetHelperExcludedRoles
                and DF.AuraContainer.GetHelperExcludedRoles()
            if not r then return "nobody" end
            local t = {}; for k in pairs(r) do t[#t + 1] = k end; table.sort(t)
            return table.concat(t, ", ")
        end)())
        :Field("watching events", pihWatching and "yes" or "no (no helper installed)")
        -- The per-frame wiring, which no setting above can show. Registrations counted at the
        -- LAST arm pass (armed on zero frames = the login-ordering failure); containers
        -- counted LIVE off both registries.
        :Field("sound registrations", ("%d over %d frame%s%s"):format(
            pihLastArmCount, pihLastArmFrames, pihLastArmFrames == 1 and "" or "s",
            pihLastArmAt and (" (last armed " .. pihLastArmAt .. ")") or ""),
            -- ⚠ Only a fault WITH A GROUP: solo there is no unit to register on (we
            -- never register the player's own), so zero is the right answer and a red zero
            -- would teach the reader to ignore the line that matters.
            (pihSoundCfg and pihGateOpen and pihLastArmCount == 0
             and GetNumGroupMembers and GetNumGroupMembers() > 1) and "bad" or "neutral")
        -- ⚠ THE COOLDOWN LIST IS WHAT SOUND REGISTERS FROM. If this reads NIL, every
        -- frame will report "no spells after class narrowing" and the count above is zero for a
        -- reason that has nothing to do with sound at all.
        :Field("cooldown list resolves", (function()
            local m = pihResolvedMap()
            if not m then return "NIL -- nothing to register" end
            local c = 0
            for _ in pairs(m) do c = c + 1 end
            return ("%d spell%s"):format(c, c == 1 and "" or "s")
        end)(), pihResolvedMap() and "good" or "bad")
        :Field("gated containers live", (function()
            local AC = DF.AuraContainer
            local n = 0
            for h in pairs((AC and AC._handles) or {}) do
                if h.config and h.config.dfGate then n = n + 1 end
            end
            for h in pairs((AC and AC._slotHandles) or {}) do
                if h.config and h.config.dfGate then n = n + 1 end
            end
            return n
        end)())
    -- ☠ The chain is REASSEMBLED here on purpose: a conditional line built as
    -- `cond and text or nil` fed a nil straight into the printer's concatenation and the
    -- readout crashed in the field -- precisely when test mode was OFF, which no dev session
    -- ever ran it in. A diagnostic must not have a state in which it throws.
    local out2 = out
    if DF.testMode or DF.raidTestMode then
        -- applyGroupTuning refuses in test mode, so a gate edge redraws nothing there --
        -- indistinguishable from a broken gate unless the readout says so.
        out2 = out2:Line("test mode is ON: gate changes do not redraw test previews", "neutral")
    end
    -- ⚠ WHY THE LAST ARM PASS PRODUCED NOTHING, per distinct reason. Printed only when
    -- there is something to explain, so a healthy readout does not grow a section about a
    -- problem it does not have.
    if pihLastArmReasons then
        out2:Section("frames that registered nothing")
        for why, howMany in pairs(pihLastArmReasons) do
            out2:Item(("%d"):format(howMany), why, "warn")
        end
    end
    out2:Hints("/df debug pi all", "/df debug pi off", "/df debug pi on", "/df debug pi auto")
end
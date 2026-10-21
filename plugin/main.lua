-- Advanced Examine.
-- Adds "Advanced Examine" under the normal Examine option on NPCs, scenery and
-- ground items, and opens a window showing what the RuneScape Wiki data knows:
-- drops, where an item comes from, recipes and shops, each linked to the next.

local Lookup = require("lookup")
local Views = require("views")
local Window = require("window")

-- In dev, mirror console lines to devlink (an optional dependency) so they can
-- be read outside the client. In release builds devlink is absent and this is
-- plain print. The dependency is exposed under its plugin name; pcall guards a
-- sandbox that errors on undefined globals.
local _, devlinkLib = pcall(function() return devlink end)
local consolePrint = print
local function print(line)
    consolePrint(line)
    if devlinkLib and devlinkLib.log then pcall(devlinkLib.log, "advex", line) end
end

Window.setLogger(print)

local meta = Lookup.meta()
print(string.format("[AdvEx] data built %s: %d items, %d sources, %d drop rows (RuneScape Wiki, %s)",
    meta.built, meta.counts.items, meta.counts.sources, meta.counts.dropRows, meta.licence))

-- Menu subjects carry colour tags, e.g. "<col=ffff00>Goblin<col=00ff00> (level: 2)".
local function plainText(s)
    return (string.gsub(s or "", "<[^>]*>", ""))
end

-- Picks the view for what was examined.
local function viewFor(kind, id, gameName)
    if kind == "npc" then
        local source = Lookup.sourceByNpc(id)
        if source then
            -- Draw the exact NPC variant that was clicked, not the wiki's first id.
            local view = Views.source(source)
            view.model = { type = "npc", id = id }
            return view
        end
    elseif kind == "loc" then
        local source = Lookup.sourceByLoc(id)
        if source then return Views.source(source) end
    else
        local item, source = Lookup.itemByObj(id), Lookup.sourceByObj(id)
        if item and source then return Views.itemWithContents(item, source) end
        if item then return Views.item(item) end
        if source then return Views.source(source) end
    end
    return Views.missing(gameName, kind, id)
end

-- Opens the window; any error is printed rather than failing silently.
local function advancedExamine(kind, id, gameName)
    gameName = plainText(gameName)
    local ok, err = pcall(function()
        local view = viewFor(kind, id, gameName)
        print(string.format("[AdvEx] examine %s %s (%s) -> %s", kind, tostring(id), gameName, view.title))
        Window.show(view)
    end)
    if not ok then print("[AdvEx] ERROR: " .. tostring(err)) end
end

-- After each Examine entry, add ours. Only NPC, scenery and ground items for now;
-- inventory items arrive as interface entries and need separate handling.
local function onEntryAdded(event)
    local entry = event.entry
    if entry.actionVerbType ~= MiniMenuActionVerbType.EXAMINE then return end
    local kind, id
    if entry.npcData then
        kind, id = "npc", entry.npcData.entity.config.id
    elseif entry.locData then
        kind, id = "loc", entry.locData.config.id
    elseif entry.objData then
        kind, id = "obj", entry.objData.config.id
    else
        return
    end
    event.miniMenu:Add("Advanced Examine", advancedExamine, kind, id, entry.subjectText)
end

Event.MiniMenuEntryAdded.Subscribe("advancedExamine", function(event)
    local ok, err = pcall(onEntryAdded, event)
    if not ok then print("[AdvEx] menu ERROR: " .. tostring(err)) end
end)

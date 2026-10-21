"""Drive the Advanced Examine window against a stand-in UI in Lua 5.4.

The stand-in records every component and its properties, so the test can read
what the window would show and fire its button/click hooks. It cannot check how
the real client draws it (fonts, sizes, styles) — that needs the beta client.

Needs lupa. Run: python test_window.py
"""

import sys
from pathlib import Path

import lupa.lua54 as lupa

PLUGIN = Path(__file__).resolve().parent / "plugin"

STUBS = r"""
-- Stand-in UI: components are tables that remember properties and hooks.
local all = {}
local function newComponent(kind, parent)
    local c = { kind = kind, parent = parent, hooks = {}, hidden = false }
    function c:SetPos(...) self.pos = { ... } end
    function c:SetSize(...) self.size = { ... } end
    function c:SetHeaderLayout(...) end
    function c:Subscribe(hook, fn) self.hooks[hook] = fn end
    all[#all + 1] = c
    return c
end
ui = {
    AlignMode = { TOPLEFT = 0, CENTRE = 1, BOTTOMRIGHT = 2 },
    Hook = { ONCLICK = 0, ONBUTTONPRESSED = 49, ONDRAG = 7, ONDRAGCOMPLETE = 8 },
    Interfaces = { GetComponent = function()
        local l = newComponent("layer"); l.width, l.height = 1278, 1360; return l end },
}
for _, kind in ipairs({ "GroupBox", "Text", "Button" }) do
    ui[kind] = { new = function(parent) return newComponent(kind, parent) end }
end
id = { Font = setmetatable({}, { __index = function(_, k) return k end }),
       StyleSheet = setmetatable({}, { __index = function(_, k) return k end }),
       Component = { TOPLEVEL_V2__PLUGIN_BUILD_LAYER_TOP = 1 } }
MiniMenuActionVerbType = { EXAMINE = 1 }
local store = {}
PersistentDB = {
    GetInt = function(_, k) return store[k] end,
    SetInt = function(_, k, v) store[k] = v; return true end,
}
function stored(k) return store[k] end
local subs = {}
Event = { MiniMenuEntryAdded = { Subscribe = function(name, fn) subs.menu = fn end } }

-- Helpers for the test driver.
function examine(kind, id, name)
    local added = {}
    local entry = { actionVerbType = 1, subjectText = name }
    if kind == "npc" then entry.npcData = { entity = { config = { id = id } } }
    elseif kind == "loc" then entry.locData = { config = { id = id } }
    else entry.objData = { config = { id = id } } end
    subs.menu({ entry = entry, miniMenu = { Add = function(_, label, fn, ...) added[#added + 1] = { fn, table.pack(...) } end } })
    local a = added[1]
    a[1](table.unpack(a[2], 1, a[2].n))
end
-- Visible texts in creation order (what a player would read).
function visibleTexts()
    local out = {}
    for _, c in ipairs(all) do
        if c.kind == "Text" and not c.hidden and c.content and c.content ~= "" then out[#out + 1] = c.content end
    end
    return out
end
function findButton(label)
    for _, c in ipairs(all) do
        if c.kind == "Button" and not c.hidden and c.label and string.find(c.label, label, 1, true) == 1 then return c end
    end
end
function press(label) local b = findButton(label); assert(b, "no visible button " .. label); b.hooks[49]() end
function clickRow(name)
    for _, c in ipairs(all) do
        if c.kind == "Text" and not c.hidden and c.content == name and c.hooks[0] then c.hooks[0](); return end
    end
    error("no clickable row " .. name)
end
function theBox() for _, c in ipairs(all) do if c.kind == "GroupBox" then return c end end end
function boxHidden() for _, c in ipairs(all) do if c.kind == "GroupBox" then return c.hidden end end end
function componentCount() return #all end
"""

lua = lupa.LuaRuntime(unpack_returned_tuples=True)
lua.execute(f'package.path = "{PLUGIN.as_posix()}/?.lua"')
lua.execute(STUBS)
lua.execute(f'dofile("{PLUGIN.as_posix()}/main.lua")')
g = lua.globals()

failures = []


def check(label, ok, detail=""):
    print(("PASS " if ok else "FAIL ") + label + (f"  ({detail})" if detail else ""))
    if not ok:
        failures.append(label)


def texts():
    t = g.visibleTexts()
    return [t[i] for i in range(1, len(t) + 1)]


# 1. Examine a Lumbridge goblin.
g.examine("npc", 11240, "<col=ffff00>Goblin<col=00ff00> (level: 2)")
shown = texts()
check("title is the wiki page", "Goblin (Lumbridge)" in shown, shown[0])
check("subtitle counts drops", "42 drops" in shown)
check("first drop row is Bones", "Bones" in shown)
check("tab label has count", g.findButton("Drops (42)") is not None)
check("page 1 of 3", "Page 1 / 3" in shown)
check("Back hidden on a fresh examine", g.findButton("<") is None)
count_after_build = g.componentCount()

# 2. Paging.
g.press("Next")
check("Next goes to page 2", "Page 2 / 3" in texts())
g.press("Prev")
check("Prev back to page 1", "Page 1 / 3" in texts())

# 3. Click a drop to open that item, then its tabs.
g.clickRow("Bones")
shown = texts()
check("clicking Bones opens the item", shown[0] == "Bones", shown[0])
check("item has a Sources tab", g.findButton("Sources (") is not None)
check("Back visible after navigating", g.findButton("<") is not None)
g.press("Used in")
check("Used in tab shows a recipe heading", any(s.startswith("Recipe 1:") for s in texts()),
      next((s for s in texts() if s.startswith("Recipe")), "none"))
g.press("<")
check("Back returns to the goblin", texts()[0] == "Goblin (Lumbridge)")

# 4. A ground item that the wiki also lists as a drop source, and an unknown id.
g.examine("obj", 536, "Dragon bones")
shown = texts()
check("obj 536 opens Dragon bones", shown[0] == "Dragon bones")
g.press("Shops")
check("Shops tab renders", True, f"{len(texts())} visible texts")
g.examine("npc", 999999, "Mystery")
check("unknown id shows the missing view", "No RuneScape Wiki data for this id." in texts())

# 5. Size button cycles M -> L -> S and resizes; settings are saved.
box = g.theBox()
g.press("M")
check("size button goes to Large", g.findButton("L") is not None and box.size[1] == 540, f"width {box.size[1]}")
g.examine("npc", 11240, "Goblin")
check("Large shows 24 rows per page", "Page 1 / 2" in texts(), next(s for s in texts() if s.startswith("Page")))
g.press("L")
check("then Small", box.size[1] == 420 and g.findButton("S") is not None)
check("size saved", g.stored("windowSize") == 1)

# 6. Dragging moves the window by the drag offset and saves the position.
box.hooks[7](box, 100, 200)
box.hooks[8](box, None, 160, 230)
check("drag moves window", list(box.pos.values())[:2] == [80, 150], str(list(box.pos.values())))
check("position saved", g.stored("windowX") == 80 and g.stored("windowY") == 150)
box.hooks[7](box, 0, 0)
box.hooks[8](box, None, -5000, -5000)
check("drag is clamped on screen", list(box.pos.values())[:2] == [0, 0], str(list(box.pos.values())))

# 7. Reuse and close.
check("components are reused, not rebuilt", g.componentCount() == count_after_build,
      f"{count_after_build} -> {g.componentCount()}")
g.press("X")
check("X hides the window", g.boxHidden() is True)

print(f"{len(failures)} failure(s)")
sys.exit(1 if failures else 0)

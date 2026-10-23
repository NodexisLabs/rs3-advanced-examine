-- The Advanced Examine window, driven through the right-click menu.
-- Port of test_window.py onto the RS3 plugin test kit:
--   rs3test run plugins/advanced-examine spec/advanced-examine
--
-- The kit stands in for the client: it checks every API call against the
-- documented signatures and records what each component shows. How the
-- client draws it (fonts, sizes, styles) still needs the beta client.

-- NPC configs the window reads (config.NPC.FromID(id).gridSize scales the model camera).
kit.config.npc(11240, { name = "Goblin", gridSize = 1 })
kit.config.npc(999999, { name = "Mystery", gridSize = 1 })

kit.start()

-- Right-click something and choose Advanced Examine.
local function examine(spec)
    spec.verb = "Examine"
    kit.menu.open({ kit.menu.entry(spec) }):select("Advanced Examine")
end

local function theBox() return kit.ui.find(function(_, kind) return kind == "ui.GroupBox" end) end
local function theModel() return kit.ui.find(function(_, kind) return kind == "ui.Model" end) end

-- The header's big icon: the first Sprite, created right after the Model.
local function bigIcon()
    local all = kit.ui.all()
    for i, c in ipairs(all) do
        if kit.ui.kind(c) == "ui.Model" then return all[i + 1] end
    end
end

-- obj id drawn by the icon on the same row as the visible text `name`, or nil.
local function iconFor(name)
    local all = kit.ui.all()
    for i, c in ipairs(all) do
        if kit.ui.kind(c) == "ui.Text" and kit.ui.isShown(c) and c.content == name then
            local s = all[i - 1]
            if s and kit.ui.kind(s) == "ui.Sprite" and kit.ui.isShown(s) then return s.associatedObjectID end
            return nil
        end
    end
end

local function pageLine()
    for _, s in ipairs(kit.ui.texts()) do
        if string.sub(s, 1, 4) == "Page" then return s end
    end
end

local goblin = kit.world.addNpc({ id = 11240, coord = { x = 3246, z = 3272 } })
local countAfterBuild

test("examining a Lumbridge goblin shows its wiki page", function()
    examine({ npc = goblin, subject = "<col=ffff00>Goblin<col=00ff00> (level: 2)" })
    local shown = kit.ui.texts()
    expect(shown).toContain("Goblin (Lumbridge)")
    expect(shown).toContain("42 drops")
    expect(shown).toContain("Bones")
    expect(kit.ui.button("Drops (42)")).toBeTruthy()
    expect(shown).toContain("Page 1 / 3")
    expect(kit.ui.button("Back")).toBeNil()
end)

test("the header shows the clicked NPC's model, scaled by its grid size", function()
    local model = theModel()
    expect(model.modelType).toBe(ui.ModelType.NPC_MODEL)
    expect(model.modelID1).toBe(11240)
    expect(model.hidden).toBe(false)
    expect(model.viewDistance).toBe(850)      -- goblin: 1 tile -> 850
    expect(iconFor("Bones")).toBe(526)        -- Bones row has the Bones icon
    countAfterBuild = kit.ui.count()
end)

test("Next and Prev page through the drops", function()
    kit.ui.press("Next")
    expect(kit.ui.texts()).toContain("Page 2 / 3")
    kit.ui.press("Prev")
    expect(kit.ui.texts()).toContain("Page 1 / 3")
end)

test("clicking a drop opens that item", function()
    kit.ui.click("Bones")
    expect(kit.ui.texts()[1]).toBe("Bones")
    local big = bigIcon()
    expect(big.associatedObjectID).toBe(526)
    expect(big.hidden).toBe(false)
    expect(theModel().hidden).toBe(true)
    expect(iconFor("Goblin (Lumbridge)")).toBeNil()   -- monster rows have no icon
    expect(kit.ui.button("Sources (", true)).toBeTruthy()
    expect(kit.ui.button("Back")).toBeTruthy()
end)

test("the Used in tab lists recipes, and Back returns to the goblin", function()
    kit.ui.press("Used in")
    local heading
    for _, s in ipairs(kit.ui.texts()) do
        if string.sub(s, 1, 9) == "Recipe 1:" then heading = s end
    end
    expect(heading).toBeTruthy()
    kit.ui.press("Back")
    expect(kit.ui.texts()[1]).toBe("Goblin (Lumbridge)")
end)

test("a ground item the wiki also lists as a source opens", function()
    examine({ obj = 536, name = "Dragon bones" })
    expect(kit.ui.texts()[1]).toBe("Dragon bones")
    kit.ui.press("Shops")
end)

test("an id with no wiki data shows the missing view", function()
    examine({ npc = 999999, name = "Mystery" })
    expect(kit.ui.texts()).toContain("No RuneScape Wiki data for this id.")
end)

test("the size button cycles M -> L -> S and is saved", function()
    local box = theBox()
    kit.ui.press("M")
    expect(kit.ui.button("L")).toBeTruthy()
    expect(box.width).toBe(540)
    examine({ npc = goblin, subject = "Goblin" })
    expect(pageLine()).toBe("Page 1 / 2")              -- Large shows 24 rows per page
    kit.ui.press("L")
    expect(box.width).toBe(420)
    expect(kit.ui.button("S")).toBeTruthy()
    expect(kit.db.get("windowSize")).toBe(1)
end)

-- Drags with a real mouse: the live client sends no drag events, so the
-- window polls its header grip and the Mouse every logic tick.
local function dragBy(dx, dy)
    local box = theBox()
    local x, y = box.x + 150, box.y + 20        -- on the title, left of the buttons
    kit.pointer.press(x, y)
    kit.tick()
    kit.pointer.move(x + dx, y + dy)
    kit.tick()
    return kit.pointer.release()
end

test("dragging the header moves the window, saves the position, and stays on screen", function()
    local box = theBox()
    expect({ box.x, box.y }).toEqual({ 20, 120 })
    local r = dragBy(60, 30)
    expect(r.released).toBe(true)
    kit.tick()
    expect({ box.x, box.y }).toEqual({ 80, 150 })
    expect(kit.db.get("windowX")).toBe(80)
    expect(kit.db.get("windowY")).toBe(150)
    dragBy(-225, -165)                          -- cursor to (5, 5): past the corner, clamped
    kit.tick()
    expect({ box.x, box.y }).toEqual({ 0, 0 })
end)

test("a fast move far off the header keeps the drag", function()
    local box = theBox()
    local r = dragBy(500, 400)                  -- one tick, well outside the old header
    expect(r.released).toBe(true)
    kit.tick()
    expect({ box.x, box.y }).toEqual({ 500, 400 })
end)

test("clicking a header button does not move the window", function()
    local box = theBox()
    local before = { box.x, box.y }
    local size = kit.ui.button("S")
    kit.pointer.press(box.x + size.x + 10, box.y + size.y + 10)
    kit.tick()
    kit.pointer.move(box.x + size.x + 40, box.y + size.y + 30)
    kit.tick()
    kit.pointer.release()
    kit.tick()
    expect({ box.x, box.y }).toEqual(before)
end)

test("another Lumbridge goblin variant (NPC 12353, seen live) opens the same page", function()
    kit.config.npc(12353, { name = "Goblin", gridSize = 1 })
    local variant = kit.world.addNpc({ id = 12353, coord = { x = 3248, z = 3270 } })
    examine({ npc = variant, subject = "<col=ffff00>Goblin<col=00ff00> (level: 2)" })
    expect(kit.ui.texts()).toContain("Goblin (Lumbridge)")
    expect(theModel().modelID1).toBe(12353)
end)

test("components are reused, not rebuilt, and X hides the window", function()
    expect(kit.ui.count()).toBe(countAfterBuild)
    kit.ui.press("X")
    expect(theBox().hidden).toBe(true)
    expect(kit.ui.texts()).toEqual({})
end)

test("no errors were printed and every click stayed out of the game world", function()
    kit.console.expectNo("ERROR")
    kit.console.expectNo("failed")
    for _, w in ipairs(kit.warnings()) do
        expect(w.code).notToContain("clickthrough")
    end
end)

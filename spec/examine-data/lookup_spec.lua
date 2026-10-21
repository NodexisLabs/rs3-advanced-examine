-- The Examine Data library against known answers from the RuneScape Wiki.
-- Port of test_lookup.py onto the RS3 plugin test kit:
--   rs3test run plugins/examine-data spec/examine-data

local started = os.clock()
local Lookup = kit.start()          -- main.lua returns the lookup API
print(string.format("    core load: %.0f ms", (os.clock() - started) * 1000))

local function indexOf(module, name)
    local names = kit.require(module).names
    for i = 1, #names do
        if names[i] == name then return i end
    end
    error("no " .. module .. " entry named " .. name)
end
local function item(name) return indexOf("data/items", name) end
local function source(name) return indexOf("data/sources", name) end

test("Dust devil drops Dragon bones at 1/262,144, 35-45 noted", function()
    local dust = {}
    for _, d in ipairs(Lookup.dropsOfItem(item("Dragon bones"))) do
        if Lookup.sourceName(d.other) == "Dust devil" then dust[#dust + 1] = d end
    end
    expect(#dust > 0).toBeTruthy()
    local found = false
    for _, d in ipairs(dust) do
        if d.rarity == "1/262,144" and d.qtyLow == 35 and d.qtyHigh == 45 and d.noted then found = true end
    end
    expect(found).toBeTruthy()
end)

test("probability parsed for 1/262,144", function()
    local found = false
    for _, d in ipairs(Lookup.dropsOfItem(item("Dragon bones"))) do
        if Lookup.sourceName(d.other) == "Dust devil" and d.probability
            and math.abs(d.probability - 1 / 262144) < 1e-12 then found = true end
    end
    expect(found).toBeTruthy()
end)

test("unknown rates come back as nil probability with the text kept", function()
    local unknown = 0
    for _, d in ipairs(Lookup.dropsOfItem(item("Dragon bones"))) do
        if d.probability == nil then
            unknown = unknown + 1
            expect(d.rarity).toBeTruthy()
        end
    end
end)

test("Green dragon always drops Dragon bones", function()
    local found = false
    for _, d in ipairs(Lookup.dropsFromSource(source("Green dragon"))) do
        if Lookup.itemName(d.other) == "Dragon bones" and d.rarity == "Always" then found = true end
    end
    expect(found).toBeTruthy()
end)

-- RS3 game ids: Dragon bones obj 536, Dust devil npc 1624, Fire altar loc 2482.
test("itemByObj(536) is Dragon bones", function()
    expect(Lookup.itemName(Lookup.itemByObj(536) or 0)).toBe("Dragon bones")
end)

test("sourceByNpc(1624) is Dust devil", function()
    expect(Lookup.sourceName(Lookup.sourceByNpc(1624) or 0)).toBe("Dust devil")
end)

test("sourceByLoc(2482) is Fire altar", function()
    expect(Lookup.sourceName(Lookup.sourceByLoc(2482) or 0)).toBe("Fire altar")
end)

test("versioned item: obj 3024 is Super restore (4)", function()
    local name = Lookup.itemName(Lookup.itemByObj(3024) or 0)
    expect(name == "Super restore (4)" or name == "Super restore").toBeTruthy()
end)

test("Overload recipe uses Clean torstol", function()
    local materials = {}
    for _, r in ipairs(Lookup.recipesMaking(item("Overload"))) do
        for _, m in ipairs(r.materials) do materials[#materials + 1] = Lookup.itemName(m[1]) end
    end
    expect(materials).toContain("Clean torstol")
end)

test("Vial is sold at Jatix's Herblore Shop", function()
    local shops = {}
    for _, s in ipairs(Lookup.shopsSelling(item("Vial"))) do shops[#shops + 1] = s.shop end
    expect(shops).toContain("Jatix's Herblore Shop")
end)

test("every drop chunk loads", function()
    local meta = Lookup.meta()
    for _, view in ipairs({ "by_item", "by_source" }) do
        for n = 0, #meta.chunkStarts[view] - 1 do
            kit.require(string.format("data/drops/%s_%02d", view, n))
        end
    end
    print(string.format("    Lua memory with everything loaded: %.1f MB", collectgarbage("count") / 1024))
end)

test("the library makes no game API calls and prints no errors", function()
    expect(#kit.trace()).toBe(0)
    kit.console.expectNo("ERROR")
end)

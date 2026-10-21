-- Builds what the Advanced Examine window shows, without touching any UI.
--
-- A view is:
--   { title, subtitle, model = { type = "npc"|"obj", id } | nil,
--     tabs = { { name, columns, rows = { row, ... } }, ... } }
-- where columns are the four headings; omitted means DROP_COLUMNS.
-- and a row is:
--   { name, qty, rate, per, colour, link = { kind = "item"|"source", index } | nil,
--     icon = game obj id to draw | nil, iconQty,
--     header = true when the row is a section heading }
-- Icons and models are drawn by the game from its own assets; the view only
-- supplies game ids.
-- Keeping this separate from the window lets it be tested outside the game.

local Lookup = require("lookup")

local Views = {}

-- Row colours (RGBA).
local WHITE = 0xFFFFFFFF
local GREY = 0xA0A0A0FF     -- rate unknown: the wiki gives only a word
local AMBER = 0xFFCC66FF    -- the wiki marks the rate as approximate
local GOLD = 0xFF981FFF     -- section headings

Views.DROP_COLUMNS = { "Name", "Qty", "Rate", "Per kill" }
local RECIPE_COLUMNS = { "Item", "Qty", "", "" }
local SHOP_COLUMNS = { "Shop", "Stock", "Price", "Currency" }

local function quantityText(drop)
    if drop.qtyLow == nil then return "?" end
    local text = tostring(drop.qtyLow)
    if drop.qtyHigh and drop.qtyHigh ~= drop.qtyLow then
        text = text .. "-" .. tostring(drop.qtyHigh)
    end
    if drop.noted then text = text .. " (n)" end
    return text
end

-- Expected amount per kill, or "" when the wiki gives no numeric rate.
local function perKillText(drop)
    local perAction = Lookup.expectedPerAction(drop)
    if perAction == nil then return "" end
    return string.format("%.3g", perAction)
end

local function rowColour(drop)
    if drop.probability == nil then return GREY end
    if drop.approximate then return AMBER end
    return WHITE
end

-- Highest known chance first; rows whose rate is only a word go last.
local function byProbability(a, b)
    return (a.probability or -1) > (b.probability or -1)
end

local function dropRows(drops, linkKind, nameOf)
    table.sort(drops, byProbability)
    local rows = {}
    for _, drop in ipairs(drops) do
        rows[#rows + 1] = {
            -- Item rows get the item's icon; source rows (monsters) have none.
            icon = linkKind == "item" and Lookup.objIdOfItem(drop.other) or nil,
            iconQty = drop.qtyLow,
            name = nameOf(drop.other) or "?",
            qty = quantityText(drop),
            rate = drop.rarity,
            per = perKillText(drop),
            colour = rowColour(drop),
            link = { kind = linkKind, index = drop.other },
        }
    end
    return rows
end

local function itemLink(item)
    return { kind = "item", index = item }
end

-- One heading per recipe, then one row per material (or output), each linked.
local function recipeRows(recipes, listKey)
    local rows = {}
    for n, recipe in ipairs(recipes) do
        local skills = {}
        for _, s in ipairs(recipe.skills or {}) do
            skills[#skills + 1] = string.format("%s %s", tostring(s[1]), tostring(s[2] or "?"))
        end
        rows[#rows + 1] = { header = true, colour = GOLD,
            name = string.format("Recipe %d: %s", n, #skills > 0 and table.concat(skills, ", ") or "no skill"),
            qty = "", rate = recipe.members and "members" or "", per = "" }
        for _, entry in ipairs(recipe[listKey] or {}) do
            rows[#rows + 1] = { name = Lookup.itemName(entry[1]) or "?",
                icon = Lookup.objIdOfItem(entry[1]), iconQty = entry[2],
                qty = entry[2] and tostring(entry[2]) or "?", rate = "", per = "",
                colour = WHITE, link = itemLink(entry[1]) }
        end
    end
    return rows
end

local function shopRows(item)
    local rows = {}
    for _, s in ipairs(Lookup.shopsSelling(item)) do
        rows[#rows + 1] = { name = s.shop or "?",
            qty = s.stock == "infinite" and "inf" or tostring(s.stock or "?"),
            rate = tostring(s.price or "?"), per = tostring(s.currency or ""),
            colour = WHITE }
    end
    return rows
end

---------------------------------------------------------------------------
-- Public
---------------------------------------------------------------------------
function Views.source(source)
    local drops = Lookup.dropsFromSource(source)
    local npcId, objId = Lookup.npcIdOfSource(source), Lookup.objIdOfSource(source)
    return {
        title = Lookup.sourceName(source) or "?",
        model = (npcId and { type = "npc", id = npcId }) or (objId and { type = "obj", id = objId }) or nil,
        subtitle = string.format("%d drops", #drops),
        tabs = { { name = "Drops", rows = dropRows(drops, "item", Lookup.itemName) } },
    }
end

function Views.item(item)
    local sources = Lookup.dropsOfItem(item)
    local making, using = Lookup.recipesMaking(item), Lookup.recipesUsing(item)
    local shops = shopRows(item)
    local objId = Lookup.objIdOfItem(item)
    return {
        title = Lookup.itemName(item) or "?",
        model = objId and { type = "obj", id = objId } or nil,
        subtitle = string.format("%d sources, %d recipes, used in %d, %d shops",
            #sources, #making, #using, #shops),
        tabs = {
            { name = "Sources", rows = dropRows(sources, "source", Lookup.sourceName) },
            { name = "Made by", columns = RECIPE_COLUMNS, rows = recipeRows(making, "materials") },
            { name = "Used in", columns = RECIPE_COLUMNS, rows = recipeRows(using, "outputs") },
            { name = "Shops", columns = SHOP_COLUMNS, rows = shops },
        },
    }
end

-- Items that are also sources (caskets, crackers) get a "Contains" tab.
function Views.itemWithContents(item, source)
    local view = Views.item(item)
    local contents = Views.source(source).tabs[1]
    contents.name = "Contains"
    table.insert(view.tabs, 1, contents)
    return view
end

-- Shown when the wiki data has nothing for what was examined.
function Views.missing(gameName, kind, id)
    return {
        title = gameName or "?",
        subtitle = string.format("%s %s", kind, tostring(id)),
        tabs = { { name = "Info", rows = {
            { name = "No RuneScape Wiki data for this id.", qty = "", rate = "", colour = GREY },
            { name = "It may be missing a game id on the wiki.", qty = "", rate = "", colour = GREY },
        } } },
    }
end

function Views.forLink(link)
    if link.kind == "item" then return Views.item(link.index) end
    return Views.source(link.index)
end

return Views

-- Examine Data lookup: answers "where does this come from / what does it drop"
-- from the generated tables in data/. Drop chunks load on first use only.
--
-- Every drop returned by this module carries the wiki's rarity text. When that
-- text is a rate ("1/128", "Always") it also carries a probability; when the
-- wiki only says "Rare" or "Varies", probability is nil and callers must show
-- the text instead of inventing a number.

local meta = require("data/meta")
local items = require("data/items")
local sources = require("data/sources")
local rarities = require("data/rarities")

local Lookup = {}

local FLAG_APPROX, FLAG_NOTED, FLAG_RARE_TABLE = 1, 2, 4

---------------------------------------------------------------------------
-- Rarity text -> probability, parsed once per distinct text
---------------------------------------------------------------------------
local probabilityCache = {}

-- "1/128" -> 0.0078125, "1/1,000" -> 0.001, "Always" -> 1, other text -> nil
local function parseProbability(text)
    if string.lower(text) == "always" then return 1 end
    local num, den = string.match(text, "^~?%s*([%d.,]+)%s*/%s*([%d.,]+)$")
    if not num then return nil end
    num = tonumber((string.gsub(num, ",", "")))
    den = tonumber((string.gsub(den, ",", "")))
    if not num or not den or den == 0 then return nil end
    return num / den
end

local function probabilityOf(rarityIndex)
    local cached = probabilityCache[rarityIndex]
    if cached == nil then
        cached = parseProbability(rarities[rarityIndex]) or false
        probabilityCache[rarityIndex] = cached
    end
    return cached or nil
end

---------------------------------------------------------------------------
-- Lazy chunk loading
---------------------------------------------------------------------------
-- Finds the chunk holding index i: the last chunk whose start is <= i.
local function chunkNumber(starts, i)
    local low, high = 1, #starts
    while low < high do
        local mid = (low + high + 1) // 2
        if starts[mid] <= i then low = mid else high = mid - 1 end
    end
    return low - 1
end

local function rowsFor(view, index)
    local starts = meta.chunkStarts[view]
    if index == nil or #starts == 0 or index < starts[1] then return {} end
    local chunk = require(string.format("data/drops/%s_%02d", view, chunkNumber(starts, index)))
    return chunk[index] or {}
end

-- Turns a packed row into a readable table. `other` is the source index for
-- item views and the item index for source views.
local function unpackRow(row)
    local flags = row[5] or 0
    return {
        other = row[1],
        rarity = rarities[row[2]],
        probability = probabilityOf(row[2]),
        qtyLow = row[3],
        qtyHigh = row[4],
        approximate = flags & FLAG_APPROX ~= 0,
        noted = flags & FLAG_NOTED ~= 0,
        rareDropTable = flags & FLAG_RARE_TABLE ~= 0,
        rolls = row[6] or 1,
    }
end

local function unpackRows(rows)
    local result = {}
    for i, row in ipairs(rows) do result[i] = unpackRow(row) end
    return result
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------
function Lookup.itemName(item) return items.names[item] end
function Lookup.sourceName(source) return sources.names[source] end

-- Game config id -> data index. nil means the wiki has no entry for that id.
function Lookup.itemByObj(objId) return items.byObj[objId] end
function Lookup.sourceByNpc(npcId) return sources.byNpc[npcId] end
function Lookup.sourceByLoc(locId) return sources.byLoc[locId] end
function Lookup.sourceByObj(objId) return sources.byObj[objId] end

-- Where an item drops from: list of drops, `other` = source index.
function Lookup.dropsOfItem(item) return unpackRows(rowsFor("by_item", item)) end

-- What a source drops: list of drops, `other` = item index.
function Lookup.dropsFromSource(source) return unpackRows(rowsFor("by_source", source)) end

-- Expected number of the item per kill/open, or nil when the rate is unknown.
function Lookup.expectedPerAction(drop)
    if drop.probability == nil or drop.qtyLow == nil then return nil end
    local averageQty = (drop.qtyLow + (drop.qtyHigh or drop.qtyLow)) / 2
    return drop.rolls * drop.probability * averageQty
end

local recipeData, shopData   -- loaded on first use; recipes are ~1 MB

local function recipeList(indexes)
    recipeData = recipeData or require("data/recipes")
    local result = {}
    for _, r in ipairs(indexes or {}) do
        local raw = recipeData.recipes[r]
        result[#result + 1] = { outputs = raw[1], materials = raw[2], skills = raw[3],
                                ticks = raw[4], members = raw[5] }
    end
    return result
end

-- Recipes whose outputs / materials include the item. Entries in outputs and
-- materials are {itemIndex, quantity}; skills are {name, level, xp}.
function Lookup.recipesMaking(item)
    recipeData = recipeData or require("data/recipes")
    return recipeList(recipeData.madeBy[item])
end

function Lookup.recipesUsing(item)
    recipeData = recipeData or require("data/recipes")
    return recipeList(recipeData.usedIn[item])
end

-- Shops currently stocking the item.
function Lookup.shopsSelling(item)
    shopData = shopData or require("data/shops")
    local result = {}
    for _, raw in ipairs(shopData.stock[item] or {}) do
        result[#result + 1] = { shop = shopData.shops[raw[1]], price = raw[2],
                                currency = shopData.currencies[raw[3]], stock = raw[4],
                                members = raw[5] }
    end
    return result
end

-- Build info for the "data as of" line and the wiki credit.
function Lookup.meta() return meta end

return Lookup

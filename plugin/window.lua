-- The Advanced Examine window: one GroupBox on the plugin layer with a title,
-- tabs, a page of rows and paging buttons. Rows that link to another item or
-- source open it when clicked; Back returns to the previous view.
--
-- The window can be dragged by its title or empty space, and the size button
-- cycles Small / Medium / Large. Position and size are saved in PersistentDB.
-- The header shows a 3D model of what was examined, and item rows show the
-- item's icon; both are drawn by the game from its own assets by game id.
--
-- Components are created once and reused; showing a view only changes text,
-- colours and visibility, and resizing only moves them (layout()).

local Lookup = require("lookup")
local Views = require("views")

local Window = {}

local SIZES = {
    { label = "S", rows = 10, width = 420 },
    { label = "M", rows = 14, width = 420 },
    { label = "L", rows = 24, width = 540 },
}
local MAX_ROWS = 24           -- rows created once; sizes show the first N
local ROW_HEIGHT = 20
local HEADER = 78             -- model + title block height
local TABS_Y = HEADER
local HEADINGS_Y = HEADER + 28
local ROWS_TOP = HEADER + 48
local MODEL_SIZE = 70
local ICON_SIZE = 18
local TEXT_X = 12 + MODEL_SIZE + 8   -- title starts right of the model
local MAX_TABS = 5
local DEFAULT_X, DEFAULT_Y = 20, 120

local FONT_TITLE = id.Font.MUSEO_SANS_17PT_BOLD
local FONT_BODY = id.Font.MUSEO_SANS_13PT_REGULAR
local FONT_SMALL = id.Font.MUSEO_SANS_11PT_REGULAR
local GREY = 0xA0A0A0FF
local TITLE_COLOUR = 0xFF981FFF

local layer                   -- plugin UI layer the window lives on
local box                     -- the GroupBox; nil until first shown
local parts = {}              -- named child components
local rowParts = {}           -- rowParts[i] = { icon, name, qty, rate, per }
local tabButtons = {}

local current = nil           -- the view being shown
local currentTab, currentPage = 1, 1
local history = {}            -- views to go back to
local sizeIndex = 2
local posX, posY = DEFAULT_X, DEFAULT_Y
local log = print             -- replaced by Window.setLogger

---------------------------------------------------------------------------
-- Saved settings (position and size)
---------------------------------------------------------------------------
local function loadSettings()
    local ok, err = pcall(function()
        posX = PersistentDB:GetInt("windowX") or DEFAULT_X
        posY = PersistentDB:GetInt("windowY") or DEFAULT_Y
        local saved = PersistentDB:GetInt("windowSize")
        if saved and SIZES[saved] then sizeIndex = saved end
    end)
    if not ok then log("[AdvEx] could not load window settings: " .. tostring(err)) end
end

local function saveSettings()
    local ok, err = pcall(function()
        PersistentDB:SetInt("windowX", posX)
        PersistentDB:SetInt("windowY", posY)
        PersistentDB:SetInt("windowSize", sizeIndex)
    end)
    if not ok then log("[AdvEx] could not save window settings: " .. tostring(err)) end
end

---------------------------------------------------------------------------
-- Component helpers
---------------------------------------------------------------------------
local function text(font, align)
    local t = ui.Text.new(box)
    t.clickthrough = false    -- clicks on the window must not reach the game world
    t.font = font
    t.alignHorizontal = align or ui.AlignMode.TOPLEFT
    t.alignVertical = ui.AlignMode.CENTRE
    t.maxLines = 1
    return t
end

local function button(label, onPress)
    local b = ui.Button.new(box)
    b.clickthrough = false
    b.stylesheetID = id.StyleSheet.BUTTON_DEFAULT
    b.label = label
    b:Subscribe(ui.Hook.ONBUTTONPRESSED, function() onPress() end)
    return b
end

local function place(c, x, y, w, h)
    c:SetPos(x, y)
    c:SetSize(w, h)
end

---------------------------------------------------------------------------
-- Layout: positions everything for the current size
---------------------------------------------------------------------------
local function rowsShown()
    return SIZES[sizeIndex].rows
end

-- Columns as {x, width}, anchored to the right edge so only Name grows.
local function columns(width)
    local per = { width - 12 - 66, 66 }
    local rate = { per[1] - 4 - 92, 92 }
    local qty = { rate[1] - 4 - 54, 54 }
    local nameX = 12 + ICON_SIZE + 6
    local name = { nameX, qty[1] - 4 - nameX }
    return { name, qty, rate, per }
end

local function layout()
    local width = SIZES[sizeIndex].width
    local pagerY = ROWS_TOP + rowsShown() * ROW_HEIGHT + 6
    local height = pagerY + 24 + 34

    box:SetSize(width, height)
    box:SetPos(posX, posY)

    place(parts.model, 12, 4, MODEL_SIZE, MODEL_SIZE)
    place(parts.bigIcon, 12 + (MODEL_SIZE - 54) / 2, 4 + (MODEL_SIZE - 48) / 2, 54, 48)
    place(parts.title, TEXT_X, 8, width - TEXT_X - 136, 24)
    place(parts.subtitle, TEXT_X, 32, width - TEXT_X - 12, 18)
    place(parts.size, width - 140, 8, 36, 24)
    place(parts.back, width - 100, 8, 52, 24)
    place(parts.close, width - 44, 8, 32, 24)

    local cols = columns(width)
    for i, h in ipairs(parts.headings) do place(h, cols[i][1], HEADINGS_Y, cols[i][2], 18) end
    for i, part in ipairs(rowParts) do
        local y = ROWS_TOP + (i - 1) * ROW_HEIGHT
        place(part.icon, 12, y + 1, ICON_SIZE, ICON_SIZE)
        for c, key in ipairs({ "name", "qty", "rate", "per" }) do
            place(part[key], cols[c][1], y, cols[c][2], ROW_HEIGHT)
        end
    end

    place(parts.prev, 12, pagerY, 60, 24)
    place(parts.page, 80, pagerY, width - 160, 24)
    place(parts.next, width - 72, pagerY, 60, 24)
    place(parts.footer, 12, height - 28, width - 24, 18)
    parts.size.label = SIZES[sizeIndex].label
end

---------------------------------------------------------------------------
-- Game-drawn visuals. Failures are logged once and the visual hidden, so a
-- model or icon problem never stops the window from showing the data.
---------------------------------------------------------------------------
local visualErrors = {}
local showModel, showIcon

local function visualFailed(what, err)
    if not visualErrors[what] then
        visualErrors[what] = true
        log("[AdvEx] " .. what .. " failed: " .. tostring(err))
    end
end

-- Header visual. NPCs get a 3D model; items get their inventory icon drawn
-- large, because item models are ground models lying flat. Tuned live:
-- a model's on-screen size depends only on viewDistance (not on the
-- component size), and NPC_MODEL is anchored at the feet, so it is pushed
-- down by 40% of the box. 850 per tile of the NPC's grid size fits a cow
-- (grid 2) at 1700.
local MODEL_DISTANCE_PER_TILE = 850

showModel = function(model)
    parts.model.hidden = true
    parts.bigIcon.hidden = true
    if model == nil then return end
    local ok, err = pcall(function()
        if model.type == "npc" then
            local gridSize = 1
            local cfg = config.NPC.FromID(model.id)
            if cfg and cfg.gridSize and cfg.gridSize > 0 then gridSize = cfg.gridSize end
            parts.model:SetModel(ui.ModelType.NPC_MODEL, model.id)
            parts.model.modelWidth = MODEL_SIZE
            parts.model.modelHeight = MODEL_SIZE
            parts.model.viewDistance = MODEL_DISTANCE_PER_TILE * gridSize
            parts.model.screenOffset = Vector3.new(0, MODEL_SIZE * 0.4, 0)
            parts.model.hidden = false
        else
            parts.bigIcon:SetAssociatedObject(model.id)
            parts.bigIcon.hidden = false
        end
    end)
    if not ok then visualFailed("model", err) end
end

-- Item icon for a row, drawn from the game's own icon for that obj id.
-- The quantity (which picks stack variants such as coin piles) is set as a
-- property: passing it to SetAssociatedObject fails on the number type.
showIcon = function(sprite, row)
    sprite.hidden = true
    if row == nil or row.icon == nil then return end
    local ok, err = pcall(function()
        sprite:SetAssociatedObject(row.icon)
        sprite.hidden = false
    end)
    if not ok then
        visualFailed("icon", err)
        return
    end
    if row.iconQty and row.iconQty > 1 then
        pcall(function() sprite.associatedObjectQuantity = math.floor(row.iconQty) end)
    end
end

---------------------------------------------------------------------------
-- Rendering: fills text for the current view, tab and page
---------------------------------------------------------------------------
local function pageCount(rows)
    return math.max(1, math.ceil(#rows / rowsShown()))
end

local render   -- forward declaration; tabs and paging call it

local function open(link)
    if current then history[#history + 1] = current end
    current = Views.forLink(link)
    currentTab, currentPage = 1, 1
    render()
end

render = function()
    local width = SIZES[sizeIndex].width
    parts.title.content = current.title
    parts.subtitle.content = current.subtitle
    parts.back.hidden = #history == 0
    showModel(current.model)

    -- Tabs: share the width between however many this view has.
    local count = math.min(#current.tabs, MAX_TABS)
    local tabWidth = math.floor((width - 24 - 4 * (count - 1)) / count)
    for i, b in ipairs(tabButtons) do
        local tab = current.tabs[i]
        b.hidden = (tab == nil) or i > count
        if tab then
            place(b, 12 + (i - 1) * (tabWidth + 4), TABS_Y, tabWidth, 24)
            b.label = string.format("%s (%d)", tab.name, #tab.rows)
        end
    end

    local tab = current.tabs[currentTab]
    local headings = tab.columns or Views.DROP_COLUMNS
    for i, h in ipairs(parts.headings) do h.content = headings[i] or "" end

    local rows = tab.rows
    local pages = pageCount(rows)
    currentPage = math.min(currentPage, pages)
    local first = (currentPage - 1) * rowsShown()
    for i, part in ipairs(rowParts) do
        local row = (i <= rowsShown()) and rows[first + i] or nil
        part.row = row
        showIcon(part.icon, row)
        for _, key in ipairs({ "name", "qty", "rate", "per" }) do
            part[key].hidden = row == nil
            if row then
                part[key].content = row[key] or ""
                part[key].rgba = row.colour or 0xFFFFFFFF
            end
        end
    end
    if #rows == 0 then
        rowParts[1].name.hidden = false
        rowParts[1].name.content = "Nothing listed on the wiki."
        rowParts[1].name.rgba = GREY
    end

    parts.page.content = string.format("Page %d / %d", currentPage, pages)
    parts.prev.hidden = currentPage <= 1
    parts.next.hidden = currentPage >= pages
end

---------------------------------------------------------------------------
-- Dragging: the client reports where a drag started and ended; the window
-- moves by that offset, kept on screen, and the position is saved.
---------------------------------------------------------------------------
local dragStart = nil

local function onDrag(_, startX, startY)
    dragStart = { x = startX, y = startY, boxX = posX, boxY = posY }
end

local function onDragComplete(_, _, endX, endY)
    if dragStart == nil then return end
    local width = SIZES[sizeIndex].width
    local maxX = math.max(0, (layer.width or 1280) - width)
    local maxY = math.max(0, (layer.height or 1360) - 60)
    posX = math.min(maxX, math.max(0, dragStart.boxX + (endX - dragStart.x)))
    posY = math.min(maxY, math.max(0, dragStart.boxY + (endY - dragStart.y)))
    dragStart = nil
    box:SetPos(posX, posY)
    saveSettings()
end

local function makeDragHandle(c)
    c:Subscribe(ui.Hook.ONDRAG, onDrag)
    c:Subscribe(ui.Hook.ONDRAGCOMPLETE, onDragComplete)
end

---------------------------------------------------------------------------
-- Construction (once)
---------------------------------------------------------------------------
local function build()
    layer = ui.Interfaces:GetComponent(id.Component.TOPLEVEL_V2__PLUGIN_BUILD_LAYER_TOP)
    if layer == nil then error("plugin UI layer not available") end
    loadSettings()

    box = ui.GroupBox.new(layer)
    box.stylesheetID = id.StyleSheet.DEFAULT
    box:SetHeaderLayout(0, 0, 0, 0, 0)
    -- Block clicks on the whole window, including empty space between rows,
    -- so they never fall through and walk the player.
    box.clickthrough = false
    box:Subscribe(ui.Hook.ONCLICK, function() return true end)
    makeDragHandle(box)

    parts.model = ui.Model.new(box)
    parts.model.clickthrough = false
    parts.model.hidden = true
    makeDragHandle(parts.model)
    parts.bigIcon = ui.Sprite.new(box)
    parts.bigIcon.clickthrough = false
    parts.bigIcon.hidden = true
    makeDragHandle(parts.bigIcon)

    parts.title = text(FONT_TITLE)
    parts.title.rgba = TITLE_COLOUR
    parts.subtitle = text(FONT_SMALL)
    parts.subtitle.rgba = GREY
    makeDragHandle(parts.title)
    makeDragHandle(parts.subtitle)

    parts.size = button("M", function()
        sizeIndex = sizeIndex % #SIZES + 1
        layout()
        render()
        saveSettings()
    end)
    -- Not "<": the client's text renderer reads "<" as the start of a tag.
    parts.back = button("Back", function()
        current = table.remove(history)
        currentTab, currentPage = 1, 1
        render()
    end)
    parts.close = button("X", function() Window.close() end)

    for i = 1, MAX_TABS do
        tabButtons[i] = button("", function()
            currentTab, currentPage = i, 1
            render()
        end)
    end

    -- Column headings; render() fills them per tab.
    parts.headings = {}
    for i = 1, 4 do
        parts.headings[i] = text(FONT_SMALL, i >= 3 and ui.AlignMode.BOTTOMRIGHT or nil)
        parts.headings[i].rgba = GREY
    end

    for i = 1, MAX_ROWS do
        local icon = ui.Sprite.new(box)
        icon.clickthrough = false
        icon.hidden = true
        local part = {
            icon = icon,
            name = text(FONT_BODY),
            qty = text(FONT_BODY),
            rate = text(FONT_BODY, ui.AlignMode.BOTTOMRIGHT),
            per = text(FONT_BODY, ui.AlignMode.BOTTOMRIGHT),
        }
        -- Clicking a linked row's name opens that item or source.
        part.name:Subscribe(ui.Hook.ONCLICK, function()
            if part.row and part.row.link then open(part.row.link) end
        end)
        rowParts[i] = part
    end

    parts.prev = button("Prev", function()
        currentPage = currentPage - 1
        render()
    end)
    parts.page = text(FONT_SMALL, ui.AlignMode.CENTRE)
    parts.next = button("Next", function()
        currentPage = currentPage + 1
        render()
    end)

    local meta = Lookup.meta()
    parts.footer = text(FONT_SMALL)
    parts.footer.content = string.format("Data: RuneScape Wiki, %s, built %s", meta.licence,
        string.sub(meta.built, 1, 10))
    parts.footer.rgba = GREY

    layout()
end

---------------------------------------------------------------------------
-- Public
---------------------------------------------------------------------------
-- Where window messages go (main.lua passes its devlink-aware print).
function Window.setLogger(fn) log = fn end

-- Shows a view from a fresh examine; clears the Back history.
function Window.show(view)
    if box == nil then build() end
    history = {}
    current = view
    currentTab, currentPage = 1, 1
    box.hidden = false
    render()
end

function Window.close()
    if box then box.hidden = true end
end

return Window

-- The Advanced Examine window: one GroupBox on the plugin layer with a title,
-- tabs, a page of rows and paging buttons. Rows that link to another item or
-- source open it when clicked; Back returns to the previous view.
--
-- The window can be dragged by its title or empty space, and the size button
-- cycles Small / Medium / Large. Position and size are saved in PersistentDB.
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
local ROWS_TOP = 102
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
local rowParts = {}           -- rowParts[i] = { name, qty, rate, per }
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
    local name = { 12, qty[1] - 4 - 12 }
    return { name, qty, rate, per }
end

local function layout()
    local width = SIZES[sizeIndex].width
    local pagerY = ROWS_TOP + rowsShown() * ROW_HEIGHT + 6
    local height = pagerY + 24 + 34

    box:SetSize(width, height)
    box:SetPos(posX, posY)

    place(parts.title, 12, 8, width - 150, 24)
    place(parts.subtitle, 12, 32, width - 24, 18)
    place(parts.size, width - 124, 8, 36, 24)
    place(parts.back, width - 84, 8, 36, 24)
    place(parts.close, width - 44, 8, 32, 24)

    local cols = columns(width)
    for i, h in ipairs(parts.headings) do place(h, cols[i][1], 82, cols[i][2], 18) end
    for i, part in ipairs(rowParts) do
        local y = ROWS_TOP + (i - 1) * ROW_HEIGHT
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

    -- Tabs: share the width between however many this view has.
    local count = math.min(#current.tabs, MAX_TABS)
    local tabWidth = math.floor((width - 24 - 4 * (count - 1)) / count)
    for i, b in ipairs(tabButtons) do
        local tab = current.tabs[i]
        b.hidden = (tab == nil) or i > count
        if tab then
            place(b, 12 + (i - 1) * (tabWidth + 4), 54, tabWidth, 24)
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
    parts.back = button("<", function()
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
        local part = {
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

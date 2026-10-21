-- Examine Data: RuneScape Wiki drop, recipe and shop data for other plugins.
--
-- This plugin has no window or menu option of its own. Other plugins list it
-- as a dependency and receive the lookup API below (see lookup.lua for every
-- function), e.g. in plugin.json:
--     "dependencies": { "ExamineData": "examine-data" }
-- and then in Lua:
--     local drops = ExamineData.dropsOfItem(ExamineData.itemByObj(536))
--
-- No network access: all data ships inside this plugin (CC BY-NC-SA 3.0,
-- RuneScape Wiki; see data/LICENSE.md).

return require("lookup")

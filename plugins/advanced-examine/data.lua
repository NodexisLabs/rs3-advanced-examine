-- The Examine Data library, provided by the "examine-data" plugin dependency
-- (plugin.json: "dependencies": { "ExamineData": "examine-data" }).
-- Fails loudly if the dependency is missing rather than showing empty windows.

local ok, lib = pcall(function() return ExamineData end)
if not ok or type(lib) ~= "table" then
    error("Advanced Examine needs the Examine Data plugin (dependency 'ExamineData' not loaded)")
end
return lib

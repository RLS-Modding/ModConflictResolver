setExtensionUnloadMode("conflictResolution_luaBreakdown", "manual")
extensions.unload("conflictResolution_luaBreakdown")

setExtensionUnloadMode("conflictResolution_luaMerger", "manual")
extensions.unload("conflictResolution_luaMerger")

setExtensionUnloadMode("conflictResolution_conflictResolver", "manual")
extensions.unload("conflictResolution_conflictResolver")

loadManualUnloadExtensions()
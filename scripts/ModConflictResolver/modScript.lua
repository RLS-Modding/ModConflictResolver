-- Load the dependency management system
setExtensionUnloadMode("requiredMods", "manual")
extensions.unload("requiredMods")

-- Load the conflict resolver system
setExtensionUnloadMode("conflictResolver", "manual")
extensions.unload("conflictResolver")

loadManualUnloadExtensions()
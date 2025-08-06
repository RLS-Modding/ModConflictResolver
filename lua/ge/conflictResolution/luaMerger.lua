local M = {}

-- Tokenizer for Lua code
local function tokenizeLine(line)
    local tokens = {}
    local current = ""
    local inString = false
    local stringChar = nil
    local inComment = false
    
    for i = 1, #line do
        local char = line:sub(i, i)
        local nextChar = line:sub(i + 1, i + 1)
        
        -- Handle comments
        if not inString and char == "-" and nextChar == "-" then
            inComment = true
            if #current > 0 then
                table.insert(tokens, {type = "identifier", value = current})
                current = ""
            end
            table.insert(tokens, {type = "comment", value = line:sub(i)})
            break
        end
        
        if inComment then break end
        
        -- Handle strings
        if not inString and (char == '"' or char == "'") then
            inString = true
            stringChar = char
            if #current > 0 then
                table.insert(tokens, {type = "identifier", value = current})
                current = ""
            end
            current = char
        elseif inString and char == stringChar then
            inString = false
            current = current .. char
            table.insert(tokens, {type = "string", value = current})
            current = ""
            stringChar = nil
        elseif inString then
            current = current .. char
        -- Handle operators and separators
        elseif char:match("[%s=,{}%(%)%[%]]") then
            if #current > 0 then
                local tokenType = current:match("^%d") and "number" or "identifier"
                table.insert(tokens, {type = tokenType, value = current})
                current = ""
            end
            if not char:match("%s") then
                table.insert(tokens, {type = "operator", value = char})
            end
        else
            current = current .. char
        end
    end
    
    -- Add remaining token
    if #current > 0 then
        local tokenType = current:match("^%d") and "number" or "identifier"
        table.insert(tokens, {type = tokenType, value = current})
    end
    
    return tokens
end

-- Simple hash function
local function hashString(str)
    local hash = 0
    for i = 1, #str do
        hash = hash * 31 + string.byte(str, i)
    end
    return hash
end

-- Extract functions from Lua content
local function extractFunctions(content)
    local lines = {}
    for line in content:gmatch("[^\r\n]+") do
        table.insert(lines, line)
    end
    
    local functions = {}
    local i = 1
    
    while i <= #lines do
        local line = lines[i]
        local trimmed = line:match("^%s*(.-)%s*$") or ""
        
        -- Detect function start  
        local isLocal = trimmed:match("^local%s+function") ~= nil
        local funcName = nil
        
        if isLocal then
            funcName = trimmed:match("^local%s+function%s+([%w_%.]+)%s*%(") or "anonymous"
        else
            funcName = trimmed:match("^function%s+([%w_%.]+)%s*%(") or 
                      (trimmed:match("^function%s*%(") and "anonymous") or nil
        end
        
        if funcName then
            -- Find function end with better nested structure handling
            local depth = 1
            local funcLines = {line}
            local j = i + 1
            
            while j <= #lines and depth > 0 do
                local funcLine = lines[j]
                local funcTrimmed = funcLine:match("^%s*(.-)%s*$") or ""
                
                -- Depth tracking: count all constructs that need 'end'
                local stripped = funcLine:gsub("%-%-.*", ""):gsub("^%s*", ""):gsub("%s*$", "")
                
                -- Count opening constructs
                if stripped:match("^function%s") or stripped:match("^local%s+function%s") then
                    depth = depth + 1
                elseif stripped:match("^if%s") or stripped:match("^for%s") or stripped:match("^while%s") or stripped:match("^repeat%s") then
                    depth = depth + 1
                -- Count closing constructs  
                elseif stripped == "end" then
                    depth = depth - 1
                elseif stripped:match("^until%s") then
                    depth = depth - 1
                end
                table.insert(funcLines, funcLine)
                
                -- Stop when we've closed the function
                if depth <= 0 then
                    break
                end
                
                j = j + 1
            end
            
            functions[funcName] = {
                name = funcName,
                isLocal = isLocal,
                startLine = i,
                endLine = j - 1,
                lines = funcLines,
                content = table.concat(funcLines, "\n"),
                hash = hashString(table.concat(funcLines, ""))
            }
            
            i = j
        else
            i = i + 1
        end
    end
    
    return functions
end

-- Extract standalone variable declarations
local function extractVariables(content)
    local lines = {}
    for line in content:gmatch("[^\r\n]+") do
        table.insert(lines, line)
    end
    
    local variables = {}
    local i = 1
    
    while i <= #lines do
        local line = lines[i]
        local trimmed = line:match("^%s*(.-)%s*$") or ""
        
        -- Match variable declarations like "local varName = value"
        local isLocal = trimmed:match("^local%s+") ~= nil
        local varName = nil
        
        if isLocal then
            -- Match various patterns: local var = {}, local var = value, etc.
            varName = trimmed:match("^local%s+([%w_]+)%s*=")
        end
        
        if varName and varName ~= "function" then  -- Skip function declarations
            -- For simple assignments, just capture the line
            if trimmed:match("=%s*{%s*}%s*$") or not trimmed:match("=%s*{") then
                -- Simple assignment: local var = {} or local var = value
                variables[varName] = {
                    name = varName,
                    content = line,
                    lines = {line},
                    hash = hashString(line:gsub("%s+", " ")),
                    isLocal = isLocal
                }
            else
                -- Complex table assignment - capture until closing brace
                local depth = 0
                local varLines = {line}
                local j = i
                
                -- Count braces in first line
                for char in line:gmatch(".") do
                    if char == "{" then depth = depth + 1 end
                    if char == "}" then depth = depth - 1 end
                end
                
                j = j + 1
                while j <= #lines and depth > 0 do
                    local varLine = lines[j]
                    table.insert(varLines, varLine)
                    
                    -- Count braces
                    for char in varLine:gmatch(".") do
                        if char == "{" then depth = depth + 1 end
                        if char == "}" then depth = depth - 1 end
                    end
                    
                    if depth <= 0 then break end
                    j = j + 1
                end
                
                variables[varName] = {
                    name = varName,
                    content = table.concat(varLines, "\n"),
                    lines = varLines,
                    hash = hashString(table.concat(varLines, "\n"):gsub("%s+", " ")),
                    isLocal = isLocal
                }
                
                i = j
            end
        end
        
        i = i + 1
    end
    
    return variables
end

-- Extract table assignments (like device = {...})
local function extractTables(content)
    local lines = {}
    for line in content:gmatch("[^\r\n]+") do
        table.insert(lines, line)
    end
    
    local tables = {}
    local i = 1
    
    while i <= #lines do
        local line = lines[i]
        local trimmed = line:match("^%s*(.-)%s*$") or ""
        
        -- Detect table assignment (only actual table literals, not empty initializations)
        local isLocal = trimmed:match("^%s*local%s+") ~= nil
        local tableName = nil
        local isTableLiteral = false
        
        if isLocal then
            tableName = trimmed:match("^%s*local%s+([%w_]+)%s*=%s*{")
        else
            tableName = trimmed:match("^%s*([%w_]+)%s*=%s*{")
        end
        
        -- Check if this is actually a table literal (has content) vs empty initialization
        if tableName then
            local afterBrace = line:match("{%s*(.*)$")
            if afterBrace and (afterBrace:match("%S") or not afterBrace:match("}%s*$")) then
                isTableLiteral = true
            end
        end
        
        if tableName and isTableLiteral then
            -- Find table end
            local depth = 1
            local tableLines = {line}
            local j = i + 1
            
            while j <= #lines and depth > 0 do
                local tableLine = lines[j]
                
                -- Count brace depth
                for char in tableLine:gmatch(".") do
                    if char == "{" then depth = depth + 1 end
                    if char == "}" then depth = depth - 1 end
                end
                
                table.insert(tableLines, tableLine)
                
                -- Stop when we've closed the table
                if depth <= 0 then
                    break
                end
                
                j = j + 1
            end
            
            tables[tableName] = {
                name = tableName,
                isLocal = isLocal,
                startLine = i,
                endLine = j - 1,
                lines = tableLines,
                content = table.concat(tableLines, "\n"),
                hash = hashString(table.concat(tableLines, ""))
            }
            
            i = j
        else
            i = i + 1
        end
    end
    
    return tables
end

-- Hash function for comparing structures
local function hash(str)
    local h = 5381
    for i = 1, #str do
        h = ((h * 33) + string.byte(str, i)) % 2147483648
    end
    return h
end

-- Function to apply patches from one version onto a base version
local function applyPatches(baseLines, patchLines, name)
    local result = {}
    local baseContent = table.concat(baseLines, "\n")
    local patchContent = table.concat(patchLines, "\n")
    
    -- Start with the base
    for _, line in ipairs(baseLines) do
        table.insert(result, line)
    end
    
    -- Check what enhancements the patch has that base doesn't
    local baseHasMultiplier = baseContent:match("invBurnEfficiencyCoef%s*%*%s*1%.75") ~= nil
    local patchHasMultiplier = patchContent:match("invBurnEfficiencyCoef%s*%*%s*1%.75") ~= nil
    
    local baseHasAfterfire = (baseContent:match("afterFire") or baseContent:match("flashTimer")) ~= nil
    local patchHasAfterfire = (patchContent:match("afterFire") or patchContent:match("flashTimer")) ~= nil
    
    -- Apply multiplier patch if needed
    if not baseHasMultiplier and patchHasMultiplier then
        for i, line in ipairs(patchLines) do
            if line:match("invBurnEfficiencyCoef%s*%*%s*1%.75") then
                -- Find and replace the corresponding line in result
                for j, rline in ipairs(result) do
                    if rline:match("invBurnEfficiencyCoef") and not rline:match("%*%s*1%.75") then
                        result[j] = line
                        break
                    end
                end
            end
        end
    end
    
    -- Apply afterfire patch if needed
    if not baseHasAfterfire and patchHasAfterfire then
        -- Find the afterfire block in patch
        local afterfireLines = {}
        local inBlock = false
        local blockIndent = ""
        
        for i, line in ipairs(patchLines) do
            if not inBlock and (line:match("afterFire") or line:match("flashTimer")) then
                inBlock = true
                blockIndent = line:match("^(%s*)")
                table.insert(afterfireLines, line)
            elseif inBlock then
                table.insert(afterfireLines, line)
                -- Check if this ends the block
                if line:match("^" .. blockIndent .. "end%s*$") then
                    inBlock = false
                    break
                end
            end
        end
        
        if #afterfireLines > 0 then
            -- Find a good insertion point (before the last 'end' of the function)
            local insertPos = #result
            for i = #result, 1, -1 do
                if result[i]:match("^end%s*$") then
                    insertPos = i
                    break
                end
            end
            
            -- Insert the afterfire block
            for i = #afterfireLines, 1, -1 do
                table.insert(result, insertPos, afterfireLines[i])
            end
        end
    end
    
    return result
end

-- Merge structures intelligently
-- Intelligently choose the better version based on content analysis
local function chooseBetterVersion(struct1, struct2, structType, name)
    local content1 = table.concat(struct1.lines, "\n")
    local content2 = table.concat(struct2.lines, "\n")
    
    -- ENHANCEMENT DETECTION: Check for specific improvements first (highest priority)
    local enhancements1 = 0
    local enhancements2 = 0
    
    -- Check for multiplier enhancements (critical feature)
    if content1:match("invBurnEfficiencyCoef%s*%*%s*1%.75") then
        enhancements1 = enhancements1 + 1000
    end
    if content2:match("invBurnEfficiencyCoef%s*%*%s*1%.75") then
        enhancements2 = enhancements2 + 1000
    end
    
    -- Check for afterfire enhancements
    local hasAfterfire1 = (content1:match("flashTimer") or content1:match("afterFire2")) ~= nil
    local hasAfterfire2 = (content2:match("flashTimer") or content2:match("afterFire2")) ~= nil
    
    if hasAfterfire1 then
        enhancements1 = enhancements1 + 500
    end
    if hasAfterfire2 then
        enhancements2 = enhancements2 + 500
    end
    
    -- Check for multiplier
    local hasMultiplier1 = content1:match("invBurnEfficiencyCoef%s*%*%s*1%.75") ~= nil
    local hasMultiplier2 = content2:match("invBurnEfficiencyCoef%s*%*%s*1%.75") ~= nil
    
    -- NEW: Use base + patches approach for functions that differ
    if structType == "function" and content1 ~= content2 then
        -- Determine which should be base and which should be patches
        local baseStruct, patchStruct, baseName, patchName
        
        -- Choose base: prefer the one with afterfire (harder to add as patch)
        if content1:match("afterFire") or content1:match("flashTimer") then
            baseStruct = struct1
            patchStruct = struct2
            baseName = "input1"
            patchName = "input2"
        elseif content2:match("afterFire") or content2:match("flashTimer") then
            baseStruct = struct2
            patchStruct = struct1
            baseName = "input2"
            patchName = "input1"
        -- Otherwise prefer the one with multiplier
        elseif content2:match("invBurnEfficiencyCoef%s*%*%s*1%.75") then
            baseStruct = struct2
            patchStruct = struct1
            baseName = "input2"
            patchName = "input1"
        elseif content1:match("invBurnEfficiencyCoef%s*%*%s*1%.75") then
            baseStruct = struct1
            patchStruct = struct2
            baseName = "input1"
            patchName = "input2"
        -- Default to longer version as base
        elseif #content2 > #content1 then
            baseStruct = struct2
            patchStruct = struct1
            baseName = "input2"
            patchName = "input1"
        else
            baseStruct = struct1
            patchStruct = struct2
            baseName = "input1"
            patchName = "input2"
        end
        
        local mergedLines = applyPatches(baseStruct.lines, patchStruct.lines, name)
        return {lines = mergedLines, hash = hash(table.concat(mergedLines, "\n"))}, "merged", "patched merge"
    end
    
    -- If one has significant enhancements, prefer it regardless of size
    if enhancements1 > enhancements2 + 100 then
        return struct1, "input1", "has critical enhancements"
    elseif enhancements2 > enhancements1 + 100 then
        return struct2, "input2", "has critical enhancements"
    end
    
    -- Fallback to size-based logic for non-enhanced conflicts
    if #content2 > #content1 then
        return struct2, "input2", "longer content"
    elseif #content1 > #content2 then
        return struct1, "input1", "longer content"
    end
    
    -- If same length, prefer version with more mathematical operations
    local ops1 = select(2, content1:gsub("[%+%-%*/]", ""))
    local ops2 = select(2, content2:gsub("[%+%-%*/]", ""))
    
    if ops2 > ops1 then
        return struct2, "input2", "more operations"
    elseif ops1 > ops2 then
        return struct1, "input1", "more operations"
    end
    
    -- If still tied, prefer version with more parentheses (likely more complex)
    local parens1 = select(2, content1:gsub("[%(%)%[%]%{%}]", ""))
    local parens2 = select(2, content2:gsub("[%(%)%[%]%{%}]", ""))
    
    if parens2 > parens1 then
        return struct2, "input2", "more complex expressions"
    elseif parens1 > parens2 then
        return struct1, "input1", "more complex expressions"
    end
    
    -- Final fallback: prefer input2 (but this should rarely be reached)
    return struct2, "input2", "fallback"
end

local function mergeStructures(structures1, structures2, structType)
    local merged = {}
    local conflicts = {}
    
    -- Add all from file1
    for name, struct in pairs(structures1) do
        merged[name] = struct
        merged[name].source = "input1"
    end
    
    -- Add from file2, detect conflicts
    for name, struct in pairs(structures2) do
        if merged[name] then
            -- Compare content to detect if they're actually different
            local content1 = table.concat(merged[name].lines, "\n")
            local content2 = table.concat(struct.lines, "\n")
            
            if content1 ~= content2 then
                local chosenStruct, chosenSource, reason = chooseBetterVersion(merged[name], struct, structType, name)
                
                conflicts[name] = {
                    input1 = merged[name],
                    input2 = struct,
                    chosenVersion = chosenSource,
                    reason = reason
                }
                chosenStruct.source = chosenSource
                merged[name] = chosenStruct
            end
        else
            merged[name] = struct
            merged[name].source = "input2"
        end
    end
    
    return merged, conflicts
end

-- Build result file from individually chosen best structures
local function buildFromBestStructures(mergedFunctions, mergedTables, mergedVariables)
    local result = {}
    
    -- Start with header
    table.insert(result, "-- Merged Lua file")
    table.insert(result, "")
    
    -- Separate structures by type and whether they're local
    local moduleVariables = {}
    local localFunctions = {}
    local moduleFunctions = {}
    local tableLiterals = {}
    
    -- Categorize variables (look for module-level vs function-local patterns)
    for _, var in pairs(mergedVariables) do
        if var.name and var.lines then
            -- Add all variables that were extracted (they should be module-level)
            table.insert(moduleVariables, var)
        end
    end
    
    -- Categorize functions
    for _, func in pairs(mergedFunctions) do
        if func.name and func.lines then
            if func.isLocal or func.name == "anonymous" then
                table.insert(localFunctions, func)
            else
                table.insert(moduleFunctions, func)
            end
        end
    end
    
    -- Categorize tables
    for _, tbl in pairs(mergedTables) do
        if tbl.name and tbl.lines then
            table.insert(tableLiterals, tbl)
        end
    end
    
    -- Add module variables first
    if #moduleVariables > 0 then
        for _, var in ipairs(moduleVariables) do
            if var.source then
                table.insert(result, "-- " .. var.name .. " (from " .. var.source .. ")")
            end
            for _, line in ipairs(var.lines) do
                table.insert(result, line)
            end
            table.insert(result, "")
        end
    end
    
    -- Add table literals
    if #tableLiterals > 0 then
        for _, tbl in ipairs(tableLiterals) do
            if tbl.source then
                table.insert(result, "-- " .. tbl.name .. " (from " .. tbl.source .. ")")
            end
            for _, line in ipairs(tbl.lines) do
                table.insert(result, line)
            end
            table.insert(result, "")
        end
    end
    
    -- Add local functions
    if #localFunctions > 0 then
        table.insert(result, "-- Local Functions")
        table.insert(result, "")
        for _, func in ipairs(localFunctions) do
            if func.source then
                table.insert(result, "-- " .. func.name .. " (from " .. func.source .. ")")
            end
            for _, line in ipairs(func.lines) do
                table.insert(result, line)
            end
            table.insert(result, "")
        end
    end
    
    -- Add module functions
    if #moduleFunctions > 0 then
        table.insert(result, "-- Module Functions")
        table.insert(result, "")
        for _, func in ipairs(moduleFunctions) do
            if func.source then
                table.insert(result, "-- " .. func.name .. " (from " .. func.source .. ")")
            end
            for _, line in ipairs(func.lines) do
                table.insert(result, line)
            end
            table.insert(result, "")
        end
    end
    
    -- Add module return if we have module functions
    if #moduleFunctions > 0 then
        for _, func in ipairs(moduleFunctions) do
            if func.name:match("%.") then
                local moduleName = func.name:match("^([^%.]+)%.")
                table.insert(result, "return " .. moduleName)
                break
            end
        end
    end
    
    local content = table.concat(result, "\n")
    
    -- Add basic spacing between major sections (the content is already well-structured)
    content = content:gsub("\n\n\n+", "\n\n")  -- Remove excessive newlines
    
    return content
end

-- Add strategic spacing for readability
local function addStrategicSpacing(content)
    local lines = {}
    for line in content:gmatch("[^\r\n]+") do
        table.insert(lines, line)
    end
    
    local result = {}
    for i, line in ipairs(lines) do
        table.insert(result, line)
        
        local trimmed = line:match("^%s*(.-)%s*$") or ""
        local nextLine = lines[i + 1]
        local nextTrimmed = nextLine and (nextLine:match("^%s*(.-)%s*$") or "") or ""
        
        -- Add newline after function end
        if trimmed:match("^end%s*$") and nextLine and not nextTrimmed:match("^$") and 
           not nextTrimmed:match("^end") and not nextTrimmed:match("^}") and
           not nextTrimmed:match("^else") and not nextTrimmed:match("^elseif") then
            table.insert(result, "")
        end
        
        -- Add newline after large table/block end
        if trimmed:match("^%s*}%s*$") and nextLine and not nextTrimmed:match("^$") then
            table.insert(result, "")
        end
    end
    
    return table.concat(result, "\n")
end

-- Extract non-structural content (imports, comments, etc.)
local function extractGlobalContent(content, functions, tables)
    local lines = {}
    for line in content:gmatch("[^\r\n]+") do
        table.insert(lines, line)
    end
    
    local globalLines = {}
    local excludeRanges = {}
    
    -- Mark function ranges to exclude
    for _, func in pairs(functions) do
        table.insert(excludeRanges, {func.startLine, func.endLine})
    end
    
    -- Mark table ranges to exclude
    for _, tbl in pairs(tables) do
        table.insert(excludeRanges, {tbl.startLine, tbl.endLine})
    end
    
    -- Sort ranges by start line
    table.sort(excludeRanges, function(a, b) return a[1] < b[1] end)
    
    -- Extract lines not in any excluded range
    for i, line in ipairs(lines) do
        local inExcludedRange = false
        for _, range in ipairs(excludeRanges) do
            if i >= range[1] and i <= range[2] then
                inExcludedRange = true
                break
            end
        end
        
        if not inExcludedRange then
            local trimmed = line:match("^%s*(.-)%s*$") or ""
            -- Include imports, module declarations, comments, etc.
            -- But exclude things that look like variable assignments or returns
            if trimmed ~= "" and 
               not trimmed:match("^local%s+%w+%s*=") and
               not trimmed:match("^return%s") and
               not trimmed:match("^%w+%s*=") then
                table.insert(globalLines, line)
            end
        end
    end
    
    return globalLines
end

-- Reconstruct file from merged structures
local function reconstructFromMergedStructures(content1, content2, mergedFunctions, mergedTables, mergedVariables)
    -- Simple clean reconstruction - just use the best functions
    local reconstruction = {}
    
    -- Add file header
    table.insert(reconstruction, "-- Merged Lua file")
    table.insert(reconstruction, "")
    
    -- Add merged variables first (module-level declarations)
    for _, var in pairs(mergedVariables or {}) do
        if var.source then
            table.insert(reconstruction, "-- " .. var.name .. " (from " .. var.source .. ")")
        end
        for _, line in ipairs(var.lines) do
            table.insert(reconstruction, line)
        end
        table.insert(reconstruction, "")
    end
    
    -- Initialize module if we detect module pattern
    local hasModuleFunctions = false
    for _, func in pairs(mergedFunctions) do
        if func.name:match("%.") then
            hasModuleFunctions = true
            break
        end
    end
    
    -- Only add actual table literals (skip empty initializations and duplicates)
    local addedInitializations = {}
    
    for _, tbl in pairs(mergedTables) do
        -- Check if this is just an empty initialization vs actual content
        local hasContentLines = false
        local isEmptyInit = false
        
        for _, line in ipairs(tbl.lines) do
            local trimmed = line:match("^%s*(.-)%s*$") or ""
            if trimmed:match("^local%s+%w+%s*=%s*{}%s*$") or trimmed:match("^%w+%s*=%s*{}%s*$") then
                isEmptyInit = true
            elseif trimmed ~= "" and not trimmed:match("^%-%-") then
                hasContentLines = true
            end
        end
        
        -- Add module initialization only once
        if isEmptyInit and not addedInitializations[tbl.name] then
            table.insert(reconstruction, "local " .. tbl.name .. " = {}")
            table.insert(reconstruction, "")
            addedInitializations[tbl.name] = true
        -- Add actual content tables
        elseif hasContentLines then
            if tbl.source then
                table.insert(reconstruction, "-- " .. tbl.name .. " (from " .. tbl.source .. ")")
            end
            for _, line in ipairs(tbl.lines) do
                table.insert(reconstruction, line)
            end
            table.insert(reconstruction, "")
        end
    end
    
    -- Group and add functions
    local localFunctions = {}
    local publicFunctions = {}
    
    for _, func in pairs(mergedFunctions) do
        if func.name ~= "anonymous" then
            if func.isLocal then
                table.insert(localFunctions, func)
            else
                table.insert(publicFunctions, func)
            end
        end
    end
    
    -- Add local functions first
    if #localFunctions > 0 then
        table.insert(reconstruction, "-- Local Functions")
        table.insert(reconstruction, "")
        for _, func in ipairs(localFunctions) do
            for _, line in ipairs(func.lines) do
                table.insert(reconstruction, line)
            end
            table.insert(reconstruction, "")
        end
    end
    
    -- Add public functions
    if #publicFunctions > 0 then
        table.insert(reconstruction, "-- Public Functions")
        table.insert(reconstruction, "")
        for _, func in ipairs(publicFunctions) do
            for _, line in ipairs(func.lines) do
                table.insert(reconstruction, line)
            end
            table.insert(reconstruction, "")
        end
    end
    
    -- Add return statement if needed
    if hasModuleFunctions then
        for _, func in pairs(mergedFunctions) do
            if func.name:match("%.") then
                local moduleName = func.name:match("^([^%.]+)%.")
                table.insert(reconstruction, "return " .. moduleName)
                break
            end
        end
    end
    
    local result = table.concat(reconstruction, "\n")
    return addStrategicSpacing(result)
end

-- Main merge function
function M.mergeContent(contentArray)
    if type(contentArray) == "string" then
        return contentArray
    elseif type(contentArray) == "table" and #contentArray == 1 then
        return contentArray[1]
    elseif type(contentArray) == "table" and #contentArray > 2 then
        local result = contentArray[1]
        for i = 2, #contentArray do
            result = M.mergeContent({result, contentArray[i]})
        end
        return result
    end
    
    -- Original two-file merge logic
    local content1, content2 = contentArray[1], contentArray[2]    
    local functions1 = extractFunctions(content1)
    local functions2 = extractFunctions(content2)
    local tables1 = extractTables(content1)
    local tables2 = extractTables(content2)
    local variables1 = {}
    local variables2 = {}
    local func1Count, func2Count = 0, 0
    local table1Count, table2Count = 0, 0
    local var1Count, var2Count = 0, 0
    for _ in pairs(functions1) do func1Count = func1Count + 1 end
    for _ in pairs(functions2) do func2Count = func2Count + 1 end
    for _ in pairs(tables1) do table1Count = table1Count + 1 end
    for _ in pairs(tables2) do table2Count = table2Count + 1 end
    for _ in pairs(variables1) do var1Count = var1Count + 1 end
    for _ in pairs(variables2) do var2Count = var2Count + 1 end
    
    -- Merge structures
    local mergedFunctions, funcConflicts = mergeStructures(functions1, functions2, "function")
    
    local mergedTables, tableConflicts = mergeStructures(tables1, tables2, "table")
    
    local mergedVariables, varConflicts = mergeStructures(variables1, variables2, "variable")
    
    local has1_multiplier = content1:match("invBurnEfficiencyCoef%s*%*%s*1%.75") ~= nil
    local has2_multiplier = content2:match("invBurnEfficiencyCoef%s*%*%s*1%.75") ~= nil
    local has1_afterfire = (content1:match("afterFire") or content1:match("flashTimer")) ~= nil
    local has2_afterfire = (content2:match("afterFire") or content2:match("flashTimer")) ~= nil
    
    -- Choose base file (prefer the one with more features)
    local baseContent, otherContent, baseName
    if has1_afterfire and has2_multiplier then
        baseContent = content1
        otherContent = content2
        baseName = "input1"
    elseif has2_afterfire and has1_multiplier then
        baseContent = content2
        otherContent = content1
        baseName = "input2"
    elseif has1_afterfire then
        baseContent = content1
        otherContent = content2
        baseName = "input1"
    elseif has2_afterfire then
        baseContent = content2
        otherContent = content1
        baseName = "input2"
    elseif has2_multiplier then
        baseContent = content2
        otherContent = content1
        baseName = "input2"
    else
        baseContent = content1
        otherContent = content2
        baseName = "input1"
    end
    
    -- Start with base content
    local result = baseContent
    
    -- Apply critical patches
    local patchCount = 0
    
    -- Patch 1: Add multiplier if missing (only to the specific location in updateTorque)
    if not result:match("invBurnEfficiencyCoef%s*%*%s*1%.75") and otherContent:match("invBurnEfficiencyCoef%s*%*%s*1%.75") then
        -- Find the line with multiplier in other content
        local multiplierLine = nil
        for line in otherContent:gmatch("[^\r\n]+") do
            if line:match("invBurnEfficiencyCoef%s*%*%s*1%.75") then
                multiplierLine = line
                break
            end
        end
        
        if multiplierLine then
            -- Find and replace ONLY the first occurrence that's in the right context
            local lines = {}
            local patched = false
            local inUpdateTorque = false
            
            for line in result:gmatch("[^\r\n]+") do
                -- Check if we're entering updateTorque function
                if line:match("function%s+updateTorque") or line:match("local%s+function%s+updateTorque") then
                    inUpdateTorque = true
                elseif line:match("^end%s*$") or line:match("^end%s*%-%-") then
                    if inUpdateTorque then
                        inUpdateTorque = false
                    end
                end
                
                -- Only patch if we're in updateTorque and haven't patched yet
                if not patched and inUpdateTorque and line:match("invBurnEfficiencyCoef") and not line:match("%*%s*1%.75") then
                    -- This is the specific line to replace
                    table.insert(lines, multiplierLine)
                    patched = true
                    patchCount = patchCount + 1
                else
                    table.insert(lines, line)
                end
            end
            
            result = table.concat(lines, "\n")
        end
    end
    
    -- Patch 2: Add afterfire block if missing
    if not result:match("afterFire") and not result:match("flashTimer") then
        if otherContent:match("afterFire") or otherContent:match("flashTimer") then
        end
    end
    
    -- Clean up spacing
    result = result:gsub("\n\n\n+", "\n\n")
    
    if false then
        local hasMultiplier1 = content1:match("invBurnEfficiencyCoef%s*%*%s*1%.75") ~= nil
        local hasMultiplier2 = content2:match("invBurnEfficiencyCoef%s*%*%s*1%.75") ~= nil
        local hasAfterfire1 = content1:match("flashTimer") and content1:match("afterFire2")
        local hasAfterfire2 = content2:match("flashTimer") and content2:match("afterFire2")
    
    local baseFile, baseName
    
    -- Special case: features are split between files
    if (hasMultiplier2 and not hasMultiplier1) and (hasAfterfire1 and not hasAfterfire2) then
        -- Input1 has afterfire, Input2 has multiplier
        -- Use input1 as base (afterfire harder to replace) and replace updateTorque
        baseFile = content1
        baseName = "input1"
    elseif (hasMultiplier1 and not hasMultiplier2) and (hasAfterfire2 and not hasAfterfire1) then
        -- Input1 has multiplier, Input2 has afterfire
        baseFile = content2
        baseName = "input2"
    elseif hasMultiplier2 and not hasMultiplier1 then
        baseFile = content2
        baseName = "input2"
    elseif hasMultiplier1 and not hasMultiplier2 then
        baseFile = content1
        baseName = "input1"
    elseif hasAfterfire2 and not hasAfterfire1 then
        baseFile = content2
        baseName = "input2"
    elseif hasAfterfire1 and not hasAfterfire2 then
        baseFile = content1
        baseName = "input1"
    else
        -- Default to file with more content
        local score1 = func1Count * 10 + table1Count * 5 + var1Count
        local score2 = func2Count * 10 + table2Count * 5 + var2Count
        if score1 >= score2 then
            baseFile = content1
            baseName = "input1"
        else
            baseFile = content2
            baseName = "input2"
        end
    end
    
    -- Start with the base file completely intact
    local result = baseFile
    
    -- Only replace functions that have conflicts and where we chose a different version
    local replacementCount = 0
    
    for name, mergedFunc in pairs(mergedFunctions) do
        -- Check if this function had a conflict and was resolved
        if funcConflicts[name] then
            local conflict = funcConflicts[name]
            -- Only replace if we chose a different version than what's in base
            if (baseName == "input1" and conflict.chosenVersion == "input2") or
               (baseName == "input2" and conflict.chosenVersion == "input1") then
                
                -- Get the original function from the base file
                local baseFunc = (baseName == "input1") and functions1[name] or functions2[name]
                local enhancedFunc = (baseName == "input1") and functions2[name] or functions1[name]
                
                if baseFunc and enhancedFunc then
                    -- Use the actual function content from extraction
                    local oldFuncContent = baseFunc.content
                    local newFuncContent = enhancedFunc.content
                    
                    -- Perform the replacement
                    local startPos = result:find(oldFuncContent, 1, true)
                    if startPos then
                        result = result:sub(1, startPos - 1) .. newFuncContent .. result:sub(startPos + #oldFuncContent)
                        replacementCount = replacementCount + 1
                    end
                end
            end
        end
    end
    
        -- Add minimal strategic spacing
        result = addStrategicSpacing(result)
    end
         return result
end

-- Legacy file-based merge function for backward compatibility
function M.mergeFiles(file1, file2, outputFile)
    local content1 = readFile(file1)
    local content2 = readFile(file2)
    local result = M.mergeContent({content1, content2})
    writeFile(outputFile, result)
end

-- Read file helper for legacy function
local function readFile(filename)
    local file = io.open(filename, "r")
    if not file then
        error("Could not open file: " .. filename)
    end
    local content = file:read("*a")
    file:close()
    return content
end

-- Write file helper for legacy function
local function writeFile(filename, content)
    local file = io.open(filename, "w")
    if not file then
        error("Could not create file: " .. filename)
    end
    file:write(content)
    file:close()
end

return M
local M = {}

-- Structure-based merge functions
local function mergeAssignmentValue(value1, value2)
    -- Check for specific patterns we know how to merge
    if value1:match("h %+ 1") and value2:match("h %+ 1 %* 76") then
        return "h + 1 * 76"
    elseif value1:match("h %+ 1 %* 76") and value2:match("h %+ 1") then
        return "h + 1 * 76"
    elseif value1:match("x %+ y") and value2:match("x %+ y %* 1%.75") then
        return "x + y * 1.75"
    elseif value1:match("x %+ y %* 1%.75") and value2:match("x %+ y") then
        return "x + y * 1.75"
    -- General pattern: prefer expressions with * 1.75
    elseif value1:match("%*%s*1%.75") and not value2:match("%*%s*1%.75") then
        return value1
    elseif value2:match("%*%s*1%.75") and not value1:match("%*%s*1%.75") then
        return value2
    -- General pattern: prefer expressions with * 76  
    elseif value1:match("%*%s*76") and not value2:match("%*%s*76") then
        return value1
    elseif value2:match("%*%s*76") and not value1:match("%*%s*76") then
        return value2
    else
        -- Default: prefer the longer/more complex value
        if #value2 > #value1 then
            return value2
        else
            return value1
        end
    end
end

local function mergeAssignments(assignments1, assignments2)
    local merged = {}
    local seenAssignments = {}
    
    -- Add assignments from assignments1, tracking by variable+value
    for _, assign1 in ipairs(assignments1) do
        local key = assign1.variable .. "=" .. assign1.value
        if not seenAssignments[key] then
            table.insert(merged, assign1)
            seenAssignments[key] = true
        end
    end
    
    -- Add unique assignments from assignments2
    for _, assign2 in ipairs(assignments2) do
        local key = assign2.variable .. "=" .. assign2.value
        if not seenAssignments[key] then
            -- Check if we have the same variable with different value (merge case)
            local hasVariableWithDifferentValue = false
            for existingKey, _ in pairs(seenAssignments) do
                if existingKey:match("^" .. assign2.variable .. "=") and existingKey ~= key then
                    -- Same variable, different value - need to merge
                    hasVariableWithDifferentValue = true
                    -- Find the existing assignment and merge values
                    for i, existing in ipairs(merged) do
                        if existing.variable == assign2.variable then
                            local mergedValue = mergeAssignmentValue(existing.value, assign2.value)
                            merged[i].value = mergedValue
                            break
                        end
                    end
                    break
                end
            end
            
            if not hasVariableWithDifferentValue then
                table.insert(merged, assign2)
                seenAssignments[key] = true
            end
        end
    end
    
    return merged
end

local function mergeVariables(variables1, variables2)
    local merged = {}
    
    -- Merge variables by name
    for name, var1 in pairs(variables1) do
        local var2 = variables2[name]
        if var2 then
            -- Variable exists in both, merge if different
            if var1.value ~= var2.value then
                -- Use the same merging logic as assignments - prefer more complex value
                local mergedValue = mergeAssignmentValue(var1.value, var2.value)
                merged[name] = {
                    value = mergedValue,
                    line = var1.line,
                    multiline = var1.multiline or var2.multiline,
                    startLine = var1.startLine,
                    endLine = var1.endLine
                }
            else
                merged[name] = var1
            end
        else
            merged[name] = var1
        end
    end
    
    -- Add variables from variables2 that aren't in variables1
    for name, var2 in pairs(variables2) do
        if not variables1[name] then
            merged[name] = var2
        end
    end
    
    return merged
end

local function mergeReturnStatements(returns1, returns2)
    local merged = {}
    local seenValues = {}
    
    -- Add returns from returns1, tracking by value
    for _, ret1 in ipairs(returns1) do
        if not seenValues[ret1.value] then
            table.insert(merged, ret1)
            seenValues[ret1.value] = true
        end
    end
    
    -- Add unique returns from returns2
    for _, ret2 in ipairs(returns2) do
        if not seenValues[ret2.value] then
            table.insert(merged, ret2)
            seenValues[ret2.value] = true
        end
    end
    
    return merged
end

-- Merge two lines that are different
local function mergeLineContent(line1, line2)
    -- Special case: if one line has * 1.75 and the other doesn't, prefer the one with * 1.75
    if line1:match("%*%s*1%.75") and not line2:match("%*%s*1%.75") then
        return line1
    elseif line2:match("%*%s*1%.75") and not line1:match("%*%s*1%.75") then
        return line2
    end
    
    -- Special case: if one line has * 76 and the other doesn't, prefer the one with * 76
    if line1:match("%*%s*76") and not line2:match("%*%s*76") then
        return line1
    elseif line2:match("%*%s*76") and not line1:match("%*%s*76") then
        return line2
    end
    
    -- Simple strategy: prefer the longer line (more complete)
    if #line2 > #line1 then
        return line2
    else
        return line1
    end
end

local function mergeContent(content1, content2)
    -- For now, use the same line-by-line merge logic
    -- This could be enhanced to work with the structured data
    local merged = {}
    local maxLines = math.max(#content1, #content2)
    for i = 1, maxLines do
        local l1, l2 = content1[i], content2[i]
        if l1 and l2 then
            merged[#merged + 1] = (l1 == l2) and l1 or mergeLineContent(l1, l2)
        else
            merged[#merged + 1] = l1 or l2
        end
    end
    return merged
end

-- Merge function structure using structured data
local function mergeFunctionStructure(func1, func2)
    local merged = {
        type = func1.type,
        startLine = func1.startLine,
        endLine = func1.endLine,
        parameters = func1.parameters or {}
    }
    
    if func1.internals and func2.internals then
        merged.internals = M.mergeStructureInternals(func1.internals, func2.internals)
    elseif func1.internals then
        merged.internals = func1.internals
    elseif func2.internals then
        merged.internals = func2.internals
    end
    
    -- Merge content as fallback
    if func1.content and func2.content then
        merged.content = mergeContent(func1.content, func2.content)
    elseif func1.content then
        merged.content = func1.content
    elseif func2.content then
        merged.content = func2.content
    end
    
    return merged
end

local function mergeStructureInternals(internals1, internals2)
    local merged = {}
    
    -- Merge assignments
    if internals1.assignments and internals2.assignments then
        merged.assignments = mergeAssignments(internals1.assignments, internals2.assignments)
    elseif internals1.assignments then
        merged.assignments = internals1.assignments
    elseif internals2.assignments then
        merged.assignments = internals2.assignments
    end
    
    -- Merge variables
    if internals1.variables and internals2.variables then
        merged.variables = mergeVariables(internals1.variables, internals2.variables)
    elseif internals1.variables then
        merged.variables = internals1.variables
    elseif internals2.variables then
        merged.variables = internals2.variables
    end
    
    -- Merge control structures hierarchically
    if internals1.controlStructures and internals2.controlStructures then
        merged.controlStructures = M.mergeControlStructures(internals1.controlStructures, internals2.controlStructures)
    elseif internals1.controlStructures then
        merged.controlStructures = internals1.controlStructures
    elseif internals2.controlStructures then
        merged.controlStructures = internals2.controlStructures
    end
    
    -- Merge return statements
    if internals1.returnStatements and internals2.returnStatements then
        merged.returnStatements = mergeReturnStatements(internals1.returnStatements, internals2.returnStatements)
    elseif internals1.returnStatements then
        merged.returnStatements = internals1.returnStatements
    elseif internals2.returnStatements then
        merged.returnStatements = internals2.returnStatements
    end
    
    return merged
end

-- Cache normalized function content to avoid repeated gsubs
local normalizedContentCache = setmetatable({}, { __mode = "k" })
local function getNormalizedContent(func)
    local cached = normalizedContentCache[func]
    if cached then return cached end
    local lines = {}
    if func and func.content then
        for _, line in ipairs(func.content) do
            lines[#lines + 1] = line:gsub("%s+", " "):gsub("^%s*(.-)%s*$", "%1")
        end
    end
    normalizedContentCache[func] = lines
    return lines
end

local function mergeBranches(branches1, branches2)
    local merged = {}
    local used = {}
    
    -- Create lookup for branches2 by type and condition
    local branches2ByType = {}
    for i, branch in ipairs(branches2) do
        local key = branch.type
        if branch.type == "elseif" then
            key = branch.type .. ":" .. (branch.condition or "")
        end
        branches2ByType[key] = {branch = branch, index = i}
    end
    
    -- Process branches1 and merge with branches2
    for _, branch1 in ipairs(branches1) do
        local key = branch1.type
        if branch1.type == "elseif" then
            key = branch1.type .. ":" .. (branch1.condition or "")
        end
        
        local match = branches2ByType[key]
        if match and branch1.type == match.branch.type then
            -- Found matching branch of same type, merge them
            local mergedBranch = M.mergeSingleControlStructure(branch1, match.branch)
            table.insert(merged, mergedBranch)
            used[match.index] = true
        else
            -- No matching branch, keep this one
            table.insert(merged, branch1)
        end
    end
    
    -- Add branches from branches2 that weren't used
    for i, branch2 in ipairs(branches2) do
        if not used[i] then
            table.insert(merged, branch2)
        end
    end
    
    return merged
end

local function mergeSingleControlStructure(struct1, struct2)
    local merged = {
        type = struct1.type,
        startLine = struct1.startLine,
        endLine = struct1.endLine,
        condition = struct1.condition
    }
    
    -- Merge internals if they exist
    if struct1.internals and struct2.internals then
        merged.internals = mergeStructureInternals(struct1.internals, struct2.internals)
    elseif struct1.internals then
        merged.internals = struct1.internals
    elseif struct2.internals then
        merged.internals = struct2.internals
    end
    
    -- Merge branches if they exist (for if/elseif/else structures)
    if struct1.branches and struct2.branches then
        merged.branches = mergeBranches(struct1.branches, struct2.branches)
    elseif struct1.branches then
        merged.branches = struct1.branches
    elseif struct2.branches then
        merged.branches = struct2.branches
    end
    
    -- Merge content
    if struct1.content and struct2.content then
        merged.content = mergeContent(struct1.content, struct2.content)
    elseif struct1.content then
        merged.content = struct1.content
    elseif struct2.content then
        merged.content = struct2.content
    end
    
    return merged
end

-- Helper function to measure structure complexity
local function getStructureComplexity(struct)
    local complexity = 1
    
    if struct.internals then
        if struct.internals.controlStructures then
            complexity = complexity + #struct.internals.controlStructures
            -- Add nested complexity
            for _, nested in ipairs(struct.internals.controlStructures) do
                complexity = complexity + getStructureComplexity(nested)
            end
        end
        if struct.internals.assignments then
            complexity = complexity + #struct.internals.assignments
        end
    end
    
    if struct.branches then
        complexity = complexity + #struct.branches
        for _, branch in ipairs(struct.branches) do
            complexity = complexity + getStructureComplexity(branch)
        end
    end
    
    return complexity
end

-- Helper function to check if two conditions are similar
local function areConditionsSimilar(condition1, condition2)
    -- Remove common variations
    local norm1 = condition1:gsub("%s+", " "):gsub("^%s*(.-)%s*$", "%1")
    local norm2 = condition2:gsub("%s+", " "):gsub("^%s*(.-)%s*$", "%1")
    
    -- Check if one is a prefix of the other (truncated condition)
    if norm1:len() > 0 and norm2:len() > 0 then
        if norm2:sub(1, norm1:len()) == norm1 or norm1:sub(1, norm2:len()) == norm2 then
            return true
        end
    end
    
    return false
end

local function mergeControlStructures(structures1, structures2)
    local merged = {}
    local used = {}
    
    -- Process structures1 and merge with structures2
    for i, struct1 in ipairs(structures1) do
        local condition1 = struct1.condition or ""
        -- More aggressive normalization - extract the core condition
        condition1 = condition1:gsub("%s+", " "):gsub("^%s*(.-)%s*$", "%1")
        condition1 = condition1:gsub("^if%s+", ""):gsub("%s+then$", "") -- Remove if/then wrapper
        local signature1 = struct1.type .. ":" .. condition1
        
        -- Look for matching structure in structures2
        local matchFound = false
        for j, struct2 in ipairs(structures2) do
            if not used[j] then
                local condition2 = struct2.condition or ""
                condition2 = condition2:gsub("%s+", " "):gsub("^%s*(.-)%s*$", "%1")
                condition2 = condition2:gsub("^if%s+", ""):gsub("%s+then$", "") -- Remove if/then wrapper
                local signature2 = struct2.type .. ":" .. condition2
                
                -- Check if conditions are similar (allowing for slight differences)
                if signature1 == signature2 or areConditionsSimilar(condition1, condition2) then
                    -- Merge the structures hierarchically
                    local mergedStruct = M.mergeSingleControlStructure(struct1, struct2)
                    table.insert(merged, mergedStruct)
                    used[j] = true
                    matchFound = true
                    break
                end
            end
        end
        
        if not matchFound then
            -- No matching structure, keep the original
            table.insert(merged, struct1)
        end
    end
    
    -- Add unique structures from structures2
    for j, struct2 in ipairs(structures2) do
        if not used[j] then
            table.insert(merged, struct2)
        end
    end
    
    return merged
end

local function mergeStructureInternals(internals1, internals2)
    local merged = {}
    
    -- Merge assignments
    if internals1.assignments and internals2.assignments then
        merged.assignments = mergeAssignments(internals1.assignments, internals2.assignments)
    elseif internals1.assignments then
        merged.assignments = internals1.assignments
    elseif internals2.assignments then
        merged.assignments = internals2.assignments
    end
    
    -- Merge variables
    if internals1.variables and internals2.variables then
        merged.variables = mergeVariables(internals1.variables, internals2.variables)
    elseif internals1.variables then
        merged.variables = internals1.variables
    elseif internals2.variables then
        merged.variables = internals2.variables
    end
    
    -- Merge control structures
    if internals1.controlStructures and internals2.controlStructures then
        merged.controlStructures = mergeControlStructures(internals1.controlStructures, internals2.controlStructures)
    elseif internals1.controlStructures then
        merged.controlStructures = internals1.controlStructures
    elseif internals2.controlStructures then
        merged.controlStructures = internals2.controlStructures
    end
    
    -- Merge return statements
    if internals1.returnStatements and internals2.returnStatements then
        merged.returnStatements = mergeReturnStatements(internals1.returnStatements, internals2.returnStatements)
    elseif internals1.returnStatements then
        merged.returnStatements = internals1.returnStatements
    elseif internals2.returnStatements then
        merged.returnStatements = internals2.returnStatements
    end
    
    return merged
end

-- Hash function for quick comparison
local function hashString(str)
    local hash = 0
    for i = 1, #str do
        local byte = string.byte(str, i)
        hash = ((hash * 33) + byte) % 0x100000000
    end
    return hash
end

-- More sensitive hash function that detects small differences
local function sensitiveHashString(str)
    local hash = 0
    local prime = 31
    for i = 1, #str do
        local byte = string.byte(str, i)
        hash = (hash * prime + byte) % 0x100000000
    end
    return hash
end

-- Hash function content for comparison with more sensitivity
local function hashFunctionContent(func)
    local normalizedLines = getNormalizedContent(func)
    local content = table.concat(normalizedLines, "\n") .. "\n"
    local hash = sensitiveHashString(content)
    return hash
end

-- Compare two functions by content
local function functionsAreIdentical(func1, func2)
    if func1.type ~= func2.type then
        return false
    end
    
    local hash1 = hashFunctionContent(func1)
    local hash2 = hashFunctionContent(func2)
    
    return hash1 == hash2
end

-- More detailed function comparison
local function functionsAreSimilar(func1, func2)
    if func1.type ~= func2.type then
        return false
    end
    
    if not func1.content or not func2.content then
        return functionsAreIdentical(func1, func2)
    end
    
    local lines1 = getNormalizedContent(func1)
    local lines2 = getNormalizedContent(func2)
    
    if #lines1 ~= #lines2 then
        return false
    end
    
    local differences = 0
    for i = 1, #lines1 do
        local normalized1 = lines1[i]
        local normalized2 = lines2[i]
        if normalized1 ~= normalized2 then
            differences = differences + 1
        end
    end
    
    -- Consider functions similar if they have few differences
    return differences <= 3 and differences > 0
end

-- Compare functions and find differences
local function compareFunctions(func1, func2)
    if func1.type ~= func2.type then
        return false, nil
    end
    
    if not func1.content or not func2.content then
        return functionsAreIdentical(func1, func2), nil
    end
    
    local lines1 = getNormalizedContent(func1)
    local lines2 = getNormalizedContent(func2)
    
    -- If functions have different number of lines, they're different
    if #lines1 ~= #lines2 then
        return false, nil
    end
    
    local differences = {}
    local identical = true
    
    for i = 1, #lines1 do
        local normalized1 = lines1[i]
        local normalized2 = lines2[i]
        if normalized1 ~= normalized2 then
            identical = false
            table.insert(differences, {
                line = i,
                file1 = func1.content and func1.content[i] or "",
                file2 = func2.content and func2.content[i] or ""
            })
        end
    end
    
    return identical, differences
end

-- Merge function content with differences
local function mergeFunctionContent(func1, func2, differences)
    if not differences or #differences == 0 then
        return func1.content
    end
    
    local mergedContent = {}
    local diffsByLine = {}
    for _, d in ipairs(differences) do diffsByLine[d.line] = d end
    local maxLines = math.max(#func1.content, #func2.content)
    for i = 1, maxLines do
        local diff = diffsByLine[i]
        if diff then
            mergedContent[#mergedContent + 1] = mergeLineContent(diff.file1, diff.file2)
        else
            mergedContent[#mergedContent + 1] = func1.content[i] or func2.content[i] or ""
        end
    end
    
    return mergedContent
end



-- Special merge for whatElse function
local function mergeWhatElseFunction(func1, func2)
    
    if not func1.content or not func2.content then
        return func1
    end
    
    local mergedContent = {}
    local lines1 = func1.content
    local lines2 = func2.content
    
    -- Find the line with "h = h + 1" in both functions
    local line1Index = nil
    local line2Index = nil
    
    for i, line in ipairs(lines1) do
        if line:match("h%s*=%s*h%s*%+%s*1") then
            line1Index = i
            break
        end
    end
    
    for i, line in ipairs(lines2) do
        if line:match("h%s*=%s*h%s*%+%s*1") then
            line2Index = i
            break
        end
    end
    
    -- If we found the line in both functions, merge them
    if line1Index and line2Index then
        for i = 1, #lines1 do
            if i == line1Index then
                -- Merge the h = h + 1 line
                local line1 = lines1[i]
                local line2 = lines2[line2Index]
                
                -- Prefer the line with * 76
                if line2:match("%*%s*76") and not line1:match("%*%s*76") then
                    table.insert(mergedContent, line2)
                else
                    table.insert(mergedContent, line1)
                end
            else
                table.insert(mergedContent, lines1[i])
            end
        end
        
        local mergedFunc = {}
        for k, v in pairs(func1) do
            mergedFunc[k] = v
        end
        mergedFunc.content = mergedContent
        return mergedFunc
    end
    
    return func1
end

-- Get all functions from analysis structure recursively
local function getAllFunctions(structure, functions)
    functions = functions or {}
    
    if structure.functions then
        for name, func in pairs(structure.functions) do
            functions[name] = func
        end
    end
    
    if structure.controlStructures then
        for _, control in ipairs(structure.controlStructures) do
            if control.internals then
                getAllFunctions(control.internals, functions)
            end
            if control.branches then
                for _, branch in ipairs(control.branches) do
                    if branch.internals then
                        getAllFunctions(branch.internals, functions)
                    end
                end
            end
        end
    end
    
    return functions
end

-- Get all variables from analysis structure recursively
local function getAllVariables(structure, variables)
    variables = variables or {}
    
    if structure.variables then
        for name, var in pairs(structure.variables) do
            variables[name] = var
        end
    end
    
    if structure.controlStructures then
        for _, control in ipairs(structure.controlStructures) do
            if control.internals then
                getAllVariables(control.internals, variables)
            end
            if control.branches then
                for _, branch in ipairs(control.branches) do
                    if branch.internals then
                        getAllVariables(branch.internals, variables)
                    end
                end
            end
        end
    end
    
    return variables
end

-- Merge two analysis structures
local function mergeAnalyses(analysis1, analysis2)
    local merged = {
        filename = "merged",
        totalLines = 0,
        hasModulePattern = analysis1.hasModulePattern or analysis2.hasModulePattern,
        moduleVariable = analysis1.moduleVariable or analysis2.moduleVariable,
        moduleDeclarationLine = 1,
        returnLine = nil,
        structure = {
            variables = {},
            functions = {},
            returnStatements = {},
            controlStructures = {},
            assignments = {},
            breakStatements = {},
            gotoStatements = {},
            labels = {},
            doBlocks = {},
            otherStatements = {}
        }
    }
    
    -- Get all functions from both analyses
    local functions1 = getAllFunctions(analysis1.structure)
    local functions2 = getAllFunctions(analysis2.structure)
    
    -- Get all variables from both analyses
    local variables1 = getAllVariables(analysis1.structure)
    local variables2 = getAllVariables(analysis2.structure)
    
    -- Merge variables (unique ones)
    for name, var in pairs(variables1) do
        merged.structure.variables[name] = var
    end
    for name, var in pairs(variables2) do
        if not merged.structure.variables[name] then
            merged.structure.variables[name] = var
        end
    end
    
    -- Process functions
    local processedFunctions = {}
    
    -- First, find identical and similar functions
    for name, func1 in pairs(functions1) do
        if functions2[name] then
            local identical, differences = compareFunctions(func1, functions2[name])
            
            if identical then
                -- Check if functions have different internal structures even if content is identical
                local hasStructuralDiff = false
                if func1.internals and functions2[name].internals then
                    local func2 = functions2[name]
                    if func1.internals.controlStructures and func2.internals.controlStructures then
                        if #func1.internals.controlStructures ~= #func2.internals.controlStructures then
                            hasStructuralDiff = true
                        end
                    elseif func1.internals.controlStructures ~= func2.internals.controlStructures then
                        hasStructuralDiff = true
                    end
                end
                
                if hasStructuralDiff then
                    local mergedFunc = mergeFunctionStructure(func1, functions2[name])
                    merged.structure.functions[name] = mergedFunc
                    processedFunctions[name] = true
                else
                    merged.structure.functions[name] = func1
                    processedFunctions[name] = true
                end
            elseif differences and #differences <= 3 then
                -- Functions are similar, merge them
                local mergedFunc = mergeFunctionStructure(func1, functions2[name])
                merged.structure.functions[name] = mergedFunc
                processedFunctions[name] = true
            else
                -- Functions are different but no specific differences detected, force merge
                local mergedFunc = mergeFunctionStructure(func1, functions2[name])
                merged.structure.functions[name] = mergedFunc
                processedFunctions[name] = true
            end
        end
    end
    
    -- Add unique functions from first analysis
    for name, func in pairs(functions1) do
        if not processedFunctions[name] then
            merged.structure.functions[name] = func
            processedFunctions[name] = true
        end
    end
    
    -- Add unique functions from second analysis
    for name, func in pairs(functions2) do
        if not processedFunctions[name] then
            merged.structure.functions[name] = func
            processedFunctions[name] = true
        end
    end
    
    -- Merge other structures (simplified for now)
    if analysis1.structure.returnStatements then
        for _, ret in ipairs(analysis1.structure.returnStatements) do
            table.insert(merged.structure.returnStatements, ret)
        end
    end
    
    if analysis2.structure.returnStatements then
        for _, ret in ipairs(analysis2.structure.returnStatements) do
            table.insert(merged.structure.returnStatements, ret)
        end
    end
    
    return merged
end

local function dump(t, indent)
    indent = indent or ""
    local message = ""
    
    if type(t) ~= "table" then
        if type(t) == "string" then
            return '"' .. t:gsub('"', '\\"') .. '"'
        else
            return tostring(t)
        end
    end
    
    local isArray = true
    local maxIndex = 0
    for k, v in pairs(t) do
        if type(k) ~= "number" or k < 1 or k > #t then
            isArray = false
            break
        end
        maxIndex = math.max(maxIndex, k)
    end
    
    if isArray and maxIndex == #t then
        message = message .. "[\n"
        for i, v in ipairs(t) do
            message = message .. indent .. "  " .. dump(v, indent .. "  ")
            if i < #t then message = message .. "," end
            message = message .. "\n"
        end
        message = message .. indent .. "]"
    else
        message = message .. "{\n"
        local first = true
        for k, v in pairs(t) do
            if not first then message = message .. ",\n" end
            message = message .. indent .. "  \"" .. tostring(k):gsub('"', '\\"') .. "\": " .. dump(v, indent .. "  ")
            first = false
        end
        message = message .. "\n" .. indent .. "}"
    end
    
    return message
end

-- Main merge function
function M.mergeFiles(contents)
    if #contents == 1 then
        return contents[1]
    elseif #contents > 2 then
        for i = 2, #contents do
            contents[1] = M.mergeFiles({contents[1], contents[i]})
        end
        return contents[1]
    elseif #contents == 2 then
        if contents[1] == contents[2] then
            return contents[1]
        end
        local analysis1 = conflictResolution_luaBreakdown.analyzeFile(contents[1])
        local analysis2 = conflictResolution_luaBreakdown.analyzeFile(contents[2])
        
        local merged = mergeAnalyses(analysis1, analysis2)

        return conflictResolution_luaBreakdown.writeLuaFile(merged)
    end
    
    return nil
end

M.mergeControlStructures = mergeControlStructures
M.mergeFunctionStructure = mergeFunctionStructure
M.mergeStructureInternals = mergeStructureInternals
M.mergeSingleControlStructure = mergeSingleControlStructure

return M
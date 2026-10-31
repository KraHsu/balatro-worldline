-- English source strings are stable compatibility keys. Unknown technical
-- diagnostics are returned verbatim; no global locale or game data is changed.
local function catalog_data(name)
    if SMODS and SMODS.load_file then
        return assert(SMODS.load_file('localization/' .. name .. '.lua', 'WorldLine'))()
    end
    return dofile('src/localization/' .. name .. '.lua')
end
local data = catalog_data('catalog')
for _,name in ipairs({'extra','film','film_export','film_controls','undo'}) do
local extra = catalog_data(name)
for locale, entries in pairs(extra.catalog) do
    assert(data.catalog[locale], 'Unsupported Worldline locale: ' .. locale)
    for key, value in pairs(entries) do
        assert(not data.catalog[locale][key], 'Duplicate Worldline translation: ' .. key)
        data.catalog[locale][key] = value
    end
end
end
local I18n = {locales = data.locales, catalog = data.catalog, supported = {}, keys = {}}
for _, locale in ipairs(I18n.locales) do I18n.supported[locale] = true end
for key in pairs(I18n.catalog['en-us']) do I18n.keys[#I18n.keys + 1] = key end
table.sort(I18n.keys)

local locale_aliases = {
    ['en'] = 'en-us', ['en_us'] = 'en-us', ['en-us'] = 'en-us',
    ['all'] = 'en-us', ['all1'] = 'en-us', ['all2'] = 'en-us',
    ['zh'] = 'zh_CN', ['zh-cn'] = 'zh_CN', ['zh_cn'] = 'zh_CN', ['zh-hans'] = 'zh_CN',
    ['zh-tw'] = 'zh_TW', ['zh_tw'] = 'zh_TW', ['zh-hant'] = 'zh_TW',
    ['pt'] = 'pt_BR', ['pt-br'] = 'pt_BR', ['pt_br'] = 'pt_BR',
    ['es'] = 'es_ES', ['es-es'] = 'es_ES', ['es_es'] = 'es_ES',
    ['es-419'] = 'es_419', ['es_419'] = 'es_419', ['es-mx'] = 'es_419',
}
function I18n.normalize(locale)
    if I18n.supported[locale] then return locale end
    local lower = tostring(locale or ''):lower()
    return locale_aliases[lower] or I18n.supported[lower] and lower or 'en-us'
end

local aliases = {
    ['WORLDLINE'] = 'Worldline', ['BALATRO TREE'] = 'Worldline', ['Balatro Tree'] = 'Worldline',
    ['Decision tree / F6'] = 'Worldline / F6', ['Decision tree (F6)'] = 'Worldline (F6)',
    ['Local trees'] = 'Local worldlines', ['No saved trees yet'] = 'No saved worldlines yet',
    ['No decision tree yet'] = 'No worldline yet', ['Tree saved'] = 'Worldline saved',
    ['Decision tree saved'] = 'Worldline saved', ['Recording decisions'] = 'Recording worldline',
    ['Other trees are still unsaved; retrying'] = 'Other worldlines are still unsaved; retrying',
    ['The tree will open when this action finishes'] = 'The worldline will open when this action finishes',
    ['Incompatible Tree archive version: '] = 'Incompatible worldline archive version: ',
    ['Returned to node #'] = 'Worldline converged · #',
    ['Returning to checkpoint'] = 'Converging worldline',
    ['Returning to checkpoint…'] = 'Converging worldline',
    ['Converging worldline…'] = 'Converging worldline',
    ['Loading share'] = 'Loading worldline', ['RETURN HERE'] = 'CONVERGE HERE',
    ['Existing branches are preserved'] = 'Existing worldlines are preserved',
    ['RUN ENDED'] = 'WORLDLINE ENDED', ['Branch ended'] = 'WORLDLINE ENDED',
    ['NODE #'] = 'POINT #', ['Convergence point #'] = 'POINT #',
    ['Start a seeded run to grow your tree'] = 'Start a run to record its worldline',
    ['No action to undo'] = 'There is no action to undo yet',
    ['Undoing last action…'] = 'Undoing the last action',
    ['Start'] = 'START',
    ['Wait for the current action to finish'] = 'Wait for the current action',
    ['Record worldlines, explore choices, or undo the last action.'] =
        'Record worldlines, explore perturbations, and undo the last action.',
    ['Cannot create tree data directory'] = 'Cannot create worldline data directory',
    ['Cannot read tree file'] = 'Cannot read worldline file',
    ['Invalid tree data'] = 'Invalid worldline data', ['Invalid decision tree'] = 'Invalid worldline',
    ['Unrecognized Balatro Tree file'] = 'Unrecognized Worldline file',
    ['Unrecognized worldline file'] = 'Unrecognized Worldline file',
    ['Tree file exceeds 128 MiB'] = 'Worldline file exceeds 128 MiB',
    ['Cannot write tree archive'] = 'Cannot write worldline archive',
    ['Cannot write shared tree'] = 'Cannot write shared worldline',
    ['Cannot read shared tree'] = 'Cannot read shared worldline',
    ['Tree file exceeds 128 MiB or is not text'] = 'Worldline file exceeds 128 MiB or is not text',
    ['Checkpoint not found'] = 'Convergence point not found',
    ['Tree drawing failed: '] = 'Worldline drawing failed: ',
    ['Checkpoint capture failed: '] = 'Worldline capture failed: ',
}
I18n.aliases = aliases

local function lookup(locale, key)
    local canonical = aliases[key] or key
    local value = I18n.catalog[locale][canonical] or I18n.catalog['en-us'][canonical]
    if key == 'WORLDLINE' and locale == 'en-us' then return 'WORLDLINE' end
    return value
end

function I18n.get(locale, key, vars)
    locale, key = I18n.normalize(locale), tostring(key or '')
    local value = lookup(locale, key) or key
    if vars then
        value = value:gsub('{([%w_]+)}', function(name)
            return vars[name] ~= nil and tostring(vars[name]) or '{' .. name .. '}'
        end)
    end
    return value
end

function I18n.error(locale, message)
    if message == nil then return nil end
    local value = tostring(message)
    locale = I18n.normalize(locale)
    local translated = lookup(locale, value)
    if translated then return translated end
    -- These are expected user-input validation failures raised through assert.
    -- Preserve paths and traces for every other exception.
    for _, key in ipairs({
        "This legacy region has no end point; choose two endpoints to fold a linear sequence.",
        "The end point must be a later descendant of the start point.",
        "A folded sequence needs at least one intermediate point.",
        "A branch occurs inside this sequence; keep every branch point visible.",
        "This sequence overlaps another collapsed region; expand that region first.",
        'Name must contain 1 to 64 characters',
        'Choose a later descendant with an intermediate node',
        'This node has no descendants to fold',
        'Bookmark limit reached', 'Folded region limit reached', 'Folded region not found',
    }) do
        if value:sub(-#key) == key and value:sub(-#key - 2, -#key - 1) == ': ' then
            return lookup(locale, key) or key
        end
    end
    local point, reason = value:match('^Node (%d+): (.*)$')
    if point then return (lookup(locale, 'POINT #') or 'Point #') .. point .. ': ' .. reason end
    -- Only explicitly catalogued prefixes are rewritten. Lua paths, stack
    -- traces, OS errors and unknown validation codes remain useful diagnostics.
    local best, target
    for key in pairs(I18n.catalog['en-us']) do
        if key:sub(-2) == ': ' and value:sub(1, #key) == key and (not best or #key > #best) then
            best, target = key, key
        end
    end
    for key, canonical in pairs(aliases) do
        if key:sub(-2) == ': ' and value:sub(1, #key) == key and (not best or #key > #best) then
            best, target = key, canonical
        end
    end
    if best then return (lookup(locale, target) or target) .. value:sub(#best + 1) end
    return value
end

function I18n.text(locale, _, english)
    return I18n.error(locale, english or '')
end

return I18n

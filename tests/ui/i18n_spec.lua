local previous_smods = SMODS
SMODS = nil
local I18n = dofile('src/ui/i18n.lua')
SMODS = previous_smods
local expected = {'en-us', 'de', 'es_419', 'es_ES', 'fr', 'id', 'it', 'ja', 'ko',
    'nl', 'pl', 'pt_BR', 'ru', 'zh_CN', 'zh_TW'}
assert(#I18n.locales == #expected)
local keys = {}
for _, key in ipairs(I18n.keys) do assert(not keys[key]); keys[key] = true end
assert(#I18n.keys >= 100, 'the complete catalog includes UI, statuses, action labels and known errors')
for _, locale in ipairs(expected) do
    assert(I18n.supported[locale], 'missing native locale ' .. locale)
    local count = 0
    for key, value in pairs(I18n.catalog[locale]) do
        count = count + 1
        assert(keys[key] and type(value) == 'string' and #value > 0, locale .. ': invalid translation ' .. key)
        assert(not value:find('TODO', 1, true) and not value:find('TRANSLATE', 1, true))
    end
    assert(count == #I18n.keys, locale .. ': catalog is incomplete')
    for _, key in ipairs(I18n.keys) do
        assert(I18n.catalog[locale][key], locale .. ': implicit English fallback for ' .. key)
    end
    if locale ~= 'zh_CN' and locale ~= 'zh_TW' and locale ~= 'ja' and locale ~= 'ko' and locale ~= 'ru' then
        for _, value in pairs(I18n.catalog[locale]) do
            assert(not value:find('’', 1, true) and not value:find('·', 1, true),
                'Punctuation unsupported by native m6x11plus font: ' .. value)
        end
    end
end
for alias, canonical in pairs(I18n.aliases) do
    assert(keys[canonical], 'alias target has no translation: ' .. alias .. ' -> ' .. canonical)
end

assert(I18n.text('zh_CN', 'ignored', 'Worldline') == '世界线')
assert(I18n.text('zh_TW', 'ignored', 'Worldline') == '世界線')
assert(I18n.text('ja', nil, 'Worldline') == '世界線')
assert(I18n.text('ko', nil, 'Worldline') == '세계선')
assert(I18n.text('zh_CN', nil, 'Worldline converged') == '世界线收束')
assert(I18n.text('zh_CN', nil, 'Worldline perturbed') == '世界线扰动')
assert(I18n.text('zh_CN', nil, 'Convergence point') == '收束点')
for _, locale in ipairs(expected) do
    for _, key in ipairs({'Continue undoing?',
        'Continuing Undo makes this a seeded run. Achievements and new discoveries will be disabled.',
        'Existing worldlines stay intact. Different choices can create new perturbations.',
        'Press Ctrl+Z again within 2 seconds to confirm, or Esc to cancel.', 'Continue Undo', 'Cancel'}) do
        assert(I18n.catalog[locale][key], 'missing continuous-Undo confirmation in ' .. locale)
    end
    assert(I18n.text(locale, nil, 'Press Ctrl+Z again within 2 seconds to confirm, or Esc to cancel.'):find('2', 1, true),
        'every translated confirmation must communicate the two-second deadline')
end
assert(I18n.text('zh_CN', nil, 'Continuing Undo makes this a seeded run. Achievements and new discoveries will be disabled.')
    == '如果继续撤回，本局将按固定种子局处理，后续无法获得成就或新发现。')
assert(I18n.text('zh_CN', nil, 'Existing worldlines stay intact. Different choices can create new perturbations.')
    == '已有世界线会保留，改变选择可产生新的扰动。')
assert(I18n.text('en-us', nil, 'WORLDLINE') == 'WORLDLINE')
assert(I18n.text('zh_CN', nil, 'WORLDLINE') == '世界线')
assert(I18n.text('zh_CN', nil, 'Decision tree saved') == '世界线已保存')
assert(I18n.text('fr', nil, 'No saved trees yet') == I18n.text('fr', nil, 'No saved worldlines yet'))
assert(I18n.normalize('zh-cn') == 'zh_CN' and I18n.normalize('zh-Hant') == 'zh_TW')
assert(I18n.normalize('pt-br') == 'pt_BR' and I18n.normalize('es-419') == 'es_419')
assert(I18n.normalize('all1') == 'en-us' and I18n.normalize('all2') == 'en-us')
assert(I18n.text('unsupported-locale', nil, 'Worldline saved') == 'Worldline saved')
assert(I18n.text('fr', '未知文案', 'Unknown future message') == 'Unknown future message')
assert(I18n.text('zh_CN', '未知文案', 'Unknown future message') == 'Unknown future message')
assert(I18n.text('fr', nil, nil) == '' and I18n.error('fr', nil) == nil)
assert(I18n.error('fr', false) == 'false')
assert(I18n.get('fr', 'id={id} path={path}', {id = 12, path = '50%/data'}) == 'id=12 path=50%/data')

local raw = [[D:\test\game.lua:51: attempt to index field 'missing' (a nil value)]]
assert(I18n.error('zh_CN', raw) == raw, 'unknown Lua errors must remain exact diagnostics')
local tail = [[D:\test\renderer.lua:8: unexpected GPU error]]
local wrapped = I18n.error('fr', 'Tree drawing failed: ' .. tail)
assert(wrapped ~= 'Tree drawing failed: ' .. tail and wrapped:sub(-#tail) == tail,
    'translate known context while preserving the complete technical cause')
assert(I18n.error('fr', wrapped) == wrapped, 'localized errors are not translated twice')
local node = I18n.error('zh_CN', 'Node 42: invalid_snapshot_data')
assert(node:find('收束点', 1, true) and node:find('42', 1, true)
    and node:sub(-#'invalid_snapshot_data') == 'invalid_snapshot_data')
assert(I18n.error('zh_CN', 'Tree file exceeds 128 MiB') == '世界线文件超过 128 MiB')
for _, value in pairs(I18n.catalog.zh_TW) do
    for _, char in ipairs({'线','录','扰','动','设','载','读','档','输','选','闭','赌','币','绘','图','刚','继','试','随','败'}) do
        assert(not value:find(char, 1, true), 'Simplified character in Traditional Chinese: ' .. value)
    end
end

-- Tokenize only our own source files. Matching literal text calls catches a new
-- UI message that would otherwise silently fall back to English in every locale.
local function tokens(source)
    local result, i = {}, 1
    while i <= #source do
        local c, pair = source:sub(i, i), source:sub(i, i + 1)
        if pair == '--' then
            if source:sub(i + 2, i + 3) == '[[' then
                i = (source:find(']]', i + 4, true) or #source - 1) + 2
            else i = source:find('\n', i + 2, true) or #source + 1 end
        elseif c == '"' or c == "'" then
            local start, quote = i, c
            i = i + 1
            while i <= #source do
                if source:sub(i, i) == '\\' then i = i + 2
                elseif source:sub(i, i) == quote then i = i + 1; break
                else i = i + 1 end
            end
            local literal = source:sub(start, i - 1)
            result[#result + 1] = {kind = 'string', value = assert(loadstring('return ' .. literal))()}
        elseif c:match('[%a_]') then
            local word = source:match('^[%a_][%w_]*', i)
            result[#result + 1] = {kind = 'word', value = word}; i = i + #word
        elseif c:match('%s') then i = i + 1
        else result[#result + 1] = {kind = 'symbol', value = c}; i = i + 1 end
    end
    return result
end
local checked = 0
local Loader = dofile('src/loader.lua')
for _, file in ipairs({'app', 'ui', 'renderer', 'storage'}) do
    local handle = assert(io.open('src/' .. Loader.path(file), 'rb'))
    local stream = tokens(handle:read('*a')); handle:close()
    for i, item in ipairs(stream) do
        local api_text = item.value == 'text' and stream[i - 1] and stream[i - 1].value == '.'
            and stream[i - 2] and stream[i - 2].value == 'API'
        local local_text = item.value == 'tr' or item.value == 'text'
        if (api_text or local_text) and stream[i + 1] and stream[i + 1].value == '(' then
            local first = i + 2
            if stream[first] and (stream[first].value == 'ctx' or stream[first].value == 'self')
                and stream[first + 1] and stream[first + 1].value == ',' then first = first + 2 end
            local a, comma, b = stream[first], stream[first + 1], stream[first + 2]
            if a and (a.kind == 'string' or a.value == 'nil') and comma and comma.value == ',' and b and b.kind == 'string' then
                local canonical = I18n.aliases[b.value] or b.value
                assert(keys[canonical], file .. ': untranslated English source key: ' .. b.value)
                checked = checked + 1
            end
        end
    end
end
assert(checked >= 80, 'literal text-call coverage unexpectedly missed UI sources')
for _, key in ipairs({'Play hand', 'Discard', 'Buy', 'Sell', 'Reroll shop', 'Use / open / take',
    'Skip pack', 'Select blind', 'Skip blind', 'Cash out', 'Leave shop', 'Reroll boss',
    'Open pack', 'Redeem voucher', 'Take from pack', 'Blind completed; enter shop',
    'Finish shopping; choose blind', 'Worldline capture failed: ', 'Cannot prepare Undo: ',
    'Cannot validate Undo: ', 'Cannot start recording: ', 'Invalid unfinished phase',
    'Unfinished phase: ', 'Resume seed mismatch', 'Resume parent mismatch', 'Missing restore job',
    'Node seed mismatch'}) do
    assert(keys[I18n.aliases[key] or key], 'missing action or known diagnostic: ' .. key)
end
print('PASS i18n: ' .. #I18n.keys .. ' keys in all 15 native locales; brand, aliases and raw diagnostics preserved')

assert(I18n.error('zh_CN', 'src/domain/tree.lua:114: Name must contain 1 to 64 characters') == I18n.get('zh_CN','Name must contain 1 to 64 characters'))
assert(I18n.error('zh_CN', 'src/domain/tree.lua:114: unknown failure') == 'src/domain/tree.lua:114: unknown failure')

-- Pure snapshot presentation. Native Card tooltip generation reads live G.GAME,
-- mutates Blueprint state, and allocates random DynaText for Misprint. Never call
-- it here: templates come from the active native locale, values from saved data.
local P = {}
local function localized(key, set)
    if key == nil then return '-' end
    if type(localize)=='function' then
        local ok,value=pcall(localize,tostring(key),set)
        if ok and type(value)=='string' and value~='ERROR' then return value end
    end
    return tostring(key)
end
local function description_name(set,key)
    local entries=G and G.localization and G.localization.descriptions
    local entry=entries and entries[set] and entries[set][key]
    if entry and type(entry.name)=='string' then return entry.name end
    return localized(key)
end
local function path(value, key)
    for part in key:gmatch('[^.]+') do
        if type(value)~='table' then return nil end
        value=value[part]
    end
    return value
end
local mappings={
 j_joker={'mult'},j_half={'extra.mult','extra.size'},j_green_joker={'extra.hand_add','extra.discard_sub','mult'},
 j_ceremonial={'mult'},j_juggler={'h_size'},j_drunkard={'d_size'},j_stencil={'x_mult'},
 j_mystic_summit={'extra.mult','extra.d_remaining'},j_runner={'extra.chips','extra.chip_mod'},
 j_ice_cream={'extra.chips','extra.chip_mod'},j_wee={'extra.chips','extra.chip_mod'},j_square={'extra.chips','extra.chip_mod'},
 j_rocket={'extra.dollars','extra.increase'},j_turtle_bean={'extra.h_size','extra.h_mod'},
 j_walkie_talkie={'extra.chips','extra.mult'},j_stuntman={'extra.chip_mod','extra.h_size'},
 j_merry_andy={'d_size','h_size'},j_scholar={'extra.mult','extra.chips'},j_faceless={'extra.dollars','extra.faces'},
 j_card_sharp={'extra.Xmult'},j_popcorn={'mult','extra'},j_ramen={'x_mult','extra'},
 j_invisible={'extra','invis_rounds'},j_caino={'extra','caino_xmult'},j_swashbuckler={'mult'},
 j_yorick={'extra.xmult','extra.discards','yorick_discards','x_mult'},
 m_bonus={'bonus'},m_mult={'mult'},m_steel={'h_x_mult'},m_stone={'bonus'},m_gold={'h_dollars'},
}
for _,key in ipairs({'j_ride_the_bus','j_red_card','j_flash'}) do mappings[key]={'extra','mult'} end
for _,key in ipairs({'j_constellation','j_glass','j_hit_the_road','j_madness','j_vampire','j_hologram','j_obelisk','j_lucky_cat','j_campfire','j_throwback'}) do mappings[key]={'extra','x_mult'} end
local scalar_extra={}
for key in ('j_chaos j_credit_card j_golden j_fibonacci j_scary_face j_delayed_grat j_egg j_burglar j_superposition j_rough_gem j_arrowhead j_onyx_agate j_flower_pot j_seeing_double j_matador j_riff_raff j_vagabond j_baron j_photograph j_gift j_to_the_moon j_baseball j_trading j_seltzer j_smiley j_shoot_the_moon j_triboulet j_perkeo j_banner j_even_steven j_odd_todd j_dna j_hiker j_astronomer j_golden_ticket j_acrobat j_certificate j_hanging_chad'):gmatch('%S+') do scalar_extra[key]=true end
local hand_jokers={}
for key in ('j_jolly j_zany j_mad j_crazy j_droll'):gmatch('%S+') do hand_jokers[key]='t_mult' end
for key in ('j_sly j_wily j_clever j_devious j_crafty'):gmatch('%S+') do hand_jokers[key]='t_chips' end
for key in ('j_duo j_trio j_family j_order j_tribe'):gmatch('%S+') do hand_jokers[key]='x_mult' end
function P.variables(item, summary)
    local a=item.ability or {};local c=summary and summary.tooltip_context or {};local e=type(a.extra)=='table' and a.extra or {}
    local cfg=type(a.consumeable)=='table' and a.consumeable or a
    local key=item.card_key or item.key;local v={}
    if mappings[key] then for i,p in ipairs(mappings[key]) do v[i]=path(a,p) end
    elseif scalar_extra[key] then v[1]=a.extra
    elseif key=='j_hack' or key=='j_dusk' or key=='j_sock_and_buskin' then v={type(a.extra)=='number' and a.extra+1 or nil}
    elseif key=='j_spare_trousers' then v={a.extra,localized('Two Pair','poker_hands'),a.mult}
    elseif key=='j_drivers_license' then v={a.extra,a.driver_tally or 0}
    elseif key=='j_troubadour' then v={e.h_size,type(e.h_plays)=='number' and -e.h_plays or nil}
    elseif key=='j_greedy_joker' or key=='j_lusty_joker' or key=='j_wrathful_joker' or key=='j_gluttenous_joker' then v={e.s_mult,localized(e.suit,'suits_singular')}
    -- Every native ability carries zero-valued t_mult/t_chips and an empty type.
    -- Lua treats those as true, so use the known hand-joker keys, never truthiness.
    elseif hand_jokers[key] then v={a[hand_jokers[key]],localized(a.type,'poker_hands')}
    elseif key=='j_todo_list' then v={e.dollars,localized(a.to_do_poker_hand,'poker_hands')}
    elseif key=='j_fortune_teller' then v={a.extra,c.consumeable_usage_total and (c.consumeable_usage_total.tarot or 0)}
    elseif key=='j_blue_joker' then v={a.extra,type(a.extra)=='number' and c.deck_count and a.extra*c.deck_count or nil}
    elseif key=='j_abstract' then v={a.extra,type(a.extra)=='number' and c.joker_count and a.extra*c.joker_count or nil}
    elseif key=='j_steel_joker' then v={a.extra,type(a.extra)=='number' and 1+a.extra*(a.steel_tally or 0) or nil}
    elseif key=='j_stone' then v={a.extra,type(a.extra)=='number' and a.extra*(a.stone_tally or 0) or nil}
    elseif key=='j_cloud_9' then v={a.extra,type(a.extra)=='number' and a.extra*(a.nine_tally or 0) or nil}
    elseif key=='j_bull' then v={a.extra,type(a.extra)=='number' and summary and summary.dollars and a.extra*math.max(0,summary.dollars) or nil}
    elseif key=='j_space' or key=='j_8_ball' or key=='j_business' or key=='j_hallucination' then v={c.probabilities and c.probabilities.normal,a.extra}
    elseif key=='j_gros_michel' then v={e.mult,c.probabilities and c.probabilities.normal,e.odds}
    elseif key=='j_cavendish' then v={e.Xmult,c.probabilities and c.probabilities.normal,e.odds}
    elseif key=='j_bloodstone' then v={c.probabilities and c.probabilities.normal,e.odds,e.Xmult}
    elseif key=='m_glass' then v={a.x_mult or a.Xmult,c.probabilities and c.probabilities.normal,a.extra}
    elseif key=='m_lucky' then v={c.probabilities and c.probabilities.normal,a.mult,5,a.p_dollars,15}
    elseif item.set=='Voucher' then
        if key=='v_tarot_merchant' or key=='v_tarot_tycoon' or key=='v_planet_merchant' or key=='v_planet_tycoon' then v={a.extra_disp}
        elseif key=='v_seed_money' or key=='v_money_tree' then v={type(a.extra)=='number' and a.extra/5 or nil}
        else v={a.extra} end
    elseif item.set=='Booster' then v={a.choose,a.extra}
    elseif item.set=='Planet' and cfg.hand_type then
        local h=c.hands and c.hands[cfg.hand_type] or {};v={h.level,localized(cfg.hand_type,'poker_hands'),h.l_mult,h.l_chips}
    elseif item.set=='Tarot' or item.set=='Spectral' then
        if cfg.mod_conv then v={cfg.max_highlighted,description_name('Enhanced',cfg.mod_conv)}
        elseif cfg.suit_conv then v={cfg.max_highlighted,localized(cfg.suit_conv,'suits_plural')}
        elseif cfg.planets then v={cfg.planets}
        elseif cfg.tarots then v={cfg.tarots}
        elseif key=='c_wheel_of_fortune' then v={c.probabilities and c.probabilities.normal,cfg.extra}
        elseif key=='c_hermit' or key=='c_cryptid' then v={cfg.extra}
        elseif key=='c_temperance' then
            local total=summary and summary.jokers and 0
            for _,joker in ipairs(summary and summary.jokers or {}) do
                if total and type(joker.sell_cost)=='number' then total=total+joker.sell_cost else total=nil end
            end
            v={cfg.extra,total and type(cfg.extra)=='number' and math.min(cfg.extra,total) or nil}
        elseif cfg.max_highlighted then v={cfg.max_highlighted} end
    end
    return v
end
function P.name(item)
    if item.suit and item.rank then return localized(item.rank,'ranks')..' '..localized(item.suit,'suits_plural') end
    if type(localize)=='function' then
        local ok,value=pcall(localize,{type='name_text',set=item.set or 'Joker',key=item.card_key or item.key})
        if ok and type(value)=='string' and value~='ERROR' then return value end
    end
    return item.name or item.card_key or item.key or '-'
end
function P.tooltip(item, summary, translate)
    translate=translate or function(value)return value end
    local result={name=P.name(item),lines={},badges={}}
    local set,key=item.set or 'Joker',item.card_key or item.key
    local descriptions=G and G.localization and G.localization.descriptions
    local template=descriptions and descriptions[set] and descriptions[set][key]
    local variables=P.variables(item,summary);local unknown=false
    for _,line in ipairs(template and template.text or {}) do
        line=tostring(line):gsub('#(%d+)#',function(index)
            local value=variables[tonumber(index)]
            if value==nil then unknown=true;return '?' end
            return tostring(value)
        end)
        result.lines[#result.lines+1]=line:gsub('{[^}]*}','')
    end
    if item.suit then
        local base,ability=item.base or {},item.ability or {}
        if base.nominal then result.lines[#result.lines+1]='+'..base.nominal..' '..localized('k_chips') end
        if ability.perma_bonus and ability.perma_bonus~=0 then result.lines[#result.lines+1]='+'..ability.perma_bonus..' '..localized('k_chips') end
    end
    if item.sell_cost~=nil then result.lines[#result.lines+1]=translate('Sell value')..' $'..item.sell_cost end
    if item.cost~=nil and item.kind then result.lines[#result.lines+1]=translate('Price')..' $'..item.cost end
    if item.money_delta~=nil then result.lines[#result.lines+1]=translate('Money change')..' '..(item.money_delta>=0 and '+' or '')..item.money_delta end
    if unknown then result.lines[#result.lines+1]=translate('Unknown saved value') end
    if #result.lines==0 then result.lines[1]=translate('Unknown saved value') end
    if item.edition then for _,key in ipairs({'negative','polychrome','holo','foil'}) do
        if item.edition[key] then result.badges[#result.badges+1]=description_name('Edition','e_'..key) end
    end end
    if item.seal then result.badges[#result.badges+1]=description_name('Other',string.lower(item.seal)..'_seal') end
    for _,key in ipairs({'eternal','perishable','rental','debuffed'}) do if item[key] then result.badges[#result.badges+1]=description_name('Other',key) end end
    return result
end
return P

-- Bounded session-only Undo history, independently of public milestone nodes.
-- The lifecycle controller owns full snapshots and tree rollback. This module
-- observes irreversible callbacks and never captures from a UI query or draw.
local Undo = {MAX_HISTORY = 200}
local unpack_values = unpack or table.unpack
local installed, installed_ctx, depth, generation = false, nil, 0, 0
local event_depth=0
local latest, latest_action, pending
local history, consecutive, pruned_tail, revision = {}, 0, nil, 0
local history_boundary

local function reset_history(reason)
    history, latest, latest_action, consecutive, pruned_tail = {}, nil, nil, 0, nil
    revision = revision + 1
    history_boundary=reason
end

local function push(entry, description)
    history[#history + 1] = {entry = entry, action = description}
    if #history > Undo.MAX_HISTORY then table.remove(history, 1);history_boundary='history_limit' end
    latest, latest_action = entry, description
    consecutive, pruned_tail = 0, nil
    revision = revision + 1
end

local function pack(...)
    return {n = select('#', ...), ...}
end

local specs = {
    play_cards_from_highlighted = {'play', '出牌', 'Play hand'},
    discard_cards_from_highlighted = {'discard', '弃牌', 'Discard'},
    buy_from_shop = {'buy', '购买', 'Buy'},
    sell_card = {'sell', '出售', 'Sell'},
    reroll_shop = {'reroll_shop', '刷新商店', 'Reroll shop'},
    -- Native use_card handles consumables, booster opening, voucher redemption
    -- and taking playing cards/Jokers from packs. can_select_* only checks UI.
    use_card = {'use', '使用 / 开包 / 选取', 'Use / open / take'},
    skip_booster = {'skip_booster', '跳过卡包', 'Skip pack'},
    select_blind = {'select_blind', '选择盲注', 'Select blind'},
    skip_blind = {'skip_blind', '跳过盲注', 'Skip blind'},
    cash_out = {'enter_shop', '结算并进入商店', 'Cash out'},
    toggle_shop = {'leave_shop', '离开商店', 'Leave shop'},
    reroll_boss = {'reroll_boss', '更换 Boss 盲注', 'Reroll boss'},
    -- Explicit mutation callbacks, if a runtime exposes them separately.
    open_booster = {'open_booster', '打开卡包', 'Open pack'},
    redeem_from_shop = {'redeem', '兑换优惠券', 'Redeem voucher'},
    select_from_booster = {'take_from_pack', '选取卡包内卡牌', 'Take from pack'},
}

local function enabled(ctx)
    return ctx and not ctx.busy and not ctx.restoring and not ctx.detached
        and type(ctx.should_record) == 'function' and ctx.should_record()
end

local function failure(ctx, message)
    Undo.last_error = tostring(message)
    if type(ctx.undo_error) == 'function' then pcall(ctx.undo_error, Undo.last_error) end
end

local function basic_action(ctx, name, spec, event)
    local result = {kind = spec[1], callback = name,
        label = ctx.text and ctx.text(spec[2], spec[3]) or spec[3]}
    local card = event and event.config and event.config.ref_table
    if type(card) == 'table' then
        local center = card.config and card.config.center
        if center and center.key then result.card_key = center.key end
        if card.sort_id then result.card_id = card.sort_id end
    end
    return result
end

-- Only this exact vanilla continuation is the same input. Merely arriving
-- while another callback's events are pending does not make a second click a
-- child operation: e.g. two shop cards may both be bought before the first
-- after-event finishes, without the native controller locking input.
local function continuation(candidate, name, args)
    return candidate and name == 'use_card' and args[2] == true
        and candidate.continuations and candidate.continuations[args[1]] == true
end

-- Pure reads. While a newer callback is pending, callers must disable undo via
-- has_pending rather than expose the preceding latest entry as the newest step.
function Undo.peek() return latest, latest_action end
function Undo.has_pending() return pending ~= nil end
function Undo.count() return #history end
function Undo.consecutive_count() return consecutive end
function Undo.revision() return revision end
function Undo.boundary_reason()return history_boundary end
function Undo.get_pruned_tail() return pruned_tail end
function Undo.set_pruned_tail(value) pruned_tail = value end

function Undo.consume(entry)
    if entry == nil or latest ~= entry then return false end
    table.remove(history)
    local previous = history[#history]
    latest, latest_action = previous and previous.entry, previous and previous.action
    consecutive = consecutive + 1
    revision = revision + 1
    return true
end

function Undo.clear()
    generation = generation + 1
    reset_history()
    pending, Undo.last_error = nil, nil
    if installed_ctx and installed_ctx.input_queue then installed_ctx.input_queue:clear()end
end

function Undo.update(ctx, allow_overlay)
    ctx = ctx or installed_ctx
    local candidate = pending
    if not candidate then return false end
    if not enabled(ctx) then return nil end
    local ok, changed, err = pcall(ctx.undo_finalize, candidate.entry, candidate.action,
        allow_overlay == true, candidate.observation)
    if not ok then
        if pending == candidate then
            pending = nil
            -- The native operation already ran. If its completed state cannot
            -- be validated, exposing an older entry would silently rewind more
            -- than the player's latest action. Future valid input can start a
            -- new bounded history; this is not a failed Undo restore transaction.
            reset_history('finalize_failed')
            if type(ctx.undo_record_untracked) == 'function' then
                pcall(ctx.undo_record_untracked, candidate.observation.actions, 'finalize_failed')
            end
        end
        failure(ctx, changed)
        return nil, Undo.last_error
    end
    if pending ~= candidate or candidate.generation ~= generation then return nil end
    if changed == nil then return nil, err end -- Animation/events have not settled.
    pending = nil
    if changed == true and candidate.entry and not candidate.observation.incomplete then
        push(candidate.entry, candidate.action)
        Undo.last_error = nil
        return true
    end
    -- Incomplete batches remain in phase history, but lack an intermediate
    -- snapshot. They cannot pretend to be one reversible action.
    return changed == true
end

function Undo.install(ctx)
    if installed then return false end
    assert(type(ctx) == 'table' and type(ctx.undo_prepare) == 'function'
        and type(ctx.undo_finalize) == 'function', 'Undo requires snapshot preparation and validation callbacks')
    installed, installed_ctx = true, ctx
    -- A use/open invoked from the native event manager is a continuation of
    -- its parent action. Deferring it would deadlock the queue it must finish.
    if EventManager and type(EventManager.update)=='function' then
        local native=EventManager.update
        EventManager.update=function(...)
            event_depth=event_depth+1
            local result=pack(pcall(native,...))
            event_depth=event_depth-1
            if not result[1]then error(result[2],0)end
            return unpack_values(result,2,result.n)
        end
    end
    for name, spec in pairs(specs) do
        local original = G.FUNCS[name]
        if type(original) == 'function' then
            G.FUNCS[name] = function(...)
                local args, entry, item = pack(...), nil, nil
                -- Two independent stable inputs can arrive before main.update.
                -- Settle the preceding step here before capturing the next one.
                -- A native Event's buy->use continuation is still unstable and
                -- keeps the same pending candidate instead of making two steps.
                local child = depth == 0 and (continuation(pending,name,args)or pending and event_depth>0)
                if depth == 0 and pending and not child then Undo.update(ctx, false) end
                if depth==0 and event_depth==0 and enabled(ctx) and ctx.input_queue
                    and ctx.input_queue:should_defer() then
                    return ctx.input_queue:enqueue(name,args,G.FUNCS[name])
                end
                local epoch = generation
                local observe = depth == 0 and event_depth==0 and not child and enabled(ctx)
                local prepare = observe and not pending
                depth = depth + 1
                if observe then
                    item = basic_action(ctx, name, spec, args[1])
                    if type(ctx.describe_choice) == 'function' then
                        local ok, value = pcall(ctx.describe_choice, item, args[1])
                        if ok then item = value or item
                        else item.replay_incomplete = true; failure(ctx, value) end
                    end
                    if prepare then
                        local ok, value = pcall(ctx.undo_prepare, item)
                        if ok then entry = value else failure(ctx, value) end
                    end
                end
                local result = pack(pcall(original, unpack_values(args, 1, args.n)))
                depth = depth - 1
                -- A native exception keeps its original type/message and leaves
                -- the previous undo intact. Likewise, a false return is blocked.
                if not result[1] then error(result[2], 0) end
                if result[2] ~= false and generation == epoch then
                    -- The native action may finish through later Events. Keep
                    -- observation dirty until a stable snapshot is captured,
                    -- even when this action could not prepare an Undo entry.
                    if enabled(ctx) and type(ctx.invalidate_snapshot) == 'function' then
                        ctx.invalidate_snapshot()
                    end
                    if child and pending then
                        if args[1]~=nil then pending.continuations[args[1]] = nil end
                    elseif observe then
                        if pending then
                            local observation = pending.observation
                            observation.actions[#observation.actions + 1] = item
                            observation.incomplete, observation.reason = true, 'overlapping_actions'
                        else
                            pending = {entry = entry, action = item, generation = epoch, continuations = {},
                                observation = {actions = {item}, incomplete = not entry,
                                    reason = not entry and 'missing_before' or nil}}
                        end
                        if item.callback == 'buy_from_shop' and item.use_after == true and args[1] ~= nil then
                            pending.continuations[args[1]] = true
                        end
                        if pending.observation.incomplete then
                            -- Keep the input descriptions, but never offer a
                            -- stale older Undo or combine independent clicks.
                            reset_history(pending.observation.reason)
                        end
                    end
                end
                return unpack_values(result, 2, result.n)
            end
        end
    end
    return true
end

return Undo

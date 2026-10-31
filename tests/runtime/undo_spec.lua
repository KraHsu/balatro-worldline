local Undo = dofile('src/runtime/undo.lua')
local function clone(value)
    if type(value) ~= 'table' then return value end
    local result = {}
    for key, item in pairs(value) do result[key] = clone(item) end
    return result
end

local game = {value = 0, selected = {}, ID = 1}
local tree = {current = 1, next_id = 2, resume = {parent = 1, shopping = 'unfinished'}, run_id = 'UNDO_TEST'}
local stable, recording = true, true
local prepares, finalizes, originals_called = 0, 0, 0
local finalize_overlay, prepare_error, prepare_nil, finalize_error
local invalidations = 0
local choice_descriptions = 0
local finalized_observation, fallback_actions
local behaviors, originals, errors = {}, {}, {}
EventManager={update=function(_,callback)return callback()end}
local irreversible = {
    'play_cards_from_highlighted', 'discard_cards_from_highlighted', 'buy_from_shop', 'sell_card',
    'reroll_shop', 'use_card', 'skip_booster', 'select_blind', 'skip_blind', 'cash_out',
    'toggle_shop', 'reroll_boss', 'open_booster', 'redeem_from_shop', 'select_from_booster',
}
local ignored = {'sort_hand_suit', 'sort_hand_value', 'can_buy', 'can_select_from_booster',
    'reroll_boss_button', 'check_for_buy_space'}
G = {GAME = game, FUNCS = {}}
CardArea = {}
function CardArea:add_to_highlighted(card) game.selected[#game.selected + 1] = card end
function CardArea:unhighlight_all() game.selected = {} end
local highlight = CardArea.add_to_highlighted
for _, name in ipairs(irreversible) do
    G.FUNCS[name] = function(...)
        originals_called = originals_called + 1
        if behaviors[name] then return behaviors[name](...) end
        game.value = game.value + 1
        return name, nil, false, 42
    end
    originals[name] = G.FUNCS[name]
end
for _, name in ipairs(ignored) do
    G.FUNCS[name] = function() game.ID = game.ID + 1 end
    originals[name] = G.FUNCS[name]
end
local ctx = {
    should_record = function() return recording end,
    text = function(_, en) return en end,
    undo_error = function(message) errors[#errors + 1] = message end,
    invalidate_snapshot = function() invalidations = invalidations + 1 end,
    undo_record_untracked = function(actions) fallback_actions = clone(actions) end,
    describe_choice = function(action, event)
        choice_descriptions = choice_descriptions + 1
        action.description_value = game.value
        action.description_event = type(event) == 'table' and 'card' or 'none'
        action.use_after = action.kind == 'buy' and type(event) == 'table'
            and event.config and event.config.id == 'buy_and_use' or nil
        return action
    end,
    undo_prepare = function(action)
        prepares = prepares + 1
        if prepare_error then error('prepare failure') end
        if prepare_nil or not stable then return nil end
        return {snapshot = clone(game), summary = {value = game.value}, tree = tree,
            checkpoint = {current = tree.current, next_id = tree.next_id,
                resume = clone(tree.resume), run_id = tree.run_id}, action_seen = action.callback}
    end,
    undo_finalize = function(entry, action, allow_overlay, observation)
        finalizes, finalize_overlay = finalizes + 1, allow_overlay
        if finalize_error then error('finalize failure') end
        if not stable then return nil end
        finalized_observation = clone(observation)
        if not entry or observation and observation.incomplete then return true end
        assert(action.callback == entry.action_seen)
        -- The controller owns canonical comparison: UI IDs/selection alone are
        -- ignored; the observer never invents its own gameplay equivalence.
        return game.value ~= entry.snapshot.value
    end,
}
assert(Undo.install(ctx) and not Undo.install(ctx), 'callbacks install exactly once')
for _, name in ipairs(irreversible) do
    assert(G.FUNCS[name] ~= originals[name], 'wrap native mutation: ' .. name)
    local a, b, c, d = G.FUNCS[name]({config = {ref_table = {sort_id = 17,
        config = {center = {key = 'j_test'}}}}})
    assert(a == name and b == nil and c == false and d == 42, 'preserve nil-bearing native returns')
    assert(Undo.has_pending() and finalizes == prepares - 1, 'callbacks prepare but never finalize snapshots')
    assert(Undo.update(ctx, false) == true and not Undo.has_pending())
    local entry, action = Undo.peek()
    assert(entry.action_seen == name and action.callback == name and action.card_key == 'j_test' and action.card_id == 17)
    assert(action.description_value == entry.snapshot.value and action.description_event == 'card',
        'choice metadata is described before native mutation using the existing Undo boundary')
end
assert(invalidations == #irreversible, 'each successful irreversible action invalidates the resume observation')
local previous, previous_action = Undo.peek()
local count = prepares
for _, name in ipairs(ignored) do
    assert(G.FUNCS[name] == originals[name], 'selection/availability/sorting remain native: ' .. name)
    G.FUNCS[name]()
end
assert(CardArea.add_to_highlighted == highlight)
CardArea.add_to_highlighted({}, 1)
CardArea.unhighlight_all({})
assert(prepares == count and Undo.peek() == previous and not Undo.has_pending())
for _ = 1, 20 do Undo.peek(); Undo.has_pending() end
assert(prepares == count, 'UI queries never capture or compare snapshots')

-- Stable independent callbacks may arrive before the next main.update. The
-- second input settles the first candidate and captures its own before-state.
local first_value, first_finalizes = game.value, finalizes
count = prepares
G.FUNCS.play_cards_from_highlighted()
G.FUNCS.discard_cards_from_highlighted()
assert(prepares == count + 2 and finalizes == first_finalizes + 1 and Undo.has_pending())
local between_entry, between_action = Undo.peek()
assert(between_entry.snapshot.value == first_value and between_action.callback == 'play_cards_from_highlighted')
assert(Undo.update(ctx) == true)
previous, previous_action = Undo.peek()
assert(previous.snapshot.value == first_value + 1 and previous_action.callback == 'discard_cards_from_highlighted',
    'undo keeps only the second independent input, not both inputs merged')

-- A stable no-op first input must also settle before preparing the next input.
behaviors.sell_card = function() game.ID = game.ID + 1 end
first_value, first_finalizes, count = game.value, finalizes, prepares
G.FUNCS.sell_card()
G.FUNCS.reroll_shop()
assert(prepares == count + 2 and finalizes == first_finalizes + 1 and Undo.peek() == previous)
assert(Undo.update(ctx) == true)
previous, previous_action = Undo.peek()
assert(previous.snapshot.value == first_value and previous_action.callback == 'reroll_shop')

-- Explicit rejection, exceptions and stable no-ops preserve the old latest.
behaviors.sell_card = function() return false, nil, 8 end
local before_rejected = invalidations
assert(G.FUNCS.sell_card() == false and not Undo.has_pending() and Undo.peek() == previous)
assert(invalidations == before_rejected, 'rejected actions do not invalidate observation')
local native_error = {kind = 'original native exception'}
behaviors.sell_card = function() error(native_error) end
local ok, err = pcall(G.FUNCS.sell_card)
assert(not ok and err == native_error and Undo.peek() == previous and not Undo.has_pending())
assert(invalidations == before_rejected, 'failed native actions preserve observation')
behaviors.sell_card = function() game.ID = game.ID + 99; game.selected = {1, 2}; return 'no gameplay change' end
G.FUNCS.sell_card()
assert(Undo.has_pending() and Undo.update(ctx, true) == false and Undo.peek() == previous)
assert(finalize_overlay == true, 'paused overlays may settle validation without drawing or UI-side capture')

-- Synchronous buy/use/open nesting creates exactly one before-state.
behaviors.buy_from_shop = function()
    game.value = game.value + 10
    G.FUNCS.use_card()
    return 'buy and use', nil, 3
end
behaviors.use_card = function() G.FUNCS.open_booster(); game.value = game.value + 2 end
count = prepares
local descriptions_before_nested = choice_descriptions
local a, b, c = G.FUNCS.buy_from_shop()
assert(a == 'buy and use' and b == nil and c == 3 and prepares == count + 1)
assert(choice_descriptions == descriptions_before_nested + 1,
    'buy/use/open continuations have one phase choice description')
assert(Undo.update(ctx) == true)
local buy_entry, buy_action = Undo.peek()
assert(buy_action.callback == 'buy_from_shop')

-- Native buy_and_use really invokes use_card from a later Event. Until that
-- event chain settles, subsequent wrapped callbacks belong to its candidate.
local scheduled
local async_event = {config = {id = 'buy_and_use'}}
behaviors.buy_from_shop = function(event)
    stable = false
    scheduled = function()
        game.value = game.value + 5
        G.FUNCS.use_card(event, true)
    end
end
count = prepares
G.FUNCS.buy_from_shop(async_event)
assert(Undo.has_pending() and Undo.peek() == buy_entry)
assert(Undo.update(ctx) == nil and Undo.has_pending())
local before_continuation_finalizes = finalizes
scheduled()
assert(prepares == count + 1 and finalizes == before_continuation_finalizes and Undo.has_pending(),
    'an unstable asynchronous child use/open still shares its parent candidate')
stable = true
assert(Undo.update(ctx, true) == true)
local async_entry, async_action = Undo.peek()
assert(async_entry ~= buy_entry and async_action.callback == 'buy_from_shop')

-- The opaque before-entry retains the full tree checkpoint and private resume
-- even while a real milestone controller changes the live tree cursor.
behaviors.select_blind = function()
    game.value = game.value + 1
    tree.current, tree.next_id, tree.resume = tree.next_id, tree.next_id + 1, nil
end
local old_current, old_next = tree.current, tree.next_id
G.FUNCS.select_blind()
assert(Undo.update(ctx) == true)
local milestone_entry = Undo.peek()
assert(milestone_entry.tree == tree and milestone_entry.checkpoint.current == old_current
    and milestone_entry.checkpoint.next_id == old_next)
assert(milestone_entry.checkpoint.resume.shopping == 'unfinished' and tree.resume == nil)
assert(not Undo.consume(async_entry), 'stale completion cannot consume a newer undo')
assert(Undo.peek() == milestone_entry)
local history_count = Undo.count()
assert(Undo.consume(milestone_entry) and Undo.peek() == async_entry and not Undo.consume(nil))
assert(Undo.count() == history_count - 1 and Undo.consecutive_count() == 1,
    'successful Undo pops only the latest entry and retains previous actions')

-- Recording/restoration boundaries do not replace the previous step.
behaviors.sell_card = nil
G.FUNCS.sell_card(); Undo.update(ctx)
previous = Undo.peek()
count = prepares
for _, flag in ipairs({'busy', 'restoring', 'detached'}) do
    ctx[flag] = true; G.FUNCS.sell_card(); ctx[flag] = nil
end
recording = false; G.FUNCS.sell_card(); recording = true
assert(prepares == count and Undo.peek() == previous and not Undo.has_pending())

-- Missing preparation invalidates stale history only if the native action
-- succeeds. Rejected/throwing native callbacks still preserve the old latest.
prepare_nil = true
behaviors.sell_card = function() return false end
G.FUNCS.sell_card()
assert(Undo.peek() == previous)
behaviors.sell_card = function() error(native_error) end
ok, err = pcall(G.FUNCS.sell_card)
assert(not ok and err == native_error and Undo.peek() == previous)
behaviors.sell_card = nil
G.FUNCS.sell_card()
assert(Undo.peek() == nil and Undo.has_pending(), 'successful uncaptured action retains its input but cannot expose an older undo')
assert(Undo.update(ctx) and finalized_observation.incomplete
    and finalized_observation.reason == 'missing_before' and not Undo.peek())
prepare_nil = false
G.FUNCS.sell_card(); Undo.update(ctx)
previous = Undo.peek()

-- Observer errors never swallow the native action. A successful action after
-- a capture error also clears stale latest data, while native failure does not.
prepare_error = true
behaviors.sell_card = function() return false end
G.FUNCS.sell_card()
assert(Undo.peek() == previous)
behaviors.sell_card = nil
local before_calls = originals_called
G.FUNCS.sell_card()
prepare_error = false
assert(originals_called == before_calls + 1 and Undo.peek() == nil and #errors > 0)
assert(Undo.update(ctx) and finalized_observation.incomplete)
G.FUNCS.sell_card(); Undo.update(ctx)
previous = Undo.peek()
G.FUNCS.sell_card()
finalize_error = true
local finished, finalize_err = Undo.update(ctx)
finalize_error = false
assert(finished == nil and finalize_err:find('finalize failure') and not Undo.has_pending()
    and Undo.peek() == nil and Undo.count() == 0 and Undo.consecutive_count() == 0,
    'a successful action with unverifiable final state must not expose an older Undo as the latest step')
assert(fallback_actions and fallback_actions[1].callback == 'sell_card',
    'failed final-state capture must still invalidate complete replay evidence')

-- Clearing during a callback or its finalizer must never resurrect stale work.
behaviors.use_card = function() game.value = game.value + 1; Undo.clear() end
G.FUNCS.use_card()
assert(Undo.peek() == nil and not Undo.has_pending())
behaviors.use_card = nil
G.FUNCS.use_card()
assert(Undo.update(ctx) == true and Undo.peek() ~= nil, 'callback depth recovers after clear and native exceptions')
local old_finalize = ctx.undo_finalize
ctx.undo_finalize = function() Undo.clear(); return true end
G.FUNCS.use_card()
assert(Undo.update(ctx) == nil and Undo.peek() == nil and not Undo.has_pending())
ctx.undo_finalize = old_finalize
G.FUNCS.use_card()
Undo.clear()
assert(not Undo.has_pending() and Undo.peek() == nil and Undo.update(ctx) == false)
assert(Undo.count() == 0 and Undo.consecutive_count() == 0)

-- History is a bounded session stack of opaque entries, not a copied tree or
-- persisted action log. Only successful canonical mutations reset a streak.
for _ = 1, Undo.MAX_HISTORY + 3 do G.FUNCS.sell_card(); assert(Undo.update(ctx)) end
assert(Undo.MAX_HISTORY == 200 and Undo.count() == Undo.MAX_HISTORY)
local top = Undo.peek()
local opaque_tail = {nodes = {}}
Undo.set_pruned_tail(opaque_tail)
assert(Undo.consume(top) and Undo.count() == 199 and Undo.consecutive_count() == 1)
assert(Undo.get_pruned_tail() == opaque_tail)
local version = Undo.revision()
behaviors.sell_card = function() return false end
G.FUNCS.sell_card()
assert(Undo.revision() == version and Undo.consecutive_count() == 1 and Undo.get_pruned_tail() == opaque_tail,
    'blocked inputs do not reset continuous Undo or discard the recoverable phase tail')
behaviors.sell_card = nil
G.FUNCS.sell_card(); assert(Undo.update(ctx))
assert(Undo.count() == 200 and Undo.consecutive_count() == 0 and Undo.get_pruned_tail() == nil,
    'a completed new action resets only the streak and obsolete tail, preserving earlier history')
for _ = 1, Undo.MAX_HISTORY do assert(Undo.consume(Undo.peek())) end
assert(Undo.count() == 0 and Undo.peek() == nil and Undo.consecutive_count() == Undo.MAX_HISTORY)
Undo.clear()
assert(Undo.consecutive_count() == 0 and Undo.get_pruned_tail() == nil)

-- Independent shop inputs may overlap native after-events. Preserve every
-- pre-click description, but never offer the whole burst as one-action Undo.
local queued = {}
behaviors.buy_from_shop = function(event)
    stable = false
    queued[#queued + 1] = function()
        game.value = game.value + event.config.ref_table.sort_id
        if event.config.id == 'buy_and_use' then G.FUNCS.use_card(event, true) end
    end
end
local function event(id, buy_use)
    return {config = {id = buy_use and 'buy_and_use' or 'buy',
        ref_table = {sort_id = id, config = {center = {key = 'c_' .. id}}}}}
end
local overlapping_prepares, overlapping_descriptions = prepares, choice_descriptions
G.FUNCS.buy_from_shop(event(101))
behaviors.sell_card = function() return false end
G.FUNCS.sell_card(event(999))
G.FUNCS.buy_from_shop(event(102, true))
G.FUNCS.buy_from_shop(event(103))
assert(prepares == overlapping_prepares + 1 and not Undo.peek() and Undo.has_pending(),
    'no unsafe intermediate full capture and no stale Undo while independent inputs overlap')
for _, callback in ipairs(queued) do callback() end
stable = true
assert(Undo.update(ctx) and Undo.count() == 0 and not Undo.has_pending())
assert(finalized_observation.incomplete and finalized_observation.reason == 'overlapping_actions'
    and #finalized_observation.actions == 3,
    'known buy-and-use continuation and rejected sell are not separate inputs')
for index, id in ipairs({101,102,103}) do
    assert(finalized_observation.actions[index].card_id == id,
        'independent inputs preserve their actual order')
end
assert(choice_descriptions == overlapping_descriptions + 4,
    'all independent clicks get descriptions; known native continuation does not')

-- A same-event use without native mute=true is not the known continuation.
queued = {}
local ordinary = event(104, true)
G.FUNCS.buy_from_shop(ordinary)
G.FUNCS.use_card(ordinary, false)
for _, callback in ipairs(queued) do callback() end
stable = true
assert(Undo.update(ctx) and finalized_observation.incomplete and #finalized_observation.actions == 2)
assert(finalized_observation.actions[2].callback == 'use_card')

-- Native event continuations must execute even while player inputs are queued.
-- Otherwise buy/open events deadlock the very animation the queue waits for.
Undo.clear()
behaviors.use_card=nil
local before_events=prepares
ctx.input_queue={should_defer=function()error('Native events must bypass the player queue')end}
local event_a,event_b,event_c=EventManager:update(function()return G.FUNCS.use_card()end)
assert(event_a=='use_card' and event_b==nil and event_c==false)
assert(prepares==before_events and not Undo.has_pending(),'Automatic events are not standalone player actions')
local event_ok,event_error=pcall(EventManager.update,EventManager,function()error(native_error)end)
assert(not event_ok and event_error==native_error,'Keep the original native event exception')
ctx.input_queue=nil
G.FUNCS.use_card();assert(Undo.update(ctx)and prepares==before_events+1,
 'Event depth recovers after exceptions, so the next player action is observed')
print('PASS undo: bounded session stack, native mutations, nested/async coalescing, no-op rejection, continuous streaks')

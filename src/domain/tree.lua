-- Immutable checkpoints with a movable cursor. Moving never deletes descendants.
local Tree = {}
Tree.__index = Tree
Tree.MAX_NODES = 10000
Tree.MAX_ID = 9007199254740991
Tree.MAX_BOOKMARKS, Tree.MAX_FOLDS = 1024, 256

-- Native selected_back_key may be a Steamodded Back object rather than a
-- string. Metadata and presentation need its identity, never its callbacks.
function Tree.deck_key(value)
    if type(value) == 'table' then value = value.key end
    if type(value) == 'string' and value ~= '' and value ~= '"MANUAL_REPLACE"' then return value end
end

local function with_deck_key(record)
    if type(record.deck) ~= 'table' then return record end
    local key = assert(Tree.deck_key(record.deck), 'Invalid deck identifier')
    local result = {}
    for field, value in pairs(record) do result[field] = value end
    result.deck = key
    return result
end

local function with_summary_deck(record)
    local summary = with_deck_key(record.summary)
    if summary == record.summary then return record end
    local result = {}
    for field, value in pairs(record) do result[field] = value end
    result.summary = summary
    return result
end

local function clone(value, ancestors, depth)
    local kind = type(value)
    if kind ~= "table" then
        assert(kind == "nil" or kind == "string" or kind == "boolean" or kind == "number", "Non-data value")
        if kind == "number" then assert(value == value and math.abs(value) ~= math.huge, "Non-finite number") end
        return value
    end
    depth = (depth or 0) + 1
    assert(depth <= 96, "Data nesting limit exceeded")
    ancestors = ancestors or {}
    assert(not ancestors[value], "Cyclic data")
    ancestors[value] = true
    local result = {}
    for key, item in pairs(value) do
        local key_type = type(key)
        assert(key_type == "string" or key_type == "number" or key_type == "boolean", "Invalid table key")
        result[key] = clone(item, ancestors, depth)
    end
    ancestors[value] = nil
    return result
end

local function positive_integer(value)
    return type(value) == "number" and value >= 1 and value <= Tree.MAX_ID and value % 1 == 0
end

-- Node IDs are never reused by archive editing. Sparse histories may retain a
-- large next_id after pruning, so no traversal may iterate through every ID.
local function node_ids(nodes)
    local ids = {}
    for id in pairs(nodes) do ids[#ids + 1] = id end
    table.sort(ids)
    return ids
end

local function ordered_ids(self)
    local cached = self._ids_cache
    if cached and cached.nodes == self.nodes and cached.revision == self.structure_revision then return cached.ids end
    local ids = node_ids(self.nodes)
    self._ids_cache = {nodes = self.nodes, revision = self.structure_revision, ids = ids}
    return ids
end

local function wire_schema(ids, next_id)
    return #ids == next_id - 1 and 1 or 2
end

local function node_shell(node, children)
    local result = {}
    for key, value in pairs(node) do result[key] = value end
    result.children = children
    return result
end

local function array(value, limit)
    if type(value) ~= "table" or #value > limit then return false end
    local count = 0
    for key in pairs(value) do
        if type(key) ~= "number" or key < 1 or key % 1 ~= 0 or key > #value then return false end
        count = count + 1
    end
    return count == #value
end

local function valid_metadata(metadata)
    return type(metadata) == "table" and type(metadata.seed) == "string"
        and #metadata.seed >= 1 and #metadata.seed <= 64
        and type(metadata.run_id) == "string" and #metadata.run_id >= 1 and #metadata.run_id <= 96
        and metadata.run_id:match("^[%w_-]+$") ~= nil
end

local function empty_annotations()
    return {schema = 1, bookmarks = {}, folds = {}, next_fold_id = 1}
end

local function label_text(value)
    assert(type(value) == 'string', 'A name is required')
    value = value:match('^%s*(.-)%s*$')
    assert(#value > 0 and #value <= 256 and not value:find('[%z\1-\31\127]'), 'Name must contain 1 to 64 characters')
    local index, count = 1, 0
    while index <= #value do
        local first, length = value:byte(index), 1
        if first >= 194 and first <= 223 then length = 2
        elseif first >= 224 and first <= 239 then length = 3
        elseif first >= 240 and first <= 244 then length = 4
        else assert(first < 128, 'Invalid UTF-8 name') end
        assert(index + length - 1 <= #value, 'Invalid UTF-8 name')
        for offset = 1, length - 1 do
            local byte = value:byte(index + offset)
            assert(byte >= 128 and byte <= 191, 'Invalid UTF-8 name')
        end
        local second = value:byte(index + 1)
        assert(not (first == 224 and second < 160 or first == 237 and second > 159
            or first == 240 and second < 144 or first == 244 and second > 143), 'Invalid UTF-8 name')
        index, count = index + length, count + 1
    end
    assert(count <= 64, 'Name must contain 1 to 64 characters')
    return value
end

local function is_ancestor(nodes, ancestor, descendant)
    local node = nodes[descendant]
    while node and node.parent ~= 0 do
        if node.parent == ancestor then return true end
        node = nodes[node.parent]
    end
    return false
end

local function annotation_change(self)
    self.annotation_revision = (self.annotation_revision or 0) + 1
    self._presentation_cache = nil
end

local function annotations(self)
    if not self.annotations then self.annotations = empty_annotations() end
    return self.annotations
end

local fold_reasons = {
    missing_end = 'This legacy region has no end point; choose two endpoints to fold a linear sequence.',
    invalid_path = 'The end point must be a later descendant of the start point.',
    too_short = 'A folded sequence needs at least one intermediate point.',
    branch = 'A branch occurs inside this sequence; keep every branch point visible.',
    overlap = 'This sequence overlaps another collapsed region; expand that region first.',
}

-- The real tree has one incoming edge per non-root node. Validate every strict
-- intermediate node's single outgoing edge as well; boundaries may branch.
local function fold_path(nodes, fold)
    if not fold.end_id then return nil, 'missing_end' end
    local start, node = nodes[fold.start_id], nodes[fold.end_id]
    if not start or not node or start.id == node.id then return nil, 'invalid_path' end
    local interior = {}
    node = nodes[node.parent]
    while node and node.id ~= start.id do
        if #node.children ~= 1 then return nil, 'branch' end
        interior[#interior + 1] = node.id
        node = nodes[node.parent]
    end
    if not node then return nil, 'invalid_path' end
    if #interior == 0 then return nil, 'too_short' end
    return interior
end

local function sorted_folds(data)
    local result = {}
    for _, fold in pairs(data.folds) do result[#result + 1] = fold end
    table.sort(result, function(a, b) return a.id < b.id end)
    return result
end

local function overlaps(fold, path, interiors, boundaries)
    local function occupied(id) return interiors[id] and interiors[id] ~= fold.id end
    if occupied(fold.start_id) or occupied(fold.end_id) then return true end
    for _, id in ipairs(path) do
        if occupied(id) or boundaries[id] then return true end
    end
    return false -- Shared boundaries alone are allowed.
end

local function reserve_region(fold, path, interiors, boundaries)
    boundaries[fold.start_id], boundaries[fold.end_id] = true, true
    for _, id in ipairs(path) do interiors[id] = fold.id end
end

local function fold_status(nodes, data, fold)
    local path, reason = fold_path(nodes, fold)
    if not path then return nil, reason end
    local interiors, boundaries = {}, {}
    for _, other in pairs(data.folds) do
        if other.id ~= fold.id and other.collapsed then
            local other_path = fold_path(nodes, other)
            if other_path then reserve_region(other, other_path, interiors, boundaries) end
        end
    end
    if overlaps(fold, path, interiors, boundaries) then return nil, 'overlap' end
    return path
end

-- Old archives may contain suworldline folds or paths that cross a branch. Keep
-- their names/endpoints, safely expand them, and explain why in fold_rows().
-- Also run after structural changes so a newly created branch is never hidden.
local function normalize_folds(nodes, data)
    local interiors, boundaries, changed = {}, {}, false
    for _, fold in ipairs(sorted_folds(data)) do
        if fold.collapsed then
            local path = fold_path(nodes, fold)
            if path and overlaps(fold, path, interiors, boundaries) then path = nil end
            if path then reserve_region(fold, path, interiors, boundaries)
            else fold.collapsed, changed = false, true end
        end
    end
    return changed
end

local function validate_annotations(value, nodes)
    if value == nil then return empty_annotations() end
    assert(type(value) == 'table' and value.schema == 1 and type(value.bookmarks) == 'table'
        and type(value.folds) == 'table' and type(value.next_fold_id) == 'number'
        and value.next_fold_id >= 1 and value.next_fold_id % 1 == 0
        and value.next_fold_id <= 9007199254740991, 'Invalid worldline annotations')
    local result, count = empty_annotations(), 0
    for id, name in pairs(value.bookmarks) do
        count = count + 1
        assert(count <= Tree.MAX_BOOKMARKS and positive_integer(id) and nodes[id], 'Invalid bookmark node')
        result.bookmarks[id] = label_text(name)
    end
    count = 0
    for id, fold in pairs(value.folds) do
        count = count + 1
        assert(count <= Tree.MAX_FOLDS and type(id) == 'number' and id >= 1 and id % 1 == 0
            and id < value.next_fold_id and type(fold) == 'table' and fold.id == id,
            'Invalid folded region')
        assert(positive_integer(fold.start_id) and nodes[fold.start_id]
            and (fold.end_id == nil or positive_integer(fold.end_id) and nodes[fold.end_id]),
            'Invalid folded region endpoints')
        assert(type(fold.collapsed) == 'boolean', 'Invalid folded region state')
        result.folds[id] = {id = id, start_id = fold.start_id, end_id = fold.end_id,
            label = label_text(fold.label), collapsed = fold.collapsed}
    end
    result.next_fold_id = value.next_fold_id
    normalize_folds(nodes, result)
    return result
end

function Tree:set_bookmark(id, name)
    assert(self.nodes[id], 'Unknown bookmark node')
    local data = annotations(self)
    local value = name ~= nil and label_text(name) or nil
    if value == data.bookmarks[id] then return false end
    if value and not data.bookmarks[id] then
        local count = 0; for _ in pairs(data.bookmarks) do count = count + 1 end
        assert(count < self.MAX_BOOKMARKS, 'Bookmark limit reached')
    end
    data.bookmarks[id] = value
    annotation_change(self)
    return true
end

function Tree:bookmark_rows()
    local result = {}
    for id, name in pairs(annotations(self).bookmarks) do
        if self.nodes[id] then result[#result + 1] = {id = id, node_id = id, label = name, name = name} end
    end
    table.sort(result, function(a, b) return a.id < b.id end)
    return result
end

function Tree:add_fold(start_id, end_id, name)
    assert(self.nodes[start_id], 'Unknown folded region start')
    if end_id and self.nodes[end_id] and is_ancestor(self.nodes, end_id, start_id) then
        start_id, end_id = end_id, start_id
    end
    if end_id == nil then
        local node = self.nodes[start_id]
        assert(#node.children == 1, 'Choose an explicit end point at a branch, or a start with one successor')
        repeat node = self.nodes[node.children[1]] until #node.children ~= 1
        end_id = node.id
    end
    local data, count = annotations(self), 0
    local candidate = {start_id = start_id, end_id = end_id}
    local existing
    for _, fold in pairs(data.folds) do
        count = count + 1
        if fold.start_id == start_id and fold.end_id == end_id then existing = fold; candidate.id = fold.id end
    end
    local path, reason = fold_status(self.nodes, data, candidate)
    assert(path, fold_reasons[reason])
    if existing then
        local label = label_text(name)
        local changed = existing.label ~= label or not existing.collapsed
        existing.label, existing.collapsed = label, true
        if changed then annotation_change(self) end
        return existing.id
    end
    assert(count < self.MAX_FOLDS and data.next_fold_id < 9007199254740991, 'Folded region limit reached')
    local id, label = data.next_fold_id, label_text(name)
    data.folds[id] = {id = id, start_id = start_id, end_id = end_id, label = label, collapsed = true}
    data.next_fold_id = id + 1
    annotation_change(self)
    return id
end

function Tree:set_fold_collapsed(id, value)
    local fold = assert(annotations(self).folds[id], 'Unknown folded region')
    assert(type(value) == 'boolean', 'Invalid folded region state')
    if value then
        local path, reason = fold_status(self.nodes, annotations(self), fold)
        assert(path, fold_reasons[reason])
    end
    if fold.collapsed == value then return false end
    fold.collapsed = value
    annotation_change(self)
    return true
end

function Tree:remove_fold(id)
    local data = annotations(self)
    if not data.folds[id] then return false end
    data.folds[id] = nil
    annotation_change(self)
    return true
end

function Tree:fold_rows()
    local result = {}
    local data = annotations(self)
    local folds, paths, reasons, interiors, boundaries = sorted_folds(data), {}, {}, {}, {}
    for _, fold in ipairs(folds) do
        local path, reason = fold_path(self.nodes, fold)
        paths[fold.id], reasons[fold.id] = path, reason
        if path and fold.collapsed then reserve_region(fold, path, interiors, boundaries) end
    end
    for _, fold in ipairs(folds) do
        local row = clone(fold)
        local path, reason = paths[fold.id], reasons[fold.id]
        if path and overlaps(fold, path, interiors, boundaries) then path, reason = nil, 'overlap' end
        row.available, row.reason_code, row.reason = path ~= nil, reason, fold_reasons[reason]
        row.hidden_count = path and #path or 0
        result[#result + 1] = row
    end
    return result
end

function Tree:reveal_node(id)
    assert(self.nodes[id], 'Unknown convergence point')
    local changed = false
    for _, fold in pairs(annotations(self).folds) do
        if fold.collapsed and id ~= fold.start_id and is_ancestor(self.nodes, fold.start_id, id)
            and (fold.end_id == nil or id ~= fold.end_id and is_ancestor(self.nodes, id, fold.end_id)) then
            fold.collapsed, changed = false, true
        end
    end
    if changed then annotation_change(self) end
    return changed
end

function Tree.new(snapshot, metadata)
    assert(valid_metadata(metadata), "Invalid run metadata")
    assert(type(snapshot) == "table" and snapshot.seed == metadata.seed, "Checkpoint seed mismatch")
    metadata = clone(with_deck_key(metadata))
    if metadata.name ~= nil then metadata.name = label_text(metadata.name) end
    return setmetatable({root = 1, current = 1, next_id = 2, structure_revision = 0,
        annotation_revision = 0, metadata_revision = 0, _node_count = 1,
        annotations = empty_annotations(), metadata = metadata, nodes = {
        [1] = {id = 1, parent = 0, children = {}, action = {kind = "start", label = "Start"},
            summary = {}, snapshot = clone(snapshot)}
    }}, Tree)
end

function Tree:get(id) return self.nodes[id] end

function Tree:node_count()
    if self._node_count == nil then
        local count = 0; for _ in pairs(self.nodes) do count = count + 1 end
        self._node_count = count
    end
    return self._node_count
end

local function branch_ids(self, id)
    assert(self.nodes[id], 'Unknown branch')
    local included, ids, stack = {}, {}, {id}
    while #stack > 0 do
        local current = table.remove(stack)
        local node = assert(self.nodes[current], 'Invalid branch connection')
        included[current], ids[#ids + 1] = true, current
        for _, child in ipairs(node.children) do stack[#stack + 1] = child end
    end
    table.sort(ids)
    return included, ids
end

local function retained_annotations(source, nodes)
    local data = clone(source or empty_annotations())
    local removed_bookmarks, removed_folds = 0, 0
    for id in pairs(data.bookmarks) do
        if not nodes[id] then data.bookmarks[id], removed_bookmarks = nil, removed_bookmarks + 1 end
    end
    for id, fold in pairs(data.folds) do
        if not nodes[fold.start_id] or fold.end_id and not nodes[fold.end_id] then
            data.folds[id], removed_folds = nil, removed_folds + 1
        end
    end
    normalize_folds(nodes, data)
    return data, removed_bookmarks, removed_folds
end

function Tree:prune_preview(id)
    local included, ids = branch_ids(self, id)
    local is_root, contains_current = id == self.root, included[self.current] == true
    local reason_code = is_root and 'root' or contains_current and 'current_path' or nil
    local kept = {}
    for key, node in pairs(self.nodes) do if not included[key] then kept[key] = node end end
    local _, bookmarks, folds = retained_annotations(self.annotations, kept)
    return {id = id, parent = self.nodes[id].parent, count = #ids, ids = ids,
        remaining_count = self:node_count() - #ids, current = self.current,
        revision = self.structure_revision or 0, annotation_revision = self.annotation_revision or 0,
        is_root = is_root, contains_current = contains_current, allowed = reason_code == nil,
        reason_code = reason_code,
        reason = is_root and 'Use Delete archive to remove the whole worldline'
            or contains_current and 'Cannot delete the current point or its history' or nil,
        removed_bookmarks = bookmarks, removed_folds = folds}
end

function Tree:prune_branch(id, expected)
    local preview = self:prune_preview(id)
    assert(preview.allowed, preview.reason)
    if expected ~= nil then
        assert(type(expected) == 'table' and expected.id == id and expected.current == preview.current
            and expected.revision == preview.revision and expected.annotation_revision == preview.annotation_revision,
            'Worldline changed; review the deletion again')
    end
    local removed, nodes = {}, {}
    for _, key in ipairs(preview.ids) do removed[key] = true end
    for key, node in pairs(self.nodes) do if not removed[key] then nodes[key] = node end end
    local parent, children = assert(nodes[preview.parent]), {}
    for _, child in ipairs(parent.children) do if not removed[child] then children[#children + 1] = child end end
    nodes[parent.id] = node_shell(parent, children)
    local notes = retained_annotations(self.annotations, nodes)
    -- Prepare everything before replacing any live structure. In-flight save
    -- views and snapshots retain their original parents, notes and data.
    self.nodes, self.annotations = nodes, notes
    self._node_count = preview.remaining_count
    self._ids_cache = nil
    self.structure_revision = (self.structure_revision or 0) + 1
    annotation_change(self)
    return preview
end

function Tree:export_branch(id)
    local included = branch_ids(self, id)
    local ancestor = self.nodes[id]
    while ancestor and ancestor.parent ~= 0 do
        included[ancestor.parent] = true
        ancestor = self.nodes[ancestor.parent]
    end
    local kept = {}
    for key in pairs(included) do
        local node, children = self.nodes[key], {}
        for _, child in ipairs(node.children) do if included[child] then children[#children + 1] = child end end
        kept[key] = node_shell(node, children)
    end
    local ids, nodes = node_ids(kept), {}
    for _, key in ipairs(ids) do nodes[#nodes + 1] = kept[key] end
    local current = included[self.current] and self.current or id
    return clone({schema = wire_schema(ids, self.next_id), root = self.root, current = current,
        next_id = self.next_id, metadata = self.metadata, nodes = nodes,
        resume = included[self.current] and self.resume or nil,
        annotations = retained_annotations(self.annotations, kept)})
end

function Tree:set_name(name)
    local value = label_text(name)
    if self.metadata.name == value then return false end
    local metadata = clone(self.metadata)
    metadata.name = value
    self.metadata = metadata
    self.metadata_revision = (self.metadata_revision or 0) + 1
    return true
end

function Tree:peek(id)
    local node = assert(self.nodes[id], "Unknown checkpoint")
    return clone(node.snapshot)
end

function Tree:checkout(id)
    local snapshot = self:peek(id)
    self.current = id
    self.resume = nil
    return snapshot
end

-- A one-action Undo restores append-only structure, not a historical checkout.
-- Existing nodes are immutable; only newly appended nodes/child links can differ.
function Tree:undo_checkpoint()
    return {run_id = self.metadata.run_id, current = self.current, next_id = self.next_id,
        resume = clone(self.resume)}
end

-- Internal lifetime-safe view for the Undo controller. Checkpoint snapshots,
-- summaries and choice arrays are immutable after attachment; only the resume
-- shell is replaced by later actions. Avoid copying the whole hand a second
-- time after the controller already captured its before-state. Public callers
-- needing an editable isolated checkpoint continue to use undo_checkpoint().
function Tree:undo_checkpoint_view()
    local value = self.resume
    return {run_id = self.metadata.run_id, current = self.current, next_id = self.next_id,
        resume = value and {parent = value.parent, snapshot = value.snapshot,
            summary = value.summary, choices = value.choices} or nil}
end

local function checkpoint_resume(self, checkpoint)
    assert(type(checkpoint) == 'table' and checkpoint.run_id == self.metadata.run_id,
        'Undo checkpoint belongs to another run')
    assert(positive_integer(checkpoint.next_id) and checkpoint.next_id <= self.next_id
        and positive_integer(checkpoint.current) and checkpoint.current < checkpoint.next_id
        and self.nodes[checkpoint.current], 'Invalid Undo tree checkpoint')
    if checkpoint.resume ~= nil then
        local resume = checkpoint.resume
        assert(type(resume) == 'table' and resume.parent == checkpoint.current
            and type(resume.snapshot) == 'table' and resume.snapshot.seed == self.metadata.seed
            and type(resume.summary) == 'table', 'Invalid Undo resume checkpoint')
    end
    return clone(checkpoint.resume)
end

-- Continuous Undo moves through its operation snapshots while retaining every
-- historical branch. Old checkpoint.next_id is only a validity bound here.
function Tree:restore_cursor(checkpoint)
    local resume = checkpoint_resume(self, checkpoint)
    self.current, self.resume = checkpoint.current, resume
    return true
end

function Tree:rollback(checkpoint, capture_tail)
    local resume = checkpoint_resume(self, checkpoint)
    local previous_count = self:node_count()
    local revision = (self.structure_revision or 0) + 1
    local stash, affected, nodes, suffix, suffix_ids = nil, {}, {}, {}, {}
    for id, node in pairs(self.nodes) do
        if id >= checkpoint.next_id then
            suffix[id], suffix_ids[#suffix_ids + 1] = node, id
            if node.parent < checkpoint.next_id then affected[node.parent] = assert(self.nodes[node.parent]) end
        else nodes[id] = node end
    end
    table.sort(suffix_ids)
    if capture_tail and checkpoint.next_id < self.next_id then
        stash = {owner = self, run_id = self.metadata.run_id, prefix_next_id = checkpoint.next_id,
            next_id = self.next_id, expected_revision = revision, nodes = suffix, node_ids = suffix_ids, parents = {}}
        -- Nodes/snapshots are immutable; only parent links at the cut need their
        -- own tiny arrays. Never copy an entire worldline or retain a mutable
        -- prefix children array which rollback is about to edit in place.
    end
    for id, node in pairs(affected) do
        local children, original, kept = {}, {}, {}
        for _, child in ipairs(node.children) do
            original[#original + 1] = child
            if child < checkpoint.next_id then
                children[#children + 1], kept[#kept + 1] = child, child
            end
        end
        nodes[id] = node_shell(node, children)
        if stash then stash.parents[id] = {node = nodes[id], kept = kept, original = original} end
    end
    local notes = retained_annotations(self.annotations, nodes)
    if stash then
        local removed = empty_annotations()
        removed.next_fold_id = annotations(self).next_fold_id
        for id, name in pairs(annotations(self).bookmarks) do
            if not notes.bookmarks[id] then removed.bookmarks[id] = name end
        end
        for id, fold in pairs(annotations(self).folds) do
            if not notes.folds[id] then removed.folds[id] = clone(fold) end
        end
        stash.annotations = removed
    end
    self.nodes, self.annotations = nodes, notes
    self._node_count = previous_count - #suffix_ids
    self._ids_cache = nil
    self.current, self.next_id, self.resume = checkpoint.current, checkpoint.next_id, resume
    self.structure_revision = revision
    annotation_change(self)
    -- Metadata includes a monotonic progress lock and must never be rolled back.
    return true, stash
end

local function same_ids(a, b)
    if not (array(a, Tree.MAX_NODES) and array(b, Tree.MAX_NODES)) or #a ~= #b then return false end
    for i = 1, #a do if a[i] ~= b[i] then return false end end
    return true
end

-- Reattach the first Undo's discarded suffix when continuous Undo is accepted.
-- Validate the entire candidate graph before changing any live node or link.
function Tree:restore_tail(stash)
    assert(type(stash) == 'table' and stash.owner == self and stash.run_id == self.metadata.run_id,
        'Undo tail belongs to another worldline')
    assert(positive_integer(stash.prefix_next_id) and positive_integer(stash.next_id)
        and stash.prefix_next_id < stash.next_id and self.next_id == stash.prefix_next_id
        and (self.structure_revision or 0) == stash.expected_revision,
        'Undo tail is stale or conflicts with newer worldline history')
    assert(type(stash.nodes) == 'table' and type(stash.parents) == 'table'
        and array(stash.node_ids, Tree.MAX_NODES), 'Invalid Undo tail')
    local cut, limit, prepared, nodes, seen_ids = stash.prefix_next_id, stash.next_id, {}, {}, {}
    for _, id in ipairs(stash.node_ids) do
        assert(positive_integer(id) and not seen_ids[id] and id >= cut and id < limit
            and self.nodes[id] == nil and type(stash.nodes[id]) == 'table', 'Conflicting Undo tail node')
        seen_ids[id] = true
    end
    for id in pairs(stash.nodes) do
        assert(seen_ids[id], 'Invalid Undo tail ID')
    end
    assert(self:node_count() + #stash.node_ids <= self.MAX_NODES, 'Checkpoint limit reached (10000); history was not truncated')
    for id, node in pairs(self.nodes) do assert(id < cut, 'Invalid Undo tail prefix'); nodes[id] = node end
    for id, node in pairs(stash.nodes) do nodes[id] = node end
    for id, links in pairs(stash.parents) do
        assert(positive_integer(id) and id < cut and type(links) == 'table'
            and links.node == self.nodes[id] and same_ids(links.kept, self.nodes[id].children)
            and array(links.original, Tree.MAX_NODES), 'Undo tail parent links changed')
        prepared[id] = {}
        for _, child in ipairs(links.original) do prepared[id][#prepared[id] + 1] = child end
        nodes[id] = node_shell(nodes[id], prepared[id])
    end
    local referenced = {[1] = true}
    for id, node in pairs(nodes) do
        assert(type(node) == 'table' and node.id == id and type(node.parent) == 'number'
            and node.parent % 1 == 0 and node.parent >= 0 and node.parent < id
            and (id == 1 and node.parent == 0 or id > 1 and node.parent > 0), 'Invalid Undo tail parent')
        assert(type(node.snapshot) == 'table' and node.snapshot.seed == self.metadata.seed
            and type(node.summary) == 'table' and type(node.action) == 'table'
            and type(node.action.kind) == 'string', 'Invalid Undo tail node')
        local children = prepared[id] or node.children
        assert(array(children, Tree.MAX_NODES), 'Invalid Undo tail child list')
        for _, child in ipairs(children) do
            assert(positive_integer(child) and child > id and child < limit and nodes[child]
                and nodes[child].parent == id and not referenced[child], 'Invalid Undo tail connection')
            referenced[child] = true
        end
    end
    for id in pairs(nodes) do assert(referenced[id], 'Disconnected Undo tail node') end
    local restored_annotations
    if stash.annotations then
        local merged = clone(annotations(self))
        for id, name in pairs(stash.annotations.bookmarks or {}) do
            if merged.bookmarks[id] == nil then merged.bookmarks[id] = name end
        end
        for id, fold in pairs(stash.annotations.folds or {}) do
            if merged.folds[id] == nil then merged.folds[id] = clone(fold) end
        end
        merged.next_fold_id = math.max(merged.next_fold_id, stash.annotations.next_fold_id or 1)
        restored_annotations = validate_annotations(merged, nodes)
    end
    self.nodes = nodes
    self._node_count = self:node_count() + #stash.node_ids
    self._ids_cache = nil
    self.next_id = limit
    self.structure_revision = (self.structure_revision or 0) + 1
    if restored_annotations then self.annotations = restored_annotations; annotation_change(self) end
    if normalize_folds(self.nodes, annotations(self)) then annotation_change(self) end
    -- Current operation snapshot/resume and monotonic metadata remain intact.
    return true
end

function Tree:commit(action, snapshot, summary, matcher)
    assert(type(snapshot) == "table" and snapshot.seed == self.metadata.seed, "Checkpoint seed mismatch")
    assert(type(action) == "table" and type(action.kind) == "string", "Invalid action")
    local id, parent = self.next_id, assert(self.nodes[self.current], "Missing current checkpoint")
    assert(matcher == nil or type(matcher) == 'function', 'Invalid checkpoint matcher')
    if matcher then
        for _, child_id in ipairs(parent.children) do
            local child = self.nodes[child_id]
            if matcher(child.action, child.snapshot, action, snapshot) then
                self.current, self.resume = child.id, nil
                return child, true
            end
        end
    end
    assert(self:node_count() < self.MAX_NODES, "Checkpoint limit reached (10000); history was not truncated")
    assert(self.next_id < Tree.MAX_ID, 'Checkpoint ID limit reached; history was not truncated')
    -- Clone before mutating the tree, so a failed snapshot cannot leave half a node.
    local node = {id = id, parent = parent.id, children = {}, action = clone(action),
        snapshot = clone(snapshot), summary = clone(with_deck_key(summary or {}))}
    self.nodes[id] = node
    parent.children[#parent.children + 1] = id
    self.next_id, self.current = id + 1, id
    self._node_count = self:node_count() + 1
    self._ids_cache = nil
    self.structure_revision = (self.structure_revision or 0) + 1
    self.resume = nil
    if normalize_folds(self.nodes, annotations(self)) then annotation_change(self) end
    return node, false
end

function Tree:rows()
    local result, stack = {}, {{id = self.root, depth = 0}}
    while #stack > 0 do
        local position = table.remove(stack)
        local node = self.nodes[position.id]
        result[#result + 1] = {id = node.id, depth = position.depth, parent = node.parent,
            action = clone(node.action), summary = clone(node.summary), current = node.id == self.current}
        for i = #node.children, 1, -1 do
            stack[#stack + 1] = {id = node.children[i], depth = position.depth + 1}
        end
    end
    return result
end

-- View-only projection. Folding never edits a checkpoint, action or real parent
-- link. Only linear interiors may disappear. Both boundaries and every branch
-- point stay visible, and disjoint folded intervals remain distinct regions.
function Tree:visible_rows()
    local cached = self._presentation_cache
    if cached and cached.structure == self.structure_revision and cached.annotation == self.annotation_revision
        and cached.current == self.current then return cached.rows end
    local data, hidden, anchors, regions, interiors, boundaries = annotations(self), {}, {}, {}, {}, {}
    for _, fold in ipairs(sorted_folds(data)) do
        local id = fold.id
        local group = anchors[fold.start_id] or {}
        anchors[fold.start_id] = group; group[#group + 1] = id
        if fold.collapsed then
            local path = fold_path(self.nodes, fold)
            if path and overlaps(fold, path, interiors, boundaries) then path = nil end
            if path then
                reserve_region(fold, path, interiors, boundaries)
                regions[#regions + 1] = {id = id, start_id = fold.start_id, end_id = fold.end_id,
                    label = fold.label, hidden_count = #path, collapsed = true}
                for _, hidden_id in ipairs(path) do hidden[hidden_id] = true end
            end
        end
    end
    local active_ids = {}; for _, region in ipairs(regions) do active_ids[region.id] = true end
    local rows, by_id, nearest, hidden_distance, stack = {}, {}, {}, {}, {self.root}
    rows.fold_regions = regions
    while #stack > 0 do
        local id = table.remove(stack)
        local node = self.nodes[id]
        if hidden[id] then
            nearest[id] = nearest[node.parent]
            hidden_distance[id] = (hidden_distance[node.parent] or 0) + 1
            local anchor = by_id[nearest[id]]
            if anchor then anchor.collapsed_count = anchor.collapsed_count + 1 end
        else
            local fold_ids, labels = anchors[id] or {}, {}
            table.sort(fold_ids)
            for _, fold_id in ipairs(fold_ids) do
                if active_ids[fold_id] then labels[#labels + 1] = data.folds[fold_id].label end
            end
            local row = {id = id, parent = nearest[node.parent] or 0, source_parent = node.parent,
                action = node.action, summary = node.summary, current = id == self.current,
                bookmark = data.bookmarks[id], fold_ids = fold_ids, collapsed_labels = labels,
                collapsed_count = 0, hidden_steps = hidden_distance[node.parent] or 0}
            rows[#rows + 1], by_id[id], nearest[id] = row, row, id
        end
        for i = #node.children, 1, -1 do stack[#stack + 1] = node.children[i] end
    end
    self._presentation_cache = {structure = self.structure_revision, annotation = self.annotation_revision,
        current = self.current, rows = rows}
    return rows
end

function Tree:export()
    local nodes, ids = {}, ordered_ids(self)
    for _, id in ipairs(ids) do nodes[#nodes + 1] = clone(self.nodes[id]) end
    return {schema = wire_schema(ids, self.next_id), root = self.root, current = self.current, next_id = self.next_id,
        metadata = clone(self.metadata), nodes = nodes, resume = clone(self.resume), annotations = clone(annotations(self))}
end

-- Internal synchronous encoder view: checkpoints are already immutable and the
-- data-only Codec never mutates them. Keep public export() deeply isolated.
function Tree:export_view()
    local nodes, ids = {}, ordered_ids(self)
    for _, id in ipairs(ids) do nodes[#nodes + 1] = self.nodes[id] end
    return {schema = wire_schema(ids, self.next_id), root = self.root, current = self.current, next_id = self.next_id,
        metadata = self.metadata, nodes = nodes, resume = self.resume, annotations = self.annotations}
end

-- A background save may span many gameplay updates. Snapshots, actions and
-- summaries are immutable once attached; cursor, metadata and child links are
-- not. Freeze only those small mutable parts instead of cloning every hand in
-- the entire history. Callers replacing checkpoint tags must use copy-on-write.
function Tree:export_save_view()
    local nodes, ids = {}, ordered_ids(self)
    for _, id in ipairs(ids) do
        local node = self.nodes[id]
        local children = {}
        for i, child in ipairs(node.children) do children[i] = child end
        nodes[#nodes + 1] = {id = node.id, parent = node.parent, children = children,
            action = node.action, summary = node.summary, snapshot = node.snapshot}
    end
    local resume = self.resume and {parent = self.resume.parent,
        snapshot = self.resume.snapshot, summary = self.resume.summary, choices = self.resume.choices} or nil
    return {schema = wire_schema(ids, self.next_id), root = self.root, current = self.current, next_id = self.next_id,
        metadata = clone(self.metadata), nodes = nodes, resume = resume, annotations = clone(annotations(self))}
end

local function import(payload)
    assert(type(payload) == "table" and (payload.schema == 1 or payload.schema == 2), "Unknown tree schema")
    assert(valid_metadata(payload.metadata), "Invalid run metadata")
    assert(array(payload.nodes, Tree.MAX_NODES) and #payload.nodes > 0, "Invalid node list")
    assert(payload.root == 1 and positive_integer(payload.current), "Invalid tree cursor")
    assert(positive_integer(payload.next_id) and payload.next_id >= #payload.nodes + 1
        and (payload.schema == 2 or payload.next_id == #payload.nodes + 1), "Invalid next checkpoint ID")
    local nodes = {}
    for _, node in ipairs(payload.nodes) do
        assert(type(node) == "table" and positive_integer(node.id) and node.id < payload.next_id
            and not nodes[node.id], "Invalid or repeated checkpoint ID")
        assert(type(node.parent) == "number" and node.parent % 1 == 0
            and node.parent >= 0 and node.parent < node.id, "Invalid checkpoint parent")
        assert(array(node.children, Tree.MAX_NODES), "Invalid child list")
        assert(type(node.action) == "table" and type(node.action.kind) == "string"
            and #node.action.kind <= 128 and type(node.summary) == "table", "Invalid action data")
        assert(type(node.snapshot) == "table" and node.snapshot.seed == payload.metadata.seed,
            "Checkpoint seed mismatch")
        nodes[node.id] = clone(with_summary_deck(node))
    end
    assert(nodes[1] and nodes[1].parent == 0 and nodes[payload.current], "Invalid root or current checkpoint")
    local referenced = {[1] = true}
    if payload.schema == 1 then
        for id = 1, #payload.nodes do assert(nodes[id], "Missing checkpoint ID") end
    end
    for id, node in pairs(nodes) do
        if id ~= 1 then assert(node.parent > 0, "Disconnected root") end
        for _, child in ipairs(node.children) do
            assert(positive_integer(child) and nodes[child] and nodes[child].parent == id,
                "Parent/child mismatch")
            assert(not referenced[child], "Repeated child reference")
            referenced[child] = true
        end
    end
    for id in pairs(nodes) do assert(referenced[id], "Disconnected checkpoint") end
    local resume
    if payload.resume ~= nil then
        local value = payload.resume
        assert(type(value) == "table" and value.parent == payload.current and nodes[value.parent]
            and type(value.snapshot) == "table" and value.snapshot.seed == payload.metadata.seed
            and type(value.summary) == "table", "Invalid in-phase resume checkpoint")
        resume = clone(with_summary_deck(value))
    end
    local notes = validate_annotations(payload.annotations, nodes)
    local metadata = clone(with_deck_key(payload.metadata))
    if metadata.name ~= nil then metadata.name = label_text(metadata.name) end
    return setmetatable({root = 1, current = payload.current, next_id = payload.next_id, structure_revision = 0,
        annotation_revision = 0, metadata_revision = 0, _node_count = #payload.nodes,
        annotations = notes, metadata = metadata, nodes = nodes, resume = resume}, Tree)
end

function Tree.import(payload)
    local ok, result = pcall(import, payload)
    if not ok then return nil, tostring(result) end
    return result
end

return Tree

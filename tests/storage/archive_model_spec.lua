local Tree = dofile('src/domain/tree.lua')
local Codec = dofile('src/storage/codec.lua')
local function snapshot(id) return {seed='EDITTEST', save={GAME={dollars=id, pseudorandom={seed='EDITTEST',shop=id/100}}}} end
local function equal(a,b)
    assert(type(a)==type(b))
    if type(a)~='table' then assert(a==b);return end
    for key,value in pairs(a) do equal(value,b[key]) end
    for key in pairs(b) do assert(a[key]~=nil) end
end
local function fixture()
    local t=Tree.new(snapshot(1), {seed='EDITTEST',run_id='archive-edit',progress_locked=true,
        pool_environment={schema=1,centers={j_locked=4}},custom_metadata={keep='yes'}})
    local function append(parent,id)
        t:checkout(parent)
        local n=t:commit({kind='phase',choices={{kind='buy',card_key='j_'..id}}},snapshot(id),{state='SHOP',dollars=id})
        assert(n.id==id)
    end
    append(1,2);append(2,3);append(3,4);append(2,5);append(5,6);append(1,7);append(7,8)
    t:set_bookmark(4,'Removed bookmark');t:set_bookmark(6,'Kept bookmark');t:set_bookmark(8,'Current bookmark')
    local removed_fold=t:add_fold(2,4,'Removed fold')
    local kept_fold=t:add_fold(2,6,'Kept fold')
    t.resume={parent=8,snapshot=snapshot(88),summary={dollars=88},choices={{kind='reroll_shop'}}}
    return t,removed_fold,kept_fold
end

local t,removed_fold,kept_fold=fixture()
local before=t:export()
local old_metadata=t.metadata
local frozen=t:export_save_view()
assert(t:set_name('  新世界线  ') and t.metadata.name=='新世界线' and t.metadata~=old_metadata)
assert(not t:set_name('新世界线') and frozen.metadata.name==nil and old_metadata.name==nil)
assert(t.metadata.progress_locked and t.metadata.pool_environment.centers.j_locked==4)
assert(t.metadata_revision==1 and t.structure_revision==7)
for _,bad in ipairs({'',' 	 ','bad\nname',string.rep('a',65),'\192\128','\237\160\128'}) do
    local wire,metadata=t:export(),t.metadata
    assert(not pcall(t.set_name,t,bad))
    assert(t.metadata==metadata);equal(wire,t:export())
end
assert(t:set_name(string.rep('牌',64)))
assert(Tree.import(t:export()).metadata.name==string.rep('牌',64))

local rows=t:visible_rows()
local preview=t:prune_preview(3)
assert(preview.allowed and preview.id==3 and preview.parent==2 and preview.count==2
    and preview.ids[1]==3 and preview.ids[2]==4 and preview.remaining_count==6
    and preview.removed_bookmarks==1 and preview.removed_folds==1 and not preview.contains_current)
assert(t:node_count()==8 and t:get(3) and t:get(4), 'preview never edits the worldline')
local retained_resume=t.resume
local result=t:prune_branch(3,preview)
assert(result.count==2 and t:node_count()==6 and t.next_id==9 and t.current==8 and t.resume==retained_resume)
assert(not t:get(3) and not t:get(4) and #t:get(2).children==1 and t:get(2).children[1]==5)
assert(not t.annotations.bookmarks[4] and t.annotations.bookmarks[6]=='Kept bookmark'
    and not t.annotations.folds[removed_fold] and t.annotations.folds[kept_fold])
assert(t:visible_rows()~=rows and t:get(6).snapshot.save.GAME.dollars==6)
assert(frozen.nodes[2].children[1]==3 and frozen.nodes[4].id==4
    and frozen.annotations.bookmarks[4]=='Removed bookmark' and frozen.annotations.folds[removed_fold],
    'an already queued save retains its complete old graph and annotations')
for _,id in ipairs({1,2,5,6,7,8}) do
    equal(t:get(id).snapshot,before.nodes[id].snapshot)
    equal(t:get(id).action,before.nodes[id].action)
    equal(t:get(id).summary,before.nodes[id].summary)
end
local sparse=t:export()
assert(sparse.schema==2 and #sparse.nodes==6 and sparse.nodes[3].id==5 and sparse.next_id==9)
local imported=assert(Tree.import(assert(Codec.decode(Codec.encode(sparse,TEST_JSON),TEST_JSON))))
assert(imported:node_count()==6 and imported.current==8 and imported.next_id==9 and not imported:get(3))
local saved=assert(Tree.import(t:export_save_view()))
assert(saved:node_count()==6 and saved:get(5).parent==2)
local appended=imported:commit({kind='new'},snapshot(9),{})
assert(appended.id==9 and imported:node_count()==7 and imported.next_id==10,
    'new nodes never recycle deleted IDs')
for _,id in ipairs({1,7,8}) do
    local p=t:prune_preview(id)
    assert(not p.allowed and p.contains_current and p.reason)
    local wire=t:export()
    assert(not pcall(t.prune_branch,t,id));equal(wire,t:export())
end
assert(not pcall(t.prune_preview,t,3) and not pcall(t.prune_branch,t,999))
local stale=t:prune_preview(5)
t:set_bookmark(6,'Changed during confirmation')
local pre_stale=t:export()
assert(not pcall(t.prune_branch,t,5,stale));equal(pre_stale,t:export())

-- A branch export keeps its full causal prefix and its entire suworldline. It
-- never rewrites root state, operation order or snapshot/card/RNG identifiers.
local source,export_removed,export_kept=fixture()
source:set_name('Shared route')
local original=source:export()
local branch=source:export_branch(5)
assert(branch.schema==2 and branch.root==1 and branch.current==5 and branch.resume==nil
    and branch.next_id==9 and #branch.nodes==4)
local branch_tree=assert(Tree.import(branch))
assert(branch_tree:get(1).children[1]==2 and #branch_tree:get(1).children==1
    and branch_tree:get(2).children[1]==5 and #branch_tree:get(2).children==1
    and branch_tree:get(5).children[1]==6 and not branch_tree:get(7))
for _,id in ipairs({1,2,5,6}) do
    equal(branch_tree:get(id).snapshot,source:get(id).snapshot)
    equal(branch_tree:get(id).action,source:get(id).action)
end
assert(branch.annotations.folds[export_kept] and not branch.annotations.folds[export_removed]
    and branch.annotations.bookmarks[6] and not branch.annotations.bookmarks[8])
equal(branch.metadata,source.metadata)
branch.nodes[1].snapshot.save.GAME.pseudorandom.shop=-99
branch.metadata.pool_environment.centers.j_locked=8
branch.annotations.bookmarks[6]='Changed in export'
equal(original,source:export())
equal(source:export_branch(1),source:export())
source:checkout(3)
source.resume={parent=3,snapshot=snapshot(33),summary={},choices={{kind='buy'}}}
local selected_current=source:export_branch(2)
assert(selected_current.current==3 and selected_current.resume.parent==3
    and selected_current.resume~=source.resume and #selected_current.nodes==6)
assert(not pcall(source.export_branch,source,12345))

-- Schema 1 stays strict. Schema 2 has a bounded live list, not an allocation
-- proportional to its largest monotonically assigned ID.
local dense=Tree.new(snapshot(1),{seed='EDITTEST',run_id='dense'})
dense:commit({kind='new'},snapshot(2),{})
assert(dense:export().schema==1)
local huge=dense:export();huge.schema=2
local large_id=1000000000000
huge.nodes[1].children={large_id};huge.nodes[2].id=large_id
huge.current,huge.next_id=large_id,large_id+1
local wide=assert(Tree.import(huge))
assert(wide:node_count()==2 and #wide:export_save_view().nodes==2)
local denied=wide:export();denied.schema=1
assert(not Tree.import(denied))
wide:checkout(1);wide:prune_branch(large_id)
assert(wide:node_count()==1 and wide.next_id==large_id+1)
local checkpoint=wide:undo_checkpoint()
local first=wide:commit({kind='first'},snapshot(2),{})
wide:commit({kind='child'},snapshot(3),{})
wide:checkout(1)
local survivor=wide:commit({kind='other'},snapshot(4),{})
wide:prune_branch(first.id)
assert(wide:node_count()==2 and survivor.id==large_id+3)
local prior=wide:export_save_view()
local ok,tail=wide:rollback(checkpoint,true)
assert(ok and tail and #tail.node_ids==1 and tail.node_ids[1]==survivor.id
    and wide:node_count()==1 and wide.next_id==large_id+1)
assert(wide:restore_tail(tail) and wide:node_count()==2 and wide.next_id==large_id+4)
assert(Tree.import(wide:export()) and prior.nodes[1].children[1]==survivor.id)
wide.MAX_NODES=2
assert(not pcall(wide.commit,wide,{kind='full'},snapshot(5),{}))
wide:prune_branch(survivor.id)
local freed=wide:commit({kind='freed'},snapshot(5),{})
assert(freed.id==large_id+4 and wide:node_count()==2, 'pruning frees live capacity without recycling IDs')
local invalid=wide:export();invalid.next_id=invalid.nodes[2].id
assert(not Tree.import(invalid))
invalid=wide:export();invalid.nodes[1].children[1]=invalid.nodes[2].id+1
assert(not Tree.import(invalid))
invalid=wide:export();invalid.metadata.name=string.rep('x',65)
assert(not Tree.import(invalid))
print('PASS archive model: names, protected branch pruning, sparse IDs, retained causal exports, atomic edits and frozen saves')

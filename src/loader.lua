-- One module registry for Steamodded, ZIP mounts, workers and offline tests.
-- The compatibility ID is fixed even after SMODS.current_mod is cleared.
local Loader = {MOD_ID = "WorldLine"}
local paths = {
    app = "runtime/app.lua",
    archive_browser = "storage/archive_browser.lua",
    archive_browser_worker = "workers/archive_browser.lua",
    card_presentation = "ui/card_presentation.lua",
    card_runtime = "runtime/card_runtime.lua",
    card_visuals = "runtime/card_visuals.lua",
    cashout = "runtime/cashout.lua",
    choices = "domain/choices.lua",
    codec = "storage/codec.lua",
    compositor = "ui/compositor.lua",
    details = "ui/details.lua",
    diff = "ui/diff.lua",
    event_policy = "runtime/event_policy.lua",
    file_dialog = "platform/file_dialog.lua",
    file_dialog_windows = "platform/file_dialog_windows.lua",
    file_dialog_worker = "workers/file_dialog.lua",
    film = "video/plan.lua",
    film_child = "video/child.lua",
    film_encoder = "video/encoder.lua",
    film_files = "video/sources.lua",
    film_host = "video/host.lua",
    film_identity = "video/identity.lua",
    film_prepare = "video/prepare.lua",
    film_runtime = "video/playback.lua",
    film_windows = "platform/windows.lua",
    film_worker = "workers/encode.lua",
    film_zip = "video/bootstrap_zip.lua",
    graph = "ui/graph.lua",
    hooks = "runtime/hooks.lua",
    hand_order = "runtime/hand_order.lua",
    i18n = "ui/i18n.lua",
    input_queue = "runtime/input_queue.lua",
    native_visuals = "ui/native_visuals.lua",
    pool_environment = "domain/pool_environment.lua",
    progress = "domain/progress.lua",
    renderer = "ui/renderer.lua",
    replay = "domain/replay.lua",
    save_worker = "workers/save.lua",
    selection = "ui/selection.lua",
    snapshot = "runtime/snapshot.lua",
    storage = "storage/repository.lua",
    tree = "domain/tree.lua",
    ui = "ui/controller.lua",
    undo = "runtime/undo.lua",
}

function Loader.path(name)
    return assert(paths[name], 'Unknown WorldLine module: ' .. tostring(name))
end

function Loader.load(name)
    local path = Loader.path(name)
    if SMODS and SMODS.load_file then
        return assert(SMODS.load_file(path, Loader.MOD_ID))()
    end
    return dofile('src/' .. path)
end

function Loader.source(name)
    local path = Loader.path(name)
    if SMODS and SMODS.NFS then
        local mod = SMODS.Mods and SMODS.Mods[Loader.MOD_ID] or SMODS.current_mod
        assert(mod and mod.id == Loader.MOD_ID and mod.path, 'WorldLine source directory is unavailable')
        return assert(SMODS.NFS.read(mod.path .. path))
    end
    local file = assert(io.open('src/' .. path, 'rb'))
    local source = file:read('*a')
    file:close()
    return assert(source)
end

return Loader

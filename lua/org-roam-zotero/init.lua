-------------------------------------------------------------------------------
-- INIT.LUA
--
-- Main entry point for the org-roam-zotero plugin.
--
-- This plugin extends org-roam.nvim to treat Zotero collection items as
-- virtual org-roam nodes.  Each Zotero item is represented as a node whose
-- file path uses a `zotero://select/...` URI that conforms to the Zotero
-- protocol specification.
--
-- Opening a Zotero node opens an ephemeral buffer populated from the
-- Zotero Web API; writing that buffer pushes the content back to Zotero.
-- If no org-roam-tagged child note exists in Zotero, one is created on
-- the first write from the ephemeral buffer (not during sync).
--
-- On write, any org-roam links to other Zotero virtual nodes found in
-- the buffer body are reflected back to Zotero as `dc:relation` entries
-- on the child note.
--
-- Sync runs automatically on OrgRoamInitialized (asynchronously via
-- plenary.async) and can also be triggered manually with :ZoteroSync.
--
-- Usage:
--   require("org-roam-zotero").setup({
--     api_key     = "YOUR_ZOTERO_API_KEY",
--     library_id  = "YOUR_USER_OR_GROUP_ID",
--     -- library_type = "user",   -- default; or "group"
--     -- auto_sync    = true,     -- default; set false to disable auto sync
--   })
--
-- Commands:
--   :ZoteroSync   - fetch items from Zotero and register them as org-roam nodes
-------------------------------------------------------------------------------

local Config = require("org-roam-zotero.config")
local Api = require("org-roam-zotero.api")
local Buffer = require("org-roam-zotero.buffer")

local Node = require("org-roam.core.file.node")
local Range = require("org-roam.core.file.range")

---@class org-roam-zotero.Plugin
---@field private __config org-roam-zotero.Config
---@field private __api org-roam-zotero.Api
---@field private __buffer org-roam-zotero.Buffer
---@field private __roam OrgRoam|nil
---@field private __synced_nodes table<string, org-roam.core.file.Node> #nodes to re-insert after DB reloads
---@field private __load_wrapped boolean #whether we have wrapped database:load()
local M = {}
M.__index = M

---@type org-roam-zotero.Plugin|nil
local INSTANCE = nil

---Configures and initialises the plugin.
---
---Must be called after `require("org-roam")` has been loaded.
---
---@param opts org-roam-zotero.Config
function M.setup(opts)
    local config = Config:new(opts)

    -- Validate required fields
    if config.api_key == "" then
        vim.notify("org-roam-zotero: api_key is required", vim.log.levels.WARN)
    end
    if config.library_id == "" then
        vim.notify("org-roam-zotero: library_id is required", vim.log.levels.WARN)
    end

    local api = Api:new(config)
    local buffer = Buffer:new(api, config)

    local instance = setmetatable({}, M)
    instance.__config = config
    instance.__api = api
    instance.__buffer = buffer
    instance.__roam = nil
    instance.__synced_nodes = {}
    instance.__load_wrapped = false

    INSTANCE = instance

    -- Register buffer autocmds for zotero:// scheme
    buffer:register_autocmds()

    -- Register user commands
    vim.api.nvim_create_user_command("ZoteroSync", function()
        M.sync()
    end, { desc = "Sync Zotero items as org-roam nodes" })

    -- Always sync on OrgRoamInitialized, asynchronously in the background.
    -- The auto_sync option can be set to false to opt out.
    if config.auto_sync then
        vim.api.nvim_create_autocmd("User", {
            pattern = "OrgRoamInitialized",
            once = true,
            callback = function()
                -- Small delay to ensure database is ready, then run async
                vim.defer_fn(function()
                    M.sync()
                end, 100)
            end,
        })
    end
end

---Returns the OrgRoam instance, resolving it lazily.
---@return OrgRoam
local function get_roam()
    if INSTANCE and INSTANCE.__roam then
        return INSTANCE.__roam
    end
    local roam = require("org-roam")
    if INSTANCE then
        INSTANCE.__roam = roam
    end
    return roam
end

---Re-inserts all tracked Zotero nodes into the org-roam database.
---Called after database:load() to restore virtual nodes that were removed
---because their zotero:// file paths don't exist on disk.
---@param db org-roam.core.Database
local function reinsert_nodes(db)
    if not INSTANCE or vim.tbl_isempty(INSTANCE.__synced_nodes) then
        return
    end

    for id, node in pairs(INSTANCE.__synced_nodes) do
        if not db:has(id) then
            db:insert(node, { id = id, overwrite = true })
            -- Re-establish links from the node's linked field
            local linked_ids = vim.tbl_keys(node.linked)
            if #linked_ids > 0 then
                db:link(id, linked_ids)
            end
        end
    end
end

---Wraps the org-roam database's load() method so that after every reload,
---our virtual Zotero nodes are re-inserted.  This is necessary because
---the loader compares files in the database against files on disk, and
---removes any that are only in the database — which includes our
---zotero:// URIs.
---
---The wrapper is installed once, on the database instance, so it does not
---modify the Database class itself.
local function ensure_load_wrapped()
    if not INSTANCE or INSTANCE.__load_wrapped then
        return
    end

    local roam = get_roam()
    local db = roam.database

    -- Capture the original load method from the metatable
    local mt = getmetatable(db) or {}
    local original_load = rawget(mt, "load")
    if not original_load then
        return
    end

    -- Store a wrapped version directly on the instance so the __index
    -- metamethod finds it via rawget(self, key) before the metatable.
    rawset(db, "load", function(self, opts)
        return original_load(self, opts):next(function(result)
            -- After the loader finishes, re-insert any missing Zotero nodes.
            -- The result contains {database = core_db, files = ...}.
            if result and result.database then
                reinsert_nodes(result.database)
            end
            return result
        end)
    end)

    INSTANCE.__load_wrapped = true
end

---Creates an org-roam Node for a Zotero item.
---@param item org-roam-zotero.ZoteroItem
---@param config org-roam-zotero.Config
---@return org-roam.core.file.Node
local function make_node(item, config)
    local item_key = item.data.key
    local node_id = "zotero-" .. item_key
    local uri = Buffer.build_uri(config.library_type, config.library_id, item_key)

    local tags = {}
    if item.data.tags then
        for _, t in ipairs(item.data.tags) do
            if t.tag then
                table.insert(tags, t.tag)
            end
        end
    end
    -- Always add a "zotero" tag so users can filter
    table.insert(tags, "zotero")

    return Node:new({
        id = node_id,
        origin = uri,
        range = Range:new(
            { row = 0, column = 0, offset = 0 },
            { row = 0, column = 0, offset = 0 }
        ),
        file = uri,
        mtime = 0,
        title = item.data.title or item_key,
        aliases = {},
        tags = tags,
        level = 0,
        linked = {},
    })
end

---Synchronises Zotero items into the org-roam database.
---
---Fetches all top-level items from the configured Zotero library and
---inserts a virtual node for each into the org-roam database.  If an item
---already has an org-roam-tagged child note, the note metadata is cached
---for the buffer handler; otherwise the note is created lazily on first
---write from the ephemeral buffer.
---
---The sync is run inside `plenary.async.void` so that `vim.notify` calls
---and database operations can be scheduled back onto the main thread.
---
---Relations are *not* read from Zotero here.  Instead, when a virtual
---node's buffer is written, the links found in the body are pushed to
---Zotero as `dc:relation` entries (see buffer.lua).
---
---@param opts? {on_done?:fun(count:integer)}
function M.sync(opts)
    opts = opts or {}
    if not INSTANCE then
        vim.notify("org-roam-zotero: call setup() first", vim.log.levels.ERROR)
        return
    end

    local async = require("plenary.async")

    async.void(function()
        local ok, err = pcall(function()
            async.util.scheduler()
            vim.notify("org-roam-zotero: syncing Zotero items…", vim.log.levels.INFO)

            local api = INSTANCE.__api

            -- Fetch items
            local fetch_ok, items = api:fetch_items()
            if not fetch_ok then
                async.util.scheduler()
                vim.notify("org-roam-zotero: failed to fetch items: " .. tostring(items), vim.log.levels.ERROR)
                return
            end

            ---@cast items org-roam-zotero.ZoteroItem[]
            local count = 0

            for _, item in ipairs(items) do
                -- Skip attachments, notes, etc. at the top level
                if item.data.itemType ~= "attachment" and item.data.itemType ~= "note" then
                    local node = make_node(item, INSTANCE.__config)

                    -- Try to find an existing org-roam note (but don't create one)
                    local note_ok, note = api:fetch_note(item.data.key)
                    if note_ok and note then
                        ---@cast note org-roam-zotero.ZoteroItem
                        -- Cache note metadata for the buffer handler
                        INSTANCE.__buffer.__note_cache[item.data.key] = {
                            note_key = note.data.key,
                            version = note.data.version,
                        }
                    end
                    -- If no note exists, the cache entry stays nil; note is created
                    -- on first write from the ephemeral buffer.

                    -- Track node for re-insertion after database reloads
                    INSTANCE.__synced_nodes[node.id] = node

                    -- Insert into org-roam database (overwrite if already present).
                    async.util.scheduler()
                    local roam = get_roam()
                    roam.database:insert(node, { overwrite = true }):wait()

                    count = count + 1
                end
            end

            -- Install the load() wrapper so Zotero nodes survive future reloads
            async.util.scheduler()
            ensure_load_wrapped()
            vim.notify(
                string.format("org-roam-zotero: synced %d Zotero item(s)", count),
                vim.log.levels.INFO
            )
            if opts.on_done then
                opts.on_done(count)
            end
        end)

        if not ok then
            async.util.scheduler()
            vim.notify("org-roam-zotero: sync error: " .. tostring(err), vim.log.levels.ERROR)
        end
    end)()
end

---Returns the current plugin instance (for testing/external use).
---@return org-roam-zotero.Plugin|nil
function M.instance()
    return INSTANCE
end

---Resets the plugin state (primarily for testing).
function M.reset()
    INSTANCE = nil
end

return M

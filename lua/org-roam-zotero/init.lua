-------------------------------------------------------------------------------
-- INIT.LUA
--
-- Main entry point for the org-roam-zotero plugin.
--
-- This plugin extends org-roam.nvim to treat Zotero collection items as
-- virtual org-roam nodes.  Each Zotero item that has a child note is
-- represented as a node whose file path uses the `zotero://` URI scheme.
--
-- Opening a Zotero node opens an ephemeral buffer populated from the
-- Zotero Web API; writing that buffer pushes the content back to Zotero.
--
-- Usage:
--   require("org-roam-zotero").setup({
--     api_key     = "YOUR_ZOTERO_API_KEY",
--     library_id  = "YOUR_USER_OR_GROUP_ID",
--     -- library_type = "user",   -- default; or "group"
--     -- auto_sync    = false,    -- set true to sync on database load
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
    local buffer = Buffer:new(api)

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

    -- If auto_sync is enabled, hook into org-roam database load
    if config.auto_sync then
        vim.api.nvim_create_autocmd("User", {
            pattern = "OrgRoamInitialized",
            once = true,
            callback = function()
                -- Small delay to ensure database is ready
                vim.defer_fn(function()
                    M.sync()
                end, 500)
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

---Creates an org-roam Node for a Zotero item + note pair.
---@param item org-roam-zotero.ZoteroItem
---@param note org-roam-zotero.ZoteroItem
---@return org-roam.core.file.Node
local function make_node(item, note)
    local item_key = item.data.key
    local note_key = note.data.key
    local node_id = "zotero-" .. item_key .. "-" .. note_key
    local uri = Buffer.build_uri(item_key, note_key)

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
        origin = "zotero://" .. item_key,
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
---Fetches all top-level items from the configured Zotero library, finds
---those with at least one `note` child, and inserts a virtual node for each
---into the org-roam database.
---
---@param opts? {on_done?:fun(count:integer)}
function M.sync(opts)
    opts = opts or {}
    if not INSTANCE then
        vim.notify("org-roam-zotero: call setup() first", vim.log.levels.ERROR)
        return
    end

    local api = INSTANCE.__api

    vim.notify("org-roam-zotero: syncing Zotero items…", vim.log.levels.INFO)

    -- Fetch items (synchronous for simplicity; runs curl under the hood)
    local ok, items = api:fetch_items()
    if not ok then
        vim.notify("org-roam-zotero: failed to fetch items: " .. tostring(items), vim.log.levels.ERROR)
        return
    end

    ---@cast items org-roam-zotero.ZoteroItem[]
    local roam = get_roam()
    local count = 0

    for _, item in ipairs(items) do
        -- Skip attachments, notes, etc. at the top level
        if item.data.itemType ~= "attachment" and item.data.itemType ~= "note" then
            local note_ok, note = api:fetch_note(item.data.key)
            if note_ok and note then
                ---@cast note org-roam-zotero.ZoteroItem
                local node = make_node(item, note)

                -- Cache note version for the buffer handler
                INSTANCE.__buffer.__note_cache[note.data.key] = {
                    version = note.data.version,
                }

                -- Track node for re-insertion after database reloads
                INSTANCE.__synced_nodes[node.id] = node

                -- Insert into org-roam database (overwrite if already present)
                roam.database:insert(node, { overwrite = true }):wait()
                count = count + 1
            end
        end
    end

    -- Install the load() wrapper so Zotero nodes survive future reloads
    ensure_load_wrapped()

    vim.notify(
        string.format("org-roam-zotero: synced %d Zotero item(s)", count),
        vim.log.levels.INFO
    )

    if opts.on_done then
        opts.on_done(count)
    end
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

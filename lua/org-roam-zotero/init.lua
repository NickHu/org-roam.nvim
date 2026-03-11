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
---@field private __synced_ids table<string, boolean> #track which node IDs we have synced
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
    instance.__synced_ids = {}

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

                -- Insert into org-roam database (overwrite if already present)
                roam.database:insert(node, { overwrite = true })
                INSTANCE.__synced_ids[node.id] = true
                count = count + 1
            end
        end
    end

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

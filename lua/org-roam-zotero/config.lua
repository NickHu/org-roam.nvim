-------------------------------------------------------------------------------
-- CONFIG.LUA
--
-- Configuration for the org-roam-zotero plugin.
-------------------------------------------------------------------------------

---@class org-roam-zotero.Config
---@field api_key string #Zotero API key (from https://www.zotero.org/settings/keys)
---@field library_type "user"|"group" #type of Zotero library to query
---@field library_id string #user or group ID for the Zotero library
---@field auto_sync boolean #if true, sync Zotero items after org-roam database loads
local M = {}
M.__index = M

---@type org-roam-zotero.Config
local DEFAULT = {
    api_key = "",
    library_type = "user",
    library_id = "",
    auto_sync = false,
}

---Creates a new config instance.
---@param opts? org-roam-zotero.Config
---@return org-roam-zotero.Config
function M:new(opts)
    local instance = vim.tbl_deep_extend("force", {}, DEFAULT, opts or {})
    setmetatable(instance, M)
    return instance
end

return M

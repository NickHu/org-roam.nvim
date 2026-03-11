-------------------------------------------------------------------------------
-- API.LUA
--
-- Zotero Web API v3 client.
-- See https://www.zotero.org/support/dev/web_api/v3/basics
-------------------------------------------------------------------------------

---@class org-roam-zotero.Api
---@field private __config org-roam-zotero.Config
local M = {}
M.__index = M

---@class org-roam-zotero.ZoteroItem
---@field key string
---@field version integer
---@field data org-roam-zotero.ZoteroItemData

---@class org-roam-zotero.ZoteroItemData
---@field key string
---@field version integer
---@field itemType string
---@field title string
---@field tags {tag:string}[]
---@field note? string
---@field parentItem? string
---@field creators? {creatorType:string, firstName?:string, lastName?:string, name?:string}[]

---Creates a new API client.
---@param config org-roam-zotero.Config
---@return org-roam-zotero.Api
function M:new(config)
    local instance = {}
    setmetatable(instance, M)
    instance.__config = config
    return instance
end

---Returns the base URL for the configured Zotero library.
---@return string
function M:base_url()
    if self.__config.library_type == "group" then
        return string.format("https://api.zotero.org/groups/%s", self.__config.library_id)
    else
        return string.format("https://api.zotero.org/users/%s", self.__config.library_id)
    end
end

---Makes an HTTP GET request to the Zotero API.
---@param path string #API path (appended to base URL)
---@param query? table<string,string> #optional query parameters
---@return boolean success, any result
function M:get(path, query)
    local url = self:base_url() .. path

    local cmd = {
        "curl", "-s", "-f",
        "-H", "Zotero-API-Key: " .. self.__config.api_key,
        "-H", "Zotero-API-Version: 3",
    }

    if query then
        local parts = {}
        for k, v in pairs(query) do
            table.insert(parts, k .. "=" .. vim.uri_encode(v))
        end
        if #parts > 0 then
            url = url .. "?" .. table.concat(parts, "&")
        end
    end

    table.insert(cmd, url)

    local result = vim.fn.system(cmd)

    if vim.v.shell_error ~= 0 then
        return false, "HTTP request failed (exit code " .. vim.v.shell_error .. "): " .. result
    end

    local ok, decoded = pcall(vim.fn.json_decode, result)
    if not ok then
        return false, "Failed to decode JSON response: " .. result
    end

    return true, decoded
end

---Makes an HTTP PATCH request to the Zotero API.
---@param path string #API path (appended to base URL)
---@param body table #request body (will be JSON-encoded)
---@param version integer #If-Unmodified-Since-Version header value
---@return boolean success, any result
function M:patch(path, body, version)
    local url = self:base_url() .. path
    local json_body = vim.fn.json_encode(body)

    local cmd = {
        "curl", "-s", "-f",
        "-X", "PATCH",
        "-H", "Zotero-API-Key: " .. self.__config.api_key,
        "-H", "Zotero-API-Version: 3",
        "-H", "Content-Type: application/json",
        "-H", "If-Unmodified-Since-Version: " .. tostring(version),
        "-d", json_body,
        url,
    }

    local result = vim.fn.system(cmd)

    if vim.v.shell_error ~= 0 then
        return false, "HTTP PATCH failed (exit code " .. vim.v.shell_error .. "): " .. result
    end

    -- PATCH may return empty body on success (204)
    if result == "" then
        return true, nil
    end

    local ok, decoded = pcall(vim.fn.json_decode, result)
    if not ok then
        -- Might be a non-JSON success response
        return true, result
    end

    return true, decoded
end

---Fetches all top-level items from the Zotero library.
---Handles pagination via the Zotero API.
---@return boolean success, org-roam-zotero.ZoteroItem[]|string result
function M:fetch_items()
    local all_items = {}
    local start = 0
    local limit = 100

    while true do
        local ok, result = self:get("/items/top", {
            format = "json",
            limit = tostring(limit),
            start = tostring(start),
        })

        if not ok then
            return false, result
        end

        ---@cast result org-roam-zotero.ZoteroItem[]
        if #result == 0 then
            break
        end

        for _, item in ipairs(result) do
            table.insert(all_items, item)
        end

        if #result < limit then
            break
        end

        start = start + limit
    end

    return true, all_items
end

---Fetches child items for a given item key.
---@param item_key string
---@return boolean success, org-roam-zotero.ZoteroItem[]|string result
function M:fetch_children(item_key)
    return self:get(string.format("/items/%s/children", item_key), {
        format = "json",
    })
end

---Fetches the first note child for a given item key.
---@param item_key string
---@return boolean success, org-roam-zotero.ZoteroItem|nil|string result
function M:fetch_note(item_key)
    local ok, children = self:fetch_children(item_key)
    if not ok then
        return false, children
    end

    ---@cast children org-roam-zotero.ZoteroItem[]
    for _, child in ipairs(children) do
        if child.data and child.data.itemType == "note" then
            return true, child
        end
    end

    return true, nil
end

---Updates the content of a note item in Zotero.
---@param note_key string #key of the note item to update
---@param content string #new HTML content for the note
---@param version integer #current version for optimistic locking
---@return boolean success, any result
function M:update_note(note_key, content, version)
    return self:patch(
        string.format("/items/%s", note_key),
        { note = content },
        version
    )
end

return M

-------------------------------------------------------------------------------
-- API.LUA
--
-- Zotero Web API v3 and local API client.
-- See https://www.zotero.org/support/dev/web_api/v3/basics
-- Local API: https://github.com/zotero/zotero/blob/8.0/chrome/content/zotero/xpcom/server/server_localAPI.js
--
-- HTTP requests use plenary.curl (synchronous).
-------------------------------------------------------------------------------

local curl = require("plenary.curl")

-- Passed as `on_error` to every plenary.curl call to suppress its default
-- `error()` throw on non-zero curl exit codes.
local function _noop() end

---Decodes the body of a plenary.curl response as JSON.
---Returns (true, decoded_table) on success, (false, error_string) on failure.
---An empty or whitespace-only body is treated as nil (not an error).
---@param response table  plenary.curl response {exit, status, headers, body}
---@return boolean, any
local function _decode_json(response)
    if response.status and response.status >= 400 then
        return false, string.format("HTTP %d: %s", response.status, response.body or "")
    end
    local body = vim.trim(response.body or "")
    if body == "" then
        return true, nil
    end
    local ok, decoded = pcall(vim.json.decode, body)
    if not ok then
        return false, "JSON decode error: " .. tostring(decoded)
    end
    return true, decoded
end

---@class org-roam-zotero.Api
---@field private __config org-roam-zotero.Config
---@field private __local_api_available boolean|nil #cached availability of local API
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
---@field relations? table<string, string|string[]>

---Creates a new API client.
---@param config org-roam-zotero.Config
---@return org-roam-zotero.Api
function M:new(config)
    local instance = {}
    setmetatable(instance, M)
    instance.__config = config
    instance.__local_api_available = nil
    return instance
end

---Returns the base URL for the Zotero Web API.
---@return string
function M:base_url()
    if self.__config.library_type == "group" then
        return string.format("https://api.zotero.org/groups/%s", self.__config.library_id)
    else
        return string.format("https://api.zotero.org/users/%s", self.__config.library_id)
    end
end

---Returns the base URL for the Zotero local API.
---User ID 0 means "the currently logged-in user".
---@return string
function M:local_base_url()
    local port = self.__config.local_api_port or 23119
    if self.__config.library_type == "group" then
        return string.format("http://localhost:%d/api/groups/%s", port, self.__config.library_id)
    else
        return string.format("http://localhost:%d/api/users/0", port)
    end
end

---Checks whether the Zotero local API is reachable (cached after first probe).
---@return boolean
function M:is_local_api_available()
    if self.__local_api_available ~= nil then
        return self.__local_api_available
    end

    local port = self.__config.local_api_port or 23119
    local url = string.format("http://localhost:%d/api/", port)
    local response = curl.get(url, {
        raw = { "--connect-timeout", "2", "--max-time", "3" },
        on_error = _noop,
    })
    self.__local_api_available = response ~= nil and response.status ~= nil and response.status > 0
    return self.__local_api_available
end

---Makes an HTTP GET request to the Zotero local API.
---No authentication is required. No pagination is needed (the local API
---returns all results by default).
---@param path string #API path (appended to local base URL)
---@param query? table<string,string> #optional query parameters
---@return boolean success, any result
function M:local_get(path, query)
    local response = curl.get(self:local_base_url() .. path, {
        headers = { ["Zotero-API-Version"] = "3" },
        query = query,
        raw = { "--connect-timeout", "2", "--max-time", "30" },
        on_error = _noop,
    })
    if not response or not response.status then
        return false, "Local API request failed"
    end
    return _decode_json(response)
end

---Makes an HTTP GET request to the Zotero Web API.
---@param path string #API path (appended to base URL)
---@param query? table<string,string> #optional query parameters
---@return boolean success, any result
function M:get(path, query)
    local response = curl.get(self:base_url() .. path, {
        headers = {
            ["Zotero-API-Key"] = self.__config.api_key,
            ["Zotero-API-Version"] = "3",
        },
        query = query,
        on_error = _noop,
    })
    if not response or not response.status then
        return false, "HTTP request failed"
    end
    return _decode_json(response)
end

---Makes a read request, preferring the local API when available.
---Falls back to the web API if the local API is unreachable.
---@param path string #API path
---@param query? table<string,string> #optional query parameters
---@return boolean success, any result
function M:read(path, query)
    if self.__config.prefer_local_api and self:is_local_api_available() then
        local ok, result = self:local_get(path, query)
        if ok then
            return ok, result
        end
        -- Fall through to web API on local API failure
    end
    return self:get(path, query)
end

---Makes an HTTP PATCH request to the Zotero Web API.
---Write requests are only supported via the web API.
---@param path string #API path (appended to base URL)
---@param body table #request body (will be JSON-encoded)
---@param version integer #If-Unmodified-Since-Version header value
---@return boolean success, any result
function M:patch(path, body, version)
    local response = curl.patch(self:base_url() .. path, {
        headers = {
            ["Zotero-API-Key"] = self.__config.api_key,
            ["Zotero-API-Version"] = "3",
            ["Content-Type"] = "application/json",
            ["If-Unmodified-Since-Version"] = tostring(version),
        },
        body = vim.fn.json_encode(body),
        on_error = _noop,
    })
    if not response or not response.status then
        return false, "HTTP PATCH failed"
    end
    return _decode_json(response)
end

---Makes an HTTP POST request to the Zotero Web API.
---Write requests are only supported via the web API.
---@param path string #API path (appended to base URL)
---@param body table #request body (will be JSON-encoded)
---@return boolean success, any result
function M:post(path, body)
    local response = curl.post(self:base_url() .. path, {
        headers = {
            ["Zotero-API-Key"] = self.__config.api_key,
            ["Zotero-API-Version"] = "3",
            ["Content-Type"] = "application/json",
        },
        body = vim.fn.json_encode(body),
        on_error = _noop,
    })
    if not response or not response.status then
        return false, "HTTP POST failed"
    end
    return _decode_json(response)
end

---Fetches all top-level items from the Zotero library.
---Uses the local API when available (no pagination needed); falls back to
---the web API with pagination.
---@return boolean success, org-roam-zotero.ZoteroItem[]|string result
function M:fetch_items()
    -- Try the local API first: it returns all results without pagination
    if self.__config.prefer_local_api and self:is_local_api_available() then
        local ok, result = self:local_get("/items/top", { format = "json" })
        if ok then
            return true, result
        end
        -- Fall through to paginated web API
    end

    -- Web API: paginate through results
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
---Uses `read()` which prefers the local API.
---@param item_key string
---@return boolean success, org-roam-zotero.ZoteroItem[]|string result
function M:fetch_children(item_key)
    return self:read(string.format("/items/%s/children", item_key), {
        format = "json",
    })
end

---Creates a new child note tagged "org-roam" for the given parent item.
---Write requests always use the web API (local API is read-only).
---@param parent_item_key string
---@return boolean success, org-roam-zotero.ZoteroItem|string result
function M:create_note(parent_item_key)
    local items = {
        {
            itemType = "note",
            parentItem = parent_item_key,
            note = "",
            tags = { { tag = "org-roam" } },
        },
    }

    local ok, result = self:post("/items", items)
    if not ok then
        return false, result
    end

    -- Parse the multi-object creation response.
    -- Zotero API v3 returns string keys ("0", "1", ...) in the successful
    -- object; vim.json.decode preserves them as string keys, but we check
    -- both representations for robustness.
    if type(result) == "table" and result.successful then
        local first = result.successful["0"] or result.successful[0]
        if first then
            return true, first
        end
    end

    return false, "Failed to create note: unexpected response"
end

---Fetches the first child note tagged "org-roam" for a given item key.
---Returns nil (not an error) if no such note exists; note creation is
---deferred to the first write from the ephemeral buffer.
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
            -- Check for the "org-roam" tag
            if child.data.tags then
                for _, t in ipairs(child.data.tags) do
                    if t.tag == "org-roam" then
                        return true, child
                    end
                end
            end
        end
    end

    -- No org-roam-tagged note found
    return true, nil
end

---Updates the content (and optionally relations) of a note item in Zotero.
---Write requests always use the web API (local API is read-only).
---@param note_key string #key of the note item to update
---@param content string #new HTML content for the note
---@param version integer #current version for optimistic locking
---@param relations? table<string, string|string[]> #optional dc:relation map
---@return boolean success, any result
function M:update_note(note_key, content, version, relations)
    local body = { note = content }
    if relations then
        body.relations = relations
    end
    return self:patch(
        string.format("/items/%s", note_key),
        body,
        version
    )
end

return M

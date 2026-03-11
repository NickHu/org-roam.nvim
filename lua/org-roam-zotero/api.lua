-------------------------------------------------------------------------------
-- API.LUA
--
-- Zotero Web API v3 and local API client.
-- See https://www.zotero.org/support/dev/web_api/v3/basics
-- Local API: https://github.com/zotero/zotero/blob/8.0/chrome/content/zotero/xpcom/server/server_localAPI.js
-------------------------------------------------------------------------------

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
    local cmd = {
        "curl", "-s", "-f",
        "--connect-timeout", "2",
        "--max-time", "3",
        string.format("http://localhost:%d/api/", port),
    }

    vim.fn.system(cmd)
    self.__local_api_available = (vim.v.shell_error == 0)
    return self.__local_api_available
end

---Makes an HTTP GET request to the Zotero local API.
---No authentication is required. No pagination is needed (the local API
---returns all results by default).
---@param path string #API path (appended to local base URL)
---@param query? table<string,string> #optional query parameters
---@return boolean success, any result
function M:local_get(path, query)
    local url = self:local_base_url() .. path

    local cmd = {
        "curl", "-s", "-f",
        "--connect-timeout", "2",
        "--max-time", "30",
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
        return false, "Local API request failed (exit code " .. vim.v.shell_error .. "): " .. result
    end

    local ok, decoded = pcall(vim.fn.json_decode, result)
    if not ok then
        return false, "Failed to decode JSON response: " .. result
    end

    return true, decoded
end

---Makes an HTTP GET request to the Zotero Web API.
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

---Makes an HTTP POST request to the Zotero Web API.
---Write requests are only supported via the web API.
---@param path string #API path (appended to base URL)
---@param body table #request body (will be JSON-encoded)
---@return boolean success, any result
function M:post(path, body)
    local url = self:base_url() .. path
    local json_body = vim.fn.json_encode(body)

    local cmd = {
        "curl", "-s", "-f",
        "-X", "POST",
        "-H", "Zotero-API-Key: " .. self.__config.api_key,
        "-H", "Zotero-API-Version: 3",
        "-H", "Content-Type: application/json",
        "-d", json_body,
        url,
    }

    local result = vim.fn.system(cmd)

    if vim.v.shell_error ~= 0 then
        return false, "HTTP POST failed (exit code " .. vim.v.shell_error .. "): " .. result
    end

    if result == "" then
        return true, nil
    end

    local ok, decoded = pcall(vim.fn.json_decode, result)
    if not ok then
        return true, result
    end

    return true, decoded
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
    -- object; vim.fn.json_decode preserves them as string keys, but we check
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

---Updates the content of a note item in Zotero.
---Write requests always use the web API (local API is read-only).
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

-------------------------------------------------------------------------------
-- BUFFER.LUA
--
-- Manages ephemeral Neovim buffers for Zotero notes.
--
-- Uses the `zotero://` URI scheme so that `vim.cmd.edit("zotero://...")` is
-- intercepted by BufReadCmd / BufWriteCmd autocmds.  This allows org-roam's
-- existing `goto_node` to work without modification.
--
-- URIs conform to the Zotero protocol specification:
--   zotero://select/library/items/[itemKey]          (user library)
--   zotero://select/groups/[groupID]/items/[itemKey]  (group library)
-- See https://github.com/zotero/zotero/blob/8.0/chrome/content/zotero/ZoteroProtocolHandler.mjs
-------------------------------------------------------------------------------

---@class org-roam-zotero.Buffer
---@field private __api org-roam-zotero.Api
---@field private __config org-roam-zotero.Config
---@field private __augroup integer
---@field __note_cache table<string, {note_key:string|nil, version:integer}>
local M = {}
M.__index = M

---Creates a new buffer manager.
---@param api org-roam-zotero.Api
---@param config org-roam-zotero.Config
---@return org-roam-zotero.Buffer
function M:new(api, config)
    local instance = {}
    setmetatable(instance, M)
    instance.__api = api
    instance.__config = config
    instance.__augroup = vim.api.nvim_create_augroup("org-roam-zotero", { clear = true })
    instance.__note_cache = {}
    return instance
end

---Parses a Zotero select URI.
---
---Supported formats (per Zotero protocol spec):
---  zotero://select/library/items/[itemKey]
---  zotero://select/groups/[groupID]/items/[itemKey]
---
---@param uri string
---@return string|nil item_key
---@return string|nil library_type  "user" or "group"
---@return string|nil library_id    group ID (nil for user library)
function M.parse_uri(uri)
    -- User library: zotero://select/library/items/KEY
    local item_key = uri:match("^zotero://select/library/items/([^/?]+)")
    if item_key then
        return item_key, "user", nil
    end

    -- Group library: zotero://select/groups/GROUPID/items/KEY
    local group_id, gitem_key = uri:match("^zotero://select/groups/([^/]+)/items/([^/?]+)")
    if group_id and gitem_key then
        return gitem_key, "group", group_id
    end

    return nil, nil, nil
end

---Builds a Zotero select URI from library info and item key.
---
---@param library_type string  "user" or "group"
---@param library_id string    library/group ID
---@param item_key string
---@return string
function M.build_uri(library_type, library_id, item_key)
    if library_type == "group" then
        return string.format("zotero://select/groups/%s/items/%s", library_id, item_key)
    else
        return string.format("zotero://select/library/items/%s", item_key)
    end
end

---Converts HTML note content to a simple plain-text representation.
---@param html string
---@return string
function M.html_to_text(html)
    if not html or html == "" then
        return ""
    end

    local text = html

    -- Replace block-level elements with newlines
    text = text:gsub("<br%s*/?>", "\n")
    text = text:gsub("</p>", "\n\n")
    text = text:gsub("</div>", "\n")
    text = text:gsub("</li>", "\n")
    text = text:gsub("<li[^>]*>", "- ")
    text = text:gsub("<h(%d)[^>]*>", function(level)
        return string.rep("*", tonumber(level)) .. " "
    end)
    text = text:gsub("</h%d>", "\n")

    -- Strip remaining HTML tags
    text = text:gsub("<[^>]+>", "")

    -- Decode common HTML entities
    text = text:gsub("&amp;", "&")
    text = text:gsub("&lt;", "<")
    text = text:gsub("&gt;", ">")
    text = text:gsub("&quot;", '"')
    text = text:gsub("&#39;", "'")
    text = text:gsub("&nbsp;", " ")

    -- Trim trailing whitespace on each line and collapse excessive blank lines
    local lines = vim.split(text, "\n")
    local result = {}
    local prev_blank = false
    for _, line in ipairs(lines) do
        line = line:gsub("%s+$", "")
        if line == "" then
            if not prev_blank then
                table.insert(result, line)
            end
            prev_blank = true
        else
            table.insert(result, line)
            prev_blank = false
        end
    end

    -- Remove leading/trailing blank lines
    while #result > 0 and result[1] == "" do
        table.remove(result, 1)
    end
    while #result > 0 and result[#result] == "" do
        table.remove(result)
    end

    return table.concat(result, "\n")
end

---Converts plain text back to simple HTML paragraphs for Zotero.
---@param text string
---@return string
function M.text_to_html(text)
    if not text or text == "" then
        return ""
    end

    -- Escape HTML entities
    text = text:gsub("&", "&amp;")
    text = text:gsub("<", "&lt;")
    text = text:gsub(">", "&gt;")

    -- Split into paragraphs on blank lines
    local paragraphs = vim.split(text, "\n\n")
    local html_parts = {}
    for _, para in ipairs(paragraphs) do
        para = vim.trim(para)
        if para ~= "" then
            -- Convert single newlines within a paragraph to <br>
            para = para:gsub("\n", "<br/>")
            table.insert(html_parts, "<p>" .. para .. "</p>")
        end
    end

    return table.concat(html_parts, "\n")
end

---Builds the org-mode content for a Zotero note buffer.
---@param item_key string
---@param note_key string|nil  #nil when the note has not been created yet
---@param title string
---@param note_html string
---@param version integer
---@param node_id string
---@param origin_uri string    #the zotero://select/... URI
---@return string[]
function M.build_org_content(item_key, note_key, title, note_html, version, node_id, origin_uri)
    local body = M.html_to_text(note_html)

    local lines = {
        ":PROPERTIES:",
        ":ID: " .. node_id,
        ":ROAM_ORIGIN: " .. origin_uri,
        ":ZOTERO_ITEM_KEY: " .. item_key,
    }

    if note_key then
        table.insert(lines, ":ZOTERO_NOTE_KEY: " .. note_key)
    end

    table.insert(lines, ":ZOTERO_VERSION: " .. tostring(version))
    table.insert(lines, ":END:")
    table.insert(lines, "#+title: " .. title)
    table.insert(lines, "")

    if body ~= "" then
        for _, line in ipairs(vim.split(body, "\n")) do
            table.insert(lines, line)
        end
    end

    return lines
end

---Extracts metadata from the org buffer content.
---@param buf integer
---@return {item_key:string|nil, note_key:string|nil, version:integer|nil}
function M.parse_buffer_metadata(buf)
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local meta = {}
    for _, line in ipairs(lines) do
        local key, value = line:match("^:(%S+):%s+(.+)$")
        if key == "ZOTERO_ITEM_KEY" then
            meta.item_key = value
        elseif key == "ZOTERO_NOTE_KEY" then
            meta.note_key = value
        elseif key == "ZOTERO_VERSION" then
            meta.version = tonumber(value)
        elseif line == ":END:" then
            break
        end
    end
    return meta
end

---Extracts the note body from the buffer (everything after the properties and title).
---@param buf integer
---@return string
function M.extract_body(buf)
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local body_start = nil

    -- Find the end of the property drawer and title
    local past_properties = false
    for i, line in ipairs(lines) do
        if line == ":END:" then
            past_properties = true
        elseif past_properties then
            -- Skip the #+title: line
            if not line:match("^#%+title:") then
                body_start = i
                break
            end
        end
    end

    if not body_start then
        return ""
    end

    -- Skip leading empty lines
    while body_start <= #lines and lines[body_start] == "" do
        body_start = body_start + 1
    end

    if body_start > #lines then
        return ""
    end

    local body_lines = {}
    for i = body_start, #lines do
        table.insert(body_lines, lines[i])
    end

    return table.concat(body_lines, "\n")
end

---Registers the BufReadCmd and BufWriteCmd autocmds for the `zotero://` scheme.
function M:register_autocmds()
    local self_ref = self

    vim.api.nvim_create_autocmd("BufReadCmd", {
        group = self.__augroup,
        pattern = "zotero://*",
        callback = function(args)
            self_ref:__on_buf_read(args.buf, args.file)
        end,
    })

    vim.api.nvim_create_autocmd("BufWriteCmd", {
        group = self.__augroup,
        pattern = "zotero://*",
        callback = function(args)
            self_ref:__on_buf_write(args.buf, args.file)
        end,
    })
end

---Handles reading a zotero:// buffer.
---@param buf integer
---@param uri string
function M:__on_buf_read(buf, uri)
    local item_key = M.parse_uri(uri)
    if not item_key then
        vim.notify("org-roam-zotero: invalid URI: " .. uri, vim.log.levels.ERROR)
        return
    end

    -- Fetch the parent item for the title
    local ok_item, item_resp = self.__api:read(
        string.format("/items/%s", item_key),
        { format = "json" }
    )
    local title = item_key
    if ok_item and item_resp then
        ---@cast item_resp org-roam-zotero.ZoteroItem
        title = (item_resp.data or {}).title or title
    end

    -- Check the note cache, or look up the note via API
    local cached = self.__note_cache[item_key]
    local note_key = cached and cached.note_key or nil
    local version = cached and cached.version or 0
    local note_html = ""

    if not note_key then
        -- No note in cache; try to find one via the API
        local ok, note = self.__api:fetch_note(item_key)
        if ok and note then
            ---@cast note org-roam-zotero.ZoteroItem
            note_key = note.data.key
            version = note.data.version
            note_html = note.data.note or ""
            self.__note_cache[item_key] = { note_key = note_key, version = version }
        else
            -- No note exists yet; show empty buffer (note created on first write)
            self.__note_cache[item_key] = { note_key = nil, version = 0 }
        end
    else
        -- Fetch the note directly to get fresh content
        local ok_get, note_resp = self.__api:read(
            string.format("/items/%s", note_key),
            { format = "json" }
        )
        if ok_get and note_resp then
            ---@cast note_resp org-roam-zotero.ZoteroItem
            local data = note_resp.data
            if not data then
                vim.notify("org-roam-zotero: unexpected API response for note " .. note_key, vim.log.levels.WARN)
                data = {}
            end
            note_html = data.note or ""
            version = note_resp.version or version
            self.__note_cache[item_key] = { note_key = note_key, version = version }
        end
    end

    -- Build the node ID and origin URI
    local node_id = "zotero-" .. item_key
    local origin_uri = M.build_uri(
        self.__config.library_type,
        self.__config.library_id,
        item_key
    )

    local lines = M.build_org_content(item_key, note_key, title, note_html, version, node_id, origin_uri)

    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modified = false
    vim.bo[buf].filetype = "org"
    vim.bo[buf].buftype = "acwrite"
end

---Handles writing a zotero:// buffer back to Zotero.
---If no note exists yet, creates one on the first write.
---@param buf integer
---@param uri string
function M:__on_buf_write(buf, uri)
    local item_key_from_uri = M.parse_uri(uri)
    local meta = M.parse_buffer_metadata(buf)

    local item_key = meta.item_key or item_key_from_uri
    local note_key = meta.note_key
    local version = meta.version

    if not item_key then
        vim.notify("org-roam-zotero: cannot determine item key for write", vim.log.levels.ERROR)
        return
    end

    -- If no note exists yet, create one on first write
    if not note_key then
        local ok, created = self.__api:create_note(item_key)
        if not ok or not created then
            vim.notify(
                "org-roam-zotero: failed to create note for item " .. item_key .. ": " .. tostring(created),
                vim.log.levels.ERROR
            )
            return
        end

        ---@cast created org-roam-zotero.ZoteroItem
        note_key = created.data.key
        version = created.data.version

        -- Update the buffer properties to include the new note key
        local buf_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        for i, line in ipairs(buf_lines) do
            if line:match("^:ZOTERO_VERSION:") then
                -- Insert ZOTERO_NOTE_KEY before ZOTERO_VERSION
                table.insert(buf_lines, i, ":ZOTERO_NOTE_KEY: " .. note_key)
                break
            end
        end
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, buf_lines)
    end

    if not version then
        vim.notify("org-roam-zotero: cannot determine version for write", vim.log.levels.ERROR)
        return
    end

    local body = M.extract_body(buf)
    local html = M.text_to_html(body)

    local ok, result = self.__api:update_note(note_key, html, version)
    if not ok then
        vim.notify(
            "org-roam-zotero: failed to update note: " .. tostring(result),
            vim.log.levels.ERROR
        )
        return
    end

    -- Determine the new version: prefer the API response, fall back to increment
    local new_version
    if type(result) == "table" and result.version then
        new_version = result.version
    else
        new_version = version + 1
    end
    self.__note_cache[item_key] = { note_key = note_key, version = new_version }

    -- Update the version in the buffer properties
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    for i, line in ipairs(lines) do
        if line:match("^:ZOTERO_VERSION:%s") then
            lines[i] = ":ZOTERO_VERSION: " .. tostring(new_version)
            vim.api.nvim_buf_set_lines(buf, i - 1, i, false, { lines[i] })
            break
        end
    end

    vim.bo[buf].modified = false
    vim.notify("org-roam-zotero: note updated successfully", vim.log.levels.INFO)
end

return M

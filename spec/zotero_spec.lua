describe("org-roam-zotero", function()
    local Buffer = require("org-roam-zotero.buffer")
    local Config = require("org-roam-zotero.config")
    local Api = require("org-roam-zotero.api")
    local ZoteroPlugin = require("org-roam-zotero")

    describe("config", function()
        it("should use defaults when no options are given", function()
            local config = Config:new()
            assert.are.equal("", config.api_key)
            assert.are.equal("user", config.library_type)
            assert.are.equal("", config.library_id)
            assert.are.equal(true, config.auto_sync)
            assert.are.equal(23119, config.local_api_port)
            assert.are.equal(true, config.prefer_local_api)
        end)

        it("should merge provided options with defaults", function()
            local config = Config:new({
                api_key = "test-key",
                library_id = "12345",
            })
            assert.are.equal("test-key", config.api_key)
            assert.are.equal("12345", config.library_id)
            assert.are.equal("user", config.library_type)
            assert.are.equal(23119, config.local_api_port)
            assert.are.equal(true, config.prefer_local_api)
        end)

        it("should allow overriding local API settings", function()
            local config = Config:new({
                local_api_port = 9999,
                prefer_local_api = false,
            })
            assert.are.equal(9999, config.local_api_port)
            assert.are.equal(false, config.prefer_local_api)
        end)
    end)

    describe("api", function()
        it("should build user library base URL", function()
            local config = Config:new({ library_type = "user", library_id = "123" })
            local api = Api:new(config)
            assert.are.equal("https://api.zotero.org/users/123", api:base_url())
        end)

        it("should build group library base URL", function()
            local config = Config:new({ library_type = "group", library_id = "456" })
            local api = Api:new(config)
            assert.are.equal("https://api.zotero.org/groups/456", api:base_url())
        end)

        it("should build local API user library base URL with user ID 0", function()
            local config = Config:new({ library_type = "user", library_id = "123" })
            local api = Api:new(config)
            assert.are.equal("http://localhost:23119/api/users/0", api:local_base_url())
        end)

        it("should build local API group library base URL", function()
            local config = Config:new({ library_type = "group", library_id = "456" })
            local api = Api:new(config)
            assert.are.equal("http://localhost:23119/api/groups/456", api:local_base_url())
        end)

        it("should respect custom local API port", function()
            local config = Config:new({ library_type = "user", library_id = "123", local_api_port = 9999 })
            local api = Api:new(config)
            assert.are.equal("http://localhost:9999/api/users/0", api:local_base_url())
        end)
    end)

    describe("extract_org_links", function()
        it("should return empty table for nil input", function()
            assert.are.same({}, Buffer.extract_org_links(nil))
        end)

        it("should return empty table for empty input", function()
            assert.are.same({}, Buffer.extract_org_links(""))
        end)

        it("should return empty table for text with no org links", function()
            assert.are.same({}, Buffer.extract_org_links("This is plain text."))
        end)

        it("should extract a single Zotero link", function()
            local keys = Buffer.extract_org_links("See [[id:zotero-ABC123]] for details.")
            assert.are.same({ "ABC123" }, keys)
        end)

        it("should extract multiple Zotero links", function()
            local keys = Buffer.extract_org_links(
                "Compare [[id:zotero-AAA111]] with [[id:zotero-BBB222]]."
            )
            assert.are.same({ "AAA111", "BBB222" }, keys)
        end)

        it("should extract links with descriptions", function()
            local keys = Buffer.extract_org_links("See [[id:zotero-XYZ789][Some paper]].")
            assert.are.same({ "XYZ789" }, keys)
        end)

        it("should ignore non-Zotero org-roam links", function()
            local keys = Buffer.extract_org_links(
                "See [[id:some-other-node]] and [[id:zotero-VALID]]."
            )
            assert.are.same({ "VALID" }, keys)
        end)
    end)

    describe("build_relation_uri", function()
        it("should build user library relation URI", function()
            local uri = Buffer.build_relation_uri("user", "12345", "ITEM1")
            assert.are.equal("http://zotero.org/users/12345/items/ITEM1", uri)
        end)

        it("should build group library relation URI", function()
            local uri = Buffer.build_relation_uri("group", "67890", "ITEM1")
            assert.are.equal("http://zotero.org/groups/67890/items/ITEM1", uri)
        end)
    end)

    describe("buffer", function()
        describe("parse_uri", function()
            it("should parse user library zotero://select URIs", function()
                local item_key, lib_type, lib_id = Buffer.parse_uri(
                    "zotero://select/library/items/ABC123"
                )
                assert.are.equal("ABC123", item_key)
                assert.are.equal("user", lib_type)
                assert.is_nil(lib_id)
            end)

            it("should parse group library zotero://select URIs", function()
                local item_key, lib_type, lib_id = Buffer.parse_uri(
                    "zotero://select/groups/456/items/DEF789"
                )
                assert.are.equal("DEF789", item_key)
                assert.are.equal("group", lib_type)
                assert.are.equal("456", lib_id)
            end)

            it("should return nil for invalid URIs", function()
                local item_key, lib_type, lib_id = Buffer.parse_uri("not-a-zotero-uri")
                assert.is_nil(item_key)
                assert.is_nil(lib_type)
                assert.is_nil(lib_id)
            end)

            it("should return nil for old-style zotero://ITEM/NOTE URIs", function()
                local item_key, lib_type, lib_id = Buffer.parse_uri("zotero://ABC123/DEF456")
                assert.is_nil(item_key)
                assert.is_nil(lib_type)
                assert.is_nil(lib_id)
            end)
        end)

        describe("build_uri", function()
            it("should construct a user library zotero://select URI", function()
                local uri = Buffer.build_uri("user", "12345", "ITEM1")
                assert.are.equal("zotero://select/library/items/ITEM1", uri)
            end)

            it("should construct a group library zotero://select URI", function()
                local uri = Buffer.build_uri("group", "67890", "ITEM1")
                assert.are.equal("zotero://select/groups/67890/items/ITEM1", uri)
            end)
        end)

        describe("html_to_text", function()
            it("should strip simple HTML tags", function()
                local result = Buffer.html_to_text("<p>Hello world</p>")
                assert.are.equal("Hello world", result)
            end)

            it("should handle empty input", function()
                assert.are.equal("", Buffer.html_to_text(""))
                assert.are.equal("", Buffer.html_to_text(nil))
            end)

            it("should convert <br> to newlines", function()
                local result = Buffer.html_to_text("line1<br>line2<br/>line3")
                assert.are.equal("line1\nline2\nline3", result)
            end)

            it("should convert list items", function()
                local result = Buffer.html_to_text("<ul><li>first</li><li>second</li></ul>")
                assert.are.equal("- first\n- second", result)
            end)

            it("should decode HTML entities", function()
                local result = Buffer.html_to_text("<p>A &amp; B &lt; C &gt; D</p>")
                assert.are.equal("A & B < C > D", result)
            end)

            it("should convert headings to org-style stars", function()
                local result = Buffer.html_to_text("<h1>Title</h1><h2>Subtitle</h2>")
                assert.are.equal("* Title\n** Subtitle", result)
            end)
        end)

        describe("text_to_html", function()
            it("should wrap text in paragraphs", function()
                local result = Buffer.text_to_html("Hello world")
                assert.are.equal("<p>Hello world</p>", result)
            end)

            it("should handle empty input", function()
                assert.are.equal("", Buffer.text_to_html(""))
                assert.are.equal("", Buffer.text_to_html(nil))
            end)

            it("should split on blank lines into separate paragraphs", function()
                local result = Buffer.text_to_html("First paragraph\n\nSecond paragraph")
                assert.are.equal("<p>First paragraph</p>\n<p>Second paragraph</p>", result)
            end)

            it("should convert single newlines to <br/>", function()
                local result = Buffer.text_to_html("line1\nline2")
                assert.are.equal("<p>line1<br/>line2</p>", result)
            end)

            it("should escape HTML entities", function()
                local result = Buffer.text_to_html("A & B < C > D")
                assert.are.equal("<p>A &amp; B &lt; C &gt; D</p>", result)
            end)
        end)

        describe("build_org_content", function()
            it("should produce org content with properties and body (note exists)", function()
                local lines = Buffer.build_org_content(
                    "ITEM1", "NOTE1", "My Paper",
                    "<p>Some notes here</p>", 42,
                    "zotero-ITEM1",
                    "zotero://select/library/items/ITEM1"
                )
                assert.are.equal(":PROPERTIES:", lines[1])
                assert.are.equal(":ID: zotero-ITEM1", lines[2])
                assert.are.equal(":ROAM_ORIGIN: zotero://select/library/items/ITEM1", lines[3])
                assert.are.equal(":ZOTERO_ITEM_KEY: ITEM1", lines[4])
                assert.are.equal(":ZOTERO_NOTE_KEY: NOTE1", lines[5])
                assert.are.equal(":ZOTERO_VERSION: 42", lines[6])
                assert.are.equal(":END:", lines[7])
                assert.are.equal("#+title: My Paper", lines[8])
                assert.are.equal("", lines[9])
                assert.are.equal("Some notes here", lines[10])
            end)

            it("should handle empty note content", function()
                local lines = Buffer.build_org_content(
                    "ITEM1", "NOTE1", "Empty Paper",
                    "", 1, "zotero-ITEM1",
                    "zotero://select/library/items/ITEM1"
                )
                assert.are.equal(":PROPERTIES:", lines[1])
                assert.are.equal("#+title: Empty Paper", lines[8])
                assert.are.equal("", lines[9])
                assert.are.equal(nil, lines[10])
            end)

            it("should omit ZOTERO_NOTE_KEY when note_key is nil", function()
                local lines = Buffer.build_org_content(
                    "ITEM1", nil, "No Note Yet",
                    "", 0, "zotero-ITEM1",
                    "zotero://select/library/items/ITEM1"
                )
                assert.are.equal(":PROPERTIES:", lines[1])
                assert.are.equal(":ID: zotero-ITEM1", lines[2])
                assert.are.equal(":ROAM_ORIGIN: zotero://select/library/items/ITEM1", lines[3])
                assert.are.equal(":ZOTERO_ITEM_KEY: ITEM1", lines[4])
                -- No ZOTERO_NOTE_KEY line
                assert.are.equal(":ZOTERO_VERSION: 0", lines[5])
                assert.are.equal(":END:", lines[6])
                assert.are.equal("#+title: No Note Yet", lines[7])
                assert.are.equal("", lines[8])
                assert.are.equal(nil, lines[9])
            end)

            it("should use group library URI in ROAM_ORIGIN", function()
                local lines = Buffer.build_org_content(
                    "ITEM1", "NOTE1", "Group Paper",
                    "", 1, "zotero-ITEM1",
                    "zotero://select/groups/999/items/ITEM1"
                )
                assert.are.equal(":ROAM_ORIGIN: zotero://select/groups/999/items/ITEM1", lines[3])
            end)
        end)

        describe("parse_buffer_metadata", function()
            it("should extract metadata from org buffer with note key", function()
                local buf = vim.api.nvim_create_buf(false, true)
                vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
                    ":PROPERTIES:",
                    ":ID: zotero-ITEM1",
                    ":ZOTERO_ITEM_KEY: ITEM1",
                    ":ZOTERO_NOTE_KEY: NOTE1",
                    ":ZOTERO_VERSION: 42",
                    ":END:",
                    "#+title: Test",
                    "",
                    "Body text",
                })

                local meta = Buffer.parse_buffer_metadata(buf)
                assert.are.equal("ITEM1", meta.item_key)
                assert.are.equal("NOTE1", meta.note_key)
                assert.are.equal(42, meta.version)

                vim.api.nvim_buf_delete(buf, { force = true })
            end)

            it("should handle missing note key (note not yet created)", function()
                local buf = vim.api.nvim_create_buf(false, true)
                vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
                    ":PROPERTIES:",
                    ":ID: zotero-ITEM1",
                    ":ZOTERO_ITEM_KEY: ITEM1",
                    ":ZOTERO_VERSION: 0",
                    ":END:",
                    "#+title: Test",
                    "",
                })

                local meta = Buffer.parse_buffer_metadata(buf)
                assert.are.equal("ITEM1", meta.item_key)
                assert.is_nil(meta.note_key)
                assert.are.equal(0, meta.version)

                vim.api.nvim_buf_delete(buf, { force = true })
            end)
        end)

        describe("extract_body", function()
            it("should extract body after properties and title", function()
                local buf = vim.api.nvim_create_buf(false, true)
                vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
                    ":PROPERTIES:",
                    ":ID: zotero-ITEM1",
                    ":END:",
                    "#+title: Test",
                    "",
                    "First paragraph",
                    "",
                    "Second paragraph",
                })

                local body = Buffer.extract_body(buf)
                assert.are.equal("First paragraph\n\nSecond paragraph", body)

                vim.api.nvim_buf_delete(buf, { force = true })
            end)

            it("should return empty string for empty body", function()
                local buf = vim.api.nvim_create_buf(false, true)
                vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
                    ":PROPERTIES:",
                    ":ID: zotero-ITEM1",
                    ":END:",
                    "#+title: Test",
                    "",
                })

                local body = Buffer.extract_body(buf)
                assert.are.equal("", body)

                vim.api.nvim_buf_delete(buf, { force = true })
            end)
        end)
    end)

    describe("integration", function()
        local utils = require("spec.utils")
        local Node = require("org-roam.core.file.node")
        local Range = require("org-roam.core.file.range")

        before_each(function()
            utils.init_before_test()
        end)

        after_each(function()
            require("org-roam-zotero").reset()
            utils.cleanup_after_test()
        end)

        it("should create valid org-roam nodes for Zotero items", function()
            -- Manually construct a node as make_node would (user library)
            local uri = "zotero://select/library/items/ITEM1"
            local node = Node:new({
                id = "zotero-ITEM1",
                origin = uri,
                range = Range:new(
                    { row = 0, column = 0, offset = 0 },
                    { row = 0, column = 0, offset = 0 }
                ),
                file = uri,
                mtime = 0,
                title = "Test Paper",
                aliases = {},
                tags = { "zotero" },
                level = 0,
                linked = {},
            })

            assert.are.equal("zotero-ITEM1", node.id)
            assert.are.equal(uri, node.origin)
            assert.are.equal(uri, node.file)
            assert.are.equal("Test Paper", node.title)
            assert.are.equal(0, node.level)
            assert.is_true(node:is_file_node())
            assert.is_false(node:is_headline_node())
            assert.are.same({ "zotero" }, node.tags)
        end)

        it("should insert nodes into the org-roam database", function()
            local roam = utils.init_plugin({ setup = true })

            -- Load the database first
            roam.database:load():wait()

            local uri = "zotero://select/library/items/ITEM1"
            local node = Node:new({
                id = "zotero-ITEM1",
                origin = uri,
                range = Range:new(
                    { row = 0, column = 0, offset = 0 },
                    { row = 0, column = 0, offset = 0 }
                ),
                file = uri,
                mtime = 0,
                title = "My Zotero Paper",
                aliases = {},
                tags = { "zotero" },
                level = 0,
                linked = {},
            })

            -- Insert the node
            roam.database:insert(node, { overwrite = true }):wait()

            -- Verify we can retrieve it
            local retrieved = roam.database:get_sync("zotero-ITEM1")
            assert.is_not_nil(retrieved)
            assert.are.equal("My Zotero Paper", retrieved.title)
            assert.are.equal(uri, retrieved.file)
            assert.are.equal(uri, retrieved.origin)
        end)

        it("should find Zotero nodes by origin", function()
            local roam = utils.init_plugin({ setup = true })

            roam.database:load():wait()

            local uri = "zotero://select/library/items/ABC"
            local node = Node:new({
                id = "zotero-ABC",
                origin = uri,
                range = Range:new(
                    { row = 0, column = 0, offset = 0 },
                    { row = 0, column = 0, offset = 0 }
                ),
                file = uri,
                mtime = 0,
                title = "Searchable Paper",
                aliases = {},
                tags = { "zotero" },
                level = 0,
                linked = {},
            })

            roam.database:insert(node, { overwrite = true }):wait()

            local results = roam.database:find_nodes_by_origin_sync(uri)
            assert.are.equal(1, #results)
            assert.are.equal("Searchable Paper", results[1].title)
        end)

        it("should find Zotero nodes by tag", function()
            local roam = utils.init_plugin({ setup = true })

            roam.database:load():wait()

            local uri = "zotero://select/library/items/TAG"
            local node = Node:new({
                id = "zotero-TAG",
                origin = uri,
                range = Range:new(
                    { row = 0, column = 0, offset = 0 },
                    { row = 0, column = 0, offset = 0 }
                ),
                file = uri,
                mtime = 0,
                title = "Tagged Paper",
                aliases = {},
                tags = { "zotero", "machine-learning" },
                level = 0,
                linked = {},
            })

            roam.database:insert(node, { overwrite = true }):wait()

            local results = roam.database:find_nodes_by_tag_sync("zotero")
            assert.is_true(#results >= 1)

            local found = false
            for _, n in ipairs(results) do
                if n.id == "zotero-TAG" then
                    found = true
                    break
                end
            end
            assert.is_true(found)
        end)

        it("should preserve Zotero nodes across database reloads", function()
            local roam = utils.init_plugin({ setup = true })

            roam.database:load():wait()

            -- Set up the Zotero plugin instance with tracked nodes
            -- (simulates what happens during sync())
            ZoteroPlugin.setup({
                api_key = "test",
                library_id = "test",
                prefer_local_api = false,
            })
            local inst = ZoteroPlugin.instance()
            ---@cast inst org-roam-zotero.Plugin

            local uri = "zotero://select/library/items/PERSIST"
            local node = Node:new({
                id = "zotero-PERSIST",
                origin = uri,
                range = Range:new(
                    { row = 0, column = 0, offset = 0 },
                    { row = 0, column = 0, offset = 0 }
                ),
                file = uri,
                mtime = 0,
                title = "Persistent Paper",
                aliases = {},
                tags = { "zotero" },
                level = 0,
                linked = {},
            })

            -- Track the node (as sync() would) and insert it
            rawget(inst, "__synced_nodes")["zotero-PERSIST"] = node
            roam.database:insert(node, { overwrite = true }):wait()

            -- Install the load wrapper (as sync() would)
            local mt = getmetatable(roam.database) or {}
            local original_load = rawget(mt, "load")
            rawset(roam.database, "load", function(self, opts)
                return original_load(self, opts):next(function(result)
                    if result and result.database then
                        local synced = rawget(inst, "__synced_nodes")
                        for id, n in pairs(synced) do
                            if not result.database:has(id) then
                                result.database:insert(n, { id = id, overwrite = true })
                            end
                        end
                    end
                    return result
                end)
            end)

            -- Verify the node exists before reload
            local before = roam.database:get_sync("zotero-PERSIST")
            assert.is_not_nil(before)
            assert.are.equal("Persistent Paper", before.title)

            -- Force a full database reload (simulates what happens on save)
            roam.database:load():wait()

            -- Verify the node still exists after reload
            local after = roam.database:get_sync("zotero-PERSIST")
            assert.is_not_nil(after)
            assert.are.equal("Persistent Paper", after.title)
            assert.are.equal(uri, after.file)
        end)

        it("should make Zotero nodes findable by title", function()
            local roam = utils.init_plugin({ setup = true })

            roam.database:load():wait()

            local uri = "zotero://select/library/items/TITLE"
            local node = Node:new({
                id = "zotero-TITLE",
                origin = uri,
                range = Range:new(
                    { row = 0, column = 0, offset = 0 },
                    { row = 0, column = 0, offset = 0 }
                ),
                file = uri,
                mtime = 0,
                title = "Unique Zotero Title For Find",
                aliases = {},
                tags = { "zotero" },
                level = 0,
                linked = {},
            })

            roam.database:insert(node, { overwrite = true }):wait()

            -- Verify findable by title (used by find-node and completion)
            local results = roam.database:find_nodes_by_title_sync("Unique Zotero Title For Find")
            assert.are.equal(1, #results)
            assert.are.equal("zotero-TITLE", results[1].id)
        end)

        it("should extract org-roam links from buffer body for Zotero relations", function()
            -- This tests the new flow: org-roam links in the body → Zotero relations on write.
            -- The extract_org_links function parses [[id:zotero-*]] links.
            local body = table.concat({
                "This paper discusses [[id:zotero-ITEMB][Paper B]].",
                "",
                "Also see [[id:zotero-ITEMC]].",
            }, "\n")

            local linked_keys = Buffer.extract_org_links(body)
            assert.are.same({ "ITEMB", "ITEMC" }, linked_keys)

            -- Build relation URIs for these links + the note's own parent
            local relation_uris = {}
            local seen = {}

            -- Own parent item
            local self_uri = Buffer.build_relation_uri("user", "12345", "ITEMA")
            table.insert(relation_uris, self_uri)
            seen[self_uri] = true

            -- Linked items
            for _, key in ipairs(linked_keys) do
                local uri = Buffer.build_relation_uri("user", "12345", key)
                if not seen[uri] then
                    table.insert(relation_uris, uri)
                    seen[uri] = true
                end
            end

            assert.are.equal(3, #relation_uris)
            assert.are.equal("http://zotero.org/users/12345/items/ITEMA", relation_uris[1])
            assert.are.equal("http://zotero.org/users/12345/items/ITEMB", relation_uris[2])
            assert.are.equal("http://zotero.org/users/12345/items/ITEMC", relation_uris[3])
        end)

        it("should work with group library URIs", function()
            local roam = utils.init_plugin({ setup = true })

            roam.database:load():wait()

            local uri = "zotero://select/groups/12345/items/GRPITEM"
            local node = Node:new({
                id = "zotero-GRPITEM",
                origin = uri,
                range = Range:new(
                    { row = 0, column = 0, offset = 0 },
                    { row = 0, column = 0, offset = 0 }
                ),
                file = uri,
                mtime = 0,
                title = "Group Paper",
                aliases = {},
                tags = { "zotero" },
                level = 0,
                linked = {},
            })

            roam.database:insert(node, { overwrite = true }):wait()

            local retrieved = roam.database:get_sync("zotero-GRPITEM")
            assert.is_not_nil(retrieved)
            assert.are.equal("Group Paper", retrieved.title)
            assert.are.equal(uri, retrieved.file)
            assert.are.equal(uri, retrieved.origin)
        end)
    end)
end)

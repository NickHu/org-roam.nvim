describe("org-roam-zotero", function()
    local Buffer = require("org-roam-zotero.buffer")
    local Config = require("org-roam-zotero.config")
    local Api = require("org-roam-zotero.api")

    describe("config", function()
        it("should use defaults when no options are given", function()
            local config = Config:new()
            assert.are.equal("", config.api_key)
            assert.are.equal("user", config.library_type)
            assert.are.equal("", config.library_id)
            assert.are.equal(false, config.auto_sync)
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

    describe("buffer", function()
        describe("parse_uri", function()
            it("should parse valid zotero:// URIs", function()
                local item_key, note_key = Buffer.parse_uri("zotero://ABC123/DEF456")
                assert.are.equal("ABC123", item_key)
                assert.are.equal("DEF456", note_key)
            end)

            it("should return nil for invalid URIs", function()
                local item_key, note_key = Buffer.parse_uri("not-a-zotero-uri")
                assert.is_nil(item_key)
                assert.is_nil(note_key)
            end)

            it("should return nil for partial URIs", function()
                local item_key, note_key = Buffer.parse_uri("zotero://ABC123")
                assert.is_nil(item_key)
                assert.is_nil(note_key)
            end)
        end)

        describe("build_uri", function()
            it("should construct a valid zotero:// URI", function()
                local uri = Buffer.build_uri("ITEM1", "NOTE1")
                assert.are.equal("zotero://ITEM1/NOTE1", uri)
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
            it("should produce org content with properties and body", function()
                local lines = Buffer.build_org_content(
                    "ITEM1", "NOTE1", "My Paper",
                    "<p>Some notes here</p>", 42,
                    "zotero-ITEM1-NOTE1"
                )
                assert.are.equal(":PROPERTIES:", lines[1])
                assert.are.equal(":ID: zotero-ITEM1-NOTE1", lines[2])
                assert.are.equal(":ROAM_ORIGIN: zotero://ITEM1", lines[3])
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
                    "", 1, "zotero-ITEM1-NOTE1"
                )
                -- Should have properties + title + blank line, no body
                assert.are.equal(":PROPERTIES:", lines[1])
                assert.are.equal("#+title: Empty Paper", lines[8])
                assert.are.equal("", lines[9])
                assert.are.equal(nil, lines[10])
            end)
        end)

        describe("parse_buffer_metadata", function()
            it("should extract metadata from org buffer", function()
                local buf = vim.api.nvim_create_buf(false, true)
                vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
                    ":PROPERTIES:",
                    ":ID: zotero-ITEM1-NOTE1",
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
        end)

        describe("extract_body", function()
            it("should extract body after properties and title", function()
                local buf = vim.api.nvim_create_buf(false, true)
                vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
                    ":PROPERTIES:",
                    ":ID: zotero-ITEM1-NOTE1",
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
                    ":ID: zotero-ITEM1-NOTE1",
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
            -- Manually construct a node as make_node would
            local node = Node:new({
                id = "zotero-ITEM1-NOTE1",
                origin = "zotero://ITEM1",
                range = Range:new(
                    { row = 0, column = 0, offset = 0 },
                    { row = 0, column = 0, offset = 0 }
                ),
                file = "zotero://ITEM1/NOTE1",
                mtime = 0,
                title = "Test Paper",
                aliases = {},
                tags = { "zotero" },
                level = 0,
                linked = {},
            })

            assert.are.equal("zotero-ITEM1-NOTE1", node.id)
            assert.are.equal("zotero://ITEM1", node.origin)
            assert.are.equal("zotero://ITEM1/NOTE1", node.file)
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

            local node = Node:new({
                id = "zotero-ITEM1-NOTE1",
                origin = "zotero://ITEM1",
                range = Range:new(
                    { row = 0, column = 0, offset = 0 },
                    { row = 0, column = 0, offset = 0 }
                ),
                file = "zotero://ITEM1/NOTE1",
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
            local retrieved = roam.database:get_sync("zotero-ITEM1-NOTE1")
            assert.is_not_nil(retrieved)
            assert.are.equal("My Zotero Paper", retrieved.title)
            assert.are.equal("zotero://ITEM1/NOTE1", retrieved.file)
            assert.are.equal("zotero://ITEM1", retrieved.origin)
        end)

        it("should find Zotero nodes by origin", function()
            local roam = utils.init_plugin({ setup = true })

            roam.database:load():wait()

            local node = Node:new({
                id = "zotero-ABC-DEF",
                origin = "zotero://ABC",
                range = Range:new(
                    { row = 0, column = 0, offset = 0 },
                    { row = 0, column = 0, offset = 0 }
                ),
                file = "zotero://ABC/DEF",
                mtime = 0,
                title = "Searchable Paper",
                aliases = {},
                tags = { "zotero" },
                level = 0,
                linked = {},
            })

            roam.database:insert(node, { overwrite = true }):wait()

            local results = roam.database:find_nodes_by_origin_sync("zotero://ABC")
            assert.are.equal(1, #results)
            assert.are.equal("Searchable Paper", results[1].title)
        end)

        it("should find Zotero nodes by tag", function()
            local roam = utils.init_plugin({ setup = true })

            roam.database:load():wait()

            local node = Node:new({
                id = "zotero-TAG-TEST",
                origin = "zotero://TAG",
                range = Range:new(
                    { row = 0, column = 0, offset = 0 },
                    { row = 0, column = 0, offset = 0 }
                ),
                file = "zotero://TAG/TEST",
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
                if n.id == "zotero-TAG-TEST" then
                    found = true
                    break
                end
            end
            assert.is_true(found)
        end)

        it("should preserve Zotero nodes across database reloads", function()
            local roam = utils.init_plugin({ setup = true })
            local ZoteroPlugin = require("org-roam-zotero")

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

            local node = Node:new({
                id = "zotero-PERSIST-TEST",
                origin = "zotero://PERSIST",
                range = Range:new(
                    { row = 0, column = 0, offset = 0 },
                    { row = 0, column = 0, offset = 0 }
                ),
                file = "zotero://PERSIST/TEST",
                mtime = 0,
                title = "Persistent Paper",
                aliases = {},
                tags = { "zotero" },
                level = 0,
                linked = {},
            })

            -- Track the node (as sync() would) and insert it
            rawget(inst, "__synced_nodes")["zotero-PERSIST-TEST"] = node
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
            local before = roam.database:get_sync("zotero-PERSIST-TEST")
            assert.is_not_nil(before)
            assert.are.equal("Persistent Paper", before.title)

            -- Force a full database reload (simulates what happens on save)
            roam.database:load():wait()

            -- Verify the node still exists after reload
            local after = roam.database:get_sync("zotero-PERSIST-TEST")
            assert.is_not_nil(after)
            assert.are.equal("Persistent Paper", after.title)
            assert.are.equal("zotero://PERSIST/TEST", after.file)
        end)

        it("should make Zotero nodes findable by title", function()
            local roam = utils.init_plugin({ setup = true })

            roam.database:load():wait()

            local node = Node:new({
                id = "zotero-TITLE-FIND",
                origin = "zotero://TITLE",
                range = Range:new(
                    { row = 0, column = 0, offset = 0 },
                    { row = 0, column = 0, offset = 0 }
                ),
                file = "zotero://TITLE/FIND",
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
            assert.are.equal("zotero-TITLE-FIND", results[1].id)
        end)
    end)
end)

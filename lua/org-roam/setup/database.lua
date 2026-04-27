-------------------------------------------------------------------------------
-- DATABASE.LUA
--
-- Setup logic for roam database.
-------------------------------------------------------------------------------

---@param roam OrgRoam
---@return OrgPromise<{database:org-roam.core.Database, files:OrgFiles}>
return function(roam)
    local Promise = require("orgmode.utils.promise")

    -- Swap out the database for one configured properly
    roam.database = roam.database:new({
        db_path = roam.config.database.path,
        directory = roam.config.directory,
        org_files = roam.config.org_files,
    })

    -- Load the database asynchronously.
    --
    -- On the very first launch (no database cache on disk yet) force a full
    -- directory scan so the database gets populated from scratch, then save
    -- the result to disk.
    --
    -- On every subsequent launch just deserialise the cached database from
    -- disk. The expensive OrgFiles glob + TreeSitter pass is skipped entirely;
    -- it was saturating the vim.schedule queue with synchronous work (stat
    -- calls, TreeSitter parses) for every file on every startup, causing a
    -- multi-second UI stall on large vaults. Files are kept current by the
    -- update_on_save autocmd (per-save) and the :RoamUpdate command (manual
    -- full rescan).
    if vim.fn.filereadable(roam.config.database.path) == 1 then
        return roam.database
            :internal()
            :catch(require("org-roam.core.ui.notify").error)
    else
        return roam.database
            :load({ force = "scan" })
            :next(function()
                -- If we are persisting to disk, do so now as the database may
                -- have changed post-load
                if roam.config.database.persist then
                    return roam.database:save()
                else
                    return Promise.resolve(nil)
                end
            end)
            :catch(require("org-roam.core.ui.notify").error)
    end
end

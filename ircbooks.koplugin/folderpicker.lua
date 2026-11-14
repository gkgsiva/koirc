--[[--
Folder picker for the save folder, with a way to make a new folder.

KOReader's own PathChooser only lets you pick a folder that already exists
(newer versions hide "New folder" behind a long-press on the home icon).
This wraps it so that long-pressing a folder also offers "New folder here…",
and the new folder can be picked straight away.

The name checks and folder creation are kept free of UI code so the tests
can run them without KOReader.
]]

local FolderPicker = {}

-- Characters that FAT/exFAT storage (most e-readers) does not allow in names.
local BAD_CHARS = '[/\\:%*%?"<>|%c]'

local function lfs() return require("libs/libkoreader-lfs") end

--- Check a folder name typed by the user.
-- @treturn string|nil the cleaned name, or nil and an error message
function FolderPicker.validateName(name)
    name = (name or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if name == "" then return nil, "empty" end
    if name == "." or name == ".." then return nil, "invalid" end
    if name:find(BAD_CHARS) then return nil, "invalid" end
    if name:find("%.$") then return nil, "invalid" end -- FAT drops trailing dots
    if #name > 255 then return nil, "too_long" end
    return name
end

--- Make `name` inside `parent`.
-- @treturn string|nil the new folder's path, or nil, an error code and details.
-- Error codes: empty, invalid, too_long, exists (a folder; its path is the
-- third value), file_exists, failed (the system message is the third value).
function FolderPicker.makeFolder(parent, name, fs)
    fs = fs or lfs()
    local clean, err = FolderPicker.validateName(name)
    if not clean then return nil, err end
    parent = (parent or ""):gsub("/+$", "")
    local path = parent .. "/" .. clean
    local mode = fs.attributes(path, "mode")
    if mode == "directory" then return nil, "exists", path end
    if mode then return nil, "file_exists" end
    local ok, msg = fs.mkdir(path)
    if not ok then return nil, "failed", msg end
    return path
end

local function errorText(code, detail, name)
    local _ = require("gettext")
    local T = require("ffi/util").template
    if code == "empty" then return _("Please type a name for the folder.") end
    if code == "invalid" then
        return T(_("“%1” can't be used as a folder name.\n\nAvoid / \\ : * ? \" < > | and names ending in a dot."), name)
    end
    if code == "too_long" then return _("That folder name is too long.") end
    if code == "file_exists" then return T(_("There is already a file called “%1” here."), name) end
    return T(_("Could not create the folder:\n%1"), tostring(detail or _("unknown error")))
end

--- Ask for a name and make a new folder inside `parent`.
-- on_created(path, existed) is called with the folder's path; `existed` is
-- true when a folder of that name was already there.
function FolderPicker.promptNewFolder(parent, on_created)
    local UIManager = require("ui/uimanager")
    local InputDialog = require("ui/widget/inputdialog")
    local InfoMessage = require("ui/widget/infomessage")
    local _ = require("gettext")
    local T = require("ffi/util").template
    local dialog
    dialog = InputDialog:new{
        title = _("New folder"),
        description = T(_("Inside: %1"), parent),
        input = "",
        input_hint = _("Folder name"),
        buttons = {{
            {
                text = _("Cancel"),
                id = "close",
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = _("Create"),
                is_enter_default = true,
                callback = function()
                    local name = dialog:getInputText()
                    local path, err, detail = FolderPicker.makeFolder(parent, name)
                    if err == "exists" then
                        UIManager:close(dialog)
                        UIManager:show(InfoMessage:new{
                            text = T(_("The folder “%1” already exists, so it was opened."), (detail:match("[^/]+$"))),
                            timeout = 3,
                        })
                        on_created(detail, true)
                        return
                    elseif not path then
                        -- Keep the dialog open so the name can be fixed.
                        UIManager:show(InfoMessage:new{ text = errorText(err, detail, name) })
                        return
                    end
                    UIManager:close(dialog)
                    on_created(path, false)
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

--- Show a folder picker. onConfirm(path) is called with the chosen folder.
function FolderPicker.choose(start_path, onConfirm)
    local PathChooser = require("ui/widget/pathchooser")
    local ButtonDialog = require("ui/widget/buttondialog")
    local ConfirmBox = require("ui/widget/confirmbox")
    local UIManager = require("ui/uimanager")
    local ffiUtil = require("ffi/util")
    local _ = require("gettext")
    local T = ffiUtil.template

    local Chooser = PathChooser:extend{}

    -- Open the new folder and offer to use it right away.
    function Chooser:afterCreate(path)
        self:changeToPath(path)
        UIManager:show(ConfirmBox:new{
            text = T(_("Save books in this folder?\n\n%1"), path),
            ok_text = _("Use this folder"),
            cancel_text = _("Keep browsing"),
            ok_callback = function()
                UIManager:close(self)
                onConfirm(path)
            end,
        })
    end

    function Chooser:newFolderIn(parent)
        FolderPicker.promptNewFolder(parent, function(path) self:afterCreate(path) end)
    end

    function Chooser:onMenuHold(item)
        local path = item.path
        if path:sub(-2) == "/." then path = path:sub(1, -3) end
        path = ffiUtil.realpath(path)
        if not path or lfs().attributes(path, "mode") ~= "directory" then return true end
        local dialog
        dialog = ButtonDialog:new{
            title = T(_("Choose this folder?\n\n%1\n"), path),
            buttons = {
                {{
                    text = _("New folder here…"),
                    callback = function()
                        UIManager:close(dialog)
                        self:newFolderIn(path)
                    end,
                }},
                {
                    { text = _("Cancel"), callback = function() UIManager:close(dialog) end },
                    {
                        text = _("Choose"),
                        callback = function()
                            UIManager:close(dialog)
                            UIManager:close(self)
                            onConfirm(path)
                        end,
                    },
                },
            },
        }
        UIManager:show(dialog)
        return true
    end

    -- Newer KOReader opens this on a long-press of the home icon; point its
    -- "New folder" at ours so the new folder can be picked straight away.
    function Chooser:showPlusMenu()
        self:newFolderIn(self.path)
    end

    if not (start_path and lfs().attributes(start_path, "mode") == "directory") then
        start_path = nil
    end
    UIManager:show(Chooser:new{
        title = _("Long-press a folder to choose it or make a new one"),
        select_file = false,
        show_files = false,
        path = start_path or (G_reader_settings and G_reader_settings:readSetting("home_dir")) or "/",
    })
end

return FolderPicker

-- authors: Luxinia Dev (Eike Decker & Christoph Kubisch)
---------------------------------------------------------

-- put bin/ and lualibs/ first to avoid conflicts with included modules
-- that may have other versions present somewhere else in path/cpath.
-- don't need to do this on Linux where we expect all the libraries
-- and binaries to be installed in *regular* places.
local iswindows = os.getenv('WINDIR') or (os.getenv('OS') or ''):match('[Ww]indows')

if iswindows or not pcall(require, "wx")
  or wx.wxPlatformInfo.Get():GetOperatingSystemFamilyName() == 'Macintosh' then
  package.cpath = (iswindows
    and 'bin/?.dll;bin/clibs/?.dll;'
     or 'bin/clibs/?.dylib;bin/lib?.dylib;')
    .. package.cpath
end

package.path  = 'lualibs/?.lua;lualibs/?/?.lua;lualibs/?/init.lua;lualibs/?/?/?.lua;lualibs/?/?/init.lua;'
              .. package.path

require("wx")
require("bit")

dofile "src/misc/util.lua"

-----------
-- IDE
--
-- Setup important defaults
dofile "src/editor/ids.lua"
dofile "src/editor/style.lua"

ide = {
  config = {
    path = {
      projectdir = "",
      app = nil,
    },
    editor = {
      usetabs = true,
      autotabs = true,
    },
    debugger = {
      verbose = false,
      hostname = nil,
      port = nil,
    },
    default = {
      name = 'untitled',
      fullname = 'untitled.lua',
    },
    outputshell = {},
    filetree = {},

    keymap = {},
    messages = {},
    language = "en",

    styles = StylesGetDefault(),
    stylesoutshell = StylesGetDefault(),
    interpreter = "_undefined_",

    autocomplete = true,
    acandtip = {
      shorttip = false,
      ignorecase = false,
      strategy = 2,
      width = 60,
    },

    activateoutput = false, -- activate output/console on Run/Debug/Compile
    unhidewindow = false, -- to unhide a gui window
    allowinteractivescript = false, -- allow interaction in the output window
    filehistorylength = 20,
    projecthistorylength = 15,
    savebak = false,
    singleinstance = false,
    singleinstanceport = 0xe493,
  },
  specs = {
    none = {
      linecomment = ">",
      sep = "\1",
    }
  },
  tools = {
  },
  iofilters = {
  },
  interpreters = {
  },

  app = nil, -- application engine
  interpreter = nil, -- current Lua interpreter
  frame = nil, -- gui related
  debugger = {}, -- debugger related info
  filetree = nil, -- filetree
  findReplace = nil, -- find & replace handling
  settings = nil, -- user settings (window pos, last files..)
  session = {
    projects = {}, -- project configuration for the current session
    lastupdated = nil, -- timestamp of the last modification in any of the editors
    lastsaved = nil, -- timestamp of the last recovery information saved
  },

  -- misc
  exitingProgram = false, -- are we currently exiting, ID_EXIT
  editorApp = wx.wxGetApp(),
  editorFilename = nil,
  openDocuments = {},-- open notebook editor documents[winId] = {
  -- editor = wxStyledTextCtrl,
  -- index = wxNotebook page index,
  -- filePath = full filepath, nil if not saved,
  -- fileName = just the filename,
  -- modTime = wxDateTime of disk file or nil,
  -- isModified = bool is the document modified? }
  ignoredFilesList = {},
  font = {
    eNormal = nil,
    eItalic = nil,
    oNormal = nil,
    oItalic = nil,
    fNormal = nil,
  }
}

dofile "src/editor/keymap.lua"

function setLuaPaths(mainpath, osname)
  -- use LUA_DEV to setup paths for Lua for Windows modules if installed
  local luadev = osname == "Windows" and os.getenv('LUA_DEV')
  local luadev_path = (luadev
    and ('LUA_DEV/?.lua;LUA_DEV/?/init.lua;LUA_DEV/lua/?.lua;LUA_DEV/lua/?/init.lua')
      :gsub('LUA_DEV', (luadev:gsub('[\\/]$','')))
    or "")
  local luadev_cpath = (luadev
    and ('LUA_DEV/?.dll;LUA_DEV/clibs/?.dll')
      :gsub('LUA_DEV', (luadev:gsub('[\\/]$','')))
    or "")

  -- (luaconf.h) in Windows, any exclamation mark ('!') in the path is replaced
  -- by the path of the directory of the executable file of the current process.
  -- this effectively prevents any path with an exclamation mark from working.
  -- if the path has an excamation mark, allow Lua to expand it as this
  -- expansion happens only once.
  if osname == "Windows" and mainpath:find('%!') then mainpath = "!/../" end
  wx.wxSetEnv("LUA_PATH", package.path .. ";"
    .. "./?.lua;./?/init.lua;./lua/?.lua;./lua/?/init.lua" .. ';'
    .. mainpath.."lualibs/?/?.lua;"..mainpath.."lualibs/?.lua" .. ';'
    .. luadev_path)

  local clibs =
    osname == "Windows" and mainpath.."bin/?.dll;"..mainpath.."bin/clibs/?.dll" or
    osname == "Macintosh" and mainpath.."bin/lib?.dylib;"..mainpath.."bin/clibs/?.dylib" or
    osname == "Unix" and mainpath.."bin/?.so;"..mainpath.."bin/clibs/?.so" or nil
  if clibs then wx.wxSetEnv("LUA_CPATH",
    package.cpath .. ';' .. clibs .. ';' .. luadev_cpath) end
end

---------------
-- process args
local filenames = {}
local configs = {}
do
  local arg = {...}
  local fullPath = arg[1] -- first argument must be the application name
  assert(type(fullPath) == "string", "first argument must be application name")

  ide.arg = arg
  ide.osname = wx.wxPlatformInfo.Get():GetOperatingSystemFamilyName()

  -- on Windows use GetExecutablePath, which is Unicode friendly,
  -- whereas wxGetCwd() is not (at least in wxlua 2.8.12.2).
  -- some wxlua version on windows report wx.dll instead of *.exe.
  local exepath = wx.wxStandardPaths.Get():GetExecutablePath()
  fullPath = wx.wxGetCwd().."/"..fullPath

  ide.editorFilename = fullPath
  ide.config.path.app = fullPath:match("([%w_-%.]+)$"):gsub("%.[^%.]*$","")
  assert(ide.config.path.app, "no application path defined")

  for index = 2, #arg do
    if (arg[index] == "-cfg" and index+1 <= #arg) then
      local str = arg[index+1]
      if #str < 4 then
        print("Comandline: -cfg arg data not passed as string")
      else
        table.insert(configs,str)
      end
    elseif arg[index-1] ~= "-cfg" then
      table.insert(filenames,arg[index])
    end
  end

  setLuaPaths(GetPathWithSep(ide.editorFilename), ide.osname)
end

----------------------
-- process application

ide.app = dofile(ide.config.path.app.."/app.lua")
local app = ide.app
assert(app)

local function addToTab(tab,file)
  local cfgfn,err = loadfile(file)
  if not cfgfn then
    print(("Error while loading configuration file: %s"):format(err))
  else
    local name = file:match("([a-zA-Z_0-9]+)%.lua$")
    local success, result = pcall(function()return cfgfn(assert(_G or _ENV))end)
    if not success then
      print(("Error while processing configuration file: %s"):format(result))
    elseif name then
      if (tab[name]) then
        local out = tab[name]
        for i,v in pairs(result) do
          out[i] = v
        end
      else
        tab[name] = result
      end
    end
  end
end

-- load interpreters
local function loadInterpreters(filter)
  for _, file in ipairs(FileSysGet("interpreters/*.*", wx.wxFILE)) do
    if file:match "%.lua$" and (filter or app.loadfilters.interpreters)(file) then
      addToTab(ide.interpreters,file)
    end
  end
end

-- load specs
local function loadSpecs(filter)
  for _, file in ipairs(FileSysGet("spec/*.*", wx.wxFILE)) do
    if file:match("%.lua$") and (filter or app.loadfilters.specs)(file) then
      addToTab(ide.specs,file)
    end
  end

  for _, spec in pairs(ide.specs) do
    spec.sep = spec.sep or "\1" -- default separator doesn't match anything
    spec.iscomment = {}
    spec.iskeyword0 = {}
    spec.isstring = {}
    if (spec.lexerstyleconvert) then
      if (spec.lexerstyleconvert.comment) then
        for _, s in pairs(spec.lexerstyleconvert.comment) do
          spec.iscomment[s] = true
        end
      end
      if (spec.lexerstyleconvert.keywords0) then
        for _, s in pairs(spec.lexerstyleconvert.keywords0) do
          spec.iskeyword0[s] = true
        end
      end
      if (spec.lexerstyleconvert.stringtxt) then
        for _, s in pairs(spec.lexerstyleconvert.stringtxt) do
          spec.isstring[s] = true
        end
      end
    end
  end
end

-- load tools
local function loadTools(filter)
  for _, file in ipairs(FileSysGet("tools/*.*", wx.wxFILE)) do
    if file:match "%.lua$" and (filter or app.loadfilters.tools)(file) then
      addToTab(ide.tools,file)
    end
  end
end

-- temporarily replace print() to capture reported error messages to show
-- them later in the Output window after everything is loaded.
local resumePrint do
  local errors = {}
  local origprint = print
  print = function(...) errors[#errors+1] = {...} end
  resumePrint = function()
    print = origprint
    for _, e in ipairs(errors) do DisplayOutput(unpack(e), "\n") end
  end
end

-----------------------
-- load config
local function addConfig(filename,isstring)
  -- skip those files that don't exist
  if not isstring and not wx.wxFileName(filename):FileExists() then return end
  -- if it's marked as command, but exists as a file, load it as a file
  if isstring and wx.wxFileName(filename):FileExists() then isstring = false end

  local cfgfn, err, msg
  if isstring
  then msg, cfgfn, err = "string", loadstring(filename)
  else msg, cfgfn, err = "file", loadfile(filename) end

  if not cfgfn then
    print(("Error while loading configuration %s: %s"):format(msg, err))
  else
    ide.config.os = os
    ide.config.wxstc = wxstc
    ide.config.load = { interpreters = loadInterpreters,
      specs = loadSpecs, tools = loadTools }
    setfenv(cfgfn,ide.config)
    local _, err = pcall(function()cfgfn(assert(_G or _ENV))end)
    if err then
      print(("Error while processing configuration %s: %s"):format(msg, err))
    end
  end
end

function GetIDEString(keyword, default)
  return app.stringtable[keyword] or default or keyword
end

----------------------
-- process config

addConfig(ide.config.path.app.."/config.lua")

----------------------
-- process plugins

if app.preinit then app.preinit() end

loadInterpreters()
loadSpecs()
loadTools()

do
  -- process user config
  for _, file in ipairs(FileSysGet("cfg/user.lua", wx.wxFILE)) do
    addConfig(file)
  end
  local home = os.getenv("HOME")
  if home then
    for _, file in ipairs(FileSysGet(home .. "/.zbstudio/user.lua", wx.wxFILE)) do
      addConfig(file)
    end
  end
  -- process all other configs (if any)
  for _, v in ipairs(configs) do
    addConfig(v, true)
  end
  configs = nil
  local sep = string_Pathsep
  if ide.config.language then
    addToTab(ide.config.messages, "cfg"..sep.."i18n"..sep..ide.config.language..".lua")
  end
end

-- load this after preinit and processing configs to allow
-- each of the lists to be modified

---------------
-- Load App

for _, file in ipairs({
    "markup", "settings", "singleinstance", "iofilters",
    "gui", "filetree", "output", "debugger", "preferences",
    "editor", "findreplace", "commands", "autocomplete", "shellbox",
    "menu_file", "menu_edit", "menu_search",
    "menu_view", "menu_project", "menu_tools", "menu_help",
    "inspect" }) do
  dofile("src/editor/"..file..".lua")
end

dofile "src/preferences/editor.lua"
dofile "src/preferences/project.lua"
dofile "src/version.lua"

-- load rest of settings
SettingsRestoreEditorSettings()
SettingsRestoreFramePosition(ide.frame, "MainFrame")
SettingsRestoreFileSession(function(tabs, params)
  if params and params.recovery
  then return SetOpenTabs(params)
  else return SetOpenFiles(tabs, params) end
end)
SettingsRestoreFileHistory(UpdateFileHistoryUI)
SettingsRestoreProjectSession(FileTreeSetProjects)
SettingsRestoreView()

-- ---------------------------------------------------------------------------
-- Load the filenames

do
  for _, fileName in ipairs(filenames) do
    if fileName ~= "--" then
      LoadFile(fileName, nil, true)
    end
  end

  local notebook = ide.frame.notebook
  if notebook:GetPageCount() == 0 then NewFile() end
end

if app.postinit then app.postinit() end

-- only set menu bar *after* postinit handler as it may include adding
-- app-specific menus (Help/About), which are not recognized by MacOS
-- as special items unless SetMenuBar is done after menus are populated.
ide.frame:SetMenuBar(ide.frame.menuBar)
if ide.osname == 'Macintosh' then -- force refresh to fix the filetree
  pcall(function() ide.frame:ShowFullScreen(true) ide.frame:ShowFullScreen(false) end)
end

resumePrint()

ide.frame:Show(true)
wx.wxGetApp():MainLoop()

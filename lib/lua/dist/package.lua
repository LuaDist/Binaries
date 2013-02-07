-- Package functions

module ("dist.package", package.seeall)

local cfg = require "dist.config"
local git = require "dist.git"
local sys = require "dist.sys"
local mf = require "dist.manifest"
local utils = require "dist.utils"
local depends = require "dist.depends"

-- Remove package from 'pkg_distinfo_dir' of 'deploy_dir'.
function remove_pkg(pkg_distinfo_dir, deploy_dir)
    deploy_dir = deploy_dir or cfg.root_dir
    assert(type(pkg_distinfo_dir) == "string", "package.remove_pkg: Argument 'pkg_distinfo_dir' is not a string.")
    assert(type(deploy_dir) == "string", "package.remove_pkg: Argument 'deploy_dir' is not a string.")
    deploy_dir = sys.abs_path(deploy_dir)

    local abs_pkg_distinfo_dir = sys.make_path(deploy_dir, pkg_distinfo_dir)

    -- check for 'dist.info'
    local info, err = mf.load_distinfo(sys.make_path(abs_pkg_distinfo_dir, "dist.info"))
    if not info then return nil, "Error removing package from '" .. pkg_distinfo_dir .. "' - it doesn't contain valid 'dist.info' file." end
    if not info.files then return nil, "File '" .. sys.make_path(pkg_distinfo_dir, "dist.info") .."' doesn't contain list of installed files." end

    -- remove files installed as components of this package
    for _, component in ipairs(cfg.components) do
        if info.files[component] then
            for i = #info.files[component], 1, -1 do
                local f = info.files[component][i]
                f = sys.make_path(deploy_dir,f)
                if sys.is_file(f) then
                    sys.delete(f)
                elseif sys.is_dir(f) then
                    local dir_files, err = sys.get_file_list(f)
                    if not dir_files then return nil, "Error removing package in '" .. abs_pkg_distinfo_dir .. "': " .. err end
                    if #dir_files == 0 then sys.delete(f) end
                end
                -- delete also all parent directories if empty
                local parents = sys.parents_up_to(f, deploy_dir)
                for _, parent in ipairs(parents) do
                    if sys.is_dir(parent) then
                        local dir_files, err = sys.get_file_list(parent)
                        if not dir_files then return nil, "Error removing package in '" .. abs_pkg_distinfo_dir .. "': " .. err end
                        if #dir_files == 0 then
                            sys.delete(parent)
                        end
                    end
                end
            end
        end
    end

    -- remove removed components also from 'dist.info'
    for _, component in ipairs(cfg.components) do
        info.files[component] = nil
    end

    -- delete the package information from deploy_dir
    local ok = sys.delete(abs_pkg_distinfo_dir)
    if not ok then return nil, "Error removing package in '" .. abs_pkg_distinfo_dir .. "'." end

    -- if the package was not completely removed (e.g. some components remain),
    -- save the new version of its 'dist.info'
    local comp_num = 0
    for _, _ in pairs(info.files) do comp_num  = comp_num + 1 end
    if comp_num ~= 0 then
        sys.make_dir(abs_pkg_distinfo_dir)
        local ok, err = mf.save_distinfo(info, sys.make_path(abs_pkg_distinfo_dir, "dist.info"))
        if not ok then return nil, "Error resaving the 'dist.info': " .. err end
    end

    return ok
end

-- Install package from 'pkg_dir' to 'deploy_dir', using optional CMake 'variables'.
-- Optional 'preserve_pkg_dir' argument specified whether to preserve the 'pkg_dir'.
function install_pkg(pkg_dir, deploy_dir, variables, preserve_pkg_dir)
    deploy_dir = deploy_dir or cfg.root_dir
    variables = variables or {}
    preserve_pkg_dir = preserve_pkg_dir or false

    assert(type(pkg_dir) == "string", "package.install_pkg: Argument 'pkg_dir' is not a string.")
    assert(type(deploy_dir) == "string", "package.install_pkg: Argument 'deploy_dir' is not a string.")
    assert(type(variables) == "table", "package.install_pkg: Argument 'variables' is not a table.")
    assert(type(preserve_pkg_dir) == "boolean", "package.install_pkg: Argument 'preserve_pkg_dir' is not a boolean.")

    pkg_dir = sys.abs_path(pkg_dir)
    deploy_dir = sys.abs_path(deploy_dir)

    -- check for dist.info
    local info, err = mf.load_distinfo(sys.make_path(pkg_dir, "dist.info"))
    if not info then return nil, "Error installing: the directory '" .. pkg_dir .. "' doesn't exist or doesn't contain valid 'dist.info' file." end

    -- check if the package is source
    if sys.exists(sys.make_path(pkg_dir, "CMakeLists.txt")) then
        info.arch = info.arch or "Universal"
        info.type = info.type or "source"
    end

    -- check package's architecture
    if info.arch ~= "Universal" and info.arch ~= cfg.arch then
        return nil, "Error installing '" .. info.name .. "-" .. info.version .. "': architecture '" .. info.arch .. "' is not suitable for this machine."
    end

    -- check package's type
    if info.type ~= "all" and info.type ~= "source" and info.type ~= cfg.type then
        return nil, "Error installing '" .. info.name .. "-" .. info.version .. "': architecture type '" .. info.type .. "' is not suitable for this machine."
    end

    local ok, err

    -- if package is of binary type, just deploy it
    if info.type ~= "source" then
        ok, err = deploy_binary_pkg(pkg_dir, deploy_dir)

    -- else build and then deploy
    else

        -- check if we have cmake
        ok = utils.system_dependency_available("cmake", "cmake --version")
        if not ok then return nil, "Error when installing: Command 'cmake' not available on the system." end

        -- set cmake variables
        local cmake_variables = {}

        -- set variables from config file
        for k, v in pairs(cfg.variables) do
            cmake_variables[k] = v
        end

        -- set variables specified as argument
        for k, v in pairs(variables) do
            cmake_variables[k] = v
        end

        cmake_variables.CMAKE_INCLUDE_PATH = table.concat({cmake_variables.CMAKE_INCLUDE_PATH or "", sys.make_path(deploy_dir, "include")}, ";")
        cmake_variables.CMAKE_LIBRARY_PATH = table.concat({cmake_variables.CMAKE_LIBRARY_PATH or "", sys.make_path(deploy_dir, "lib"), sys.make_path(deploy_dir, "bin")}, ";")
        cmake_variables.CMAKE_PROGRAM_PATH = table.concat({cmake_variables.CMAKE_PROGRAM_PATH or "", sys.make_path(deploy_dir, "bin")}, ";")

        -- build the package and deploy it
        ok, err = build_pkg(pkg_dir, deploy_dir, cmake_variables)
        if not ok then return nil, err end

    end

    -- delete directory of fetched package
    if not (cfg.debug or preserve_pkg_dir) then sys.delete(pkg_dir) end

    return ok, err
end

-- Build and deploy package from 'src_dir' to 'deploy_dir' using 'variables'.
-- Return directory to which the package was built or nil on error.
-- 'variables' is table of optional CMake variables.
function build_pkg(src_dir, deploy_dir, variables)
    deploy_dir = deploy_dir or cfg.root_dir
    variables = variables or {}

    assert(type(src_dir) == "string", "package.build_pkg: Argument 'src_dir' is not a string.")
    assert(type(deploy_dir) == "string", "package.build_pkg: Argument 'deploy_dir' is not a string.")
    assert(type(variables) == "table", "package.build_pkg: Argument 'variables' is not a table.")

    src_dir = sys.abs_path(src_dir)
    deploy_dir = sys.abs_path(deploy_dir)

    -- check for dist.info
    local info, err = mf.load_distinfo(sys.make_path(src_dir, "dist.info"))
    if not info then return nil, "Error building package from '" .. src_dir .. "': it doesn't contain valid 'dist.info' file." end
    local pkg_name = info.name .. "-" .. info.version

    -- set machine information
    info.arch = cfg.arch
    info.type = cfg.type

    -- create CMake build dir
    local cmake_build_dir = sys.abs_path(sys.make_path(deploy_dir, cfg.temp_dir, pkg_name .. "-CMake-build"))
    sys.make_dir(cmake_build_dir)

    -- create cmake cache
    variables["CMAKE_INSTALL_PREFIX"] = deploy_dir
    local cache_file = io.open(sys.make_path(cmake_build_dir, "cache.cmake"), "w")
    if not cache_file then return nil, "Error creating CMake cache file in '" .. cmake_build_dir .. "'" end

    -- Fill in cache variables
    for k,v in pairs(variables) do
        cache_file:write("SET(" .. k .. " " .. sys.quote(v):gsub("\\+", "/") .. " CACHE STRING \"\" FORCE)\n")
    end

    -- If user cache file is provided then append it
    if cfg.cache_file ~= "" then
        local user_cache = io.open(sys.abs_path(cfg.cache_file), "r")
        if user_cache then
            cache_file:write(user_cache:read("*all").."\n")
            user_cache:close()
        end
    end
    cache_file:close()

    src_dir = sys.abs_path(src_dir)
    print("Building " .. sys.extract_name(src_dir) .. "...")

    -- set cmake cache command
    local cache_command = cfg.cache_command
    if cfg.debug then cache_command = cache_command .. " " .. cfg.cache_debug_options end

    -- set cmake build command
    local build_command = cfg.build_command
    if cfg.debug then build_command = build_command .. " " .. cfg.build_debug_options end

    -- set the cmake cache
    local ok = sys.exec("cd " .. sys.quote(cmake_build_dir) .. " && " .. cache_command .. " " .. sys.quote(src_dir))
    if not ok then return nil, "Error preloading the CMake cache script '" .. sys.make_path(cmake_build_dir, "cmake.cache") .. "'" end

    -- build with cmake
    ok = sys.exec("cd " .. sys.quote(cmake_build_dir) .. " && " .. build_command)
    if not ok then return nil, "Error building with CMake in directory '" .. cmake_build_dir .. "'" end

    -- if this is only simulation, exit sucessfully, skipping the next actions
    if cfg.simulate then
        return true, "Simulated build and deployment of package '" .. pkg_name .. "' sucessfull."
    end

    -- table to collect files installed in the components
    info.files = {}

    local build_dir = sys.quote(cmake_build_dir)
    -- install the components
    for _, component in ipairs(cfg.components) do
        local strip_option = ""
        if not cfg.debug and component ~= "Library" then strip_option = cfg.strip_option end

        local ok = sys.exec("cd " .. build_dir .. " && " .. cfg.cmake .. " " .. strip_option .. " " ..cfg.install_component_command:gsub("#COMPONENT#", component))

        if not ok then return nil, "Error when installing the component '" .. component .. "' with CMake in directory '" .. cmake_build_dir .. "'" end

        local install_mf = sys.make_path(cmake_build_dir, "install_manifest_" .. component .. ".txt")
        local mf, err
        local component_files = {}

        -- collect files installed in this component
        if sys.exists(install_mf) then
            mf, err = io.open(install_mf, "r")
            if not mf then return nil, "Error when opening the CMake installation manifest '" .. install_mf .. "': " .. err end
            for line in mf:lines() do
                line = sys.check_separators(line)
                local file = line:gsub(utils.escape_magic(deploy_dir .. sys.path_separator()), "")
                table.insert(component_files, file)
            end
            mf:close()

            -- add list of component files to the 'dist.info'
            if #component_files > 0 then info.files[component] = component_files end
        end
    end
--    if bookmark == 0 then return nil, "Package did not install any files!" end

    -- test with ctest
    if cfg.test then
        print("Testing " .. sys.extract_name(src_dir) .. " ...")
        ok = sys.exec("cd " .. sys.quote(deploy_dir) .. " && " .. cfg.test_command)
        if not ok then return nil, "Error when testing the module '" .. pkg_name .. "' with CTest." end
    end

    -- save modified 'dist.info' file
    local pkg_distinfo_dir = sys.make_path(deploy_dir, cfg.distinfos_dir, pkg_name)
    sys.make_dir(pkg_distinfo_dir)
    ok, err = mf.save_distinfo(info, sys.make_path(pkg_distinfo_dir, "dist.info"))
    if not ok then return nil, err end

    -- clean up
    if not cfg.debug then sys.delete(cmake_build_dir) end

    return true, "Package '" .. pkg_name .. "' successfully builded and deployed to '" .. deploy_dir .. "'."
end

-- Deploy binary package from 'pkg_dir' to 'deploy_dir' by copying.
function deploy_binary_pkg(pkg_dir, deploy_dir)
    deploy_dir = deploy_dir or cfg.root_dir

    assert(type(pkg_dir) == "string", "package.deploy_binary_pkg: Argument 'pkg_dir' is not a string.")
    assert(type(deploy_dir) == "string", "package.deploy_binary_pkg: Argument 'deploy_dir' is not a string.")

    pkg_dir = sys.abs_path(pkg_dir)
    deploy_dir = sys.abs_path(deploy_dir)

    -- check for dist.info
    local info, err = mf.load_distinfo(sys.make_path(pkg_dir, "dist.info"))
    if not info then return nil, "Error deploying package from '" .. pkg_dir .. "': it doesn't contain valid 'dist.info' file." end
    local pkg_name = info.name .. "-" .. info.version

    -- if this is only simulation, exit sucessfully, skipping the next actions
    if cfg.simulate then
        return true, "Simulated deployment of package '" .. pkg_name .. "' sucessfull."
    end

    -- copy all components of the module to the deploy_dir
    for _, component in ipairs(cfg.components) do
        if info.files[component] then
            for _, file in ipairs(info.files[component]) do
                local dest_dir = sys.make_path(deploy_dir, sys.parent_dir(file))

                local ok, err = sys.make_dir(dest_dir)
                if not ok then return nil, "Error when deploying package '" .. pkg_name .. "': cannot create directory '" .. dest_dir .. "': " .. err end

                ok, err = sys.copy(sys.make_path(pkg_dir, file), dest_dir)
                if not ok then return nil, "Error when deploying package '" .. pkg_name .. "': cannot copy file '" .. file .. "' to the directory '" .. dest_dir .. "': " .. err end
            end
        end
    end

    -- copy dist.info to register the module as installed
    local pkg_distinfo_dir = sys.make_path(deploy_dir, cfg.distinfos_dir, pkg_name)
    sys.make_dir(pkg_distinfo_dir)
    ok, err = mf.save_distinfo(info, sys.make_path(pkg_distinfo_dir, "dist.info"))
    if not ok then return nil, err end

    return true, "Package '" .. pkg_name .. "' successfully deployed to '" .. deploy_dir .. "'."
end

-- Fetch package (table 'pkg') to download_dir. Return path to the directory of
-- downloaded package on success or an error message on error.
function fetch_pkg(pkg, download_dir)
    download_dir = download_dir or sys.current_dir()
    assert(type(pkg) == "table", "package.fetch_pkg: Argument 'pkg' is not a table.")
    assert(type(download_dir) == "string", "package.fetch_pkg: Argument 'download_dir' is not a string.")
    assert(type(pkg.name) == "string", "package.fetch_pkg: Argument 'pkg.name' is not a string.")
    assert(type(pkg.version) == "string", "package.fetch_pkg: Argument 'pkg.version' is not a string.")
    assert(type(pkg.path) == "string", "package.fetch_pkg: Argument 'pkg.path' is not a string.")
    download_dir = sys.abs_path(download_dir)

    local pkg_full_name = pkg.name .. "-" .. pkg.version
    local repo_url = pkg.path
    local clone_dir = sys.abs_path(sys.make_path(download_dir, pkg_full_name))

    -- check if download_dir already exists, assuming the package was already downloaded
    if sys.exists(sys.make_path(clone_dir, "dist.info")) then
        if cfg.cache and not utils.cache_timeout_expired(cfg.cache_timeout, clone_dir) then
            print("'" .. pkg_full_name .. "' already in cache, skipping downloading (use '-cache=false' to force download).")
            return clone_dir
        else
            sys.delete(sys.make_path(clone_dir))
        end
    end

    local bin_tag = pkg.version .. "-" .. cfg.arch .. "-" .. cfg.type
    local use_binary = false

    if cfg.binary then
        -- check if binary version of the module for this arch & type available
        local avail_tags, err = git.get_remote_tags(repo_url)
        if not avail_tags then return nil, err end

        if utils.contains(avail_tags, bin_tag) then
            use_binary = true
        end
    end

    -- init the git repository
    local ok, err = git.create_repo(clone_dir)
    if not ok then return nil, err end

    -- Fetch the desired ref (from the pkg's remote repo) and checkout into it.

    if use_binary then

        print("Getting " .. pkg_full_name .. " (binary)...")

        -- We fetch the binary tag.
        local sha
        if ok then sha, err = git.fetch_tag(clone_dir, repo_url, bin_tag) end
        if sha then ok, err = git.checkout_sha(sha, clone_dir) end

    elseif cfg.source then

        print("Getting " .. pkg_full_name .. " (source)...")

        -- If we want the 'scm' version, we fetch the 'master' branch, otherwise
        -- we fetch the tag, matching the desired package version.
        if ok and pkg.version ~= "scm" then
            local sha
            sha, err = git.fetch_tag(clone_dir, repo_url, pkg.version)
            if sha then ok, err = git.checkout_sha(sha, clone_dir) end
        elseif ok then
            local sha
            sha, err = git.fetch_branch(clone_dir, repo_url, "master")
            if sha then ok, err = git.checkout_sha(sha, clone_dir) end
        end

    else
        ok = false
        if cfg.binary then
            err = "Binary version of module not available and using source modules disabled."
        else
            err = "Using both binary and source modules disabled."
        end
    end

    if not ok then
        -- clean up
        if not cfg.debug then sys.delete(clone_dir) end
        return nil, "Error fetching package '" .. pkg_full_name .. "' from '" .. pkg.path .. "' to '" .. download_dir .. "': " .. err
    end

    -- delete '.git' directory
    if not cfg.debug then sys.delete(sys.make_path(clone_dir, ".git")) end

    return clone_dir
end

-- Fetch packages (table 'packages') to 'download_dir'. Return table of paths
-- to the directories on success or an error message on error.
function fetch_pkgs(packages, download_dir)
    download_dir = download_dir or sys.current_dir()
    assert(type(packages) == "table", "package.fetch_pkgs: Argument 'packages' is not a table.")
    assert(type(download_dir) == "string", "package.fetch_pkgs: Argument 'download_dir' is not a string.")
    download_dir = sys.abs_path(download_dir)

    local fetched_dirs = {}
    local dir, err

    for _, pkg in pairs(packages) do
        -- if package was downloaded by dependency resolving function, do not download it again.
        if pkg.download_dir then
            dir, err = pkg.download_dir, nil
        -- else download it.
        else
            dir, err = fetch_pkg(pkg, download_dir)
        end
        if not dir then
            return nil, err
        else
            table.insert(fetched_dirs, dir)
        end
    end

    return fetched_dirs
end

-- Return table with information about available versions of 'package'.
function retrieve_versions(package, manifest)
    assert(type(package) == "string", "package.retrieve_versions: Argument 'string' is not a string.")
    assert(type(manifest) == "table", "package.retrieve_versions: Argument 'manifest' is not a table.")

    -- get package table
    local pkg_name = depends.split_name_constraint(package)
    local tmp_packages = depends.find_packages(pkg_name, manifest)

    if #tmp_packages == 0 then
        return nil, "No suitable candidate for package '" .. package .. "' found."
    else
        package = tmp_packages[1]
    end

    print("Finding out available versions of " .. package.name .. "...")

    -- get available versions
    local tags, err = git.get_remote_tags(package.path)
    if not tags then return nil, "Error when retrieving versions of package '" .. package.name .. "': " .. err end

    -- filter out tags of binary packages
    local versions = utils.filter(tags, function (tag) return tag:match("^[^%-]+%-?[^%-]*$") and true end)

    packages = {}

    -- create package information
    for _, version in pairs(versions) do
        pkg = {}
        pkg.name = package.name
        pkg.version = version
        pkg.path = package.path
        table.insert(packages, pkg)
    end

    return packages
end

-- Return table with information from package's dist.info and path to downloaded
-- package. Optional argument 'deploy_dir' is used just as a temporary
-- place to place the downloaded packages into.
function retrieve_pkg_info(package, deploy_dir)
    deploy_dir = deploy_dir or cfg.root_dir
    assert(type(package) == "table", "package.retrieve_pkg_info: Argument 'package' is not a table.")
    assert(type(deploy_dir) == "string", "package.retrieve_pkg_info: Argument 'deploy_dir' is not a string.")
    deploy_dir = sys.abs_path(deploy_dir)

    local tmp_dir = sys.abs_path(sys.make_path(deploy_dir, cfg.temp_dir))

    -- download the package
    local pkg_dir, err = fetch_pkg(package, tmp_dir)
    if not pkg_dir then return nil, "Error when retrieving the info about '" .. package.name .. "': " .. err end

    -- load information from 'dist.info'
    local info, err = mf.load_distinfo(sys.make_path(pkg_dir, "dist.info"))
    if not info then return nil, err end

    -- add 'path' attribute
    if package.path then info.path = package.path end

    -- set default arch/type if not explicitly stated and package is of source type
    if sys.exists(sys.make_path(pkg_dir, "CMakeLists.txt")) then
        info.arch = info.arch or "Universal"
        info.type = info.type or "source"
    elseif not (info.arch and info.type) then
        return nil, pkg_dir .. ": binary package missing arch or type in 'dist.info'."
    end

    return info, pkg_dir
end

-- Return manifest, augmented with info about all available versions
-- of package 'pkg'. Optional argument 'deploy_dir' is used just as a temporary
-- place to place the downloaded packages into.
-- Optional argument 'installed' is manifest of all installed packages. When
-- specified, info from installed packages won't be downloaded from repo,
-- but the dist.info from installed package will be used.
function get_versions_info(pkg, manifest, deploy_dir, installed)
    deploy_dir = deploy_dir or cfg.root_dir
    assert(type(pkg) == "string", "package.get_versions_info: Argument 'pkg' is not a string.")
    assert(type(manifest) == "table", "package.get_versions_info: Argument 'manifest' is not a table.")
    assert(type(deploy_dir) == "string", "package.get_versions_info: Argument 'deploy_dir' is not a string.")
    deploy_dir = sys.abs_path(deploy_dir)

    -- find all available versions of package
    local versions, err = retrieve_versions(pkg, manifest)
    if not versions then return nil, err end

    -- collect info about all retrieved versions
    local infos = {}
    for _, version in pairs(versions) do

        local info, path_or_err
        local installed_version = {}

        -- find out whether this 'version' is installed so we can use it's dist.info
        if type(installed) == "table" then installed_version = depends.find_packages(version.name .. "-" .. version.version, installed) end

        -- get info
        if #installed_version > 0 then
            print("Using dist.info from installed " .. version.name .. "-" .. version.version)
            info = installed_version[1]
            info.path = version.path
            info.from_installed = true  -- flag that dist.info of installed package was used
        else
            info, path_or_err = retrieve_pkg_info(version, deploy_dir)
            if not info then return nil, path_or_err end
            sys.delete(path_or_err)
        end
        table.insert(infos, info)
    end

    -- found and add an implicit 'scm' version
    local pkg_name = depends.split_name_constraint(pkg)
    local found = depends.find_packages(pkg_name, manifest)
    if #found == 0 then return nil, "No suitable candidate for package '" .. pkg .. "' found." end
    local scm_info, path_or_err = retrieve_pkg_info({name = pkg_name, version = "scm", path = found[1].path})
    if not scm_info then return nil, path_or_err end
    sys.delete(path_or_err)
    scm_info.version = "scm"
    table.insert(infos, scm_info)

    local tmp_manifest = utils.deepcopy(manifest)

    -- add collected info to the temp. manifest, replacing existing tables
    for _, info in pairs(infos) do
        local already_in_manifest = false
        -- find if this version is already in manifest
        for idx, pkg in ipairs(tmp_manifest) do
            -- if yes, replace it
            if pkg.name == info.name and pkg.version == info.version then
                tmp_manifest[idx] = info
                already_in_manifest = true
                break
            end
        end
        -- if not, just normally add to the manifest
        if not already_in_manifest then
            table.insert(tmp_manifest, info)
        end
    end

    return tmp_manifest
end

local utils = require "nvim-tree.utils"
local builders = require "nvim-tree.explorer.node-builders"
local explorer_node = require "nvim-tree.explorer.node"
local git = require "nvim-tree.git"
local log = require "nvim-tree.log"

local FILTER_REASON = require("nvim-tree.enum").FILTER_REASON
local NodeIterator = require "nvim-tree.iterators.node-iterator"
local Watcher = require "nvim-tree.watcher"

local M = {}

---@param nodes_by_path table
---@param node_ignored boolean
---@param status table
---@return fun(node: Node): table
local function update_status(nodes_by_path, node_ignored, status)
  return function(node)
    if nodes_by_path[node.absolute_path] then
      explorer_node.update_git_status(node, node_ignored, status)
    end
    return node
  end
end

---@param path string
---@param callback fun(toplevel: string|nil, project: table|nil)
local function reload_and_get_git_project(path, callback)
  local toplevel = git.get_toplevel(path)

  git.reload_project(toplevel, path, function()
    callback(toplevel, git.get_project(toplevel) or {})
  end)
end

---@param node Node
---@param project table|nil
---@param root string|nil
local function update_parent_statuses(node, project, root)
  while project and node do
    -- step up to the containing project
    if node.absolute_path == root then
      -- stop at the top of the tree
      if not node.parent then
        break
      end

      root = git.get_toplevel(node.parent.absolute_path)

      -- stop when no more projects
      if not root then
        break
      end

      -- update the containing project
      project = git.get_project(root)
      git.reload_project(root, node.absolute_path, nil)
    end

    -- update status
    explorer_node.update_git_status(node, explorer_node.is_git_ignored(node.parent), project)

    -- maybe parent
    node = node.parent
  end
end

---@param node Node
---@param git_status table
function M.reload(node, git_status)
  local explorer = require("nvim-tree.core").get_explorer()
  if not explorer then
    return
  end
  local cwd = node.link_to or node.absolute_path
  local handle = vim.loop.fs_scandir(cwd)
  if not handle then
    return
  end

  local profile = log.profile_start("reload %s", node.absolute_path)

  local filter_status = explorer.filters:prepare(git_status)

  if node.group_next then
    node.nodes = { node.group_next }
    node.group_next = nil
  end

  local remain_childs = {}

  local node_ignored = explorer_node.is_git_ignored(node)
  ---@type table<string, Node>
  local nodes_by_path = utils.key_by(node.nodes, "absolute_path")

  -- To reset we must 'zero' everything that we use
  node.hidden_stats = vim.tbl_deep_extend("force", node.hidden_stats or {}, {
    git = 0,
    buf = 0,
    dotfile = 0,
    custom = 0,
    bookmark = 0,
  })

  while true do
    local name, t = vim.loop.fs_scandir_next(handle)
    if not name then
      break
    end

    local abs = utils.path_join { cwd, name }
    ---@type uv.fs_stat.result|nil
    local stat = vim.loop.fs_stat(abs)

    local filter_reason = explorer.filters:should_filter_as_reason(abs, stat, filter_status)
    if filter_reason == FILTER_REASON.none then
      remain_childs[abs] = true

      -- Recreate node if type changes.
      if nodes_by_path[abs] then
        local n = nodes_by_path[abs]

        if n.type ~= t then
          utils.array_remove(node.nodes, n)
          explorer_node.node_destroy(n)
          nodes_by_path[abs] = nil
        end
      end

      if not nodes_by_path[abs] then
        local new_child = nil
        if t == "directory" and vim.loop.fs_access(abs, "R") and Watcher.is_fs_event_capable(abs) then
          new_child = builders.folder(node, abs, name, stat)
        elseif t == "file" then
          new_child = builders.file(node, abs, name, stat)
        elseif t == "link" then
          local link = builders.link(node, abs, name, stat)
          if link.link_to ~= nil then
            new_child = link
          end
        end
        if new_child then
          table.insert(node.nodes, new_child)
          nodes_by_path[abs] = new_child
        end
      else
        local n = nodes_by_path[abs]
        if n then
          n.executable = builders.is_executable(abs) or false
          n.fs_stat = stat
        end
      end
    else
      for reason, value in pairs(FILTER_REASON) do
        if filter_reason == value then
          node.hidden_stats[reason] = node.hidden_stats[reason] + 1
        end
      end
    end
  end

  node.nodes = vim.tbl_map(
    update_status(nodes_by_path, node_ignored, git_status),
    vim.tbl_filter(function(n)
      if remain_childs[n.absolute_path] then
        return remain_childs[n.absolute_path]
      else
        explorer_node.node_destroy(n)
        return false
      end
    end, node.nodes)
  )

  local is_root = not node.parent
  local child_folder_only = explorer_node.has_one_child_folder(node) and node.nodes[1]
  if M.config.group_empty and not is_root and child_folder_only then
    node.group_next = child_folder_only
    local ns = M.reload(child_folder_only, git_status)
    node.nodes = ns or {}
    log.profile_end(profile)
    return ns
  end

  explorer.sorters:sort(node.nodes)
  explorer.live_filter:apply_filter(node)
  log.profile_end(profile)
  return node.nodes
end

---Refresh contents and git status for a single node
---@param node Node
---@param callback function
function M.refresh_node(node, callback)
  if type(node) ~= "table" then
    callback()
  end

  local parent_node = utils.get_parent_of_group(node)

  reload_and_get_git_project(node.absolute_path, function(toplevel, project)
    require("nvim-tree.explorer.reload").reload(parent_node, project)

    update_parent_statuses(parent_node, project, toplevel)

    callback()
  end)
end

---Refresh contents of all nodes to a path: actual directory and links.
---Groups will be expanded if needed.
---@param path string absolute path
function M.refresh_parent_nodes_for_path(path)
  local explorer = require("nvim-tree.core").get_explorer()
  if not explorer then
    return
  end

  local profile = log.profile_start("refresh_parent_nodes_for_path %s", path)

  -- collect parent nodes from the top down
  local parent_nodes = {}
  NodeIterator.builder({ explorer })
    :recursor(function(node)
      return node.nodes
    end)
    :applier(function(node)
      local abs_contains = node.absolute_path and path:find(node.absolute_path, 1, true) == 1
      local link_contains = node.link_to and path:find(node.link_to, 1, true) == 1
      if abs_contains or link_contains then
        table.insert(parent_nodes, node)
      end
    end)
    :iterate()

  -- refresh in order; this will expand groups as needed
  for _, node in ipairs(parent_nodes) do
    local toplevel = git.get_toplevel(node.absolute_path)
    local project = git.get_project(toplevel) or {}

    M.reload(node, project)
    update_parent_statuses(node, project, toplevel)
  end

  log.profile_end(profile)
end

function M.setup(opts)
  M.config = opts.renderer
end

return M

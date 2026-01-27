local ce = require("compiler-explorer.lazy")

local api = vim.api

local M = {}

local function ensure_info(bufnr)
  local info = ce.clientstate.get_info_by_opt_pipeline(bufnr)
  if not info then
    ce.alert.warn("No opt pipeline data for this buffer.")
    return nil
  end
  return info
end

-- read results from buffer local var
local function get_results(info)
  local ok, results =
    pcall(api.nvim_buf_get_var, info.opt_pipeline.bufnr, "ce_opt_pipeline_results")
  if not ok then
    ce.alert.error("Failed to get opt pipeline results.")
    return nil
  end
  return results
end

local function get_pass_index_by_name(passes, pass_name)
  for i, pass in ipairs(passes) do
    if pass.name == pass_name then return i end
  end
  return nil
end

local function render(bufnr, info, results, opts)
  -- Determine selected group
  local selected_group = opts.selected_group or info.opt_pipeline.selected_group
  local passes = results[selected_group]

  local selected_pass = opts.selected_pass or info.opt_pipeline.selected_pass
  local pass_index = get_pass_index_by_name(passes, selected_pass)
  local pass = passes[pass_index]

  local conf = ce.config.get_config()
  local view = conf.opt_pipeline_view or "after"
  local source = view == "before" and pass.before or pass.after
  local lines = vim.tbl_map(function(line) return line.text end, source or {})

  ce.util.write_output_buf(bufnr, lines, {
    new_buf_name = string.format(
      "compiler-explorer://%s-%s-opt-pipeline (%s)",
      info.compiler_id,
      info.asm_bufnr,
      selected_pass
    ),
  })
  info.opt_pipeline = {
    bufnr = bufnr,
    selected_group = selected_group,
    selected_pass = selected_pass,
  }

  if pass then
    ce.alert.info("Opt pipeline %s / %s (%s)", selected_group, selected_pass, view)
  else
    ce.alert.warn("Opt pipeline has no passes to display.")
  end
end

function M.setup_buffer(bufnr)
  local ok, ready = pcall(api.nvim_buf_get_var, bufnr, "ce_opt_pipeline_ready")
  if ok and ready then return end

  api.nvim_buf_set_var(bufnr, "ce_opt_pipeline_ready", true)

  api.nvim_buf_create_user_command(bufnr, "CEOptPipelineNextPass", function() M.next_pass() end, {})
  api.nvim_buf_create_user_command(bufnr, "CEOptPipelinePrevPass", function() M.prev_pass() end, {})
  api.nvim_buf_create_user_command(
    bufnr,
    "CEOptPipelineSelectPass",
    function() M.select_pass() end,
    {}
  )
  api.nvim_buf_create_user_command(
    bufnr,
    "CEOptPipelineSelectGroup",
    function() M.select_group() end,
    {}
  )

  vim.keymap.set("n", "]p", M.next_pass, { buffer = bufnr, desc = "CE opt pipeline next pass" })
  vim.keymap.set("n", "[p", M.prev_pass, { buffer = bufnr, desc = "CE opt pipeline previous pass" })
  vim.keymap.set("n", "gp", M.select_pass, { buffer = bufnr, desc = "CE opt pipeline select pass" })
  vim.keymap.set(
    "n",
    "gP",
    M.select_group,
    { buffer = bufnr, desc = "CE opt pipeline select group" }
  )
end

function M.set_results(bufnr, info, results)
  pcall(api.nvim_buf_set_var, bufnr, "ce_opt_pipeline_results", results)

  local selected_group = info.opt_pipeline.selected_group
  local groups = vim.tbl_keys(results)
  if #groups == 0 then
    ce.alert.error("No opt pipeline groups available.")
    ce.util.write_output_buf(bufnr, {})
    return
  end
  if not selected_group or selected_group == "" then selected_group = groups[1] end

  local passes = results[selected_group]
  if not passes then
    ce.alert.warn(
      "Opt pipeline group not found: " .. selected_group .. ". Defaulting to first available group."
    )
    selected_group = groups[1]
  end
  if #passes == 0 then
    ce.alert.error("Opt pipeline group has no passes: " .. selected_group)
    return
  end

  local selected_pass = info.opt_pipeline.selected_pass
  if not selected_pass or selected_pass == "" then selected_pass = passes[1].name end

  local pass_index = get_pass_index_by_name(passes, selected_pass) or 1
  local pass = passes[pass_index]
  if not pass then
    ce.alert.warn("Opt pipeline pass not found: " .. selected_pass .. ". Defaulting to first pass.")
    selected_pass = passes[1].name
  end

  render(bufnr, info, results, {
    selected_group = selected_group,
    selected_pass = selected_pass,
  })
end

local function prev_or_next_pass(bufnr, direction)
  local info = ensure_info(bufnr)
  if not info then return end

  local results = get_results(info)
  if not results then return end

  local passes = results[info.opt_pipeline.selected_group] or {}
  local pass_index = get_pass_index_by_name(passes, info.opt_pipeline.selected_pass)
  if not pass_index then
    ce.alert.error("Current opt pipeline pass not found.")
    return
  end

  pass_index = pass_index + direction
  if pass_index < 1 then
    ce.alert.warn("Already at the first opt pipeline pass.")
    return
  elseif pass_index > #passes then
    ce.alert.warn("Already at the last opt pipeline pass.")
    return
  end

  render(bufnr, info, results, {
    selected_pass = passes[pass_index].name,
  })
end

function M.next_pass()
  local bufnr = api.nvim_get_current_buf()
  prev_or_next_pass(bufnr, 1)
end

function M.prev_pass()
  local bufnr = api.nvim_get_current_buf()
  prev_or_next_pass(bufnr, -1)
end

M.select_pass = ce.async.void(function()
  local bufnr = api.nvim_get_current_buf()
  local info = ensure_info(bufnr)
  if not info then return end

  local results = get_results(info)
  if not results then return end

  local passes = results[info.opt_pipeline.selected_group] or {}
  if #passes == 0 then
    ce.alert.error("No opt pipeline passes to select.")
    return
  end

  local items = {}
  for i, pass in ipairs(passes) do
    table.insert(items, {
      index = i,
      name = pass.name,
      irChanged = pass.irChanged,
    })
  end

  local choice = ce.util.prompt_select(items, {
    prompt = "Select opt pass> ",
    format_item = function(item)
      local prefix = item.irChanged and "* " or ""
      return string.format("%s%s", prefix, item.name)
    end,
  })
  if not choice then return end

  local selected_pass = choice.name
  render(bufnr, info, results, {
    selected_pass = selected_pass,
  })
end)

M.select_group = ce.async.void(function()
  local bufnr = api.nvim_get_current_buf()
  local info = ensure_info(bufnr)
  if not info then return end

  local results = get_results(info)
  if not results then return end

  local groups = vim.tbl_keys(results)
  if #groups == 0 then
    ce.alert.warn("No opt pipeline groups to select.")
    return
  end

  local choice = ce.util.prompt_select(groups, {
    prompt = "Select opt group> ",
    format_item = function(item) return item end,
  })
  if not choice then return end

  local selected_group = choice
  render(bufnr, info, results, {
    selected_group = selected_group,
  })
end)

return M

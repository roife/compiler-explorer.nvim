local api, fn = vim.api, vim.fn

local M = {}

M.state = {}

local function build_sessions()
  local sessions = {}
  local id = 1
  for source_bufnr, asm_data in pairs(M.state) do
    if api.nvim_buf_is_loaded(source_bufnr) then
      local compilers = {}
      for asm_bufnr, data in pairs(asm_data) do
        if api.nvim_buf_is_loaded(asm_bufnr) then table.insert(compilers, data) end
      end

      local lines = api.nvim_buf_get_lines(source_bufnr, 0, -1, false)
      local source = table.concat(lines, "\n")

      table.insert(sessions, {
        language = compilers[1].lang,
        id = id,
        source = source,
        compilers = compilers,
      })
      id = id + 1
    end
  end

  if vim.tbl_isempty(sessions) then return nil end
  return sessions
end

M.build_sessions = function() return build_sessions() end

M.create = function()
  local sessions = build_sessions()
  if sessions == nil then return nil end

  return vim.base64.encode(vim.json.encode { sessions = sessions })
end

M.save_info = function(source_bufnr, body, opts)
  local asm_bufnr = opts.asm_bufnr
  M.state[source_bufnr] = M.state[source_bufnr] or {}

  M.state[source_bufnr][asm_bufnr] = {
    lang = body.lang,
    compiler_id = body.compiler.id,
    options = body.options.userArguments,
    filters = body.options.filters,
    libs = vim.tbl_map(
      function(lib) return { name = lib.id, ver = lib.version } end,
      body.options.libraries
    ),
    range = opts.range,
    asm_bufnr = asm_bufnr,
    ir_bufnr = opts.ir_bufnr,
    opt_pipeline = opts.opt_pipeline,
  }
end

M.get_info_by_asm = function(asm_bufnr)
  for source_bufnr, asm_data in pairs(M.state) do
    if asm_data[asm_bufnr] then return source_bufnr, asm_data[asm_bufnr] end
  end
  return nil, nil
end

M.get_info_by_opt_pipeline = function(opt_pipeline_bufnr)
  for _, asm_data in pairs(M.state) do
    for _, data in pairs(asm_data) do
      if data.opt_pipeline and data.opt_pipeline.bufnr == opt_pipeline_bufnr then return data end
    end
  end
  return nil
end

M.get_last_asm_bufwin = function(source_bufnr)
  for _, asm_bufnr in ipairs(vim.tbl_keys(M.state[source_bufnr] or {})) do
    local winid = fn.bufwinid(asm_bufnr)
    if winid ~= -1 then return asm_bufnr, winid end
  end
  return nil, nil
end

return M

local api, fn = vim.api, vim.fn

local M = {}

M.state = {}

M.create = function()
  local sessions = {}
  local id = 1
  for source_bufnr, asm_data in pairs(M.state) do
    if api.nvim_buf_is_loaded(source_bufnr) then
      local compilers = {}
      for asm_bufnr, data in pairs(asm_data) do
        if api.nvim_buf_is_loaded(asm_bufnr) then
          table.insert(compilers, data)
        end
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

  return vim.base64.encode(vim.json.encode({ sessions = sessions }))
end

M.ASM_NAME = "asm"
M.IR_NAME = "ir"

M.save_info = function(source_bufnr, asm_bufnr, body, opts)
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
    ir_bufnr = opts.ir_bufnr,
  }
end

M.get_info_by_asm = function(asm_bufnr)
  for source_bufnr, asm_data in pairs(M.state) do
    if asm_data[asm_bufnr] then
      return source_bufnr, asm_data[asm_bufnr]
    end
  end
  return nil, nil
end

M.get_last_asm_bufwin = function(source_bufnr)
  for _, asm_bufnr in ipairs(vim.tbl_keys(M.state[source_bufnr] or {})) do
    local winid = fn.bufwinid(asm_bufnr)
    if winid ~= -1 then return asm_bufnr, winid end
  end
  return nil, nil
end

return M

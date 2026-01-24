local ce = require("compiler-explorer.lazy")

local uv = vim.loop
local api = vim.api
local fn = vim.fn

local M = {}

local function smart_split(conf)
  if conf.split ~= "auto" then
    vim.cmd(conf.split)
  elseif vim.o.columns > vim.o.lines * 2 then
    vim.cmd("vsplit")
  else
    vim.cmd("split")
  end
end

function M.create_ir_window(bufnr, compiler_id, filetype)
  local conf = ce.config.get_config()

  if bufnr == nil then
    bufnr = api.nvim_create_buf(false, true)

    local buf_name = "compiler-explorer://" .. compiler_id .. filetype .. "-" .. math.random(100)
    api.nvim_buf_set_name(bufnr, buf_name)

    api.nvim_set_option_value("ft", filetype, { buf = bufnr })
    api.nvim_set_option_value("bufhidden", "wipe", { buf = bufnr })
  end

  local winid = fn.bufwinid(bufnr)

  if winid == -1 then
    smart_split(conf)
    winid = api.nvim_get_current_win()
  end

  api.nvim_set_current_win(winid)
  local win = api.nvim_get_current_win()
  api.nvim_win_set_buf(win, bufnr)

  return bufnr
end

-- Creates a new buffer and window or uses the previous one.
function M.create_window_buffer(bufnr, compiler_id, new_buffer, filetype)
  local conf = ce.config.get_config()

  local asm_bufnr, winid = ce.clientstate.get_last_asm_bufwin(bufnr)

  if asm_bufnr == nil or new_buffer then
    asm_bufnr = api.nvim_create_buf(false, true)

    local buf_name = "compiler-explorer://"
      .. compiler_id
      .. "-"
      .. filetype
      .. "-"
      .. math.random(100)
    api.nvim_buf_set_name(asm_bufnr, buf_name)

    api.nvim_set_option_value("ft", filetype, { buf = asm_bufnr })
    api.nvim_set_option_value("bufhidden", "wipe", { buf = asm_bufnr })
  end

  if winid == nil or new_buffer then
    smart_split(conf)
    winid = api.nvim_get_current_win()
  end

  api.nvim_set_current_win(winid)
  local win = api.nvim_get_current_win()
  api.nvim_win_set_buf(win, asm_bufnr)

  return asm_bufnr
end

function M.set_binary_extmarks(lines, bufnr)
  local ns = api.nvim_create_namespace("ce-binary")

  for i, line in ipairs(lines) do
    if line.address ~= nil then
      local address = string.format("%x", line.address)
      local opcodes = " " .. table.concat(line.opcodes, " ")

      api.nvim_buf_set_extmark(bufnr, ns, i - 1, 0, {
        virt_lines_above = true,
        virt_lines = { { { opcodes, "Comment" } } },
        virt_text = { { address, "Comment" } },
      })
    end
  end
end

local function to_bool(s)
  if s == "true" then
    return true
  elseif s == "false" then
    return false
  else
    return s
  end
end

function M.parse_args(fargs)
  local conf = ce.config.get_config()
  local args = {}
  args.inferLang = conf.infer_lang

  for _, f in ipairs(fargs) do
    local arg, value = f:match("^(.-)=(.*)$")
    if arg == nil or value == nil then
      ::continue::
    end
    args[arg] = to_bool(value)
  end

  return args
end

local frames = { "⣼", "⣹", "⢻", "⠿", "⡟", "⣏", "⣧", "⣶" }
local interval = 100

function M.start_spinner(text)
  if M.spinner == nil then M.spinner = { count = 0, timer = nil } end

  M.spinner.count = M.spinner.count + 1
  if M.spinner.timer ~= nil and not M.spinner.timer:is_closing() then return end

  local i = 1
  M.spinner.timer = uv.new_timer()
  M.spinner.timer:start(0, interval, function()
    i = (i == #frames) and 1 or (i + 1)
    local msg = text .. " " .. frames[i]
    vim.schedule(function() api.nvim_echo({ { msg, "None" } }, false, {}) end)
  end)
end

function M.stop_spinner()
  if M.spinner == nil or M.spinner.timer == nil then return end

  if M.spinner.count > 0 then M.spinner.count = M.spinner.count - 1 end
  if M.spinner.count > 0 then return end

  api.nvim_echo({ { "", "None" } }, false, {})
  if not M.spinner.timer:is_closing() then
    M.spinner.timer:stop()
    M.spinner.timer:close()
  end
end

return M

local ce = require("compiler-explorer.lazy")

local api, fn = vim.api, vim.fn

local M = {}

-- Return a function to avoid caching the vim.ui functions
local get_select = function() return ce.async.wrap(vim.ui.select, 3) end
local get_input = function() return ce.async.wrap(vim.ui.input, 2) end

local group = api.nvim_create_augroup("CompilerExplorerLive", { clear = true })

M.setup = function(user_config) ce.config.setup(user_config or {}) end

local function get_buf_contents(source_bufnr, range)
  local lines = api.nvim_buf_get_lines(source_bufnr, range.line1 - 1, range.line2, false)
  return table.concat(lines, "\n")
end

local function ensure_compiler_selection(args)
  -- Get compiler from args
  local ok, compiler = pcall(ce.rest.check_compiler, args.compiler)
  if not ok then
    ce.alert.error("Could not compile code with compiler id %s", args.compiler)
    return nil
  elseif compiler then
    return compiler
  end

  local conf = ce.config.get_config()
  local vim_select = get_select()
  local vim_input = get_input()

  -- Get compiler from user input
  local lang_list = ce.rest.languages_get()
  local possible_langs = lang_list

  -- Infer language based on extension and prompt user.
  if args.inferLang then
    local extension = "." .. fn.expand("%:e")

    possible_langs = vim.tbl_filter(
      function(el) return vim.tbl_contains(el.extensions, extension) end,
      lang_list
    )

    if vim.tbl_isempty(possible_langs) then
      ce.alert.error("File extension %s not supported by compiler-explorer", extension)
      return nil
    end
  end

  local lang = #possible_langs == 1 and possible_langs[1]
    or vim.select(possible_langs, {
      prompt = "Select language> ",
      format_item = function(item) return item.name end,
    })

  if not lang then return nil end
  vim.cmd("redraw")

  -- Extend config with config specific to the language
  local lang_conf = conf.languages[lang.id]
  if lang_conf then conf = vim.tbl_deep_extend("force", conf, lang_conf) end

  if conf.compiler then
    ok, compiler = pcall(ce.rest.check_compiler, conf.compiler)
    if not ok then ce.alert.error("Could not compile code with compiler id %s", conf.compiler) end
  else
    local compilers = ce.rest.compilers_get(lang.id)
    compiler = vim_select(compilers, {
      prompt = "Select compiler> ",
      format_item = function(item) return item.name end,
    })

    if not compiler then return nil end
    vim.cmd("redraw")
  end

  -- Choose compiler options
  args.flags = vim_input {
    prompt = "Select compiler options> ",
    default = conf.compiler_flags,
  }
  vim.cmd("redraw")

  return compiler
end

local function write_output_buf(bufnr, lines)
  api.nvim_buf_clear_namespace(bufnr, -1, 0, -1)
  api.nvim_set_option_value("modifiable", true, { buf = bufnr })
  api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  api.nvim_set_option_value("modifiable", false, { buf = bufnr })
end

M.compile = ce.async.void(function(opts, live)
  local args = ce.util.parse_args(opts.fargs)

  local source_bufnr, source_winid = api.nvim_get_current_buf(), api.nvim_get_current_win()

  -- Ensure compiler
  local compiler = ensure_compiler_selection(args)
  if compiler == nil then return end

  -- Prepare args
  args.compiler = compiler
  args.lang = compiler.lang
  args.source = get_buf_contents(source_bufnr, opts)

  ce.async.scheduler()

  -- Compile
  local body = ce.rest.create_compile_body(args)
  local ok, response = pcall(ce.rest.compile_post, compiler.id, body)
  if not ok then ce.alert.error(response) end
  if response.code == 0 then
    ce.alert.info("Compilation done with %s compiler.", compiler.name)
  else
    ce.alert.error("Could not compile code with %s", compiler.name)
  end

  -- Write output to buffer
  local asm_bufnr = opts.reuse_bufnr
    or ce.util.create_window_buffer(source_bufnr, compiler.id, opts.bang, "asm")
  local asm_lines = vim.tbl_map(function(line) return line.text end, response.asm)
  write_output_buf(asm_bufnr, asm_lines)
  if args.binary then ce.util.set_binary_extmarks(response.asm, asm_bufnr) end

  -- Update LLVM IR if needed
  local _, info = ce.clientstate.get_info_by_asm(asm_bufnr)
  local ir_bufnr = info and info.ir_bufnr or nil
  if ir_bufnr then M.compile_llvm_ir { asm_bufnr = asm_bufnr } end

  ce.clientstate.save_info(source_bufnr, asm_bufnr, body, {
    range = { line1 = opts.line1, line2 = opts.line2 },
    ir_bufnr = ir_bufnr,
  })

  -- Create autocmd for live compilation
  if live and not opts.reuse_bufnr then
    api.nvim_create_autocmd({ "BufWritePost" }, {
      group = group,
      buffer = source_bufnr,
      callback = function()
        M.compile({
          line1 = 1,
          line2 = fn.line("$"),
          fargs = {
            "compiler=" .. args.compiler.id,
            "flags=" .. (args.flags or ""),
          },
          reuse_bufnr = asm_bufnr,
        }, false)
      end,
    })
  end

  -- Return to source window
  api.nvim_set_current_win(source_winid)
  ce.stderr.add_diagnostics(response.stderr, source_bufnr, opts.line1 - 1)

  if not args.binary then
    ce.autocmd.init_line_match(source_bufnr, asm_bufnr, response.asm, opts.line1 - 1)
  end

  api.nvim_buf_set_var(asm_bufnr, "arch", compiler.instructionSet) -- used by show_tooltips
  api.nvim_buf_set_var(asm_bufnr, "labels", response.labelDefinitions) -- used by goto_label
  api.nvim_buf_create_user_command(asm_bufnr, "CEShowTooltip", M.show_tooltip, {})
  api.nvim_buf_create_user_command(asm_bufnr, "CEGotoLabel", M.goto_label, {})
end)

M.compile_llvm_ir = ce.async.void(function(opts)
  local asm_bufnr = opts.asm_bufnr or api.nvim_get_current_buf()

  local source_bufnr, info = ce.clientstate.get_info_by_asm(asm_bufnr)
  if info == nil then
    ce.alert.warn("Run :CECompileLLVMIR on an ASM output buffer.")
    return
  end

  local ok, compiler = pcall(ce.rest.check_compiler, info.compiler_id)
  if not ok or not compiler then
    ce.alert.error("Could not compile code with compiler id %s", info.compiler_id)
    return
  end

  if compiler.supportsIrView == false then
    ce.alert.error("Compiler %s does not support LLVM IR output.", compiler.name)
    return
  end

  -- Prepare args
  local args = {
    source = get_buf_contents(source_bufnr, info.range),
    compiler = compiler.id,
    flags = info.flags or "",
    lang = compiler.lang,
  }
  if info.filters then
    for key, value in pairs(info.filters) do
      args[key] = value
    end
  end

  -- Prepare body for IR compilation
  local body = ce.rest.create_compile_body(args)
  body.options.compilerOptions.produceIr = {
    filterDebugInfo = true,
    filterIRMetadata = true,
    filterAttributes = true,
    filterComments = true,
    noDiscardValueNames = true,
    demangle = true,
    showOptimized = true,
  }
  body.options.filters.binary = false

  -- Compile
  local response
  ok, response = pcall(ce.rest.compile_post, compiler.id, body)
  if not ok then
    ce.alert.error(response)
    return
  end
  if response.irOutput == nil or response.irOutput == vim.NIL then
    ce.alert.error("Compiler %s does not support LLVM IR output.", compiler.name)
    return
  end
  if response.code == 0 then
    ce.alert.info("LLVM IR generated with %s compiler.", compiler.name)
  else
    ce.alert.error("Could not generate LLVM IR with %s", compiler.name)
  end

  -- Write IR output to buffer
  local ir_bufnr = ce.util.create_ir_window(info.ir_bufnr, compiler.id, "llvm")
  local ir_lines = vim.tbl_map(function(line) return line.text end, response.irOutput.asm)
  write_output_buf(ir_bufnr, ir_lines)

  -- Update clientstate
  info.ir_bufnr = ir_bufnr

  if not opts.asm_bufnr then
    local asm_winid = fn.bufwinid(asm_bufnr)
    api.nvim_set_current_win(asm_winid)
  end
  ce.autocmd.init_line_match(source_bufnr, ir_bufnr, response.irOutput.asm, info.range.line1 - 1)
end)

M.open_website = function()
  local cmd
  if fn.executable("xdg-open") == 1 then
    cmd = "!xdg-open"
  elseif fn.executable("open") == 1 then
    cmd = "!open"
  elseif fn.executable("wslview") == 1 then
    cmd = "!wslview"
  else
    ce.alert.warn("CEOpenWebsite is not supported.")
    return
  end

  local conf = ce.config.get_config()

  local state = ce.clientstate.create()
  if state == nil then
    ce.alert.warn("No compiler configurations were found. Run :CECompile before this.")
    return
  end

  local url = table.concat({ conf.url, "clientstate", state }, "/")
  vim.cmd(table.concat({ "silent", cmd, url }, " "))
end

M.add_library = ce.async.void(function()
  local vim_select = get_select()
  local lang_list = ce.rest.languages_get()

  -- Infer language based on extension and prompt user.
  local extension = "." .. fn.expand("%:e")

  local possible_langs = vim.tbl_filter(
    function(el) return vim.tbl_contains(el.extensions, extension) end,
    lang_list
  )

  if vim.tbl_isempty(possible_langs) then
    ce.alert.error("File extension %s not supported by compiler-explorer.", extension)
    return
  end

  local lang = #possible_langs == 1 and possible_langs[1]
    or vim_select(possible_langs, {
      prompt = "Select language> ",
      format_item = function(item) return item.name end,
    })

  if not lang then return end
  vim.cmd("redraw")

  local libs = ce.rest.libraries_get(lang.id)
  if vim.tbl_isempty(libs) then
    ce.alert.info("No libraries are available for %.", lang.name)
    return
  end

  -- Choose library
  local lib = vim_select(libs, {
    prompt = "Select library> ",
    format_item = function(item) return item.name end,
  })

  if not lib then return end
  vim.cmd("redraw")

  -- Choose version
  local version = vim_select(lib.versions, {
    prompt = "Select library version> ",
    format_item = function(item) return item.version end,
  })

  if not version then return end
  vim.cmd("redraw")

  -- Add lib to buffer variable, overwriting previous library version if already present
  vim.b.libs = vim.tbl_deep_extend("force", vim.b.libs or {}, { [lib.id] = version.version })

  ce.alert.info("Added library %s version %s", lib.name, version.version)
end)

M.format = ce.async.void(function()
  local vim_select = get_select()
  -- Get contents of current buffer
  local source = get_buf_contents(0, { line1 = 1, line2 = -1 })

  -- Select formatter
  local formatters = ce.rest.formatters_get()
  local formatter = vim_select(formatters, {
    prompt = "Select formatter> ",
    format_item = function(item) return item.name end,
  })
  if not formatter then return end
  vim.cmd("redraw")

  local style = formatter.styles[1] or "__DefaultStyle"
  if #formatter.styles > 0 then
    style = vim_select(formatter.styles, {
      prompt = "Select formatter style> ",
      format_item = function(item) return item end,
    })

    if not style then return end
    vim.cmd("redraw")
  end

  local body = ce.rest.create_format_body(source, style)
  local out = ce.rest.format_post(formatter.type, body)

  if out.exit ~= 0 then
    ce.alert.error("Could not format code with %s", formatter.name)
    return
  end

  -- Split by newlines
  local lines = vim.split(out.answer, "\n")

  -- Replace lines of the current buffer with formatted text
  api.nvim_buf_set_lines(0, 0, -1, false, lines)

  ce.alert.info("Text formatted using %s and style %s", formatter.name, style)
end)

M.show_tooltip = ce.async.void(function()
  local ok, response = pcall(ce.rest.tooltip_get, vim.b.arch, fn.expand("<cword>"))
  if not ok then
    ce.alert.error(response)
    return
  end

  vim.lsp.util.open_floating_preview({ response.tooltip }, "markdown", {
    wrap = true,
    close_events = { "CursorMoved" },
    border = "single",
  })
end)

M.goto_label = function()
  local word_under_cursor = fn.expand("<cWORD>")
  if vim.b.labels == vim.NIL then
    ce.alert.error("No label found with the name %s", word_under_cursor)
    return
  end

  local label = vim.b.labels[word_under_cursor]
  if label == nil then
    ce.alert.error("No label found with the name %s", word_under_cursor)
    return
  end

  vim.cmd("norm m'")
  api.nvim_win_set_cursor(0, { label, 0 })
end

M.load_example = ce.async.void(function()
  local vim_select = get_select()
  local examples = ce.rest.list_examples_get()

  local examples_by_lang = {}
  for _, example in ipairs(examples) do
    if examples_by_lang[example.lang] == nil then
      examples_by_lang[example.lang] = { example }
    else
      table.insert(examples_by_lang[example.lang], example)
    end
  end

  local langs = vim.tbl_keys(examples_by_lang)
  table.sort(langs)

  local lang_id = vim_select(langs, {
    prompt = "Select language> ",
    format_item = function(item) return item end,
  })

  if not lang_id then return end
  vim.cmd("redraw")

  local example = vim_select(examples_by_lang[lang_id], {
    prompt = "Select example> ",
    format_item = function(item) return item.name end,
  })
  local response = ce.rest.load_example_get(lang_id, example.file)
  local lines = vim.split(response.file, "\n")

  langs = ce.rest.languages_get()
  local filtered = vim.tbl_filter(function(el) return el.id == lang_id end, langs)
  local extension = filtered[1].extensions[1]
  local bufname = example.file .. extension

  vim.cmd("tabedit")
  api.nvim_buf_set_lines(0, 0, -1, false, lines)
  api.nvim_buf_set_name(0, bufname)
  api.nvim_set_option_value("bufhidden", "wipe", { buf = 0 })

  if fn.has("nvim-0.8") then
    local ft = vim.filetype.match { filename = bufname }
    api.nvim_set_option_value("filetype", ft, { buf = 0 })
  else
    vim.filetype.match(bufname, 0)
  end
end)

return M

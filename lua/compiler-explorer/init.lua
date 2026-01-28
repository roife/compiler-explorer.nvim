local ce = require("compiler-explorer.lazy")

local api, fn = vim.api, vim.fn

local M = {}

local group = api.nvim_create_augroup("CompilerExplorerLive", { clear = true })

M.setup = function(user_config) ce.config.setup(user_config or {}) end

local function get_buf_contents(source_bufnr, range)
  local lines = api.nvim_buf_get_lines(source_bufnr, range.line1 - 1, range.line2, false)
  return table.concat(lines, "\n")
end

local function get_compiler(compiler_id)
  local ok, compiler = pcall(ce.rest.check_compiler, compiler_id)
  return ok and compiler or nil
end

local function ensure_compiler_selection(args)
  -- Get compiler from args
  local compiler = get_compiler(args.compiler)
  if compiler then return compiler end

  local conf = ce.config.get_config()

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
    or ce.util.prompt_select(possible_langs, {
      prompt = "Select language> ",
      format_item = function(item) return item.name end,
    })
  if not lang then return nil end

  -- Extend config with config specific to the language
  local lang_conf = conf.languages[lang.id]
  if lang_conf then conf = vim.tbl_deep_extend("force", conf, lang_conf) end

  if conf.compiler then
    compiler = get_compiler(conf.compiler)
  else
    local compilers = ce.rest.compilers_get(lang.id)
    compiler = ce.util.prompt_select(compilers, {
      prompt = "Select compiler> ",
      format_item = function(item) return item.name end,
    })
    if not compiler then return nil end
  end

  -- Choose compiler options
  args.flags = ce.util.prompt_input {
    prompt = "Select compiler options> ",
    default = conf.compiler_flags,
  }

  return compiler
end

local function extract_shortlink_id(raw)
  if raw == nil then return nil end
  local id = raw:match("/api/shortlinkinfo/([^/?#]+)")
    or raw:match("/z/([^/?#]+)")
    or raw:match("/shortlink/([^/?#]+)")
    or raw
  return id
end

local function get_aux_context(opts, cmd_name)
  local asm_bufnr = opts.asm_bufnr or api.nvim_get_current_buf()

  local source_bufnr, info = ce.clientstate.get_info_by_asm(asm_bufnr)
  if info == nil then
    ce.alert.warn(("Run :%s on an ASM output buffer."):format(cmd_name))
    return nil
  end

  local compiler = get_compiler(info.compiler_id)
  if compiler == nil then
    ce.alert.error("Could not compile code with compiler id %s", info.compiler_id)
    return nil
  end

  return asm_bufnr, source_bufnr, info, compiler
end

local function build_compile_args(source_bufnr, info, compiler)
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
  return args
end

local function restore_asm_window(asm_bufnr, opts)
  if not opts.asm_bufnr then
    local asm_winid = fn.bufwinid(asm_bufnr)
    api.nvim_set_current_win(asm_winid)
  end
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
  if not ok then
    ce.alert.error(response)
    return
  end
  if response.code == 0 then
    ce.alert.info("Compilation done with %s compiler.", compiler.name)
  else
    ce.alert.error("Could not compile code with %s", compiler.name)
  end

  -- Write output to buffer
  local asm_bufnr = opts.reuse_bufnr
    or ce.util.create_window_buffer(source_bufnr, compiler.id, opts.bang)
  local asm_lines = vim.tbl_map(function(line) return line.text end, response.asm)
  ce.util.write_output_buf(asm_bufnr, asm_lines)
  if args.binary then ce.util.set_binary_extmarks(response.asm, asm_bufnr) end

  -- Update LLVM IR if needed
  local _, info = ce.clientstate.get_info_by_asm(asm_bufnr)
  local ir_bufnr = info and info.ir_bufnr or nil
  local rust_mir_bufnr = info and info.rust_mir_bufnr or nil
  local opt_pipeline = info and info.opt_pipeline or {}

  ce.clientstate.save_info(source_bufnr, body, {
    range = { line1 = opts.line1, line2 = opts.line2 },
    asm_bufnr = asm_bufnr,
    ir_bufnr = ir_bufnr,
    rust_mir_bufnr = rust_mir_bufnr,
    opt_pipeline = opt_pipeline,
  })
  if ir_bufnr then M.compile_llvm_ir { asm_bufnr = asm_bufnr } end
  if rust_mir_bufnr then M.compile_rust_mir { asm_bufnr = asm_bufnr } end
  if opt_pipeline.bufnr then
    M.compile_opt_pipeline {
      asm_bufnr = asm_bufnr,
      selected_group = opt_pipeline.selected_group,
      selected_pass = opt_pipeline.selected_pass,
    }
  end

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
  local asm_bufnr, source_bufnr, info, compiler = get_aux_context(opts, "CECompileLLVMIR")
  if asm_bufnr == nil then return end

  if compiler.supportsIrView == false then
    ce.alert.error("Compiler %s does not support LLVM IR output.", compiler.name)
    return
  end

  -- Prepare args
  local args = build_compile_args(source_bufnr, info, compiler)

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
  local ok, response = pcall(ce.rest.compile_post, compiler.id, body)
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
  local ir_bufnr = ce.util.create_ir_window(info.ir_bufnr, asm_bufnr, compiler.id, "llvm", "ir")
  local ir_lines = vim.tbl_map(function(line) return line.text end, response.irOutput.asm)
  ce.util.write_output_buf(ir_bufnr, ir_lines)

  -- Update clientstate
  info.ir_bufnr = ir_bufnr

  restore_asm_window(asm_bufnr, opts)
  ce.autocmd.init_line_match(source_bufnr, ir_bufnr, response.irOutput.asm, info.range.line1 - 1)
end)

M.compile_rust_mir = ce.async.void(function(opts)
  local asm_bufnr, source_bufnr, info, compiler = get_aux_context(opts, "CECompileRustMIR")
  if asm_bufnr == nil then return end

  if compiler.supportsRustMirView == false then
    ce.alert.error("Compiler %s does not support Rust MIR output.", compiler.name)
    return
  end

  -- Prepare args
  local args = build_compile_args(source_bufnr, info, compiler)

  -- Prepare body for Rust MIR compilation
  local body = ce.rest.create_compile_body(args)
  body.options.compilerOptions.produceRustMir = true
  body.options.filters.binary = false

  -- Compile
  local ok, response = pcall(ce.rest.compile_post, compiler.id, body)
  if not ok then
    ce.alert.error(response)
    return
  end
  if response.rustMirOutput == nil or response.rustMirOutput == vim.NIL then
    ce.alert.error("Compiler %s does not support Rust MIR output.", compiler.name)
    return
  end
  if response.code == 0 then
    ce.alert.info("Rust MIR generated with %s compiler.", compiler.name)
  else
    ce.alert.error("Could not generate Rust MIR with %s", compiler.name)
  end

  -- Write Rust MIR output to buffer
  local mir_bufnr =
    ce.util.create_ir_window(info.rust_mir_bufnr, asm_bufnr, compiler.id, "rust", "rust_mir")
  local mir_lines = vim.tbl_map(function(line) return line.text end, response.rustMirOutput)
  ce.util.write_output_buf(mir_bufnr, mir_lines)

  -- Update clientstate
  info.rust_mir_bufnr = mir_bufnr

  restore_asm_window(asm_bufnr, opts)
end)

M.compile_opt_pipeline = ce.async.void(function(opts)
  local asm_bufnr, source_bufnr, info, compiler = get_aux_context(opts, "CECompileOptPipeline")
  if asm_bufnr == nil then return end

  -- Prepare args
  local args = build_compile_args(source_bufnr, info, compiler)

  -- Prepare body for opt pipeline compilation
  local body = ce.rest.create_compile_body(args)
  body.options.compilerOptions.produceOptPipeline = {
    filterDebugInfo = true,
    filterIRMetadata = false,
    fullModule = false,
    noDiscardValueNames = true,
    demangle = true,
    libraryFunctions = true,
  }
  body.options.filters.binary = false

  -- Compile
  local ok, response = pcall(ce.rest.compile_post, compiler.id, body)
  if not ok then
    ce.alert.error(response)
    return
  end

  local output = response.optPipelineOutput
  if output == nil or output == vim.NIL then
    ce.alert.error("Compiler %s does not support opt pipeline output.", compiler.name)
    return
  end
  if output.error then
    ce.alert.error("Opt pipeline error: %s", output.error)
    return
  end

  if response.code == 0 then
    ce.alert.info("Opt pipeline generated with %s compiler.", compiler.name)
  else
    ce.alert.error("Could not generate opt pipeline with %s", compiler.name)
  end

  -- Write opt pipeline output to buffer
  local opt_bufnr =
    ce.util.create_ir_window(info.opt_pipeline.bufnr, asm_bufnr, compiler.id, "llvm", "opt_pipeline")
  info.opt_pipeline = {
    bufnr = opt_bufnr,
    selected_group = opts.selected_group or "",
    selected_pass = opts.selected_pass or "",
  }
  ce.opt_pipeline.setup_buffer(opt_bufnr)
  ce.opt_pipeline.set_results(opt_bufnr, info, output.results or {})

  restore_asm_window(asm_bufnr, opts)
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

M.share_shortlink = ce.async.void(function()
  local sessions = ce.clientstate.build_sessions()
  if sessions == nil then
    ce.alert.warn("No compiler configurations were found. Run :CECompile before this.")
    return
  end

  local ok, response = pcall(ce.rest.shortener_post, { sessions = sessions })
  if not ok then
    ce.alert.error(response)
    return
  end

  local url = response.url
  if url == nil then
    ce.alert.error("Shortener did not return a url.")
    return
  end

  local register = (fn.has("clipboard") == 1) and "+" or '"'
  pcall(fn.setreg, register, url)
  ce.alert.info("Shortlink copied: %s", url)
end)

M.add_library = ce.async.void(function()
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
    or ce.util.prompt_select(possible_langs, {
      prompt = "Select language> ",
      format_item = function(item) return item.name end,
    })
  if not lang then return end

  local libs = ce.rest.libraries_get(lang.id)
  if vim.tbl_isempty(libs) then
    ce.alert.info("No libraries are available for %.", lang.name)
    return
  end

  -- Choose library
  local lib = ce.util.prompt_select(libs, {
    prompt = "Select library> ",
    format_item = function(item) return item.name end,
  })
  if not lib then return end

  -- Choose version
  local version = ce.util.prompt_select(lib.versions, {
    prompt = "Select library version> ",
    format_item = function(item) return item.version end,
  })
  if not version then return end

  -- Add lib to buffer variable, overwriting previous library version if already present
  vim.b.libs = vim.tbl_deep_extend("force", vim.b.libs or {}, { [lib.id] = version.version })

  ce.alert.info("Added library %s version %s", lib.name, version.version)
end)

M.format = ce.async.void(function()
  -- Get contents of current buffer
  local source = get_buf_contents(0, { line1 = 1, line2 = -1 })

  -- Select formatter
  local formatters = ce.rest.formatters_get()
  local formatter = ce.util.prompt_select(formatters, {
    prompt = "Select formatter> ",
    format_item = function(item) return item.name end,
  })
  if not formatter then return end

  local style = formatter.styles[1] or "__DefaultStyle"
  if #formatter.styles > 0 then
    style = ce.util.prompt_select(formatter.styles, {
      prompt = "Select formatter style> ",
      format_item = function(item) return item end,
    })
    if not style then return end
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

  local lang_id = ce.util.prompt_select(langs, {
    prompt = "Select language> ",
    format_item = function(item) return item end,
  })
  if not lang_id then return end

  local example = ce.util.prompt_select(examples_by_lang[lang_id], {
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

M.load_shortlink = ce.async.void(function(opts)
  local raw = opts and opts.fargs and opts.fargs[1] or nil
  local link_id = extract_shortlink_id(raw)
  if link_id == nil or link_id == "" then
    link_id = ce.util.prompt_input { prompt = "Shortlink or link_id> " }
    link_id = extract_shortlink_id(link_id)
  end
  if link_id == nil or link_id == "" then
    ce.alert.error("No valid shortlink or link_id provided.")
    return
  end

  local ok, response = pcall(ce.rest.shortlinkinfo_get, link_id)
  if not ok then
    ce.alert.error(response)
    return
  end

  local sessions = response.sessions
    or (response.config and response.config.sessions)
    or (response.state and response.state.sessions)

  if sessions == nil or vim.tbl_isempty(sessions) then
    ce.alert.error("Shortlink %s did not include any sessions.", link_id)
    return
  end

  local langs = ce.rest.languages_get()

  for i, session in ipairs(sessions) do
    if session.source == nil then
      ce.alert.warn("Shortlink session %d did not include source.", i)
      goto continue
    end

    local lang_id = session.language or ""
    local extension = ".txt"
    for _, lang in ipairs(langs) do
      if lang.id == lang_id and lang.extensions and #lang.extensions > 0 then
        extension = lang.extensions[1]
        break
      end
    end

    -- Create new tab with source code
    local bufname = session.filename or ("godbolt-" .. link_id .. "-" .. i .. extension)
    vim.cmd("tabedit")
    local source_bufnr = api.nvim_get_current_buf()
    local source_winid = api.nvim_get_current_win()
    api.nvim_buf_set_lines(source_bufnr, 0, -1, false, vim.split(session.source, "\n"))
    api.nvim_buf_set_name(source_bufnr, bufname)
    local ft = vim.filetype.match { filename = bufname }
    if ft then
      api.nvim_set_option_value("filetype", ft, { buf = source_bufnr })
    end

    if session.compilers == nil or vim.tbl_isempty(session.compilers) then
      ce.alert.warn("Shortlink session %d did not include compilers.", i)
      goto continue
    end

    for _, compiler in ipairs(session.compilers) do
      if compiler and compiler.id then
        local fargs = {
          "compiler=" .. compiler.id,
          "flags=" .. (compiler.options or ""),
        }
        if compiler.filters then
          for key, value in pairs(compiler.filters) do
            table.insert(fargs, key .. "=" .. tostring(value))
          end
        end
        if compiler.libs then
          vim.b.libs = {}
          for _, lib in ipairs(compiler.libs) do
            local id = lib.id or lib.name
            local version = lib.version or lib.ver
            if id and version then vim.b.libs[id] = version end
          end
        end
        if compiler.tools then
          vim.b.tools = vim.tbl_map(function(tool) return tool.id end, compiler.tools)
        end
        M.compile({
          line1 = 1,
          line2 = api.nvim_buf_line_count(source_bufnr),
          fargs = fargs,
          bang = true,
        }, false)
        api.nvim_set_current_win(source_winid)
      end
    end

    ::continue::
  end
end)

return M

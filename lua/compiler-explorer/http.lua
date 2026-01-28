local ce = require("compiler-explorer.lazy")

local json = vim.json

local M = {}

local net_request = ce.async.wrap(function(url, opts, cb)
  vim.net.request(url, opts, function(err, response) cb(err, response) end)
end, 3)

M.get = ce.async.void(function(url)
  local data = ce.cache.get()[url]
  if data ~= nil then return 200, data end

  local err, response = net_request(url, { retry = 3 })
  if err ~= nil then error(("vim.net.request error: %s"):format(err)) end
  if response == nil then error("vim.net.request returned no response") end
  if response.body == true then error("vim.net.request returned no body") end

  local resp = json.decode(response.body)
  local status = response.status or 200
  if status == 200 then ce.cache.get()[url] = resp end
  return status, resp
end)

M.post = ce.async.void(function(url, body)
  local args = {
    "-s",
    "-X",
    "POST",
    "-H",
    "Accept: application/json",
    "-H",
    "Content-Type: application/json",
    "-d",
    json.encode(body),
    "-w",
    [[\n%{http_code}\n]],
    url,
  }
  local ok, ret = pcall(ce.job.curl, args)
  if not ok then error("curl executable not found") end

  ce.async.scheduler()
  if ret.exit ~= 0 then
    error(
      ("curl error:\n command: %s \n exit_code %d\n stderr: %s"):format(
        ret.cmd,
        ret.exit,
        ret.stderr
      )
    )
  end

  if ret.signal == 9 then error("SIGKILL: curl command timed out") end

  local split = vim.split(ret.stdout, "\n")
  if #split < 2 then
    error([[curl response does not follow the <body \n\n status_code> pattern]])
  end
  local resp, status = json.decode(split[1]), tonumber(split[2])
  return status, resp
end)

return M

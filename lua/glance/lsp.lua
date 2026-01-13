local utils = require('glance.utils')

local M = {}

local function convert_calls_to_locations(calls)
  local locations = {}
  for _, call in ipairs(calls) do
    local item = call.from or call.to
    -- Use the selectionRange of the item instead of fromRanges
    -- fromRanges are the call sites, but we want to show the symbol locations
    table.insert(locations, {
      uri = item.uri,
      range = item.selectionRange,
    })
  end
  return locations
end

local function create_call_handler(method)
  return function(bufnr, params, cb)
    -- First, prepare call hierarchy to get the item
    vim.lsp.buf_request(bufnr, 'textDocument/prepareCallHierarchy', params, function(err, result, ctx)
      if err then
        utils.error(('An error happened preparing call hierarchy: %s'):format(err.message))
        return cb({})
      end

      if not result or vim.tbl_isempty(result) then
        return cb({})
      end

      -- Use the first item
      local item = result[1]

      -- Now request incoming/outgoing calls with the item
      vim.lsp.buf_request(bufnr, method.lsp_method, { item = item }, function(err2, result2, ctx2)
        if err2 and not method.non_standard then
          utils.error(('An error happened requesting %s: %s'):format(method.label, err2.message))
        end

        if result2 == nil or vim.tbl_isempty(result2) then
          return cb({})
        end

        result2 = (
          vim.fn.has('nvim-0.10.0') == 1 and vim.islist(result2)
          or vim.tbl_islist(result2)
        )
          and result2
          or { result2 }

        -- Convert call hierarchy results to locations
        result2 = convert_calls_to_locations(result2)

        return cb(result2, ctx)
      end)
    end)
  end
end

local function create_handler(method)
  return function(bufnr, params, cb)
    local _client_request_ids, cancel_all_requests, client_request_ids

    _client_request_ids, cancel_all_requests = vim.lsp.buf_request(
      bufnr,
      method.lsp_method,
      params,
      function(err, result, ctx)
        if not client_request_ids then
          -- do a copy of the table we don't want
          -- to mutate the original table
          client_request_ids =
            vim.tbl_deep_extend('keep', _client_request_ids, {})
        end

        -- Don't log an error when LSP method is non-standard
        if err and not method.non_standard then
          utils.error(
            ('An error happened requesting %s: %s'):format(
              method.label,
              err.message
            )
          )
        end

        if result == nil or vim.tbl_isempty(result) then
          client_request_ids[ctx.client_id] = nil
        else
          cancel_all_requests()
          result = (
            vim.fn.has('nvim-0.10.0') == 1 and vim.islist(result)
            or vim.tbl_islist(result)
          )
              and result
            or { result }

          return cb(result, ctx)
        end

        if vim.tbl_isempty(client_request_ids) then
          cb({})
        end
      end
    )
  end
end

---@alias GlanceMethod
--- | '"type_definitions"'
--- | '"implementations"'
--- | '"definitions"'
--- | '"references"'
--- | '"incoming_calls"'
--- | '"outgoing_calls"'

M.methods = {
  type_definitions = {
    label = 'type definitions',
    lsp_method = 'textDocument/typeDefinition',
  },
  implementations = {
    label = 'implementations',
    lsp_method = 'textDocument/implementation',
  },
  definitions = {
    label = 'definitions',
    lsp_method = 'textDocument/definition',
  },
  references = {
    label = 'references',
    lsp_method = 'textDocument/references',
  },
  incoming_calls = {
    label = 'incoming calls',
    lsp_method = 'callHierarchy/incomingCalls',
  },
  outgoing_calls = {
    label = 'outgoing calls',
    lsp_method = 'callHierarchy/outgoingCalls',
  },
}

function M.setup()
  for key, method in pairs(M.methods) do
    if method.lsp_method == 'callHierarchy/incomingCalls' or method.lsp_method == 'callHierarchy/outgoingCalls' then
      M.methods[key].handler = create_call_handler(method)
    else
      M.methods[key].handler = create_handler(method)
    end
  end
end

local function client_position_params(params)
  local win = vim.api.nvim_get_current_win()

  return function(client)
    local ret = vim.lsp.util.make_position_params(win, client.offset_encoding)
    return vim.tbl_extend('force', ret, params or {})
  end
end

local function make_position_params(params)
  if vim.fn.has('nvim-0.11') ~= 0 then
    return client_position_params(params)
  end

  local ret = vim.lsp.util.make_position_params(0)
  return vim.tbl_extend('force', ret, params or {})
end

function M.request(name, bufnr, cb)
  if M.methods[name] then
    local params =
      make_position_params({ context = { includeDeclaration = true } })
    M.methods[name].handler(bufnr, params, cb)
  else
    utils.error(("No such method '%s'"):format(name))
  end
end

return M

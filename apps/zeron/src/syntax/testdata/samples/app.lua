-- comment
--[[ block
comment ]]
local M = {}
local value, other = 1, 2.5e3
function M.greet(name, ...)
  local msg = "Hello " .. (name or "world") .. '!'
  for i = 1, #msg do print(i) end
  for k, v in pairs({a = 1, [2] = true, nil}) do print(k, v) end
  return msg, select('#', ...)
end
local function helper(x) return x * 2 end
setmetatable(M, { __index = function(t, k) return rawget(t, k) end })
goto done
::done::
return M

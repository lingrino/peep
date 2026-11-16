-- A simple FIFO queue.
local Queue = {}
Queue.__index = Queue

function Queue.new()
  return setmetatable({ first = 1, last = 0, items = {} }, Queue)
end

function Queue:push(value)
  self.last = self.last + 1
  self.items[self.last] = value
end

function Queue:pop()
  if self.first > self.last then return nil end
  local value = self.items[self.first]
  self.items[self.first] = nil
  self.first = self.first + 1
  return value
end

local q = Queue.new()
q:push("a"); q:push("b")
print(q:pop(), q:pop(), q:pop() == nil)

-- Generates the browser compiler's checked standard-library interfaces.
--
-- BUNDLE must already carry the prelude image: the interfaces are written against
-- its graph. Each SOURCE is compiled the way a browser session compiles it, and
-- every bundled module that took goes in, exactly as that first `require` checked
-- it. The image travels through the guest's fixed startup mailbox, so it holds what
-- the playground reaches rather than every module the compiler could load. See
-- `nupp.compiler.project.stdlibimage`.

local bundle, output = ...
local sources = {select(3, ...)}
assert(bundle and output and #sources > 0, "usage: lua generate-stdlib-image.lua BUNDLE OUTPUT SOURCE...")

local function read(path)
    local file = assert(io.open(path, "rb"))
    local text = assert(file:read("*a"))
    assert(file:close())
    return text
end

local texts = {}
for index, path in ipairs(sources) do
    texts[index] = read(path)
end

local Browser = assert(loadfile(bundle))()
local session = Browser.new()
local env = session:environment(nil)
assert(env.preludeArena, "generate-stdlib-image: the bundle carries no prelude image")

for index, path in ipairs(sources) do
    local response = session:compile(texts[index], path:match("[^/\\]+$"), {})
    assert(response.code, "generate-stdlib-image: " .. path .. " does not compile: " .. tostring(response.reason))
end

local names = {}
for _, name in ipairs(env.bundledModuleNames()) do
    if rawget(env.bundled, name) then
        names[#names + 1] = name
    end
end

local data = assert(require("nupp.compiler.project.stdlibimage").encode(env, names))
local file = assert(io.open(output, "wb"))
assert(file:write(data))
assert(file:close())
print(("wrote %s with %d modules"):format(output, #names))

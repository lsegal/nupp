-- Generates the browser compiler's checked standard-library interfaces.
--
-- BUNDLE must already carry the prelude image: the interfaces are written against
-- its graph. Every bundled module the browser compiler's own environment checks
-- cleanly goes in, checked exactly as a first `require` in a browser session would
-- check it. See `nupp.compiler.project.stdlibimage`.

local bundle, output = ...
assert(bundle and output, "usage: lua generate-stdlib-image.lua BUNDLE OUTPUT")

local Browser = assert(loadfile(bundle))()
local session = Browser.new()
local env = session:environment(nil)
assert(env.preludeArena, "generate-stdlib-image: the bundle carries no prelude image")

local data = assert(require("nupp.compiler.project.stdlibimage").encode(env, env.bundledModuleNames()))
local file = assert(io.open(output, "wb"))
assert(file:write(data))
assert(file:close())

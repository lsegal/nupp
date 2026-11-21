-- The benchmark programs the bench-process suites run, built ahead of time.
--
-- Building them checks `debug.bench` and the standard library beneath it, about
-- fifteen seconds on Linux CI. The suites used to build them as a shared fixture,
-- and four of them start at once, so each waited out the same build and was
-- charged for it: 18 to 24 s apiece against a 10 s budget (#438). The runner now
-- builds them before any case starts (the `prerequisites` in tests/groups.lua)
-- and names the directory in `variable`. Run without that runner, `path` builds
-- them itself; the build is incremental and its store persists, so a second one
-- answers from its cache.
--
-- The directory holds `project/`, whose `out/` has a `<program>.benchmark.lua`
-- per program, and `store/`, the compiler store the build filled. The suites'
-- children use that store too, so a child that compiles a fixture from source
-- finds `debug.bench` and everything beneath it there.

local prerequisite = require("helpers.prerequisite")

local M = {}

M.PROGRAMS = {"bench_fixed_records", "bench_protocol", "bench_suite"}

-- What `debug.bench` reaches that the compiler does not carry. A project that
-- compiles a benchmark from source includes these copies rather than the whole of
-- `src`: with `src` included, every standard-library module the program reaches
-- resolves to a project file there and is checked again in each process instead
-- of shared from the carried copy (#410).
M.UNCARRIED = {"debug/bench.nupp", "nupp/bench/internal/record.nupp", "nupp/bench/internal/statistics.nupp"}

--- Where the runner leaves the directory it built for this run.
M.variable = "NUPP_TEST_BENCH_PROGRAMS"

M.DIRECTORY = "build/test-bench-programs"

local function quote(value)
    return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

-- Registers the built modules before `nupp run`'s source loader. Native
-- libraries remain beside them in the ordinary module output tree.
local PRELOAD = [[local source = debug.getinfo(1, "S").source:gsub("\\", "/")
local root = assert(source:match("^@(.*)/[^/]+$"))
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path
]]

--- The shell command that builds the programs from ROOT and prints the
--- directory's absolute path last.
function M.command(root)
    local entries, sources = {}, {}
    for index, program in ipairs(M.PROGRAMS) do
        entries[index], sources[index] = ("%q"):format(program), ("%q"):format("src/" .. program .. ".nupp")
    end
    local manifest = ([[return {include = {"src", "bench"}, build = {default = "app", targets = {
app = {kind = "modules", entries = {%s}, sources = {%s}, outDir = "out", optimize = 1}
}}}
]]):format(table.concat(entries, ", "), table.concat(sources, ", "))
    local lines = {
        "cd " .. quote(root) .. " || exit 1",
        "nupp=\"$(pwd)/bin/nupp\"",
        "top=" .. quote(M.DIRECTORY),
        -- The store persists across runs; the project is made afresh, so a module
        -- that is gone from the programs is gone from `out` too.
        "rm -rf \"$top/project\" && mkdir -p \"$top/store\" \"$top/project/src\" || exit 1",
    }
    for _, program in ipairs(M.PROGRAMS) do
        lines[#lines + 1] = ("cp %s \"$top/project/src/\" || exit 1"):format(quote("tests/fixtures/" .. program .. ".nupp"))
    end
    for _, relative in ipairs(M.UNCARRIED) do
        local target = "\"$top/project/bench/\"" .. quote(relative)
        lines[#lines + 1] = ("mkdir -p \"$(dirname %s)\" && cp %s %s || exit 1"):format(
            target,
            quote("src/" .. relative),
            target
        )
    end
    lines[#lines + 1] = "cat > \"$top/project/nupp.lua\" <<'NUPP_MANIFEST'\n" .. manifest .. "NUPP_MANIFEST"
    lines[#lines + 1] = "cd \"$top\" && top=\"$(pwd -W 2>/dev/null || pwd)\" && cd project || exit 1"
    lines[#lines + 1] = "NUPP_CACHE_DIR=\"$top/store\" \"$nupp\" build || exit 1"
    lines[#lines + 1] = "cat > out/.preload.lua <<'NUPP_PRELOAD'\n" .. PRELOAD .. "NUPP_PRELOAD"
    lines[#lines + 1] = [[(cd out && find . -name '*.lua' ! -name '.preload.lua' ! -name '*.benchmark.lua') | sed 's#^\./##' | sort | while read -r relative; do
    module=$(printf '%s' "$relative" | sed -e 's#\.lua$##' -e 's#/init$##' -e 's#/#.#g')
    printf 'if package.loaded["%s"] == nil then package.preload["%s"] = assert(loadfile(root .. "/%s")) end\n' "$module" "$module" "$relative"
done >> out/.preload.lua || exit 1]]
    for _, program in ipairs(M.PROGRAMS) do
        lines[#lines + 1] = (
            "{ cat out/.preload.lua; printf 'assert(loadfile(root .. \"/%%s\"))()\\n' %s; } > %s || exit 1"
        ):format(quote(program .. ".lua"), quote("out/" .. program .. ".benchmark.lua"))
    end
    lines[#lines + 1] = "printf '%s\\n' \"$top\""

    -- A subshell, so `exit` ends the script rather than whatever runs it.
    return "(\n" .. table.concat(lines, "\n") .. "\n)"
end

local cached, problem

--- The built directory, or nil and the build's output.
function M.path(root)
    if not cached and not problem then
        local status, output, path = prerequisite.result(M, root)
        if status ~= 0 or not path then
            problem = ("building the benchmark programs failed:\n%s"):format(output:sub(-2000))
        else
            cached = path
        end
    end

    return cached, problem
end

--- The store the build filled, when this run has built the programs already.
function M.preparedStore()
    local prepared = cached or os.getenv(M.variable)
    if prepared and prepared ~= "" then
        return prepared .. "/store"
    end

    return nil
end

return M

-- The test run's compile service: which shell commands it takes, the request
-- it makes of them, and that a command it answers reads exactly as the same
-- command run by the shell.
local test = require("assert")
local compileservice = require("nupp.tools.compileservice")
-- The runner puts its route in front of the runtime's `popen` before each case,
-- and only once that is loaded.
require("nupp.runtime.standardio")
local M = {}

local ROOT = debug.getinfo(1, "S").source:match("^@(.+)/tests/")
if not ROOT then
    local pwd = assert(io.popen("pwd"))
    ROOT = pwd:read("*l")
    pwd:close()
end
ROOT = ROOT:gsub("\\", "/")
local NUPP = ROOT .. "/bin/nupp"

local function parse(command, mode)
    return compileservice.parse(command, mode or "pipe")
end

function M.aPlainCompilerCommandIsReadWord_by_word()
    local command = parse("cd '/work/p' && NUPP_CACHE_DIR=/tmp/c '/repo/bin/nupp' check --json main.nupp 2>&1")
    test.eq(command.cwd, "/work/p")
    test.eq(#command.env, 1)
    test.eq(command.env[1][1], "NUPP_CACHE_DIR")
    test.eq(command.env[1][2], "/tmp/c")
    test.eq(command.executable, "/repo/bin/nupp")
    test.eq(table.concat(command.argv, " "), "check --json main.nupp")
    test.eq(command.stdout, "pipe")
    test.eq(command.stderr, "pipe")
end

function M.quotingFollowsTheShell()
    local command = parse([[cd "/work/a b" && "/repo/bin/nupp" check "x\"y" 'it''s' a\ b "\q"]])
    test.eq(command.cwd, "/work/a b")
    test.eq(command.argv[2], 'x"y')
    test.eq(command.argv[3], "its")
    test.eq(command.argv[4], "a b")
    test.eq(command.argv[5], "\\q")
end

function M.redirectionsApplyInOrder()
    local both = parse("/repo/bin/nupp check >/dev/null 2>&1")
    test.eq(both.stdout, "null")
    test.eq(both.stderr, "null")
    local swapped = parse("/repo/bin/nupp check 2>&1 >/dev/null")
    test.eq(swapped.stdout, "null")
    test.eq(swapped.stderr, "pipe")
    local quiet = parse("/repo/bin/nupp check 2>/dev/null")
    test.eq(quiet.stdout, "pipe")
    test.eq(quiet.stderr, "null")
    local inherited = parse("/repo/bin/nupp check 2>&1", "out")
    test.eq(inherited.stdout, "out")
    test.eq(inherited.stderr, "out")
    test.eq(parse("/repo/bin/nupp check", "out").stderr, "err")
end

function M.anythingNeedingMoreOfAShellIsLeftToIt()
    local refused = {
        "/repo/bin/nupp check | head -1",
        "/repo/bin/nupp check; echo done",
        "/repo/bin/nupp check $FILE",
        "/repo/bin/nupp check \"$FILE\"",
        "/repo/bin/nupp check `pwd`",
        "/repo/bin/nupp check *.nupp",
        "/repo/bin/nupp check > out.txt",
        "/repo/bin/nupp check >> /dev/null",
        "/repo/bin/nupp fmt - < main.nupp",
        "cd /p && /repo/bin/nupp check && /repo/bin/nupp build",
        "cd /p; /repo/bin/nupp check",
        "/repo/bin/nupp check &",
        "/repo/bin/nupp check 'unterminated",
        "/repo/bin/nupp check\n/repo/bin/nupp build",
        "(cd /p && /repo/bin/nupp check)",
        "env -u X /repo/bin/nupp check ~/x",
        "",
    }
    for _, command in ipairs(refused) do
        test.eq(parse(command), nil, command)
    end
end

function M.onlyThisCheckoutsCompilerCommandsAreAnswered()
    local function request(command, cwd)
        return compileservice.request(parse(command), "/repo", cwd or "/work", false)
    end

    local answered = request("cd p && ../../repo/tools/../bin/nupp build")
    test.eq(answered.cwd, "/work/p")
    test.eq(answered.argv[1], "build")
    test.eq(request("/other/bin/nupp check"), nil)
    test.eq(request("nupp check"), nil)
    for _, name in ipairs({"run", "test", "lsp", "watch", "bench", "task", "fixpoint", "rock", "__comptime-worker"}) do
        test.eq(request("/repo/bin/nupp " .. name), nil, name)
    end
    -- Builds of the checkout itself keep the launcher's build lock.
    test.eq(request("cd /repo && /repo/bin/nupp build"), nil)
    test.eq(request("/repo/bin/nupp clean", "/repo/tests"), nil)
    test.ne(request("/repo/bin/nupp check", "/repo"), nil)
    test.ne(request("/repo/bin/nupp --version"), nil)
end

function M.windowsGetsTheWordsANativeProgramWouldHave()
    local function request(command)
        return compileservice.request(parse(command), "C:/repo", "C:/work", true)
    end

    local answered = request("cd /c/work/p && X=/c/tmp/y /c/repo/bin/nupp check /c/work/p/main.nupp --out=/d/o")
    test.eq(answered.cwd, "C:/work/p")
    test.eq(answered.argv[2], "C:/work/p/main.nupp")
    test.eq(answered.argv[3], "--out=D:/o")
    test.eq(answered.env[1][2], "C:/tmp/y")
    test.ne(request("C:/Repo/bin/nupp check"), nil)
    -- Git Bash translates other POSIX paths in ways only it knows.
    test.eq(request("C:/repo/bin/nupp check /tmp/main.nupp"), nil)
    test.eq(request("X=/dev/null C:/repo/bin/nupp check"), nil)
end

function M.framesCarryAnyBytes()
    local items = {"", "a:b", "12:x", "line\nbreak\0nul", ("x"):rep(70000)}
    local back = compileservice.unpack(compileservice.pack(items))
    test.eq(#back, #items)
    for index, item in ipairs(items) do
        test.eq(back[index], item)
    end
    test.eq(compileservice.unpack("5:abc"), nil)
    test.eq(compileservice.unpack("x:abc"), nil)
end

local function tempProject()
    local dir = os.tmpname()
    os.remove(dir)
    assert(os.execute("mkdir -p '" .. dir .. "'") == 0)
    local manifest = assert(io.open(dir .. "/nupp.lua", "wb"))
    manifest:write('return {include = {"."}}\n')
    manifest:close()
    local source = assert(io.open(dir .. "/main.nupp", "wb"))
    source:write("local value: integer = \"text\"\nprint(value)\n")
    source:close()

    return dir
end

local function capture(command)
    local pipe = assert(io.popen(command))
    local output = pipe:read("*a")
    local ok, how, code = pipe:close()

    return output, ok, how, code
end

-- `exec` makes the same command one the service does not take, so the shell
-- runs it: the two answers come from the two routes.
function M.anAnsweredCommandReadsAsTheShellsOwn()
    local counts = rawget(_G, "__NUPP_TEST_COMPILE_SERVICE_COUNTS")
    if os.getenv("NUPP_LAUNCHER_RUN_ROOT") == nil or os.getenv("NUPP_TEST_COMPILE_SERVICE") == "0" or counts == nil then
        return
    end
    local dir = tempProject()
    local commands = {
        ("cd '%s' && '%s' check main.nupp 2>&1"):format(dir, NUPP),
        ("cd '%s' && '%s' check --json main.nupp 2>/dev/null"):format(dir, NUPP),
        ("cd '%s' && '%s' check nosuch.nupp 2>&1"):format(dir, NUPP),
        ("'%s' --version"):format(NUPP),
        ("'%s' explain NUPP2004"):format(NUPP),
    }
    for _, command in ipairs(commands) do
        local before = counts()
        local routed, ok, how, code = capture(command)
        test.eq(counts(), before + 1, "answered by the service: " .. command)
        local direct = command:match("^cd ") and command:gsub("&& '", "&& exec '", 1) or "exec " .. command
        local shell, shellOk, shellHow, shellCode = capture(direct)
        test.eq(counts(), before + 1, "answered by the shell: " .. command)
        -- How long a check took is the one thing two runs of it do not agree on.
        local function untimed(text)
            return (text:gsub('"timing":.*$', ""))
        end
        test.eq(untimed(routed), untimed(shell), command)
        test.eq(ok, shellOk, command)
        test.eq(how, shellHow, command)
        test.eq(code, shellCode, command)
    end
    os.execute("rm -rf '" .. dir .. "'")
end

return M

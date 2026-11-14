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

-- The suites' usual ways of reading a status beside merged output.
function M.aTrailingReportOfTheStatusIsKept()
    local S = compileservice.STATUS
    local forms = {
        {[[/repo/bin/nupp check 2>&1; echo "__exit__:$?"]], "__exit__:" .. S .. "\n", "pipe"},
        {"/repo/bin/nupp check 2>&1; echo '__exit__:'$?", "__exit__:" .. S .. "\n", "pipe"},
        {"/repo/bin/nupp check; echo rc=$?", "rc=" .. S .. "\n", "pipe"},
        {"/repo/bin/nupp check ; echo $? done", S .. " done\n", "pipe"},
        {[[/repo/bin/nupp check; echo "[$?]"]], "[" .. S .. "]\n", "pipe"},
        {"/repo/bin/nupp check 2>&1; printf ' __status__:%s' $?", " __status__:" .. S, "pipe"},
        {[[/repo/bin/nupp check > out 2>&1; printf '%s\n' "$?" > status]], S .. "\n", "file:status"},
        {"/repo/bin/nupp check; echo $? >/dev/null", S .. "\n", "null"},
    }
    for _, form in ipairs(forms) do
        local command = parse(form[1])
        test.ne(command, nil, form[1])
        test.eq(command.argv[1], "check", form[1])
        test.eq(command.report.text, form[2], form[1])
        test.eq(command.report.target, form[3], form[1])
    end
    test.eq(compileservice.withStatus("rc=" .. S .. " [" .. S .. "]", 3), "rc=3 [3]")
    test.eq(parse("/repo/bin/nupp check").report, nil)
    local refused = {
        [[/repo/bin/nupp check; echo "$HOME$?"]],
        "/repo/bin/nupp check; echo -n $?",
        "/repo/bin/nupp check; echo done; echo $?",
        "/repo/bin/nupp check; printf '%d' $?",
        "/repo/bin/nupp check; printf '%s %s' $? $?",
        [[/repo/bin/nupp check; printf '\t%s' $?]],
        "/repo/bin/nupp check; true",
        "/repo/bin/nupp check $?",
        "/repo/bin/nupp check; echo $? > status 2>&1",
    }
    for _, command in ipairs(refused) do
        test.eq(parse(command), nil, command)
    end
end

function M.redirectionsToFilesNameThem()
    local command = parse("cd /p && /repo/bin/nupp fmt > 'out file' 2> .err")
    test.eq(command.stdout, "file:out file")
    test.eq(command.stderr, "file:.err")
    local merged = parse("/repo/bin/nupp check >log 2>&1")
    test.eq(merged.stdout, "file:log")
    test.eq(merged.stderr, "file:log")
end

function M.anythingNeedingMoreOfAShellIsLeftToIt()
    local refused = {
        "/repo/bin/nupp check | head -1",
        "/repo/bin/nupp check $FILE",
        "/repo/bin/nupp check \"$FILE\"",
        "/repo/bin/nupp check `pwd`",
        "/repo/bin/nupp check *.nupp",
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
    -- Help writes nothing, whichever command it names; a one-shot `lsp` query
    -- and a task listing compile and answer.
    test.ne(request("/repo/bin/nupp build --help", "/repo"), nil)
    test.ne(request("/repo/bin/nupp rock pack --help"), nil)
    test.ne(request("/repo/bin/nupp test -h"), nil)
    test.ne(request("/repo/bin/nupp lsp inspect --json main.nupp 1 1"), nil)
    test.ne(request("/repo/bin/nupp task --list --json"), nil)
    test.ne(request("/repo/bin/nupp __complete bash 2 check --js"), nil)
    test.eq(request("/repo/bin/nupp lsp serve"), nil)
    test.eq(request("/repo/bin/nupp lsp --stdio"), nil)
    test.eq(request("/repo/bin/nupp task build"), nil)
    -- The words after `run`'s file are the program's.
    test.eq(request("/repo/bin/nupp run main.nupp --help"), nil)
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

-- A leading `true &&` makes the same command one the service does not take, so
-- the shell runs it: the two answers come from the two routes.
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
        ("cd '%s' && NO_COLOR= '%s' check 2>&1; echo \"__exit__:$?\""):format(dir, NUPP),
        ("cd '%s' && '%s' check > out.txt 2>&1; printf '%%s\\n' \"$?\" > status.txt"):format(dir, NUPP),
        ("cd '%s' && '%s' check main.nupp 2> out.txt; printf ' __status__:%%s' $?"):format(dir, NUPP),
    }
    -- What a command left in the files it was told to write, taken away again.
    local function written()
        local text = {}
        for _, name in ipairs({"out.txt", "status.txt"}) do
            local file = io.open(dir .. "/" .. name, "rb")
            if file then
                text[#text + 1] = name .. ":" .. file:read("*a")
                file:close()
                os.remove(dir .. "/" .. name)
            end
        end

        return table.concat(text, "\n")
    end

    for _, command in ipairs(commands) do
        local before = counts()
        local routed, ok, how, code = capture(command)
        local routedFiles = written()
        test.eq(counts(), before + 1, "answered by the service: " .. command)
        local direct = "true && " .. command
        local shell, shellOk, shellHow, shellCode = capture(direct)
        test.eq(counts(), before + 1, "answered by the shell: " .. command)
        test.eq(routedFiles, written(), command)
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

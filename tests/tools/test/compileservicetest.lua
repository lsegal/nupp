-- The test run's compile service: which shell commands it takes, the request
-- it makes of them, and that a command it answers reads exactly as the same
-- command run by the shell.
local test = require("assert")
local compileservice = require("nupp.tools.compileservice")
-- The runner puts its route in front of the runtime's `popen` and the compiler's
-- process module before each case, and only once they are loaded.
require("nupp.runtime.standardio")
local process = require("nupp.compiler.process")
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

-- A `~` inside a word is literal, as in the short names a Windows temp path
-- carries; a leading one, or one after `=` or `:`, is the shell's to expand.
function M.aTildeInsideAWordIsLiteral()
    local command = parse("cd C:/Users/RUNNER~1/Temp/s1 && C:/Users/RUNNER~1/Temp/s1/bin/nupp build a~b")
    test.ne(command, nil)
    test.eq(command.cwd, "C:/Users/RUNNER~1/Temp/s1")
    test.eq(command.executable, "C:/Users/RUNNER~1/Temp/s1/bin/nupp")
    test.eq(command.argv[2], "a~b")
    for _, refused in ipairs({
        "/repo/bin/nupp check ~/x",
        "/repo/bin/nupp check ~",
        "X=~/x /repo/bin/nupp check",
        "PATH=/bin:~/bin /repo/bin/nupp check",
        "/repo/bin/nupp check --out=~/x",
    }) do
        test.eq(parse(refused), nil, refused)
    end
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
        {"/repo/bin/nupp check 2>&1; printf '\n__status__:%s' $?", "\n__status__:" .. S, "pipe"},
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
    -- A relative program is found from where the command's `cd` went: another
    -- tree's launcher is not this checkout's compiler.
    test.eq(request("cd /tmp/planted && ./bin/nupp check", "/repo"), nil)
    test.ne(request("cd /repo && ./bin/nupp check", "/work"), nil)
    test.eq(request("nupp check"), nil)
    for _, name in ipairs({"test", "lsp", "watch", "bench", "task", "fixpoint", "rock", "__comptime-worker"}) do
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
    -- A project of its own beneath the checkout is not the checkout.
    local windows = package.config:sub(1, 1) == "\\"
    local checkout = compileservice.normalize(os.tmpname(), windows)
    os.remove(checkout)
    assert(os.execute("mkdir -p '" .. checkout .. "/fixture/src' '" .. checkout .. "/tests'") == 0)
    local manifest = assert(io.open(checkout .. "/fixture/nupp.lua", "wb"))
    manifest:write("return {}\n")
    manifest:close()
    local function build(cwd)
        return compileservice.request(parse(checkout .. "/bin/nupp build"), checkout, cwd, windows)
    end
    test.ne(build(checkout .. "/fixture/src"), nil)
    test.ne(build(checkout .. "/fixture"), nil)
    test.eq(build(checkout .. "/tests"), nil)
    test.eq(build(checkout), nil)
    os.execute("rm -rf '" .. checkout .. "'")
    -- So does asking for a report's schema.
    test.ne(request("/repo/bin/nupp build --schema", "/repo"), nil)
    test.ne(request("/repo/bin/nupp bench --list --file x.bench.nupp --schema"), nil)
    test.eq(request("/repo/bin/nupp bench --list --json"), nil)
    test.eq(request("/repo/bin/nupp run main.nupp --schema").spawn, true)
    test.eq(request("/repo/bin/nupp lsp serve"), nil)
    test.eq(request("/repo/bin/nupp lsp --stdio"), nil)
    test.eq(request("/repo/bin/nupp task build"), nil)
    -- `run`'s program keeps a process of its own, which the service starts; the
    -- words after its file are the program's, and `--watch` stays up.
    test.eq(request("/repo/bin/nupp run main.nupp").spawn, true)
    test.eq(request("/repo/bin/nupp run -O2 main.nupp --help").spawn, true)
    test.eq(request("/repo/bin/nupp run main.nupp --watch").spawn, true)
    test.eq(request("/repo/bin/nupp run --watch main.nupp"), nil)
    test.eq(request("/repo/bin/nupp run --help").spawn, false)
    test.eq(request("/repo/bin/nupp check").spawn, false)
end

-- `PATH='dir':"$PATH"` in front of the compiler, or of a bare `nupp` that
-- search path finds in this checkout.
function M.aSearchPathAssignmentKeepsTheCallersOwn()
    local P = compileservice.PATH
    local command = parse([[cd /p && PATH='/repo/bin':"$PATH" NO_COLOR= nupp check 2>&1]])
    test.eq(command.env[1][1], "PATH")
    test.eq(command.env[1][2], "/repo/bin:" .. P)
    test.eq(command.env[2][1], "NO_COLOR")
    test.eq(command.executable, "nupp")
    test.eq(parse("PATH=/x:${PATH} /repo/bin/nupp check").env[1][2], "/x:" .. P)
    test.eq(parse("PATH=$PATH:/x /repo/bin/nupp check").env[1][2], P .. ":/x")
    for _, refused in ipairs({
        [[X="$PATH" /repo/bin/nupp check]],
        "/repo/bin/nupp check $PATH",
        "/repo/bin/nupp check; echo $PATH",
        "PATH=$PATHS /repo/bin/nupp check",
    }) do
        test.eq(parse(refused), nil, refused)
    end

    local function request(text)
        return compileservice.request(parse(text), "/repo", "/work", false)
    end

    local own = os.getenv("PATH") or ""
    test.eq(request([[PATH='/repo/bin':"$PATH" nupp check]]).env[1][2], "/repo/bin:" .. own)
    test.ne(request("PATH=../repo/bin:$PATH nupp check"), nil)
    test.ne(request("PATH=/work/x/../../repo/bin /repo/bin/nupp check"), nil)
    -- A `nupp` the caller's own search path finds first is not one this can see.
    test.eq(request("PATH=$PATH:/repo/bin nupp check"), nil)
    test.eq(request("PATH=/other/bin:$PATH nupp check"), nil)
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
    -- A native program gets a search path separated by semicolons.
    local own = os.getenv("PATH") or ""
    test.eq(request([[PATH='/c/repo/bin':"$PATH" nupp check]]).env[1][2], "C:/repo/bin;" .. own)
    test.eq(request([[PATH='C:/repo/bin':/d/x:"$PATH" nupp check]]).env[1][2], "C:/repo/bin;D:/x;" .. own)
    -- An argv a caller passed is already what the compiler receives.
    local native = compileservice.request(
        {
            env = {{"PATH", [[C:\repo\bin;D:\x]]}},
            executable = "nupp",
            argv = {"check", "/tmp/x"},
            stdout = "pipe",
            stderr = "pipe",
            native = true,
        },
        "C:/repo",
        "C:/work",
        true
    )
    test.eq(native.argv[2], "/tmp/x")
    test.eq(native.env[1][2], [[C:\repo\bin;D:\x]])
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
    local program = assert(io.open(dir .. "/hello.nupp", "wb"))
    program:write('print("hello", ...)\nio.stderr:write("to stderr\\n")\nos.exit(3)\n')
    program:close()

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
        ("cd '%s' && PATH='%s':\"$PATH\" nupp check main.nupp 2>&1"):format(dir, ROOT .. "/bin"),
        ("cd '%s' && '%s' run hello.nupp a 'b c' 2>&1; echo \"__exit__:$?\""):format(dir, NUPP),
        ("cd '%s' && '%s' run hello.nupp > out.txt 2>/dev/null; echo \"__exit__:$?\""):format(dir, NUPP),
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
    -- An argv handed to the compiler's process module takes the same route.
    local before = counts()
    local code, output = process.capture({NUPP, "check", "main.nupp"}, {cwd = dir, env = {NO_COLOR = "1"}})
    test.eq(counts(), before + 1, "an argv reaches the service")
    local shell = capture(("true && cd '%s' && NO_COLOR=1 '%s' check main.nupp 2>&1"):format(dir, NUPP))
    test.eq(output, shell)
    test.eq(code, 1)
    os.execute("rm -rf '" .. dir .. "'")
end

-- The file a redirect names is created with the permissions the shell would give
-- it, so whoever ran the command can read it back. On arm64 macOS the service
-- once created it with a mode read off the stack (#298).
function M.aRedirectedFileReadsBackWithTheShellsPermissions()
    local counts = rawget(_G, "__NUPP_TEST_COMPILE_SERVICE_COUNTS")
    if os.getenv("NUPP_LAUNCHER_RUN_ROOT") == nil or os.getenv("NUPP_TEST_COMPILE_SERVICE") == "0" or counts == nil then
        return
    end
    local dir = tempProject()
    local function permissions(name)
        local listing = capture(("cd '%s' && ls -l %s"):format(dir, name))

        return listing:match("^(%S+)")
    end

    local before = counts()
    capture(("cd '%s' && '%s' check > routed.txt 2> routed.err"):format(dir, NUPP))
    test.eq(counts(), before + 1, "answered by the service")
    capture(("true && cd '%s' && '%s' check > shell.txt 2> shell.err"):format(dir, NUPP))
    test.eq(counts(), before + 1, "answered by the shell")
    for _, pair in ipairs({{"routed.txt", "shell.txt"}, {"routed.err", "shell.err"}}) do
        local file = io.open(dir .. "/" .. pair[1], "rb")
        test.truthy(file, pair[1] .. " can be read back")
        if file then
            file:close()
        end
        test.eq(permissions(pair[1]), permissions(pair[2]), pair[1])
    end
    os.execute("rm -rf '" .. dir .. "'")
end

return M

-- OS threads and atomics in a native program.
--
-- A native program starts threads through its platform's own functions, with a
-- Nupp function as the entry, and reaches atomics through libatomic's sized
-- functions, which the backend lowers in place. The lowering is read from the
-- module text; the threads are run, because whether the counters they share
-- come out exact is the only evidence the orderings mean anything.

local test = require("assert")
local parser = require("nupp.compiler.syntax.parser")
local check = require("helpers.fragment")
local envMod = require("nupp.compiler.project.env")
local native = require("nupp.compiler.aot.llvm.native")

local HERE = require("helpers.paths").absoluteTests
local NUPP = HERE .. "/../bin/nupp"

local sharedEnv = envMod.new(require("helpers.paths").tests .. "/..")

local M = {}

--- The module `source` lowers to, or nil and the refusal's message.
local function lower(source)
    local tree = parser.parse(source, "host.nupp")
    if #tree.errors > 0 then
        error("syntax: " .. tree.errors[1].message, 2)
    end
    local diagnostics = check.check(tree, "host.nupp", sharedEnv)
    if #diagnostics > 0 then
        error("check: " .. diagnostics[1].code .. " " .. tostring(diagnostics[1].msg), 2)
    end
    local ir, problem = native.module(tree.root, "")
    if ir == nil then
        return nil, problem.message
    end

    return ir
end

local function contains(ir, fragment)
    assert(ir:find(fragment, 1, true), "expected `" .. fragment .. "` in:\n" .. ir)
end

local ATOMICS = [[
cdef function __atomic_load_8(borrows p: int64*, order: int32): int64
cdef function __atomic_store_8(borrows p: int64*, v: int64, order: int32)
cdef function __atomic_fetch_add_8(borrows p: int64*, v: int64, order: int32): int64
cdef function __atomic_fetch_sub_4(borrows p: int32*, v: int32, order: int32): int32
cdef function __atomic_exchange_8(borrows p: int64*, v: int64, order: int32): int64
cdef function __atomic_compare_exchange_8(borrows p: int64*, borrows expected: int64*, desired: int64, success: int32, failure: int32): boolean
]]

function M.atomicsLowerInPlaceWithTheirOrders()
    local ir = assert(lower(ATOMICS .. [[

local function main(argc: int32, argv: cstring*): int32
    local cell = argv as int64*
    local small = argv as int32*
    __atomic_store_8(cell, 1, 3)
    local seen = __atomic_load_8(cell, 2)
    local before = __atomic_fetch_add_8(cell, seen, 5)
    __atomic_fetch_sub_4(small, 1, 0)
    __atomic_exchange_8(cell, before, 4)
    if __atomic_compare_exchange_8(cell, cell, 9, 5, 1) then
        return 1
    end
    return 0
end
]]))
    contains(ir, "store atomic i64 1, ptr")
    contains(ir, "release, align 8")
    contains(ir, "load atomic i64, ptr")
    contains(ir, "acquire, align 8")
    contains(ir, "atomicrmw add ptr")
    contains(ir, "seq_cst, align 8")
    contains(ir, "atomicrmw sub ptr")
    contains(ir, "i32 1 monotonic, align 4")
    contains(ir, "atomicrmw xchg ptr")
    contains(ir, "acq_rel, align 8")
    contains(ir, "cmpxchg ptr")
    contains(ir, "i64 9 seq_cst acquire, align 8")
    assert(not ir:find("@__atomic_", 1, true), "an atomic is never called or declared:\n" .. ir)
end

function M.anOrderThatIsNotALiteralIsSequentiallyConsistent()
    local ir = assert(lower(ATOMICS .. [[

local function main(argc: int32, argv: cstring*): int32
    __atomic_fetch_add_8(argv as int64*, 1, argc)
    return 0
end
]]))
    contains(ir, "atomicrmw add ptr")
    contains(ir, "i64 1 seq_cst, align 8")
end

function M.anAtomicDeclaredWithTheWrongShapeIsRefused()
    local ir, message = lower([[
cdef function __atomic_load_8(borrows p: int64*, order: int32): int32

local function main(): int32
    return 0
end
]])
    test.eq(ir, nil)
    test.eq(message, "__atomic_load_8 takes (ptr, i32) and returns i64, as libatomic declares it")
end

function M.anOrderAnAccessCannotHaveIsRefused()
    local ir, message = lower(ATOMICS .. [[

local function main(argc: int32, argv: cstring*): int32
    __atomic_store_8(argv as int64*, 1, 2)
    return 0
end
]])
    test.eq(ir, nil)
    test.eq(message, "memory order 2 is not valid for this atomic operation")
end

function M.anUnknownAtomicIsRefused()
    local ir, message = lower([[
cdef function __atomic_fetch_min_8(borrows p: int64*, v: int64, order: int32): int64

local function main(): int32
    return 0
end
]])
    test.eq(ir, nil)
    test.eq(message, "__atomic_fetch_min_8 is not a libatomic operation a native program can lower")
end

local function quote(value)
    return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function run(command)
    local pipe = assert(io.popen(command .. " 2>&1; printf '\n__status__:%s' $?"))
    local output = pipe:read("*a")
    pipe:close()
    local status = tonumber(output:match("__status__:(%d+)%s*$"))

    return status, (output:gsub("\r?\n__status__:%d+%s*$", ""))
end

--- What a program needs from its platform. The locks come before the work that
--- takes them: `prepare` readies a zeroed mutex, which `lock` and `unlock` hold.
local POSIX_LOCKS = [[
cdef function pthread_mutex_init(borrows mutex: voidptr, attributes: voidptr?): int32
cdef function pthread_mutex_lock(borrows mutex: voidptr): int32
cdef function pthread_mutex_unlock(borrows mutex: voidptr): int32

local function prepare(mutex: voidptr): nil
    pthread_mutex_init(mutex, nil)
end

local function lock(mutex: voidptr): nil
    pthread_mutex_lock(mutex)
end

local function unlock(mutex: voidptr): nil
    pthread_mutex_unlock(mutex)
end
]]

local WINDOWS_LOCKS = [[
cdef function AcquireSRWLockExclusive(borrows lock: voidptr)
cdef function ReleaseSRWLockExclusive(borrows lock: voidptr)

local function prepare(mutex: voidptr): nil
end

local function lock(mutex: voidptr): nil
    AcquireSRWLockExclusive(mutex)
end

local function unlock(mutex: voidptr): nil
    ReleaseSRWLockExclusive(mutex)
end
]]

--- The threads come after the work they run: `spawn` starts `work` on a thread
--- whose handle goes in a slot, and `join` waits for it.
local POSIX_THREADS = [[
cdef function pthread_create(borrows thread: voidptr, attributes: voidptr?, start: function(arg: voidptr): voidptr, borrows arg: voidptr): int32
cdef function pthread_join(thread: uint64, result: voidptr?): int32

local function entry(context: voidptr): voidptr
    work(context as voidptr*)
    return nil
end

local function spawn(slot: voidptr, context: voidptr): boolean
    return pthread_create(slot, nil, entry, context) == 0
end

local function join(slot: voidptr): boolean
    local thread: uint64 = 0
    @unsafe do
        thread = (slot as uint64*)[0]
    end
    return pthread_join(thread, nil) == 0
end
]]

local WINDOWS_THREADS = [[
cdef function CreateThread(attributes: voidptr?, stack: uint64, start: function(arg: voidptr): uint32, borrows arg: voidptr, flags: uint32, id: voidptr?): voidptr?
cdef function WaitForSingleObject(borrows handle: voidptr, milliseconds: uint32): uint32
cdef function CloseHandle(borrows handle: voidptr): int32

local function entry(context: voidptr): uint32
    work(context as voidptr*)
    return 0
end

local function spawn(slot: voidptr, context: voidptr): boolean
    local handle = CreateThread(nil, 0, entry, context, 0, nil)
    if handle == nil then
        return false
    end
    local cell = slot as voidptr*
    @unsafe do
        cell[0] = handle
    end
    return true
end

local function join(slot: voidptr): boolean
    local handle: voidptr? = nil
    @unsafe do
        handle = (slot as voidptr*)[0]
    end
    if handle == nil then
        return false
    end
    local waited = WaitForSingleObject(handle, 4294967295) == 0
    CloseHandle(handle)
    return waited
end
]]

-- Four threads each add to three counters 20000 times: one with an atomic add,
-- one with a compare-exchange loop, and a plain one under a mutex. The exit
-- status says which counter, if any, lost an update.
local MEMORY = [[
cdef function calloc(count: uint64, size: uint64): voidptr
cdef function free(borrows p: voidptr)
]]

local WORK = [[

local function work(context: voidptr*): nil
    @unsafe do
        local added = context[0] as int64*
        local swapped = context[1] as int64*
        local guarded = context[2] as int64*
        local mutex = context[3]
        local expected = calloc(1, 8) as int64*
        for _ = 1, 20000 do
            __atomic_fetch_add_8(added, 1, 0)
            expected[0] = __atomic_load_8(swapped, 0)
            while not __atomic_compare_exchange_8(swapped, expected, expected[0] + 1, 4, 0) do
            end
            lock(mutex)
            guarded[0] = guarded[0] + 1
            unlock(mutex)
        end
        free(expected as voidptr)
    end
end
]]

local MAIN = [[

local function main(argc: int32, argv: cstring*): int32
    @unsafe do
        local context = calloc(4, 8) as voidptr*
        context[0] = calloc(1, 8)
        context[1] = calloc(1, 8)
        context[2] = calloc(1, 8)
        context[3] = calloc(1, 64)
        prepare(context[3])
        __atomic_store_8(context[0] as int64*, 0, 3)
        local slots = calloc(4, 8) as voidptr*
        for i = 0, 3 do
            slots[i] = calloc(1, 16)
            if not spawn(slots[i], context as voidptr) then
                return 10
            end
        end
        for i = 0, 3 do
            if not join(slots[i]) then
                return 11
            end
        end
        if __atomic_load_8(context[0] as int64*, 2) ~= 80000 then
            return 1
        end
        if __atomic_load_8(context[1] as int64*, 5) ~= 80000 then
            return 2
        end
        if (context[2] as int64*)[0] ~= 80000 then
            return 3
        end
    end
    return 0
end
]]

--- The program for the platform this test runs on.
local function threadsProgram()
    local windows = jit.os == "Windows"
    return table.concat({
        ATOMICS,
        MEMORY,
        windows and WINDOWS_LOCKS or POSIX_LOCKS,
        WORK,
        windows and WINDOWS_THREADS or POSIX_THREADS,
        MAIN,
    }, "\n")
end

function M.threadsShareAtomicAndGuardedCounters()
    local available, why = require("nupp.tools.build.aotllvm").selected()
    if available ~= true then
        test.suite.skip("this nupp has no code generator: " .. tostring(why))
    end
    local dir = os.tmpname()
    os.remove(dir)
    assert(os.execute("mkdir -p " .. quote(dir)) == 0)
    local manifest = assert(io.open(dir .. "/nupp.lua", "wb"))
    manifest:write('return {include = {"."}}\n')
    manifest:close()
    local handle = assert(io.open(dir .. "/host.nupp", "wb"))
    handle:write(threadsProgram())
    handle:close()
    local executable = dir .. "/host" .. (jit.os == "Windows" and ".exe" or "")
    local status, output = run(
        ("cd %s && NO_COLOR= %s aot --emit executable --output %s host.nupp"):format(
            quote(dir),
            quote(NUPP),
            quote(executable)
        )
    )
    test.eq(status, 0, output)
    local ran, said = run(quote(executable))
    test.eq(ran, 0, said)
    os.execute("rm -rf " .. quote(dir))
end

return M

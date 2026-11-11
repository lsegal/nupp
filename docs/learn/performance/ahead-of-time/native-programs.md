---
order: 638
---

# Native programs

An `@aot` function is code an already-running LuaJIT host calls into. A native
program is the other way round: a checked Nupp file whose `main` is the
executable's own. It reaches LuaJIT, the C runtime and any other C library
through the `cdef function` declarations beside it, and no Lua state exists
until it makes one.

```nupp
cdef function puts(borrows s: cstring): int32

local function main(): int32
    puts("hello from native Nupp")
    return 0
end
```

```bash
nupp aot --emit executable --output build/hello hello.nupp
./build/hello
```

`--emit executable` checks the file, lowers it to LLVM IR, and compiles and
links it in process with the same code generator `aot = "require"` uses, so no
C compiler or system linker is run. The program is written to exactly the path
`--output` names, so on Windows that path includes `.exe`. A `nupp` built
without the code generator still reports every refusal below, and then refuses
to link.

The program links LuaJIT statically from the platform's link kit, so it needs no
LuaJIT shared library at run time, and it exports the Lua C API the way a
standalone host does.

A project builds the same program from a `kind = "program"` target in
`nupp.lua`, which `nupp build` places under the target's `outDir` and does not
relink while the program is unchanged; see
[Native programs](../../projects/build.md#native-programs) in the build guide.

## The shape of a program

The top level holds only `cdef function` and `cdef struct` declarations,
`const` literals, [module state](#module-state), the
[modules it requires](#programs-that-span-modules) and plain functions. Every
function becomes a C function, so
each parameter and result needs a written C type: `number`, `integer`, `float`,
`boolean`, the fixed-width integers, `cstring`, `voidptr` and typed pointers
such as `int64*`.

`main` takes nothing, or `(argc: int32, argv: cstring*)`, and returns the exit
status as an `int32`:

```nupp
cdef function puts(borrows s: cstring): int32

local function main(argc: int32, argv: cstring*): int32
    if argc < 2 then
        puts("usage: greet NAME")
        return 2
    end
    @unsafe do
        puts(argv[1])
    end
    return 0
end
```

Inside a function you can use locals, `if`, `while`, `repeat`, numeric `for`,
`break`, `return`, calls to the program's own functions and to declared C
functions (variadic ones included), string literals as C strings, `p[i]` reads
and writes through typed pointers, `as` casts between pointer types and between
numeric types, and `@unsafe do` around pointer access.

Arithmetic keeps the language's meaning, not C's. `number` and `integer` are
binary64, and so is arithmetic over the `int32`, `uint32` and `float`
refinements: a value enters those through an establishing call such as
`math.i32.wrap` or `math.f32.narrow`, not through an operator that wraps. `//`
and `%` floor and `/` divides exactly. Only `int64` and `uint64` are
fixed-width, and they wrap as LuaJIT's do. `math.floor`, `math.ceil`,
`math.abs` and `math.sqrt` are lowered in place. The bit operators `&`, `|`,
`~`, `<<`, `>>` and `~>>` are LuaJIT's: numbers meet as 32-bit words and give
the signed word back, and an `int64` or `uint64` operand makes the operation
64-bit.

## Calling into LuaJIT

LuaJIT is just another C library to a native program. Declare the parts of its
API the program uses, and pass a Nupp function wherever C expects a function
pointer. Here `answer` is registered as a `lua_CFunction`:

```nupp
cdef function luaL_newstate(): voidptr
cdef function luaL_openlibs(borrows L: voidptr)
cdef function luaL_loadstring(borrows L: voidptr, source: cstring): int32
cdef function lua_pcall(borrows L: voidptr, nargs: int32, nresults: int32, handler: int32): int32
cdef function lua_pushcclosure(borrows L: voidptr, fn: function(L: voidptr): int32, n: int32)
cdef function lua_pushnumber(borrows L: voidptr, n: number)
cdef function lua_setfield(borrows L: voidptr, index: int32, k: cstring)
cdef function lua_tonumber(borrows L: voidptr, index: int32): number
cdef function lua_close(borrows L: voidptr)

const GLOBALS = -10002

local function answer(L: voidptr): int32
    lua_pushnumber(L, 42)
    return 1
end

local function main(): int32
    local L = luaL_newstate()
    luaL_openlibs(L)
    lua_pushcclosure(L, answer, 0)
    lua_setfield(L, GLOBALS, "answer")
    if luaL_loadstring(L, "print('answer is ' .. answer()) return answer() - 40") ~= 0 then
        return 100
    end
    if lua_pcall(L, 0, 1, 0) ~= 0 then
        lua_close(L)
        return 101
    end
    local status = math.i32.wrap(math.floor(lua_tonumber(L, -1)))
    lua_close(L)
    return status
end
```

The program prints `answer is 42` and exits with status 2. Every function
carries unwind tables, so `luaL_error` raised inside a Nupp callback unwinds
through it to the `lua_pcall` that called it.

## Function pointers

A function type such as `function(L: voidptr): int32` is a C function pointer.
A local, a parameter, a struct field or [module state](#module-state) of that
type holds one, and calling it is an indirect call with the declared
signature. A function of the program's own, or a declared C function, is a
pointer of its own type when used as a value. A pointer from anywhere else, such as
the `voidptr` that `dlsym` or `GetProcAddress` returns, is given its type with
`as`. A function type ending in `...` is variadic, and its extra arguments pass
as they would to a variadic C function.

This is how a program binds an API it does not link against directly, at run
time: here `lua_atpanic` hands back the handler it replaces, and module state
holds `luaL_error` to be called later:

```nupp
cdef function luaL_newstate(): voidptr
cdef function luaL_error(borrows L: voidptr, format: cstring, ...): int32
cdef function lua_atpanic(borrows L: voidptr, panicf: function(L: voidptr): int32): function(L: voidptr): int32
cdef function lua_close(borrows L: voidptr)

local raise: function(L: voidptr, format: cstring, ...): int32

local function first(L: voidptr): int32
    return raise(L, "first handler, %d", 1)
end

local function second(L: voidptr): int32
    return 2
end

local function main(): int32
    raise = luaL_error
    local L = luaL_newstate()
    lua_atpanic(L, second)
    local previous = lua_atpanic(L, first)
    local erased = previous as voidptr
    local handler = erased as function(L: voidptr): int32
    local status = handler(L)
    lua_close(L)
    return status
end
```

The program exits with status 2. A function type whose parameters or result
have no C representation, such as a table, is refused where it is called.

## C structs

A `cdef struct` is laid out for the target triple by the same model the
headers from [`nupp export-c`](../../runtime/c-interop/index.md#export-ordinary-structs-to-c)
use. A program reads and writes its fields through a pointer, nested structs
and `p[i]` of a struct included:

```nupp
cdef function calloc(count: uint64, size: uint64): voidptr
cdef function free(borrows p: voidptr)

cdef struct Point
    x: number
    y: number
end

local function main(): int32
    local points = calloc(2, 16) as Point*
    @unsafe do
        points.x = 3
        points[1].y = points.x * 2
        if points[1].y ~= 6 then
            return 1
        end
    end
    free(points as voidptr)
    return 0
end
```

A field is read or written in place, never the whole struct, and a struct does
not pass by value. A `cdef union`, or a struct with a bitfield, is refused where
its fields are read, because the layout model does not place those as C does.

## Module state

A top-level `local` is module state: a global that lives as long as the
program, which every function of its module reads and writes. It holds a
scalar, a pointer or a `cdef struct`. A scalar or pointer starts as a literal,
`nil` or a `const`, and as zero when it has no value; a struct starts zeroed
and has no value written. A struct's name stands for the address of its
storage, so its fields are reached with `.` and it is passed wherever C takes a
pointer to it:

```nupp
cdef struct Totals
    count: int32
    sum: number
end

cdef function memset(s: Totals*, c: int32, n: uint64): voidptr

const FIRST = 1

local calls: int32 = FIRST
local scale: number = 0.5
local last: cstring? = nil
local totals: Totals

local function record(value: number): nil
    calls = math.i32.wrap(calls + 1)
    totals.count = math.i32.wrap(totals.count + 1)
    totals.sum += value * scale
    last = "recorded"
end

local function main(): int32
    memset(totals, 0, 16)
    record(4)
    record(6)
    if last == nil then
        return 1
    end
    return math.i32.wrap(math.floor(totals.sum) + calls)
end
```

The program exits with status 8. State is private to its module: two modules
may each have a `count` of their own, and another module reaches one only
through the functions its own module exports.

## Programs that span modules

A program module can `require` other modules, which are native-program
modules themselves, and `nupp aot` and `kind = "program"` targets build the
modules it requires, directly or not, into the one program. A required module
declares itself with `module`, and what it marks `export` is what the modules
requiring it see: its functions, and its `const` literals.

`app/counter.nupp`:

```nupp:fragment
module app.counter

local count: int32 = 0
export const STEP = 2

export function bump(): int32
    count = math.i32.wrap(count + STEP)
    return count
end
```

`host.nupp`:

```nupp:fragment
local counter = require("app.counter")
const {bump, STEP as step} = require("app.counter")

local function main(): int32
    counter.bump()
    return math.i32.wrap(bump() + step)
end
```

`require` binds the module to one name, whose exported members are reached as
`counter.bump`, or selects members with a pattern. Either is written at the top
level, with the module's name as a literal. A function's exports are its
module's; the state behind them stays private, and an export is never
assigned.

An `export function` is also a C symbol under its own name, with external
linkage, where every other function is internal to the program. That is how a
static archive linked into the program, or the code that loads a library, finds
it, so two modules of one program cannot export the same name.

## Libraries

`--emit static-library` writes a static archive, and `--emit shared-library` a
shared library: a `.so`, `.dylib` or `.dll`. Neither needs a `main`. What a
library publishes is its `export function`s:

```nupp:fragment
module runtime

local created: int32 = 0

export function runtime_new(): int32
    created = math.i32.wrap(created + 1)
    return created
end
```

```bash
nupp aot --emit static-library --output build/libruntime.a runtime.nupp
nupp aot --emit shared-library --exports runtime.exports --output build/libruntime.so runtime.nupp
```

A shared library links LuaJIT from the link kit as an executable does. A static
archive holds only the program's own code and is linked by whoever links it, so
it needs no link kit.

`--archive PATH`, repeated for each, links more static archives in whole, such
as a native provider's archive: into an executable or shared library, or
merged into a static archive. A program declares what it calls in one with
`cdef function`, as for any C library.

`--exports PATH` names a file listing every symbol an executable or shared
library exports, one per line, with `#` comments and blank lines skipped.
Nothing it leaves out is exported, LuaJIT's API included. The list is handed to
each platform's linker in its own form: a version script on Linux, an
exported-symbols list on macOS, and a module definition file on Windows.
Without one, a shared library exports everything it defines, and an executable
what a standalone host does.

## Threads and atomics

A native program starts OS threads with its platform's own functions, passing
a Nupp function as the entry: `pthread_create` and `pthread_join` on Linux and
macOS, `CreateThread` and `WaitForSingleObject` on Windows. Mutexes and
condition variables are reached the same way (`pthread_mutex_*` and
`pthread_cond_*`, or SRW locks and `CONDITION_VARIABLE`). There is no thread
runtime of Nupp's own.

```nupp
cdef function calloc(count: uint64, size: uint64): voidptr
cdef function free(borrows p: voidptr)
cdef function pthread_create(borrows thread: voidptr, attributes: voidptr?, start: function(arg: voidptr): voidptr?, borrows arg: voidptr): int32
cdef function pthread_join(thread: uint64, result: voidptr?): int32
cdef function __atomic_fetch_add_8(borrows p: int64*, v: int64, order: int32): int64
cdef function __atomic_load_8(borrows p: int64*, order: int32): int64

local function count(context: voidptr): voidptr?
    local counter = context as int64*
    for _ = 1, 10000 do
        -- 0 is a relaxed add: only the total matters.
        __atomic_fetch_add_8(counter, 1, 0)
    end
    return nil
end

local function main(): int32
    local counter = calloc(1, 8) as int64*
    local threads = calloc(4, 8) as voidptr*
    @unsafe do
        for i = 0, 3 do
            threads[i] = calloc(1, 8)
            if pthread_create(threads[i], nil, count, counter as voidptr) ~= 0 then
                return 10
            end
        end
        for i = 0, 3 do
            pthread_join((threads[i] as uint64*)[0], nil)
            free(threads[i])
        end
    end
    -- 2 is an acquire load, after every thread has been joined.
    local total = __atomic_load_8(counter, 2)
    free(threads as voidptr)
    free(counter as voidptr)
    if total ~= 40000 then
        return 1
    end
    return 0
end
```

Atomics are the one part a C program gets from its compiler rather than a
library, so a native program declares libatomic's sized functions and the
backend lowers each call in place to LLVM's atomic instructions, the way a C
compiler handles its `__atomic` builtins. No libatomic is linked.

- `__atomic_load_N` and `__atomic_store_N` become atomic loads and stores.
- `__atomic_exchange_N` and `__atomic_fetch_add_N`, `_sub_`, `_and_`, `_or_`,
  `_xor_` and `_nand_` become `atomicrmw`.
- `__atomic_compare_exchange_N` becomes `cmpxchg`. On failure it writes the
  value it found back through `expected`, as in C.

`N` is 1, 2, 4 or 8. The order arguments are GCC's constants, from 0 (relaxed)
through 5 (sequentially consistent), written as number literals. Any other
expression, a named `const` included, is sequentially consistent, as in C. An
order the access cannot have, such as a release load, is refused. So is a
declaration whose shape differs from libatomic's, and an operation libatomic
does not have, such as `fetch_min`.

## What a program cannot do

There is no Lua state to fall back to, so anything outside the subset above is
refused where it was written, as `file:line:col: native: ...`, before anything
is compiled. That includes tables, closures and Lua strings as values, string
concatenation, methods, several results, destructuring, numeric truthiness (a
condition is a boolean or a pointer), and `^` over 64-bit integers.

## Exporting Nupp functions to C

A C program, rather than a Nupp one, can also call compiled Nupp code. An
`@aot(export = "name")` function is defined under that C name in the target's
AOT library, and `nupp export-c` writes its prototype into a header. See
[export functions to C](../../runtime/c-interop/index.md#export-functions-to-c).

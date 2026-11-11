local testAssert = require("assert")
local cdecl = require("nupp.compiler.cinterop.cdecl")
local ffi = require("ffi")

local M = {}

function M.inspectionReturnsNeutralDeclarations()
    local parsed, err = cdecl.inspect(
        table.concat(
            {
                "struct NuppCdeclPoint { double x; double y; };",
                "void nuppCdeclVisit(void (*visit)(int), unsigned long n);",
            },
            "\n"
        )
    )
    assert(parsed, err)
    testAssert.eq(#parsed.structs, 1)
    testAssert.eq(parsed.structs[1].name, "NuppCdeclPoint")
    testAssert.eq(parsed.structs[1].fields[1].type.kind, "float")
    testAssert.eq(#parsed.functions, 1)
    local callback = parsed.functions[1].params[1].type
    testAssert.eq(callback.kind, "pointer")
    testAssert.eq(callback.to.kind, "function")
    testAssert.eq(callback.to.params[1].type.bits, 32)
end

function M.fixedArraysPreserveTheirRecursiveCounts()
    local parsed, err = cdecl.inspect("struct NuppCdeclArrays { int values[4]; float matrix[2][3]; };")
    assert(parsed, err)
    local fields = parsed.structs[1].fields
    testAssert.eq(fields[1].type.kind, "array")
    testAssert.eq(fields[1].type.count, 4)
    testAssert.eq(fields[1].type.of.bits, 32)
    testAssert.eq(fields[2].type.count, 2)
    testAssert.eq(fields[2].type.of.count, 3)
    testAssert.eq(fields[2].type.of.of.bits, 32)
end

function M.typedefNamedAnonymousAggregatesUseTheTypedefIdentity()
    local parsed, err = cdecl.inspect("typedef struct { float x; float y; } NuppCdeclAnonPoint;")
    assert(parsed, err)
    testAssert.eq(#parsed.structs, 1)
    testAssert.eq(parsed.structs[1].name, "NuppCdeclAnonPoint")
    testAssert.eq(parsed.structs[1].kind, "struct")
    testAssert.eq(parsed.structs[1].fields[2].name, "y")
end

function M.preludeTypesAreNotExported()
    local parsed, err = cdecl.inspect(
        "struct NuppCdeclOwned { NuppCdeclPrelude *value; };",
        "typedef struct NuppCdeclPrelude NuppCdeclPrelude;"
    )
    assert(parsed, err)
    testAssert.eq(#parsed.structs, 1)
    testAssert.eq(parsed.structs[1].name, "NuppCdeclOwned")
end

function M.targetDefinitionsCompletePreludeForwardDeclarations()
    local parsed, err = cdecl.inspect("struct NuppCdeclForwardTarget { int value; };", "struct NuppCdeclForwardTarget;")
    assert(parsed, err)
    testAssert.eq(#parsed.structs, 1)
    testAssert.eq(parsed.structs[1].name, "NuppCdeclForwardTarget")
    testAssert.eq(parsed.structs[1].fields[1].name, "value")
end

function M.registryEntriesBeyondTheOldCeilingAreVisible()
    local padding = {}
    for index = 1, 4100 do
        padding[index] = ("struct NuppCdeclPadding%d { int value; };"):format(index)
    end
    ffi.cdef(table.concat(padding, "\n"))
    assert(
        tonumber(ffi.typeof("struct NuppCdeclPadding4100")) > 8192,
        "the fixture reaches beyond the former registry ceiling"
    )

    local parsed, err = cdecl.inspect("int nuppCdeclAfterPadding(int value);")
    assert(parsed, err)
    testAssert.eq(#parsed.functions, 1)
    testAssert.eq(parsed.functions[1].name, "nuppCdeclAfterPadding")
end

function M.enumMembersComeBackInDeclarationOrder()
    local parsed, err = cdecl.inspect(
        table.concat(
            {
                "enum NuppCdeclStatus { NUPP_CDECL_OK = 0, NUPP_CDECL_LAST = 7 };",
                "typedef enum { NUPP_CDECL_ANON = 3 } NuppCdeclAnon;",
            },
            "\n"
        )
    )
    assert(parsed, err)
    testAssert.eq(#parsed.enums, 2)
    testAssert.eq(parsed.enums[1].name, "NuppCdeclStatus")
    testAssert.eq(parsed.enums[1].values[1].name, "NUPP_CDECL_OK")
    testAssert.eq(parsed.enums[1].values[1].value, 0)
    testAssert.eq(parsed.enums[1].values[2].name, "NUPP_CDECL_LAST")
    testAssert.eq(parsed.enums[1].values[2].value, 7)
    -- an anonymous enum has no name of its own and its members still count
    testAssert.eq(parsed.enums[2].name, nil)
    testAssert.eq(parsed.enums[2].values[1].name, "NUPP_CDECL_ANON")
    testAssert.eq(parsed.enums[2].values[1].value, 3)
end

function M.negativeEnumMembersAreReadBack()
    -- LuaJIT keeps the value where -1 means "no size", so it cannot be read
    -- from the entry alone.
    local parsed, err = cdecl.inspect("enum NuppCdeclSigned { NUPP_CDECL_ERR = -1, NUPP_CDECL_NONE = 0 };")
    assert(parsed, err)
    testAssert.eq(parsed.enums[1].values[1].value, -1)
    testAssert.eq(parsed.enums[1].values[2].value, 0)
end

function M.anUnusablePreludeEntryCostsOnlyItself()
    -- A system header's vocabulary is a chain, and a link this reader cannot
    -- spell must not take the declarations that do not need it with it.
    local parsed, err = cdecl.inspect("struct NuppCdeclKept { int n; };", {
        "typedef struct NuppCdeclNoSuchThing *NuppCdeclFine;",
        "typedef __nupp_cdecl_never_declared_t NuppCdeclBroken;"
    })
    assert(parsed, err)
    testAssert.eq(#parsed.structs, 1)
    testAssert.eq(parsed.structs[1].name, "NuppCdeclKept")
end

function M.aRejectedDeclarationIsSetAsideNotFatal()
    local parsed, err = cdecl.inspect({
        "struct NuppCdeclOpaque;",
        "struct NuppCdeclUnsized { struct NuppCdeclOpaque inner; };",
        "int nuppCdeclSurvives(int a);",
    })
    assert(parsed, err)
    testAssert.eq(#parsed.rejected, 1)
    testAssert.eq(parsed.declared, 3)
    testAssert.eq(#parsed.functions, 1)
    testAssert.eq(parsed.functions[1].name, "nuppCdeclSurvives")
    assert(parsed.rejected[1].reason:find("size", 1, true), "the reason travels with it: " .. parsed.rejected[1].reason)
end

function M.oneBlobIsStillTakenOrLeftWhole()
    -- What a `cheader` pins is not a subset: a header that will not parse is
    -- the answer, and quietly typing part of it would be the wrong one.
    local parsed = cdecl.inspect("struct NuppCdeclWhole { struct NuppCdeclNeverDefined inner; };")
    testAssert.eq(parsed, nil)
end

function M.membersWithoutANameAreCountedNotDropped()
    local parsed, err = cdecl.inspect(
        table.concat(
            {
                "struct NuppCdeclAnonMember { int tag; union { int i; double d; }; int after; };",
                "struct NuppCdeclPadding { unsigned a : 3; unsigned : 0; unsigned b : 3; unsigned : 5; };",
            },
            "\n"
        )
    )
    assert(parsed, err)
    local byName = {}
    for _, declaration in ipairs(parsed.structs) do
        byName[declaration.name] = declaration
    end
    testAssert.eq(byName.NuppCdeclAnonMember.anonymous, 1, "anonymous members")
    testAssert.eq(#byName.NuppCdeclAnonMember.fields, 2, "named fields")
    testAssert.eq(byName.NuppCdeclAnonMember.size, ffi.sizeof(cdecl.checked("struct NuppCdeclAnonMember")))
    testAssert.eq(byName.NuppCdeclPadding.unnamed, 2, "unnamed bitfields")
    testAssert.eq(byName.NuppCdeclPadding.fields[2].bitPos, 0, "b starts the unit the zero-width field opened")
    testAssert.eq(byName.NuppCdeclPadding.fields[2].offset, 4)
end

function M.vectorAndComplexTypesAreNotArrays()
    local parsed, err = cdecl.inspect(
        table.concat(
            {
                "typedef float nupp_cdecl_v4 __attribute__((vector_size(16)));",
                "nupp_cdecl_v4 nuppCdeclVector(double _Complex z);",
            },
            "\n"
        )
    )
    assert(parsed, err)
    local fn = parsed.functions[1]
    testAssert.eq(fn.returns.kind, "vector")
    testAssert.eq(fn.params[1].type.kind, "complex")
end

function M.aBoolBitfieldIsABoolean()
    local parsed, err = cdecl.inspect("struct NuppCdeclFlags { bool on : 1; int level : 4; };")
    assert(parsed, err)
    local fields = parsed.structs[1].fields
    testAssert.eq(fields[1].type.kind, "boolean")
    testAssert.eq(fields[1].bitWidth, 1)
    testAssert.eq(fields[2].type.kind, "integer")
end

function M.layoutAnswersForAMemberList()
    local layout = assert(cdecl.layout("struct", "uint8_t kind; uint32_t len; uint16_t a : 3;"))
    testAssert.eq(layout.size, 12)
    testAssert.eq(layout.align, 4)
    testAssert.eq(layout.fields[2].offset, 4)
    testAssert.eq(layout.fields[3].bitWidth, 3)
    local packed = cdecl.inspect("struct __attribute__((packed)) NuppCdeclPacked { uint8_t kind; uint32_t len; };")
    testAssert.eq(packed.structs[1].size, 5, "an attribute LuaJIT reads is laid out by")
    testAssert.eq(packed.structs[1].fields[2].offset, 1)
end

function M.eachDeclarationKnowsWhichUnitIntroducedIt()
    local parsed, err = cdecl.inspect({
        "int nuppCdeclUnitOne(void);",
        "struct NuppCdeclUnitTwo { int x; };",
        "struct NuppCdeclUnitBroken { struct NuppCdeclUnitNever inner; };",
    })
    assert(parsed, err)
    testAssert.eq(parsed.functions[1].unit, 1)
    testAssert.eq(parsed.structs[1].unit, 2)
    testAssert.eq(parsed.rejected[1].unit, 3)
end

-- A checked program declares under names of its own, so a runtime module that declares
-- the same name later gets the shape it wrote. LuaJIT ignores a typedef of a name it
-- already holds, which used to hand the runtime whatever the checker reached first.
function M.aCheckedTypedefLeavesTheRuntimeItsOwnShape()
    local ok, err = cdecl.declare("typedef struct { int32_t checked; } NuppCdeclShadowed;")
    assert(ok, err)
    ffi.cdef("typedef struct { int64_t pid; int32_t status; } NuppCdeclShadowed;")
    local value = ffi.new("NuppCdeclShadowed")
    value.pid = 7
    testAssert.eq(tonumber(value.pid), 7)
    testAssert.eq(ffi.sizeof("NuppCdeclShadowed"), 16)
    -- and the checked program still reads its own
    local model = assert(cdecl.typeFromString(cdecl.checked("NuppCdeclShadowed")))
    local declaration = assert(cdecl.structById(model.id))
    testAssert.eq(#declaration.fields, 1)
    testAssert.eq(declaration.fields[1].name, "checked")
end

function M.aCheckedTagLeavesTheRuntimeFreeToDefineIt()
    local ok, err = cdecl.declare("struct NuppCdeclShadowTag { int32_t checked; };")
    assert(ok, err)
    -- redefining a tag LuaJIT holds raises, so this used to fail outright
    ffi.cdef("struct NuppCdeclShadowTag { double runtime; };")
    testAssert.eq(ffi.sizeof("struct NuppCdeclShadowTag"), 8)
    local model = assert(cdecl.typeFromString(cdecl.checked("struct NuppCdeclShadowTag")))
    testAssert.eq(model.name, "NuppCdeclShadowTag", "read back under the name the program spelled")
    testAssert.eq(assert(cdecl.structById(model.id)).fields[1].name, "checked")
end

function M.everyNameACheckedBlockDeclaresIsItsOwn()
    local ok, err, names = cdecl.declare(table.concat({
        "typedef int (*NuppCdeclOwnCallback)(int code);",
        "typedef struct NuppCdeclOwnNode NuppCdeclOwnNode;",
        "struct NuppCdeclOwnNode { NuppCdeclOwnNode *next; struct NuppCdeclOwnInner { int x; } inner; };",
        "enum { NUPP_CDECL_OWN_A = 3, NUPP_CDECL_OWN_B };",
        "static const int NUPP_CDECL_OWN_LIMIT = 4;",
        'int nuppCdeclOwnVisit(NuppCdeclOwnNode *node, NuppCdeclOwnCallback callback) __asm__("visit");',
    }, "\n"))
    assert(ok, err)
    testAssert.eq(names.nuppCdeclOwnVisit, true, "functions come back under their own names")
    for _, spec in ipairs({
        "NuppCdeclOwnCallback",
        "NuppCdeclOwnNode",
        "struct NuppCdeclOwnNode",
        "struct NuppCdeclOwnInner",
        "NUPP_CDECL_OWN_B",
        "NUPP_CDECL_OWN_LIMIT",
    }) do
        assert(cdecl.checked(spec) ~= spec, spec .. " is the checked program's")
    end
    -- what the program uses but does not declare keeps meaning what the process holds
    testAssert.eq(cdecl.checked("uint32_t *"), "uint32_t *")
    local visit = cdecl.declaredFunctions(names).nuppCdeclOwnVisit
    testAssert.eq(visit.params[1].type.to.name, "NuppCdeclOwnNode")
    -- the runtime can still declare every one of those names itself
    ffi.cdef(table.concat({
        "typedef double NuppCdeclOwnCallback;",
        "struct NuppCdeclOwnNode { double runtime; };",
        "struct NuppCdeclOwnInner { double runtime; };",
        "enum { NUPP_CDECL_OWN_A = 9 };",
    }, "\n"))
    testAssert.eq(ffi.sizeof("NuppCdeclOwnCallback"), 8)
    testAssert.eq(ffi.sizeof("struct NuppCdeclOwnInner"), 8)
    testAssert.eq(ffi.C.NUPP_CDECL_OWN_A, 9)
end

-- A pinned header and its prelude declare under checked names too, so a runtime module
-- that declares one of the same names afterwards gets the shape it wrote (#153).
function M.aHeaderTypedefLeavesTheRuntimeItsOwnShape()
    local parsed = assert(cdecl.inspect(
        table.concat({
            "typedef struct { int32_t header; } NuppCdeclHeaderShadowed;",
            "void nupp_cdecl_header_use(NuppCdeclHeaderShadowed *p, NuppCdeclPreludeShadowed q);",
        }, "\n"),
        "typedef int8_t NuppCdeclPreludeShadowed;"
    ))
    -- the header still reads under the names it spelled
    testAssert.eq(#parsed.structs, 1)
    testAssert.eq(parsed.structs[1].name, "NuppCdeclHeaderShadowed")
    testAssert.eq(parsed.structs[1].fields[1].name, "header")
    testAssert.eq(#parsed.functions, 1)
    testAssert.eq(parsed.functions[1].name, "nupp_cdecl_header_use")
    testAssert.eq(parsed.functions[1].params[2].type.bits, 8)
    ffi.cdef("typedef struct { int64_t pid; int32_t status; } NuppCdeclHeaderShadowed;")
    ffi.cdef("typedef double NuppCdeclPreludeShadowed;")
    local value = ffi.new("NuppCdeclHeaderShadowed")
    value.pid = 7
    testAssert.eq(tonumber(value.pid), 7)
    testAssert.eq(ffi.sizeof("NuppCdeclHeaderShadowed"), 16)
    testAssert.eq(ffi.sizeof("NuppCdeclPreludeShadowed"), 8)
    -- and a checked program still reads the header's
    local model = assert(cdecl.typeFromString(cdecl.checked("NuppCdeclHeaderShadowed")))
    testAssert.eq(assert(cdecl.structById(model.id)).fields[1].name, "header")
    testAssert.eq(cdecl.sizeof(cdecl.checked("NuppCdeclPreludeShadowed")), 1)
end

function M.aHeaderTagLeavesTheRuntimeFreeToDefineIt()
    local parsed = assert(cdecl.inspect({"struct NuppCdeclHeaderTag { int32_t header; };"}))
    testAssert.eq(#parsed.rejected, 0)
    testAssert.eq(parsed.structs[1].name, "NuppCdeclHeaderTag")
    -- redefining a tag LuaJIT holds raises, so this used to fail outright
    ffi.cdef("struct NuppCdeclHeaderTag { double runtime; };")
    testAssert.eq(ffi.sizeof("struct NuppCdeclHeaderTag"), 8)
    local layout = assert(cdecl.layout("struct", "struct NuppCdeclHeaderTag inner;"))
    testAssert.eq(layout.size, 4, "a layout check reads the header's tag")
end

-- Importing a header that was already pinned meets its own declarations under the
-- checked names, and claims them back rather than the runtime's.
function M.aHeaderMetTwiceIsStillItsOwn()
    local text = table.concat({
        "struct NuppCdeclTwice { int16_t header; };",
        "int nupp_cdecl_twice(struct NuppCdeclTwice *p);",
    }, "\n")
    assert(cdecl.inspect(text))
    ffi.cdef("struct NuppCdeclTwice { double runtime; }; int nupp_cdecl_twice(double x);")
    local parsed = assert(cdecl.inspect({
        "struct NuppCdeclTwice { int16_t header; };",
        "int nupp_cdecl_twice(struct NuppCdeclTwice *p);",
    }))
    testAssert.eq(#parsed.structs, 1)
    testAssert.eq(parsed.structs[1].fields[1].name, "header")
    testAssert.eq(#parsed.functions, 1)
    testAssert.eq(parsed.functions[1].params[1].type.kind, "pointer")
end

return M

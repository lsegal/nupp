-- The numeric-contract checks, the codegen options and the report, which run
-- in the compiler over what the code generator returns.

local codegen = require("nupp.compiler.aot.llvm.codegen")
local contract = require("nupp.compiler.aot.llvm.contract")

local M = {}

local IR = [[
define void @plain(ptr %a) #0 {
  %x = fmul nnan double 1.0, 2.0
  %y = fadd reassoc double %x, 1.0
  ret void
}
define double @sum(<4 x double> %v) #1 {
  %r = call reassoc double @llvm.vector.reduce.fadd.v4f64(double -0.0, <4 x double> %v)
  ret double %r
}
define double @relaxed(double %a, double %b, double %c) #2 {
  %r = call double @llvm.fmuladd.f64(double %a, double %b, double %c)
  %s = fmul contract double %r, %a
  ret double %s
}
attributes #0 = { nounwind }
attributes #1 = { nounwind "nupp-algebraic" }
attributes #2 = { "nupp-fp-contract" }
]]

function M.licencesFollowAttributes()
    local bad = contract.ir(IR)
    assert(#bad == 1, table.concat(bad, "\n"))
    assert(bad[1]:find("^plain:"), bad[1])
    assert(bad[1]:find("`reassoc` outside its licence", 1, true), bad[1])
end

function M.fusedMultiplyAddNeedsTheContractLicence()
    local ir = IR:gsub('attributes #2 = { "nupp%-fp%-contract" }', "attributes #2 = { nounwind }")
    local bad = contract.ir(ir)
    local fused, flagged = false, false
    for _, line in ipairs(bad) do
        fused = fused or line:find("^relaxed: fused multiply%-add outside an fp%-contract function") ~= nil
        flagged = flagged or line:find("^relaxed: `contract` outside its licence") ~= nil
    end
    assert(fused and flagged, table.concat(bad, "\n"))
end

function M.quotedNamesAndInlineAttributesAreRead()
    local ir = table.concat(
        {
            'define double @"with.dots"(double %a) "nupp-fp-contract" {',
            "  %r = call double @llvm.fma.f64(double %a, double %a, double %a)",
            "  ret double %r",
            "}",
        },
        "\n"
    )
    local bad = contract.ir(ir)
    assert(#bad == 0, table.concat(bad, "\n"))
    local asm = '"with.dots":\n\tvfmadd231sd %xmm1, %xmm0, %xmm2\n'
    assert(#contract.fusedInstructions(asm, ir) == 1, "a quoted label is not a function name")
    asm = "_with.dots:\n\tvfmadd231sd %xmm1, %xmm0, %xmm2\n"
    assert(#contract.fusedInstructions(asm, ir) == 0)
end

function M.fusedInstructionsOutsideContractFunctions()
    local asm = "_plain:\n\tfmadd d0, d0, d1, d2\n\tret\n_relaxed:\n\tfmadd d0, d0, d1, d2\n"
    local bad = contract.fusedInstructions(asm, IR)
    assert(#bad == 1, table.concat(bad, "\n"))
    assert(bad[1] == "plain: fmadd d0, d0, d1, d2", bad[1])
end

function M.localLabelsStayInTheirFunction()
    local asm = table.concat(
        {
            "_plain:",
            "LBB0_1:",
            ".Ltmp0:",
            "ltmp1:",
            "\tvfmadd213pd %ymm2, %ymm1, %ymm0",
            "_relaxed:",
            "\tf64x2.relaxed_madd",
            "",
        },
        "\r\n"
    )
    local bad = contract.fusedInstructions(asm, IR)
    assert(#bad == 1, table.concat(bad, "\n"))
    assert(bad[1] == "plain: vfmadd213pd %ymm2, %ymm1, %ymm0", bad[1])
end

function M.optionsParseKeyValueLines()
    local options = assert(
        codegen.parseOptions(
            "  triple=x86_64-unknown-linux-gnu\n\ncpu=x86-64-v3\nfeatures=+avx2,+fma\nopt=2\nassembly=1\noptimized-ir=true\nverify=0\n"
        )
    )
    assert(options.triple == "x86_64-unknown-linux-gnu")
    assert(options.cpu == "x86-64-v3")
    assert(options.features == "+avx2,+fma")
    assert(options.opt == 2)
    assert(options.assembly == true)
    assert(options.optimizedIr == true)
    assert(options.verify == false)
    local defaults = assert(codegen.parseOptions("triple=wasm32-unknown-unknown"))
    assert(defaults.opt == 3 and defaults.cpu == "" and not defaults.assembly and not defaults.verify)
end

function M.optionsRefuseWhatTheyDoNotKnow()
    local cases = {
        {"triple=t\nwhat=1", "unknown codegen option `what`"},
        {"triple=t\nopt=4", "codegen opt `4` is not 0-3"},
        {"triple=t\nopt=-1", "codegen opt `-1` is not 0-3"},
        {"triple=t\nopt=", "codegen opt `` is not 0-3"},
        {"triple=t\nverify", "codegen option `verify` has no `=`"},
        {"cpu=generic", "codegen options name no triple"},
        {"", "codegen options name no triple"},
    }
    for _, case in ipairs(cases) do
        local options, err = codegen.parseOptions(case[1])
        assert(options == nil, case[1])
        assert(err == case[2], ("%q: %s"):format(case[1], tostring(err)))
    end
end

function M.compileRefusesBadOptionsBeforeTheProvider()
    local compiled, err = codegen.compile("", "bad", {triple = "t", opt = "9"})
    assert(compiled == nil)
    assert(tostring(err):find("codegen opt `9` is not 0-3", 1, true), tostring(err))
end

-- A prebuilt code generator that cannot be opened is refused with its path,
-- and is not taken up in place of the one this process already reaches.
function M.aPrebuiltCodeGeneratorThatCannotBeLoadedIsRefused()
    local available = codegen.available()
    local missing = "/nonexistent/nupp-prebuilt/libnupp_codegen.so"
    local err = codegen.useLibrary(missing)
    assert(err and err:find("cannot load the code generator " .. missing, 1, true), tostring(err))
    assert(codegen.available() == available, "a refused prebuilt changed whether the code generator is available")
end

function M.reportListsTimingsThenViolations()
    local report = codegen.report({12.4, 3.6, 1000}, 42, {"plain: one", "two\nlines"})
    assert(
        report == "parse-us=12\noptimize-us=4\ncodegen-us=1000\nobject-bytes=42\n"
        .. "violation=plain: one\nviolation=two lines\n",
        report
    )
    assert(codegen.report({}, 0, {}) == "parse-us=0\noptimize-us=0\ncodegen-us=0\nobject-bytes=0\n")
end

local KERNEL = [[
define void @scale(ptr noalias %out, ptr noalias readonly %in, i64 %n) #0 {
entry:
  br label %loop
loop:
  %i = phi i64 [ 0, %entry ], [ %next, %body ]
  %done = icmp uge i64 %i, %n
  br i1 %done, label %exit, label %body
body:
  %p = getelementptr inbounds nuw double, ptr %in, i64 %i
  %x = load double, ptr %p, align 8
  %m = fmul double %x, 1.25
  %y = fadd double %m, -0.5
  %q = getelementptr inbounds nuw double, ptr %out, i64 %i
  store double %y, ptr %q, align 8
  %next = add nuw i64 %i, 1
  br label %loop
exit:
  ret void
}
attributes #0 = { nounwind }
]]

-- Where the host carries LLVM, a real compile verifies clean on every target:
-- the optimizer must not fuse the multiply and add on its own.
-- A target machine the heap placed at the end of its region is searched only
-- up to that end: reading the whole window there faulted (#219).
function M.theOptionsSearchStopsWhereTheMappingDoes()
    local ffi = require("ffi")
    if ffi.os ~= "Windows" then
        assert(codegen.mappedWindow(ffi.new("uint8_t[1]")) == 2048)
        return
    end
    pcall(ffi.cdef, [[
void *llvmcontract_VirtualAlloc(void *address, size_t size, uint32_t type, uint32_t protect) __asm__("VirtualAlloc");
int llvmcontract_VirtualFree(void *address, size_t size, uint32_t type) __asm__("VirtualFree");
]])
    -- One committed page, with only reserved address space after it.
    local page = ffi.cast("uint8_t *", ffi.C.llvmcontract_VirtualAlloc(nil, 4096, 0x3000, 4))
    assert(page ~= nil, "VirtualAlloc failed")
    local whole, last = codegen.mappedWindow(page), codegen.mappedWindow(page + 4096 - 100)
    ffi.C.llvmcontract_VirtualFree(page, 0, 0x8000)
    assert(whole == 2048, "a machine with room after it is searched across the whole window, not " .. whole)
    assert(last == 100, "a machine 100 bytes from the end of its region is searched over 100 bytes, not " .. last)
end

function M.compiledKernelsVerifyCleanWhereLlvmIsLinked()
    if not codegen.available() then
        return
    end
    for _, triple in ipairs({
        "arm64-apple-macosx11.0.0",
        "x86_64-unknown-linux-gnu",
        "x86_64-w64-windows-gnu",
        "wasm32-unknown-unknown",
    }) do
        local options = {triple = triple, opt = "3", verify = "1", assembly = "1"}
        if triple:find("^x86_64") then
            options.features = "+avx2,+fma"
        end
        local compiled = assert(codegen.compile(KERNEL, "scale", options))
        assert(#compiled.object > 0, triple)
        assert(compiled.assembly ~= nil, triple)
        assert(compiled.optimizedIr == nil, triple .. ": the optimized IR was not asked for")
        assert(compiled.report:find("object%-bytes=%d+\n$"), triple .. ": " .. compiled.report)
    end
end

local FUSIBLE = [[
define double @blessed(double %a, double %b, double %c) #0 {
  %r = call double @llvm.fmuladd.f64(double %a, double %b, double %c)
  ret double %r
}
define double @flagged(double %a, double %b, double %c) #0 {
  %m = fmul contract double %a, %b
  %r = fadd contract double %m, %c
  ret double %r
}
attributes #0 = { nounwind }
]]

-- The functions of an assembly listing, each with its own lines.
local function functionsOf(assembly)
    local bodies, current = {}, nil
    for line in assembly:gmatch("[^\n]+") do
        local label = line:match("^_?([%w_]+):")
        if label == "blessed" or label == "flagged" then
            current = label
            bodies[current] = ""
        elseif current then
            bodies[current] = bodies[current] .. line .. "\n"
        end
    end

    return bodies
end

-- Fusion is strict: `llvm.fmuladd` alone is not licence to form a fused
-- multiply-add, which LLVM's default mode would take it as. An instruction's
-- own `contract` flag still is, so the target demonstrably could fuse both.
function M.onlyContractFlagsFuseAMultiplyAdd()
    if not codegen.available() then
        return
    end
    for triple, fused in pairs({["x86_64-unknown-linux-gnu"] = "vfmadd", ["arm64-apple-macosx11.0.0"] = "fmadd"}) do
        local options = {triple = triple, opt = "3", assembly = "1"}
        if triple:find("^x86_64") then
            options.features = "+avx2,+fma"
        end
        local compiled = assert(codegen.compile(FUSIBLE, "fusible", options))
        local bodies = functionsOf(compiled.assembly)
        assert(bodies.blessed and bodies.flagged, triple .. ": no listing of both functions:\n" .. compiled.assembly)
        assert(not bodies.blessed:find(fused, 1, true), triple .. ": fmuladd was fused:\n" .. bodies.blessed)
        assert(bodies.flagged:find(fused, 1, true), triple .. ": contract flags were not fused:\n" .. bodies.flagged)
    end
end

function M.invalidIrIsAnErrorNotAnAbort()
    if not codegen.available() then
        return
    end
    local compiled, err = codegen.compile("define void @f() { ret i32 1 }", "bad", {triple = "x86_64-unknown-linux-gnu"})
    assert(compiled == nil)
    assert(tostring(err):find("bad", 1, true), tostring(err))
end

local function scratch(suffix)
    return require("nupp.compiler.process").tmpname() .. suffix
end

local function contents(path)
    local file = io.open(path, "rb")
    if not file then
        return nil
    end
    local text = file:read("*a")
    file:close()

    return text
end

local function writeTo(path, text)
    local file = assert(io.open(path, "wb"))
    file:write(text)
    file:close()
end

-- An ELF object of the kernel, written to a scratch file.
local function kernelObject()
    local compiled = assert(codegen.compile(KERNEL, "scale", {triple = "x86_64-unknown-linux-gnu"}))
    local path = scratch(".o")
    writeTo(path, compiled.object)

    return path
end

-- lld runs in process, more than once in one process, and a failed link
-- answers with what lld printed rather than ending nupp.
function M.lldLinksAndReportsWhatItPrinted()
    if not codegen.available() then
        return
    end
    local object = kernelObject()
    local missing = scratch(".absent.o")
    for _ = 1, 2 do
        local output = scratch(".so")
        local messages, err = codegen.link({"ld.lld", "-shared", object, "-o", output})
        assert(messages, tostring(err))
        assert(contents(output):sub(1, 4) == "\127ELF", "lld wrote no shared object")
        os.remove(output)
    end
    local messages, err = codegen.link({"ld.lld", missing, "-o", scratch(".so")})
    assert(messages == nil, "a link of a missing object succeeded")
    assert(tostring(err):find("lld exited 1", 1, true), tostring(err))
    assert(tostring(err):find(missing, 1, true), tostring(err))
    os.remove(object)
end

-- An archive is indexed by the members' definitions, and deterministic: the
-- same members give the same bytes.
function M.archivesAreIndexedAndDeterministic()
    if not codegen.available() then
        return
    end
    local object = kernelObject()
    for _, format in ipairs({"gnu", "darwin"}) do
        local first, second = scratch(".a"), scratch(".a")
        assert(codegen.archive(first, {object}, format) == nil)
        assert(codegen.archive(second, {object}, format) == nil)
        local bytes = assert(contents(first))
        assert(bytes:sub(1, 8) == "!<arch>\n", format .. ": not an archive")
        assert(bytes == contents(second), format .. ": the same member gave different bytes")
        local index = format == "gnu" and "/               " or "__.SYMDEF"
        assert(bytes:find(index, 1, true), format .. ": the archive has no symbol index")
        assert(bytes:find("scale\0", 1, true), format .. ": the index does not name the kernel")
        os.remove(first)
        os.remove(second)
    end
    local missing = scratch(".absent.o")
    local err = codegen.archive(scratch(".a"), {missing}, "gnu")
    assert(err and err:find(missing, 1, true), tostring(err))
    os.remove(object)
end

-- An import library names its DLL and imports each name through `__imp_`.
function M.importLibrariesNameEveryExport()
    if not codegen.available() then
        return
    end
    local path = scratch(".a")
    local err = codegen.importLibrary("kernel32.dll", path, {{"GetCurrentProcess"}, {"TerminateProcess"}})
    assert(err == nil, tostring(err))
    local bytes = assert(contents(path))
    assert(bytes:sub(1, 8) == "!<arch>\n", "not an archive")
    for _, name in ipairs({"kernel32.dll", "__imp_GetCurrentProcess", "__imp_TerminateProcess"}) do
        assert(bytes:find(name, 1, true), "the import library does not name " .. name)
    end
    os.remove(path)
end

-- Each job of a batch is its own outcome: one module that fails leaves the
-- others' objects and reports alone.
function M.compileFilesAnswersEachJob()
    if not codegen.available() then
        return
    end
    local good, bad = scratch(".ll"), scratch(".ll")
    writeTo(good, KERNEL)
    writeTo(bad, "define void @f() { ret i32 1 }\n")
    local jobs = {}
    for _, ir in ipairs({good, bad, good}) do
        jobs[#jobs + 1] = {
            ir = ir,
            object = scratch(".o"),
            options = {triple = "x86_64-unknown-linux-gnu", verify = "1", assembly = "1"},
        }
    end
    local outcomes = assert(codegen.compileFiles(jobs, 2))
    assert(#outcomes == 3)
    for _, position in ipairs({1, 3}) do
        local outcome = outcomes[position]
        assert(outcome.error == nil, tostring(outcome.error))
        assert(outcome.report:find("object%-bytes=%d+\n$"), outcome.report)
        assert(#contents(jobs[position].object) > 0)
        assert(contents(jobs[position].object .. ".ll") == nil, "a verifying job's IR was left behind")
    end
    assert(outcomes[2].report == nil and outcomes[2].error:find(bad, 1, true), tostring(outcomes[2].error))
    for _, job in ipairs(jobs) do
        os.remove(job.object)
    end
    os.remove(good)
    os.remove(bad)
end

return M

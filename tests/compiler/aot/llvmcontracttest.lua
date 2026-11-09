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
    local ir = table.concat({
        'define double @"with.dots"(double %a) "nupp-fp-contract" {',
        "  %r = call double @llvm.fma.f64(double %a, double %a, double %a)",
        "  ret double %r",
        "}",
    }, "\n")
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
    local asm = table.concat({
        "_plain:",
        "LBB0_1:",
        ".Ltmp0:",
        "ltmp1:",
        "\tvfmadd213pd %ymm2, %ymm1, %ymm0",
        "_relaxed:",
        "\tf64x2.relaxed_madd",
        "",
    }, "\r\n")
    local bad = contract.fusedInstructions(asm, IR)
    assert(#bad == 1, table.concat(bad, "\n"))
    assert(bad[1] == "plain: vfmadd213pd %ymm2, %ymm1, %ymm0", bad[1])
end

function M.optionsParseKeyValueLines()
    local options = assert(codegen.parseOptions(
        "  triple=x86_64-unknown-linux-gnu\n\ncpu=x86-64-v3\nfeatures=+avx2,+fma\nopt=2\nassembly=1\noptimized-ir=true\nverify=0\n"
    ))
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

return M

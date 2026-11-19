local M = {}

-- In process against the carried standard library, as evalsemanticstest runs: a
-- `nupp run` rooted at the repository checked its `src` copy of the standard
-- library cold, 143 modules, before the self-test started (#419).
function M.theEvaluationHarnessIsImplementedAndTestedInNupp()
    local root = require("helpers.paths").root
    local config = require("helpers.repositoryenv").config()
    local project = require("helpers.contractproject").open(root, {config = config})
    local text = project.run("tests/fixtures/evals/compiler.nupp", true)
    assert(text:find("evaluation harness self-test passed", 1, true), text)
end

return M

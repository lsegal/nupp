return {
    include = {"../src", "../../../../src"},
    build = {
        outDir = "build",
        default = "compiled-contracts",
        targets = {
            [
                "compiled-contracts"
            ] = {
                kind = "modules",
                entries = {
                    "contract.compiledfixture",
                    "nupp.serde.internal.json.compiled",
                    "nupp.codec.json.aot",
                    "contract.hotpath",
                    "contract.matrix",
                    "contract.breadth"
                },
                sources = {
                    "../src/contract/compiledfixture.nupp",
                    "../../../../src/nupp/serde/internal/json/compiled.nupp",
                    "../../../../src/nupp/codec/json/aot.nupp",
                    "../src/contract/hotpath.nupp",
                    "../src/contract/matrix.nupp",
                    "../src/contract/breadth.nupp",
                },
                optimize = 1,
                aot = "require",
            },
        },
    },
}

# Third-party notices

The compiler and its native providers carry third-party code, so a binary or
provider built from them is a distribution of those selected copies. Their
licenses ask that notices travel with the copies, which is what this directory
provides for both the pinned C sources and the locked Rust dependency graph.

Ship `NOTICE.md` and `notices/` beside a binary the way a release archive ships
a README. Native sources are fetched at build time, so their notices would
otherwise exist only inside somebody's toolchain cache. Lunajson is committed
under `src/nupp/runtime/vendor`; its notice is repeated here so the release
notices remain complete in one place.

| Dependency | Pinned at | License | Notice |
| --- | --- | --- | --- |
| [LuaJIT](https://luajit.org/) | `1edc3e52b67eaf6ce5f809be8e17d6862594b8bc` | MIT | [notices/LuaJIT-COPYRIGHT.txt](notices/LuaJIT-COPYRIGHT.txt) |
| [LPeg](https://www.inf.puc-rio.br/~roberto/lpeg/) | `1.1.0` | MIT | [notices/LPeg-LICENSE.txt](notices/LPeg-LICENSE.txt) |
| [Lunajson](https://github.com/grafi-tt/lunajson) | `1.2.3` | MIT | [notices/lunajson-LICENSE.txt](notices/lunajson-LICENSE.txt) |
| [wgpu-native](https://github.com/gfx-rs/wgpu-native) | `v29.0.1.1` | MIT or Apache-2.0 | [notices/wgpu-native-LICENSE.MIT.txt](notices/wgpu-native-LICENSE.MIT.txt), [notices/wgpu-native-LICENSE.APACHE.txt](notices/wgpu-native-LICENSE.APACHE.txt), [notices/wgpu-native-Rust-dependencies.html](notices/wgpu-native-Rust-dependencies.html) |

LuaJIT's notice also carries the public-domain statement for dlmalloc, which
LuaJIT includes; it is reproduced there rather than summarised here.

A copy here that no longer matches the source it came from is worse than none,
because it is a claim about what was distributed. `scripts/toolchain` compares
each file against the notice in the source it just verified. LPeg publishes its
notice inside HTML, so that check verifies the identifying copyright, grant and
warranty terms in both copies. Bumping a pin without updating the notice beside
it therefore stops the build rather than shipping the wrong text.

LuaJIT is in every compiler host. LPeg is a selected host feature. A build that
does not select it does not distribute it; the notice stays here because each
binary's features are decided independently.
Lunajson's decoder and encoder are vendored into the portable compiler runtime.
wgpu-native is not built here: the GPU provider stages its prebuilt release
library beside a program that opens a GPU context, so it travels with GPU
programs rather than with any host. That library statically contains wgpu's
own Rust dependency graph, so its row also links a generated notice covering
every third-party package in wgpu-native's `Cargo.lock` at the pinned tag.

Maintainers refresh the wgpu-native notice with cargo-about 0.9.2 and
`scripts/rust-dependency-notices --write wgpu-native`, from the source archive
of the tag `WGPU_VERSION` pins, and the test suite refuses a pin that notice was
not generated from. Ordinary builds and releases use the committed result and
need neither `cargo-about` nor network access.

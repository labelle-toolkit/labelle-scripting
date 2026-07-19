// The go-scripts module a labelle game builds its scripts/ sources into
// (labelle-engine#746, native family — rust's cargo-crate analog). The
// assembler's declared build step (see plugin.labelle .language_builds)
// runs
//
//   go build -C {package}/native-go -buildmode=c-archive
//            -o {cache}/liblabelle_go_scripts.a ./glue
//
// and links the archive into the game binary. Zero dependencies on
// purpose: the contract header IS the binding (labelle-engine#734 POC
// finding #3), so a game's go scripts build offline with nothing but a
// go toolchain (cgo enabled — a C compiler must be present, which every
// labelle build environment already has for Zig's own cc).
//
// The module path is the bare "labelle" deliberately: game scripts
// spell `import "labelle"` — dotless module paths cannot be fetched
// from a proxy, which is exactly right for a module that is always
// consumed as staged local source (the assembler stages it; this
// repo's test module reaches it via a `replace` directive).
module labelle

// 1.21 floor: `go build -C` (1.20) plus unsafe.StringData in the
// wrappers; any modern toolchain satisfies it.
go 1.21

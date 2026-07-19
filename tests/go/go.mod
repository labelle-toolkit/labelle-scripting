// The go suite's test module: the SHIPPED glue + labelle package
// (native-go/, reached BY REFERENCE through the replace directive below
// — not copied, so the code under test can never drift from the code
// that ships) recomposed around tests/go/game/'s scenario scripts,
// built as a c-archive and linked into the go test binary by
// build.zig's go wiring. main.go is the eight-line stub the shipped
// glue/main.go models — go's spelling of tests/rust/src/lib.rs's
// #[path] recomposition.
module labelle_go_test

go 1.21

require labelle v0.0.0

replace labelle => ../../native-go

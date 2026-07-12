// components/hunger.ts — the component DECLARED IN TYPESCRIPT (rev 20
// option (b), labelle-engine#773), beside the zero-field tag spelling
// (components/worker.ts). The components/ dir is extension-keyed and
// mixed-language by design — declaration files live where their kind
// lives, not in a scripts corner (a components/*.zig would sit right here
// beside these).
//
// ONE line, two consumers:
//
//   - at `labelle generate` the assembler TRANSPILES this file FIRST
//     (option (b): declaration files are transpiled before the declare
//     phase), then its embedded-VM declare runner (labelle-declare-ts)
//     evals the emitted .js and the assembler codegens a REAL Zig registry
//     component from the schema (.labelle/<target>/scripting_components.zig
//     — `pub const Hunger` with `level: f32 = 0.875, starving: bool =
//     false`): scenes, save buckets, typed queries, the generated
//     labelle-components.d.ts and the contract's by-name dispatch all reach
//     it exactly like the components/hunger.zig it replaces (CI greps the
//     generated file);
//
//   - at RUNTIME this file's emitted .js is embedded and registered BEFORE
//     every scripts/ entry (components-first registration order — CI pins
//     it), so `labelle.component` returns a ref and the `Hunger` constant
//     exists by the time the scripts load.
//
// The declared default level 0.875 (7/8 — exact in binary floating point
// at every width en route) IS the decay chain's seed: the spawner attaches
// the component BARE (`worker.set("Hunger")` — the contract's all-defaults
// write), so tick 1's TS_LEVEL_0.625 = 0.875 - 0.25 is reachable only
// through THIS declaration having traveled schema -> codegen -> registry
// -> ECS.
export const Hunger = labelle.component("Hunger", { level: 0.875, starving: false });

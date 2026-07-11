# labelle-scripting mruby vendor build config.
#
# Run ONCE on a host with ruby+rake to (re)generate the C sources vendored
# under vendor/mruby/ — consumers never need ruby/rake, they compile the
# vendored output with zig cc.
#
#   rake -f <mruby>/Rakefile MRUBY_CONFIG=<this file>
#
# Gem posture (the sandbox stance): pure-language core gems only.
#   IN : stdlib gembox (enum/array/hash/string/... -ext, set, fiber,
#        enumerator, objectspace — all OS-free language surface),
#        math, random, sprintf, catch (puts/p are mruby-3.4 core),
#        struct (Component.ref backing — REQUIRED),
#        metaprog (instance_variable_get/set for class metadata),
#        error (mrb_protect family), compiler (runtime script loading).
#   OUT: io, socket, dir, errno (filesystem/network), eval (sandbox),
#        time, sleep, exit (OS clock / tick blocking / process kill),
#        method, binding, pack, bigint/rational/complex/cmath (weight).
MRuby::Build.new do |conf|
  conf.toolchain :clang

  conf.gembox 'stdlib'
  conf.gem core: 'mruby-math'
  conf.gem core: 'mruby-random'
  conf.gem core: 'mruby-sprintf'
  conf.gem core: 'mruby-catch'
  conf.gem core: 'mruby-struct'
  conf.gem core: 'mruby-metaprog'
  conf.gem core: 'mruby-error'
  conf.gem core: 'mruby-compiler'

  # Must match the defines build.zig compiles the vendored sources with:
  # entity ids ride mrb_int as the signed 64-bit bitcast (MRB_INT64), and
  # the Zig bindings hand-mirror mrb_value, which is only ABI-stable in the
  # unboxed representation (MRB_NO_BOXING; the word-boxing default would
  # also demote bit-63 ids to heap-boxed RIntegers).
  conf.cc.defines << 'MRB_INT64'
  conf.cc.defines << 'MRB_NO_BOXING'
end

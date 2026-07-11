// u64str_check.js — pins labelle.u64str, the unsigned-decimal renderer
// for entity ids. In this backend ids are BigInt and already print
// unsigned, so u64str is parity sugar — but it must render the whole u64
// range exactly, Number and BigInt inputs alike. The bit-63 literals MUST
// be BigInt (0x8000000000000001 as a Number literal would round): results
// land in a component so the Zig side asserts the exact decimal strings.

export function init() {
  const e = Entity.create();
  e.set("U64Str", {
    zero: labelle.u64str(0),
    one: labelle.u64str(1),
    pow62: labelle.u64str(1n << 62n),
    high_one: labelle.u64str(0x8000000000000001n),
    all_ones: labelle.u64str(0xffffffffffffffffn),
  });
}

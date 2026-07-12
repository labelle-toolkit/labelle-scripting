# Game-side JSON field extraction, slice-1 style: scripts own their
# payload parsing (a structured serde story is future work — the
# contract's payloads are small and flat). Works on raw Bytes
# (`Buffer#to_slice`, `String#to_slice`) so the hot path never
# allocates; needles are pre-quoted literals (`%("x":)`).

module Util
  # The integer after `needle` (e.g. `%("x":)`) in `json`, or nil.
  # Pure Int64 arithmetic — no float ever touches the value.
  def self.i64_field(json : Bytes, needle : String) : Int64?
    at = find(json, needle.to_slice)
    return nil unless at
    i = at + needle.bytesize
    # Tolerate the encoder-side space ("key": 1).
    while i < json.size && json[i] == 0x20
      i += 1
    end
    neg = i < json.size && json[i] == 0x2d # '-'
    i += 1 if neg
    val = 0_i64
    any = false
    while i < json.size && 48 <= json[i] <= 57
      val = val &* 10 &+ (json[i] - 48)
      any = true
      i += 1
    end
    return nil unless any
    neg ? -val : val
  end

  private def self.find(haystack : Bytes, needle : Bytes) : Int32?
    return nil if needle.empty? || haystack.size < needle.size
    (0..haystack.size - needle.size).each do |i|
      return i if haystack[i, needle.size] == needle
    end
    nil
  end
end

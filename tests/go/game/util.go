// Shared payload parsing — scripts own their payload parsing (contract
// payloads are small, flat JSON; a structured story is future work).
// Pure byte walks; no float ever touches an entity id.
package game

import "strconv"

// i64Field returns the integer after needle (e.g. `"x":`), or 0/false.
func i64Field(json []byte, needle string) (int64, bool) {
	i, ok := skipToValue(json, needle)
	if !ok {
		return 0, false
	}
	start := i
	if i < len(json) && (json[i] == '-' || json[i] == '+') {
		i++
	}
	for i < len(json) && json[i] >= '0' && json[i] <= '9' {
		i++
	}
	if i == start {
		return 0, false
	}
	v, err := strconv.ParseInt(string(json[start:i]), 10, 64)
	return v, err == nil
}

// u64Field returns the unsigned integer after needle, tolerating a
// string-encoded id (`"entity":"123"`) — dynamic-language emitters
// spell ids as JSON strings.
func u64Field(json []byte, needle string) (uint64, bool) {
	i, ok := skipToValue(json, needle)
	if !ok {
		return 0, false
	}
	if i < len(json) && json[i] == '"' {
		i++
	}
	var v uint64
	any := false
	for i < len(json) && json[i] >= '0' && json[i] <= '9' {
		v = v*10 + uint64(json[i]-'0')
		any = true
		i++
	}
	return v, any
}

// f32Field returns the float after needle, or 0/false.
func f32Field(json []byte, needle string) (float32, bool) {
	start, ok := skipToValue(json, needle)
	if !ok {
		return 0, false
	}
	end := start
	for end < len(json) {
		switch c := json[end]; {
		case c >= '0' && c <= '9', c == '-', c == '+', c == '.', c == 'e', c == 'E':
			end++
		default:
			goto done
		}
	}
done:
	if end == start {
		return 0, false
	}
	v, err := strconv.ParseFloat(string(json[start:end]), 32)
	if err != nil {
		return 0, false
	}
	return float32(v), true
}

// skipToValue finds the first value byte after needle, tolerating JSON
// whitespace.
func skipToValue(json []byte, needle string) (int, bool) {
	n := []byte(needle)
	if len(n) == 0 || len(json) < len(n) {
		return 0, false
	}
	at := -1
	for i := 0; i+len(n) <= len(json); i++ {
		if string(json[i:i+len(n)]) == needle {
			at = i
			break
		}
	}
	if at < 0 {
		return 0, false
	}
	i := at + len(n)
	for i < len(json) && (json[i] == ' ' || json[i] == '\t' || json[i] == '\n' || json[i] == '\r') {
		i++
	}
	return i, true
}

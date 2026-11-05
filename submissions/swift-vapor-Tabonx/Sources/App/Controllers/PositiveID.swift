/// An id made of ASCII digits only and above zero, so `+1`, `1.5`, `-1`, `0` and values that
/// overflow `Int64` are all rejected.
struct PositiveID {
    let value: Int64

    init?(_ text: String) {
        guard !text.isEmpty, text.utf8.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }),
              let value = Int64(text), value > 0
        else { return nil }
        self.value = value
    }
}

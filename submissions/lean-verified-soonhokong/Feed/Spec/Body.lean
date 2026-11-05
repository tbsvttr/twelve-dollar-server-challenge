import Feed.Spec.Errors
import Feed.Spec.Json

/-!
# The post body

SPEC.md:67-69 (the `POST /posts` body) and schema.sql:13 (the CHECK on `posts.body`). Where
SPEC.md leaves room, these are this server's choices: "whitespace" is what ECMAScript's
`String.prototype.trim` removes, and a "character" is a Unicode scalar value, the unit of
SQLite's `length()` on text.
-/
namespace Feed.Spec.Body
open Json

abbrev Bytes := List UInt8

/-- "whitespace" (SPEC.md:68): what ECMAScript's `String.prototype.trim` removes -/
def isTrimSpace (c : Nat) : Bool :=
  (0x09 ≤ c && c ≤ 0x0d) || c == 0x20 || c == 0xa0 || c == 0x1680 || (0x2000 ≤ c && c ≤ 0x200a) ||
  c == 0x2028 || c == 0x2029 || c == 0x202f || c == 0x205f || c == 0x3000 || c == 0xfeff

/-- "after trimming whitespace" -/
def trim (cs : List Nat) : List Nat := ((cs.dropWhile isTrimSpace).reverse.dropWhile isTrimSpace).reverse

def bodyName : List Nat := [0x62, 0x6f, 0x64, 0x79]

open Classical in
/-- SPEC.md:67-69: the text to store (the `body` member's string, trimmed, as UTF-8), or the
error. "Characters" are Unicode scalar values, the unit of schema.sql's `length(body)`. -/
noncomputable def postBody (t : Bytes) : Except ApiErr Bytes :=
  if ¬ IsText t then .error .malformedJson
  else if h : ∃ ms, IsObjectText t ms then
    match member (Classical.choose h) bodyName with
    | none => .error .bodyRequired
    | some v =>
      if hs : ∃ us, IsString v us then
        let s := trim (scalars (Classical.choose hs))
        if s = [] then .error .bodyRequired
        else if 500 < s.length then .error .bodyTooLong
        else .ok (encode s)
      else .error .bodyRequired
  else .error .bodyRequired

/-- SQLite's `length(X)` on UTF-8 text: the characters before the first NUL (the bytes that are no
continuation bytes). `accept` applies it only to UTF-8; SQLite counts other bytes differently, a
continuation byte that does not follow a byte of 0x80 or more as a character. -/
def sqlLength (t : Bytes) : Nat := ((t.takeWhile (· ≠ 0)).filter (fun b => b &&& 0xc0 ≠ 0x80)).length

/-- schema.sql:13 `CHECK (length(body) BETWEEN 1 AND 500)` -/
def schemaOk (t : Bytes) : Bool := Decidable.decide (1 ≤ sqlLength t ∧ sqlLength t ≤ 500)

/-- The body as the API takes it: SPEC.md's rules, then the schema's CHECK, whose failure is
SPEC.md:70's "anything else | 500" -/
noncomputable def accept (t : Bytes) : Except ApiErr Bytes :=
  (postBody t).bind fun s => if schemaOk s then .ok s else .error .internal

example : sqlLength [0, 0x78] = 0 := by decide
example : sqlLength [0x78, 0, 0x78] = 1 := by decide

end Feed.Spec.Body

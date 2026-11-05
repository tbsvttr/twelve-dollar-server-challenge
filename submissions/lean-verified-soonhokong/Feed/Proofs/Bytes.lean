import Feed.Model
import Feed.Handler

/-!
# Byte arrays as lists

Every byte-array operation the handler uses, stated on `bs` (the bytes as a list). The leaves of
`Feed/Bytes.lean` are reasoned about through their Lean definitions.
-/
namespace Feed
open Spec

@[simp] theorem bs_append (a b : ByteArray) : bs (a ++ b) = bs a ++ bs b :=
  ByteArray.toList_data_append

@[simp] theorem bs_push (a : ByteArray) (x : UInt8) : bs (a.push x) = bs a ++ [x] := by
  simp [bs, ByteArray.push]

@[simp] theorem bs_mk (l : List UInt8) : bs ⟨l.toArray⟩ = l := by simp [bs]

@[simp] theorem bs_empty : bs ByteArray.empty = [] := rfl

@[simp] theorem bs_emptyWithCapacity (n : Nat) : bs (ByteArray.emptyWithCapacity n) = [] := rfl

/-- `ByteArray`'s `==` (the runtime's `lean_sarray_dec_eq`) is equality. -/
instance : LawfulBEq ByteArray where
  eq_of_beq {a b} h := by
    cases a; cases b
    exact congrArg ByteArray.mk (eq_of_beq (show ByteArray.beq _ _ = true from h))
  rfl {a} := by
    show ByteArray.beq a a = true
    simp [ByteArray.beq]

theorem size_eq_length (a : ByteArray) : a.size = (bs a).length := by
  rw [bs, Array.length_toList]; rfl

@[simp] theorem bs_appendAll (out src : ByteArray) : bs (Bytes.appendAll out src) = bs out ++ bs src := by
  simp [Bytes.appendAll]

@[simp] theorem bs_appendEsc (out src : ByteArray) (lo hi : Nat) :
    bs (Bytes.appendEsc out src lo hi) = bs out ++ escape (slice src lo hi) := by
  simp [Bytes.appendEsc]

@[simp] theorem bs_appendNat (out : ByteArray) (n : Nat) :
    bs (Bytes.appendNat out n) = bs out ++ digits n := by
  simp only [Bytes.appendNat, bs_append]; rfl

@[simp] theorem bs_appendLitEsc (out lit src : ByteArray) (lo hi : Nat) :
    bs (Bytes.appendLitEsc out lit src lo hi) = bs out ++ bs lit ++ escape (slice src lo hi) := by
  simp [Bytes.appendLitEsc]

@[simp] theorem bs_appendLitNat (out lit : ByteArray) (n : Nat) :
    bs (Bytes.appendLitNat out lit n) = bs out ++ bs lit ++ digits n := by
  simp only [Bytes.appendLitNat, bs_append]; rfl

@[simp] theorem bs_appendSlice (out src : ByteArray) (lo hi : Nat) :
    bs (Bytes.appendSlice out src lo hi) = bs out ++ slice src lo hi := by
  simp [Bytes.appendSlice]

@[simp] theorem bs_clear (a : ByteArray) : bs (Bytes.clear a) = [] := rfl

@[simp] theorem bs_lit (s : String) : bs (Feed.lit s) = Spec.lit s := rfl

/-- The post object the handler writes is the specification's. -/
theorem bs_postJson (out : ByteArray) (id : Nat) (src : ByteArray) (b c e : Nat) (names : ByteArray) (ns ne likes : Nat) :
    bs (postJson out id src b c e names ns ne likes) =
      bs out ++ viewJson ⟨id, slice src b c, slice src c e, slice names ns ne, likes⟩ := by
  simp [postJson, postJsonAfter, viewJson, kId, kBody, kCreated, kAuthor, kLikes, kClose]

theorem bs_postJsonAfter_id (out : ByteArray) (id : Nat) (src : ByteArray) (b c e : Nat) (names : ByteArray)
    (ns ne likes : Nat) :
    bs (postJsonAfter out kId id src b c e names ns ne likes) =
      bs out ++ viewJson ⟨id, slice src b c, slice src c e, slice names ns ne, likes⟩ :=
  bs_postJson out id src b c e names ns ne likes

/-- After a previous object: a comma, then the post object. -/
theorem bs_postJsonAfter_comma (out : ByteArray) (id : Nat) (src : ByteArray) (b c e : Nat) (names : ByteArray)
    (ns ne likes : Nat) :
    bs (postJsonAfter out kCommaId id src b c e names ns ne likes) =
      bs out ++ [0x2c] ++ viewJson ⟨id, slice src b c, slice src c e, slice names ns ne, likes⟩ := by
  have : bs kCommaId = [0x2c] ++ Spec.lit "{\"id\":" := rfl
  simp [postJsonAfter, viewJson, this, kBody, kCreated, kAuthor, kLikes, kClose]

/-! ## Response bytes -/

theorem bs_statusLine (s : Nat) :
    bs (statusLine s) =
      Spec.lit ("HTTP/1.1 " ++ statusPhrase s ++ "\r\nContent-Type: application/json\r\nContent-Length: ") := by
  unfold statusLine statusPhrase
  split <;> (try rfl) <;> split <;> first | rfl | (exfalso; simp_all)

/-- `respond` appends the specification's response. -/
theorem bs_respond (out : ByteArray) (status : Nat) (body : ByteArray) (close : Bool) :
    bs (respond out status body close) = bs out ++ response status (bs body) close := by
  have hout : bs (if out.size == 0 then ByteArray.emptyWithCapacity (body.size + 160) else out) = bs out := by
    split
    · rename_i h
      have : (bs out).length = 0 := by rw [← size_eq_length]; simpa using h
      rw [bs_emptyWithCapacity, List.eq_nil_of_length_eq_zero this]
    · rfl
  simp only [respond, bs_appendAll, bs_appendNat, hout, bs_statusLine, response, List.append_assoc]
  rw [size_eq_length body]
  cases close <;> rfl

end Feed

import Feed.Spec.Http
import Feed.Proofs.Slice

/-!
# The head's lines and fields

The byte scan of `Http.parse` (`Http.scan`) against `Feed/Spec/Http.lean`'s lines and fields.
`Http.scan_spec` says what the scan of the input at `pos` returns, in the specification's terms:
414 exactly when `TargetTooLong` holds; when no head ends within the first `maxHead + 4` bytes,
431 once they have all arrived and a wait before; 400 when the bytes up to the first CR LF CR LF
after the empty lines are not a head of HTTP/1.x; otherwise that head, with its parts (`IsHead`)
and the record of what its field lines say (`Http.Fields.Sums`). `finish`'s checks of the Host
value and the request-target are `Feed/Proofs/Uri.lean`'s, and the frame is
`Feed/Proofs/Http.lean`'s.

The pieces, each against the specification's list view of the bytes:

* the head ends at the first CR LF CR LF (`Http.headEnd_eq`), after the empty lines
  (`Http.skipLead_eq`), and a head's length is where its first CR LF CR LF ends
  (`Spec.Http.headLen_head`); so does a response's head (`crlf2Idx_response`, where `readLoop`
  cuts the answer to HEAD), and `Http.headAt` tells malformed input that starts with "HEAD " as
  `Spec.Http.headRequest` does (`Http.headAt_eq`);
* the scan's loops stop where the specification's runs end (`Http.tokenEnd_eq`,
  `Http.targetEnd_eq`, `Http.valueEnd_eq`), and `skipL` and `skipR` remove OWS (`Http.trim_eq`);
* field names are compared as RFC 9110 §5.1 says (`Http.eqCI_iff`), Connection options as §7.6.1
  says (`Http.hasToken_eq`), and Content-Length is read as a decimal number of any length
  (`Http.lengthOf_eq`; `decimal_eq_iff` for the digits `sameBytes` compares);
* a field line is a name, ":" and a value in one way only (`Spec.Http.fieldLine_iff`), and so is a
  head (`Spec.Http.isHead_unique`); input that starts with a head whose request-target has at most
  `maxTarget` bytes is not `TargetTooLong` (`Spec.Http.not_targetTooLong`);
* the field scan finds no fault exactly in field lines (`Http.fields_sound`,
  `Http.fields_complete`), and its record says what they say (`Http.field_sums`; the corollaries
  in `Http.Fields.Sums` are in `HeadOk`'s and `IsRequest`'s terms).
-/
namespace Feed
open Spec

/-! ## The end of the head -/

/-- The first `i` at which `l` has CR LF CR LF (the bytes `i` to `i + 3`). -/
def crlf2Idx : List UInt8 → Option Nat
  | [] => none
  | c :: l => if c :: l.take 3 = [0x0d, 0x0a, 0x0d, 0x0a] then some 0 else (crlf2Idx l).map (· + 1)

theorem crlf2Idx_short : ∀ l : List UInt8, l.length < 4 → crlf2Idx l = none
  | [], _ => rfl
  | c :: l, h => by
    have hl : l.length < 3 := by simp at h; omega
    rw [crlf2Idx, ite_eq_right, crlf2Idx_short l (by omega)]
    · rfl
    · intro he
      have := congrArg List.length he
      simp only [List.length_cons, List.length_take] at this
      omega

/-- A byte other than CR starts no CR LF CR LF. -/
theorem crlf2Idx_cons_ne (c : UInt8) (l : List UInt8) (h : c ≠ 0x0d) :
    crlf2Idx (c :: l) = (crlf2Idx l).map (· + 1) := by
  rw [crlf2Idx, ite_eq_right]
  intro he
  exact h (List.cons.inj he).1

/-- Positions without a CR are skipped. -/
theorem crlf2Idx_skip (a : ByteArray) {hi : Nat} (h' : hi ≤ a.size) :
    ∀ j i, i + j ≤ hi → (∀ k, i ≤ k → k < i + j → a.get! k ≠ 0x0d) →
      crlf2Idx (slice a i hi) = (crlf2Idx (slice a (i + j) hi)).map (· + j) := by
  intro j
  induction j with
  | zero => intro i _ _; simp
  | succ j ih =>
    intro i hj hk
    rw [slice_cons a (by omega) h', crlf2Idx_cons_ne _ _ (hk i (Nat.le_refl _) (by omega)),
      ih (i + 1) (by omega) (fun k h1 h2 => hk k (by omega) (by omega)), Option.map_map,
      show i + 1 + j = i + (j + 1) by omega]
    congr 1

theorem headEnd_go (a : ByteArray) {hi : Nat} (h' : hi ≤ a.size) :
    ∀ f i, i ≤ hi → hi - i ≤ f → Http.headEnd.go a hi i f = (crlf2Idx (slice a i hi)).map (i + ·) := by
  intro f
  induction f with
  | zero =>
    intro i hi' hf
    rw [show i = hi by omega, slice_empty]
    rfl
  | succ f ih =>
    intro i hi' hf
    simp only [Http.headEnd.go]
    by_cases hlt : i + 3 < hi
    · have hm : min (hi - 3) a.size = hi - 3 := by omega
      obtain ⟨h1, h2, h3, h4⟩ := Bytes.findByte_first a 0x0d (lo := i) (hi := hi - 3) (by omega)
      generalize Bytes.findByte a 0x0d i (hi - 3) = c at h1 h2 h3 h4
      rw [hm] at h2 h4
      have hskip := crlf2Idx_skip a h' (c - i) i (by omega) (fun m hm1 hm2 => h3 m hm1 (by omega))
      rw [show i + (c - i) = c by omega] at hskip
      by_cases hfound : c < hi - 3
      · have hcr := h4 hfound
        rw [ite_eq_left (by omega)]
        have hwin : slice a c hi =
            0x0d :: a.get! (c + 1) :: a.get! (c + 2) :: a.get! (c + 3) :: slice a (c + 4) hi := by
          rw [slice_cons a (by omega) h', slice_cons a (by omega) h', slice_cons a (by omega) h',
            slice_cons a (by omega) h', hcr]
        rw [hskip, hwin, crlf2Idx]
        simp only [List.take_succ_cons, List.take_zero, Option.map_map]
        by_cases hm4 : (a.get! (c + 1) == 0x0a && a.get! (c + 2) == 0x0d && a.get! (c + 3) == 0x0a) = true
        · simp only [Bool.and_eq_true, beq_iff_eq] at hm4
          simp only [Http.byte, hm4, beq_self_eq_true, Bool.and_self, ↓reduceIte, Option.map_some,
            Function.comp_apply]
          congr 1
          omega
        · have hne :
              ¬ ([0x0d, a.get! (c + 1), a.get! (c + 2), a.get! (c + 3)] : List UInt8) = [0x0d, 0x0a, 0x0d, 0x0a] := by
            intro he
            apply hm4
            simp only [List.cons.injEq] at he
            simp [he.2.1, he.2.2.1, he.2.2.2.1]
          simp only [Http.byte, hm4, Bool.false_eq_true, ↓reduceIte, hne]
          have hwin1 :
              slice a (c + 1) hi = a.get! (c + 1) :: a.get! (c + 2) :: a.get! (c + 3) :: slice a (c + 4) hi := by
            rw [slice_cons a (by omega) h', slice_cons a (by omega) h', slice_cons a (by omega) h']
          rw [ih (c + 1) (by omega) (by omega), hwin1, Option.map_map]
          congr 1
          funext x
          simp only [Function.comp_apply]
          omega
      · rw [ite_eq_right (by omega), hskip, crlf2Idx_short _ (by rw [slice_length a h']; omega)]
        rfl
    · rw [Bytes.findByte_past a 0x0d (by omega), ite_eq_right (by omega),
        crlf2Idx_short _ (by rw [slice_length a h']; omega)]
      rfl

/-- **The head ends at the first CR LF CR LF**: `headEnd` finds the first position of the range
that starts CR LF CR LF within it. -/
theorem Http.headEnd_eq (a : ByteArray) {lo hi : Nat} (h : lo ≤ hi) (h' : hi ≤ a.size) :
    Http.headEnd a lo hi = (crlf2Idx (slice a lo hi)).map (lo + ·) :=
  headEnd_go a h' (hi - lo) lo h (Nat.le_refl _)

/-- info: 'Feed.Http.headEnd_eq' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms Http.headEnd_eq

/-- `crlf2Idx` is the search of `Spec.Http.headLen`. -/
theorem crlf2Idx_eq_find : ∀ l : List UInt8,
    crlf2Idx l = (List.range l.length).find? fun i => (l.drop i).take 4 == Spec.Http.crlf ++ Spec.Http.crlf
  | [] => rfl
  | c :: l => by
    rw [List.length_cons, List.range_succ_eq_map, List.find?_cons, crlf2Idx, crlf2Idx_eq_find l,
      List.find?_map]
    have h0 : (List.drop 0 (c :: l)).take 4 = c :: l.take 3 := rfl
    have hs : ((fun i => List.take 4 (List.drop i (c :: l)) == Spec.Http.crlf ++ Spec.Http.crlf) ∘ Nat.succ) =
        fun i => List.take 4 (List.drop i l) == Spec.Http.crlf ++ Spec.Http.crlf := by
      funext i; rfl
    rw [h0, hs]
    by_cases he : c :: l.take 3 = [0x0d, 0x0a, 0x0d, 0x0a]
    · rw [ite_eq_left he]
      have : (c :: l.take 3 == Spec.Http.crlf ++ Spec.Http.crlf) = true := by rw [he]; rfl
      rw [this]
    · rw [ite_eq_right he]
      have : (c :: l.take 3 == Spec.Http.crlf ++ Spec.Http.crlf) = false := by
        simp only [beq_eq_false_iff_ne]; exact he
      rw [this]

/-! ## The end of a response's head

`readLoop` answers HEAD with GET's response cut after its first CR LF CR LF, which ends its head:
the head's lines have no CR LF CR LF before. -/

/-- The bytes of a number's decimal digits are digits. -/
theorem digits_isDigit (n : Nat) : ∀ c ∈ digits n, Spec.Http.isDigit c = true := by
  have key : ∀ l : List Char, (∀ ch ∈ l, ch.isDigit = true) →
      ∀ c ∈ (List.utf8Encode l).data.toList, Spec.Http.isDigit c = true := by
    intro l
    induction l with
    | nil => intro _ c hc; simp [List.utf8Encode_nil] at hc
    | cons ch l ih =>
      intro hl c hc
      rw [List.utf8Encode_cons, ByteArray.toList_data_append, List.utf8Encode_singleton,
        List.toList_data_toByteArray] at hc
      have hch := hl ch List.mem_cons_self
      simp only [Char.isDigit, Bool.and_eq_true, decide_eq_true_eq, ge_iff_le] at hch
      have hv1 : 48 ≤ ch.val.toNat := by rw [UInt32.le_iff_toNat_le] at hch; exact hch.1
      have hv2 : ch.val.toNat ≤ 57 := by rw [UInt32.le_iff_toNat_le] at hch; exact hch.2
      have h1 : ch.utf8Size = 1 := Char.utf8Size_eq_one_iff.mpr (by
        rw [UInt32.le_iff_toNat_le, show UInt32.toNat 127 = 127 from rfl]; omega)
      rw [String.utf8EncodeChar_eq_singleton h1] at hc
      rcases List.mem_append.mp hc with hc | hc
      · rw [List.mem_singleton] at hc
        subst hc
        simp only [Spec.Http.isDigit, Bool.and_eq_true, decide_eq_true_eq, UInt8.le_iff_toNat_le,
          UInt32.toNat_toUInt8]
        rw [show UInt8.toNat 48 = 48 from rfl, show UInt8.toNat 57 = 57 from rfl]
        omega
      · exact ih (fun x hx => hl x (List.mem_cons_of_mem _ hx)) c hc
  intro c hc
  unfold digits Spec.lit at hc
  rw [Nat.toString_eq_ofList_toDigits, String.toUTF8_eq_toByteArray, String.toByteArray_ofList] at hc
  exact key _ (fun ch h => Nat.isDigit_of_mem_toDigits (by decide) (by decide) h) c hc

/-- No CR LF CR LF starts in `p`, whatever follows it. -/
def noCrlf2 : List UInt8 → Bool
  | [] => true
  | c :: p => (c != 0x0d || p.take 3 != [0x0a, 0x0d, 0x0a].take p.length) && noCrlf2 p

theorem noCrlf2_of_ne : ∀ p : List UInt8, (∀ c ∈ p, c ≠ 0x0d) → noCrlf2 p = true
  | [], _ => rfl
  | c :: p, h => by
    simp only [noCrlf2, Bool.and_eq_true, Bool.or_eq_true, bne_iff_ne, ne_eq]
    exact ⟨Or.inl (h c List.mem_cons_self), noCrlf2_of_ne p (fun x hx => h x (List.mem_cons_of_mem _ hx))⟩

theorem crlf2Idx_append_noCrlf2 : ∀ p q : List UInt8, noCrlf2 p = true →
    crlf2Idx (p ++ q) = (crlf2Idx q).map (· + p.length)
  | [], q, _ => by simp
  | c :: p, q, h => by
    simp only [noCrlf2, Bool.and_eq_true, Bool.or_eq_true, bne_iff_ne, ne_eq] at h
    rw [List.cons_append, crlf2Idx, ite_eq_right, crlf2Idx_append_noCrlf2 p q h.2, Option.map_map]
    · congr 1
    · intro he
      simp only [List.cons.injEq] at he
      rcases h.1 with h1 | h1
      · exact h1 he.1
      · apply h1
        have ht := he.2
        rw [List.take_append] at ht
        have hl : (p.take 3).length = min 3 p.length := by simp
        have := congrArg (List.take (p.take 3).length) ht
        rw [List.take_left' rfl] at this
        rw [this, hl]
        by_cases hp : 3 ≤ p.length
        · rw [Nat.min_eq_left hp, List.take_of_length_le (by simp <;> omega),
            List.take_of_length_le (by simp <;> omega)]
        · rw [Nat.min_eq_right (by omega)]

/-- The first CR LF CR LF of a response ends its head. -/
theorem crlf2Idx_response (status : Nat) (body : List UInt8) (close : Bool) :
    crlf2Idx (Spec.response status body close) = some ((Spec.Http.responseHead status body close).length - 4) := by
  have hb : Spec.lit (if close then "\r\nConnection: close\r\n\r\n" else "\r\n\r\n") =
      Spec.lit (if close then "\r\nConnection: close" else "") ++ [0x0d, 0x0a, 0x0d, 0x0a] := by
    cases close <;> rfl
  have hc : noCrlf2 (Spec.lit (if close then "\r\nConnection: close" else "")) = true := by
    cases close <;> rfl
  have ha : noCrlf2 (Spec.lit ("HTTP/1.1 " ++ statusPhrase status ++
      "\r\nContent-Type: application/json\r\nContent-Length: ")) = true := by
    unfold statusPhrase
    split <;> rfl
  have hd : noCrlf2 (digits body.length) = true :=
    noCrlf2_of_ne _ (fun c hc he => by have := digits_isDigit _ c hc; rw [he] at this; exact absurd this (by decide))
  rw [Spec.Http.response_eq_head, Spec.Http.responseHead, hb]
  simp only [List.append_assoc]
  rw [crlf2Idx_append_noCrlf2 _ _ ha, crlf2Idx_append_noCrlf2 _ _ hd, crlf2Idx_append_noCrlf2 _ _ hc]
  have h0 : crlf2Idx ([0x0d, 0x0a, 0x0d, 0x0a] ++ body) = some 0 := rfl
  rw [h0]
  simp only [Option.map_some, List.length_append, List.length_cons, List.length_nil]
  congr 1
  omega

/-! ## Empty lines before a request -/

theorem drop_cons2 (a : ByteArray) {i : Nat} (h : i + 1 < a.size) :
    (bs a).drop i = a.get! i :: a.get! (i + 1) :: (bs a).drop (i + 2) := by
  have h0 : i < (bs a).length := by simp [bs]; omega
  have h1 : i + 1 < (bs a).length := by simp [bs]; omega
  rw [List.drop_eq_getElem_cons h0, List.drop_eq_getElem_cons h1, get!_eq, get!_eq,
    List.getElem?_eq_getElem h0, List.getElem?_eq_getElem h1]
  rfl

theorem skipLead_go (a : ByteArray) : ∀ f i, a.size - i ≤ f →
    Http.skipLead.go a i f = i + 2 * Spec.Http.lead ((bs a).drop i) := by
  intro f
  induction f with
  | zero =>
    intro i h
    rw [List.drop_eq_nil_of_le (by simp [bs]; omega)]
    rfl
  | succ f ih =>
    intro i h
    rw [Http.skipLead.go]
    by_cases hi : i + 1 < a.size
    · rw [drop_cons2 a hi, Spec.Http.lead]
      by_cases hc : (Http.byte a i == 0x0d && Http.byte a (i + 1) == 0x0a) = true
      · have hc' : a.get! i = 0x0d ∧ a.get! (i + 1) = 0x0a := by simpa [Http.byte] using hc
        rw [ite_eq_left hc, ih (i + 2) (by omega), ite_eq_left hc']
        omega
      · have hc' : ¬ (a.get! i = 0x0d ∧ a.get! (i + 1) = 0x0a) := by simpa [Http.byte] using hc
        rw [ite_eq_right hc, ite_eq_right hc']
        omega
    · have h0 : Spec.Http.lead ((bs a).drop i) = 0 := by
        match hl : (bs a).drop i with
        | [] => rfl
        | [_] => rfl
        | _ :: _ :: _ =>
          exfalso
          have := congrArg List.length hl
          simp [bs] at this
          omega
      have h1 : a.get! (i + 1) = 0 := by
        rw [get!_eq, List.getElem?_eq_none (by simp [bs]; omega)]
        rfl
      have hc : ¬ (Http.byte a i == 0x0d && Http.byte a (i + 1) == 0x0a) = true := by simp [Http.byte, h1]
      rw [ite_eq_right hc, h0]
      omega

theorem Http.skipLead_eq (a : ByteArray) (pos : Nat) :
    Http.skipLead a pos = pos + 2 * Spec.Http.lead ((bs a).drop pos) :=
  skipLead_go a _ pos (Nat.le_refl _)

/-- Whether malformed input is a HEAD request is decided as the specification says. -/
theorem Http.headAt_eq (a : ByteArray) (pos : Nat) :
    Http.headAt a pos = Spec.Http.headRequest ((bs a).drop pos) := by
  unfold Http.headAt Spec.Http.headRequest
  rw [Http.skipLead_eq, List.drop_drop]
  generalize pos + 2 * Spec.Http.lead ((bs a).drop pos) = i
  have hlit : Spec.lit "HEAD " = bs Http.kHeadSp := rfl
  rw [hlit]
  apply Bool.eq_iff_iff.mpr
  rw [beq_iff_eq]
  by_cases h : i + 5 ≤ a.size
  · rw [eqAt_spec a Http.kHeadSp (by omega) h]
    simp only [slice, bs]
    rw [show i + 5 - i = 5 by omega]
  · constructor
    · intro he
      exfalso
      rw [Http.eqAt, Bool.and_eq_true, eqAt_go] at he
      have hk := he.2 (a.size - i) (Nat.zero_le _) (by rw [show Http.kHeadSp.size = 5 from rfl]; omega)
      rw [show i + (a.size - i) = max i a.size by omega] at hk
      have h0 : a.get! (max i a.size) = 0 := by
        rw [get!_eq, List.getElem?_eq_none (by simp [bs]; omega)]
        rfl
      rw [h0] at hk
      have hlt : a.size - i < 5 := by omega
      generalize a.size - i = k at hk hlt
      revert hk
      match k, hlt with
      | 0, _ => decide
      | 1, _ => decide
      | 2, _ => decide
      | 3, _ => decide
      | 4, _ => decide
    · intro he
      exfalso
      have := congrArg List.length he
      simp only [List.length_take, List.length_drop, bs, Array.length_toList] at this
      have h5 : Http.kHeadSp.data.size = 5 := rfl
      have hs : a.data.size = a.size := rfl
      omega

/-- info: 'Feed.Http.headAt_eq' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms Http.headAt_eq

/-! ## Characters -/

theorem tchar_all : ∀ v : Fin 256, Http.tchar v.val.toUInt8 = Spec.Http.isTchar v.val.toUInt8 := by decide +kernel

/-- The parser's `tchar` is RFC 9110's. -/
theorem Http.tchar_eq (c : UInt8) : Http.tchar c = Spec.Http.isTchar c := by
  simpa using tchar_all ⟨c.toNat, c.toNat_lt⟩

theorem fieldChar_all : ∀ v : Fin 256,
    Http.fieldChar v.val.toUInt8 = (Spec.Http.isVchar v.val.toUInt8 || Spec.Http.isWs v.val.toUInt8) := by
  decide +kernel

/-- A byte of a field line's value: field-vchar, SP or HTAB. -/
theorem Http.fieldChar_eq (c : UInt8) : Http.fieldChar c = (Spec.Http.isVchar c || Spec.Http.isWs c) := by
  simpa using fieldChar_all ⟨c.toNat, c.toNat_lt⟩

theorem lower_all : ∀ v : Fin 256,
    Http.lower v.val.toUInt8 =
      if 0x41 ≤ v.val.toUInt8 ∧ v.val.toUInt8 ≤ 0x5a then v.val.toUInt8 + 32 else v.val.toUInt8 := by
  decide +kernel

theorem Http.lower_eq (c : UInt8) : Http.lower c = if 0x41 ≤ c ∧ c ≤ 0x5a then c + 32 else c := by
  simpa using lower_all ⟨c.toNat, c.toNat_lt⟩

/-- not SP, CR or LF -/
def notSpCrLf (c : UInt8) : Bool := !(c == 0x20 || c == 0x0d || c == 0x0a)

theorem notSpCrLf_iff (c : UInt8) : notSpCrLf c = true ↔ c ≠ 0x20 ∧ c ≠ 0x0d ∧ c ≠ 0x0a := by
  unfold notSpCrLf
  by_cases h1 : c = 0x20 <;> by_cases h2 : c = 0x0d <;> by_cases h3 : c = 0x0a <;> simp_all

theorem crlf_not_tchar : Spec.Http.isTchar 0x0d = false ∧ Spec.Http.isTchar 0x0a = false ∧
    Spec.Http.isTchar 0x3a = false ∧ Spec.Http.isTchar 0x20 = false := by decide

theorem crlf_not_field : (Spec.Http.isVchar 0x0d || Spec.Http.isWs 0x0d) = false ∧
    (Spec.Http.isVchar 0x0a || Spec.Http.isWs 0x0a) = false := by decide

/-! ## The scans of a line -/

theorem Http.tokenEnd_eq (a : ByteArray) (i : Nat) {hi : Nat} (h : hi ≤ a.size) :
    Http.tokenEnd a i hi = i + ((slice a i hi).takeWhile Spec.Http.isTchar).length := by
  have hp : Spec.Http.isTchar = Http.tchar := funext fun c => (Http.tchar_eq c).symm
  rw [hp]
  exact scan_while_slice Http.tchar (Http.tokenEnd.go a) (fun _ => rfl) (fun _ _ => rfl) h

theorem Http.targetEnd_eq (a : ByteArray) (i : Nat) {hi : Nat} (h : hi ≤ a.size) :
    Http.targetEnd a i hi = i + ((slice a i hi).takeWhile notSpCrLf).length := by
  refine scan_while_slice notSpCrLf (Http.targetEnd.go a) (fun _ => rfl) (fun i f => ?_) h
  show (if (Http.byte a i == 0x20 || Http.byte a i == 0x0d || Http.byte a i == 0x0a) = true then i
    else Http.targetEnd.go a (i + 1) f) = _
  unfold notSpCrLf Http.byte
  cases (a.get! i == 0x20 || a.get! i == 0x0d || a.get! i == 0x0a) <;> rfl

theorem Http.valueEnd_eq (a : ByteArray) (i : Nat) {hi : Nat} (h : hi ≤ a.size) :
    Http.valueEnd a i hi = i + ((slice a i hi).takeWhile fun c => Spec.Http.isVchar c || Spec.Http.isWs c).length := by
  have hp : (fun c => Spec.Http.isVchar c || Spec.Http.isWs c) = Http.fieldChar :=
    funext fun c => (Http.fieldChar_eq c).symm
  rw [hp]
  exact scan_while_slice Http.fieldChar (Http.valueEnd.go a) (fun _ => rfl) (fun _ _ => rfl) h

theorem Http.skipL_eq (a : ByteArray) (s : Nat) {e : Nat} (h : e ≤ a.size) :
    Http.skipL a s e = s + ((slice a s e).takeWhile Spec.Http.isWs).length :=
  scan_while_slice Spec.Http.isWs (Http.skipL.go a) (fun _ => rfl) (fun _ _ => rfl) h

theorem Http.skipZeros_eq (a : ByteArray) (i : Nat) {hi : Nat} (h : hi ≤ a.size) :
    Http.skipZeros a i hi = i + ((slice a i hi).takeWhile (· == 0x30)).length :=
  scan_while_slice (· == 0x30) (Http.skipZeros.go a) (fun _ => rfl) (fun _ _ => rfl) h

theorem skipR_go (a : ByteArray) : ∀ f e, f ≤ e → e ≤ a.size →
    Http.skipR.go a e f = e - ((slice a (e - f) e).reverse.takeWhile Spec.Http.isWs).length := by
  intro f
  induction f with
  | zero => intro e _ _; rw [Nat.sub_zero, slice_empty]; rfl
  | succ f ih =>
    intro e hf he
    have hsl : slice a (e - (f + 1)) e = slice a (e - 1 - f) (e - 1) ++ [a.get! (e - 1)] := by
      rw [slice_append a (mid := e - 1) (by omega) (by omega), slice_cons a (by omega) he,
        show e - 1 + 1 = e by omega, slice_empty, show e - (f + 1) = e - 1 - f by omega]
    rw [hsl, List.reverse_append, List.reverse_singleton, List.singleton_append, List.takeWhile_cons]
    show (if (Http.byte a (e - 1) == 0x20 || Http.byte a (e - 1) == 0x09) = true then Http.skipR.go a (e - 1) f
      else e) = _
    by_cases hw : Spec.Http.isWs (a.get! (e - 1)) = true
    · have hw' : (Http.byte a (e - 1) == 0x20 || Http.byte a (e - 1) == 0x09) = true := hw
      rw [ite_eq_left hw', ite_eq_left hw, ih (e - 1) (by omega) (by omega)]
      simp only [List.length_cons]
      have := takeWhile_length_le Spec.Http.isWs (slice a (e - 1 - f) (e - 1)).reverse
      simp only [List.length_reverse, slice_length a (show e - 1 ≤ a.size by omega)] at this
      omega
    · have hw' : ¬ (Http.byte a (e - 1) == 0x20 || Http.byte a (e - 1) == 0x09) = true := hw
      rw [ite_eq_right hw', ite_eq_right hw]
      rfl

/-- `skipR` stops after the last byte of the range that is not SP or HTAB. -/
theorem Http.skipR_eq (a : ByteArray) {s e : Nat} (h : s ≤ e) (h' : e ≤ a.size) :
    s ≤ Http.skipR a s e ∧ Http.skipR a s e ≤ e ∧
      slice a s (Http.skipR a s e) = ((slice a s e).reverse.dropWhile Spec.Http.isWs).reverse := by
  have hg := skipR_go a (e - s) e (by omega) h'
  rw [show e - (e - s) = s by omega] at hg
  unfold Http.skipR
  rw [hg]
  have hlen := takeWhile_length_le Spec.Http.isWs (slice a s e).reverse
  have hsl := slice_length a (lo := s) h'
  rw [List.length_reverse, hsl] at hlen
  refine ⟨by omega, by omega, ?_⟩
  rw [← drop_takeWhile, List.drop_reverse, List.reverse_reverse, slice_take a (lo := s) (hi := e) _ (by omega)]
  congr 1
  rw [hsl]
  omega

/-- The value of a field line: the bytes between OWS (RFC 9112 §5). -/
theorem Http.trim_eq (a : ByteArray) {s e : Nat} (h : s ≤ e) (h' : e ≤ a.size) :
    s ≤ Http.skipL a s e ∧ Http.skipL a s e ≤ Http.skipR a (Http.skipL a s e) e ∧
      Http.skipR a (Http.skipL a s e) e ≤ e ∧
      slice a (Http.skipL a s e) (Http.skipR a (Http.skipL a s e) e) = Spec.Http.trimOws (slice a s e) := by
  have hl := Http.skipL_eq a s h'
  have ⟨_, hd⟩ := slice_takeWhile a Spec.Http.isWs (i := s) h'
  have hlen := takeWhile_length_le Spec.Http.isWs (slice a s e)
  rw [slice_length a h'] at hlen
  rw [← hl] at hd
  have hle : Http.skipL a s e ≤ e := by omega
  obtain ⟨h1, h2, h3⟩ := Http.skipR_eq a hle h'
  refine ⟨by omega, h1, h2, ?_⟩
  rw [h3, hd]
  rfl

/-! ## Comparisons -/

theorem lower_eq_map (s : List UInt8) : Spec.Http.lower s = s.map Feed.Http.lower := by
  unfold Spec.Http.lower
  congr 1
  funext b
  rw [Http.lower_eq]

theorem eqCI_go (a lit : ByteArray) (lo : Nat) :
    ∀ f k, Http.eqCI.go a lo lit k f = true ↔ ∀ j, k ≤ j → j < k + f → Http.lower (a.get! (lo + j)) = lit.get! j := by
  intro f
  induction f with
  | zero => intro k; simp only [Http.eqCI.go, true_iff]; intro j h1 h2; omega
  | succ f ih =>
    intro k
    simp only [Http.eqCI.go, Bool.and_eq_true, beq_iff_eq, Http.byte, ih (k + 1)]
    constructor
    · rintro ⟨h0, hr⟩ j h1 h2
      rcases Nat.eq_or_lt_of_le h1 with rfl | hlt
      · exact h0
      · exact hr j (by omega) (by omega)
    · intro h
      exact ⟨h k (Nat.le_refl _) (by omega), fun j h1 h2 => h j (by omega) (by omega)⟩

/-- `eqCI` compares a range of the input with a literal, ignoring ASCII case. -/
theorem eqCI_spec (a lit : ByteArray) {lo hi : Nat} (h' : hi ≤ a.size) :
    Http.eqCI a lo hi lit = true ↔ Spec.Http.lower (slice a lo hi) = bs lit := by
  rw [lower_eq_map, map_slice_eq_iff a _ h', Http.eqCI, Bool.and_eq_true, beq_iff_eq, eqCI_go,
    ← size_eq_length]
  constructor
  · rintro ⟨hl, hk⟩
    refine ⟨hl, fun k hk' => ?_⟩
    rw [hk k (Nat.zero_le _) (by omega), get!_eq]
  · rintro ⟨hl, hk⟩
    refine ⟨hl, fun j _ hj => ?_⟩
    rw [hk j (by simpa using hj), get!_eq]

/-- **Field names are compared as RFC 9110 §5.1 says**: `eqCI` holds of a range and a lowercase
literal exactly when the range, in lowercase, is the literal. -/
theorem Http.eqCI_iff (a lit : ByteArray) {lo hi : Nat} (_ : lo ≤ hi) (h' : hi ≤ a.size)
    (_ : Spec.Http.lower (bs lit) = bs lit) :
    Http.eqCI a lo hi lit = true ↔ Spec.Http.lower (slice a lo hi) = bs lit :=
  eqCI_spec a lit h'

/-- info: 'Feed.Http.eqCI_iff' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms Http.eqCI_iff

theorem sameBytes_go (a : ByteArray) (lo lo' : Nat) :
    ∀ f k, Http.sameBytes.go a lo lo' k f = true ↔ ∀ j, k ≤ j → j < k + f → a.get! (lo + j) = a.get! (lo' + j) := by
  intro f
  induction f with
  | zero => intro k; simp only [Http.sameBytes.go, true_iff]; intro j h1 h2; omega
  | succ f ih =>
    intro k
    simp only [Http.sameBytes.go, Bool.and_eq_true, beq_iff_eq, Http.byte, ih (k + 1)]
    constructor
    · rintro ⟨h0, hr⟩ j h1 h2
      rcases Nat.eq_or_lt_of_le h1 with rfl | hlt
      · exact h0
      · exact hr j (by omega) (by omega)
    · intro h
      exact ⟨h k (Nat.le_refl _) (by omega), fun j h1 h2 => h j (by omega) (by omega)⟩

/-- `sameBytes` compares two ranges of the input. -/
theorem Http.sameBytes_iff (a : ByteArray) {lo hi lo' hi' : Nat} (h₁ : hi ≤ a.size) (h₂ : hi' ≤ a.size) :
    Http.sameBytes a lo hi lo' hi' = true ↔ slice a lo hi = slice a lo' hi' := by
  rw [Http.sameBytes, Bool.and_eq_true, beq_iff_eq, sameBytes_go]
  constructor
  · rintro ⟨hl, hk⟩
    apply List.ext_getElem?
    intro k
    by_cases hk' : k < hi - lo
    · rw [slice_getElem? a (by omega) h₁, slice_getElem? a (by omega) h₂, hk k (Nat.zero_le _) (by omega)]
    · rw [List.getElem?_eq_none (by rw [slice_length a h₁]; omega),
        List.getElem?_eq_none (by rw [slice_length a h₂]; omega)]
  · intro h
    have hl : hi - lo = hi' - lo' := by rw [← slice_length a h₁, ← slice_length a h₂, h]
    refine ⟨hl, fun j _ hj => ?_⟩
    have e1 := slice_getElem? a (lo := lo) (hi := hi) (k := j) (by omega) h₁
    have e2 := slice_getElem? a (lo := lo') (hi := hi') (k := j) (by omega) h₂
    rw [h, e2] at e1
    exact (Option.some.inj e1).symm

theorem Http.eqAt_lit_iff (a : ByteArray) {lo hi : Nat} (h : lo ≤ hi) (h' : hi ≤ a.size) (lit : ByteArray) :
    Http.eqAt a lo hi lit = Decidable.decide (slice a lo hi = bs lit) := by
  apply Bool.eq_iff_iff.mpr
  rw [eqAt_spec a lit h h', decide_eq_true_iff]

/-! ## Numbers -/

theorem decimal_isSome : ∀ (l : List UInt8) (acc : Nat), (∀ c ∈ l, Spec.Http.isDigit c = true) →
    ∃ n, decimal l acc = some n
  | [], acc, _ => ⟨acc, rfl⟩
  | c :: l, acc, h => by
    have hc := h c List.mem_cons_self
    simp only [Spec.Http.isDigit, Bool.and_eq_true, decide_eq_true_eq] at hc
    rw [decimal, ite_eq_left hc]
    exact decimal_isSome l _ fun x hx => h x (List.mem_cons_of_mem _ hx)

/-- The value grows with the digits. -/
theorem decimal_ge : ∀ (l : List UInt8) (acc n : Nat), decimal l acc = some n → acc ≤ n
  | [], acc, n, h => by simp [decimal] at h; omega
  | c :: l, acc, n, h => by
    rw [decimal] at h
    split at h
    · have := decimal_ge l _ n h; omega
    · exact absurd h (by simp)

theorem decimal_snoc : ∀ (u : List UInt8) (d : UInt8) (acc : Nat),
    decimal (u ++ [d]) acc = (decimal u acc).bind fun n => decimal [d] n
  | [], d, acc => rfl
  | c :: u, d, acc => by
    simp only [List.cons_append, decimal]
    split
    · exact decimal_snoc u d _
    · rfl

/-- Leading zeros do not change the value. -/
theorem decimal_dropZeros : ∀ (l : List UInt8), decimal (l.dropWhile (· == 0x30)) 0 = decimal l 0
  | [] => rfl
  | c :: l => by
    rw [List.dropWhile_cons]
    by_cases hc : (c == 0x30) = true
    · rw [ite_eq_left hc, decimal_dropZeros l, decimal, ite_eq_left (by simp at hc; subst hc; decide)]
      simp at hc; subst hc; rfl
    · rw [ite_eq_right hc]

theorem digit_val_inj {d e : UInt8} (hd : Spec.Http.isDigit d = true) (he : Spec.Http.isDigit e = true)
    (h : (d - 0x30).toNat = (e - 0x30).toNat) : d = e := by
  simp only [Spec.Http.isDigit, Bool.and_eq_true, decide_eq_true_eq, UInt8.le_iff_toNat_le] at hd he
  rw [UInt8.toNat_sub_of_le _ _ (by rw [UInt8.le_iff_toNat_le]; exact hd.1),
    UInt8.toNat_sub_of_le _ _ (by rw [UInt8.le_iff_toNat_le]; exact he.1)] at h
  apply UInt8.toNat_inj.mp
  have : UInt8.toNat 0x30 = 48 := rfl
  omega

/-- Digit strings without leading zeros that have the same value are the same. -/
theorem decimal_inj : ∀ (k : Nat) (u w : List UInt8), u.length + w.length ≤ k →
    (∀ c ∈ u.head?, c ≠ 0x30) → (∀ c ∈ w.head?, c ≠ 0x30) →
    (∀ c ∈ u, Spec.Http.isDigit c = true) → (∀ c ∈ w, Spec.Http.isDigit c = true) →
    decimal u 0 = decimal w 0 → u = w := by
  intro k
  induction k with
  | zero =>
    intro u w hk _ _ _ _ _
    rw [List.eq_nil_of_length_eq_zero (by omega : u.length = 0),
      List.eq_nil_of_length_eq_zero (by omega : w.length = 0)]
  | succ k ih =>
    intro u w hk hu hw du dw h
    -- a nonempty digit string without a leading zero has a value of at least 1
    have pos : ∀ x : List UInt8, x ≠ [] → (∀ c ∈ x.head?, c ≠ 0x30) → (∀ c ∈ x, Spec.Http.isDigit c = true) →
        ∀ n, decimal x 0 = some n → 1 ≤ n := by
      intro x hx hh hd n hn
      match x, hx with
      | c :: x, _ =>
        have hc := hd c List.mem_cons_self
        have hc0 := hh c rfl
        rw [decimal, ite_eq_left (by simpa [Spec.Http.isDigit] using hc)] at hn
        have := decimal_ge x _ n hn
        have : (c - 0x30).toNat ≠ 0 := by
          intro h0
          apply hc0
          simp only [Spec.Http.isDigit, Bool.and_eq_true, decide_eq_true_eq, UInt8.le_iff_toNat_le] at hc
          rw [UInt8.toNat_sub_of_le _ _ (by rw [UInt8.le_iff_toNat_le]; exact hc.1)] at h0
          apply UInt8.toNat_inj.mp
          have : UInt8.toNat 0x30 = 48 := rfl
          omega
        omega
    rcases List.eq_nil_or_concat u with rfl | ⟨u', d, rfl⟩ <;> rcases List.eq_nil_or_concat w with rfl | ⟨w', e, rfl⟩
    · rfl
    · exfalso
      obtain ⟨n, hn⟩ := decimal_isSome _ 0 dw
      have := pos _ (by simp) hw dw n hn
      rw [hn] at h
      simp [decimal] at h
      omega
    · exfalso
      obtain ⟨n, hn⟩ := decimal_isSome _ 0 du
      have := pos _ (by simp) hu du n hn
      rw [hn] at h
      simp [decimal] at h
      omega
    · simp only [List.concat_eq_append] at *
      have du' : ∀ c ∈ u', Spec.Http.isDigit c = true := fun c hc => du c (List.mem_append_left _ hc)
      have dw' : ∀ c ∈ w', Spec.Http.isDigit c = true := fun c hc => dw c (List.mem_append_left _ hc)
      have hd := du d (List.mem_append_right _ List.mem_cons_self)
      have he := dw e (List.mem_append_right _ List.mem_cons_self)
      obtain ⟨n, hn⟩ := decimal_isSome u' 0 du'
      obtain ⟨m, hm⟩ := decimal_isSome w' 0 dw'
      rw [decimal_snoc, decimal_snoc, hn, hm] at h
      have hd' : 0x30 ≤ d ∧ d ≤ 0x39 := by simpa [Spec.Http.isDigit] using hd
      have he' : 0x30 ≤ e ∧ e ≤ 0x39 := by simpa [Spec.Http.isDigit] using he
      simp only [Option.bind_some, decimal, ite_eq_left hd', ite_eq_left he', Option.some.injEq] at h
      have hdl : (d - 0x30).toNat < 10 := by
        simp only [UInt8.le_iff_toNat_le] at hd'
        rw [UInt8.toNat_sub_of_le _ _ (by rw [UInt8.le_iff_toNat_le]; exact hd'.1)]
        have : UInt8.toNat 0x30 = 48 := rfl
        have : UInt8.toNat 0x39 = 57 := rfl
        omega
      have hel : (e - 0x30).toNat < 10 := by
        simp only [UInt8.le_iff_toNat_le] at he'
        rw [UInt8.toNat_sub_of_le _ _ (by rw [UInt8.le_iff_toNat_le]; exact he'.1)]
        have : UInt8.toNat 0x30 = 48 := rfl
        have : UInt8.toNat 0x39 = 57 := rfl
        omega
      have hde : (d - 0x30).toNat = (e - 0x30).toNat := by omega
      have hnm : n = m := by omega
      have hu' : ∀ c ∈ u'.head?, c ≠ 0x30 := by
        intro c hc
        cases u' with
        | nil => simp at hc
        | cons x u' => exact hu c (by simpa using hc)
      have hw' : ∀ c ∈ w'.head?, c ≠ 0x30 := by
        intro c hc
        cases w' with
        | nil => simp at hc
        | cons x w' => exact hw c (by simpa using hc)
      rw [ih u' w' (by simp at hk; omega) hu' hw' du' dw' (by rw [hn, hm, hnm]), digit_val_inj hd he hde]

theorem head_dropZeros (l : List UInt8) : ∀ c ∈ (l.dropWhile (· == 0x30)).head?, c ≠ 0x30 := by
  intro c hc
  have := List.head?_dropWhile_not (· == 0x30) l
  rw [Option.mem_def] at hc
  rw [hc] at this
  simpa using this

/-- Two digit strings have the same value exactly when they are the same after their leading zeros. -/
theorem decimal_eq_iff {v w : List UInt8} (hv : ∀ c ∈ v, Spec.Http.isDigit c = true)
    (hw : ∀ c ∈ w, Spec.Http.isDigit c = true) :
    decimal v 0 = decimal w 0 ↔ v.dropWhile (· == 0x30) = w.dropWhile (· == 0x30) := by
  constructor
  · intro h
    apply decimal_inj _ _ _ (Nat.le_refl _) (head_dropZeros v) (head_dropZeros w)
      (fun c hc => hv c (mem_of_mem_dropWhile hc)) (fun c hc => hw c (mem_of_mem_dropWhile hc))
    rw [decimal_dropZeros, decimal_dropZeros, h]
  · intro h
    rw [← decimal_dropZeros v, h, decimal_dropZeros]

theorem lengthOf_go (a : ByteArray) : ∀ f i acc n, i + f ≤ a.size → acc ≤ Http.maxBody →
    decimal (slice a i (i + f)) acc = some n → Http.lengthOf.go a i f acc = min n (Http.maxBody + 1) := by
  intro f
  induction f with
  | zero =>
    intro i acc n _ hacc h
    rw [Nat.add_zero, slice_empty] at h
    simp only [decimal, Option.some.injEq] at h
    subst h
    show acc = _
    omega
  | succ f ih =>
    intro i acc n hf hacc h
    rw [slice_cons a (by omega) hf, decimal] at h
    split at h
    · show (if acc * 10 + (Http.byte a i - 0x30).toNat > Http.maxBody then Http.maxBody + 1
        else Http.lengthOf.go a (i + 1) f (acc * 10 + (Http.byte a i - 0x30).toNat)) = _
      have hn := decimal_ge _ _ n h
      by_cases hbig : acc * 10 + (Http.byte a i - 0x30).toNat > Http.maxBody
      · rw [ite_eq_left hbig]
        simp only [Http.byte] at hbig
        omega
      · rw [ite_eq_right hbig,
          ih (i + 1) _ n (by omega) (by omega) (by rw [show i + 1 + f = i + (f + 1) by omega]; exact h)]
    · exact absurd h (by simp)

/-- **Content-Length is read as a decimal number of any length**: `lengthOf` is its value, or
`maxBody + 1` for any value above `maxBody`. -/
theorem Http.lengthOf_eq (a : ByteArray) {lo hi n : Nat} (h' : hi ≤ a.size) (h : decimal (slice a lo hi) 0 = some n) :
    Http.lengthOf a lo hi = min n (Http.maxBody + 1) := by
  unfold Http.lengthOf
  by_cases hle : lo ≤ hi
  · exact lengthOf_go a (hi - lo) lo 0 n (by omega) (Nat.zero_le _) (by rw [show lo + (hi - lo) = hi by omega]; exact h)
  · have he : slice a lo hi = [] := by simp [slice, show hi - lo = 0 by omega]
    rw [he] at h
    simp only [decimal, Option.some.injEq] at h
    subst h
    rw [show hi - lo = 0 by omega]
    rfl

/-- info: 'Feed.Http.lengthOf_eq' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms Http.lengthOf_eq

theorem Http.allDigits_eq (a : ByteArray) (lo : Nat) {hi : Nat} (h' : hi ≤ a.size) :
    Http.allDigits a lo hi = (slice a lo hi).all Spec.Http.isDigit := by
  unfold Http.allDigits
  by_cases hle : lo ≤ hi
  · rw [all_while Spec.Http.isDigit (Http.allDigits.go a) (fun _ => rfl) (fun _ _ => rfl) (hi - lo) lo (by omega),
      show lo + (hi - lo) = hi by omega]
  · rw [show hi - lo = 0 by omega, show slice a lo hi = [] by simp [slice, show hi - lo = 0 by omega]]
    rfl

/-! ## Connection options -/

theorem splitComma_comma : ∀ (u w : List UInt8), (∀ c ∈ u, c ≠ 0x2c) →
    Spec.Http.splitComma (u ++ 0x2c :: w) = u :: Spec.Http.splitComma w
  | [], w, _ => by simp [Spec.Http.splitComma]
  | c :: u, w, h => by
    have hc : c ≠ 0x2c := h c List.mem_cons_self
    simp only [List.cons_append, Spec.Http.splitComma, hc, ↓reduceIte,
      splitComma_comma u w (fun x hx => h x (List.mem_cons_of_mem _ hx))]
    rfl

theorem splitComma_none : ∀ (u : List UInt8), (∀ c ∈ u, c ≠ 0x2c) → Spec.Http.splitComma u = [u]
  | [], _ => rfl
  | c :: u, h => by
    have hc : c ≠ 0x2c := h c List.mem_cons_self
    simp only [Spec.Http.splitComma, hc, ↓reduceIte, splitComma_none u (fun x hx => h x (List.mem_cons_of_mem _ hx))]
    rfl

/-- One member's test, as `hasToken` makes it on the element between two commas. -/
theorem any_member (x tok : List UInt8) (ht : tok ≠ []) :
    ((if Spec.Http.trimOws x ≠ [] then [Spec.Http.trimOws x] else []).any (Spec.Http.lower · == tok)) =
      (Spec.Http.lower (Spec.Http.trimOws x) == tok) := by
  by_cases hx : Spec.Http.trimOws x = []
  · rw [hx]
    simp only [ne_eq, not_true_eq_false, ↓reduceIte, List.any_nil]
    symm
    simp only [beq_eq_false_iff_ne, ne_eq]
    intro he
    apply ht
    rw [← he]
    rfl
  · simp [hx]

theorem members_comma (u w : List UInt8) (h : ∀ c ∈ u, c ≠ 0x2c) :
    Spec.Http.members (u ++ 0x2c :: w) =
      (if Spec.Http.trimOws u ≠ [] then [Spec.Http.trimOws u] else []) ++ Spec.Http.members w := by
  simp only [Spec.Http.members, splitComma_comma u w h, List.map_cons, List.filter_cons]
  by_cases hu : Spec.Http.trimOws u = [] <;> simp [hu]

theorem members_none (u : List UInt8) (h : ∀ c ∈ u, c ≠ 0x2c) :
    Spec.Http.members u = if Spec.Http.trimOws u ≠ [] then [Spec.Http.trimOws u] else [] := by
  simp only [Spec.Http.members, splitComma_none u h, List.map_cons, List.map_nil, List.filter_cons, List.filter_nil]
  by_cases hu : Spec.Http.trimOws u = [] <;> simp [hu]

theorem hasToken_go (a tok : ByteArray) {hi : Nat} (h' : hi ≤ a.size) (ht : bs tok ≠ []) :
    ∀ f i, i ≤ hi → hi + 1 - i ≤ f →
      Http.hasToken.go a hi tok i f = (Spec.Http.members (slice a i hi)).any (Spec.Http.lower · == bs tok) := by
  intro f
  induction f with
  | zero => intro i _ hf; omega
  | succ f ih =>
    intro i hi' hf
    simp only [Http.hasToken.go]
    by_cases hend : i ≥ hi
    · rw [ite_eq_left hend, show i = hi by omega, slice_empty]
      rfl
    rw [ite_eq_right hend]
    obtain ⟨e1, e2, e3, e4⟩ := Bytes.findByte_first a 0x2c (lo := i) (hi := hi) (by omega)
    rw [show min hi a.size = hi by omega] at e2 e4
    generalize Bytes.findByte a 0x2c i hi = e at e1 e2 e3 e4
    obtain ⟨t1, t2, t3, t4⟩ := Http.trim_eq a e1 (by omega)
    have hci : Http.eqCI a (Http.skipL a i e) (Http.skipR a (Http.skipL a i e) e) tok =
        (Spec.Http.lower (Spec.Http.trimOws (slice a i e)) == bs tok) := by
      apply Bool.eq_iff_iff.mpr
      rw [eqCI_spec a tok (by omega), t4, beq_iff_eq]
    rw [hci]
    have hnc : ∀ c ∈ slice a i e, c ≠ 0x2c := by
      intro c hc
      obtain ⟨k, hk, hkc⟩ := List.getElem_of_mem hc
      rw [slice_length a (by omega)] at hk
      have := slice_getElem? a (lo := i) (hi := e) (k := k) (by omega) (by omega)
      rw [List.getElem?_eq_getElem (by rw [slice_length a (by omega)]; omega), hkc] at this
      rw [Option.some.inj this]
      exact e3 (i + k) (by omega) (by omega)
    by_cases hlast : e < hi
    · have hsl : slice a i hi = slice a i e ++ 0x2c :: slice a (e + 1) hi := by
        rw [slice_append a (mid := e) (by omega) (by omega), slice_cons a hlast h', e4 hlast]
      rw [hsl, members_comma _ _ hnc, List.any_append, any_member _ _ ht, ih (e + 1) (by omega) (by omega)]
    · have he : e = hi := by omega
      subst he
      rw [members_none _ hnc, any_member _ _ ht]
      cases f with
      | zero => simp [Http.hasToken.go]
      | succ f => simp [Http.hasToken.go]

/-- **Connection options are read as RFC 9110 §5.6.1 and §7.6.1 say**: `hasToken` holds of a value
and a (non-empty) option exactly when the option is one of the value's members, in any case. -/
theorem Http.hasToken_eq (a tok : ByteArray) {lo hi : Nat} (h : lo ≤ hi) (h' : hi ≤ a.size) (ht : bs tok ≠ []) :
    Http.hasToken a lo hi tok = (Spec.Http.members (slice a lo hi)).any (Spec.Http.lower · == bs tok) :=
  hasToken_go a tok h' ht _ lo h (by omega)

/-- info: 'Feed.Http.hasToken_eq' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms Http.hasToken_eq

/-! ## Field lines -/

/-- A field value is what OWS around it trims to. -/
theorem trimOws_eq {w₁ v w₂ : Spec.Http.Bytes} (h₁ : Spec.Http.Ows w₁) (h₂ : Spec.Http.Ows w₂)
    (hv : Spec.Http.FieldValue v) : Spec.Http.trimOws (w₁ ++ v ++ w₂) = v := by
  unfold Spec.Http.trimOws
  rw [List.append_assoc, List.dropWhile_append_of_pos h₁]
  by_cases hv0 : v = []
  · subst hv0
    rw [List.nil_append, dropWhile_all h₂]
    rfl
  · have d1 : (v ++ w₂).dropWhile Spec.Http.isWs = v ++ w₂ := dropWhile_of_head (by
      intro c hc
      have : (v ++ w₂).head? = v.head? := by cases v with | nil => exact absurd rfl hv0 | cons x v => rfl
      rw [this] at hc
      exact hv.2.1 c hc)
    have d2 : v.reverse.dropWhile Spec.Http.isWs = v.reverse := dropWhile_of_head (by
      intro c hc
      rw [List.head?_reverse] at hc
      exact hv.2.2 c hc)
    rw [d1, List.reverse_append, List.dropWhile_append_of_pos (fun c hc => h₂ c (List.mem_reverse.mp hc)), d2,
      List.reverse_reverse]

theorem ows_takeWhile (l : Spec.Http.Bytes) : Spec.Http.Ows (l.takeWhile Spec.Http.isWs) :=
  fun _ hc => of_mem_takeWhile hc

/-- The bytes around a trimmed value are OWS. -/
theorem split_trim (rest : Spec.Http.Bytes) :
    rest = rest.takeWhile Spec.Http.isWs ++ Spec.Http.trimOws rest ++
      ((rest.dropWhile Spec.Http.isWs).reverse.takeWhile Spec.Http.isWs).reverse := by
  have e2 : Spec.Http.trimOws rest ++ ((rest.dropWhile Spec.Http.isWs).reverse.takeWhile Spec.Http.isWs).reverse =
      rest.dropWhile Spec.Http.isWs := by
    unfold Spec.Http.trimOws
    rw [← List.reverse_append, List.takeWhile_append_dropWhile, List.reverse_reverse]
  rw [List.append_assoc, e2, List.takeWhile_append_dropWhile]

/-- **A field line is a name, ":" and a value, in one way only** (RFC 9112 §5): its name is a
token, and its value is what follows the ":" without the OWS at either end. -/
theorem Spec.Http.fieldLine_iff (l n v : Spec.Http.Bytes) :
    Spec.Http.FieldLine l n v ↔ Spec.Http.IsToken n ∧ ∃ rest, l = n ++ [0x3a] ++ rest ∧
      (∀ c ∈ rest, (Spec.Http.isVchar c || Spec.Http.isWs c) = true) ∧ v = Spec.Http.trimOws rest := by
  constructor
  · rintro ⟨hn, hv, w₁, w₂, h₁, h₂, rfl⟩
    refine ⟨hn, w₁ ++ v ++ w₂, by simp [List.append_assoc], ?_, (trimOws_eq h₁ h₂ hv).symm⟩
    intro c hc
    simp only [List.mem_append] at hc
    rcases hc with (hc | hc) | hc
    · simp [h₁ c hc]
    · exact hv.1 c hc
    · simp [h₂ c hc]
  · rintro ⟨hn, rest, rfl, hr, rfl⟩
    have hs := split_trim rest
    have e2 : Spec.Http.trimOws rest ++ ((rest.dropWhile Spec.Http.isWs).reverse.takeWhile Spec.Http.isWs).reverse =
        rest.dropWhile Spec.Http.isWs := by
      unfold Spec.Http.trimOws
      rw [← List.reverse_append, List.takeWhile_append_dropWhile, List.reverse_reverse]
    refine ⟨hn, ⟨fun c hc => hr c ?_, ?_, ?_⟩, rest.takeWhile Spec.Http.isWs,
      ((rest.dropWhile Spec.Http.isWs).reverse.takeWhile Spec.Http.isWs).reverse, ows_takeWhile rest, ?_, ?_⟩
    · rw [hs]; simp [hc]
    · intro c hc
      have : (rest.dropWhile Spec.Http.isWs).head? = some c := by
        rw [← e2]
        cases h : Spec.Http.trimOws rest with
        | nil => rw [h] at hc; simp at hc
        | cons x t => rw [h] at hc; simp at hc; subst hc; rfl
      exact head_dropWhile _ _ c this
    · intro c hc
      unfold Spec.Http.trimOws at hc
      rw [List.getLast?_reverse] at hc
      exact head_dropWhile _ _ c hc
    · intro c hc
      exact of_mem_takeWhile (List.mem_reverse.mp hc)
    · conv => lhs; rw [hs]
      simp only [List.append_assoc]

/-- info: 'Feed.Spec.Http.fieldLine_iff' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms Spec.Http.fieldLine_iff

theorem token_not_mem {n : Spec.Http.Bytes} (hn : Spec.Http.IsToken n) {x : UInt8} (hx : Spec.Http.isTchar x = false) :
    x ∉ n := fun h => by rw [hn.2 x h] at hx; exact absurd hx (by decide)

theorem Spec.Http.fieldLine_unique {l n v n' v' : Spec.Http.Bytes} (h : Spec.Http.FieldLine l n v)
    (h' : Spec.Http.FieldLine l n' v') : n = n' ∧ v = v' := by
  obtain ⟨hn, rest, rfl, -, rfl⟩ := (Spec.Http.fieldLine_iff _ _ _).mp h
  obtain ⟨hn', rest', he, -, rfl⟩ := (Spec.Http.fieldLine_iff _ _ _).mp h'
  simp only [List.append_assoc, List.singleton_append] at he
  obtain ⟨h1, h2⟩ := cancel_sep (token_not_mem hn (by decide)) (token_not_mem hn' (by decide)) he
  exact ⟨h1, by rw [h2]⟩

/-- `r` is the field lines `fls`, each ended by CR LF, then the empty line; `fs` are their names and
values. -/
def FieldLines (r : Spec.Http.Bytes) (fls : List Spec.Http.Bytes) (fs : List (Spec.Http.Bytes × Spec.Http.Bytes)) :
    Prop :=
  r = (fls.map (· ++ Spec.Http.crlf)).flatten ++ Spec.Http.crlf ∧ (∀ l ∈ fls, l ≠ [] ∧ 0x0d ∉ l ∧ 0x0a ∉ l) ∧
    fls.length = fs.length ∧ ∀ p ∈ fls.zip fs, Spec.Http.FieldLine p.1 p.2.1 p.2.2

/-- The lines of a head, each ended by CR LF and holding no CR, are cut at the CRs. -/
theorem lines_unique : ∀ {fls gls : List Spec.Http.Bytes}, (∀ l ∈ fls, l ≠ [] ∧ 0x0d ∉ l) →
    (∀ l ∈ gls, l ≠ [] ∧ 0x0d ∉ l) →
    (fls.map (· ++ Spec.Http.crlf)).flatten ++ Spec.Http.crlf =
      (gls.map (· ++ Spec.Http.crlf)).flatten ++ Spec.Http.crlf →
    fls = gls
  | [], [], _, _, _ => rfl
  | [], g :: gs, _, hg, h => by
    exfalso
    obtain ⟨hg0, hgc⟩ := hg g List.mem_cons_self
    cases g with
    | nil => exact hg0 rfl
    | cons c g =>
      simp only [List.map_nil, List.flatten_nil, List.nil_append, List.map_cons, List.flatten_cons, List.cons_append,
        Spec.Http.crlf, List.cons.injEq] at h
      exact hgc (h.1 ▸ List.mem_cons_self)
  | l :: ls, [], hl, _, h => by
    exfalso
    obtain ⟨hl0, hlc⟩ := hl l List.mem_cons_self
    cases l with
    | nil => exact hl0 rfl
    | cons c l =>
      simp only [List.map_nil, List.flatten_nil, List.nil_append, List.map_cons, List.flatten_cons, List.cons_append,
        Spec.Http.crlf, List.cons.injEq] at h
      exact hlc (h.1.symm ▸ List.mem_cons_self)
  | l :: ls, g :: gs, hl, hg, h => by
    simp only [List.map_cons, List.flatten_cons, Spec.Http.crlf, List.append_assoc, List.cons_append,
      List.nil_append] at h
    obtain ⟨h1, h2⟩ := cancel_sep (hl l List.mem_cons_self).2 (hg g List.mem_cons_self).2 h
    simp only [List.cons.injEq, true_and] at h2
    rw [h1, lines_unique (fun x hx => hl x (List.mem_cons_of_mem _ hx)) (fun x hx => hg x (List.mem_cons_of_mem _ hx))
      (by simpa [Spec.Http.crlf] using h2)]

theorem fields_unique : ∀ {fls : List Spec.Http.Bytes} {fs fs' : List (Spec.Http.Bytes × Spec.Http.Bytes)},
    fls.length = fs.length → fls.length = fs'.length →
    (∀ p ∈ fls.zip fs, Spec.Http.FieldLine p.1 p.2.1 p.2.2) → (∀ p ∈ fls.zip fs', Spec.Http.FieldLine p.1 p.2.1 p.2.2) →
    fs = fs'
  | [], [], [], _, _, _, _ => rfl
  | l :: ls, (n, v) :: fs, (n', v') :: fs', h₁, h₂, h, h' => by
    simp only [List.zip_cons_cons, List.mem_cons, forall_eq_or_imp] at h h'
    obtain ⟨rfl, rfl⟩ := Spec.Http.fieldLine_unique h.1 h'.1
    rw [fields_unique (by simpa using h₁) (by simpa using h₂) h.2 h'.2]

/-! ## Heads -/

theorem lead_rep : ∀ (k : Nat) (y : Spec.Http.Bytes),
    Spec.Http.lead ((List.replicate k Spec.Http.crlf).flatten ++ y) = k + Spec.Http.lead y
  | 0, y => by simp
  | k + 1, y => by
    have e : (List.replicate (k + 1) Spec.Http.crlf).flatten ++ y =
        0x0d :: 0x0a :: ((List.replicate k Spec.Http.crlf).flatten ++ y) := by
      simp [List.replicate_succ, Spec.Http.crlf]
    rw [e, Spec.Http.lead, ite_eq_left ⟨rfl, rfl⟩, lead_rep k y]
    omega

theorem lead_zero : ∀ {y : Spec.Http.Bytes}, (∀ c ∈ y.head?, c ≠ 0x0d) → Spec.Http.lead y = 0
  | [], _ => rfl
  | [_], _ => rfl
  | c :: d :: y, h => by
    rw [Spec.Http.lead, ite_eq_right (fun hc => h c rfl hc.1)]

/-- A head's empty lines are its leading CR LFs. -/
theorem lead_head {h : Spec.Http.Bytes} {k : Nat} {line : Spec.Http.Bytes} {fls : List Spec.Http.Bytes}
    (hh : Spec.Http.HeadLines h k line fls) (rest : Spec.Http.Bytes) : Spec.Http.lead (h ++ rest) = k := by
  obtain ⟨rfl, hl⟩ := hh
  obtain ⟨hl0, hlc, -⟩ := hl line List.mem_cons_self
  simp only [List.append_assoc]
  rw [lead_rep, lead_zero]
  · rfl
  · cases line with
    | nil => exact absurd rfl hl0
    | cons c line => intro x hx; simp at hx; subst hx; exact fun he => hlc (he ▸ List.mem_cons_self)

/-- **A head has its parts in one way only**: the empty lines before it, the request-line and its
method, target and version, and the field lines with their names and values. -/
theorem Spec.Http.isHead_unique {h : Spec.Http.Bytes} {H H' : Spec.Http.Head} (hH : Spec.Http.IsHead h H)
    (hH' : Spec.Http.IsHead h H') : H = H' := by
  obtain ⟨k, line, method, target, major, minor, fls, fs⟩ := H
  obtain ⟨k', line', method', target', major', minor', fls', fs'⟩ := H'
  have hk : k = k' := by
    have e1 := lead_head hH.1 []
    rw [lead_head hH'.1 []] at e1
    exact e1.symm
  subst hk
  simp only [Spec.Http.IsHead, Spec.Http.HeadLines, Spec.Http.RequestLine, Spec.Http.Version] at hH hH'
  obtain ⟨⟨e, hl⟩, ⟨hm, -, hsp, v, ⟨a, b, -, -, hv, hmaj, hmin⟩, hline⟩, hlen, hfs⟩ := hH
  obtain ⟨⟨e', hl'⟩, ⟨hm', -, hsp', v', ⟨a', b', -, -, hv', hmaj', hmin'⟩, hline'⟩, hlen', hfs'⟩ := hH'
  have e := e.symm.trans e'
  simp only [List.append_assoc] at e
  have e := List.append_cancel_left e
  simp only [Spec.Http.crlf, List.cons_append, List.nil_append] at e
  obtain ⟨h1, h2⟩ := cancel_sep (hl _ List.mem_cons_self).2.1 (hl' _ List.mem_cons_self).2.1 e
  simp only [List.cons.injEq, true_and] at h2
  have hf : fls = fls' := lines_unique
    (fun l hm => ⟨(hl l (List.mem_cons_of_mem _ hm)).1, (hl l (List.mem_cons_of_mem _ hm)).2.1⟩)
    (fun l hm => ⟨(hl' l (List.mem_cons_of_mem _ hm)).1, (hl' l (List.mem_cons_of_mem _ hm)).2.1⟩)
    (by simpa [Spec.Http.crlf] using h2)
  subst hf h1
  rw [hline'] at hline
  simp only [List.append_assoc, List.singleton_append] at hline
  obtain ⟨hm1, h3⟩ := cancel_sep (token_not_mem hm' (by decide)) (token_not_mem hm (by decide)) hline
  obtain ⟨ht1, h4⟩ := cancel_sep hsp' hsp h3
  rw [hv, hv'] at h4
  have hab : a' = a ∧ b' = b := by
    have := List.append_cancel_left h4
    simp only [List.cons.injEq] at this
    exact ⟨this.1, this.2.2.1⟩
  obtain ⟨rfl, rfl⟩ := hab
  subst hm1 ht1 hmaj hmin hmaj' hmin'
  rw [fields_unique hlen hlen' hfs hfs']

/-- info: 'Feed.Spec.Http.isHead_unique' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms Spec.Http.isHead_unique

theorem lead_le : ∀ s : Spec.Http.Bytes, 2 * Spec.Http.lead s ≤ s.length
  | [] => Nat.zero_le _
  | [_] => Nat.zero_le _
  | c :: d :: s => by
    rw [Spec.Http.lead]
    split
    · have := lead_le s; simp; omega
    · exact Nat.zero_le _

/-- The empty lines a request starts with. -/
theorem take_lead : ∀ (s : Spec.Http.Bytes),
    s.take (2 * Spec.Http.lead s) = (List.replicate (Spec.Http.lead s) Spec.Http.crlf).flatten
  | [] => rfl
  | [_] => rfl
  | c :: d :: s => by
    rw [Spec.Http.lead]
    split
    · rename_i h
      obtain ⟨rfl, rfl⟩ := h
      rw [show 2 * (Spec.Http.lead s + 1) = 2 * Spec.Http.lead s + 2 by omega, List.replicate_succ, List.flatten_cons]
      simp only [List.take_succ_cons, take_lead s]
      rfl
    · rfl

/-- The four bytes at the first CR LF CR LF are CR LF CR LF. -/
theorem crlf2Idx_some : ∀ {l : List UInt8} {k : Nat}, crlf2Idx l = some k →
    (l.drop k).take 4 = [0x0d, 0x0a, 0x0d, 0x0a] ∧ k + 4 ≤ l.length
  | [], k, h => by simp [crlf2Idx] at h
  | c :: l, k, h => by
    rw [crlf2Idx] at h
    split at h
    · rename_i he
      obtain rfl := (Option.some.inj h).symm
      refine ⟨he, ?_⟩
      have := congrArg List.length he
      simp at this ⊢
      omega
    · cases h' : crlf2Idx l with
      | none => rw [h'] at h; simp at h
      | some k' =>
        rw [h'] at h
        obtain rfl := (Option.some.inj h).symm
        obtain ⟨h1, h2⟩ := crlf2Idx_some h'
        exact ⟨by simpa using h1, by simp; omega⟩

/-- The first CR LF CR LF within the first `n` bytes. -/
theorem crlf2Idx_take : ∀ (l : List UInt8) (n : Nat), crlf2Idx (l.take n) = (crlf2Idx l).filter (· + 4 ≤ n)
  | [], n => by simp [crlf2Idx]
  | c :: l, 0 => by
    rw [List.take_zero]
    show none = _
    cases crlf2Idx (c :: l) with
    | none => rfl
    | some k => simp [Option.filter_some]
  | c :: l, n + 1 => by
    rw [List.take_succ_cons, crlf2Idx, crlf2Idx, crlf2Idx_take l n, List.take_take]
    by_cases hw : c :: l.take 3 = [0x0d, 0x0a, 0x0d, 0x0a]
    · rw [ite_eq_left hw]
      by_cases hn : 3 ≤ n
      · rw [Nat.min_eq_left hn, ite_eq_left hw, Option.filter_some, ite_eq_left (by simp; omega)]
      · have hne : ¬ c :: l.take (min 3 n) = [0x0d, 0x0a, 0x0d, 0x0a] := by
          intro he
          have := congrArg List.length he
          simp at this
          omega
        rw [ite_eq_right hne]
        have hb : ¬ 0 + 4 ≤ n + 1 := by omega
        rw [Option.filter_some, ite_eq_right (by simp; omega)]
        cases crlf2Idx l with
        | none => rfl
        | some k => simp; omega
    · rw [ite_eq_right hw]
      have hne : ¬ c :: l.take (min 3 n) = [0x0d, 0x0a, 0x0d, 0x0a] := by
        intro he
        apply hw
        have hlen := congrArg List.length he
        simp at hlen
        have h3 : min 3 n = 3 := by
          have : (l.take (min 3 n)).length = 3 := by simp; omega
          simp at this; omega
        rw [h3] at he
        exact he
      rw [ite_eq_right hne]
      cases crlf2Idx l with
      | none => rfl
      | some k =>
        simp only [Option.filter_some, Option.map_some, decide_eq_true_eq]
        by_cases hk : k + 4 ≤ n
        · rw [ite_eq_left hk, ite_eq_left (by omega)]; rfl
        · rw [ite_eq_right hk, ite_eq_right (by omega)]; rfl

/-- After a line's CR LF: the empty line, or the next line. -/
theorem crlf2Idx_crlf (z : List UInt8) :
    crlf2Idx (0x0d :: 0x0a :: z) = some 0 ∨ crlf2Idx (0x0d :: 0x0a :: z) = (crlf2Idx z).map (· + 2) := by
  rw [crlf2Idx]
  split
  · exact Or.inl rfl
  · right
    rw [crlf2Idx_cons_ne _ _ (by decide), Option.map_map]
    rfl

/-- `headLen` is `crlf2Idx` after the empty lines. -/
theorem headLen_eq (s : Spec.Http.Bytes) :
    Spec.Http.headLen s = (crlf2Idx (s.drop (2 * Spec.Http.lead s))).map (2 * Spec.Http.lead s + · + 4) := by
  unfold Spec.Http.headLen
  rw [crlf2Idx_eq_find]

/-- The first CR LF CR LF of a head's lines (and whatever follows them) is the one that ends them. -/
theorem crlf2Idx_lines : ∀ (fls : List Spec.Http.Bytes) (line rest : Spec.Http.Bytes), 0x0d ∉ line →
    (∀ l ∈ fls, l ≠ [] ∧ 0x0d ∉ l) →
    crlf2Idx (line ++ Spec.Http.crlf ++ (fls.map (· ++ Spec.Http.crlf)).flatten ++ Spec.Http.crlf ++ rest) =
      some (line.length + (fls.map (· ++ Spec.Http.crlf)).flatten.length)
  | [], line, rest, hline, _ => by
    simp only [List.map_nil, List.flatten_nil, List.append_nil, List.length_nil, Nat.add_zero, List.append_assoc]
    rw [crlf2Idx_append_noCrlf2 _ _ (noCrlf2_of_ne _ fun c hc he => hline (he ▸ hc))]
    have : crlf2Idx (Spec.Http.crlf ++ (Spec.Http.crlf ++ rest)) = some 0 := by
      show crlf2Idx (0x0d :: 0x0a :: 0x0d :: 0x0a :: rest) = some 0
      rw [crlf2Idx, ite_eq_left (by simp)]
    rw [this]
    simp
  | l :: fls, line, rest, hline, hl => by
    obtain ⟨hl0, hlc⟩ := hl l List.mem_cons_self
    have ih := crlf2Idx_lines fls l rest hlc fun x hx => hl x (List.mem_cons_of_mem _ hx)
    simp only [List.map_cons, List.flatten_cons, List.append_assoc] at ih ⊢
    rw [crlf2Idx_append_noCrlf2 _ _ (noCrlf2_of_ne _ fun c hc he => hline (he ▸ hc))]
    obtain ⟨c, l', rfl⟩ : ∃ c l', l = c :: l' := by
      cases l with | nil => exact absurd rfl hl0 | cons c l' => exact ⟨c, l', rfl⟩
    have hc : c ≠ 0x0d := fun he => hlc (he ▸ List.mem_cons_self)
    have e2 : ∀ z : List UInt8, crlf2Idx (Spec.Http.crlf ++ (c :: z)) = (crlf2Idx (c :: z)).map (· + 2) := by
      intro z
      show crlf2Idx (0x0d :: 0x0a :: c :: z) = _
      rw [crlf2Idx, ite_eq_right (by simp [hc]), crlf2Idx_cons_ne _ _ (by decide), Option.map_map]
      rfl
    simp only [List.cons_append] at ih ⊢
    rw [e2, ih]
    simp [Spec.Http.crlf]
    omega

/-- **A head's length is where the first CR LF CR LF after its empty lines ends**, whatever
follows it. -/
theorem Spec.Http.headLen_head {h : Spec.Http.Bytes} {H : Spec.Http.Head} (hH : Spec.Http.IsHead h H)
    (rest : Spec.Http.Bytes) :
    Spec.Http.headLen (h ++ rest) = some h.length := by
  rw [headLen_eq, lead_head hH.1 rest]
  obtain ⟨⟨e, hl⟩, -⟩ := hH
  have hk : 2 * H.k = ((List.replicate H.k Spec.Http.crlf).flatten).length := by simp [Spec.Http.crlf]; omega
  rw [e]
  simp only [List.append_assoc]
  rw [hk, List.drop_left' rfl, ← hk]
  have := crlf2Idx_lines H.fls H.line rest (hl _ List.mem_cons_self).2.1
    fun l hm => ⟨(hl l (List.mem_cons_of_mem _ hm)).1, (hl l (List.mem_cons_of_mem _ hm)).2.1⟩
  simp only [List.append_assoc] at this
  rw [this]
  simp [Spec.Http.crlf]
  omega

/-- info: 'Feed.Spec.Http.headLen_head' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms Spec.Http.headLen_head

/-- **A head whose request-target is short is not `TargetTooLong`**: the request-target's bytes are
the ones after the method and SP, which `TargetTooLong` counts. -/
theorem Spec.Http.not_targetTooLong {s : Spec.Http.Bytes} {n : Nat} {H : Spec.Http.Head}
    (hH : Spec.Http.IsHead (s.take n) H) (hshort : H.target.length ≤ Spec.Http.maxTarget) :
    ¬ Spec.Http.TargetTooLong s := by
  rintro ⟨M, T, rest, hs, hM, hTl, hT, -⟩
  obtain ⟨⟨e, hl⟩, ⟨hm, -, hsp, v, -, hline⟩, -⟩ := hH
  have hk : Spec.Http.lead s = H.k := by
    have := lead_head ⟨e, hl⟩ (s.drop n)
    rwa [List.take_append_drop] at this
  have hlen : (List.replicate H.k Spec.Http.crlf).flatten.length = 2 * H.k := by
    simp [Spec.Http.crlf]; omega
  have hd : s.drop (2 * Spec.Http.lead s) = H.line ++ (Spec.Http.crlf ++
      ((H.fls.map (· ++ Spec.Http.crlf)).flatten ++ (Spec.Http.crlf ++ s.drop n))) := by
    rw [hk]
    conv => lhs; rw [← List.take_append_drop n s, e]
    rw [← hlen]
    simp only [List.append_assoc]
    rw [List.drop_left' rfl]
  rw [hd, hline] at hs
  simp only [List.append_assoc, List.singleton_append] at hs
  obtain ⟨-, h2⟩ := cancel_sep (token_not_mem hm (by decide)) (token_not_mem hM (by decide)) hs
  -- the target, then SP, starts the `maxTarget + 1` bytes `T`, which hold no SP
  simp only [List.append_eq] at h2
  have h3 := congrArg (List.take (H.target.length + 1)) h2
  rw [List.take_length_add_append, List.take_append_of_le_length (l₁ := T) (l₂ := rest) (by omega)] at h3
  have : (0x20 : UInt8) ∈ T := by
    have hmem : (0x20 : UInt8) ∈ List.take (H.target.length + 1) T := by rw [← h3]; simp
    exact List.mem_of_mem_take hmem
  exact (hT _ this).1 rfl

/-- info: 'Feed.Spec.Http.not_targetTooLong' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms Spec.Http.not_targetTooLong

/-- So input that starts with a valid head is not `TargetTooLong` (`HeadOk.short`). -/
theorem Spec.Http.validHead_not_targetTooLong {s : Spec.Http.Bytes} {n len : Nat}
    (h : Spec.Http.ValidHead (s.take n) len) : ¬ Spec.Http.TargetTooLong s := by
  obtain ⟨H, _, hH, hok⟩ := h
  exact Spec.Http.not_targetTooLong hH hok.short

/-! ## What the field lines say -/

theorem values_snoc (fs : List (Spec.Http.Bytes × Spec.Http.Bytes)) (n w name : Spec.Http.Bytes) :
    Spec.Http.values (fs ++ [(n, w)]) name =
      Spec.Http.values fs name ++ (if Spec.Http.lower n = name then [w] else []) := by
  unfold Spec.Http.values
  rw [List.filterMap_append]
  by_cases h : Spec.Http.lower n = name <;> simp [h]

theorem values_snoc_ne {fs : List (Spec.Http.Bytes × Spec.Http.Bytes)} {n name : Spec.Http.Bytes} (w : Spec.Http.Bytes)
    (h : Spec.Http.lower n ≠ name) : Spec.Http.values (fs ++ [(n, w)]) name = Spec.Http.values fs name := by
  rw [values_snoc, ite_eq_right h, List.append_nil]

theorem values_snoc_eq {fs : List (Spec.Http.Bytes × Spec.Http.Bytes)} {n name : Spec.Http.Bytes} (w : Spec.Http.Bytes)
    (h : Spec.Http.lower n = name) : Spec.Http.values (fs ++ [(n, w)]) name = Spec.Http.values fs name ++ [w] := by
  rw [values_snoc, ite_eq_left h]

theorem hasOption_snoc (fs : List (Spec.Http.Bytes × Spec.Http.Bytes)) (n w opt : Spec.Http.Bytes) :
    Spec.Http.hasOption (fs ++ [(n, w)]) opt =
      (Spec.Http.hasOption fs opt ||
        (Spec.Http.lower n == Spec.lit "connection" && (Spec.Http.members w).any (Spec.Http.lower · == opt))) := by
  unfold Spec.Http.hasOption
  rw [values_snoc, List.any_append]
  by_cases h : Spec.Http.lower n = Spec.lit "connection" <;> simp [h]

theorem hasOption_snoc_ne {fs : List (Spec.Http.Bytes × Spec.Http.Bytes)} {n : Spec.Http.Bytes}
    (w opt : Spec.Http.Bytes) (h : Spec.Http.lower n ≠ Spec.lit "connection") :
    Spec.Http.hasOption (fs ++ [(n, w)]) opt = Spec.Http.hasOption fs opt := by
  rw [hasOption_snoc]
  simp [h]

/-- What the field scan's record `f` says of the field lines `fs` (names and values, OWS
removed): how many Host and Authorization lines there are and the last one's value; whether there
is a Transfer-Encoding line; whether the Connection options include close and keep-alive; whether
there is a Content-Length line (`hasLen`), whether one of the values is not `1*DIGIT` or names
another number (`lenBad`), and the first value's digits from its first that is not 0. The ranges
are inside the input. -/
structure Http.Fields.Sums (a : ByteArray) (f : Http.Fields) (fs : List (Spec.Http.Bytes × Spec.Http.Bytes)) :
    Prop where
  host_le : f.hostLo ≤ f.hostHi ∧ f.hostHi ≤ a.size
  auth_le : f.authLo ≤ f.authHi ∧ f.authHi ≤ a.size
  len_le : f.lenLo ≤ f.lenHi ∧ f.lenHi ≤ a.size
  hosts : f.hosts = (Spec.Http.values fs (Spec.lit "host")).length
  host : 0 < f.hosts → (Spec.Http.values fs (Spec.lit "host")).getLast? = some (slice a f.hostLo f.hostHi)
  auths : f.auths = (Spec.Http.values fs (Spec.lit "authorization")).length
  auth : 0 < f.auths →
    (Spec.Http.values fs (Spec.lit "authorization")).getLast? = some (slice a f.authLo f.authHi)
  coding : f.coding = !(Spec.Http.values fs (Spec.lit "transfer-encoding")).isEmpty
  close : f.close = Spec.Http.hasOption fs (Spec.lit "close")
  keepAlive : f.keepAlive = Spec.Http.hasOption fs (Spec.lit "keep-alive")
  noLen : Spec.Http.values fs (Spec.lit "content-length") = [] → f.hasLen = false ∧ f.lenBad = false
  len : ∀ v vs, Spec.Http.values fs (Spec.lit "content-length") = v :: vs →
    f.lenBad = !((v :: vs).all fun w => !w.isEmpty && w.all Spec.Http.isDigit && decimal w 0 == decimal v 0) ∧
      (f.lenBad = false → f.hasLen = true ∧ slice a f.lenLo f.lenHi = v.dropWhile (· == 0x30))

theorem Http.Fields.sums_empty (a : ByteArray) : Http.Fields.Sums a {} [] where
  host_le := ⟨Nat.le_refl _, Nat.zero_le _⟩
  auth_le := ⟨Nat.le_refl _, Nat.zero_le _⟩
  len_le := ⟨Nat.le_refl _, Nat.zero_le _⟩
  hosts := rfl
  host := fun h => absurd h (Nat.lt_irrefl _)
  auths := rfl
  auth := fun h => absurd h (Nat.lt_irrefl _)
  coding := rfl
  close := rfl
  keepAlive := rfl
  noLen := fun _ => ⟨rfl, rfl⟩
  len := fun _ _ h => by simp [Spec.Http.values] at h

/-- A line of another name changes nothing the scan looks at. -/
theorem Http.Fields.Sums.otherLine {a : ByteArray} {f : Http.Fields} {fs : List (Spec.Http.Bytes × Spec.Http.Bytes)}
    (h : Http.Fields.Sums a f fs) {n : Spec.Http.Bytes} (w : Spec.Http.Bytes)
    (h1 : Spec.Http.lower n ≠ Spec.lit "host") (h2 : Spec.Http.lower n ≠ Spec.lit "content-length")
    (h3 : Spec.Http.lower n ≠ Spec.lit "authorization") (h4 : Spec.Http.lower n ≠ Spec.lit "connection")
    (h5 : Spec.Http.lower n ≠ Spec.lit "transfer-encoding") : Http.Fields.Sums a f (fs ++ [(n, w)]) where
  host_le := h.host_le
  auth_le := h.auth_le
  len_le := h.len_le
  hosts := by rw [values_snoc_ne w h1]; exact h.hosts
  host := by rw [values_snoc_ne w h1]; exact h.host
  auths := by rw [values_snoc_ne w h3]; exact h.auths
  auth := by rw [values_snoc_ne w h3]; exact h.auth
  coding := by rw [values_snoc_ne w h5]; exact h.coding
  close := by rw [hasOption_snoc_ne w _ h4]; exact h.close
  keepAlive := by rw [hasOption_snoc_ne w _ h4]; exact h.keepAlive
  noLen := by rw [values_snoc_ne w h2]; exact h.noLen
  len := by rw [values_snoc_ne w h2]; exact h.len

theorem lit_ne_host : Spec.lit "content-length" ≠ Spec.lit "host" ∧ Spec.lit "authorization" ≠ Spec.lit "host" ∧
    Spec.lit "connection" ≠ Spec.lit "host" ∧ Spec.lit "transfer-encoding" ≠ Spec.lit "host" ∧
    Spec.lit "authorization" ≠ Spec.lit "content-length" ∧ Spec.lit "connection" ≠ Spec.lit "content-length" ∧
    Spec.lit "transfer-encoding" ≠ Spec.lit "content-length" ∧ Spec.lit "connection" ≠ Spec.lit "authorization" ∧
    Spec.lit "transfer-encoding" ≠ Spec.lit "authorization" ∧ Spec.lit "transfer-encoding" ≠ Spec.lit "connection" := by
  decide

theorem ne_of_eq_ne {x A B : Spec.Http.Bytes} (e : x = A) (d : B ≠ A) : x ≠ B := fun h => d (h ▸ e)

/-- The step for a Content-Length line (RFC 9110 §8.6): the first valid value sets the length;
a value that is not `1*DIGIT`, or names another number than the first, makes it bad. -/
theorem Http.Fields.Sums.lenLine {a : ByteArray} {f : Http.Fields} {fs : List (Spec.Http.Bytes × Spec.Http.Bytes)}
    (h : Http.Fields.Sums a f fs) {n : Spec.Http.Bytes} {vs ve : Nat} (hva : ve ≤ a.size) (hv : vs ≤ ve)
    (e : Spec.Http.lower n = Spec.lit "content-length") :
    Http.Fields.Sums a
      (if (vs < ve && Http.allDigits a vs ve) = true then
        if (!f.hasLen) = true then { f with hasLen := true, lenLo := Http.skipZeros a vs ve, lenHi := ve }
        else if Http.sameBytes a f.lenLo f.lenHi (Http.skipZeros a vs ve) ve = true then f
        else { f with lenBad := true }
      else { f with lenBad := true })
      (fs ++ [(n, slice a vs ve)]) := by
  obtain ⟨d1, d2, d3, d4, d5, d6, d7, d8, d9, d10⟩ := lit_ne_host
  have ne1 : Spec.Http.lower n ≠ Spec.lit "host" := ne_of_eq_ne e d1.symm
  have ne3 : Spec.Http.lower n ≠ Spec.lit "authorization" := ne_of_eq_ne e d5
  have ne4 : Spec.Http.lower n ≠ Spec.lit "connection" := ne_of_eq_ne e d6
  have ne5 : Spec.Http.lower n ≠ Spec.lit "transfer-encoding" := ne_of_eq_ne e d7
  generalize hw : slice a vs ve = w
  have hV := values_snoc_eq (fs := fs) w e
  -- the parts of the record the line does not touch
  have keep : ∀ g : Http.Fields, g.hosts = f.hosts → g.hostLo = f.hostLo → g.hostHi = f.hostHi → g.auths = f.auths →
      g.authLo = f.authLo → g.authHi = f.authHi → g.coding = f.coding → g.close = f.close → g.keepAlive = f.keepAlive →
      g.lenLo ≤ g.lenHi ∧ g.lenHi ≤ a.size →
      (∀ v vs, Spec.Http.values (fs ++ [(n, w)]) (Spec.lit "content-length") = v :: vs →
        g.lenBad = !((v :: vs).all fun x => !x.isEmpty && x.all Spec.Http.isDigit && decimal x 0 == decimal v 0) ∧
          (g.lenBad = false → g.hasLen = true ∧ slice a g.lenLo g.lenHi = v.dropWhile (· == 0x30))) →
      Http.Fields.Sums a g (fs ++ [(n, w)]) := by
    intro g e1 e2 e3 e4 e5 e6 e7 e8 e9 hle hlen
    exact {
      host_le := by rw [e2, e3]; exact h.host_le
      auth_le := by rw [e5, e6]; exact h.auth_le
      len_le := hle
      hosts := by rw [e1, values_snoc_ne _ ne1]; exact h.hosts
      host := by rw [e1, e2, e3, values_snoc_ne _ ne1]; exact h.host
      auths := by rw [e4, values_snoc_ne _ ne3]; exact h.auths
      auth := by rw [e4, e5, e6, values_snoc_ne _ ne3]; exact h.auth
      coding := by rw [e7, values_snoc_ne _ ne5]; exact h.coding
      close := by rw [e8, hasOption_snoc_ne _ _ ne4]; exact h.close
      keepAlive := by rw [e9, hasOption_snoc_ne _ _ ne4]; exact h.keepAlive
      noLen := by rw [hV]; simp
      len := hlen }
  have hvalid : (vs < ve && Http.allDigits a vs ve) = (!w.isEmpty && w.all Spec.Http.isDigit) := by
    rw [Http.allDigits_eq a vs hva, hw]
    congr 1
    have := slice_length a (lo := vs) hva
    rw [hw] at this
    cases w with
    | nil => simp at this ⊢; omega
    | cons x w => simp at this ⊢; omega
  rw [hvalid]
  -- the first value's test, and the new value's
  by_cases hwv : (!w.isEmpty && w.all Spec.Http.isDigit) = true
  · rw [ite_eq_left hwv]
    have hz := (slice_takeWhile a (· == 0x30) (i := vs) hva).2
    rw [← Http.skipZeros_eq a vs hva, hw] at hz
    have hzle : vs ≤ Http.skipZeros a vs ve ∧ Http.skipZeros a vs ve ≤ ve := by
      rw [Http.skipZeros_eq a vs hva]
      have := takeWhile_length_le (· == (0x30 : UInt8)) (slice a vs ve)
      rw [slice_length a hva] at this
      omega
    have wd : ∀ c ∈ w, Spec.Http.isDigit c = true := by
      simp only [Bool.and_eq_true, List.all_eq_true] at hwv
      exact hwv.2
    by_cases hl : f.hasLen = true
    · rw [ite_eq_right (by simp [hl])]
      cases hV0 : Spec.Http.values fs (Spec.lit "content-length") with
      | nil => exact absurd ((h.noLen hV0).1.symm.trans hl) (by decide)
      | cons v vs' =>
        obtain ⟨hb, hgood⟩ := h.len v vs' hV0
        have hV' : Spec.Http.values (fs ++ [(n, w)]) (Spec.lit "content-length") = v :: (vs' ++ [w]) := by
          rw [hV, hV0]; rfl
        by_cases hbad : f.lenBad = true
        · have hall := congrArg (!·) hb
          simp only [Bool.not_not, hbad, Bool.not_true] at hall
          split
          · exact keep f rfl rfl rfl rfl rfl rfl rfl rfl rfl h.len_le (fun v₁ vs₁ hv₁ => by
              rw [hV'] at hv₁
              obtain ⟨rfl, rfl⟩ := List.cons.inj hv₁
              refine ⟨?_, fun hb' => absurd (hbad.symm.trans hb') (by decide)⟩
              rw [hbad, ← List.cons_append, List.all_append, ← hall]
              rfl)
          · exact keep _ rfl rfl rfl rfl rfl rfl rfl rfl rfl h.len_le (fun v₁ vs₁ hv₁ => by
              rw [hV'] at hv₁
              obtain ⟨rfl, rfl⟩ := List.cons.inj hv₁
              refine ⟨?_, fun hb' => by simp at hb'⟩
              rw [← List.cons_append, List.all_append, ← hall]
              rfl)
        · have hbad' : f.lenBad = false := by simpa using hbad
          obtain ⟨-, hsl⟩ := hgood hbad'
          have hall := congrArg (!·) hb
          simp only [Bool.not_not, hbad', Bool.not_false] at hall
          replace hall := hall.symm
          have vd : ∀ c ∈ v, Spec.Http.isDigit c = true := by
            have := (List.all_eq_true.mp hall) v List.mem_cons_self
            simp only [Bool.and_eq_true, List.all_eq_true] at this
            exact this.1.2
          have hsame : Http.sameBytes a f.lenLo f.lenHi (Http.skipZeros a vs ve) ve = (decimal w 0 == decimal v 0) := by
            apply Bool.eq_iff_iff.mpr
            rw [Http.sameBytes_iff a h.len_le.2 hva, hsl, hz, beq_iff_eq, decimal_eq_iff wd vd]
            exact ⟨fun h => h.symm, fun h => h.symm⟩
          rw [hsame]
          split
          · rename_i hd
            exact keep f rfl rfl rfl rfl rfl rfl rfl rfl rfl h.len_le (fun v₁ vs₁ hv₁ => by
              rw [hV'] at hv₁
              obtain ⟨rfl, rfl⟩ := List.cons.inj hv₁
              refine ⟨?_, fun _ => ⟨hl, hsl⟩⟩
              rw [hbad', ← List.cons_append, List.all_append, hall]
              simp [hwv, hd])
          · rename_i hd
            exact keep _ rfl rfl rfl rfl rfl rfl rfl rfl rfl h.len_le (fun v₁ vs₁ hv₁ => by
              rw [hV'] at hv₁
              obtain ⟨rfl, rfl⟩ := List.cons.inj hv₁
              refine ⟨?_, fun hb' => by simp at hb'⟩
              rw [← List.cons_append, List.all_append, hall]
              simp [hd])
    · rw [ite_eq_left (by simpa using hl)]
      have hl' : f.hasLen = false := by simpa using hl
      cases hV0 : Spec.Http.values fs (Spec.lit "content-length") with
      | nil =>
        have hb := (h.noLen hV0).2
        have hV' : Spec.Http.values (fs ++ [(n, w)]) (Spec.lit "content-length") = [w] := by rw [hV, hV0]; rfl
        exact keep _ rfl rfl rfl rfl rfl rfl rfl rfl rfl ⟨hzle.2, hva⟩ (fun v₁ vs₁ hv₁ => by
          rw [hV'] at hv₁
          obtain ⟨rfl, rfl⟩ := List.cons.inj hv₁
          refine ⟨?_, fun _ => ⟨rfl, hz⟩⟩
          show f.lenBad = _
          rw [hb]
          simp [hwv])
      | cons v vs' =>
        obtain ⟨hb, hgood⟩ := h.len v vs' hV0
        have hbad : f.lenBad = true := by
          cases hb' : f.lenBad with
          | true => rfl
          | false => exact absurd (hgood hb').1 (by rw [hl']; decide)
        have hall := congrArg (!·) hb
        simp only [Bool.not_not, hbad, Bool.not_true] at hall
        have hV' : Spec.Http.values (fs ++ [(n, w)]) (Spec.lit "content-length") = v :: (vs' ++ [w]) := by
          rw [hV, hV0]; rfl
        exact keep _ rfl rfl rfl rfl rfl rfl rfl rfl rfl ⟨hzle.2, hva⟩ (fun v₁ vs₁ hv₁ => by
          rw [hV'] at hv₁
          obtain ⟨rfl, rfl⟩ := List.cons.inj hv₁
          refine ⟨?_, fun hb' => absurd (hbad.symm.trans hb') (by decide)⟩
          show f.lenBad = _
          rw [hbad, ← List.cons_append, List.all_append, ← hall]
          rfl)
  · rw [ite_eq_right hwv]
    have hwv' : (!w.isEmpty && w.all Spec.Http.isDigit) = false := by simpa using hwv
    cases hV0 : Spec.Http.values fs (Spec.lit "content-length") with
    | nil =>
      have hV' : Spec.Http.values (fs ++ [(n, w)]) (Spec.lit "content-length") = [w] := by rw [hV, hV0]; rfl
      exact keep _ rfl rfl rfl rfl rfl rfl rfl rfl rfl h.len_le (fun v₁ vs₁ hv₁ => by
        rw [hV'] at hv₁
        obtain ⟨rfl, rfl⟩ := List.cons.inj hv₁
        refine ⟨?_, fun hb' => by simp at hb'⟩
        simp [hwv'])
    | cons v vs' =>
      have hV' : Spec.Http.values (fs ++ [(n, w)]) (Spec.lit "content-length") = v :: (vs' ++ [w]) := by
        rw [hV, hV0]; rfl
      exact keep _ rfl rfl rfl rfl rfl rfl rfl rfl rfl h.len_le (fun v₁ vs₁ hv₁ => by
        rw [hV'] at hv₁
        obtain ⟨rfl, rfl⟩ := List.cons.inj hv₁
        refine ⟨?_, fun hb' => by simp at hb'⟩
        rw [← List.cons_append, List.all_append]
        simp [hwv'])

/-- **The scan gathers what the field lines say**: one more field line, of name `a[lo, c)` and
value `a[vs, ve)`, updates the record as the specification's reading of the lines changes. -/
theorem Http.field_sums {a : ByteArray} {f : Http.Fields} {fs : List (Spec.Http.Bytes × Spec.Http.Bytes)}
    (h : Http.Fields.Sums a f fs) {lo c vs ve : Nat} (hc : c ≤ a.size) (hv : vs ≤ ve) (hva : ve ≤ a.size) :
    Http.Fields.Sums a (Http.field a lo c vs ve f) (fs ++ [(slice a lo c, slice a vs ve)]) := by
  obtain ⟨d1, d2, d3, d4, d5, d6, d7, d8, d9, d10⟩ := lit_ne_host
  have hn : ∀ lit, Http.eqCI a lo c lit = true ↔ Spec.Http.lower (slice a lo c) = bs lit :=
    fun lit => eqCI_spec a lit hc
  unfold Http.field
  by_cases e1 : Http.eqCI a lo c Http.hHost = true
  · rw [ite_eq_left e1]
    have e := (hn _).mp e1
    change _ = Spec.lit "host" at e
    exact {
      host_le := ⟨hv, hva⟩, auth_le := h.auth_le, len_le := h.len_le
      hosts := by rw [values_snoc_eq _ e, List.length_append, ← h.hosts]; rfl
      host := fun _ => by rw [values_snoc_eq _ e, List.getLast?_concat]
      auths := by rw [values_snoc_ne _ (ne_of_eq_ne e d2)]; exact h.auths
      auth := by rw [values_snoc_ne _ (ne_of_eq_ne e d2)]; exact h.auth
      coding := by rw [values_snoc_ne _ (ne_of_eq_ne e d4)]; exact h.coding
      close := by rw [hasOption_snoc_ne _ _ (ne_of_eq_ne e d3)]; exact h.close
      keepAlive := by rw [hasOption_snoc_ne _ _ (ne_of_eq_ne e d3)]; exact h.keepAlive
      noLen := by rw [values_snoc_ne _ (ne_of_eq_ne e d1)]; exact h.noLen
      len := by rw [values_snoc_ne _ (ne_of_eq_ne e d1)]; exact h.len }
  rw [ite_eq_right e1]
  have n1 : Spec.Http.lower (slice a lo c) ≠ Spec.lit "host" := fun he => e1 ((hn _).mpr he)
  by_cases e2 : Http.eqCI a lo c Http.hContentLength = true
  · rw [ite_eq_left e2]
    have e := (hn _).mp e2
    change _ = Spec.lit "content-length" at e
    exact h.lenLine hva hv e
  rw [ite_eq_right e2]
  have n2 : Spec.Http.lower (slice a lo c) ≠ Spec.lit "content-length" := fun he => e2 ((hn _).mpr he)
  by_cases e3 : Http.eqCI a lo c Http.hAuthorization = true
  · rw [ite_eq_left e3]
    have e := (hn _).mp e3
    change _ = Spec.lit "authorization" at e
    exact {
      host_le := h.host_le, auth_le := ⟨hv, hva⟩, len_le := h.len_le
      hosts := by rw [values_snoc_ne _ n1]; exact h.hosts
      host := by rw [values_snoc_ne _ n1]; exact h.host
      auths := by rw [values_snoc_eq _ e, List.length_append, ← h.auths]; rfl
      auth := fun _ => by rw [values_snoc_eq _ e, List.getLast?_concat]
      coding := by rw [values_snoc_ne _ (ne_of_eq_ne e d9)]; exact h.coding
      close := by rw [hasOption_snoc_ne _ _ (ne_of_eq_ne e d8)]; exact h.close
      keepAlive := by rw [hasOption_snoc_ne _ _ (ne_of_eq_ne e d8)]; exact h.keepAlive
      noLen := by rw [values_snoc_ne _ n2]; exact h.noLen
      len := by rw [values_snoc_ne _ n2]; exact h.len }
  rw [ite_eq_right e3]
  have n3 : Spec.Http.lower (slice a lo c) ≠ Spec.lit "authorization" := fun he => e3 ((hn _).mpr he)
  by_cases e4 : Http.eqCI a lo c Http.hConnection = true
  · rw [ite_eq_left e4]
    have e := (hn _).mp e4
    change _ = Spec.lit "connection" at e
    have ht1 := Http.hasToken_eq a Http.tClose hv hva (by decide)
    have ht2 := Http.hasToken_eq a Http.tKeepAlive hv hva (by decide)
    exact {
      host_le := h.host_le, auth_le := h.auth_le, len_le := h.len_le
      hosts := by rw [values_snoc_ne _ n1]; exact h.hosts
      host := by rw [values_snoc_ne _ n1]; exact h.host
      auths := by rw [values_snoc_ne _ n3]; exact h.auths
      auth := by rw [values_snoc_ne _ n3]; exact h.auth
      coding := by rw [values_snoc_ne _ (ne_of_eq_ne e d10)]; exact h.coding
      close := by rw [hasOption_snoc, ← h.close, ht1, e]; simp; rfl
      keepAlive := by rw [hasOption_snoc, ← h.keepAlive, ht2, e]; simp; rfl
      noLen := by rw [values_snoc_ne _ n2]; exact h.noLen
      len := by rw [values_snoc_ne _ n2]; exact h.len }
  rw [ite_eq_right e4]
  have n4 : Spec.Http.lower (slice a lo c) ≠ Spec.lit "connection" := fun he => e4 ((hn _).mpr he)
  by_cases e5 : Http.eqCI a lo c Http.hTransferEncoding = true
  · rw [ite_eq_left e5]
    have e := (hn _).mp e5
    change _ = Spec.lit "transfer-encoding" at e
    exact {
      host_le := h.host_le, auth_le := h.auth_le, len_le := h.len_le
      hosts := by rw [values_snoc_ne _ n1]; exact h.hosts
      host := by rw [values_snoc_ne _ n1]; exact h.host
      auths := by rw [values_snoc_ne _ n3]; exact h.auths
      auth := by rw [values_snoc_ne _ n3]; exact h.auth
      coding := by rw [values_snoc_eq _ e]; simp
      close := by rw [hasOption_snoc_ne _ _ n4]; exact h.close
      keepAlive := by rw [hasOption_snoc_ne _ _ n4]; exact h.keepAlive
      noLen := by rw [values_snoc_ne _ n2]; exact h.noLen
      len := by rw [values_snoc_ne _ n2]; exact h.len }
  rw [ite_eq_right e5]
  exact h.otherLine _ n1 n2 n3 n4 fun he => e5 ((hn _).mpr he)

/-- info: 'Feed.Http.field_sums' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms Http.field_sums

theorem Http.field_bad (a : ByteArray) (lo c vs ve : Nat) (f : Http.Fields) :
    (Http.field a lo c vs ve f).bad = f.bad := by
  unfold Http.field
  dsimp only
  repeat' split
  all_goals rfl

/-! ## The field lines' scan -/

/-- One field line at `i`, as the scan reads it: its name `a[i, c)`, then ":", then value bytes up
to `e`, where CR LF follows. -/
theorem fieldLine_at (a : ByteArray) {i c e he : Nat} (hhe : he ≤ a.size) (hic : i < c) (hce : c + 1 ≤ e)
    (heh : e ≤ he) (hc : c = i + ((slice a i he).takeWhile Spec.Http.isTchar).length) (hcolon : a.get! c = 0x3a)
    (he' : e = c + 1 + ((slice a (c + 1) he).takeWhile fun x => Spec.Http.isVchar x || Spec.Http.isWs x).length) :
    slice a i e = slice a i c ++ [0x3a] ++ slice a (c + 1) e ∧
      Spec.Http.FieldLine (slice a i e) (slice a i c) (Spec.Http.trimOws (slice a (c + 1) e)) ∧
      slice a i e ≠ [] ∧ 0x0d ∉ slice a i e ∧ 0x0a ∉ slice a i e := by
  have hsplit : slice a i e = slice a i c ++ [0x3a] ++ slice a (c + 1) e := by
    rw [slice_append a (mid := c) (by omega) (by omega), slice_cons a (i := c) (hi := e) (by omega) (by omega), hcolon]
    simp
  have htok : ∀ x ∈ slice a i c, Spec.Http.isTchar x = true := by
    rw [hc]; exact run_all a _ hhe
  have hval : ∀ x ∈ slice a (c + 1) e, (Spec.Http.isVchar x || Spec.Http.isWs x) = true := by
    rw [he']; exact run_all a _ hhe
  have hne : slice a i c ≠ [] := by
    intro h0; have := slice_length a (lo := i) (hi := c) (by omega); rw [h0] at this; simp at this; omega
  obtain ⟨t1, t2, t3, t4⟩ := crlf_not_tchar
  obtain ⟨f1, f2⟩ := crlf_not_field
  refine ⟨hsplit, (Spec.Http.fieldLine_iff _ _ _).mpr ⟨⟨hne, htok⟩, _, hsplit, hval, rfl⟩, ?_, ?_, ?_⟩
  · rw [hsplit]; simp
  · rw [hsplit]
    simp only [List.mem_append, List.mem_singleton, not_or]
    exact ⟨⟨fun hm => by have := htok _ hm; rw [t1] at this; exact absurd this (by decide), by decide⟩,
      fun hm => by have := hval _ hm; rw [f1] at this; exact absurd this (by decide)⟩
  · rw [hsplit]
    simp only [List.mem_append, List.mem_singleton, not_or]
    exact ⟨⟨fun hm => by have := htok _ hm; rw [t2] at this; exact absurd this (by decide), by decide⟩,
      fun hm => by have := hval _ hm; rw [f2] at this; exact absurd this (by decide)⟩

/-- **The field scan reads field lines**: if it finds no fault in the bytes from `i` to the end of
the head at `he`, they are field lines, and the record says what they say. -/
theorem Http.fields_sound {a : ByteArray} {he : Nat} (hhe : he + 4 ≤ a.size)
    (hend : slice a he (he + 4) = Spec.Http.crlf ++ Spec.Http.crlf) :
    ∀ fuel i (f : Http.Fields) fs₀, (Http.fields a he i f fuel).bad = false → Http.Fields.Sums a f fs₀ →
      ∃ fls fs, fls ≠ [] ∧ FieldLines (slice a i (he + 4)) fls fs ∧
        Http.Fields.Sums a (Http.fields a he i f fuel) (fs₀ ++ fs) := by
  have hcr : a.get! he = 0x0d := by
    have := slice_getElem? a (lo := he) (hi := he + 4) (k := 0) (by omega) hhe
    rw [hend, show (Spec.Http.crlf ++ Spec.Http.crlf)[0]? = some 0x0d from rfl, Nat.add_zero] at this
    exact (Option.some.inj this).symm
  intro fuel
  induction fuel with
  | zero => intro i f fs₀ hb _; simp [Http.fields] at hb
  | succ fuel ih =>
    intro i f fs₀ hb hs
    simp only [Http.fields] at hb ⊢
    have hc := Http.tokenEnd_eq a i (hi := he) (by omega)
    generalize Http.tokenEnd a i he = c at hb hc ⊢
    by_cases h1 : (c == i || Http.byte a c != 0x3a) = true
    · rw [ite_eq_left h1] at hb; simp at hb
    rw [ite_eq_right h1] at hb ⊢
    simp only [Bool.or_eq_true, beq_iff_eq, bne_iff_ne, ne_eq, not_or, Decidable.not_not, Http.byte] at h1
    obtain ⟨hci, hcolon⟩ := h1
    have hic : i < c := by omega
    have hch : c < he := by
      have := run_le a Spec.Http.isTchar (i := i) (by omega : he ≤ a.size)
      by_cases hle : i ≤ he
      · rcases Nat.lt_or_ge c he with h | h
        · exact h
        · exfalso; have : c = he := by rw [hc]; have := this hle; omega
          rw [this, hcr] at hcolon; exact absurd hcolon (by decide)
      · exfalso; rw [show slice a i he = [] by simp [slice, show he - i = 0 by omega]] at hc; simp at hc; omega
    have he' := Http.valueEnd_eq a (c + 1) (hi := he) (by omega)
    generalize Http.valueEnd a (c + 1) he = e at hb he' ⊢
    have hce : c + 1 ≤ e ∧ e ≤ he := by
      have := run_le a (fun x => Spec.Http.isVchar x || Spec.Http.isWs x) (i := c + 1) (by omega : he ≤ a.size)
        (by omega)
      omega
    by_cases h2 : (Http.byte a e != 0x0d || Http.byte a (e + 1) != 0x0a) = true
    · rw [ite_eq_left h2] at hb; simp at hb
    rw [ite_eq_right h2] at hb ⊢
    simp only [Bool.or_eq_true, bne_iff_ne, ne_eq, not_or, Decidable.not_not, Http.byte] at h2
    obtain ⟨hecr, helf⟩ := h2
    obtain ⟨t1, t2, t3, t4⟩ := Http.trim_eq a (s := c + 1) (e := e) hce.1 (by omega)
    have hs' := Http.field_sums hs (lo := i) (c := c) (by omega) t2 (by omega)
    rw [t4] at hs'
    obtain ⟨hsplit, hfl, hne, hncr, hnlf⟩ := fieldLine_at a (by omega : he ≤ a.size) hic hce.1 hce.2 hc hcolon he'
    by_cases h3 : he ≤ e
    · rw [ite_eq_left h3] at hb ⊢
      have hee : e = he := by omega
      subst hee
      refine ⟨[slice a i e], [(slice a i c, Spec.Http.trimOws (slice a (c + 1) e))], by simp, ⟨?_, ?_, rfl, ?_⟩, hs'⟩
      · rw [slice_append a (mid := e) (by omega) (by omega), hend]; simp
      · intro l hl; simp at hl; subst hl; exact ⟨hne, hncr, hnlf⟩
      · intro p hp; simp at hp; subst hp; exact hfl
    · rw [ite_eq_right h3] at hb ⊢
      obtain ⟨fls, fs, hfls, ⟨hr, hl, hlen, hz⟩, hsum⟩ := ih (e + 2) _ _ hb hs'
      refine ⟨slice a i e :: fls, (slice a i c, Spec.Http.trimOws (slice a (c + 1) e)) :: fs, by simp,
        ⟨?_, ?_, ?_, ?_⟩, ?_⟩
      · rw [slice_append a (mid := e) (by omega) (by omega), slice_cons a (i := e) (hi := he + 4) (by omega) (by omega),
          slice_cons a (i := e + 1) (hi := he + 4) (by omega) (by omega), hecr, helf, hr]
        simp [Spec.Http.crlf]
      · intro l hm
        rcases List.mem_cons.mp hm with rfl | hm
        · exact ⟨hne, hncr, hnlf⟩
        · exact hl l hm
      · simp [hlen]
      · intro p hp
        rw [List.zip_cons_cons] at hp
        rcases List.mem_cons.mp hp with rfl | hp
        · exact hfl
        · exact hz p hp
      · simpa [List.append_assoc] using hsum

/-- info: 'Feed.Http.fields_sound' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms Http.fields_sound

/-- **The field scan finds no fault in field lines**: from the start of field lines that end the
head at `he`, it reads them all (with enough fuel). -/
theorem Http.fields_complete {a : ByteArray} {he : Nat} (hhe : he + 4 ≤ a.size) :
    ∀ fuel i (f : Http.Fields) fls fs, FieldLines (slice a i (he + 4)) fls fs → fls ≠ [] → he - i ≤ fuel →
      (Http.fields a he i f fuel).bad = f.bad := by
  intro fuel
  induction fuel with
  | zero =>
    intro i f fls fs ⟨hr, hl, _, _⟩ hne hf
    exfalso
    obtain ⟨l, fls', rfl⟩ : ∃ l fls', fls = l :: fls' := by
      cases fls with | nil => exact absurd rfl hne | cons l t => exact ⟨l, t, rfl⟩
    have hlen := slice_length a (lo := i) (hi := he + 4) hhe
    rw [hr] at hlen
    simp only [List.map_cons, List.flatten_cons, List.length_append, Spec.Http.crlf, List.length_cons,
      List.length_nil] at hlen
    have := (hl l List.mem_cons_self).1
    have : l.length ≥ 1 := by cases l with | nil => exact absurd rfl this | cons _ _ => simp
    omega
  | succ fuel ih =>
    intro i f fls fs ⟨hr, hl, hlen, hz⟩ hne hf
    obtain ⟨l, fls', rfl⟩ : ∃ l fls', fls = l :: fls' := by
      cases fls with | nil => exact absurd rfl hne | cons l t => exact ⟨l, t, rfl⟩
    obtain ⟨⟨n, v⟩, fs', rfl⟩ : ∃ p fs', fs = p :: fs' := by
      cases fs with | nil => simp at hlen | cons p t => exact ⟨p, t, rfl⟩
    rw [List.zip_cons_cons] at hz
    have hfl : Spec.Http.FieldLine l n v := hz _ List.mem_cons_self
    obtain ⟨⟨hn0, hn⟩, rest, hlr, hrest, -⟩ := (Spec.Http.fieldLine_iff _ _ _).mp hfl
    simp only [List.map_cons, List.flatten_cons, List.append_assoc] at hr
    have hi4 : i ≤ he + 4 := by
      by_cases h0 : i ≤ he + 4
      · exact h0
      · have : slice a i (he + 4) = [] := by simp [slice, show he + 4 - i = 0 by omega]
        rw [this] at hr
        have := congrArg List.length hr
        simp [Spec.Http.crlf] at this
    obtain ⟨hle1, hsl1, hsl2⟩ := slice_cut a hi4 hhe hr
    obtain ⟨hl0, hlcr, hllf⟩ := hl l List.mem_cons_self
    -- the line, then CR LF
    have hcrlf : slice a (i + l.length) (he + 4) =
        0x0d :: 0x0a :: ((fls'.map (· ++ Spec.Http.crlf)).flatten ++ Spec.Http.crlf) := by
      rw [hsl2]; rfl
    have hlen2 := slice_length a (lo := i + l.length) (hi := he + 4) hhe
    rw [hcrlf] at hlen2
    simp only [List.length_cons, List.length_append, Spec.Http.crlf, List.length_nil] at hlen2
    have hcr : a.get! (i + l.length) = 0x0d := by
      rw [slice_cons a (by omega) hhe] at hcrlf; exact (List.cons.inj hcrlf).1
    have hlf : a.get! (i + l.length + 1) = 0x0a := by
      rw [slice_cons a (by omega) hhe, slice_cons a (by omega) hhe] at hcrlf
      exact (List.cons.inj (List.cons.inj hcrlf).2).1
    have hrest' : slice a (i + l.length + 2) (he + 4) = (fls'.map (· ++ Spec.Http.crlf)).flatten ++ Spec.Http.crlf := by
      rw [slice_cons a (by omega) hhe, slice_cons a (by omega) hhe] at hcrlf
      exact (List.cons.inj (List.cons.inj hcrlf).2).2
    have hlh : i + l.length ≤ he := by omega
    -- the name and the value
    have hll : l.length = n.length + (1 + rest.length) := by rw [hlr]; simp; omega
    rw [hlr] at hsl1
    simp only [List.append_assoc, List.length_append, List.length_singleton] at hsl1
    obtain ⟨hn1, hns, hnr⟩ := slice_cut a (by omega) (by omega) hsl1
    have hcolon : a.get! (i + n.length) = 0x3a := by
      rw [slice_cons a (by omega) (by omega)] at hnr; exact (List.cons.inj hnr).1
    have hrs : slice a (i + n.length + 1) (i + (n.length + (1 + rest.length))) = rest := by
      rw [slice_cons a (by omega) (by omega)] at hnr; exact (List.cons.inj hnr).2
    obtain ⟨t1, t2, t3, t4⟩ := crlf_not_tchar
    obtain ⟨f1, f2⟩ := crlf_not_field
    have hc : Http.tokenEnd a i he = i + n.length := by
      rw [Http.tokenEnd_eq a i (by omega)]
      exact run_eq a _ (by omega) (by omega) (by omega) (by rw [hns]; exact hn) (fun _ => by rw [hcolon]; exact t3)
    have he' : Http.valueEnd a (i + n.length + 1) he = i + l.length := by
      rw [Http.valueEnd_eq a _ (by omega)]
      exact run_eq a _ (by omega) (by omega) hlh (by rw [hll, hrs]; exact hrest) (fun _ => by rw [hcr]; exact f1)
    simp only [Http.fields]
    rw [hc]
    rw [ite_eq_right (by
      simp [Http.byte, hcolon]; intro h0; cases n with | nil => exact hn0 rfl | cons _ _ => simp at h0)]
    rw [he', ite_eq_right (by simp [Http.byte, hcr, hlf])]
    by_cases h3 : he ≤ i + l.length
    · rw [ite_eq_left h3, Http.field_bad]
    · rw [ite_eq_right h3, ih (i + l.length + 2) _ fls' fs' ⟨hrest', fun x hx => hl x (List.mem_cons_of_mem _ hx),
        by simpa using hlen, fun p hp => hz p (List.mem_cons_of_mem _ hp)⟩ ?_ (by omega), Http.field_bad]
      intro h0
      subst h0
      simp at hlen2
      omega

/-- info: 'Feed.Http.fields_complete' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms Http.fields_complete

/-! ## The byte scan -/

theorem lead_le_size (a : ByteArray) (pos : Nat) : pos + 2 * Spec.Http.lead ((bs a).drop pos) ≤ max pos a.size := by
  have := lead_le ((bs a).drop pos)
  rw [List.length_drop, ← size_eq_length] at this
  omega

theorem drop_lead_eq_slice (a : ByteArray) (pos : Nat) :
    ((bs a).drop pos).drop (2 * Spec.Http.lead ((bs a).drop pos)) =
      slice a (pos + 2 * Spec.Http.lead ((bs a).drop pos)) a.size := by
  rw [List.drop_drop, drop_eq_slice]

/-- The bytes before the request-line are its empty lines. -/
theorem slice_lead (a : ByteArray) (pos : Nat) :
    slice a pos (pos + 2 * Spec.Http.lead ((bs a).drop pos)) =
      (List.replicate (Spec.Http.lead ((bs a).drop pos)) Spec.Http.crlf).flatten := by
  rw [← take_drop_eq_slice, take_lead]

theorem headLen_scan (a : ByteArray) (pos : Nat) :
    Spec.Http.headLen ((bs a).drop pos) =
      (crlf2Idx (slice a (pos + 2 * Spec.Http.lead ((bs a).drop pos)) a.size)).map
        (2 * Spec.Http.lead ((bs a).drop pos) + · + 4) := by
  rw [headLen_eq, drop_lead_eq_slice]

/-- Where `headEnd` stops, as the first CR LF CR LF after the empty lines. -/
theorem scan_headEnd (a : ByteArray) {pos lim i0 : Nat}
    (hlim : lim = min a.size (pos + Http.maxHead + 4)) (hi0 : i0 = pos + 2 * Spec.Http.lead ((bs a).drop pos)) :
    Http.headEnd a i0 lim = ((crlf2Idx (slice a i0 a.size)).filter (· + 4 ≤ lim - i0)).map (i0 + ·) := by
  have hla : lim ≤ a.size := by omega
  by_cases hle : i0 ≤ lim
  · rw [Http.headEnd_eq a hle hla, ← crlf2Idx_take, slice_take a (lo := i0) (hi := a.size) _ (by omega),
      show i0 + (lim - i0) = lim by omega]
  · rw [show lim - i0 = 0 by omega]
    unfold Http.headEnd
    rw [show lim - i0 = 0 by omega]
    cases crlf2Idx (slice a i0 a.size) with
    | none => rfl
    | some k => simp [Option.filter_some]; rfl

/-- The end of the head that `headEnd` finds, as bytes. -/
theorem scan_he (a : ByteArray) {pos lim i0 he : Nat} (hp : pos ≤ a.size)
    (hlim : lim = min a.size (pos + Http.maxHead + 4)) (hi0 : i0 = pos + 2 * Spec.Http.lead ((bs a).drop pos))
    (hhe : Http.headEnd a i0 lim = some he) :
    i0 ≤ he ∧ he + 4 ≤ lim ∧ crlf2Idx (slice a i0 a.size) = some (he - i0) ∧
      slice a he (he + 4) = Spec.Http.crlf ++ Spec.Http.crlf ∧
      Spec.Http.headLen ((bs a).drop pos) = some (he + 4 - pos) := by
  have hi0a : i0 ≤ a.size := by have := lead_le_size a pos; omega
  have h := scan_headEnd a hlim hi0
  rw [hhe] at h
  cases hk : crlf2Idx (slice a i0 a.size) with
  | none => rw [hk] at h; simp at h
  | some k =>
    rw [hk] at h
    simp only [Option.filter_some, decide_eq_true_eq] at h
    split at h
    · rename_i hkle
      simp only [Option.map_some, Option.some.injEq] at h
      subst h
      obtain ⟨hwin, hklen⟩ := crlf2Idx_some hk
      rw [slice_length a (Nat.le_refl _)] at hklen
      refine ⟨by omega, by omega, by simp, ?_, ?_⟩
      · rw [slice_drop a (lo := i0) (hi := a.size) k (by omega),
          slice_take a (lo := i0 + k) (hi := a.size) 4 (by omega)] at hwin
        rw [hwin]; rfl
      · rw [headLen_scan, ← hi0, hk]
        simp
        omega
    · simp at h

/-- 414 as the specification says: the scan's test for a request-target that is too long holds
exactly when more than `maxTarget` bytes of target have arrived within the first `maxHead + 4`
bytes (`Spec.Http.TargetTooLong`). -/
theorem scan_414 (a : ByteArray) {pos lim i0 m t : Nat} (hp : pos ≤ a.size)
    (hlim : lim = min a.size (pos + Http.maxHead + 4)) (hi0 : i0 = pos + 2 * Spec.Http.lead ((bs a).drop pos))
    (hm : m = Http.tokenEnd a i0 lim) (ht : t = Http.targetEnd a (m + 1) (min lim (m + 2 + Http.maxTarget))) :
    ((Decidable.decide (i0 < m) && Http.byte a m == 0x20) && t == m + 2 + Http.maxTarget) = true ↔
      Spec.Http.TargetTooLong ((bs a).drop pos) := by
  have hla : lim ≤ a.size := by omega
  have hu := drop_lead_eq_slice a pos
  rw [← hi0] at hu
  rw [Http.tokenEnd_eq a i0 hla] at hm
  rw [Http.targetEnd_eq a (m + 1) (by omega)] at ht
  have hi0a : i0 ≤ a.size := by
    have := lead_le_size a pos
    omega
  constructor
  · intro h
    simp only [Bool.and_eq_true, decide_eq_true_eq, beq_iff_eq, Http.byte] at h
    obtain ⟨⟨hlt, hsp⟩, htm⟩ := h
    have hma : m < a.size := byte_lt hsp (by decide)
    have hml : m ≤ lim := by
      have := run_le a Spec.Http.isTchar (i := i0) hla
      by_cases hle : i0 ≤ lim
      · rw [hm]; exact this hle
      · exfalso
        rw [show slice a i0 lim = [] by simp [slice, show lim - i0 = 0 by omega]] at hm
        simp at hm; omega
    have hB : m + 2 + Http.maxTarget ≤ lim := by
      have := run_le a notSpCrLf (i := m + 1) (hi := min lim (m + 2 + Http.maxTarget)) (by omega) (by
        have := takeWhile_length_le notSpCrLf (slice a (m + 1) (min lim (m + 2 + Http.maxTarget)))
        rw [slice_length a (by omega)] at this
        omega)
      omega
    have hT := run_all a notSpCrLf (i := m + 1) (hi := min lim (m + 2 + Http.maxTarget)) (by omega)
    rw [← ht, htm] at hT
    have hM := run_all a Spec.Http.isTchar (i := i0) (hi := lim) hla
    rw [← hm] at hM
    refine ⟨slice a i0 m, slice a (m + 1) (m + 2 + Http.maxTarget), slice a (m + 2 + Http.maxTarget) a.size,
      ?_, ?_, ?_, ?_, ?_⟩
    · rw [hu, slice_append a (mid := m) (by omega) (by omega), slice_cons a hma (Nat.le_refl _), hsp,
        slice_append a (lo := m + 1) (mid := m + 2 + Http.maxTarget) (by omega) (by omega)]
      simp
    · refine ⟨fun h0 => ?_, hM⟩
      have := slice_length a (lo := i0) (hi := m) (by omega)
      rw [h0] at this; simp at this; omega
    · rw [slice_length a (by omega)]; unfold Spec.Http.maxTarget Http.maxTarget; omega
    · intro c hc; exact (notSpCrLf_iff c).mp (hT c hc)
    · rw [slice_length a (by omega), slice_length a (by omega)]
      have : 2 * Spec.Http.lead ((bs a).drop pos) = i0 - pos := by omega
      rw [this]
      unfold Http.maxTarget at *
      unfold Http.maxHead at hlim
      unfold Spec.Http.maxHead
      omega
  · rintro ⟨M, T, rest, hs, ⟨hM0, hM⟩, hTl, hT, hb⟩
    rw [hu] at hs
    simp only [List.append_assoc, List.singleton_append] at hs
    obtain ⟨hle1, hsM, hsr⟩ := slice_cut a hi0a (Nat.le_refl _) hs
    have hlen := slice_length a (lo := i0 + M.length) (hi := a.size) (Nat.le_refl _)
    rw [hsr] at hlen
    simp only [List.length_cons, List.length_append] at hlen
    have hsp : a.get! (i0 + M.length) = 0x20 := by
      rw [slice_cons a (by omega) (Nat.le_refl _)] at hsr; exact (List.cons.inj hsr).1
    have hTs : slice a (i0 + M.length + 1) a.size = T ++ rest := by
      rw [slice_cons a (by omega) (Nat.le_refl _)] at hsr; exact (List.cons.inj hsr).2
    obtain ⟨hle2, hsT, -⟩ := slice_cut a (by omega) (Nat.le_refl _) hTs
    have h2l : 2 * Spec.Http.lead ((bs a).drop pos) = i0 - pos := by omega
    rw [h2l] at hb
    have hlimb : i0 + M.length + 1 + T.length ≤ lim := by
      rw [hlim]; unfold Http.maxHead; unfold Spec.Http.maxHead at hb; omega
    have t3 := crlf_not_tchar.2.2.2
    have hmeq : m = i0 + M.length := by
      rw [hm]
      exact run_eq a _ hla (by omega) (by omega) (by rw [hsM]; exact hM) (fun _ => by rw [hsp]; exact t3)
    subst hmeq
    have hTl' : T.length = Http.maxTarget + 1 := hTl
    have hB : min lim (i0 + M.length + 2 + Http.maxTarget) = i0 + M.length + 2 + Http.maxTarget := by omega
    have hteq : t = i0 + M.length + 2 + Http.maxTarget := by
      rw [ht, hB]
      apply run_eq a _ (by omega) (by omega) (Nat.le_refl _)
      · rw [show i0 + M.length + 2 + Http.maxTarget = i0 + M.length + 1 + T.length by omega, hsT]
        intro c hc; exact (notSpCrLf_iff c).mpr (hT c hc)
      · intro h0; omega
    simp only [Bool.and_eq_true, decide_eq_true_eq, beq_iff_eq, Http.byte]
    refine ⟨⟨?_, hsp⟩, hteq⟩
    cases M with
    | nil => exact absurd rfl hM0
    | cons _ _ => simp

theorem lit_http1 : bs Http.vHttp1 = Spec.lit "HTTP/1." := rfl

theorem not_mem_of {l : List UInt8} {x : UInt8} {p : UInt8 → Bool} (h : ∀ c ∈ l, p c = true)
    (hx : p x = false) : x ∉ l :=
  fun hm => by rw [h x hm] at hx; exact absurd hx (by decide)

/-- A request-line the scan accepts: what the checks of `scan` on the request-line say, as the
bytes of the line. -/
theorem requestLine_at (a : ByteArray) {i0 lim m t : Nat} (hla : lim ≤ a.size)
    (hm : m = Http.tokenEnd a i0 lim) (ht : t = Http.targetEnd a (m + 1) (min lim (m + 2 + Http.maxTarget)))
    (hlt : i0 < m) (hsp : a.get! m = 0x20) (hmt : m + 1 < t) (htsp : a.get! t = 0x20)
    (hver : Http.eqAt a (t + 1) (t + 1 + 7) Http.vHttp1 = true) (hdig : Http.digit (a.get! (t + 1 + 7)) = true)
    (hlf : a.get! (t + 1 + 9) = 0x0a) :
    t + 1 + 9 < a.size ∧
      slice a i0 (t + 9) = slice a i0 m ++ [0x20] ++ slice a (m + 1) t ++ [0x20] ++
        (Spec.lit "HTTP/" ++ [0x31, 0x2e, a.get! (t + 8)]) ∧
      Spec.Http.RequestLine (slice a i0 (t + 9)) (slice a i0 m) (slice a (m + 1) t) 1 (a.get! (t + 8) - 0x30).toNat ∧
      slice a i0 (t + 9) ≠ [] ∧ 0x0d ∉ slice a i0 (t + 9) ∧ 0x0a ∉ slice a i0 (t + 9) := by
  rw [Http.tokenEnd_eq a i0 hla] at hm
  rw [Http.targetEnd_eq a (m + 1) (by omega)] at ht
  have hend : t + 1 + 9 < a.size := byte_lt hlf (by decide)
  have hM := run_all a Spec.Http.isTchar (i := i0) (hi := lim) hla
  rw [← hm] at hM
  have hT := run_all a notSpCrLf (i := m + 1) (hi := min lim (m + 2 + Http.maxTarget)) (by omega)
  rw [← ht] at hT
  have hv := (eqAt_spec a Http.vHttp1 (lo := t + 1) (hi := t + 1 + 7) (by omega) (by omega)).mp hver
  rw [lit_http1] at hv
  have hline : slice a i0 (t + 9) = slice a i0 m ++ [0x20] ++ slice a (m + 1) t ++ [0x20] ++
      (Spec.lit "HTTP/" ++ [0x31, 0x2e, a.get! (t + 8)]) := by
    rw [slice_append a (mid := m) (by omega) (by omega), slice_cons a (i := m) (hi := t + 9) (by omega) (by omega), hsp,
      slice_append a (lo := m + 1) (mid := t) (by omega) (by omega),
      slice_cons a (i := t) (hi := t + 9) (by omega) (by omega),
      htsp, slice_append a (lo := t + 1) (mid := t + 1 + 7) (by omega) (by omega), hv,
      show t + 1 + 7 = t + 8 by omega, slice_cons a (i := t + 8) (hi := t + 9) (by omega) (by omega),
      show t + 8 + 1 = t + 9 by omega, slice_empty]
    simp
    rfl
  have hMne : slice a i0 m ≠ [] := by
    intro h0; have := slice_length a (lo := i0) (hi := m) (by omega); rw [h0] at this; simp at this; omega
  have hTne : slice a (m + 1) t ≠ [] := by
    intro h0; have := slice_length a (lo := m + 1) (hi := t) (by omega); rw [h0] at this; simp at this; omega
  have hd : Spec.Http.isDigit (a.get! (t + 8)) = true := by rw [show t + 8 = t + 1 + 7 by omega]; exact hdig
  obtain ⟨t1, t2, t3, t4⟩ := crlf_not_tchar
  have hTsp : ∀ c ∈ slice a (m + 1) t, c ≠ 0x20 ∧ c ≠ 0x0d ∧ c ≠ 0x0a := fun c hc => (notSpCrLf_iff c).mp (hT c hc)
  have hdcr : a.get! (t + 8) ≠ 0x0d ∧ a.get! (t + 8) ≠ 0x0a := by
    constructor <;> intro he <;> rw [he] at hd <;> exact absurd hd (by decide)
  refine ⟨hend, hline, ⟨⟨hMne, hM⟩, hTne, fun h0 => (hTsp _ h0).1 rfl, _,
    ⟨0x31, a.get! (t + 8), by decide, hd, rfl, rfl, rfl⟩, by
    rw [hline]⟩, by rw [hline]; simp, ?_, ?_⟩
  · rw [hline]
    simp only [List.mem_append, List.mem_singleton, not_or]
    refine ⟨⟨⟨⟨not_mem_of hM t1, by decide⟩, fun h0 => (hTsp _ h0).2.1 rfl⟩, by decide⟩, by decide, ?_⟩
    simp only [List.mem_cons, List.not_mem_nil, or_false, not_or]
    exact ⟨by decide, by decide, fun h => hdcr.1 h.symm⟩
  · rw [hline]
    simp only [List.mem_append, List.mem_singleton, not_or]
    refine ⟨⟨⟨⟨not_mem_of hM t2, by decide⟩, fun h0 => (hTsp _ h0).2.2 rfl⟩, by decide⟩, by decide, ?_⟩
    simp only [List.mem_cons, List.not_mem_nil, or_false, not_or]
    exact ⟨by decide, by decide, fun h => hdcr.2 h.symm⟩

/-- The head the scan reads: when the request-line passes the scan's checks and the field scan
finds no fault, the bytes up to the head's end are a head with these parts, and the field record
says what its field lines say. -/
theorem scan_head_sound (a : ByteArray) {pos lim i0 m t he : Nat} (hp : pos ≤ a.size)
    (hlim : lim = min a.size (pos + Http.maxHead + 4)) (hi0 : i0 = pos + 2 * Spec.Http.lead ((bs a).drop pos))
    (hm : m = Http.tokenEnd a i0 lim) (ht : t = Http.targetEnd a (m + 1) (min lim (m + 2 + Http.maxTarget)))
    (hhe : Http.headEnd a i0 lim = some he)
    (hlt : i0 < m) (hsp : a.get! m = 0x20) (hmt : m + 1 < t) (htsp : a.get! t = 0x20)
    (hver : Http.eqAt a (t + 1) (t + 1 + 7) Http.vHttp1 = true) (hdig : Http.digit (a.get! (t + 1 + 7)) = true)
    (hcr : a.get! (t + 1 + 8) = 0x0d) (hlf : a.get! (t + 1 + 9) = 0x0a)
    (hf : (if t + 1 + 8 == he then ({} : Http.Fields)
      else Http.fields a he (t + 1 + 10) {} (he - (t + 1 + 10))).bad = false) :
    t + 9 ≤ he ∧ ∃ fls fs, Spec.Http.IsHead (slice a pos (he + 4))
        ⟨Spec.Http.lead ((bs a).drop pos), slice a i0 (t + 9), slice a i0 m, slice a (m + 1) t, 1,
          (a.get! (t + 1 + 7) - 0x30).toNat, fls, fs⟩ ∧
      Http.Fields.Sums a (if t + 1 + 8 == he then ({} : Http.Fields)
        else Http.fields a he (t + 1 + 10) {} (he - (t + 1 + 10))) fs := by
  have hla : lim ≤ a.size := by omega
  obtain ⟨hend, hline, hrl, hl0, hlcr, hllf⟩ := requestLine_at a hla hm ht hlt hsp hmt htsp hver hdig hlf
  obtain ⟨hi0he, hhel, hk, hwin, -⟩ := scan_he a hp hlim hi0 hhe
  have hi0a : i0 ≤ a.size := by have := lead_le_size a pos; omega
  -- the head ends at the line's CR LF, or after field lines
  have hk' := hk
  rw [slice_append a (mid := t + 9) (by omega) (by omega),
    crlf2Idx_append_noCrlf2 _ _ (noCrlf2_of_ne _ fun c hc he => hlcr (he ▸ hc)),
    slice_cons a (i := t + 9) (hi := a.size) (by omega) (Nat.le_refl _),
    slice_cons a (i := t + 9 + 1) (hi := a.size) (by omega) (Nat.le_refl _),
    show t + 9 = t + 1 + 8 by omega, hcr, show t + 1 + 8 + 1 = t + 1 + 9 by omega, hlf,
    slice_length a (by omega), show t + 1 + 9 + 1 = t + 1 + 10 by omega] at hk'
  have hcase : he = t + 1 + 8 ∨ t + 1 + 10 ≤ he := by
    rcases crlf2Idx_crlf (slice a (t + 1 + 10) a.size) with hz | hz <;> rw [hz] at hk'
    · simp at hk'; omega
    · cases hz' : crlf2Idx (slice a (t + 1 + 10) a.size) with
      | none => rw [hz'] at hk'; simp at hk'
      | some z => rw [hz'] at hk'; simp at hk'; omega
  have hstart : slice a pos (he + 4) = (List.replicate (Spec.Http.lead ((bs a).drop pos)) Spec.Http.crlf).flatten ++
      slice a i0 (t + 9) ++ Spec.Http.crlf ++ slice a (t + 1 + 10) (he + 4) := by
    rw [slice_append a (lo := pos) (mid := i0) (by omega) (by omega), hi0, slice_lead, ← hi0,
      slice_append a (lo := i0) (mid := t + 9) (by omega) (by omega),
      slice_cons a (i := t + 9) (hi := he + 4) (by omega) (by omega),
      slice_cons a (i := t + 9 + 1) (hi := he + 4) (by omega) (by omega),
      show t + 9 = t + 1 + 8 by omega, hcr, show t + 1 + 8 + 1 = t + 1 + 9 by omega, hlf,
      show t + 1 + 9 + 1 = t + 1 + 10 by omega]
    simp [Spec.Http.crlf]
  by_cases h8 : (t + 1 + 8 == he) = true
  · have h8' : t + 1 + 8 = he := by simpa using h8
    rw [ite_eq_left h8] at hf ⊢
    refine ⟨by omega, [], [], ⟨⟨?_, ?_⟩, hrl, rfl, by simp⟩, Http.Fields.sums_empty a⟩
    · have hw := hwin
      rw [← h8', slice_append a (lo := t + 1 + 8) (mid := t + 1 + 10) (by omega) (by omega)] at hw
      have hw2 := (List.append_inj hw (by rw [slice_length a (by omega)]; simp [Spec.Http.crlf])).2
      rw [hstart, ← h8', show t + 1 + 8 + 4 = t + 1 + 10 + 2 by omega] at *
      rw [show t + 1 + 8 + 4 = t + 1 + 10 + 2 by omega] at hw2
      rw [hw2]
      simp
    · intro l hl; simp at hl; subst hl; exact ⟨hl0, hlcr, hllf⟩
  · rw [ite_eq_right h8] at hf ⊢
    have hge : t + 1 + 10 ≤ he := by
      rcases hcase with h | h
      · exact absurd (by simp [h]) h8
      · exact h
    obtain ⟨fls, fs, hne, ⟨hr, hl, hlen, hz⟩, hsum⟩ :=
      Http.fields_sound (by omega) hwin _ _ _ [] hf (Http.Fields.sums_empty a)
    refine ⟨by omega, fls, fs, ⟨⟨?_, ?_⟩, hrl, hlen, hz⟩, by simpa using hsum⟩
    · rw [hstart, hr]; simp [List.append_assoc]
    · intro l hm
      rcases List.mem_cons.mp hm with rfl | hm
      · exact ⟨hl0, hlcr, hllf⟩
      · exact hl l hm

/-- The scan reads every head of HTTP/1.x: if the bytes up to the end of the head that
`headEnd` finds are a head with major version 1, its request-line passes the scan's checks and the
field scan finds no fault in its field lines (the scan has answered 414 before, if the target is
too long). -/
theorem scan_head_complete (a : ByteArray) {pos lim i0 m t he : Nat} (hp : pos ≤ a.size)
    (hlim : lim = min a.size (pos + Http.maxHead + 4)) (hi0 : i0 = pos + 2 * Spec.Http.lead ((bs a).drop pos))
    (hm : m = Http.tokenEnd a i0 lim) (ht : t = Http.targetEnd a (m + 1) (min lim (m + 2 + Http.maxTarget)))
    (hhe : Http.headEnd a i0 lim = some he)
    (h414 : ¬ ((Decidable.decide (i0 < m) && Http.byte a m == 0x20) && t == m + 2 + Http.maxTarget) = true)
    {H : Spec.Http.Head} (hH : Spec.Http.IsHead (slice a pos (he + 4)) H) (hmaj : H.major = 1) :
    i0 < m ∧ a.get! m = 0x20 ∧ m + 1 < t ∧ a.get! t = 0x20 ∧ Http.eqAt a (t + 1) (t + 1 + 7) Http.vHttp1 = true ∧
      Http.digit (a.get! (t + 1 + 7)) = true ∧ a.get! (t + 1 + 8) = 0x0d ∧ a.get! (t + 1 + 9) = 0x0a ∧
      (if t + 1 + 8 == he then ({} : Http.Fields)
        else Http.fields a he (t + 1 + 10) {} (he - (t + 1 + 10))).bad = false := by
  have hla : lim ≤ a.size := by omega
  obtain ⟨hi0he, hhel, hk, hwin, -⟩ := scan_he a hp hlim hi0 hhe
  obtain ⟨⟨e, hl⟩, ⟨hM, hT0, hTsp, v, ⟨d1, d2, hd1, hd2, hv, hmaj', hmin⟩, hline⟩, hlen, hz⟩ := hH
  -- the empty lines are the input's
  have hk' : H.k = Spec.Http.lead ((bs a).drop pos) := by
    have := lead_head ⟨e, hl⟩ (slice a (he + 4) a.size)
    rw [← slice_append a (by omega) (by omega), ← drop_eq_slice] at this
    exact this.symm
  have hrest : slice a i0 (he + 4) =
      H.line ++ (Spec.Http.crlf ++ ((H.fls.map (· ++ Spec.Http.crlf)).flatten ++ Spec.Http.crlf)) := by
    have hsl : slice a pos i0 = (List.replicate H.k Spec.Http.crlf).flatten := by rw [hi0, slice_lead, hk']
    rw [slice_append a (lo := pos) (mid := i0) (by omega) (by omega), hsl] at e
    simp only [List.append_assoc] at e
    exact List.append_cancel_left e
  obtain ⟨hl0, hlcr, hllf⟩ := hl _ List.mem_cons_self
  have hd1' : d1 = 0x31 := by
    rw [hmaj] at hmaj'
    apply UInt8.toNat_inj.mp
    simp only [Spec.Http.isDigit, Bool.and_eq_true, decide_eq_true_eq, UInt8.le_iff_toNat_le] at hd1
    rw [UInt8.toNat_sub_of_le _ _ (by rw [UInt8.le_iff_toNat_le]; exact hd1.1)] at hmaj'
    have : UInt8.toNat 0x30 = 48 := rfl
    have : UInt8.toNat 0x31 = 49 := rfl
    omega
  subst hd1'
  -- cut the bytes from i0 at the request-line's parts
  rw [hline, hv] at hrest
  simp only [List.append_assoc, List.cons_append] at hrest
  have htot := congrArg List.length hrest
  rw [slice_length a (by omega)] at htot
  simp only [List.length_append, List.length_cons, Spec.Http.crlf, List.length_nil] at htot
  have hlit5 : (Spec.lit "HTTP/").length = 5 := rfl
  rw [hlit5] at htot
  obtain ⟨hle1, hsM, hr1⟩ := slice_cut a (by omega) (by omega) hrest
  have hsp : a.get! (i0 + H.method.length) = 0x20 := by
    rw [slice_cons a (by have := congrArg List.length hr1; rw [slice_length a (by omega)] at this; simp at this; omega)
      (by omega)] at hr1
    exact (List.cons.inj hr1).1
  have hr2 : slice a (i0 + H.method.length + 1) (he + 4) = H.target ++ (0x20 :: (Spec.lit "HTTP/" ++
      (0x31 :: 0x2e :: d2 :: (Spec.Http.crlf ++ ((H.fls.map (· ++ Spec.Http.crlf)).flatten ++ Spec.Http.crlf))))) := by
    rw [slice_cons a (by have := congrArg List.length hr1; rw [slice_length a (by omega)] at this; simp at this; omega)
      (by omega)] at hr1
    have := (List.cons.inj hr1).2
    simpa [List.append_assoc] using this
  obtain ⟨hle2, hsT, hr3⟩ := slice_cut a (by omega) (by omega) hr2
  have hlen3 := congrArg List.length hr3
  rw [slice_length a (by omega)] at hlen3
  simp [Spec.Http.crlf, Spec.lit] at hlen3
  have htsp : a.get! (i0 + H.method.length + 1 + H.target.length) = 0x20 := by
    rw [slice_cons a (by omega) (by omega)] at hr3; exact (List.cons.inj hr3).1
  have hr4 : slice a (i0 + H.method.length + 1 + H.target.length + 1) (he + 4) = Spec.lit "HTTP/1." ++ (d2 ::
      (Spec.Http.crlf ++ ((H.fls.map (· ++ Spec.Http.crlf)).flatten ++ Spec.Http.crlf))) := by
    rw [slice_cons a (by omega) (by omega)] at hr3
    have := (List.cons.inj hr3).2
    rw [this]
    rfl
  obtain ⟨hle4, hsV, hr5⟩ := slice_cut a (by omega) (by omega) hr4
  have hlit7 : (Spec.lit "HTTP/1.").length = 7 := rfl
  rw [hlit7] at hle4 hsV hr5
  have hdig : a.get! (i0 + H.method.length + 1 + H.target.length + 1 + 7) = d2 := by
    rw [slice_cons a (by omega) (by omega)] at hr5; exact (List.cons.inj hr5).1
  have hr6 : slice a (i0 + H.method.length + 1 + H.target.length + 1 + 7 + 1) (he + 4) =
      0x0d :: 0x0a :: ((H.fls.map (· ++ Spec.Http.crlf)).flatten ++ Spec.Http.crlf) := by
    rw [slice_cons a (by omega) (by omega)] at hr5; exact (List.cons.inj hr5).2
  have hcr : a.get! (i0 + H.method.length + 1 + H.target.length + 1 + 7 + 1) = 0x0d := by
    rw [slice_cons a (by omega) (by omega)] at hr6; exact (List.cons.inj hr6).1
  have hlf : a.get! (i0 + H.method.length + 1 + H.target.length + 1 + 7 + 1 + 1) = 0x0a := by
    rw [slice_cons a (by omega) (by omega), slice_cons a (by omega) (by omega)] at hr6
    exact (List.cons.inj (List.cons.inj hr6).2).1
  have hr7 : slice a (i0 + H.method.length + 1 + H.target.length + 1 + 7 + 1 + 1 + 1) (he + 4) =
      (H.fls.map (· ++ Spec.Http.crlf)).flatten ++ Spec.Http.crlf := by
    rw [slice_cons a (by omega) (by omega), slice_cons a (by omega) (by omega)] at hr6
    exact (List.cons.inj (List.cons.inj hr6).2).2
  -- the method
  obtain ⟨t1, t2, t3, t4⟩ := crlf_not_tchar
  have hmeq : m = i0 + H.method.length := by
    rw [hm, Http.tokenEnd_eq a i0 hla]
    exact run_eq a _ hla (by omega) (by omega) (by rw [hsM]; exact hM.2) (fun _ => by rw [hsp]; exact t4)
  subst hmeq
  have hMpos : 0 < H.method.length := by cases h : H.method with | nil => exact absurd h hM.1 | cons _ _ => simp
  -- the target, which is not too long
  have hTok : ∀ c ∈ H.target, notSpCrLf c = true := by
    intro c hc
    apply (notSpCrLf_iff c).mpr
    refine ⟨fun h0 => hTsp (h0 ▸ hc), fun h0 => hlcr ?_, fun h0 => hllf ?_⟩
    · rw [hline]; simp [h0 ▸ hc]
    · rw [hline]; simp [h0 ▸ hc]
  have htlen : H.target.length ≤ Http.maxTarget := by
    apply Classical.byContradiction
    intro hgt
    apply h414
    have htB : t = i0 + H.method.length + 2 + Http.maxTarget := by
      rw [ht, Http.targetEnd_eq a _ (by omega)]
      apply run_eq a _ (by omega) (by omega) (by omega)
      · intro c hc
        apply hTok
        have : slice a (i0 + H.method.length + 1) (i0 + H.method.length + 2 + Http.maxTarget) =
            H.target.take (Http.maxTarget + 1) := by
          rw [← hsT,
            slice_take a (lo := i0 + H.method.length + 1) (hi := i0 + H.method.length + 1 + H.target.length) _
              (by omega),
            show i0 + H.method.length + 1 + (Http.maxTarget + 1) = i0 + H.method.length + 2 + Http.maxTarget by omega]
        rw [this] at hc
        exact List.mem_of_mem_take hc
      · intro h0; omega
    simp only [Bool.and_eq_true, decide_eq_true_eq, beq_iff_eq, Http.byte]
    exact ⟨⟨by omega, hsp⟩, htB⟩
  have hteq : t = i0 + H.method.length + 1 + H.target.length := by
    rw [ht, Http.targetEnd_eq a _ (by omega)]
    apply run_eq a _ (by omega) (by omega) (by omega)
    · rw [hsT]; exact hTok
    · intro _; rw [htsp]; decide
  subst hteq
  have hT0' : 0 < H.target.length := by cases h : H.target with | nil => exact absurd h hT0 | cons _ _ => simp
  refine ⟨by omega, hsp, by omega, htsp, ?_, ?_, hcr, hlf, ?_⟩
  · rw [eqAt_spec a _ (by omega) (by omega), lit_http1, hsV]
  · rw [hdig]; exact hd2
  · by_cases hf0 : H.fls = []
    · have h8 : (i0 + H.method.length + 1 + H.target.length + 1 + 8 == he) = true := by
        rw [hf0] at hr7
        have := congrArg List.length hr7
        rw [slice_length a (by omega)] at this
        simp [Spec.Http.crlf] at this
        simp; omega
      rw [ite_eq_left h8]
    · have h8 : ¬ (i0 + H.method.length + 1 + H.target.length + 1 + 8 == he) = true := by
        obtain ⟨l, fls', hfl⟩ : ∃ l fls', H.fls = l :: fls' := by
          cases h : H.fls with | nil => exact absurd h hf0 | cons l t => exact ⟨l, t, rfl⟩
        rw [hfl] at hr7
        have := congrArg List.length hr7
        rw [slice_length a (by omega)] at this
        simp [Spec.Http.crlf] at this
        have hl1 := (hl l (by rw [hfl]; simp)).1
        have : l.length ≥ 1 := by cases l with | nil => exact absurd rfl hl1 | cons _ _ => simp
        simp; omega
      rw [ite_eq_right h8]
      rw [show i0 + H.method.length + 1 + H.target.length + 1 + 10 =
        i0 + H.method.length + 1 + H.target.length + 1 + 7 + 1 + 1 + 1 by omega]
      exact Http.fields_complete (by omega) _ _ _ H.fls H.fs
        ⟨hr7, fun l hm => hl l (List.mem_cons_of_mem _ hm), hlen, hz⟩ hf0 (Nat.le_refl _)

/-- **The byte scan reads the head as `Feed/Spec/Http.lean` says**: 414 when more than `maxTarget`
bytes of request-target have arrived within the first `maxHead + 4` bytes of the input from `pos`;
else, when no head ends within them, 431 once they have all arrived and a wait before; else 400 when
the bytes up to the first CR LF CR LF after the empty lines are not a head of HTTP/1.x; else that
head's parts, and the record of what its field lines say. -/
theorem Http.scan_spec (a : ByteArray) {pos : Nat} (hp : pos ≤ a.size) :
    match Http.scan a pos with
    | .incomplete =>
      ¬ Spec.Http.TargetTooLong ((bs a).drop pos) ∧ Spec.Http.headLen ((bs a).drop pos) = none ∧
        ((bs a).drop pos).length < Spec.Http.maxHead + 4
    | .bad st =>
      (st = 414 ∧ Spec.Http.TargetTooLong ((bs a).drop pos)) ∨
      (st = 431 ∧ ¬ Spec.Http.TargetTooLong ((bs a).drop pos) ∧
        (∀ n, Spec.Http.headLen ((bs a).drop pos) = some n → Spec.Http.maxHead + 4 < n) ∧
        Spec.Http.maxHead + 4 ≤ ((bs a).drop pos).length) ∨
      (st = 400 ∧ ¬ Spec.Http.TargetTooLong ((bs a).drop pos) ∧ ∃ n, Spec.Http.headLen ((bs a).drop pos) = some n ∧
        n ≤ Spec.Http.maxHead + 4 ∧ ∀ H, Spec.Http.IsHead (((bs a).drop pos).take n) H → H.major ≠ 1)
    | .head i0 m t minor he f =>
      ¬ Spec.Http.TargetTooLong ((bs a).drop pos) ∧ i0 = pos + 2 * Spec.Http.lead ((bs a).drop pos) ∧ i0 < m ∧
        m + 1 < t ∧ t ≤ m + 1 + Spec.Http.maxTarget ∧ t + 9 ≤ he ∧ he + 4 ≤ a.size ∧
        Spec.Http.headLen ((bs a).drop pos) = some (he + 4 - pos) ∧ he + 4 - pos ≤ Spec.Http.maxHead + 4 ∧
        ∃ fls fs, Spec.Http.IsHead (((bs a).drop pos).take (he + 4 - pos))
          ⟨Spec.Http.lead ((bs a).drop pos), slice a i0 (t + 9), slice a i0 m, slice a (m + 1) t, 1, minor, fls, fs⟩ ∧
          Http.Fields.Sums a f fs := by
  have hmh : Http.maxHead = Spec.Http.maxHead := rfl
  have hmt : Http.maxTarget = Spec.Http.maxTarget := rfl
  have hslen : ((bs a).drop pos).length = a.size - pos := by rw [List.length_drop, ← size_eq_length]
  have hi0a := lead_le_size a pos
  unfold Http.scan
  dsimp only
  rw [Http.skipLead_eq]
  generalize hlim : min a.size (pos + Http.maxHead + 4) = lim
  generalize hi0 : pos + 2 * Spec.Http.lead ((bs a).drop pos) = i0
  generalize hm : Http.tokenEnd a i0 lim = m
  generalize ht : Http.targetEnd a (m + 1) (min lim (m + 2 + Http.maxTarget)) = t
  have h414 := scan_414 a hp hlim.symm hi0.symm hm.symm ht.symm
  by_cases hT : ((Decidable.decide (i0 < m) && Http.byte a m == 0x20) && t == m + 2 + Http.maxTarget) = true
  · rw [ite_eq_left hT]
    exact Or.inl ⟨rfl, h414.mp hT⟩
  rw [ite_eq_right hT]
  have hnT : ¬ Spec.Http.TargetTooLong ((bs a).drop pos) := fun h => hT (h414.mpr h)
  have hhe := scan_headEnd a hlim.symm hi0.symm
  have hlen := headLen_scan a pos
  rw [hi0] at hlen
  cases hh : Http.headEnd a i0 lim with
  | none =>
    dsimp only
    rw [hh] at hhe
    have hk : ∀ k, crlf2Idx (slice a i0 a.size) = some k → ¬ k + 4 ≤ lim - i0 := by
      intro k hk hle
      rw [hk] at hhe
      simp [Option.filter_some, hle] at hhe
    by_cases hbig : pos + Http.maxHead + 4 ≤ a.size
    · rw [ite_eq_left hbig]
      refine Or.inr (Or.inl ⟨rfl, hnT, fun n hn => ?_, by rw [hslen, ← hmh]; omega⟩)
      rw [hlen] at hn
      cases hc : crlf2Idx (slice a i0 a.size) with
      | none => rw [hc] at hn; simp at hn
      | some k =>
        rw [hc] at hn
        simp only [Option.map_some, Option.some.injEq] at hn
        have := hk k hc
        rw [← hmh]
        omega
    · rw [ite_eq_right hbig]
      refine ⟨hnT, ?_, by rw [hslen, ← hmh]; omega⟩
      rw [hlen]
      cases hc : crlf2Idx (slice a i0 a.size) with
      | none => rfl
      | some k =>
        exfalso
        have := (crlf2Idx_some hc).2
        rw [slice_length a (Nat.le_refl _)] at this
        exact hk k hc (by omega)
  | some he =>
    dsimp only
    obtain ⟨hi0he, hhel, hkk, hwin, hlenhe⟩ := scan_he a hp hlim.symm hi0.symm hh
    have htake : ((bs a).drop pos).take (he + 4 - pos) = slice a pos (he + 4) := by
      rw [take_drop_eq_slice, show pos + (he + 4 - pos) = he + 4 by omega]
    have hn400 : ∀ H, Spec.Http.IsHead (((bs a).drop pos).take (he + 4 - pos)) H → H.major = 1 →
        (Decidable.decide (i0 < m) && Http.byte a m == 0x20 && Decidable.decide (m + 1 < t) && Http.byte a t == 0x20 &&
          Http.eqAt a (t + 1) (t + 1 + 7) Http.vHttp1 && Http.digit (Http.byte a (t + 1 + 7)) &&
          Http.byte a (t + 1 + 8) == 0x0d && Http.byte a (t + 1 + 9) == 0x0a) = true ∧
        (if t + 1 + 8 == he then ({} : Http.Fields)
          else Http.fields a he (t + 1 + 10) {} (he - (t + 1 + 10))).bad = false := by
      intro H hH hmaj
      rw [htake] at hH
      obtain ⟨c1, c2, c3, c4, c5, c6, c7, c8, c9⟩ :=
        scan_head_complete a hp hlim.symm hi0.symm hm.symm ht.symm hh hT hH hmaj
      refine ⟨?_, c9⟩
      simp [Http.byte, c1, c2, c3, c4, c5, c6, c7, c8]
    by_cases hok : (Decidable.decide (i0 < m) && Http.byte a m == 0x20 && Decidable.decide (m + 1 < t) &&
        Http.byte a t == 0x20 && Http.eqAt a (t + 1) (t + 1 + 7) Http.vHttp1 && Http.digit (Http.byte a (t + 1 + 7)) &&
        Http.byte a (t + 1 + 8) == 0x0d && Http.byte a (t + 1 + 9) == 0x0a) = true
    · rw [ite_eq_right (by simp [hok])]
      by_cases hfb : (if t + 1 + 8 == he then ({} : Http.Fields)
          else Http.fields a he (t + 1 + 10) {} (he - (t + 1 + 10))).bad = true
      · rw [ite_eq_left hfb]
        refine Or.inr (Or.inr ⟨rfl, hnT, he + 4 - pos, hlenhe, by rw [← hmh]; omega, fun H hH hmaj => ?_⟩)
        have := (hn400 H hH hmaj).2
        rw [hfb] at this
        exact absurd this (by decide)
      · rw [ite_eq_right hfb]
        have hfb' : (if t + 1 + 8 == he then ({} : Http.Fields)
            else Http.fields a he (t + 1 + 10) {} (he - (t + 1 + 10))).bad = false := by
          simpa using hfb
        simp only [Bool.and_eq_true, decide_eq_true_eq, beq_iff_eq, Http.byte] at hok
        obtain ⟨⟨⟨⟨⟨⟨⟨hlt, hsp⟩, hmt'⟩, htsp⟩, hver⟩, hdig⟩, hcr⟩, hlf⟩ := hok
        obtain ⟨h9, fls, fs, hH, hS⟩ :=
          scan_head_sound a hp hlim.symm hi0.symm hm.symm ht.symm hh hlt hsp hmt' htsp hver hdig hcr hlf hfb'
        have htle : t ≤ m + 1 + Spec.Http.maxTarget := by
          have h1 := takeWhile_length_le notSpCrLf (slice a (m + 1) (min lim (m + 2 + Http.maxTarget)))
          rw [slice_length a (by omega)] at h1
          have h2 :
              t = m + 1 + (List.takeWhile notSpCrLf (slice a (m + 1) (min lim (m + 2 + Http.maxTarget)))).length := by
            rw [← ht, Http.targetEnd_eq a _ (by omega)]
          have hne : t ≠ m + 2 + Http.maxTarget := by
            intro h0; apply hT; simp [Http.byte, hlt, hsp, h0]
          rw [← hmt]
          omega
        refine ⟨hnT, rfl, hlt, hmt', htle, h9, by omega, hlenhe, by rw [← hmh]; omega, fls, fs, ?_, hS⟩
        rw [htake]
        exact hH
    · rw [ite_eq_left (by simp [hok])]
      refine Or.inr (Or.inr ⟨rfl, hnT, he + 4 - pos, hlenhe, by rw [← hmh]; omega, fun H hH hmaj => ?_⟩)
      exact hok (hn400 H hH hmaj).1

/-- info: 'Feed.Http.scan_spec' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms Http.scan_spec

/-! ## What the record says, as `HeadOk` and `IsRequest` read it -/

namespace Http.Fields.Sums
variable {a : ByteArray} {f : Http.Fields} {fs : List (Spec.Http.Bytes × Spec.Http.Bytes)}

/-- No Host line, or exactly one, with its value. -/
theorem hosts_zero (h : Sums a f fs) : f.hosts = 0 ↔ Spec.Http.values fs (Spec.lit "host") = [] := by
  rw [h.hosts, List.length_eq_zero_iff]

theorem hosts_one (h : Sums a f fs) (h1 : f.hosts = 1) :
    Spec.Http.values fs (Spec.lit "host") = [slice a f.hostLo f.hostHi] := by
  have hl := h.hosts
  have hg := h.host (by omega)
  rw [h1] at hl
  match hv : Spec.Http.values fs (Spec.lit "host"), hl with
  | [x], _ => rw [hv] at hg; simp at hg; rw [hg]

theorem hosts_many (h : Sums a f fs) (h2 : 2 ≤ f.hosts) : 2 ≤ (Spec.Http.values fs (Spec.lit "host")).length := by
  rw [← h.hosts]; exact h2

/-- The Authorization value a request carries: none without the line, its value with one. -/
theorem auth_head (h : Sums a f fs) (h1 : f.auths ≤ 1) :
    (Spec.Http.values fs (Spec.lit "authorization")).head? =
      if f.auths == 1 then some (slice a f.authLo f.authHi) else none := by
  have hl := h.auths
  by_cases h0 : f.auths = 1
  · have hg := h.auth (by omega)
    rw [h0] at hl
    rw [ite_eq_left (by simp [h0])]
    match hv : Spec.Http.values fs (Spec.lit "authorization"), hl with
    | [x], _ => rw [hv] at hg; simp at hg; rw [hg]; rfl
  · rw [ite_eq_right (by simpa using h0)]
    have : f.auths = 0 := by omega
    rw [this] at hl
    rw [List.eq_nil_of_length_eq_zero hl.symm]
    rfl

theorem auths_le (h : Sums a f fs) : (Spec.Http.values fs (Spec.lit "authorization")).length ≤ 1 ↔ f.auths ≤ 1 := by
  rw [h.auths]

theorem coding_false (h : Sums a f fs) :
    f.coding = false ↔ Spec.Http.values fs (Spec.lit "transfer-encoding") = [] := by
  rw [h.coding]
  cases Spec.Http.values fs (Spec.lit "transfer-encoding") <;> simp

/-- Whether the connection closes after the answer (RFC 9112 §9.3). -/
theorem closes_eq (h : Sums a f fs) (minor : Nat) :
    Spec.Http.closes minor fs = (f.close || (minor == 0 && !f.keepAlive)) := by
  rw [Spec.Http.closes, h.close, h.keepAlive]

/-- The Content-Length the record stands for. -/
theorem contentLength_eq (h : Sums a f fs) :
    Spec.Http.contentLength fs =
      if f.lenBad then none else if f.hasLen then decimal (slice a f.lenLo f.lenHi) 0 else some 0 := by
  unfold Spec.Http.contentLength
  cases hv : Spec.Http.values fs (Spec.lit "content-length") with
  | nil =>
    obtain ⟨h1, h2⟩ := h.noLen hv
    simp [h1, h2]
  | cons v vs =>
    obtain ⟨h1, h2⟩ := h.len v vs hv
    dsimp only
    by_cases hb : f.lenBad = true
    · have hall := congrArg (!·) h1
      simp only [Bool.not_not, hb, Bool.not_true] at hall
      simp [← hall, hb]
    · have hb' : f.lenBad = false := by simpa using hb
      have hall := congrArg (!·) h1
      simp only [Bool.not_not, hb', Bool.not_false] at hall
      obtain ⟨hl, hsl⟩ := h2 hb'
      simp [← hall, hb', hl, hsl, decimal_dropZeros]

/-- The length of the content: when the Content-Length values agree, the record's digits are
their number, which `lengthOf` reads up to `maxBody + 1`. -/
theorem length_eq (h : Sums a f fs) (hb : f.lenBad = false) :
    ∃ n, Spec.Http.contentLength fs = some n ∧
      (if f.hasLen then Http.lengthOf a f.lenLo f.lenHi else 0) = min n (Http.maxBody + 1) := by
  rw [h.contentLength_eq, ite_eq_right (by simp [hb])]
  by_cases hl : f.hasLen = true
  · rw [ite_eq_left hl, ite_eq_left hl]
    cases hv : Spec.Http.values fs (Spec.lit "content-length") with
    | nil => exact absurd (h.noLen hv).1 (by rw [hl]; decide)
    | cons v vs =>
      obtain ⟨h1, h2⟩ := h.len v vs hv
      have hall := congrArg (!·) h1
      simp only [Bool.not_not, hb, Bool.not_false] at hall
      obtain ⟨-, hsl⟩ := h2 hb
      have vd : ∀ c ∈ v, Spec.Http.isDigit c = true := by
        have := (List.all_eq_true.mp hall.symm) v List.mem_cons_self
        simp only [Bool.and_eq_true, List.all_eq_true] at this
        exact this.1.2
      obtain ⟨n, hn⟩ := decimal_isSome (slice a f.lenLo f.lenHi) 0 (by
        rw [hsl]; exact fun c hc => vd c (mem_of_mem_dropWhile hc))
      exact ⟨n, hn, Http.lengthOf_eq a h.len_le.2 hn⟩
  · rw [ite_eq_right hl, ite_eq_right hl]
    exact ⟨0, rfl, by simp⟩

/-- The Content-Length values agree exactly when the record finds none bad. -/
theorem lenBad_iff (h : Sums a f fs) : f.lenBad = false ↔ ∃ n, Spec.Http.contentLength fs = some n := by
  constructor
  · intro hb
    obtain ⟨n, hn, -⟩ := h.length_eq hb
    exact ⟨n, hn⟩
  · rintro ⟨n, hn⟩
    rw [h.contentLength_eq] at hn
    cases hb : f.lenBad with
    | false => rfl
    | true => rw [hb] at hn; simp at hn

/-- `finish`'s test of the Host lines, as `HeadOk.host` reads them: none in HTTP/1.0, else one with
a valid value (`ok` is the test of the value, `P` what it decides). -/
theorem host_iff (h : Sums a f fs) (minor : Nat) {ok : Bool} {P : Spec.Http.Bytes → Prop}
    (hok : ok = true ↔ P (slice a f.hostLo f.hostHi)) :
    (if f.hosts == 0 then minor == 0 else f.hosts == 1 && ok) = true ↔
      match Spec.Http.values fs (Spec.lit "host") with
      | [] => minor = 0
      | [v] => P v
      | _ => False := by
  by_cases h0 : f.hosts = 0
  · rw [(h.hosts_zero).mp h0]
    simp [h0]
  · by_cases h1 : f.hosts = 1
    · rw [h.hosts_one h1]
      simp [h1, hok]
    · have h2 := h.hosts_many (by omega)
      rw [ite_eq_right (by simpa using h0)]
      have : (f.hosts == 1) = false := by simpa using h1
      rw [this]
      match hv : Spec.Http.values fs (Spec.lit "host"), h2 with
      | _ :: _ :: _, _ => simp

end Http.Fields.Sums

/-- The method the API routes on, as `finish` reads the method token. -/
theorem Http.method_eq (a : ByteArray) {lo hi : Nat} (h : lo ≤ hi) (h' : hi ≤ a.size) :
    (if (Http.eqAt a lo hi Http.mHead || Http.eqAt a lo hi Http.mGet) = true then Http.Method.get
      else if Http.eqAt a lo hi Http.mPost = true then Http.Method.post else Http.Method.other) =
      Spec.Http.methodOf (slice a lo hi) := by
  rw [Http.eqAt_lit_iff a h h', Http.eqAt_lit_iff a h h', Http.eqAt_lit_iff a h h', Spec.Http.methodOf]
  have e1 : bs Http.mHead = Spec.lit "HEAD" := rfl
  have e2 : bs Http.mGet = Spec.lit "GET" := rfl
  have e3 : bs Http.mPost = Spec.lit "POST" := rfl
  rw [e1, e2, e3]
  have d1 : Spec.lit "POST" ≠ Spec.lit "HEAD" := by decide
  have d2 : Spec.lit "POST" ≠ Spec.lit "GET" := by decide
  have d3 : Spec.lit "HEAD" ≠ Spec.lit "GET" := by decide
  by_cases g : slice a lo hi = Spec.lit "GET" <;> by_cases hd : slice a lo hi = Spec.lit "HEAD" <;>
    by_cases p : slice a lo hi = Spec.lit "POST" <;> simp [g, hd, p, d1, d2, d3]

end Feed

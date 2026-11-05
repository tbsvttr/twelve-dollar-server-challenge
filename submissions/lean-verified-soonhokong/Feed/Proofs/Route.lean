import Feed.Proofs.Bytes

/-!
# Routing

`route`, which compares byte ranges of the input in place, computes the specification's
`Spec.route` on the path's bytes.
-/
namespace Feed
open Spec Http

/-! ## Byte ranges as lists -/

theorem get!_eq (a : ByteArray) (i : Nat) : a.get! i = ((bs a)[i]?).getD 0 := by
  cases a with
  | mk d => simp only [ByteArray.get!, bs, getElem!_def, Array.getElem?_toList]; cases d[i]? <;> rfl

theorem slice_length (a : ByteArray) {lo hi : Nat} (h : hi ≤ a.size) : (slice a lo hi).length = hi - lo := by
  simp only [slice, List.length_take, List.length_drop, Array.length_toList]
  have : a.data.size = a.size := rfl
  omega

theorem slice_getElem? (a : ByteArray) {lo hi k : Nat} (hk : lo + k < hi) (h : hi ≤ a.size) :
    (slice a lo hi)[k]? = some (a.get! (lo + k)) := by
  have : lo + k < a.data.toList.length := by simp; exact Nat.lt_of_lt_of_le hk h
  simp only [slice, List.getElem?_take, List.getElem?_drop, get!_eq, bs]
  rw [ite_eq_left (by omega), List.getElem?_eq_getElem this]
  rfl

theorem slice_empty (a : ByteArray) (lo : Nat) : slice a lo lo = [] := by simp [slice]

theorem slice_cons (a : ByteArray) {i hi : Nat} (hi' : i < hi) (h : hi ≤ a.size) :
    slice a i hi = a.get! i :: slice a (i + 1) hi := by
  apply List.ext_getElem?
  intro k
  cases k with
  | zero => rw [slice_getElem? a (by omega) h]; simp
  | succ k =>
    rw [List.getElem?_cons_succ]
    by_cases hk : i + 1 + k < hi
    · rw [slice_getElem? a (by omega) h, slice_getElem? a hk h, Nat.add_right_comm, Nat.add_assoc]
    · rw [List.getElem?_eq_none (by rw [slice_length a h]; omega), List.getElem?_eq_none (by rw [slice_length a h]; omega)]

theorem slice_take (a : ByteArray) {lo hi : Nat} (k : Nat) (_ : lo + k ≤ hi) :
    (slice a lo hi).take k = slice a lo (lo + k) := by
  simp only [slice, List.take_take]; congr 1; omega

theorem slice_drop (a : ByteArray) {lo hi : Nat} (k : Nat) (_ : lo + k ≤ hi) :
    (slice a lo hi).drop k = slice a (lo + k) hi := by
  simp only [slice, List.drop_take, List.drop_drop]; congr 1 <;> omega

/-- A byte range equals a list when they have the same length and agree at every position. -/
theorem slice_eq_iff (a : ByteArray) {lo hi : Nat} (h : lo ≤ hi) (h' : hi ≤ a.size) (l : List UInt8) :
    slice a lo hi = l ↔ hi - lo = l.length ∧ ∀ k < l.length, a.get! (lo + k) = l[k]?.getD 0 := by
  constructor
  · rintro rfl
    refine ⟨(slice_length a h').symm, fun k hk => ?_⟩
    rw [slice_length a h'] at hk
    rw [slice_getElem? a (by omega) h']; rfl
  · rintro ⟨hlen, hk⟩
    apply List.ext_getElem?
    intro k
    by_cases hkl : k < l.length
    · rw [slice_getElem? a (by omega) h', hk k hkl, List.getElem?_eq_getElem hkl]; rfl
    · rw [List.getElem?_eq_none (by rw [slice_length a h']; omega), List.getElem?_eq_none (by omega)]

/-! ## The comparisons -/

theorem eqAt_go (a lit : ByteArray) (lo : Nat) :
    ∀ f k, eqAt.go a lo lit k f = true ↔ ∀ j, k ≤ j → j < k + f → a.get! (lo + j) = lit.get! j := by
  intro f
  induction f with
  | zero => intro k; simp [eqAt.go]; intro j h1 h2; omega
  | succ f ih =>
    intro k
    simp only [eqAt.go, Bool.and_eq_true, beq_iff_eq, byte, ih (k + 1)]
    constructor
    · rintro ⟨h0, hr⟩ j h1 h2
      rcases Nat.eq_or_lt_of_le h1 with rfl | hlt
      · exact h0
      · exact hr j (by omega) (by omega)
    · intro h
      exact ⟨h k (Nat.le_refl _) (by omega), fun j h1 h2 => h j (by omega) (by omega)⟩

/-- `eqAt` compares a range of the input with a literal. -/
theorem eqAt_spec (a lit : ByteArray) {lo hi : Nat} (h : lo ≤ hi) (h' : hi ≤ a.size) :
    eqAt a lo hi lit = true ↔ slice a lo hi = bs lit := by
  rw [slice_eq_iff a h h', eqAt, Bool.and_eq_true, beq_iff_eq, eqAt_go, ← size_eq_length]
  constructor
  · rintro ⟨hl, hk⟩
    refine ⟨hl, fun k hk' => ?_⟩
    rw [hk k (Nat.zero_le _) (by omega), get!_eq]
  · rintro ⟨hl, hk⟩
    refine ⟨hl, fun j _ hj => ?_⟩
    rw [hk j (by simpa using hj), get!_eq]

theorem findByte_go (a : ByteArray) (b : UInt8) (hi : Nat) :
    ∀ f i, i + f = min hi a.size →
      (Bytes.findByte.go a b hi i f = min hi a.size ↔ ∀ j, i ≤ j → j < i + f → a.get! j ≠ b) := by
  intro f
  induction f with
  | zero => intro i _; simp [Bytes.findByte.go]; intro j h1 h2; omega
  | succ f ih =>
    intro i hif
    simp only [Bytes.findByte.go]
    split
    · rename_i hb
      simp only [beq_iff_eq] at hb
      constructor
      · intro h; omega
      · intro h; exact absurd hb (h i (Nat.le_refl _) (by omega))
    · rename_i hb
      simp only [beq_iff_eq] at hb
      rw [ih (i + 1) (by omega)]
      constructor
      · intro h j h1 h2
        rcases Nat.eq_or_lt_of_le h1 with rfl | hlt
        · exact hb
        · exact h j (by omega) (by omega)
      · intro h j h1 h2; exact h j (by omega) (by omega)

/-- `findByte` reaches the end of the range exactly when the byte does not occur in it. -/
theorem findByte_spec (a : ByteArray) (b : UInt8) {lo hi : Nat} (h : lo ≤ hi) (h' : hi ≤ a.size) :
    Bytes.findByte a b lo hi = hi ↔ b ∉ slice a lo hi := by
  have hm : min hi a.size = hi := Nat.min_eq_left h'
  have hgo := findByte_go a b hi (min hi a.size - lo) lo (by omega)
  simp only [hm] at hgo
  unfold Bytes.findByte
  simp only [hm]
  rw [hgo]
  constructor
  · intro hn hmem
    obtain ⟨k, hk, hkb⟩ := List.getElem_of_mem hmem
    rw [slice_length a h'] at hk
    have := slice_getElem? a (lo := lo) (hi := hi) (k := k) (by omega) h'
    rw [List.getElem?_eq_getElem (by rw [slice_length a h']; omega), hkb] at this
    exact hn (lo + k) (by omega) (by omega) (Option.some.inj this).symm
  · intro hn j h1 h2 hj
    apply hn
    have := slice_getElem? a (lo := lo) (hi := hi) (k := j - lo) (by omega) h'
    rw [Nat.add_sub_cancel' h1, hj] at this
    exact List.mem_of_getElem? this

/-! ## The `:id` segment -/

theorem parseId_go (a : ByteArray) : ∀ f i acc, i + f ≤ a.size →
    parseId.go a i f acc = decimal (slice a i (i + f)) acc := by
  intro f
  induction f with
  | zero => intro i acc _; simp [parseId.go, slice_empty, decimal]
  | succ f ih =>
    intro i acc h
    rw [slice_cons a (by omega) h, parseId.go, decimal, show i + (f + 1) = i + 1 + f by omega, ← ih (i + 1) _ (by omega)]
    simp only [Bool.and_eq_true, decide_eq_true_eq]

def PostId.toOption : PostId → Option Nat
  | .ok n => some n
  | .invalid => none

theorem parseId_spec (a : ByteArray) {lo hi : Nat} (h : lo ≤ hi) (h' : hi ≤ a.size) :
    (parseId a lo hi).toOption = postId (slice a lo hi) := by
  unfold parseId postId
  rw [parseId_go a _ _ _ (by omega), show lo + (hi - lo) = hi by omega]
  split
  · rename_i n hn
    rw [hn]
    split
    · rfl
    · have : lo = hi := by omega
      subst this
      simp [slice_empty, decimal] at hn
  · rename_i hn
    split
    · rename_i n hn'; exact absurd hn' (hn n)
    · rfl

/-! ## Routes -/

def Route.toSpec : Route → Spec.Route
  | .health => .health
  | .feed => .feed
  | .post id => .post id.toOption
  | .create => .create
  | .like id => .like id.toOption
  | .notFound => .notFound

theorem dropPrefix_slice (a lit : ByteArray) {lo hi : Nat} (h : lo + lit.size ≤ hi) (h' : hi ≤ a.size) :
    dropPrefix (bs lit) (slice a lo hi) =
      if eqAt a lo (lo + lit.size) lit then some (slice a (lo + lit.size) hi) else none := by
  rw [dropPrefix, ← size_eq_length, slice_take a _ h, slice_drop a _ h]
  by_cases he : eqAt a lo (lo + lit.size) lit = true
  · rw [ite_eq_left he, ite_eq_left ((eqAt_spec a lit (by omega) (by omega)).mp he)]
  · rw [ite_eq_right he, ite_eq_right (fun hs => he ((eqAt_spec a lit (by omega) (by omega)).mpr hs))]

theorem dropPrefix_short (pre l : List UInt8) (h : l.length ≤ pre.length) :
    dropPrefix pre l = if l = pre then some [] else none := by
  unfold dropPrefix
  rw [List.take_of_length_le h, List.drop_of_length_le h]

theorem dropSuffix_slice (a lit : ByteArray) {lo hi : Nat} (h : lo + lit.size ≤ hi) (h' : hi ≤ a.size) :
    dropSuffix (bs lit) (slice a lo hi) =
      if eqAt a (hi - lit.size) hi lit then some (slice a lo (hi - lit.size)) else none := by
  have hlen := slice_length a (lo := lo) h'
  rw [dropSuffix, ← size_eq_length, hlen, slice_take a _ (by omega), slice_drop a _ (by omega),
    show lo + (hi - lo - lit.size) = hi - lit.size by omega]
  by_cases he : eqAt a (hi - lit.size) hi lit = true
  · rw [ite_eq_left he, ite_eq_left ⟨by omega, (eqAt_spec a lit (by omega) h').mp he⟩]
  · rw [ite_eq_right he, ite_eq_right (fun hs => he ((eqAt_spec a lit (by omega) h').mpr hs.2))]

theorem dropSuffix_short (suf l : List UInt8) (h : l.length ≤ suf.length) :
    dropSuffix suf l = if l = suf then some [] else none := by
  unfold dropSuffix
  by_cases hl : l.length = suf.length
  · rw [hl, Nat.sub_self, List.drop_zero, List.take_zero]
    by_cases he : l = suf
    · simp [he]
    · simp [he]
  · have hne : l ≠ suf := fun he => hl (by rw [he])
    rw [ite_eq_right (by omega), ite_eq_right hne]

theorem bs_size (b : ByteArray) : (bs b).length = b.size := (size_eq_length b).symm

/-- A range, clamped to the array, has the same bytes. -/
theorem slice_clamp (a : ByteArray) (lo hi : Nat) :
    slice a lo hi = slice a (min lo (min hi a.size)) (min hi a.size) := by
  apply List.ext_getElem?
  intro k
  simp only [slice, List.getElem?_take, List.getElem?_drop]
  have hs : a.data.toList.length = a.size := by simp
  by_cases hk : k < hi - lo
  · by_cases hk2 : k < min hi a.size - min lo (min hi a.size)
    · rw [ite_eq_left hk, ite_eq_left hk2, show min lo (min hi a.size) + k = lo + k by omega]
    · rw [ite_eq_left hk, ite_eq_right hk2, List.getElem?_eq_none (by omega)]
  · rw [ite_eq_right hk, ite_eq_right (by omega)]

/-- **The handler routes as the specification**: for a request whose path is the range
`[pathLo, pathHi)` of the input, `route` answers `Spec.route` of the path's bytes. -/
theorem route_spec (a : ByteArray) (r : Req) :
    (route a r).toSpec = Spec.route r.method (slice a r.pathLo r.pathHi) := by
  have hp7 : (bs pPostsSlash).length = 7 := rfl
  have hl5 : (bs pLike).length = 5 := rfl
  have hps : pPostsSlash.size = 7 := rfl
  have hlk : pLike.size = 5 := rfl
  rw [slice_clamp]
  unfold route
  simp only []
  generalize hhi : min r.pathHi a.size = hi
  generalize hlo : min r.pathLo hi = lo
  have h : lo ≤ hi := by omega
  have h' : hi ≤ a.size := by omega
  cases r.method with
  | other => rfl
  | get =>
    simp only [Spec.route]
    rw [show Spec.lit "/feed" = bs pFeed from rfl, show Spec.lit "/health" = bs pHealth from rfl,
      show Spec.lit "/posts/" = bs pPostsSlash from rfl]
    by_cases hf : eqAt a lo hi pFeed = true
    · rw [ite_eq_left hf, ite_eq_left ((eqAt_spec a pFeed h h').mp hf)]; rfl
    rw [ite_eq_right hf, ite_eq_right (fun hs => hf ((eqAt_spec a pFeed h h').mpr hs))]
    by_cases hh : eqAt a lo hi pHealth = true
    · rw [ite_eq_left hh, ite_eq_left ((eqAt_spec a pHealth h h').mp hh)]; rfl
    rw [ite_eq_right hh, ite_eq_right (fun hs => hh ((eqAt_spec a pHealth h h').mpr hs))]
    by_cases hlen : hi - lo > 7
    · rw [dropPrefix_slice a pPostsSlash (by rw [hps]; omega) h', hps]
      by_cases hpre : eqAt a lo (lo + 7) pPostsSlash = true
      · rw [ite_eq_left hpre]
        simp only [hlen, decide_true, hpre, Bool.true_and]
        have hseg : slice a (lo + 7) hi ≠ [] := by
          intro he; have := slice_length a (lo := lo + 7) h'; rw [he] at this; simp at this; omega
        by_cases hsl : Bytes.findByte a 0x2f (lo + 7) hi = hi
        · rw [ite_eq_left (by simpa using hsl), ite_eq_left ⟨hseg, (findByte_spec a 0x2f (by omega) h').mp hsl⟩]
          simp only [Route.toSpec]
          rw [parseId_spec a (by omega) h']
        · rw [ite_eq_right (by simpa using hsl), ite_eq_right (fun hc => hsl ((findByte_spec a 0x2f (by omega) h').mpr hc.2))]
          rfl
      · rw [ite_eq_right hpre]
        simp only [hpre, Bool.and_false]
        rfl
    · simp only [hlen, decide_false, Bool.false_and, Bool.false_eq_true, ↓reduceIte]
      rw [dropPrefix_short _ _ (by rw [slice_length a h', hp7]; omega)]
      split
      · rename_i seg hs
        have : seg = [] := by split at hs <;> simp_all
        subst this; rfl
      · rfl
  | post =>
    simp only [Spec.route]
    rw [show Spec.lit "/posts" = bs pPosts from rfl, show Spec.lit "/posts/" = bs pPostsSlash from rfl,
      show Spec.lit "/like" = bs pLike from rfl]
    by_cases hc : eqAt a lo hi pPosts = true
    · rw [ite_eq_left hc, ite_eq_left ((eqAt_spec a pPosts h h').mp hc)]; rfl
    rw [ite_eq_right hc, ite_eq_right (fun hs => hc ((eqAt_spec a pPosts h h').mpr hs))]
    by_cases hlen : hi - lo > 12
    · rw [dropPrefix_slice a pPostsSlash (by rw [hps]; omega) h', hps]
      by_cases hpre : eqAt a lo (lo + 7) pPostsSlash = true
      · rw [ite_eq_left hpre, Option.bind_some, dropSuffix_slice a pLike (by rw [hlk]; omega) h', hlk]
        by_cases hsuf : eqAt a (hi - 5) hi pLike = true
        · rw [ite_eq_left hsuf]
          dsimp only
          have hseg : slice a (lo + 7) (hi - 5) ≠ [] := by
            intro he; have := slice_length a (lo := lo + 7) (hi := hi - 5) (by omega); rw [he] at this; simp at this; omega
          by_cases hsl : Bytes.findByte a 0x2f (lo + 7) (hi - 5) = hi - 5
          · rw [ite_eq_left (by simp [hlen, hpre, hsuf, hsl]),
              ite_eq_left ⟨hseg, (findByte_spec a 0x2f (by omega) (by omega)).mp hsl⟩]
            simp only [Route.toSpec]
            rw [parseId_spec a (by omega) (by omega)]
          · rw [ite_eq_right (by simp [hsl]), ite_eq_right (fun hc => hsl ((findByte_spec a 0x2f (by omega) (by omega)).mpr hc.2))]
            rfl
        · rw [ite_eq_right hsuf, ite_eq_right (by simp [hsuf])]; rfl
      · rw [ite_eq_right hpre, Option.bind_none, ite_eq_right (by simp [hpre])]; rfl
    · rw [ite_eq_right (by simp [hlen])]
      by_cases h7 : hi - lo ≥ 7
      · rw [dropPrefix_slice a pPostsSlash (by rw [hps]; omega) h', hps]
        by_cases hpre : eqAt a lo (lo + 7) pPostsSlash = true
        · rw [ite_eq_left hpre, Option.bind_some, dropSuffix_short _ _ (by rw [slice_length a h', hl5]; omega)]
          split
          · rename_i seg hs
            have : seg = [] := by split at hs <;> simp_all
            subst this; rfl
          · rfl
        · rw [ite_eq_right hpre, Option.bind_none]; rfl
      · have hne : slice a lo hi ≠ bs pPostsSlash := by
          intro he; have := congrArg List.length he; rw [slice_length a h', hp7] at this; omega
        rw [dropPrefix_short _ _ (by rw [slice_length a h', hp7]; omega), ite_eq_right hne, Option.bind_none]
        rfl

/-- info: 'Feed.route_spec' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms route_spec

end Feed

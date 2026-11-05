import Feed.Proofs.HttpLines
import Feed.Proofs.Uri
import Feed.Proofs.Views

/-!
# Framing

`Http.parse` computes the specification's frame of a connection's unread input (`Spec.Http.frame`,
`Feed/Spec/Http.lean`) from every position in it: `Http.parse_view`. The theorems are about the
Lean definition of `Http.parse`, `finish` of `scan`; the server runs its C version
(`runtime/leaves.c`), which the self-test compares with that definition.

Of the specification alone: a connection's input has exactly one frame (`Spec.Http.frames_total`,
`Spec.Http.frames_unique`), and two requests at the start of the same bytes are the same request
(`Spec.Http.isRequest_unique`); a frame other than a wait is also the frame of every longer input
(`Spec.Http.frame_append`), so the answer does not depend on how the input was split into reads;
and the server waits on fewer than `maxHead + 4 + maxBody` bytes (`Spec.Http.waiting_bounded`:
32,772, where the transport closes a connection whose unanswered input passes 65,536 bytes,
runtime/uring.c:44).

Of the parser: it reads the input as `Spec.Http.Frames` does (`Http.parse_frames`), so it computes
the frame; a request it returns is the specification's request of the bytes from `pos` to its
`next`, where its content ends (`Http.parse_sound`); it returns every request that starts at `pos`
(`Http.parse_complete`), and it answers malformed input exactly when the specification does, with
the same status (`Http.parse_bad_iff`). What its byte scan returns is proved in
`Feed/Proofs/HttpLines.lean` (`Http.scan_spec`) and what the deciders of the Host value and the
request-target return in `Feed/Proofs/Uri.lean` (`Http.hostOk_iff`, `Http.target_spec`); proved here
are `finish` (`Http.finish_head`) and the frame. `Http.frame_vectors` frames, by evaluation of
`Http.parse`, 26 of the inputs on which the parser of version 011a111 departed from the RFCs (the
other two are left to `Spec.Http.frame_append` and `Spec.Http.TargetTooLong`, below). Also proved
here: the parser's limits are the specification's.
-/
namespace Feed

theorem Http.maxHead_eq : Http.maxHead = Spec.Http.maxHead := rfl
theorem Http.maxTarget_eq : Http.maxTarget = Spec.Http.maxTarget := rfl
theorem Http.maxBody_eq : Http.maxBody = Spec.Http.maxBody := rfl

open Spec

/-! ## Input that grows -/

/-- The first CR LF CR LF stays the first when more bytes come. -/
theorem crlf2Idx_append {y : List UInt8} {i : Nat} (t : List UInt8) (h : crlf2Idx y = some i) :
    crlf2Idx (y ++ t) = some i := by
  have e := crlf2Idx_take (y ++ t) y.length
  rw [List.take_left, h] at e
  exact (Option.filter_eq_some_iff.mp e.symm).1

/-- A first CR LF CR LF within the first bytes is theirs. -/
theorem crlf2Idx_of_append {y t : List UInt8} {i : Nat} (h : crlf2Idx (y ++ t) = some i) (hi : i + 4 ≤ y.length) :
    crlf2Idx y = some i := by
  have e := crlf2Idx_take (y ++ t) y.length
  rw [List.take_left, h, Option.filter_some, ite_eq_left (by simpa using hi)] at e
  exact e

namespace Spec.Http

/-- The empty lines are counted the same when more bytes come, once two bytes after them have
arrived (or two after those counted in the longer input). -/
theorem lead_append : ∀ (s t : Bytes), 2 * lead s + 2 ≤ s.length ∨ 2 * lead (s ++ t) + 2 ≤ s.length →
    lead (s ++ t) = lead s
  | [], _, h => by simp at h
  | [_], _, h => by simp at h
  | a :: b :: s, t, h => by
    by_cases hab : a = 0x0d ∧ b = 0x0a
    · simp only [List.cons_append, lead, hab, and_self, ↓reduceIte, List.length_cons] at h ⊢
      rw [lead_append s t (by omega)]
    · simp only [List.cons_append, lead, hab, ↓reduceIte]

/-- A head's length counts its empty lines and its CR LF CR LF, and no more than the input's bytes. -/
theorem headLen_le {s : Bytes} {n : Nat} (h : headLen s = some n) : 2 * lead s + 4 ≤ n ∧ n ≤ s.length := by
  rw [headLen_eq] at h
  cases hc : crlf2Idx (s.drop (2 * lead s)) with
  | none => rw [hc] at h; simp at h
  | some i =>
    rw [hc] at h
    simp only [Option.map_some, Option.some.injEq] at h
    have h1 := (crlf2Idx_some hc).2
    rw [List.length_drop] at h1
    have h2 := lead_le s
    omega

/-- A head that has ended ends at the same place when more bytes come. -/
theorem headLen_append {s : Bytes} {n : Nat} (t : Bytes) (h : headLen s = some n) : headLen (s ++ t) = some n := by
  obtain ⟨h1, h2⟩ := headLen_le h
  have hl : lead (s ++ t) = lead s := lead_append s t (.inl (by omega))
  rw [headLen_eq] at h ⊢
  rw [hl, List.drop_append_of_le_length (by omega)]
  cases hc : crlf2Idx (s.drop (2 * lead s)) with
  | none => rw [hc] at h; simp at h
  | some i => rw [hc] at h; rw [crlf2Idx_append t hc]; exact h

/-- A head of a longer input that ends within the first bytes ends there in those bytes. -/
theorem headLen_of_append {s t : Bytes} {n : Nat} (h : headLen (s ++ t) = some n) (hn : n ≤ s.length) :
    headLen s = some n := by
  obtain ⟨h1, -⟩ := headLen_le h
  have hl : lead (s ++ t) = lead s := lead_append s t (.inr (by omega))
  rw [headLen_eq] at h ⊢
  rw [hl, List.drop_append_of_le_length (by omega)] at h
  rw [hl] at h1
  cases hc : crlf2Idx (s.drop (2 * lead s) ++ t) with
  | none => rw [hc] at h; simp at h
  | some i =>
    rw [hc] at h
    simp only [Option.map_some, Option.some.injEq] at h
    rw [crlf2Idx_of_append hc (by rw [List.length_drop]; omega)]
    exact congrArg some h

/-- A request-target that is too long stays too long when more bytes come. -/
theorem targetTooLong_append {s : Bytes} (h : TargetTooLong s) (t : Bytes) : TargetTooLong (s ++ t) := by
  obtain ⟨m, t', rest, hs, hm, hl, ht, hb⟩ := h
  have hlen := congrArg List.length hs
  simp only [List.length_drop, List.length_append, List.length_cons, List.length_nil] at hlen
  have hm0 : 0 < m.length := List.length_pos_iff.mpr hm.1
  have hl' : lead (s ++ t) = lead s := lead_append s t (.inl (by omega))
  refine ⟨m, t', rest ++ t, ?_, hm, hl, ht, by rw [hl']; exact hb⟩
  rw [hl', List.drop_append_of_le_length (by omega), hs]
  simp only [List.append_assoc]

/-- The method, SP and target bytes that make a longer input's target too long make the first
bytes' target too long, if those bytes hold them. -/
theorem targetTooLong_of_append_le {s t m t' rest : Bytes}
    (e : (s ++ t).drop (2 * lead (s ++ t)) = m ++ [0x20] ++ t' ++ rest) (hm : IsToken m)
    (hl : t'.length = maxTarget + 1) (ht : ∀ c ∈ t', c ≠ 0x20 ∧ c ≠ 0x0d ∧ c ≠ 0x0a)
    (hb : 2 * lead (s ++ t) + m.length + 1 + t'.length ≤ maxHead + 4)
    (hs : 2 * lead (s ++ t) + m.length + 1 + t'.length ≤ s.length) : TargetTooLong s := by
  have hm0 : 0 < m.length := List.length_pos_iff.mpr hm.1
  have hl' : lead (s ++ t) = lead s := lead_append s t (.inr (by omega))
  rw [hl'] at e hb hs
  rw [List.drop_append_of_le_length (by omega)] at e
  have hy : (s.drop (2 * lead s)).length = s.length - 2 * lead s := List.length_drop
  have hPl : (m ++ [0x20] ++ t').length = m.length + 1 + t'.length := by simp; omega
  have e1 : (s.drop (2 * lead s)).take (m ++ [0x20] ++ t').length = m ++ [0x20] ++ t' := by
    have := congrArg (List.take (m ++ [0x20] ++ t').length) e
    rwa [List.take_append_of_le_length (by omega), List.take_left] at this
  refine ⟨m, t', (s.drop (2 * lead s)).drop (m ++ [0x20] ++ t').length, ?_, hm, hl, ht, hb⟩
  conv => lhs; rw [← List.take_append_drop (m ++ [0x20] ++ t').length (s.drop (2 * lead s)), e1]

/-- So with the first `maxHead + 4` bytes all in, more bytes make no target too long. -/
theorem targetTooLong_of_append_long {s t : Bytes} (h : TargetTooLong (s ++ t)) (hb : maxHead + 4 ≤ s.length) :
    TargetTooLong s := by
  obtain ⟨m, t', rest, e, hm, hl, ht, hb'⟩ := h
  exact targetTooLong_of_append_le e hm hl ht hb' (by omega)

/-- Nor once a head has ended: the bytes of the method, the SP and the target hold no CR, so they
come before the head's end. -/
theorem targetTooLong_of_append_head {s t : Bytes} {n : Nat} (h : TargetTooLong (s ++ t)) (hn : headLen s = some n) :
    TargetTooLong s := by
  obtain ⟨m, t', rest, e, hm, hl, ht, hb⟩ := h
  refine targetTooLong_of_append_le e hm hl ht hb ?_
  obtain ⟨h1, h2⟩ := headLen_le hn
  have hl' : lead (s ++ t) = lead s := lead_append s t (.inl (by omega))
  rw [hl'] at e ⊢
  rw [List.drop_append_of_le_length (by omega)] at e
  rw [headLen_eq] at hn
  cases hc : crlf2Idx (s.drop (2 * lead s)) with
  | none => rw [hc] at hn; simp at hn
  | some i =>
    obtain ⟨hw, hi⟩ := crlf2Idx_some hc
    have hcr : (s.drop (2 * lead s))[i]? = some 0x0d := by
      have := congrArg (·[0]?) hw
      simp only [List.getElem?_take, List.getElem?_drop] at this
      simpa using this
    have hP : ∀ c ∈ m ++ [0x20] ++ t', c ≠ 0x0d := by
      intro c hc'
      simp only [List.mem_append, List.mem_singleton] at hc'
      rcases hc' with (hc' | rfl) | hc'
      · intro he; rw [he] at hc'; exact absurd (hm.2 _ hc') (by decide)
      · decide
      · exact (ht c hc').2.1
    refine Nat.le_of_not_lt fun hlt => ?_
    have hy : (s.drop (2 * lead s)).length = s.length - 2 * lead s := List.length_drop
    have hi' : i < (m ++ [0x20] ++ t').length := by simp; omega
    have e2 := congrArg (·[i]?) e
    rw [List.getElem?_append_left (by omega), hcr, List.getElem?_append_left hi'] at e2
    exact hP _ (List.mem_of_getElem? e2.symm) rfl

/-! ## One frame per input -/

/-- A valid head has one content length. -/
theorem validHead_unique {h : Bytes} {len len' : Nat} (v : ValidHead h len) (v' : ValidHead h len') :
    len = len' := by
  obtain ⟨H, _, hH, hok⟩ := v
  obtain ⟨H', _, hH', hok'⟩ := v'
  cases isHead_unique hH hH'
  exact Option.some.inj (hok.length.symm.trans hok'.length)

/-- What a request at the start of the input says of the input: its head ends where the input's
first CR LF CR LF after the empty lines does, within `maxHead + 4` bytes, and is valid with the
request's content length. -/
theorem request_head {s : Bytes} {q : Request} {n : Nat} (hn : n ≤ s.length) (h : IsRequest (s.take n) q) :
    ∃ k, headLen s = some k ∧ k ≤ maxHead + 4 ∧ ValidHead (s.take k) q.body.length ∧
      q.body.length ≤ maxBody ∧ n = k + q.body.length := by
  obtain ⟨hd, H, path, e, hH, hhl, hok, hbl, -⟩ := h
  have hs : s = hd ++ (q.body ++ s.drop n) := by rw [← List.append_assoc, ← e, List.take_append_drop]
  have hlen : n = hd.length + q.body.length := by
    have := congrArg List.length e
    rw [List.length_take, Nat.min_eq_left hn, List.length_append] at this
    exact this
  have htk : s.take hd.length = hd := by rw [hs, List.take_left]
  refine ⟨hd.length, ?_, hhl, ⟨H, path, by rw [htk]; exact hH, hok⟩, hbl, hlen⟩
  rw [hs]
  exact headLen_head hH _

theorem malformed_unique {s : Bytes} {st st' : Nat} (h : Malformed s st) (h' : Malformed s st') : st = st' := by
  cases h with
  | uriTooLong hT =>
    cases h' with
    | uriTooLong => rfl
    | headTooLarge hT' => exact absurd hT hT'
    | invalid hT' => exact absurd hT hT'
    | tooLarge _ _ hv => exact absurd hT (validHead_not_targetTooLong hv)
  | headTooLarge hT hall hl =>
    cases h' with
    | uriTooLong hT' => exact absurd hT' hT
    | headTooLarge => rfl
    | invalid _ hh hn => exact absurd (hall _ hh) (by omega)
    | tooLarge hh hn => exact absurd (hall _ hh) (by omega)
  | invalid hT hh hn hnv =>
    cases h' with
    | uriTooLong hT' => exact absurd hT' hT
    | headTooLarge _ hall => exact absurd (hall _ hh) (by omega)
    | invalid => rfl
    | tooLarge hh' _ hv =>
      rw [hh] at hh'
      cases hh'
      exact absurd ⟨_, hv⟩ hnv
  | tooLarge hh hn hv hb =>
    cases h' with
    | uriTooLong hT' => exact absurd hT' (validHead_not_targetTooLong hv)
    | headTooLarge _ hall => exact absurd (hall _ hh) (by omega)
    | invalid _ hh' _ hnv =>
      rw [hh] at hh'
      cases hh'
      exact absurd ⟨_, hv⟩ hnv
    | tooLarge => rfl

theorem malformed_not_undecided {s : Bytes} {st : Nat} (h : Malformed s st) (h' : Undecided s) : False := by
  cases h with
  | uriTooLong hT =>
    cases h' with
    | head hT' => exact hT' hT
    | body _ _ hv => exact validHead_not_targetTooLong hv hT
  | headTooLarge _ hall hl =>
    cases h' with
    | head _ _ hl' => omega
    | body hh hn => exact absurd (hall _ hh) (by omega)
  | invalid _ hh _ hnv =>
    cases h' with
    | head _ hh' => rw [hh] at hh'; cases hh'
    | body hh' _ hv =>
      rw [hh] at hh'
      cases hh'
      exact hnv ⟨_, hv⟩
  | tooLarge hh _ hv hb =>
    cases h' with
    | head _ hh' => rw [hh] at hh'; cases hh'
    | body hh' _ hv' hb' =>
      rw [hh] at hh'
      cases hh'
      have := validHead_unique hv hv'
      omega

theorem request_not_malformed {s : Bytes} {q : Request} {n st : Nat} (hn : n ≤ s.length)
    (h : IsRequest (s.take n) q) (h' : Malformed s st) : False := by
  obtain ⟨k, hk, hkl, hv, hb, -⟩ := request_head hn h
  cases h' with
  | uriTooLong hT => exact validHead_not_targetTooLong hv hT
  | headTooLarge _ hall => exact absurd (hall _ hk) (by omega)
  | invalid _ hh _ hnv =>
    rw [hk] at hh
    cases hh
    exact hnv ⟨_, hv⟩
  | tooLarge hh _ hv' hb' =>
    rw [hk] at hh
    cases hh
    have := validHead_unique hv hv'
    omega

theorem request_not_undecided {s : Bytes} {q : Request} {n : Nat} (hn : n ≤ s.length)
    (h : IsRequest (s.take n) q) (h' : Undecided s) : False := by
  obtain ⟨k, hk, hkl, hv, hb, rfl⟩ := request_head hn h
  cases h' with
  | head _ hh => rw [hk] at hh; cases hh
  | body hh _ hv' _ hl =>
    rw [hk] at hh
    cases hh
    have := validHead_unique hv hv'
    omega

/-- **Two requests at the start of the same bytes are the same request**, of the same bytes: the
head ends at the first CR LF CR LF after the empty lines, has its parts in one way only, and fixes
the content's length. -/
theorem isRequest_unique {s t u : List UInt8} {q q' : Request} (hs : IsRequest s q) (ht : IsRequest t q')
    (h₁ : s <+: u) (h₂ : t <+: u) : s = t ∧ q = q' := by
  obtain ⟨hd, H, path, rfl, hH, -, hok, -, hm, hh, hp, ha, hc⟩ := hs
  obtain ⟨hd', H', path', rfl, hH', -, hok', -, hm', hh', hp', ha', hc'⟩ := ht
  obtain ⟨r, rfl⟩ := h₁
  obtain ⟨r', hr⟩ := h₂
  simp only [List.append_assoc] at hr
  have e1 := headLen_head hH (q.body ++ r)
  have e2 := headLen_head hH' (q'.body ++ r')
  rw [hr, e1] at e2
  obtain ⟨rfl, hr2⟩ := List.append_inj hr (Option.some.inj e2).symm
  cases isHead_unique hH hH'
  have hbl : q'.body.length = q.body.length := Option.some.inj (hok'.length.symm.trans hok.length)
  obtain ⟨hb, -⟩ := List.append_inj hr2 hbl
  cases targetPath_unique hok.target hok'.target
  refine ⟨by rw [hb], ?_⟩
  cases q
  cases q'
  simp only at hm hh hp ha hc hm' hh' hp' ha' hc' hb
  rw [hm, hh, hp, ha, hc, hm', hh', hp', ha', hc', hb]

/-- info: 'Feed.Spec.Http.isRequest_unique' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms isRequest_unique

/-- **An input has at most one frame**: a request, malformed input and a wait exclude each other,
and each fixes what it says (the request and its length, the status). -/
theorem frames_unique {s : List UInt8} {f g : Frame} (hf : Frames s f) (hg : Frames s g) : f = g := by
  cases hf with
  | ok hn hq =>
    cases hg with
    | ok hn' hq' =>
      obtain ⟨e1, rfl⟩ := isRequest_unique hq hq' (List.take_prefix _ _) (List.take_prefix _ _)
      have := congrArg List.length e1
      rw [List.length_take, List.length_take, Nat.min_eq_left hn, Nat.min_eq_left hn'] at this
      rw [this]
    | bad hm => exact (request_not_malformed hn hq hm).elim
    | wait hu => exact (request_not_undecided hn hq hu).elim
  | bad hm =>
    cases hg with
    | ok hn' hq' => exact (request_not_malformed hn' hq' hm).elim
    | bad hm' => rw [malformed_unique hm hm']
    | wait hu => exact (malformed_not_undecided hm hu).elim
  | wait hu =>
    cases hg with
    | ok hn' hq' => exact (request_not_undecided hn' hq' hu).elim
    | bad hm => exact (malformed_not_undecided hm hu).elim
    | wait => rfl

/-- info: 'Feed.Spec.Http.frames_unique' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms frames_unique

/-- **Every input has a frame**: 414, else 431 or a wait while no head has ended within the first
`maxHead + 4` bytes, else 400 for a head that is not valid, else 413, a wait for the content, or
the request. -/
theorem frames_total (s : List UInt8) : ∃ f, Frames s f := by
  by_cases hT : TargetTooLong s
  · exact ⟨_, .bad (.uriTooLong hT)⟩
  cases hh : headLen s with
  | none =>
    by_cases hl : s.length < maxHead + 4
    · exact ⟨_, .wait (.head hT hh hl)⟩
    · exact ⟨_, .bad (.headTooLarge hT (fun _ h => by rw [hh] at h; cases h) (by omega))⟩
  | some n =>
    have hnl := (headLen_le hh).2
    by_cases hn : n ≤ maxHead + 4
    · by_cases hv : ∃ len, ValidHead (s.take n) len
      · obtain ⟨len, hv⟩ := hv
        by_cases hb : maxBody < len
        · exact ⟨_, .bad (.tooLarge hh hn hv hb)⟩
        · by_cases hs : s.length < n + len
          · exact ⟨_, .wait (.body hh hn hv (by omega) hs)⟩
          · obtain ⟨H, path, hH, hok⟩ := hv
            have hbl : ((s.drop n).take len).length = len := by
              rw [List.length_take, List.length_drop]; omega
            refine ⟨.ok ⟨methodOf H.method, Decidable.decide (H.method = lit "HEAD"), path,
              (values H.fs (lit "authorization")).head?, (s.drop n).take len, closes H.minor H.fs⟩ (n + len),
              .ok (by omega) ⟨s.take n, H, path, List.take_add, hH, ?_, ?_, ?_, rfl, rfl, rfl, rfl, rfl⟩⟩
            · rw [List.length_take]; omega
            · dsimp only; rw [hbl]; exact hok
            · dsimp only; rw [hbl]; omega
      · exact ⟨_, .bad (.invalid hT hh hn hv)⟩
    · exact ⟨_, .bad (.headTooLarge hT (fun n' h => by rw [hh] at h; cases h; omega) (by omega))⟩

/-- info: 'Feed.Spec.Http.frames_total' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms frames_total

/-- The frame of an input is the one it has. -/
theorem frame_eq {s : Bytes} {f : Frame} (h : Frames s f) : frame s = f := by
  unfold frame
  rw [dite_eq_left ⟨f, h⟩]
  exact frames_unique (Classical.choose_spec (⟨f, h⟩ : ∃ f, Frames s f)) h

/-- `frame` gives every input its frame (`frames_total`). -/
theorem frames_frame (s : Bytes) : Frames s (frame s) := by
  obtain ⟨f, h⟩ := frames_total s
  rw [frame_eq h]
  exact h

/-! ## Reads split anywhere -/

/-- Malformed input stays malformed, with the same status, when more bytes come. -/
theorem malformed_append {s : Bytes} {st : Nat} (t : Bytes) (h : Malformed s st) : Malformed (s ++ t) st := by
  cases h with
  | uriTooLong hT => exact .uriTooLong (targetTooLong_append hT t)
  | headTooLarge hT hall hl =>
    refine .headTooLarge (fun h => hT (targetTooLong_of_append_long h hl)) (fun n hn => ?_)
      (by rw [List.length_append]; omega)
    refine Nat.lt_of_not_le fun hle => ?_
    exact absurd (hall n (headLen_of_append hn (by omega))) (by omega)
  | invalid hT hh hn hnv =>
    have hk := (headLen_le hh).2
    refine .invalid (fun h => hT (targetTooLong_of_append_head h hh)) (headLen_append t hh) hn ?_
    rwa [List.take_append_of_le_length hk]
  | tooLarge hh hn hv hb =>
    have hk := (headLen_le hh).2
    refine .tooLarge (headLen_append t hh) hn ?_ hb
    rwa [List.take_append_of_le_length hk]

/-- **The frame does not depend on how the input was split into reads**: a frame other than a wait
is also the frame of every longer input. -/
theorem frame_append {s : List UInt8} (t : List UInt8) (h : frame s ≠ .incomplete) :
    frame (s ++ t) = frame s := by
  apply frame_eq
  have hf := frames_frame s
  revert h hf
  generalize frame s = f
  intro h hf
  cases hf with
  | ok hn hq => exact .ok (by rw [List.length_append]; omega) (by rwa [List.take_append_of_le_length hn])
  | bad hm => exact .bad (malformed_append t hm)
  | wait => exact absurd rfl h

/-- info: 'Feed.Spec.Http.frame_append' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms frame_append

/-- **The server waits on fewer than `maxHead + 4 + maxBody` bytes**: a head that has not ended
within the first `maxHead + 4` bytes, or a valid head's content of at most `maxBody` bytes. -/
theorem waiting_bounded {s : List UInt8} (h : frame s = .incomplete) :
    s.length < maxHead + 4 + maxBody := by
  have hf := frames_frame s
  rw [h] at hf
  cases hf with
  | wait hu =>
    cases hu with
    | head _ _ hl => omega
    | body _ hn _ hb hl => omega

/-- info: 'Feed.Spec.Http.waiting_bounded' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms waiting_bounded

end Spec.Http

/-! ## The parser -/

/-- What `finish` answers for a head that the byte scan read: 400 when the head is not valid (a
Transfer-Encoding line, Content-Length values that are not one number, more than one Authorization
line, the Host lines, the request-target), 413 when its content is too long, a wait for the
content, or the request. -/
theorem Http.finish_head (a : ByteArray) {pos i0 m t minor he : Nat} {f : Http.Fields} (hp : pos ≤ a.size)
    (hsc : Http.scan a pos = .head i0 m t minor he f) :
    match Http.finish a (.head i0 m t minor he f) with
    | .incomplete => Spec.Http.Undecided ((bs a).drop pos)
    | .bad st => Spec.Http.Malformed ((bs a).drop pos) st
    | .ok r => pos < r.next ∧ r.next ≤ a.size ∧ r.bodyHi = r.next ∧
        Spec.Http.IsRequest (slice a pos r.next) (r.toRequest a) := by
  have hs := Http.scan_spec a hp
  rw [hsc] at hs
  obtain ⟨hnT, hi0, hm, hmt, htle, h9, hhe, hlen, hn, fls, fs, hH, hS⟩ := hs
  have hta : t ≤ a.size := by omega
  have hmb : Http.maxBody = Spec.Http.maxBody := rfl
  -- a head of these bytes that the specification reads otherwise is not valid: 400
  have h400 : (∀ path len, ¬ Spec.Http.HeadOk ⟨Spec.Http.lead ((bs a).drop pos), slice a i0 (t + 9),
      slice a i0 m, slice a (m + 1) t, 1, minor, fls, fs⟩ path len) → Spec.Http.Malformed ((bs a).drop pos) 400 := by
    intro hno
    refine .invalid hnT hlen hn ?_
    rintro ⟨len, H, path, hH', hok⟩
    cases Spec.Http.isHead_unique hH hH'
    exact hno path len hok
  generalize hF : Http.finish a (.head i0 m t minor he f) = F
  simp only [Http.finish] at hF
  generalize hc1 : (f.coding || f.lenBad || Decidable.decide (f.auths > 1)) = c1 at hF
  generalize hc2 : (if (f.hosts == 0) = true then minor == 0 else f.hosts == 1 && Http.hostOk a f.hostLo f.hostHi) = c2
    at hF
  generalize hLd : (if f.hasLen = true then Http.lengthOf a f.lenLo f.lenHi else 0) = L at hF
  cases c1
  case true =>
    -- a transfer coding, Content-Length values that are not one number, or more than one Authorization
    simp only [↓reduceIte] at hF
    subst hF
    refine h400 fun path len hok => ?_
    have h1 := hS.coding_false.mpr hok.noCoding
    have h2 := hS.lenBad_iff.mpr ⟨len, hok.length⟩
    have h3 := hS.auths_le.mp hok.oneAuth
    simp only [h1, h2, Bool.or_false, Bool.false_or, decide_eq_true_eq] at hc1
    omega
  simp only [Bool.or_eq_false_iff, decide_eq_false_iff_not] at hc1
  obtain ⟨⟨hcod, hlb⟩, hau⟩ := hc1
  have hhost := hS.host_iff minor (ok := Http.hostOk a f.hostLo f.hostHi)
    (P := fun v => ∃ host, Spec.Http.HostPort v host) (Http.hostOk_iff a hS.host_le.1 hS.host_le.2)
  cases c2
  case false =>
    -- the Host lines
    simp only [Bool.false_eq_true, ↓reduceIte, Bool.not_false] at hF
    subst hF
    refine h400 fun path len hok => ?_
    have := hhost.mpr hok.host
    rw [hc2] at this
    exact absurd this (by decide)
  simp only [Bool.false_eq_true, ↓reduceIte, Bool.not_true] at hF
  have hts := Http.target_spec a (lo := m + 1) (hi := t) (by omega) hta
  cases htg : Http.target a (m + 1) t with
  | none =>
    -- no request-target
    rw [htg] at hF hts
    subst hF
    exact h400 fun path len hok => hts path hok.target
  | some p =>
    obtain ⟨plo, phi⟩ := p
    rw [htg] at hF hts
    simp only at hF
    obtain ⟨hp1, hp2, hp3, htp⟩ := hts
    obtain ⟨n0, hcl, hL⟩ := hS.length_eq hlb
    rw [hLd] at hL
    -- the head is valid, with the content length n0
    have hok : Spec.Http.HeadOk ⟨Spec.Http.lead ((bs a).drop pos), slice a i0 (t + 9), slice a i0 m,
        slice a (m + 1) t, 1, minor, fls, fs⟩ (slice a plo phi) n0 :=
      { version := rfl
        target := htp
        short := by show (slice a (m + 1) t).length ≤ _; rw [slice_length a hta]; omega
        host := hhost.mp hc2
        noCoding := hS.coding_false.mp hcod
        oneAuth := hS.auths_le.mpr (by omega)
        length := hcl }
    have hv : Spec.Http.ValidHead (((bs a).drop pos).take (he + 4 - pos)) n0 := ⟨_, _, hH, hok⟩
    by_cases h413 : L > Http.maxBody
    · -- the content is too long
      rw [ite_eq_left h413] at hF
      subst hF
      exact .tooLarge hlen hn hv (by omega)
    rw [ite_eq_right h413] at hF
    have hLn : L = n0 := by omega
    subst hLn
    by_cases hwait : he + 4 + L > a.size
    · -- the content is not all there
      rw [ite_eq_left hwait] at hF
      subst hF
      refine .body hlen hn hv (by omega) ?_
      rw [List.length_drop, ← size_eq_length]
      omega
    rw [ite_eq_right hwait] at hF
    subst hF
    dsimp only
    refine ⟨by omega, by omega, rfl, ?_⟩
    -- the request: the head, then the content
    have htake : ((bs a).drop pos).take (he + 4 - pos) = slice a pos (he + 4) := by
      rw [take_drop_eq_slice, show pos + (he + 4 - pos) = he + 4 by omega]
    rw [htake] at hH
    have hbl : (slice a (he + 4) (he + 4 + L)).length = L := by rw [slice_length a (by omega)]; omega
    refine ⟨slice a pos (he + 4), _, slice a plo phi, slice_append a (by omega) (by omega), hH,
      by rw [slice_length a (by omega)]; omega, by rw [Http.Req.toRequest]; dsimp only; rw [hbl]; exact hok,
      by rw [Http.Req.toRequest]; dsimp only; rw [hbl]; omega, ?_, ?_, rfl, ?_, ?_⟩
    · exact Http.method_eq a (by omega) (by omega)
    · show Http.eqAt a i0 m Http.mHead = _
      rw [Http.eqAt_lit_iff a (by omega) (by omega)]
      rfl
    · show (if (f.auths == 1) = true then some (slice a f.authLo f.authHi) else none) = _
      rw [hS.auth_head (by omega)]
    · show (f.close || (minor == 0 && !f.keepAlive)) = _
      rw [hS.closes_eq]

/-- info: 'Feed.Http.finish_head' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms Http.finish_head

/-- **`Http.parse` reads the input as `Feed/Spec/Http.lean` frames it**: its result, read as a
frame, is a frame of the input from `pos`. -/
theorem Http.parse_frames (a : ByteArray) (pos : Nat) (hp : pos ≤ a.size) :
    Spec.Http.Frames ((bs a).drop pos) ((Http.parse a pos).view a pos) := by
  have hs := Http.scan_spec a hp
  unfold Http.parse
  cases hsc : Http.scan a pos with
  | incomplete =>
    rw [hsc] at hs
    exact .wait (.head hs.1 hs.2.1 hs.2.2)
  | bad st =>
    rw [hsc] at hs
    show Spec.Http.Frames _ (.bad st)
    rcases hs with ⟨rfl, hT⟩ | ⟨rfl, hT, hall, hl⟩ | ⟨rfl, hT, n, hh, hn, hmaj⟩
    · exact .bad (.uriTooLong hT)
    · exact .bad (.headTooLarge hT hall hl)
    · exact .bad (.invalid hT hh hn fun ⟨_, H, _, hH, hok⟩ => hmaj H hH hok.version)
  | head i0 m t minor he f =>
    have hF := Http.finish_head a hp hsc
    revert hF
    cases Http.finish a (.head i0 m t minor he f) with
    | incomplete => exact fun hF => .wait hF
    | bad st => exact fun hF => .bad hF
    | ok r =>
      rintro ⟨h1, h2, -, h4⟩
      refine .ok (by rw [List.length_drop, ← size_eq_length]; omega) ?_
      rw [take_drop_eq_slice, show pos + (r.next - pos) = r.next by omega]
      exact h4

/-- info: 'Feed.Http.parse_frames' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms Http.parse_frames

/-- **`Http.parse` computes the specification's frame** of the input from `pos`. -/
theorem Http.parse_view (a : ByteArray) (pos : Nat) (hpos : pos ≤ a.size) :
    (Http.parse a pos).view a pos = Spec.Http.frame ((bs a).drop pos) :=
  (Spec.Http.frame_eq (Http.parse_frames a pos hpos)).symm

/-- info: 'Feed.Http.parse_view' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms Http.parse_view

/-- **A request that `Http.parse` returns is the specification's request of its bytes**, from
`pos` to `next`, where its content ends. -/
theorem Http.parse_sound {a : ByteArray} {pos : Nat} {r : Http.Req} (hp : pos ≤ a.size)
    (h : Http.parse a pos = .ok r) :
    pos ≤ r.next ∧ r.next ≤ a.size ∧ r.bodyHi = r.next ∧
      Spec.Http.IsRequest (slice a pos r.next) (r.toRequest a) := by
  unfold Http.parse at h
  cases hsc : Http.scan a pos with
  | incomplete => rw [hsc] at h; simp [Http.finish] at h
  | bad st => rw [hsc] at h; simp [Http.finish] at h
  | head i0 m t minor he f =>
    rw [hsc] at h
    have hF := Http.finish_head a hp hsc
    rw [h] at hF
    obtain ⟨h1, h2, h3, h4⟩ := hF
    exact ⟨by omega, h2, h3, h4⟩

/-- info: 'Feed.Http.parse_sound' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms Http.parse_sound

/-- **`Http.parse` returns every request that starts at `pos`.** -/
theorem Http.parse_complete {a : ByteArray} {pos n : Nat} {q : Spec.Http.Request} (hn : pos + n ≤ a.size)
    (h : Spec.Http.IsRequest (slice a pos (pos + n)) q) :
    ∃ r, Http.parse a pos = .ok r ∧ r.next = pos + n ∧ r.toRequest a = q := by
  have hp : pos ≤ a.size := by omega
  have hf : Spec.Http.Frames ((bs a).drop pos) (.ok q n) :=
    .ok (by rw [List.length_drop, ← size_eq_length]; omega) (by rw [take_drop_eq_slice]; exact h)
  have e := Spec.Http.frames_unique (Http.parse_frames a pos hp) hf
  cases hr : Http.parse a pos with
  | incomplete => rw [hr] at e; cases e
  | bad st => rw [hr] at e; cases e
  | ok r =>
    rw [hr] at e
    simp only [Http.Parse.view, Spec.Http.Frame.ok.injEq] at e
    obtain ⟨h1, h2⟩ := e
    have := (Http.parse_sound hp hr).1
    exact ⟨r, rfl, by omega, h1⟩

/-- info: 'Feed.Http.parse_complete' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms Http.parse_complete

/-- **`Http.parse` answers malformed input exactly when the specification does**, with the same
status. -/
theorem Http.parse_bad_iff (a : ByteArray) (pos st : Nat) (hp : pos ≤ a.size) :
    Http.parse a pos = .bad st ↔ Spec.Http.Malformed ((bs a).drop pos) st := by
  constructor
  · intro h
    have := Http.parse_frames a pos hp
    rw [h] at this
    cases this with
    | bad hm => exact hm
  · intro hm
    have e := Spec.Http.frames_unique (Http.parse_frames a pos hp) (.bad hm)
    cases hr : Http.parse a pos with
    | incomplete => rw [hr] at e; cases e
    | bad st' => rw [hr] at e; cases e; rfl
    | ok r => rw [hr] at e; cases e

/-- info: 'Feed.Http.parse_bad_iff' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms Http.parse_bad_iff

/-! ## Examples

The inputs on which the parser of version 011a111 departed from the RFCs, framed through
`Http.parse_view` and the kernel's evaluation of `Http.parse` on the literals. Two of them are left
out, since the kernel would evaluate the parser on all their bytes: a head of 16,388 bytes read in
two parts that split its CR LF CR LF, where `Spec.Http.frame_append` says that the answer does not
depend on how the input was split, and a target of 17,000 bytes, which `Spec.Http.TargetTooLong`
makes a 414. -/

namespace Http.Vectors

-- for `decide` on frames
deriving instance DecidableEq for Http.Method
deriving instance DecidableEq for Spec.Http.Request
deriving instance DecidableEq for Spec.Http.Frame

/-- The frame of a literal, from what `Http.parse` returns on its bytes. -/
theorem frame_lit {s : String} {f : Spec.Http.Frame} (h : (Http.parse s.toUTF8 0).view s.toUTF8 0 = f) :
    Spec.Http.frame (Spec.lit s) = f := by
  rw [← h, Http.parse_view _ 0 (Nat.zero_le _)]
  rfl

end Http.Vectors

open Http.Vectors in
/-- 26 of the inputs on which the parser of version 011a111 departed from the RFCs, as the
specification frames them: no Host in HTTP/1.1, two Host lines and a Host value that is none;
whitespace before a field's colon, obs-fold, a bare CR and a bare LF, NUL and DEL in a field value;
a method that is not a token, HTAB, a fragment and a byte that is not ASCII in the target, and an
empty target; two Authorization lines; chunked; HTTP/2.0 (each 400); content over 16,384 bytes and
a Content-Length of 16 digits (413); `Expect: 100-continue` before the content (a wait); and
requests: HTTP/1.0 with the options keep-alive and close (which closes), a Content-Length with
leading zeros, the absolute-form (routed on its path), HEAD (as GET, without the content), an empty
line before the request, and HTTP/1.2 (as HTTP/1.1). -/
theorem Http.frame_vectors :
    Spec.Http.frame (Spec.lit "GET /feed HTTP/1.1\r\n\r\n") = .bad 400 ∧
    Spec.Http.frame (Spec.lit "GET /feed HTTP/1.1\r\nHost: x\r\nHost: y\r\n\r\n") = .bad 400 ∧
    Spec.Http.frame (Spec.lit "GET /feed HTTP/1.1\r\nHost: a b\r\n\r\n") = .bad 400 ∧
    Spec.Http.frame (Spec.lit "POST /posts HTTP/1.1\r\nHost: x\r\nContent-Length : 5\r\n\r\nhello") = .bad 400 ∧
    Spec.Http.frame (Spec.lit "GET /feed HTTP/1.1\r\nHost: x\r\n x:y\r\n\r\n") = .bad 400 ∧
    Spec.Http.frame (Spec.lit "GET /feed HTTP/1.1\r\nHost: x\r\r\nConnection: close\r\n\r\n") = .bad 400 ∧
    Spec.Http.frame (Spec.lit "GET /feed HTTP/1.1\r\nHost: x\nConnection: close\r\n\r\n") = .bad 400 ∧
    Spec.Http.frame (Spec.lit "GET /feed HTTP/1.1\r\nHost: x\r\nConnection: close\x00\r\n\r\n") = .bad 400 ∧
    Spec.Http.frame (Spec.lit "GET /feed HTTP/1.1\r\nHost: x\r\nX: a\x7fb\r\n\r\n") = .bad 400 ∧
    Spec.Http.frame (Spec.lit "G(T /feed HTTP/1.1\r\nHost: x\r\n\r\n") = .bad 400 ∧
    Spec.Http.frame (Spec.lit "GET /fe\ted HTTP/1.1\r\nHost: x\r\n\r\n") = .bad 400 ∧
    Spec.Http.frame (Spec.lit "GET /feed#x HTTP/1.1\r\nHost: x\r\n\r\n") = .bad 400 ∧
    Spec.Http.frame (Spec.lit "GET /café HTTP/1.1\r\nHost: x\r\n\r\n") = .bad 400 ∧
    Spec.Http.frame (Spec.lit "GET  HTTP/1.1\r\nHost: x\r\n\r\n") = .bad 400 ∧
    Spec.Http.frame (Spec.lit "GET /feed HTTP/1.1\r\nHost: x\r\nAuthorization: a\r\nAuthorization: b\r\n\r\n") =
      .bad 400 ∧
    Spec.Http.frame (Spec.lit "POST /posts HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n") =
      .bad 400 ∧
    Spec.Http.frame (Spec.lit "GET /feed HTTP/2.0\r\nHost: x\r\n\r\n") = .bad 400 ∧
    Spec.Http.frame (Spec.lit "POST /posts HTTP/1.1\r\nHost: x\r\nContent-Length: 100000\r\n\r\n") = .bad 413 ∧
    Spec.Http.frame (Spec.lit "POST /posts HTTP/1.1\r\nHost: x\r\nContent-Length: 1234567890123456\r\n\r\n") =
      .bad 413 ∧
    Spec.Http.frame (Spec.lit "POST /posts HTTP/1.1\r\nHost: x\r\nExpect: 100-continue\r\nContent-Length: 12\r\n\r\n") =
      .incomplete ∧
    Spec.Http.frame (Spec.lit "GET /feed HTTP/1.0\r\nConnection: keep-alive, close\r\n\r\n") =
      .ok ⟨.get, false, Spec.lit "/feed", none, [], true⟩ 53 ∧
    Spec.Http.frame (Spec.lit "POST /posts HTTP/1.1\r\nHost: x\r\nContent-Length: 0000000000000005\r\n\r\nhello") =
      .ok ⟨.post, false, Spec.lit "/posts", none, Spec.lit "hello", false⟩ 72 ∧
    Spec.Http.frame (Spec.lit "GET http://127.0.0.1:3000/feed HTTP/1.1\r\nHost: 127.0.0.1:3000\r\n\r\n") =
      .ok ⟨.get, false, Spec.lit "/feed", none, [], false⟩ 65 ∧
    Spec.Http.frame (Spec.lit "HEAD /feed HTTP/1.1\r\nHost: x\r\n\r\n") =
      .ok ⟨.get, true, Spec.lit "/feed", none, [], false⟩ 32 ∧
    Spec.Http.frame (Spec.lit "\r\nGET /feed HTTP/1.1\r\nHost: x\r\n\r\n") =
      .ok ⟨.get, false, Spec.lit "/feed", none, [], false⟩ 33 ∧
    Spec.Http.frame (Spec.lit "GET /feed HTTP/1.2\r\nHost: x\r\n\r\n") =
      .ok ⟨.get, false, Spec.lit "/feed", none, [], false⟩ 31 :=
  ⟨frame_lit (by decide +kernel), frame_lit (by decide +kernel), frame_lit (by decide +kernel),
    frame_lit (by decide +kernel), frame_lit (by decide +kernel), frame_lit (by decide +kernel),
    frame_lit (by decide +kernel), frame_lit (by decide +kernel), frame_lit (by decide +kernel),
    frame_lit (by decide +kernel), frame_lit (by decide +kernel), frame_lit (by decide +kernel),
    frame_lit (by decide +kernel), frame_lit (by decide +kernel), frame_lit (by decide +kernel),
    frame_lit (by decide +kernel), frame_lit (by decide +kernel), frame_lit (by decide +kernel),
    frame_lit (by decide +kernel), frame_lit (by decide +kernel), frame_lit (by decide +kernel),
    frame_lit (by decide +kernel), frame_lit (by decide +kernel), frame_lit (by decide +kernel),
    frame_lit (by decide +kernel), frame_lit (by decide +kernel)⟩

/-- info: 'Feed.Http.frame_vectors' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms Http.frame_vectors

end Feed

import Feed.Server

/-!
# Idle connections under a budget

What `Idle.pick` guarantees for any candidates and any count `n` of open connections:

* `pickList_closed`: a closed connection is not busy, and it was closed either because more
  connections were open than the budget at its turn and it had been idle for `minIdle`, or because
  it had been idle past a timeout that is set (`pick_busy`: the same for `pick`'s arrays);
* `count_pickList`: without a timeout, it closes exactly the excess over the budget, or every
  spare candidate if there are fewer; so `pickList_none`: nothing at or below the budget;
* `pickList_longest`: with the candidates in order of idle time, longest first (the order in which
  the transport offers them), every connection closed was idle at least as long as every spare
  connection left open;
* `pickList_expired`: every connection that is not busy and idle past a timeout that is set is
  closed.
-/
namespace Feed.Idle

theorem length_pickList (cfg : Cfg) : ∀ (n : Nat) (cs : List Cand), (pickList cfg n cs).length = cs.length
  | _, [] => rfl
  | n, c :: cs => by
    simp only [pickList]
    split <;> simp [length_pickList]

/-- A connection is closed only if it is not busy and, at its turn, more connections were open than
the budget and it had been idle for `minIdle`, or it had been idle past a timeout that is set. -/
theorem pickList_closed (cfg : Cfg) : ∀ (n : Nat) (cs : List Cand) (k : Nat) (c : Cand),
    cs[k]? = some c → (pickList cfg n cs)[k]? = some true →
    c.2 = false ∧ (cfg.minIdle ≤ c.1 ∨ (0 < cfg.timeout ∧ cfg.timeout ≤ c.1))
  | _, [], k, c, h, _ => by simp at h
  | n, d :: cs, 0, c, h, hp => by
    simp only [List.getElem?_cons_zero, Option.some.injEq] at h
    subst h
    simp only [pickList] at hp
    split at hp
    · rename_i hc
      simp only [Cfg.spare, Cfg.expired, Bool.or_eq_true, Bool.and_eq_true, Bool.not_eq_true',
        decide_eq_true_eq] at hc
      rcases hc with ⟨_, h1, h2⟩ | ⟨⟨h1, h2⟩, h3⟩
      · exact ⟨h1, Or.inl h2⟩
      · exact ⟨h1, Or.inr ⟨h2, h3⟩⟩
    · simp at hp
  | n, d :: cs, k + 1, c, h, hp => by
    simp only [List.getElem?_cons_succ] at h
    simp only [pickList] at hp
    split at hp <;> simp only [List.getElem?_cons_succ] at hp <;> exact pickList_closed cfg _ cs k c h hp

/-- info: 'Feed.Idle.pickList_closed' depends on axioms: [propext, Classical.choice] -/
#guard_msgs in #print axioms pickList_closed

/-- Without a timeout, exactly as many are closed as the excess over the budget, or every spare
candidate if there are fewer. -/
theorem count_pickList (cfg : Cfg) (ht : cfg.timeout = 0) : ∀ (n : Nat) (cs : List Cand),
    (pickList cfg n cs).count true = min (n - cfg.budget) (cs.countP cfg.spare)
  | n, [] => by simp [pickList]
  | n, c :: cs => by
    have hx : cfg.expired c = false := by simp [Cfg.expired, ht]
    have ih1 := count_pickList cfg ht (n - 1) cs
    have ih0 := count_pickList cfg ht n cs
    simp only [pickList, hx, Bool.or_false]
    by_cases hb : cfg.budget < n <;> by_cases hs : cfg.spare c = true <;>
      simp [hb, hs, ih1, ih0] <;> omega

/-- info: 'Feed.Idle.count_pickList' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms count_pickList

/-- Without a timeout, nothing is closed while the open connections are within the budget. -/
theorem pickList_none (cfg : Cfg) (ht : cfg.timeout = 0) (n : Nat) (cs : List Cand) (hn : n ≤ cfg.budget) :
    true ∉ pickList cfg n cs := by
  have h := count_pickList cfg ht n cs
  have h0 : n - cfg.budget = 0 := by omega
  rw [h0, Nat.zero_min] at h
  exact List.count_eq_zero.mp h

/-- With no room left under the budget, only expired connections are closed. -/
theorem pickList_full (cfg : Cfg) : ∀ (n : Nat) (cs : List Cand) (k : Nat) (c : Cand), n ≤ cfg.budget →
    cs[k]? = some c → (pickList cfg n cs)[k]? = some true → cfg.expired c = true
  | _, [], k, c, _, h, _ => by simp at h
  | n, d :: cs, 0, c, hn, h, hp => by
    simp only [List.getElem?_cons_zero, Option.some.injEq] at h
    subst h
    simp only [pickList] at hp
    split at hp
    · rename_i hc
      have : Decidable.decide (cfg.budget < n) = false := by simp; omega
      simpa [this] using hc
    · simp at hp
  | n, d :: cs, k + 1, c, hn, h, hp => by
    simp only [List.getElem?_cons_succ] at h
    simp only [pickList] at hp
    split at hp <;> simp only [List.getElem?_cons_succ] at hp
    · exact pickList_full cfg _ cs k c (by omega) h hp
    · exact pickList_full cfg _ cs k c hn h hp

/-- Every connection that is not busy and idle past a timeout that is set is closed. -/
theorem pickList_expired (cfg : Cfg) : ∀ (n : Nat) (cs : List Cand) (k : Nat) (c : Cand),
    cs[k]? = some c → cfg.expired c = true → (pickList cfg n cs)[k]? = some true
  | _, [], k, c, h, _ => by simp at h
  | n, d :: cs, 0, c, h, he => by
    simp only [List.getElem?_cons_zero, Option.some.injEq] at h
    subst h
    simp [pickList, he]
  | n, d :: cs, k + 1, c, h, he => by
    simp only [List.getElem?_cons_succ] at h
    simp only [pickList]
    split <;> simp only [List.getElem?_cons_succ] <;> exact pickList_expired cfg _ cs k c h he

/-- info: 'Feed.Idle.pickList_expired' depends on axioms: [propext, Classical.choice] -/
#guard_msgs in #print axioms pickList_expired

/-- Longest idle first: with the candidates in order of idle time, longest first, every connection
closed was idle at least as long as every spare connection left open. -/
theorem pickList_longest (cfg : Cfg) : ∀ (n : Nat) (cs : List Cand), cs.Pairwise (fun a b => b.1 ≤ a.1) →
    ∀ (i j : Nat) (ci cj : Cand), cs[i]? = some ci → cs[j]? = some cj →
    (pickList cfg n cs)[i]? = some true → (pickList cfg n cs)[j]? = some false → cfg.spare cj = true →
    cj.1 ≤ ci.1
  | _, [], _, i, _, ci, _, hi, _, _, _, _ => by simp at hi
  | n, d :: cs, hs, i, j, ci, cj, hi, hj, hpi, hpj, hsp => by
    rw [List.pairwise_cons] at hs
    match i, j with
    | 0, 0 =>
      have : (pickList cfg n (d :: cs))[0]? = some true := hpi
      rw [hpj] at this
      simp at this
    | 0, j + 1 =>
      simp only [List.getElem?_cons_zero, Option.some.injEq] at hi
      simp only [List.getElem?_cons_succ] at hj
      subst hi
      exact hs.1 cj (List.mem_of_getElem? hj)
    | i + 1, 0 =>
      -- the spare head was left open, so there was no room under the budget and it was not
      -- expired; a later connection closed must then be expired, and idle no longer than the head
      simp only [List.getElem?_cons_zero, Option.some.injEq] at hj
      simp only [List.getElem?_cons_succ] at hi
      subst hj
      have hci : ci.1 ≤ d.1 := hs.1 ci (List.mem_of_getElem? hi)
      simp only [pickList] at hpi hpj
      by_cases hc : (Decidable.decide (cfg.budget < n) && cfg.spare d || cfg.expired d) = true
      · simp [hc] at hpj
      · simp only [hc, Bool.false_eq_true, ↓reduceIte, List.getElem?_cons_succ] at hpi
        simp only [hsp, Bool.and_true, Bool.or_eq_true, decide_eq_true_eq, not_or] at hc
        have he := pickList_full cfg n cs i ci (by omega) hi hpi
        simp only [Cfg.expired, Bool.and_eq_true, Bool.not_eq_true', decide_eq_true_eq] at he
        simp only [Cfg.spare, Bool.and_eq_true, Bool.not_eq_true', decide_eq_true_eq] at hsp
        exact absurd (show cfg.expired d = true by
          simp only [Cfg.expired, Bool.and_eq_true, Bool.not_eq_true', decide_eq_true_eq]
          exact ⟨⟨hsp.1, he.1.2⟩, by omega⟩) hc.2
    | i + 1, j + 1 =>
      simp only [List.getElem?_cons_succ] at hi hj
      simp only [pickList] at hpi hpj
      by_cases hc : (Decidable.decide (cfg.budget < n) && cfg.spare d || cfg.expired d) = true
      · simp only [hc, ↓reduceIte, List.getElem?_cons_succ] at hpi hpj
        exact pickList_longest cfg _ cs hs.2 i j ci cj hi hj hpi hpj hsp
      · simp only [hc, Bool.false_eq_true, ↓reduceIte, List.getElem?_cons_succ] at hpi hpj
        exact pickList_longest cfg _ cs hs.2 i j ci cj hi hj hpi hpj hsp

/-- info: 'Feed.Idle.pickList_longest' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms pickList_longest

/-! ## The arrays the transport passes -/

theorem pick_toList (b m t n : Nat) (idle : Array Nat) (busy : Array Bool) :
    (pick b m t n idle busy).toList = pickList ⟨b, m, t⟩ n (idle.toList.zip busy.toList) := by
  simp [pick]

/-- `pick` never closes a busy connection, nor one idle for less than `minIdle` unless it is past
a timeout that is set. -/
theorem pick_busy (b m t n : Nat) (idle : Array Nat) (busy : Array Bool) (k : Nat)
    (h : (pick b m t n idle busy)[k]? = some true) :
    busy[k]? = some false ∧ ∃ i, idle[k]? = some i ∧ (m ≤ i ∨ (0 < t ∧ t ≤ i)) := by
  rw [← Array.getElem?_toList, pick_toList] at h
  have hk : k < (idle.toList.zip busy.toList).length := by
    have := (List.getElem?_eq_some_iff.mp h).1
    rwa [length_pickList] at this
  obtain ⟨c, hc⟩ : ∃ c, (idle.toList.zip busy.toList)[k]? = some c := ⟨_, List.getElem?_eq_getElem hk⟩
  have := pickList_closed _ n _ k c hc h
  rw [List.getElem?_zip_eq_some] at hc
  obtain ⟨hi, hb⟩ := hc
  rw [Array.getElem?_toList] at hi hb
  exact ⟨by rw [hb, this.1], c.1, hi, this.2⟩

/-- Without a timeout `pick` closes nothing while the open connections are within the budget. -/
theorem pick_none (b m n : Nat) (idle : Array Nat) (busy : Array Bool) (hn : n ≤ b) :
    true ∉ pick b m 0 n idle busy := by
  rw [← Array.mem_toList_iff, pick_toList]
  exact pickList_none ⟨b, m, 0⟩ rfl n _ hn

end Feed.Idle

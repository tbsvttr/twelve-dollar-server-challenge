import Lean
import UorEmit.Emit

/-! The claims, stated here directly on the functions the C tables are computed from, so that weakening or deleting a
theorem in the generated module, or redefining a helper it was stated through, stops the build. -/

open Lean Elab Command
open UorEmit.Emit

-- A theorem may rest only on these two. An added axiom or a `sorry` stops the build.
elab "#check_axioms " id:ident : command => do
  let name ← liftCoreM (realizeGlobalConstNoOverloadWithInfo id)
  let axioms ← liftCoreM (collectAxioms name)
  for axiom' in axioms do
    unless axiom' == ``propext || axiom' == ``Quot.sound do
      throwError "{name} rests on {axiom'}"

-- Batch order.
example (p : Phase) (e : Event) (h : actionOf p e = Action.sendAll) : p = Phase.committing ∧ e = Event.commitOk := by
  revert h; cases p <;> cases e <;> simp [actionOf]
example (p : Phase) (e : Event) (h : actionOf p e = Action.failAll) : p = Phase.committing ∧ e = Event.commitFail := by
  revert h; cases p <;> cases e <;> simp [actionOf]
example (p : Phase) (e : Event) (h : nextPhase p e = Phase.committing) : p = Phase.committing ∨ actionOf p e = Action.commit := by
  revert h; cases p <;> cases e <;> simp [nextPhase, actionOf]

-- Routes.
example (r : Route) : isWrite r = needsAuth r := by cases r <;> rfl
example (m : Method) (s : Shape) (h : isWrite (routeOf m s) = true) : m = Method.post := by
  revert h; cases m <;> cases s <;> simp [routeOf, isWrite]
example (s : Shape) : routeOf Method.other s = Route.notFound := by cases s <;> rfl

-- Holding writes.
example (room gate : Flag) : shouldHold room gate Flag.no Flag.no = Flag.no := by cases room <;> cases gate <;> rfl
example (gate write : Flag) : shouldHold Flag.yes gate write Flag.yes = Flag.yes := by cases gate <;> cases write <;> rfl
example (held : Flag) : shouldHold Flag.yes Flag.yes Flag.yes held = Flag.yes := by cases held <;> rfl
example (room write : Flag) : shouldHold room Flag.no write Flag.no = Flag.no := by cases room <;> cases write <;> rfl
example (gate write held : Flag) : shouldHold Flag.no gate write held = Flag.no := by rfl

-- The write pause.
example (over : Flag) : gateNext Flag.yes over Flag.no Flag.no = Flag.yes := by cases over <;> rfl
example (copied timed : Flag) : gateNext Flag.no Flag.yes copied timed = Flag.yes := by rfl
example (over timed : Flag) : gateNext Flag.yes over Flag.yes timed = Flag.no := by rfl
example (over copied : Flag) : gateNext Flag.yes over copied Flag.yes = Flag.no := by cases copied <;> rfl

-- The failure table.
example (f : Failure) : statusOf f = Status.serverError ↔ f = Failure.internal := by
  cases f <;> simp [statusOf]

-- Byte classes, at the checked values.
example : escapeClass 34 = EscapeClass.backslash := by rfl
example : escapeClass 92 = EscapeClass.backslash := by rfl
example : escapeClass 0 = EscapeClass.unicode := by rfl
example : escapeClass 31 = EscapeClass.unicode := by rfl
example : escapeClass 32 = EscapeClass.plain := by rfl
example : escapeClass 255 = EscapeClass.plain := by rfl

-- All 22 theorems exist and rest on nothing else.
#check_axioms send_only_after_commit
#check_axioms fail_only_after_failed_commit
#check_axioms committing_follows_commit
#check_axioms every_write_needs_a_token
#check_axioms only_post_writes
#check_axioms unknown_methods_are_not_found
#check_axioms reads_go_on_while_writes_wait
#check_axioms a_held_connection_keeps_its_order
#check_axioms a_closed_gate_holds_writes
#check_axioms an_open_gate_holds_nothing_new
#check_axioms a_full_hold_queue_holds_nothing
#check_axioms the_gate_stays_closed_until_the_log_is_copied
#check_axioms the_gate_closes_at_the_limit
#check_axioms the_gate_opens_when_the_log_is_copied
#check_axioms a_timeout_always_opens_the_gate
#check_axioms only_an_internal_failure_is_a_server_error
#check_axioms a_quote_is_escaped
#check_axioms a_backslash_is_escaped
#check_axioms the_first_control_byte_is_escaped
#check_axioms the_last_control_byte_is_escaped
#check_axioms a_space_is_plain
#check_axioms the_top_byte_is_plain

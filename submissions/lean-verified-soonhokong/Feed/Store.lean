/-!
# The storage interface

The handler reads and writes the database only through these operations. Each has a one-line
meaning over the list model of the tables (`Feed/Model.lean`): the proofs
are about the handler instantiated with the model; the server runs the same handler code
instantiated with `IO`, where each operation is a C function over SQLite (`runtime/db.c`).
What the end-to-end theorems ask of an implementation is `Store.Contract`
(`Feed/Proofs/Store.lean`): each operation as its meaning says (a page up to `Page.Same`), and
`insertPost` only for a body that is a post's text as the API takes it (`Spec.Body.accept`), the
only bodies the handler inserts; schema.sql's CHECK refuses some other bodies, and SQLite adds no
row for them.

A read returns its rows in a flat form so that a request costs one call and a handful of
allocations: one byte array with the text and one array of numbers describing each row.
-/
namespace Feed

/-- Posts with their authors and like counts. Row `k` is `cols[8k .. 8k+8)`:
`id, b, c, e, found, s, t, likes`; the body is `blob[b, c)`, `created_at` is `blob[c, e)`, and the
author's username is `blob[s, t)` when `found` is 1 (0: the post's user row is missing). -/
structure Page where
  blob : ByteArray
  cols : Array Nat
  deriving Inhabited

/-- The operations, in reading order of a batch: `begin` opens the batch's transaction; the reads
see its snapshot; `endReads` closes the read cursors; then writes; then `commit`. -/
class Store (m : Type → Type) where
  begin : m Bool
  /-- the first `n` posts in `(created_at DESC, id DESC)` order with their authors and like counts -/
  feedPage : Nat → m Page
  /-- the post with this id with its author and like count; no row if there is no such post -/
  postPage : Nat → m Page
  /-- `SELECT 1` succeeded -/
  health : m Bool
  endReads : m Unit
  /-- whether a posts row with this id exists: 0 no, 1 yes, 2 error -/
  postExists : Nat → m Nat
  /-- insert (user, post) into likes unless present: 1 inserted, 0 present, 2 error -/
  insertLike : (uid pid : Nat) → m Nat
  /-- insert a post: its `created_at` and id (id 0 on error) -/
  insertPost : (uid : Nat) → (body : ByteArray) → m (ByteArray × Nat)
  commit : m Bool

namespace Ffi
@[extern "feed_db_begin"] opaque begin : IO Bool
@[extern "feed_db_feed_page"] opaque feedPage (n : @& Nat) : IO Page
@[extern "feed_db_post_page"] opaque postPage (id : @& Nat) : IO Page
@[extern "feed_db_health"] opaque health : IO Bool
@[extern "feed_db_end_reads"] opaque endReads : IO Unit
@[extern "feed_db_post_exists"] opaque postExists (id : @& Nat) : IO Nat
@[extern "feed_db_insert_like"] opaque insertLike (uid pid : @& Nat) : IO Nat
@[extern "feed_db_insert_post"] opaque insertPost (uid : @& Nat) (body : @& ByteArray) : IO (ByteArray × Nat)
@[extern "feed_db_commit"] opaque commit : IO Bool
end Ffi

instance : Store IO where
  begin := Ffi.begin
  feedPage := Ffi.feedPage
  postPage := Ffi.postPage
  health := Ffi.health
  endReads := Ffi.endReads
  postExists := Ffi.postExists
  insertLike := Ffi.insertLike
  insertPost := Ffi.insertPost
  commit := Ffi.commit

end Feed

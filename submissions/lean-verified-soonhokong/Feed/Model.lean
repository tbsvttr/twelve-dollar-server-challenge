import Feed.Spec
import Feed.Store

/-!
# The storage model

`Store Model` implements every storage operation of `Feed/Store.lean` on the specification's
tables (`Feed.Spec.DB`), in a state monad. It is the meaning of the contract each C primitive in
`runtime/db.c` is written to: same results, same effect on the tables. The proofs run the handler
on this instance; the server runs the same handler code on `Store IO`.

Pages come back in the flat form the C functions produce (`Feed.Page`); `Page.view` reads a row
back as the post object it renders, if any.
-/
namespace Feed
open Spec

/-- The bytes of a byte array, as a list. -/
abbrev bs (b : ByteArray) : List UInt8 := b.data.toList

/-! ## Pages -/

/-- A post with what a page holds about it: its author's name, if the user exists, and its like count. -/
def Spec.DB.entry (db : DB) (p : Post) : Post × Option (List UInt8) × Nat :=
  (p, (db.user? p.userId).map (·.name), db.likeCount p.id)

/-- The post object of an entry, if it has an author. -/
def entryView : Post × Option (List UInt8) × Nat → Option View
  | (p, u, n) => u.map fun u => ⟨p.id, p.body, p.createdAt, u, n⟩

/-- Blob and columns for a page of entries, the blob starting at offset `off`. -/
def encPage : List (Post × Option (List UInt8) × Nat) → Nat → List UInt8 × List Nat
  | [], _ => ([], [])
  | (p, none, n) :: ps, off =>
    let c := off + p.body.length
    let e := c + p.createdAt.length
    let r := encPage ps e
    (p.body ++ p.createdAt ++ r.1, [p.id, off, c, e, 0, e, e, n] ++ r.2)
  | (p, some u, n) :: ps, off =>
    let c := off + p.body.length
    let e := c + p.createdAt.length
    let t := e + u.length
    let r := encPage ps t
    (p.body ++ p.createdAt ++ u ++ r.1, [p.id, off, c, e, 1, e, t, n] ++ r.2)

def mkPage (ps : List (Post × Option (List UInt8) × Nat)) : Page :=
  let r := encPage ps 0
  ⟨⟨r.1.toArray⟩, r.2.toArray⟩

/-- The number of rows. -/
def Page.count (pg : Page) : Nat := pg.cols.size / 8

/-- Row `k` as the post object it renders: none when its author row is missing. -/
def Page.view (pg : Page) (k : Nat) : Option View :=
  if pg.cols[8 * k + 4]! = 1 then
    some ⟨pg.cols[8 * k]!, slice pg.blob pg.cols[8 * k + 1]! pg.cols[8 * k + 2]!,
      slice pg.blob pg.cols[8 * k + 2]! pg.cols[8 * k + 3]!, slice pg.blob pg.cols[8 * k + 5]! pg.cols[8 * k + 6]!,
      pg.cols[8 * k + 7]!⟩
  else none

/-! ## The model -/

abbrev Model := StateM DB

instance : Store Model where
  begin := pure true
  feedPage n := do let db ← get; return mkPage ((db.sorted.take n).map db.entry)
  postPage id := do let db ← get; return mkPage ((db.post? id).toList.map db.entry)
  health := pure true
  endReads := pure ()
  postExists id := do return if ((← get).post? id).isSome then 1 else 0
  insertLike uid pid := do
    let (had, db) := (← get).insertLike uid pid
    set db
    return if had then 0 else 1
  insertPost uid body := do
    let (p, db) := (← get).insertPost uid (bs body)
    set db
    return (⟨p.createdAt.toArray⟩, p.id)
  commit := pure true

end Feed

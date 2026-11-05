import Lean
import Feed

/-!
# What the docs say of the proofs

Run by `check-docs.sh`, not by `build.sh`; nothing here is linked into the server. Three checks of
statements that no theorem makes:

* The statements still to prove: the ```lean blocks in the module docs of `Feed/` (all of them in
  `Feed/Proofs/` today) are elaborated against the code, in `namespace Feed` with `Spec` open, as
  their docs say. A `theorem` without a proof is checked as `theorem` checks its statement; one
  with a proof has its proof checked too, with the statements before it as hypotheses. The other
  commands (`def`, `opaque`) run as they are. A statement that the code has as a theorem by now
  is an error: when a statement is proved it moves out of the doc.
* The hypotheses of the end-to-end theorems (`endToEnd`): none may be one that does not depend on
  the theorem's other arguments, as their docs and `README.md` say. A statement still to prove,
  taken as a hypothesis, would be one, so none can come back unnoticed; the error names the
  statement when the hypothesis is one of the docs' statements.
* The leaves whose Lean definitions the theorems use: each theorem of `Feed/Proofs/` that refers
  to a leaf, directly or through other constants, is checked again by the kernel, in a copy of
  its environment that is then dropped, with the leaf replaced by an opaque constant, which the
  kernel never unfolds. It fails exactly when its proof needs the leaf's definition, or a theorem
  whose proof does. `README.md` (the top and the C leaves bullet) and the header of
  `runtime/leaves.c` name the leaves no theorem of `Feed/Proofs/` needs; so does `unusedLeaves`,
  which changes with them.

Errors name the file and line they are about; `lean` exits with 1 on any. Each check ends its
output with a line that says what it checked.
-/

open Lean Elab Command Meta

/-- A `theorem` of a doc without a proof: its statement. -/
syntax (name := docStatement) "theorem " declId ppIndent(declSig) : command

namespace CheckDocs

/-- The text of the ```lean blocks in the module docs (`/-! … -/`) of a file, every other line
left empty, so that positions in it are those in the file. -/
def docBlocks (text : String) : String := Id.run do
  let mut out := ""
  let mut inDoc := false
  let mut inBlock := false
  for line in text.splitOn "\n" do
    let t := line.trimAscii.toString
    if inBlock then
      if t == "```" then inBlock := false else out := out ++ line
    else if inDoc then
      if t == "```lean" then inBlock := true
      else if t.endsWith "-/" then inDoc := false
    else if t.startsWith "/-!" && !t.endsWith "-/" then inDoc := true
    out := out ++ "\n"
  return out

/-- the module that declares `n` -/
def moduleOf (env : Environment) (n : Name) : Name :=
  ((env.getModuleIdxFor? n).map (env.allImportedModuleNames[·]!)).getD .anonymous

/-- The statement of a doc theorem, `∀ binders, type`, elaborated as `theorem` elaborates its
statement; with a proof, the proof too, with the earlier statements as hypotheses. -/
def elabStatement (binders : Array Syntax) (type : Syntax) (proof? : Option Syntax)
    (earlier : Array (Name × Expr)) : CommandElabM Expr :=
  runTermElabM fun _ => withLocalDeclsD (earlier.map fun (n, t) => (n, fun _ => pure t)) fun hs =>
    Term.elabBinders binders fun xs => do
      let ty ← Term.elabType type
      Term.synthesizeSyntheticMVarsNoPostponing
      let ty ← instantiateMVars ty
      unless ← isProp ty do throwErrorAt type "not a proposition:{indentExpr ty}"
      if let some p := proof? then
        let v ← Term.elabTermEnsuringType p ty
        Term.synthesizeSyntheticMVarsNoPostponing
        if (← instantiateMVars v).hasExprMVar then throwErrorAt p "the proof is not complete"
      let st ← instantiateMVars (← mkForallFVars xs ty)
      if st.hasExprMVar || hs.any (st.containsFVar ·.fvarId!) then
        throwErrorAt type "the statement is not closed:{indentExpr st}"
      return st

/-- A statement of a doc, checked, with its name as the doc writes it; an error if the code has a
constant of its name. -/
def checkStatement (id : Syntax) (sig : Syntax) (proof? : Option Syntax)
    (earlier : Array (Name × Expr)) : CommandElabM (Name × Expr) := do
  let name := id[0].getId
  let st ← elabStatement sig[0].getArgs sig[1][1] proof? earlier
  let full := (← getCurrNamespace) ++ name
  if let some ci := (← getEnv).find? full then
    let same ← liftTermElabM <| isDefEq ci.type st
    let other := if same then "" else " with another statement"
    logErrorAt id
      m!"`{full}` is in {moduleOf (← getEnv) full}{other}: take its statement out of the doc"
  return (name, st)

/-- Checks the doc statements of one file; returns how many there were. -/
def checkFile (file : System.FilePath) (earlier : Array (Name × Expr)) :
    CommandElabM (Nat × Array (Name × Expr)) := do
  let input := docBlocks (← IO.FS.readFile file)
  if input.all (· == '\n') then return (0, earlier)
  let ictx := Parser.mkInputContext input file.toString
  withReader ({ · with fileName := file.toString, fileMap := ictx.fileMap, snap? := none }) do
    elabCommand (← `(namespace $(mkIdent `Feed)))
    elabCommand (← `(open $(mkIdent `Spec):ident))
    let mut earlier := earlier
    let mut n := 0
    let mut ps : Parser.ModuleParserState := {}
    repeat
      let env ← getEnv
      let scope ← getScope
      let pmctx := { env, options := scope.opts, currNamespace := scope.currNamespace,
                     openDecls := scope.openDecls }
      let (stx, ps', msgs) := Parser.parseCommand ictx pmctx ps {}
      ps := ps'
      modify fun s => { s with messages := s.messages ++ msgs }
      if stx.isOfKind ``Parser.Command.eoi then break
      let thm? : Option (Syntax × Syntax × Option Syntax) :=
        if stx.isOfKind ``docStatement then some (stx[1], stx[2], none)
        else if stx.isOfKind ``Parser.Command.declaration &&
            stx[1].isOfKind ``Parser.Command.theorem then
          some (stx[1][1], stx[1][2], some stx[1][3][1])
        else none
      match thm? with
      | some (id, sig, proof?) =>
        n := n + 1
        try earlier := earlier.push (← withRef stx (checkStatement id sig proof? earlier))
        catch e => logException e
      | none => withRef stx (elabCommand stx)
    elabCommand (← `(end $(mkIdent `Feed)))
    return (n, earlier)

/-- The leaves whose Lean definitions no theorem of `Feed/Proofs/` needs, as `README.md` and
`runtime/leaves.c` say. -/
def unusedLeaves : List Name :=
  []

/-- the constants an entry refers to: in its type, its value, its constructors -/
def refs (env : Environment) : ConstantInfo → Array Name
  | .defnInfo v => v.type.getUsedConstants ++ v.value.getUsedConstants
  | .thmInfo v => v.type.getUsedConstants ++ v.value.getUsedConstants
  | .opaqueInfo v => v.type.getUsedConstants ++ v.value.getUsedConstants
  | .inductInfo v =>
    v.ctors.foldl (fun acc c => acc ++ ((env.find? c).map (·.type.getUsedConstants)).getD #[])
      v.type.getUsedConstants
  | .ctorInfo v => v.type.getUsedConstants.push v.induct
  | .recInfo v => v.type.getUsedConstants ++ v.all.toArray
  | ci => ci.type.getUsedConstants

/-- `e` with every constant of `dep` renamed under `_opaque` -/
def rename (dep : NameSet) (e : Expr) : CoreM Expr :=
  Core.transform e (post := fun
    | .const n us => return .done (.const (if dep.contains n then `_opaque ++ n else n) us)
    | .proj s i b => return .done (.proj (if dep.contains s then `_opaque ++ s else s) i b)
    | e => return .done e)

/-- The entry `n` again as a declaration of `_opaque ++ n`, its expressions passed through `r`. -/
def copyDecl (env : Environment) (r : Expr → CoreM Expr) (n : Name) : ConstantInfo → CoreM Declaration
  | .defnInfo v => do
    return .defnDecl { v with
      name := `_opaque ++ n, type := (← r v.type), value := (← r v.value), all := v.all.map (`_opaque ++ ·) }
  | .thmInfo v => do
    return .thmDecl { v with
      name := `_opaque ++ n, type := (← r v.type), value := (← r v.value), all := v.all.map (`_opaque ++ ·) }
  | .opaqueInfo v => do
    return .opaqueDecl { v with
      name := `_opaque ++ n, type := (← r v.type), value := (← r v.value), all := v.all.map (`_opaque ++ ·) }
  | .inductInfo v => do
    let ts ← v.all.mapM fun t => do
      let some (.inductInfo tv) := env.find? t | throwError "no {t}"
      let cs ← tv.ctors.mapM fun c => do
        let some cc := env.find? c | throwError "no {c}"
        return ({ name := `_opaque ++ c, type := (← r cc.type) } : Constructor)
      return ({ name := `_opaque ++ t, type := (← r tv.type), ctors := cs } : InductiveType)
    return .inductDecl v.levelParams v.numParams ts v.isUnsafe
  | _ => throwError "{n}: an entry of an unexpected kind"

/-- The theorems of the package that fail to check with `leaf` opaque, each with a constant it
refers to that failed (none: its own proof needs the leaf's definition). Every constant that
reaches `leaf` is added again, renamed, in an order where each comes after what it refers to. -/
def failingWith (env : Environment) (feed : Array Name) (refsOf : NameMap (Array Name)) (leaf : Name) :
    CoreM (Array (Name × Option Name)) := do
  -- the constants that reach `leaf`, each after the ones it refers to
  let mut reaches : NameMap Bool := {}
  let mut order : Array Name := #[]
  for root in feed do
    if reaches.contains root then continue
    let mut stack : Array (Name × Bool) := #[(root, false)]
    let mut seen : NameSet := {}
    while h : stack.size > 0 do
      let (n, after) := stack[stack.size - 1]
      stack := stack.pop
      if after then
        let r := n == leaf || (refsOf.getD n #[]).any (reaches.getD · false)
        reaches := reaches.insert n r
        if r then order := order.push n
      else if !reaches.contains n && !seen.contains n then
        seen := seen.insert n
        stack := stack.push (n, true)
        for d in refsOf.getD n #[] do
          if !reaches.contains d && !seen.contains d then stack := stack.push (d, false)
  -- unsafe and partial definitions stay as they are: no theorem can need their values
  let isSafe (n : Name) : Bool := match env.find? n with
    | some (.defnInfo v) => v.safety == .safe
    | some (.opaqueInfo v) => !v.isUnsafe
    | _ => true
  let safe := order.filter isSafe
  let dep : NameSet := safe.foldl (·.insert ·) {}
  let some li := env.find? leaf | throwError "no {leaf}"
  let mut kenv := env.toKernelEnv
  -- the leaf as an opaque constant, whose value (the leaf) the kernel never unfolds
  let opq := Declaration.opaqueDecl
    { name := `_opaque ++ leaf, levelParams := li.levelParams, type := (← rename dep li.type),
      value := .const leaf (li.levelParams.map .param), isUnsafe := false, all := [`_opaque ++ leaf] }
  match kenv.addDeclCore 0 0 opq none with
  | .ok k => kenv := k
  | .error _ => throwError "cannot add {leaf} as an opaque constant"
  let mut failed : NameMap (Option Name) := {}
  let mut added : NameSet := {}
  for n in safe do
    if n == leaf || added.contains n then continue
    let some ci := env.find? n | continue
    -- constructors and recursors come with their inductive type
    let withType := match ci with | .ctorInfo _ | .recInfo _ => true | _ => false
    if withType then continue
    if let some d := (refsOf.getD n #[]).find? failed.contains then
      failed := failed.insert n (some d)
      continue
    match kenv.addDeclCore 0 0 (← copyDecl env (rename dep) n ci) none with
    | .ok k =>
      kenv := k
      if let .inductInfo v := ci then added := v.all.foldl (·.insert ·) added
    | .error _ => failed := failed.insert n none
  return failed.toArray.filter fun (n, _) => (env.find? n).any (·.isTheorem)

/-- Which leaves' definitions the theorems of `Feed/Proofs/` need, against `unusedLeaves`. -/
def checkLeaves : CommandElabM Unit := liftTermElabM do
  let env ← getEnv
  let inFeed (n : Name) := (`Feed).isPrefixOf (moduleOf env n)
  let feed : Array Name := env.constants.fold (init := #[]) fun acc n _ =>
    if inFeed n then acc.push n else acc
  let refsOf : NameMap (Array Name) := feed.foldl (init := {}) fun m n =>
    m.insert n (((env.find? n).map (refs env)).getD #[] |>.filter inFeed)
  let leaves := (feed.filter fun n => (env.find? n).any (·.isDefinition) && isExtern env n).qsort Name.lt
  let mut unused := #[]
  for leaf in leaves do
    let proofs := (← failingWith env feed refsOf leaf).filter fun (n, _) =>
      (`Feed.Proofs).isPrefixOf (moduleOf env n)
    let own := proofs.filter (·.2.isNone)
    if proofs.isEmpty then
      unused := unused.push leaf
      IO.println s!"{leaf}: no theorem of Feed/Proofs/ needs its definition"
    else
      IO.println s!"{leaf}: {proofs.size} theorems of Feed/Proofs/ need its definition, \
        {own.size} in their own proofs: {(own.map (·.1)).qsort Name.lt}"
  let said := unusedLeaves.toArray.qsort Name.lt
  if unused != said then
    logError m!"the theorems of Feed/Proofs/ need the definitions of all {leaves.size} leaves but \
      {unused}, where README.md, runtime/leaves.c and `unusedLeaves` say all but {said}"
  else
    IO.println s!"the theorems of Feed/Proofs/ need the definitions of {leaves.size - unused.size} of \
      the {leaves.size} leaves, as README.md and runtime/leaves.c say"

/-- The end-to-end theorems, which take no statement still to prove as a hypothesis. -/
def endToEnd : List Name :=
  [`Feed.decide_correct, `Feed.readLoop_correct, `Feed.runBatch_correct, `Feed.runBatch_correct_model]

/-- The hypotheses of the theorems of `endToEnd` that do not depend on their other arguments, of
which there must be none; one whose name ends in that of a doc statement of `earlier` and whose
type is that statement (a hypothesis's name has one part, so `Http.parse_view` is `parse_view`
there) is named as that statement. -/
def checkHypotheses (earlier : Array (Name × Expr)) : CommandElabM Unit := liftTermElabM do
  let mut bad := 0
  for thm in endToEnd do
    let some ci := (← getEnv).find? thm | throwError "`{thm}` is not in the code"
    let file := System.mkFilePath ((moduleOf (← getEnv) thm).components.map (·.toString))
      |>.addExtension "lean"
    let at_ := match ← findDeclarationRanges? thm with
      | some r => s!"{file}:{r.selectionRange.pos.line}: "
      | none => s!"{file}: "
    let hyps ← forallTelescope ci.type fun xs _ => xs.filterMapM fun x => do
      let d ← x.fvarId!.getDecl
      return if (← isProp d.type) && !d.type.hasFVar then some (d.userName, d.type) else none
    for (h, ty) in hyps do
      bad := bad + 1
      let stmt? ← earlier.findM? fun (n, st) => do
        return n.getString! == h.getString! && (← isDefEq ty st)
      match stmt? with
      | some (n, _) =>
        logError m!"{at_}`{thm}` takes the statement `{n}` still to prove as its hypothesis `{h}`: \
          the end-to-end theorems take none, as their docs and README.md say"
      | none =>
        logError m!"{at_}`{thm}` takes `{h}`, a hypothesis that does not depend on its other \
          arguments: the end-to-end theorems take none, as their docs and README.md say"
  if bad == 0 then
    IO.println s!"the {endToEnd.length} end-to-end theorems take no hypothesis that does not depend on \
      their other arguments, so no statement still to prove"

/-- The doc statements of every module of the package, in the order of the imports; then the
hypotheses of the theorems of `endToEnd`, against them. -/
def checkStatements : CommandElabM Unit := do
  let mut earlier := #[]
  let mut total := 0
  let mut files := 0
  for m in (← getEnv).allImportedModuleNames do
    unless (`Feed).isPrefixOf m do continue
    let file := System.mkFilePath (m.components.map (·.toString)) |>.addExtension "lean"
    let (n, e) ← checkFile file earlier
    earlier := e
    total := total + n
    if n > 0 then files := files + 1
  IO.println s!"{total} statements still to prove, in the module docs of {files} files, checked \
    against the code"
  checkHypotheses earlier

end CheckDocs

set_option autoImplicit false in
#eval CheckDocs.checkStatements

#eval CheckDocs.checkLeaves

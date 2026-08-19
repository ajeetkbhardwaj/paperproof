/-
  # Enriched JSON Output

  A sibling to `terminal.lean`. Produces a JSON document tailored for
  Lean-4 → natural-language translation pipelines (e.g. Paperproof +
  Ollama). On top of the standard Paperproof `Result` payload, this
  adds:

    - `theoremName`     : the Lean constant name of the theorem proved
    - `declarationKind` : "theorem" | "lemma" | "example" | "def" | ...
    - `theoremType`     : the *statement* of the theorem, fully
                          pretty-printed with `pp.fullNames := true`
    - `theoremDocstring` : the user-written `/-- ... -/` doc comment,
                           if any (empty string otherwise)
    - `allHypotheses`   : the names + types of the theorem's bound
                          variables (i.e. the "Given" part)

  These fields give the downstream LLM a clean theorem statement
  separate from the proof trace.

  Build (add to the consumer's `lakefile.lean`):

    ```lean
    lean_exe enrichedTerminal where
      srcDir := ".lake/packages/Paperproof/lean"
      supportInterpreter := true
    ```

  Run:

    ```shell
    lake exe enrichedTerminal FILE.lean THEOREM_NAME out.json
    ```
-/
import Lean
import Lean.DocString
import Lean.Meta.Basic
import Services.BetterParser

open Lean Elab Paperproof.Services

namespace Paperproof.Terminal

/-- One theorem's worth of metadata, on top of the parsed `Result`. -/
structure EnrichedResult where
  theoremName      : Name
  declarationKind  : String
  theoremType      : String
  theoremDocstring : String
  allHypotheses    : List Hypothesis
  steps            : List ProofStep
  allGoals         : List GoalInfo
  deriving Inhabited

instance : ToJson EnrichedResult where
  toJson r := Json.mkObj [
    ("theoremName",      toJson r.theoremName.toString),
    ("declarationKind",  toJson r.declarationKind),
    ("theoremType",      toJson r.theoremType),
    ("theoremDocstring", toJson r.theoremDocstring),
    ("allHypotheses",    toJson r.allHypotheses),
    ("steps",            toJson r.steps),
    ("allGoals",         toJson r.allGoals)
  ]

/-- Pretty-print the type of a declaration with `pp.fullNames := true`. -/
def prettyType (env : Environment) (type : Expr) : MetaM String := do
  let opts := ({} : Lean.Options).setBool `pp.fullNames true
  let mctx : MetavarContext ← getMCtx
  let lctx : LocalContext    := {}
  let ctx : PPContext        := { env, mctx, lctx, opts }
  let fmt ← ppExprWithInfos ctx type
  return fmt.fmt.pretty

/-- Extract a friendly "declaration kind" string from a `ConstantInfo`. -/
def declarationKind (ci : ConstantInfo) : String :=
  match ci with
  | .axiomInfo _    => "axiom"
  | .defnInfo _     => "def"
  | .thmInfo _      => "theorem"
  | .opaqueInfo _   => "opaque"
  | .quotInfo _     => "quotient"
  | .inductInfo _   => "inductive"
  | .structInfo _   => "structure"
  | .classInfo _    => "class"
  | .ctorInfo _     => "constructor"
  | .recInfo _      => "recursor"

/-- Pretty-print the theorem's binder variables as a list of hypotheses. -/
def collectBinderHyps (env : Environment) (type : Expr) :
    MetaM (List Hypothesis) := do
  let opts := ({} : Lean.Options).setBool `pp.fullNames true
  Meta.forallTelescope type fun args _ => do
    let mut lctx' := LocalContext.empty
    for arg in args do
      let decl ← arg.fvarId!.getDecl
      lctx' := lctx'.addDecl decl
    let mctx ← getMCtx
    let ppCtx : PPContext := { env, mctx, lctx := lctx', opts }
    args.mapM fun arg => do
      let decl ← arg.fvarId!.getDecl
      let tyFmt ← ppExprWithInfos ppCtx decl.type
      return ({
        username := decl.userName.toString,
        type     := tyFmt.fmt.pretty,
        value    := none,
        id       := decl.fvarId.name.toString,
        isProof  := "data"
      } : Hypothesis)

/-- Build an `EnrichedResult` for a given theorem. The docstring must be
    fetched by the caller (it is IO-based) and passed in. -/
def enrichResult (env : Environment) (name : Name)
    (result : Result) (doc : String) : MetaM EnrichedResult := do
  let some ci := env.find? name | throwError "unknown constant {name}"
  let kind := declarationKind ci
  let typeStr ← prettyType env ci.type
  let hyps    ← collectBinderHyps env ci.type
  return {
    theoremName      := name
    declarationKind  := kind
    theoremType      := typeStr
    theoremDocstring := doc
    allHypotheses    := hyps
    steps            := result.steps
    allGoals         := result.allGoals.toList
  }

end Paperproof.Terminal

open Paperproof.Terminal

structure Config where
  filePath   : System.FilePath := "."
  constName  : Lean.Name      := `Unknown
  outputPath : System.FilePath := "."

def parseArgs (args : Array String) : IO Config := do
  if args.size < 3 then
    throw <| IO.userError
      "usage: lake exe enrichedTerminal FILE_PATH CONST_NAME OUTPUT_PATH"
  let cfg : Config := {
    filePath   := ⟨args[0]!⟩,
    constName  := args[1]!.toName,
    outputPath := ⟨args[2]!⟩
  }
  IO.println s!"File:     {cfg.filePath}"
  IO.println s!"Constant: {cfg.constName}"
  IO.println s!"Output:   {cfg.outputPath}"
  return cfg

unsafe def processCommands : Frontend.FrontendM (List (Lean.Environment × InfoState)) := do
  let done ← Lean.Elab.Frontend.processCommand
  let st ← get
  let pair := (st.commandState.env, st.commandState.infoState)
  set { st with commandState := { st.commandState with infoState := {} } }
  if done then
    return [pair]
  else
    return pair :: (← processCommands)

unsafe def main (args : List String) : IO Unit := do
  let config ← parseArgs args.toArray
  Lean.initSearchPath (← Lean.findSysroot)
  Lean.enableInitializersExecution
  let input ← IO.FS.readFile config.filePath
  let inputCtx := Lean.Parser.mkInputContext input config.filePath.toString
  let (header, parserState, messages) ← Lean.Parser.parseHeader inputCtx
  let (env, messages) ← Lean.Elab.processHeader header {} messages inputCtx

  if messages.hasErrors then
    for msg in messages.toList do
      if msg.severity == .error then
        println! "ERROR: {← msg.toString}"
    throw <| IO.userError "Errors during import; aborting"

  let env := env.setMainModule (← Lean.moduleNameOfFileName config.filePath none)

  if env.contains config.constName then
    throw <| IO.userError s!"'{config.constName}' is already in the environment before processing"

  let commandState := { Lean.Elab.Command.mkState env messages {} with infoState.enabled := true }
  let (steps, _) ← (processCommands.run { inputCtx }).run
    { commandState, parserState, cmdPos := parserState.pos }

  -- Docstrings are IO-backed; fetch once up-front.
  let doc := (← Lean.findDocString? env config.constName).getD ""

  let fileMap := Lean.FileMap.ofString input
  for (env, s) in steps do
    if env.contains config.constName then
      for tree in s.trees do
        let ctx   : Core.Context := { fileName := config.filePath.toString, fileMap, options := {} }
        let state : Core.State   := { env }
        let ((parsed, _), _) ← ((BetterParser_Tree fileMap tree).run {} {}).toIO ctx state
        match parsed with
        | some r =>
          let ((enriched, _), _) ←
            ((enrichResult env config.constName r doc).run {} {}).toIO ctx state
          IO.FS.writeFile config.outputPath (Json.pretty (toJson enriched))
          IO.println s!"Saved enriched JSON to {config.outputPath}"
        | none   => IO.println "No proof tree found."
      break

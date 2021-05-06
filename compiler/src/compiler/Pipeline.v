Require Export Coq.Lists.List.
Require Import Coq.ZArith.ZArith.
Export ListNotations.
Require Export coqutil.Decidable.
Require        compiler.ExprImp.
Require Export compiler.FlattenExprDef.
Require Export compiler.FlattenExpr.
Require        compiler.FlatImp.
Require Export riscv.Spec.Machine.
Require Export riscv.Platform.Run.
Require Export riscv.Platform.RiscvMachine.
Require Export riscv.Platform.MetricLogging.
Require Export riscv.Utility.Monads.
Require Import riscv.Utility.runsToNonDet.
Require Export riscv.Platform.MetricRiscvMachine.
Require Import coqutil.Z.Lia.
Require Import compiler.NameGen.
Require Import compiler.StringNameGen.
Require Export compiler.util.Common.
Require Export coqutil.Decidable.
Require Export riscv.Utility.Encode.
Require Import riscv.Spec.Decode.
Require Export riscv.Spec.Primitives.
Require Export riscv.Spec.MetricPrimitives.
Require Import compiler.GoFlatToRiscv.
Require Import riscv.Utility.MkMachineWidth.
Require Export riscv.Proofs.DecodeEncode.
Require Export riscv.Proofs.EncodeBound.
Require Import riscv.Utility.Utility.
Require Export riscv.Platform.Memory.
Require Export riscv.Utility.InstructionCoercions.
Require Import compiler.SeparationLogic.
Require Import coqutil.Tactics.Simp.
Require Import compiler.FlattenExprSimulation.
Require Import compiler.Spilling.
Require Import compiler.RegRename.
Require Import compiler.FlatToRiscvSimulation.
Require Import compiler.Simulation.
Require Import compiler.RiscvEventLoop.
Require Coq.Init.Byte.
Require Import bedrock2.MetricLogging.
Require Import compiler.FlatToRiscvCommon.
Require Import compiler.FlatToRiscvFunctions.
Require Import compiler.DivisibleBy4.
Require Export coqutil.Word.SimplWordExpr.
Require Import compiler.ForeverSafe.
Require Export compiler.MemoryLayout.
Require Import FunctionalExtensionality.
Require Import coqutil.Tactics.autoforward.
Require Import compiler.FitsStack.
Import Utility.

Existing Instance riscv.Spec.Machine.DefaultRiscvState.

Open Scope Z_scope.

Section WithWordAndMem.
  Context {width: Z} {word: word.word width} {mem: map.map word byte}.

  (* bedrock2.ptsto_bytes.ptsto_bytes takes an n-tuple of bytes, whereas this one takes a list of bytes *)
  Definition ptsto_bytes: word -> list byte -> mem -> Prop := array ptsto (word.of_Z 1).

  Definition mem_available(start pastend: word) : mem -> Prop :=
    ex1 (fun anybytes: list byte =>
      emp (Z.of_nat (List.length anybytes) = word.unsigned (word.sub pastend start)) *
      (ptsto_bytes start anybytes))%sep.
End WithWordAndMem.

Module Import Pipeline.

  Class parameters := {
    W :> Words;
    mem :> map.map word byte;
    Registers :> map.map Z word;
    string_keyed_map :> forall T: Type, map.map string T; (* abstract T for better reusability *)
    trace := list (mem * string * list word * (mem * list word));
    ExtSpec := trace -> mem -> string -> list word -> (mem -> list word -> Prop) -> Prop;
    ext_spec : ExtSpec;
    compile_ext_call : string_keyed_map Z -> Z -> Z -> FlatImp.stmt Z -> list Instruction;
    M: Type -> Type;
    MM :> Monad M;
    RVM :> RiscvProgram M word;
    PRParams :> PrimitivesParams M MetricRiscvMachine;
  }.

  Instance FlatToRiscvDef_parameters{p: parameters}: FlatToRiscvDef.FlatToRiscvDef.parameters := {|
    iset := if Utility.width =? 32 then RV32I else RV64I;
    FlatToRiscvDef.FlatToRiscvDef.compile_ext_call := compile_ext_call;
  |}.

  Instance FlattenExpr_parameters{p: parameters}: FlattenExpr.parameters := {
    FlattenExpr.W := _;
    FlattenExpr.locals := _;
    FlattenExpr.mem := mem;
    FlattenExpr.ext_spec := ext_spec;
    FlattenExpr.NGstate := N;
  }.

  Instance FlatToRiscv_params{p: parameters}: FlatToRiscvCommon.parameters := {|
    FlatToRiscvCommon.ext_spec := ext_spec;
  |}.

  Class assumptions{p: parameters}: Prop := {
    word_riscv_ok :> RiscvWordProperties.word.riscv_ok word;
    string_keyed_map_ok :> forall T, map.ok (string_keyed_map T);
    Registers_ok :> map.ok Registers;
    PR :> MetricPrimitives PRParams;
    FlatToRiscv_hyps :> FlatToRiscvCommon.assumptions;
    ext_spec_ok :> Semantics.ext_spec.ok (FlattenExpr.mk_Semantics_params FlattenExpr_parameters);
    compile_ext_call_correct: forall resvars extcall argvars,
        compiles_FlatToRiscv_correctly
          compile_ext_call (FlatImp.SInteract resvars extcall argvars);
    compile_ext_call_length_ignores_positions: forall stackoffset posmap1 posmap2 c pos1 pos2,
      List.length (compile_ext_call posmap1 pos1 stackoffset c) =
      List.length (compile_ext_call posmap2 pos2 stackoffset c);
  }.

End Pipeline.

Section SIM.
  Context {Frame1 State1: Type}.
  Context (exec1: State1 -> (State1 -> Prop) -> Prop).
  Context {Frame2 State2: Type}.
  Context (exec2: State2 -> (State2 -> Prop) -> Prop).
  Context (states_related: Frame1 -> Frame2 -> State1 -> State2 -> Prop).

  Definition simulation f1 f2 :=
      forall (P1: State1 -> Prop) (P2: State2 -> Prop),
      (* read line below as "P2 must be implied by exists s1', states_related f1 f2 s1' s2' /\ P1 s1'"
         or as "if P1 says s1' is an acceptable final state, then P2 must accept all s2' related to s1'" *)
      (forall s1' s2', states_related f1 f2 s1' s2' -> P1 s1' -> P2 s2') ->
      forall s1 s2, states_related f1 f2 s1 s2 -> exec1 s1 P1 -> exec2 s2 P2.

  (* Note: The above could be simplified like this, but then P2 cannot be weakened and we need
     to carry around a separate hypothesis requiring weakening for language 2. *)
  Definition simulation_without_weakening f1 f2 := forall (P1: State1 -> Prop) s1 s2,
      states_related f1 f2 s1 s2 ->
      exec1 s1 P1 ->
      exec2 s2 (fun s2' => exists s1', states_related f1 f2 s1' s2' /\ P1 s1').

  Lemma simulation_alt: forall f1 f2, simulation f1 f2 -> simulation_without_weakening f1 f2.
  Proof. unfold simulation, simulation_without_weakening. eauto 10. Qed.

  Lemma simulation_alt_verboseproof: forall f1 f2, simulation f1 f2 -> simulation_without_weakening f1 f2.
  Proof.
    unfold simulation, simulation_without_weakening.
    intros *. intro Sim. intros. eapply Sim. 2,3: eassumption.
    clear. intros. eauto.
  Qed.

  Lemma simulation_alt':
    (forall (P2 P2': State2 -> Prop), (forall s2, P2 s2 -> P2' s2) -> forall s2, exec2 s2 P2 -> exec2 s2 P2') ->
    forall f1 f2, simulation_without_weakening f1 f2 -> simulation f1 f2.
  Proof.
    unfold simulation_without_weakening, simulation.
    intros W. intros *. intros Sim. intros.
    eapply W. 2: {
      eapply Sim. 1: eassumption. eassumption.
    }
    cbv beta.
    intros s (s1' & ? & ?).
    eauto.
  Qed.

End SIM.

Section COMPOSE.
  Context {Frame1 State1: Type}.
  Context (exec1: State1 -> (State1 -> Prop) -> Prop).
  Context {Frame2 State2: Type}.
  Context (exec2: State2 -> (State2 -> Prop) -> Prop).
  Context {Frame3 State3: Type}.
  Context (exec3: State3 -> (State3 -> Prop) -> Prop).
  Context (frelated12: Frame1 -> Frame2 -> Prop).
  Context (frelated23: Frame2 -> Frame3 -> Prop).
  Context (related12: Frame1 -> Frame2 -> State1 -> State2 -> Prop).
  Context (related23: Frame2 -> Frame3 -> State2 -> State3 -> Prop).

(*
  Definition compose_frelated: Frame1 -> Frame3 -> Prop :=
    fun f1 f3 => exists f2, frelated12 f1 f2 /\ frelated23 f2 f3.
*)

  Definition compose_related(f2: Frame2)(f1: Frame1)(f3: Frame3): State1 -> State3 -> Prop :=
    fun s1 s3 => exists s2, related12 f1 f2 s1 s2 /\ related23 f2 f3 s2 s3.

  Lemma compose_simulation
        (S12: forall f1 f2, frelated12 f1 f2 -> simulation exec1 exec2 related12 f1 f2)
        (S23: forall f2 f3, frelated23 f2 f3 -> simulation exec2 exec3 related23 f2 f3):
    forall f1 f3 f2, frelated12 f1 f2 -> frelated23 f2 f3 ->
    simulation exec1 exec3 (compose_related f2) f1 f3.
  Proof.
  Abort.
(* how to say that middle frame is still the same in post? above can, but makes simulation uncomposable
   previous approach didn't achieve that


each simulation holds under some assumptions about frames, and assuming intermediate frames exist
compose two simulations that live under assumptions, combining the list of assumptions?


forall (a1: A1) ... (an: An), A
forall (b1: B1) ... (bm: Bm), B

forall (a1: A1) ... (an: An)(b1: B1) ... (bm: Bm), compose A B

forall (a: {A1 * ... An | P}), A

real parameterization only needed in last phase

but previous phases might have target-language-state validity (and thus "related") depend on source program



    unfold simulation, compose_frelated, compose_related in *.
    intros f1 f3 (f2 & HF12 & HF23) P1 P3 P13 s1 s3 (f2 & s2 & HR12 & HR23) Ex1.
    eapply S23. 2: exact HR23. 2: {
      eapply S12 with (P2 := (fun s2' => exists s1', related12 f1 s1' f2 s2' /\ P1 s1')).
      2: exact HR12. 2: exact Ex1. eauto. }
    intros s2' s3' HR23' (s1' & HR12' & p1). eauto.
  Qed.

*)

(* simulation  nil/cons ? *)

End COMPOSE.

Arguments compose_simulation {_} {_} {_} {_} {_} {_} {_} {_} {_} {_} {_}.

Section Pipeline1.

  Context {p: parameters}.
  Context {h: assumptions}.

  Add Ring wring : (word.ring_theory (word := word))
      (preprocess [autorewrite with rew_word_morphism],
       morphism (word.ring_morph (word := word)),
       constants [word_cst]).

  Instance mk_FlatImp_ext_spec_ok:
    FlatImp.ext_spec.ok  string (FlattenExpr.mk_FlatImp_params FlattenExpr_parameters).
  Proof.
    destruct h. destruct ext_spec_ok0.
    constructor.
    all: intros; eauto.
    eapply intersect; eassumption.
  Qed.

  Instance FlattenExpr_hyps: FlattenExpr.assumptions FlattenExpr_parameters.
  Proof.
    constructor.
    - apply (string_keyed_map_ok (p := p) (@word (@FlattenExpr.W (@FlattenExpr_parameters p)))).
    - exact mem_ok.
    - apply (string_keyed_map_ok (p := p) (list string * list string * Syntax.cmd.cmd)).
    - apply (string_keyed_map_ok (p := p) (list string * list string * FlatImp.stmt string)).
    - apply mk_FlatImp_ext_spec_ok.
  Qed.

  Local Notation source_env := (@string_keyed_map p (list string * list string * Syntax.cmd)).
  Local Notation flat_env := (@string_keyed_map p (list string * list string * FlatImp.stmt string)).
  Local Notation renamed_env := (@string_keyed_map p (list Z * list Z * FlatImp.stmt Z)).

  Definition flattenPhase(prog: source_env): option flat_env := flatten_functions prog.
  Definition renamePhase(prog: flat_env): option renamed_env :=
    rename_functions prog.
  Definition spillingPhase(prog: renamed_env): option renamed_env := Some (spill_functions prog).

  (* Note: we could also track code size from the source program all the way to the target
     program, and a lot of infrastructure is already there, will do once/if we want to get
     a total compiler.
     Returns the fun_pos_env so that users know where to jump to call the compiled functions. *)
  Definition riscvPhase(prog: renamed_env):
    option (list Instruction * funname_env Z * Z) :=
    bind_opt stack_words_needed <- stack_usage prog;
    let positions := FlatToRiscvDef.build_fun_pos_env prog in
    let '(i, _) := FlatToRiscvDef.compile_funs positions prog in
    Some (i, positions, stack_words_needed).

  Definition composePhases{A B C: Type}(phase1: A -> option B)(phase2: B -> option C)(a: A) :=
    match phase1 a with
    | Some b => phase2 b
    | None => None
    end.

  Definition composed_compile: source_env -> option (list Instruction * funname_env Z * Z) :=
    (composePhases flattenPhase
    (composePhases renamePhase
    (composePhases spillingPhase
                   riscvPhase))).

  Definition FlatState(varname: Type){pp : FlatImp.parameters varname}: Type :=
    FlatImp.env * FlatImp.stmt varname * bool * FlatImp.trace * FlatImp.mem * FlatImp.locals * MetricLog.

  Definition flatExec{varname: Type}{pp : FlatImp.parameters varname}:
    FlatState varname -> (FlatState varname -> Prop) -> Prop :=
    fun '(e, s, done, t, m, l, mc) post =>
      done = false /\
      FlatImp.exec e s t m l mc (fun t' m' l' mc' => post (e, s, true, t', m', l', mc')).

  (* Note: contrary to GhostConsts, this record only contains risc-v-related types, no FlatImp-related types *)
  Record RiscvFrame: Type := {
    addr_functions: word;
    insts_functions: list Instruction;
    addr_snippet: word;
    insts_snippet: list Instruction;
    stack_start: word;
    stack_pastend: word;
    xframe: mem -> Prop;
    dframe: mem -> Prop;
  }.

  Definition satisfiesRiscvFrame(done: bool)(f: RiscvFrame)(mach: MetricRiscvMachine): Prop :=
      (program iset f.(addr_functions) f.(insts_functions) *
       program iset f.(addr_snippet) f.(insts_snippet) *
       mem_available f.(stack_start) f.(stack_pastend) *
       f.(dframe) * f.(xframe)
      )%sep mach.(getMem) /\
      subset (footpr (program iset f.(addr_functions) f.(insts_functions) *
                      program iset f.(addr_snippet) f.(insts_snippet) *
                      f.(xframe))%sep)
             (of_list (getXAddrs mach)) /\
      word.unsigned (mach.(getPc)) mod 4 = 0 /\
      mach.(getPc) = (if done
                      then word.add f.(addr_snippet) (word.of_Z (4 * Z.of_nat (length f.(insts_snippet))))
                      else f.(addr_snippet)) /\
      mach.(getNextPc) = word.add mach.(getPc) (word.of_Z 4) /\
      regs_initialized mach.(getRegs) /\
      map.get mach.(getRegs) RegisterNames.sp = Some f.(stack_pastend) /\
      (* configured by PrimitivesParams, can contain invariants needed for external calls *)
      valid_machine mach.

  Definition flat_related_to_riscv
             (frame1: @FlatImp.env Z _ * FlatImp.stmt Z)(s1: FlatState Z)
             (frame2: RiscvFrame)(s2: MetricRiscvMachine): Prop :=
    let '(e, c, done, t, m, l, mc) := s1 in
    frame1 = (e, c) /\
    map.extends s2.(getRegs) l /\
    s2.(getLog) = t /\
    fits_stack 0 (word.unsigned (word.sub frame2.(stack_pastend) frame2.(stack_start))) e c /\
    FlatToRiscvDef.stmt_not_too_big c /\
    FlatToRiscvDef.valid_FlatImp_vars c /\
    let relpos := (word.unsigned (word.sub frame2.(addr_snippet) frame2.(addr_functions))) in
    let e_pos := FlatToRiscvDef.build_fun_pos_env e in
    fst (FlatToRiscvDef.compile_funs e_pos e) = frame2.(insts_functions) /\
    FlatToRiscvDef.compile_stmt e_pos relpos 0 c = frame2.(insts_snippet) /\
    satisfiesRiscvFrame done frame2 s2 /\
    good_e_impl e e_pos.

  Axiom TODO: False.

(*
  Lemma flatToRiscvSim: simulation flatExec FlatToRiscvCommon.runsTo flat_related_to_riscv.
  Proof.
    unfold simulation, flatExec, FlatState, FlatImp.SimExec, flat_related_to_riscv.
    intros.
    destruct s1 as ((((((e & c) & done) & t) & m) & l) & mc).
    destruct_RiscvMachine s2.
    simp.
    eapply runsTo_weaken.
    - specialize compile_stmt_correct with (1 := @compile_ext_call_correct _ h).
      unfold compiles_FlatToRiscv_correctly. intros compile_stmt_correct.
      eapply compile_stmt_correct.  all: case TODO. with (g := f2); clear compile_stmt_correct; simpl.
      + eassumption.
      + clear. intros k v ?. eassumption.
      + assumption.
      + eauto using fits_stack_call.
      + eassumption.
      + eassumption.
      + eassumption.
      + assert (word.ok word) by exact Utility.word_ok.
        solve_divisibleBy4.
        case TODO.
      + assert (word.ok word) by exact Utility.word_ok.
        solve_divisibleBy4.
        case TODO.
      + (* TODO why are these manual steps needed? *)
        case TODO.
      + assert (word.ok word) by exact Utility.word_ok.
        case TODO.
      + assumption.
    - simpl. intros. simp.
      eapply H. 2: eassumption.
      cbv beta iota.
      repeat match goal with
             | |- _ /\ _ => split
             | _ => eassumption
             | _ => reflexivity
             end.

      Unshelve. all: case TODO.
    - case TODO.
  Qed.
*)

  Definition spilling_related
             (frame1: @FlatImp.env Z _ * FlatImp.stmt Z)(s1: FlatState Z)
             (frame2: @FlatImp.env Z _ * FlatImp.stmt Z)(s2: FlatState Z) :=
    let '(e1, c1, done1, t1, m1, l1, mc1) := s1 in
    let '(e2, c2, done2, t2, m2, l2, mc2) := s2 in
    frame1 = (e1, c1) /\
    frame2 = (e2, c2) /\
    done1 = done2 /\
    c2 = spill_stmt c1 /\
    exists maxvar (fpval: word),
      Spilling.envs_related e1 e2 /\
      Spilling.valid_vars_src maxvar c1 /\
      Spilling.related ext_spec maxvar (emp True) fpval t1 m1 l1 t2 m2 l2.

  Lemma spilling_sim: simulation flatExec flatExec spilling_related.
  Proof.
    unfold simulation, flatExec, spilling_related. intros f1 f2 P1 P2 R.
    intros ((((((e1 & c1) & done1) & t1) & m1) & l1) & mc1) ((((((e2 & c2) & done2) & t2) & m2) & l2) & mc2).
    intros. simp. split; [reflexivity|].
    eapply FlatImp.exec.weaken.
    - eapply spilling_correct; eassumption.
    - cbv beta. intros. simp. eapply R. 2: eassumption. simpl.
      eauto 10.
  Qed.

  Definition renaming_related
             (frame1: @FlatImp.env string _ * FlatImp.stmt string)(s1: FlatState string)
             (frame2: @FlatImp.env Z _ * FlatImp.stmt Z)(s2: FlatState Z) :=
    let '(e1, c1, done1, t1, m1, l1, mc1) := s1 in
    let '(e2, c2, done2, t2, m2, l2, mc2) := s2 in
    frame1 = (e1, c1) /\
    frame2 = (e2, c2) /\
    done1 = done2 /\
    RegRename.envs_related e1 e2 /\
    (exists r' av', RegRename.rename map.empty c1 lowest_available_impvar = Some (r', c2, av')) /\
    t1 = t2 /\
    m1 = m2 /\
    (done1 = false -> l1 = map.empty /\ l2 = map.empty /\ mc1 = mc2).

  Lemma renaming_sim: simulation flatExec flatExec renaming_related.
  Proof.
    unfold simulation, flatExec, renaming_related. intros f1 f2 P1 P2 R.
    intros ((((((e1 & c1) & done1) & t1) & m1) & l1) & mc1) ((((((e2 & c2) & done2) & t2) & m2) & l2) & mc2).
    intros. simp. split; [reflexivity|]. specialize (Hp3 eq_refl). simp.
    pose proof Hp1 as A.
    apply rename_props in A;
      [|eapply map.empty_injective|eapply dom_bound_empty].
    simp.
    eapply FlatImp.exec.weaken.
    - eapply rename_correct.
      1: eassumption.
      1: eassumption.
      3: {
        eapply Ap2. eapply TestLemmas.extends_refl.
      }
      1: eassumption.
      1: eassumption.
      unfold states_compat. intros *. intro B.
      erewrite map.get_empty in B. discriminate.
    - simpl. intros. simp.
      eapply R. 2: eassumption. simpl. clear R. intuition (discriminate || eauto).
  Qed.

  Definition SrcState: Type :=
    Semantics.env * Syntax.cmd * bool * Semantics.trace * Semantics.mem * Semantics.locals * MetricLog.

  Definition srcExec: SrcState -> (SrcState -> Prop) -> Prop :=
    fun '(e, c, done, t, m, l, mc) post =>
      done = false /\
      Semantics.exec e c t m l mc (fun t' m' l' mc' => post (e, c, true, t', m', l', mc')).

  Definition flattening_related
             (frame1: Semantics.env * Syntax.cmd)(s1: SrcState)
             (frame2: @FlatImp.env string _ * FlatImp.stmt string)(s2: FlatState string) :=
    let '(e1, c1, done1, t1, m1, l1, mc1) := s1 in
    let '(e2, c2, done2, t2, m2, l2, mc2) := s2 in
    frame1 = (e1, c1) /\
    frame2 = (e2, c2) /\
    done1 = done2 /\
    ExprImp2FlatImp c1 = c2 /\
    flatten_functions e1 = Some e2 /\
    t1 = t2 /\
    m1 = m2 /\
    (done1 = false -> l1 = map.empty /\ l2 = map.empty /\ mc1 = mc2).

  Lemma flattening_sim: simulation srcExec flatExec flattening_related.
  Proof.
    unfold simulation, srcExec, flatExec, flattening_related, ExprImp2FlatImp. intros f1 f2 P1 P2 R.
    intros ((((((e1 & c1) & done1) & t1) & m1) & l1) & mc1) ((((((e2 & c2) & done2) & t2) & m2) & l2) & mc2).
    intros. simp. split; [reflexivity|]. specialize (Hp2 eq_refl). simp.
    eapply FlatImp.exec.weaken.
    - eapply @flattenStmt_correct_aux with (eH := e1).
      + typeclasses eauto.
      + eassumption.
      + eassumption.
      + reflexivity.
      + match goal with
        | |- ?p = _ => rewrite (surjective_pairing p)
        end.
        reflexivity.
      + intros x k A. rewrite map.get_empty in A. discriminate.
      + unfold map.undef_on, map.agree_on. intros. reflexivity.
      + eapply freshNameGenState_disjoint.
    - simpl. intros. simp. eapply R. 2: eassumption. simpl. intuition (discriminate || eauto).
  Qed.

  Definition related: Semantics.env * Syntax.cmd -> SrcState -> RiscvFrame -> MetricRiscvMachine -> Prop :=
    (compose_related flattening_related
    (compose_related renaming_related
    (compose_related spilling_related
                     flat_related_to_riscv))).

  Lemma sim: simulation srcExec FlatToRiscvCommon.runsTo related.
  Proof.
    exact (compose_simulation flattening_sim
          (compose_simulation renaming_sim
          (compose_simulation spilling_sim
                              flatToRiscvSim))).
  Qed.

  Lemma rename_fun_valid: forall argnames retnames body impl',
      rename_fun (argnames, retnames, body) = Some impl' ->
      NoDup argnames ->
      NoDup retnames ->
      FlatImp.stmt_size body < 2 ^ 10 ->
      FlatToRiscvDef.valid_FlatImp_fun impl'.
  Proof.
    unfold rename_fun, FlatToRiscvDef.valid_FlatImp_fun.
    intros.
    simp.
    eapply rename_binds_props in E; cycle 1.
    { eapply map.empty_injective. }
    { eapply dom_bound_empty. }
    simp.
    eapply rename_binds_props in E0; cycle 1.
    { assumption. }
    { assumption. }
    simp.
    pose proof E1 as E1'.
    eapply rename_props in E1; cycle 1.
    { assumption. }
    { assumption. }
    simp.
    set (lowest_nonregister := 32).
    assert (Z.leb z1 lowest_nonregister = true) as E2 by case TODO.
    ssplit.
    - eapply Forall_impl. 2: {
        eapply map.getmany_of_list_in_map. eassumption.
      }
      simpl.
      intros. simp.
      match goal with
      | X: _ |- _ => specialize X with (1 := H); rename X into A
      end.
      destruct A as [A | A].
      + apply Zle_bool_imp_le in E2.
        unfold FlatToRiscvDef.valid_FlatImp_var, lowest_available_impvar, lowest_nonregister in *.
        blia.
      + rewrite map.get_empty in A. discriminate A.
    - eapply Forall_impl. 2: {
        eapply map.getmany_of_list_in_map. eassumption.
      }
      simpl.
      intros. simp.
      match goal with
      | X: _ |- _ => specialize X with (1 := H); rename X into A
      end.
      destruct A as [A | A].
      + apply Zle_bool_imp_le in E2.
        unfold FlatToRiscvDef.valid_FlatImp_var, lowest_available_impvar, lowest_nonregister in *.
        blia.
      + match goal with
        | X: _ |- _ => specialize X with (1 := A); rename X into B
        end.
        destruct B as [B | B].
        * apply Zle_bool_imp_le in E2.
          unfold FlatToRiscvDef.valid_FlatImp_var, lowest_available_impvar, lowest_nonregister in *.
          blia.
        * rewrite map.get_empty in B. discriminate B.
    - eapply FlatImp.ForallVars_stmt_impl; [|eassumption].
      simpl. intros. simp.
      match goal with
      | X: _ |- _ => specialize X with (1 := H); rename X into A
      end.
      destruct A as [A | A].
      + apply Zle_bool_imp_le in E2.
        unfold FlatToRiscvDef.valid_FlatImp_var, lowest_available_impvar, lowest_nonregister in *.
        blia.
      + match goal with
        | X: _ |- _ => specialize X with (1 := A); rename X into B
        end.
        destruct B as [B | B].
        * apply Zle_bool_imp_le in E2.
          unfold FlatToRiscvDef.valid_FlatImp_var, lowest_available_impvar, lowest_nonregister in *.
          blia.
        * match goal with
          | X: _ |- _ => specialize X with (1 := B); rename X into C
          end.
          destruct C as [C | C].
          -- apply Zle_bool_imp_le in E2.
             unfold FlatToRiscvDef.valid_FlatImp_var, lowest_available_impvar, lowest_nonregister in *.
             blia.
          -- rewrite map.get_empty in C. discriminate C.
    - eapply map.getmany_of_list_injective_NoDup. 3: eassumption. all: eassumption.
    - eapply map.getmany_of_list_injective_NoDup. 3: eassumption. all: eassumption.
    - unfold FlatToRiscvDef.stmt_not_too_big.
      pose proof (rename_preserves_stmt_size _ _ _ _ _ _ E1') as M.
      rewrite <- M.
      assumption.
  Qed.

  Local Instance map_ok': @map.ok (@word (@W p)) Init.Byte.byte (@mem p) := mem_ok.

  Lemma get_build_fun_pos_env: forall e f,
      map.get e f <> None ->
      exists pos, map.get (FlatToRiscvDef.build_fun_pos_env e) f = Some pos.
  Proof.
    intros pos0 e.
    unfold FlatToRiscvDef.build_fun_pos_env, FlatToRiscvDef.compile_funs.
    eapply map.fold_spec.
    - intros. rewrite map.get_empty in H. congruence.
    - intros. destruct r as [ insts env]. simpl.
      rewrite map.get_put_dec in H1.
      rewrite map.get_put_dec.
      destruct_one_match; eauto.
  Qed.

  Local Definition FlatImp__word_eq : FlatImp.word -> FlatImp.word -> bool := word.eqb.
  Local Instance  EqDecider_FlatImp__word_eq : EqDecider FlatImp__word_eq.
  Proof. eapply word.eqb_spec. Unshelve. exact word_ok. Qed.

  Lemma mem_available_to_exists: forall start pastend m P,
      (mem_available start pastend * P)%sep m ->
      exists anybytes,
        Z.of_nat (List.length anybytes) = word.unsigned (word.sub pastend start) /\
        (ptsto_bytes start anybytes * P)%sep m.
  Proof.
    unfold mem_available. intros * H.
    eapply sep_ex1_l in H. (* semicolon here fails *) destruct H.
    eapply sep_assoc in H.
    eapply sep_emp_l in H. destruct H.
    eauto.
  Qed.

  Definition mem_to_available: forall start pastend m P anybytes,
     Z.of_nat (List.length anybytes) = word.unsigned (word.sub pastend start) ->
     (ptsto_bytes start anybytes * P)%sep m ->
     (mem_available start pastend * P)%sep m.
  Proof.
    unfold mem_available. intros * H Hsep.
    eapply sep_ex1_l. eexists. eapply sep_assoc. eapply sep_emp_l. eauto.
  Qed.

  Lemma get_compile_funs_pos: forall e,
      let '(insts, posmap) := FlatToRiscvDef.compile_funs map.empty e in
      forall f impl, map.get e f = Some impl -> exists pos2, map.get posmap f = Some pos2 /\ pos2 mod 4 = 0.
  Proof.
    intros e.
    unfold FlatToRiscvDef.compile_funs.
    eapply map.fold_spec.
    - intros. rewrite map.get_empty in H. congruence.
    - intros. destruct r as [ insts env]. simpl.
      intros.
      rewrite map.get_put_dec in H1.
      rewrite map.get_put_dec.
      destruct_one_match; eauto.
      eexists. split; [reflexivity|].
      solve_divisibleBy4.
  Qed.

  Lemma mod_2width_mod_bytes_per_word: forall x,
      (x mod 2 ^ width) mod bytes_per_word = x mod bytes_per_word.
  Proof.
    intros.
    rewrite <- Znumtheory.Zmod_div_mod.
    - reflexivity.
    - unfold bytes_per_word. destruct width_cases as [E | E]; rewrite E; reflexivity.
    - destruct width_cases as [E | E]; rewrite E; reflexivity.
    - unfold Z.divide.
      exists (2 ^ width / bytes_per_word).
      unfold bytes_per_word, Memory.bytes_per_word.
      destruct width_cases as [E | E]; rewrite E; reflexivity.
  Qed.

  Lemma stack_length_divisible: forall (ml: MemoryLayout) {mlOk: MemoryLayoutOk ml},
    word.unsigned (word.sub (MemoryLayout.stack_pastend ml) (MemoryLayout.stack_start ml)) mod bytes_per_word = 0.
  Proof.
    intros.
    destruct mlOk.
    rewrite word.unsigned_sub. unfold word.wrap.
    rewrite mod_2width_mod_bytes_per_word.
    rewrite Zminus_mod.
    rewrite stack_start_aligned.
    rewrite stack_pastend_aligned.
    rewrite Z.sub_diag.
    apply Zmod_0_l.
  Qed.

  Lemma program_mod_4_0: forall a instrs R m,
      instrs <> [] ->
      (program iset a instrs * R)%sep m ->
      word.unsigned a mod 4 = 0.
  Proof.
    intros.
    destruct instrs as [|instr instrs]. 1: congruence.
    simpl in *.
    unfold sep, ptsto_instr, sep, emp in *.
    simp.
    assumption.
  Qed.

  Lemma compile_funs_nonnil: forall e positions positions' f impl instrs,
      map.get e f = Some impl ->
      FlatToRiscvDef.compile_funs positions e = (instrs, positions') ->
      instrs <> [].
  Proof.
    intros e positions.
    unfold FlatToRiscvDef.compile_funs.
    eapply map.fold_spec; intros.
    - rewrite map.get_empty in H.
      discriminate.
    - rewrite map.get_put_dec in H1.
      destr (k =? f)%string.
      + subst.
        unfold FlatToRiscvDef.add_compiled_function in H2. simp.
        unfold FlatToRiscvDef.compile_function.
        destruct impl as [ [args res] body ].
        intro C. destruct l; discriminate.
      + specialize H0 with (1 := H1).
        destruct r as [ instrs'' positions'' ].
        specialize H0 with (1 := eq_refl).
        intro C. subst instrs.
        unfold FlatToRiscvDef.add_compiled_function in H2. simp.
        unfold FlatToRiscvDef.compile_function in *.
        destruct v as [ [args res] body ].
        destruct instrs''; discriminate.
  Qed.

  Ltac ignore_positions :=
    repeat match goal with
           | |- _ => reflexivity
           | |- _ => rewrite !List.app_length
           | |- _ => solve [eauto]
           | |- _ => progress simpl
           | |- S _ = S _ => f_equal
           | |- (_ + _)%nat = (_ + _)%nat => f_equal
           end.

  Lemma compile_stmt_length_ignores_positions: forall posmap1 posmap2 c stackoffset pos1 pos2,
      List.length (FlatToRiscvDef.compile_stmt posmap1 pos1 stackoffset c) =
      List.length (FlatToRiscvDef.compile_stmt posmap2 pos2 stackoffset c).
  Proof.
    induction c; intros; ignore_positions.
    apply compile_ext_call_length_ignores_positions.
  Qed.

  Lemma compile_function_length_ignores_positions: forall posmap1 posmap2 pos1 pos2 impl,
      List.length (FlatToRiscvDef.compile_function posmap1 pos1 impl) =
      List.length (FlatToRiscvDef.compile_function posmap2 pos2 impl).
  Proof.
    intros. destruct impl as [ [args rets] body ]. ignore_positions.
    apply compile_stmt_length_ignores_positions.
  Qed.

  Lemma build_fun_pos_env_ignores_posmap_aux: forall posmap1 posmap2 e i1 m1 i2 m2,
      map.fold (FlatToRiscvDef.add_compiled_function posmap1) ([], map.empty) e = (i1, m1) ->
      map.fold (FlatToRiscvDef.add_compiled_function posmap2) ([], map.empty) e = (i2, m2) ->
      m1 = m2 /\ List.length i1 = List.length i2.
  Proof.
    intros until e.
    eapply map.fold_parametricity with (fa := (FlatToRiscvDef.add_compiled_function posmap1))
                                       (fb := (FlatToRiscvDef.add_compiled_function posmap2));
      intros.
    - destruct a as [insts1 map1]. destruct b as [insts2 map2].
      unfold FlatToRiscvDef.add_compiled_function in *.
      inversion H0. inversion H1. subst. clear H0 H1.
      specialize H with (1 := eq_refl) (2 := eq_refl). destruct H.
      rewrite ?H0. subst.
      split. 1: reflexivity.
      ignore_positions.
      apply compile_function_length_ignores_positions.
    - inversion H. inversion H0. subst. auto.
  Qed.

  Lemma build_fun_pos_env_ignores_posmap: forall posmap1 posmap2 e,
      snd (map.fold (FlatToRiscvDef.add_compiled_function posmap1) ([], map.empty) e) =
      snd (map.fold (FlatToRiscvDef.add_compiled_function posmap2) ([], map.empty) e).
  Proof.
    intros.
    destr (map.fold (FlatToRiscvDef.add_compiled_function posmap1) ([], map.empty) e).
    destr (map.fold (FlatToRiscvDef.add_compiled_function posmap2) ([], map.empty) e).
    simpl.
    edestruct build_fun_pos_env_ignores_posmap_aux.
    - exact E.
    - exact E0.
    - assumption.
  Qed.

  (* This lemma should relate two map.folds which fold two different f over the same env e:
     1) FlatToRiscvDef.compile_funs, which folds FlatToRiscvDef.add_compiled_function.
        Note that this one is called twice: First in build_fun_pos_env, and then in
        compile_funs, and we rely on the order being the same both times.
     2) functions, which folds sep
     Note that 1) is not commutative (the iteration order determines in which order code
     is layed out in memory), while 2) should be commutative because the "function"
     separation logic predicate it seps onto the separation logic formula is the same
     if we pass it the same function position map. *)
  Lemma functions_to_program: forall functions_start e instrs pos_map stack_size,
      riscvPhase e = Some (instrs, pos_map, stack_size) ->
      iff1 (program iset functions_start instrs)
           (FlatToRiscvCommon.functions functions_start (FlatToRiscvDef.build_fun_pos_env e) e).
  Proof.
    (* PARAMRECORDS *)
    assert (map.ok FlatImp.env). { unfold FlatImp.env. simpl. typeclasses eauto. }
    assert (map.ok mem) as Ok by exact mem_ok.

    unfold riscvPhase.
    intros.
    simp.
    unfold FlatToRiscvDef.compile_funs, functions in *.
    remember (FlatToRiscvDef.build_fun_pos_env e) as positions.
    (* choose your IH carefully! *)
    lazymatch goal with
    | |- ?G => enough ((forall f, map.get r f <> None <-> map.get e f <> None) /\
                       ((forall f pos, map.get r f = Some pos -> map.get positions f = Some pos) -> G))
    end.
    1: {
      destruct H0. apply H1; clear H1.
      intros. rewrite <- H1. f_equal.
      subst.
      apply (f_equal snd) in E0. simpl in E0. rewrite <- E0.
      transitivity (snd (map.fold (FlatToRiscvDef.add_compiled_function map.empty) ([], map.empty) e)).
      - unfold FlatToRiscvDef.build_fun_pos_env, snd. reflexivity.
      - apply build_fun_pos_env_ignores_posmap.
    }
    revert E0.
    revert instrs r. clear E stack_size.
    eapply (map.fold_spec (R:=(list Instruction * _))) with (m:=e); repeat (cbn || simp || intros).
    { rewrite map.fold_empty. intuition try reflexivity.
      - eapply H0. eapply map.get_empty.
      - eapply H0. eapply map.get_empty.
    }
    rewrite map.fold_put; trivial.
    2: { intros.
      eapply functional_extensionality_dep; intros x.
      eapply PropExtensionality.propositional_extensionality; revert x.
      match goal with |- forall x, ?P x <-> ?Q x => change (iff1 P Q) end.
      cancel. }
    case r as (instrs'&r').
    specialize H1 with (1 := eq_refl).
    unfold FlatToRiscvDef.add_compiled_function in E0.
    injection E0; clear E0; intros. subst.
    unfold program in *.
    wseplog_pre.
    destruct H1.
    split. {
      intros. rewrite ?map.get_put_dec.
      destr (k =? f)%string. 2: eauto. intuition discriminate.
    }
    intros.
    rewrite H2. 2: {
      intros.
      eapply H3.
      rewrite map.get_put_dec.
      destr (k =? f)%string. 2: assumption.
      subst. exfalso.
      specialize (H1 f). unfold not in H1. rewrite H0 in H1. rewrite H4 in H1.
      intuition congruence.
    }
    cancel.
    unfold function.
    specialize (H3 k).
    rewrite map.get_put_same in H3.
    specialize H3 with (1 := eq_refl).
    simpl in *. rewrite H3.
    cancel.
    unfold program.
    cancel_seps_at_indices 0%nat 0%nat. 2: reflexivity.
    f_equal.
    f_equal.
    solve_word_eq word_ok.
  Qed.

  Open Scope ilist_scope.

  Definition machine_ok(p_functions: word)(f_entry_rel_pos: Z)(stack_start stack_pastend: word)
             (finstrs: list Instruction)
             (p_call pc: word)(mH: mem)(Rdata Rexec: mem -> Prop)(mach: MetricRiscvMachine): Prop :=
      let CallInst := Jal RegisterNames.ra
                          (f_entry_rel_pos + word.signed (word.sub p_functions p_call)) : Instruction in
      (program iset p_functions finstrs *
       program iset p_call [CallInst] *
       mem_available stack_start stack_pastend *
       Rdata * Rexec * eq mH
      )%sep mach.(getMem) /\
      subset (footpr (program iset p_functions finstrs *
                      program iset p_call [CallInst] *
                      Rexec)%sep)
             (of_list (getXAddrs mach)) /\
      word.unsigned (mach.(getPc)) mod 4 = 0 /\
      mach.(getPc) = pc /\
      mach.(getNextPc) = word.add mach.(getPc) (word.of_Z 4) /\
      regs_initialized mach.(getRegs) /\
      map.get mach.(getRegs) RegisterNames.sp = Some stack_pastend /\
      (* configured by PrimitivesParams, can contain invariants needed for external calls *)
      valid_machine mach.

  (* handwritten "related" (rather than composition of all phases), and restricted to
     argument-less function calls (compiling general snippets need more context for
     FlatToRiscv, namely function positions) and thus simpler *)
  Definition manual_related(f1: Semantics.env * Syntax.cmd.cmd)(s1: SrcState)
                           (f2: GhostConsts)(mach: MetricRiscvMachine): Prop :=
    let '(functions, c) := f1 in
    let '(functions', c', done, t, mH, lH, mcH) := s1 in
    functions' = functions /\
    c' = c /\
    mach.(getLog) = t /\
    (done = false -> lH = map.empty) /\
    exists f_entry_name f_entry_rel_pos (finstrs: list Instruction) stack_start stack_words_needed,
      c = Syntax.cmd.call [] f_entry_name [] /\
      ExprImp.valid_funs functions /\
      composed_compile functions = Some (finstrs, f2.(e_pos), stack_words_needed) /\
      map.get f2.(e_pos) f_entry_name = Some f_entry_rel_pos /\
      machine_ok f2.(program_base) f_entry_rel_pos
                 stack_start f2.(p_sp) finstrs
                 f2.(p_insts) (if done then (word.add f2.(p_insts) (word.of_Z 4)) else f2.(p_insts))
                 mH f2.(FlatToRisc... ? dframe) f2.(xframe) mach /\
      f2.(rem_stackwords) = word.unsigned (word.sub f2.(p_sp) stack_start) /\
      f2.(rem_framewords) = 0 /\
      stack_words_needed <= f2.(rem_stackwords) / bytes_per_word /\
      f2.(insts) = [[Jal RegisterNames.ra
                         (f_entry_rel_pos + word.signed (word.sub f2.(program_base) f2.(p_insts)))]].

manual_related new?

  Ltac sim'_destructible T :=
    lazymatch T with
    | prod _ _ => idtac
    | SrcState => idtac
    | FlatState _ => idtac
    | GhostConsts => idtac
    end.

  Lemma rename_functions_related: forall e1 e2,
    rename_functions e1 = Some e2 ->
    RegRename.envs_related e1 e2.
  Proof.
    intros.
    unfold envs_related.
    intros f [ [argnames resnames] body1 ] G.
    unfold rename_functions in *.
    eapply map.map_all_values_fw.
    5: exact G. 4: eassumption.
    - eapply String.eqb_spec.
    - typeclasses eauto.
    - typeclasses eauto.
  Qed.

  Create HintDb simpl_related.
  Hint Resolve rename_functions_related : simpl_related.


  (* Some compilation phases establish some kind of "validFrame" for the target language,
     eg spilling guarantees that all register names are <32 *, and these "validFrame"
     conditions are then needed by the next phase's "related".
     (making "validFrame" a distinct concept might be overkill, and not work so well for
     risc-v because it would need the high-level memory as well to split the memory).
     Filling in the intermediate existentials created by compose_related and showing that
     the compilation of phase i respects the "validFrame" conditions of phase i+1 is the
     purpose of this proof. *)

  (* where to go from "compile hl = ll" to "envs_related hl ll"?
     ideally in each phase simulation, rather than after the composition *)

  Lemma sim': simulation srcExec runsTo manual_related.
  Proof.
    eapply specialize_simulation_frames. 3: eapply sim.
    - unfold related, compose_related.
      unfold flattening_related, renaming_related, spilling_related, flat_related_to_riscv.
      unfold manual_related, machine_ok, goodMachine.
      unfold composed_compile, composePhases.
      unfold flattenPhase, renamePhase, spillingPhase, riscvPhase.

Ltac step := match goal with
             | x: ?T |- _ => sim'_destructible T; destruct x
             | |- forall _, _ => intros
             | |- _ => progress (cbn in *; simp)
             | |- exists x: ?T, _ =>
               let y := fresh x in unshelve epose (_: T) as y;
               [ repeat lazymatch goal with
                        | |- ?T => sim'_destructible T; econstructor
                        end;
                 shelve
               | exists y; subst y ]
             | |- _ /\ _ => split
           (*| |- ?G => assert_fails (has_evar G); reflexivity*)
             | |- ?G => reflexivity
             | |- _ => eauto 3 with simpl_related
             end.

      repeat step.


      {

Search r3.

(* problem with GhostConsts: contains e_impl, which is a concept from FlatImp, can't easily
   be derived by looking at RiscvMachine state (would need to decompile) *)

  E2 : FlatToRiscvDef.compile_funs (FlatToRiscvDef.build_fun_pos_env (spill_functions r3))
         (spill_functions r3) = (finstrs, r4)

spill_functions r3 = e_impl   ?


Set Ltac Profiling.

Set Nested Lemmas.


E0: rename_functions r1 = Some r3


      Search r1.

Show Ltac Profile.

total time:     32.688s

 tactic                                   local  total   calls       max
────────────────────────────────────────┴──────┴──────┴───────┴─────────┘
─step ----------------------------------  99.8% 100.0%     326   11.103s
─simp ----------------------------------   0.0%  96.8%     228   11.085s
─simp_step -----------------------------   0.1%  96.7%     153    0.577s
─destruct_unique_match -----------------  71.2%  71.2%    2271    0.383s
─destruct e eqn:N ----------------------  37.6%  37.6%     620    0.057s
─unique_inversion ----------------------  25.4%  25.4%    4647    0.253s
─protect_equalities --------------------   8.1%  16.8%    4333    0.015s
─congruence ----------------------------  13.2%  13.2%    1508    0.018s
─change_no_check (protected (a = b)) in    8.7%   8.7%   19512    0.011s
─elimtype ------------------------------   7.3%   7.3%    3021    0.014s
─discriminate --------------------------   5.7%   5.7%    1513    0.015s
─destruct e ----------------------------   4.8%   4.8%     137    0.036s

 tactic                                   local  total   calls       max
────────────────────────────────────────┴──────┴──────┴───────┴─────────┘
─step ----------------------------------  99.8% 100.0%     326   11.103s
└simp ----------------------------------   0.0%  96.8%     228   11.085s
└simp_step -----------------------------   0.1%  96.7%     153    0.577s
 ├─destruct_unique_match ---------------  71.2%  71.2%    2271    0.383s
 │ ├─destruct e eqn:N ------------------  37.6%  37.6%     620    0.057s
 │ ├─congruence ------------------------  13.2%  13.2%    1508    0.018s
 │ ├─elimtype --------------------------   7.3%   7.3%    3021    0.014s
 │ ├─discriminate ----------------------   5.7%   5.7%    1513    0.015s
 │ └─destruct e ------------------------   4.8%   4.8%     137    0.036s
 └─unique_inversion --------------------  25.4%  25.4%    4647    0.253s
  └protect_equalities ------------------   8.1%  16.8%    4333    0.015s
  └change_no_check (protected (a = b)) i   8.7%   8.7%   19512    0.011s

      Search r.

      step.
      step.
      step.
      step.
      step.
      step.
      step.
      step.
      step.
      step.
      step.
      step.


step.
      step.
      step.
      step.
      step.
      step.
      step.

      repeat match goal with
             | x: ?T |- _ => sim'_destructible T; destruct x
             | |- _ => progress (cbn in *; simp)
             | |- exists x: ?T, _ =>
               let y := fresh x in unshelve epose (_: T) as y;
               [ repeat lazymatch goal with
                        | |- ?T => sim'_destructible T; econstructor
                        end;
                 shelve | ]
             end.
      match goal with
      | |- exists x: ?T, _ =>
        sim'_destructible T;
        let y := fresh x in unshelve epose (_: T) as y
      end.
      { econstructor; shelve. }
      exists f2. subst f2.
      cbn.
      match goal with
      | |- exists x: ?T, _ =>
        let y := fresh x in unshelve epose (_: T) as y
      end.
      { repeat lazymatch goal with
               | |- ?T => sim'_destructible T; econstructor
               end;
          shelve. }
      exists s0.
      subst s0.
      cbn.

 econstructor.

      match goal with
      | |- exists x: ?T, _ =>
        sim'_destructible T;
        let y := fresh x in evar (y: T)
      end.
      exists f2.
      destruct f2 eqn: E.

      cbn.

      destruct f2.
      ma
      intros (e & c).
      intros ((? & ?) & ?).


 (e' & c
      intros. simp.


case TODO.
    - case TODO.
  Qed.

  Definition compile(ml: MemoryLayout)(p: source_env): option (list Instruction * funname_env Z) :=
    match composed_compile p with
    | Some (insts, positions, stack_words_needed) =>
      let num_stackwords := word.unsigned (word.sub ml.(stack_pastend) ml.(stack_start)) / bytes_per_word in
      if Z.ltb num_stackwords stack_words_needed then None (* not enough stack *) else Some (insts, positions)
    | None => None
    end.

  (* This lemma translates "sim", which depends on the large definition "related", into something
     more understandable and usable. *)
  Lemma compiler_correct: forall
      (ml: MemoryLayout)
      (mlOk: MemoryLayoutOk ml)
      (f_entry_name : string) (fbody: Syntax.cmd.cmd) (f_entry_rel_pos: Z)
      (p_call p_functions: word)
      (Rdata Rexec : mem -> Prop)
      (functions: source_env)
      (instrs: list Instruction)
      (pos_map: funname_env Z)
      (mH: mem) (mc: MetricLog)
      (postH: Semantics.trace -> Semantics.mem -> Prop)
      (initial: MetricRiscvMachine),
      ExprImp.valid_funs functions ->
      compile ml functions = Some (instrs, pos_map) ->
      map.get functions f_entry_name = Some (nil, nil, fbody) ->
      map.get pos_map f_entry_name = Some f_entry_rel_pos ->
      Semantics.exec functions fbody initial.(getLog) mH map.empty mc (fun t' m' l' mc' => postH t' m') ->
      machine_ok p_functions f_entry_rel_pos ml.(stack_start) ml.(stack_pastend) instrs
                 p_call p_call mH Rdata Rexec initial ->
      runsTo initial (fun final => exists mH',
          postH final.(getLog) mH' /\
          machine_ok p_functions f_entry_rel_pos ml.(stack_start) ml.(stack_pastend) instrs
                     p_call (word.add p_call (word.of_Z 4)) mH' Rdata Rexec final).
  Proof.
    intros. unfold compile in *. simp. eapply Z.ltb_ge in E0.
    eapply runsTo_weaken.
    - pose proof sim' as P. eapply simulation_alt in P.
      unfold simulation_without_weakening, SrcState, srcExec in P.
      let x := open_constr:((_, _, false, _, _, _, _):
        Semantics.env * Syntax.cmd.cmd * bool * Semantics.trace * Semantics.mem * Semantics.locals * MetricLog)
      in specialize P with (s1 := x).
      let x := open_constr:((_, _): Semantics.env * Syntax.cmd.cmd)
      in specialize P with (f1 := x).
      specialize P with (P1 := fun '(e', c', done', t', m', l', mc') =>
                 e' = functions /\ c' = Syntax.cmd.call [] f_entry_name [] /\ done' = true /\ postH t' m').
      let x := open_constr:({| p_sp := _ |}) in specialize (P x initial).
      simpl in P.
      eapply P; clear P.
      + repeat match goal with
               | |- _ /\ _ => split
               | |- exists _, _ => eexists
               | |- _ => reflexivity
               | |- _ => eassumption
               end.
      + split; [reflexivity|].
        eapply Semantics.exec.call; try eassumption || reflexivity.
        cbv beta. intros.
        repeat match goal with
               | |- _ /\ _ => split
               | |- exists _, _ => eexists
               | |- _ => reflexivity
               | |- _ => eassumption
               end.
    - cbv beta. intros. simp. eexists. split; [eassumption|].
      match goal with
      | H: ?P |- ?Q => let hP := head_of_app P in let hQ := head_of_app Q in constr_eq hP hQ;
                       replace Q with P; [exact H|f_equal]
      end.
      + blia.
      + rename H0p0p3p5 into A. clear -A h.
        (* TODO how to automate this one? *)
        apply (f_equal word.of_Z) in A. rewrite ?@word.of_Z_unsigned in A. 2,3: typeclasses eauto.
        apply (f_equal (word.sub (stack_pastend ml))) in A.
        ring_simplify in A.
        symmetry in A.
        exact A.
      + congruence.
    Unshelve. all: try exact map.empty.
  Qed.

  (* Old proof: *)
  Goal forall
      (ml: MemoryLayout)
      (mlOk: MemoryLayoutOk ml)
      (f_entry_name : string) (fbody: Syntax.cmd.cmd) (f_entry_rel_pos: Z)
      (p_call p_functions: word)
      (Rdata Rexec : mem -> Prop)
      (functions: source_env)
      (instrs: list Instruction)
      (pos_map: funname_env Z)
      (mH: mem) (mc: MetricLog)
      (postH: Semantics.trace -> Semantics.mem -> Prop)
      (initial: MetricRiscvMachine),
      ExprImp.valid_funs functions ->
      compile ml functions = Some (instrs, pos_map) ->
      map.get functions f_entry_name = Some (nil, nil, fbody) ->
      map.get pos_map f_entry_name = Some f_entry_rel_pos ->
      Semantics.exec functions fbody initial.(getLog) mH map.empty mc (fun t' m' l' mc' => postH t' m') ->
      machine_ok p_functions f_entry_rel_pos ml.(stack_start) ml.(stack_pastend) instrs
                 p_call p_call mH Rdata Rexec initial ->
      runsTo initial (fun final => exists mH',
          postH final.(getLog) mH' /\
          machine_ok p_functions f_entry_rel_pos ml.(stack_start) ml.(stack_pastend) instrs
                     p_call (word.add p_call (word.of_Z 4)) mH' Rdata Rexec final).
  Proof.
    intros.
    match goal with
    | H: map.get pos_map _ = Some _ |- _ => rename H into GetPos
    end.
    unfold compile, composed_compile, composePhases, flattenPhase, renamePhase, spillingPhase in *. simp.

    match goal with
    | H: flatten_functions _ = _ |- _ => rename H into FlattenEq
    end.
    unfold flatten_functions in FlattenEq.
    match goal with
    | H: _ |- _ => unshelve epose proof (map.map_all_values_fw _ _ _ _ FlattenEq _ _ H)
    end.
    simp.
    match goal with
    | H: rename_functions _ = _ |- _ => rename H into RenameEq
    end.
    unfold rename_functions in RenameEq.
    match goal with
    | H: _ |- _ => unshelve epose proof (map.map_all_values_fw _ _ _ _ RenameEq _ _ H)
    end.
    simp.
    match goal with
    | H: flatten_function _ = _ |- _ => rename H into FF
    end.
    unfold flatten_function in FF. simp.

    eapply runsTo_weaken.
    - pose proof sim as P. eapply simulation_alt in P.
      unfold simulation_without_weakening, SrcState, srcExec in P.
      let x := open_constr:((_, _, _, _, _, _, _):
        Semantics.env * Syntax.cmd.cmd * bool * Semantics.trace * Semantics.mem * Semantics.locals * MetricLog)
      in specialize P with (s1 := x).
      let x := open_constr:((_, _): Semantics.env * Syntax.cmd.cmd)
      in specialize P with (f1 := x).
      specialize P with (P1 := fun '(e', c', done', t', m', l', mc') =>
                                 e' = functions /\ c' = fbody /\ done' = true /\ postH t' m').
      simpl in P.
      eapply P; clear P. 2: {
        split; [reflexivity|]. eapply ExprImp.weaken_exec. 1: eassumption.
        cbv beta. eauto.
      }
      unfold related, flattening_related, renaming_related, spilling_related, flat_related_to_riscv,
             compose_related.
      eexists (_, _), (_, _, _, _, _, _, _).
      all: admit.
      (*
      ssplit; try reflexivity; eauto.
      { eexists.
        match goal with
        | |- ?x = (?evar1, ?evar2) => transitivity (fst x, snd x)
        end.
        2: reflexivity.
        match goal with
        | |- ?x = (_, _) => destruct x; reflexivity
        end. }
      eexists (_, _), (_, _, _, _, _, _, _).
      ssplit; try reflexivity; eauto.
      { unfold envs_related.
        intros f [ [argnames resnames] body1 ] G.
        unfold rename_functions in *.
        eapply map.map_all_values_fw.
        5: exact G. 4: eassumption.
        - eapply String.eqb_spec.
        - typeclasses eauto.
        - simpl. typeclasses eauto.
      }
      refine (ex_intro _ (_, _, _, _) _).
      ssplit; try reflexivity.
      { intros. ssplit; reflexivity. }
      { unfold machine_ok in *. simp.
        (* PARAMRECORDS *) simpl.
        solve_word_eq word_ok. }
      unfold goodMachine. simpl. ssplit.
      { simpl. unfold map.extends. intros k v Emp. rewrite map.get_empty in Emp. discriminate. }
      { simpl. unfold map.extends. intros k v Emp. rewrite map.get_empty in Emp. discriminate. }
      { simpl. unfold machine_ok in *. simp. assumption. }
      { unfold machine_ok in *. simp. assumption. }
      { unfold machine_ok in *. simp. assumption. }
      { unfold machine_ok in *. simp. simpl.
        eapply rearrange_footpr_subset. 1: eassumption.
        (* COQBUG https://github.com/coq/coq/issues/11649 *)
        pose proof (mem_ok: @map.ok (@word (@W p)) Init.Byte.byte (@mem p)).
        wwcancel.
        eapply functions_to_program.
        eassumption. }
      { simpl.
        (* COQBUG https://github.com/coq/coq/issues/11649 *)
        pose proof (mem_ok: @map.ok (@word (@W p)) Init.Byte.byte (@mem p)).
        unfold machine_ok in *. simp.
        edestruct mem_available_to_exists as [ stack_trash [? ?] ]. 1: simpl; ecancel_assumption.
        destruct (byte_list_to_word_list_array stack_trash)
          as (stack_trash_words&Hlength_stack_trash_words&Hstack_trash_words).
        { rewrite H4.
          apply stack_length_divisible.
          assumption. }
        exists stack_trash_words.
        split. 2: {
          unfold word_array.
          rewrite <- (iff1ToEq (Hstack_trash_words _)).
          match goal with
          | E: Z.of_nat _ = word.unsigned (word.sub _ _) |- _ => simpl in E|-*; rewrite <- E
          end.
          lazymatch goal with
          | H: riscvPhase _ _ = _ |- _ => specialize functions_to_program with (1 := H) as P
          end.
          symmetry in P.
          simpl in P|-*. unfold program in P.
          seprewrite P. clear P.
          assert (word.ok FlatImp.word) by exact word_ok.
          rewrite <- Z_div_exact_2; cycle 1. {
            unfold bytes_per_word. clear -h.
            destruct width_cases as [E | E]; rewrite E; reflexivity.
          }
          {
            match goal with
            | H: ?x = ?y |- _ => rewrite H
            end.
            apply stack_length_divisible.
            assumption.
          }
          wcancel_assumption.
          rewrite word.of_Z_unsigned.
          cancel_seps_at_indices O O. {
            (* PARAMRECORDS *) simpl.
            sepclause_eq word_ok.
          }
          cbn [seps]. reflexivity.
        }
        match goal with
        | E: Z.of_nat _ = word.unsigned (word.sub _ _) |- _ => simpl in E|-*; rewrite <- E
        end.
        rewrite Z.sub_0_r. symmetry.
        apply Hlength_stack_trash_words. }
      { reflexivity. }
      { unfold machine_ok in *. simp. assumption. }
      *)
    - intros. unfold compile_inv, related, compose_related in *.
      match goal with
      | H: context[machine_ok] |- _ =>
        unfold machine_ok in H;
        repeat match type of H with
               | _ /\ _ => let A := fresh "HOK0" in destruct H as [A H];
                           lazymatch type of A with
                           | verify _ _ => idtac
                           | _ = p_call => idtac
                         (*| _ => clear A*)
                           end
               end
      end.
      subst.
      repeat match goal with
             | H: context[Semantics.exec] |- _ => clear H
             end.
      unfold flattening_related, renaming_related, spilling_related, flat_related_to_riscv in *.
      unfold FlatToRiscvSimulation.related, FlattenExprSimulation.related, RegRename.related, goodMachine in *.
      admit.
      (*
      simp.
      eexists. split. 1: eassumption.
      unfold machine_ok. ssplit; try assumption.
      + assert (map.ok mem). { exact mem_ok. } (* PARAMRECORDS *)
        cbv [rem_stackwords rem_framewords ghostConsts] in H2p0p1p8p0.
        cbv [mem_available].
        repeat rewrite ?(iff1ToEq (sep_ex1_r _ _)), ?(iff1ToEq (sep_ex1_l _ _)).
        exists (List.flat_map (fun x => HList.tuple.to_list (LittleEndian.split (Z.to_nat bytes_per_word) (word.unsigned x))) stack_trash).
        rewrite !(iff1ToEq (sep_emp_2 _ _ _)).
        rewrite !(iff1ToEq (sep_assoc _ _ _)).
        eapply (sep_emp_l _ _); split.
        { assert (0 < bytes_per_word). { (* TODO: deduplicate *)
            unfold bytes_per_word; simpl; destruct width_cases as [EE | EE]; rewrite EE; cbv; trivial.
          }
          rewrite (length_flat_map _ (Z.to_nat bytes_per_word)).
          { rewrite Nat2Z.inj_mul, Z2Nat.id by blia. rewrite Z.sub_0_r in H2p0p1p8p0.
            rewrite <-H2p0p1p8p0, <-Z_div_exact_2; try trivial.
            { eapply Z.lt_gt; assumption. }
            { eapply stack_length_divisible; trivial. } }
          intros w.
          rewrite HList.tuple.length_to_list; trivial. }
        use_sep_assumption.
        cbn [dframe xframe ghostConsts program_base ghostConsts e_pos e_impl p_insts insts].
        progress simpl (@FlatToRiscvCommon.mem (@FlatToRiscv_params p)).
        wwcancel.
        cancel_seps_at_indices 0%nat 3%nat. {
          reflexivity.
        }
        cancel_seps_at_indices 0%nat 2%nat. {
          cbn [rem_stackwords rem_framewords ghostConsts p_sp].
          replace (word.sub (stack_pastend ml) (word.of_Z (bytes_per_word *
                      (word.unsigned (word.sub (stack_pastend ml) (stack_start ml)) / bytes_per_word))))
            with (stack_start ml). 2: {
            rewrite <- Z_div_exact_2; cycle 1. {
              unfold bytes_per_word. clear -h. simpl.
              destruct width_cases as [E | E]; rewrite E; reflexivity.
            }
            {
              apply stack_length_divisible.
              assumption.
            }
            rewrite word.of_Z_unsigned.
            solve_word_eq word_ok.
          }
          apply iff1ToEq, cast_word_array_to_bytes.
        }
        unfold ptsto_instr.
        simpl.
        unfold ptsto_bytes, ptsto_instr, truncated_scalar, littleendian, ptsto_bytes.ptsto_bytes.
        simpl.
        assert (map.ok mem). { exact mem_ok. } (* PARAMRECORDS *)
        wwcancel.
        epose proof (functions_to_program ml _ r0 instrs) as P.
        cbn [seps].
        rewrite <- P; clear P.
        * wwcancel. reflexivity.
        * eassumption.
      + unfold machine_ok in *. simp. simpl.
        eapply rearrange_footpr_subset. 1: eassumption.
        (* COQBUG https://github.com/coq/coq/issues/11649 *)
        pose proof (mem_ok: @map.ok (@word (@W p)) Init.Byte.byte (@mem p)).
        (* TODO remove duplication *)
        lazymatch goal with
        | H: riscvPhase _ _ = _ |- _ => specialize functions_to_program with (1 := H) as P
        end.
        symmetry in P.
        rewrite P. clear P.
        cbn [dframe xframe ghostConsts program_base ghostConsts e_pos e_impl p_insts insts program].
        simpl.
        unfold ptsto_bytes, ptsto_instr, truncated_scalar, littleendian, ptsto_bytes.ptsto_bytes.
        simpl.
        wwcancel.
      + destr_RiscvMachine final. subst. solve_divisibleBy4.
      *)
    Unshelve.
    all: try exact (bedrock2.MetricLogging.mkMetricLog 0 0 0 0).
    all: try (simpl; typeclasses eauto).
    all: try exact EmptyString.
    all: try exact nil.
    all: try exact map.empty.
    all: try exact mem_ok.
  Abort.

  Definition instrencode(p: list Instruction): list byte :=
    List.flat_map (fun inst => HList.tuple.to_list (LittleEndian.split 4 (encode inst))) p.

End Pipeline1.

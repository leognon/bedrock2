Require Import String.
Require Import Coq.ZArith.ZArith.
Require Import Coq.Lists.List. Import ListNotations.

Require Import Kami.
Require Import Kami.Ex.MemTypes Kami.Ex.SC Kami.Ex.IsaRv32 Kami.Ex.SCMMInl.
Require Import Kami.Ex.ProcMemCorrect.

Local Open Scope Z_scope.

Set Implicit Arguments.

Section Parametrized.
  Variables addrSize iaddrSize fifoSize instBytes dataBytes rfIdx: nat.

  Variables (fetch: AbsFetch instBytes dataBytes)
            (dec: AbsDec addrSize instBytes dataBytes rfIdx)
            (exec: AbsExec iaddrSize instBytes dataBytes rfIdx)
            (ammio: AbsMMIO addrSize).

  Variable (init: ProcInit iaddrSize dataBytes rfIdx).

  Definition pprocInl := scmmInl fetch dec exec ammio init.
  Definition pproc := projT1 pprocInl.

  (** The auxiliary hardware state; this is for manipulating hardware state
   * without knowing much about Kami states.
   *)
  Record pst :=
    mk { pc: word (2 + iaddrSize);
         rf: word rfIdx -> word (dataBytes * BitsPerByte);
         pgm: word iaddrSize -> word (instBytes * BitsPerByte);
         mem: word addrSize -> word (dataBytes * BitsPerByte)
       }.

  Definition pRegsToT (r: Kami.Semantics.RegsT): option pst :=
    (mlet pcv: (Pc iaddrSize) <- r |> "pc" <| None;
       mlet rfv: (Vector (Data dataBytes) rfIdx) <- r |> "rf" <| None;
       mlet pgmv: (Vector (Data instBytes) iaddrSize) <- r |> "pgm" <| None;
       mlet memv: (Vector (Data dataBytes) addrSize) <- r |> "mem" <| None;
       (Some {| pc := pcv; rf := rfv; pgm := pgmv; mem := memv |}))%mapping.

  (** * Inverting Kami rules for instruction executions *)

  Local Definition iaddrSizeZ: Z := Z.of_nat iaddrSize.

  Ltac kinvert_more :=
    kinvert;
    try (repeat
           match goal with
           | [H: annot ?klbl = Some _ |- _] => rewrite H in *
           | [H: (_ :: _)%struct = (_ :: _)%struct |- _] =>
             inversion H; subst; clear H
           end; discriminate).

  Lemma invert_Kami_execLd_memory:
    forall km1 kt1 kupd klbl,
      pRegsToT km1 = Some kt1 ->
      Step pproc km1 kupd klbl ->
      klbl.(annot) = Some (Some "execLd"%string) ->
      exists curInst ldAddr,
        curInst = (pgm kt1) (split2 _ _ (pc kt1)) /\
        ldAddr = evalExpr
                   (calcLdAddr
                      _ (evalExpr (getLdAddr _ curInst))
                      (rf kt1 (evalExpr (getLdSrc _ curInst)))) /\
        (evalExpr (isMMIO _ ldAddr) = false ->
         exists kt2,
           klbl.(calls) = FMap.M.empty _ /\
           pRegsToT (FMap.M.union kupd km1) = Some kt2 /\
           kt2 = {| pc := evalExpr (getNextPc _ (rf kt1) (pc kt1) curInst);
                    rf :=
                      fun w =>
                        if weq w (evalExpr (getLdDst _ curInst))
                        then mem kt1 ldAddr
                        else rf kt1 w;
                    pgm := pgm kt1;
                    mem := mem kt1 |}).
  Proof.
    intros.
    kinvert_more.
    do 2 eexists; repeat split.
    kinv_action_dest.
    - unfold pRegsToT in *.
      kregmap_red.
      destruct (FMap.M.find "mem"%string km1) as [[[memk|] memv]|]; try discriminate.
      destruct (decKind memk _); try discriminate.
      kregmap_red.
      inversion H; subst; clear H.
      simpl in *.
      exfalso; clear -H3 Heqic; congruence.
    - kinv_red.
      unfold pRegsToT in *.
      kregmap_red.
      inversion H; subst; clear H; simpl in *.
      repeat esplit.
      assumption.
  Qed.

  Lemma invert_Kami_execNm:
    forall km1 kt1 kupd klbl,
      pRegsToT km1 = Some kt1 ->
      Step pproc km1 kupd klbl ->
      klbl.(annot) = Some (Some "execNm"%string) ->
      exists kt2,
        klbl.(calls) = FMap.M.empty _ /\
        pRegsToT (FMap.M.union kupd km1) = Some kt2 /\
        exists curInst execVal,
          curInst = (pgm kt1) (split2 _ _ (pc kt1)) /\
          execVal = evalExpr
                      (doExec
                         _
                         (rf kt1 (evalExpr (getSrc1 _ curInst)))
                         (rf kt1 (evalExpr (getSrc2 _ curInst)))
                         (pc kt1)
                         curInst) /\
          kt2 = {| pc := evalExpr (getNextPc _ (rf kt1) (pc kt1) curInst);
                   rf :=
                     fun w =>
                       if weq w (evalExpr (getDst type curInst))
                       then execVal else rf kt1 w;
                   pgm := pgm kt1;
                   mem := mem kt1 |}.
  Proof.
    intros.
    kinvert_more.
    kinv_action_dest.
    unfold pRegsToT in *.
    kregmap_red.
    destruct (FMap.M.find "mem"%string km1) as [[[memk|] memv]|]; try discriminate.
    destruct (decKind memk _); try discriminate.
    kregmap_red.
    inversion H; subst; clear H.
    repeat esplit.
    assumption.
  Qed.

End Parametrized.

Definition width: Z := 32.
Definition width_cases: width = 32 \/ width = 64 := or_introl eq_refl.
Local Notation nwidth := (Z.to_nat width).

Instance rv32MMIO: AbsMMIO nwidth :=
  {| isMMIO := cheat _ |}.

Section PerInstAddr.
  Context {instrMemSizeLg: Z}.
  Local Notation ninstrMemSizeLg := (Z.to_nat instrMemSizeLg).

  Definition procInit: ProcInit ninstrMemSizeLg rv32DataBytes rv32RfIdx :=
    {| pcInit := getDefaultConst _;
       rfInit := getDefaultConst _ |}.

  Definition predictNextPc ty (ppc: fullType ty (SyntaxKind (Pc ninstrMemSizeLg))) :=
    (#ppc + $4)%kami_expr.

  Definition procInl :=
    pprocInl rv32Fetch (rv32Dec _) (rv32Exec _) rv32MMIO procInit.
  Definition proc: Kami.Syntax.Modules := projT1 procInl.

  Definition hst := Kami.Semantics.RegsT.

  (** Abstract hardware state *)
  Definition st :=
    @pst nwidth ninstrMemSizeLg rv32InstBytes rv32DataBytes rv32RfIdx.

  Definition RegsToT (r: hst): option st :=
    pRegsToT nwidth ninstrMemSizeLg rv32InstBytes rv32DataBytes rv32RfIdx r.

  (** Refinement from [p4mm] to [proc] (as a spec) *)

  Definition p4mm: Kami.Syntax.Modules :=
    p4mm 1 rv32Fetch (rv32Dec _) (rv32Exec _) rv32MMIO predictNextPc procInit.

  Theorem proc_correct: p4mm <<== proc.
  Proof.
    ketrans.
    - apply p4mm_correct. (* [p4mm] refines [scmm] *)
    - apply (projT2 procInl). (* [scmm] refines [projT1 scmmInl], the inlined module. *)
  Qed.

End PerInstAddr.

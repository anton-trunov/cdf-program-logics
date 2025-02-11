(** Concurrent separation logic. *)

From Coq Require Import ssreflect ssrfun ssrbool Lia FunctionalExtensionality PropExtensionality.
From mathcomp Require Import ssrnat ssrint ssrnum ssralg seq eqtype order zify.
From CDF Require Import Sequences Separation.
Local Open Scope ring_scope.

(** * 1. A language with pointers and concurrency *)

(** Here is a variant of the PTR language (from the course on separation logic)
    with concurrency (the PAR and ATOMIC constructs).

    Like PTR, it's an ML-like language with immutable variables and
    references to mutable memory locations, represented using higher-order
    abstract syntax. *)

Inductive com: Type :=
  | PURE (x: int)                    (**r command without effects *)
  | LET (c: com) (f: int -> com)     (**r sequencing of commands *)
  | IFTHENELSE (b: int) (c1 c2: com  (**r conditional *))
  | REPEAT (c: com)                  (**r iterate [c] until it returns not 0 *)
  | PAR (c1 c2: com)                 (**r run [c1] and [c2] in parallel *)
  | ATOMIC (c: com)                  (**r run [c] as one atomic step *)
  | ALLOC (sz: nat)                  (**r allocate [sz] words of storage *)
  | GET (l: addr)                    (**r dereference a pointer *)
  | SET (l: addr) (v: int)           (**r assign through a pointer *)
  | FREE (l: addr).                  (**r free one word of storage *)

Definition not_pure (c : com) :=
  if c is PURE _ then false else true.

(** Some derived forms. *)

Definition SKIP: com := PURE 0.

Definition SEQ (c1 c2: com) := LET c1 (fun _ => c2).

(** Locations that can be read / written right now. *)

Fixpoint immacc (l: addr) (c: com) : bool :=
  match c with
  | LET c _ => immacc l c
  | PAR c1 c2 => immacc l c1 || immacc l c2
  | GET l' => l == l'
  | SET l' _ => l == l'
  | FREE l' => l == l'
  | _ => false
  end.

(** Reduction semantics. *)

Inductive red: com * heap -> com * heap -> Prop :=
  | red_let_done: forall x f h,
      red (LET (PURE x) f, h) (f x, h)
  | red_let_step: forall c f h c' h',
      red (c, h) (c', h') ->
      red (LET c f, h) (LET c' f, h')
  | red_ifthenelse: forall b c1 c2 h,
      red (IFTHENELSE b c1 c2, h) ((if b == 0 then c2 else c1), h)
  | red_repeat: forall c h,
      red (REPEAT c, h) (LET c (fun b => IFTHENELSE b (PURE b) (REPEAT c)), h)
  | red_par_done: forall v1 v2 h,
      red (PAR (PURE v1) (PURE v2), h) (SKIP, h)
  | red_par_left: forall c1 c2 h c1' h',
      red (c1, h) (c1', h') ->
      red (PAR c1 c2, h) (PAR c1' c2, h')
  | red_par_right: forall c1 c2 h c2' h',
      red (c2, h) (c2', h') ->
      red (PAR c1 c2, h) (PAR c1 c2', h')
  | red_atomic: forall c h v h',
      star red (c, h) (PURE v, h') ->
      red (ATOMIC c, h) (PURE v, h')
  | red_alloc: forall sz (h: heap) l,
      (forall i, l <= i < l + sz%:Z -> h i = None) ->
      l != 0 ->
      red (ALLOC sz, h) (PURE l, hinit l sz h)
  | red_get: forall l (h: heap) v,
      h l = Some v ->
      red (GET l, h) (PURE v, h)
  | red_set: forall l v (h: heap),
      h l <> None ->
      red (SET l v, h) (SKIP, hupdate l v h)
  | red_free: forall l (h: heap),
      h l <> None ->
      red (FREE l, h) (SKIP, hfree l h).

(** Run-time errors. This includes race conditions, where a location is
    immediately accessed by two commands running in parallel. *)

Inductive erroneous: com * heap -> Prop :=
  | erroneous_let: forall c f h,
      erroneous (c, h) -> erroneous (LET c f, h)
  | erroneous_par_race: forall c1 c2 h l,
      immacc l c1 && immacc l c2 ->
      erroneous (PAR c1 c2, h)
  | erroneous_par_l: forall c1 c2 h,
      erroneous (c1, h) -> erroneous (PAR c1 c2, h)
  | erroneous_par_r: forall c1 c2 h,
      erroneous (c2, h) -> erroneous (PAR c1 c2, h)
  | erroneous_atomic: forall c h c' h',
      star red (c, h) (c', h') ->
      erroneous (c', h') ->
      erroneous (ATOMIC c, h)
  | erroneous_get: forall l (h: heap),
      h l = None -> erroneous (GET l, h)
  | erroneous_set: forall l v (h: heap),
      h l = None -> erroneous (SET l v, h)
  | erroneous_free: forall l (h: heap),
      h l = None -> erroneous (FREE l, h).

(** * 2.  The rules of concurrent separation logic *)

Definition invariant := assertion.
Definition precond := assertion.
Definition postcond := int -> assertion.

(** ** 2.1.  Semantic definition of weak triples *)

(** We now define "triples" (actually, quadruples) [ J ⊢ ⦃ P ⦄ c ⦃ Q ⦄ ],
  where [c] is a command, [P] a precondition (on the initial memory heap),
  [Q] a postcondition (on the return value and the final memory heap),
  and [J] an invariant about the shared heap that is accessed by atomic
  commands.  This is a weak triple: termination is not guaranteed.

  As in the [Seplog] module, we define the "triple" semantically
  in terms of a [safe n c h1 Q J] predicate over the possible reductions
  of command [c] in heap [h1].

  The definition of [safe] follows Vafeiadis (2011) and uses quantification
  over all possible shared heaps [hj] and framing heaps [hf].

  Step-indexing (the [n] parameter) provides an induction principle
  over the [safe] predicate. *)

Inductive safe: nat -> com -> heap -> postcond -> invariant -> Prop :=
  | safe_zero: forall c h Q J,
      safe O c h Q J
  | safe_done: forall n v h (Q: postcond) (J: invariant),
      Q v h ->
      safe (S n) (PURE v) h Q J
  | safe_step: forall n c (h1: heap) (Q: postcond) (J: invariant)
      (NOTDONE: not_pure c)
      (ACC: forall l, immacc l c -> h1 l <> None)
      (IMM: forall hf hj h,
         hdisj3 h1 hj hf ->
         h = hunion h1 (hunion hj hf) ->
         J hj ->
         ~ erroneous (c, h))
      (STEP: forall hf hj h c' h',
         hdisj3 h1 hj hf ->
         h = hunion h1 (hunion hj hf) ->
         J hj ->
         red (c, h) (c', h') ->
         exists h1' hj',
           hdisj3 h1' hj' hf /\
           h' = hunion h1' (hunion hj' hf) /\
           J hj' /\ safe n c' h1' Q J),
      safe (S n) c h1 Q J.

Definition triple (J: invariant) (P: precond) (c: com) (Q: postcond) :=
  forall n h, P h -> safe n c h Q J.

Notation "J '⊢' ⦃ P ⦄ c ⦃ Q ⦄" := (triple J P c Q) (at level 90, c at next level).

(** ** 2.2. Properties about [safe] *)

Lemma safe_pure: forall n v h (Q: postcond) J,
  Q v h -> safe n (PURE v) h Q J.
Proof. by case=>[|n] ?????; [apply: safe_zero|apply: safe_done]. Qed.

Lemma safe_pure_inv: forall n v h Q J,
  safe (S n) (PURE v) h Q J -> Q v h.
Proof.
move=>n v ??? HS.
case: {-1}_ {-2}_ _ _ _ / HS (erefl (S n)) (erefl (PURE v)) =>//.
- by move=>??????? [<-].
by move=>????? ND ???? E; rewrite E in ND.
Qed.

Lemma safe_red: forall n c h1 Q J hj hf c' h',
  red (c, hunion h1 (hunion hj hf)) (c', h') ->
  safe (S n) c h1 Q J ->
  J hj ->
  hdisj3 h1 hj hf ->
  exists h1' hj',
    hdisj3 h1' hj' hf /\
    h' = hunion h1' (hunion hj' hf) /\
    J hj' /\ safe n c' h1' Q J.
Proof.
move=>n c h1 Q J hj hf ?? R HS.
case: {-1}_ {-2}_ {-2}_ _ _ / HS (erefl (S n)) (erefl c) (erefl h1) (erefl Q) (erefl J)=>//.
- move=>? v ????? E; rewrite -E in R.
  by case : {-1}_ _ / R (erefl (PURE v, hunion h1 (hunion hj hf))).
move=>???????? ST [->] EC EH ????.
by apply: (ST hf hj)=>//; rewrite EC EH.
Qed.

Lemma safe_redN: forall n c h1 Q J hj hf c' h',
  starN red n (c, hunion h1 (hunion hj hf)) (c', h') ->
  safe (S n) c h1 Q J ->
  J hj ->
  hdisj3 h1 hj hf ->
  exists h1' hj',
    hdisj3 h1' hj' hf /\
    h' = hunion h1' (hunion hj' hf) /\
    J hj' /\ safe 1%nat c' h1' Q J.
Proof.
elim=>[|n IH] c h1 ?? hj hf c' h' HST HS ??.
- case: {-1}_ {-2}_ {-1}_ / HST (erefl 0%N) (erefl (c, hunion h1 (hunion hj hf))) (erefl (c',h')) =>//.
  move=>[??] _ [EC EH][->->]; rewrite {}EC {}EH.
  by exists h1, hj.
case: {-2}_ {-2}_ {-1}_ / HST (erefl (S n)) (erefl (c, hunion h1 (hunion hj hf))) (erefl (c',h')) =>//.
move=>? [??][a1 ?][??] R S [EN][EA EB][->->]; rewrite {}EN {}EA {}EB in R S.
case: (safe_red _ _ _ _ _ _ _ _ _ R HS)=>// h1'[hj'][D3][EB][?]?; rewrite {}EB in S.
by apply/(IH a1 h1')/D3.
Qed.

Lemma safe_not_erroneous: forall n c h1 Q J hj hf,
  safe (S n) c h1 Q J ->
  hdisj3 h1 hj hf ->
  J hj ->
  ~ erroneous (c, hunion h1 (hunion hj hf)).
Proof.
move=>n c h1 Q J hj hf HS ??.
case: {-1}_ {-2}_ {-2}_ _ {-2}_ / HS (erefl (S n)) (erefl c) (erefl h1) (erefl Q) (erefl J)=>//.
- move=>? v h ???????? HE.
  by case: {-1}_ / HE (erefl (PURE v, hunion h (hunion hj hf))).
- move=>??????? IMM ??? EH ? EJ; rewrite EH EJ in IMM *.
  by apply: (IMM hf hj).
Qed.

Lemma safe_immacc: forall n c h1 Q J l,
  safe (S n) c h1 Q J ->
  immacc l c ->
  h1 l <> None.
Proof.
move=>n c h1 Q J ? HS HI.
case: {-1}_ {-2}_ {-2}_ _ {-2}_ / HS (erefl (S n)) (erefl c) (erefl h1) (erefl Q) (erefl J)=>//.
- by move=>??????? EC; rewrite -EC /= in HI.
by move=>?????? ACC ??? EC ???; apply: ACC; rewrite EC.
Qed.

Lemma safe_mono: forall n c h Q J,
  safe n c h Q J -> forall n', (n' <= n)%nat -> safe n' c h Q J.
Proof.
elim=>[|n IH] ???? HS n' H.
- by rewrite leqn0 in H; move/eqP: H=>->.
case: n' H=>[|n'] H; first by apply: safe_zero.
case: {-2}_ _ _ _ _ / HS (erefl (S n))=>//.
- by move=>???????; apply: safe_done.
move=>???????? ST [EN] ; rewrite {}EN in ST.
apply: safe_step=>// hf0 hj0 h0 c' h' ????.
case: (ST hf0 hj0 h0 c' h')=>// h1'[hj'][?][?][?]?.
exists h1', hj'; do!split=>//.
by apply: IH.
Qed.

(** ** 2.3. The rules of concurrent separation logic *)

(** *** The frame rule *)

Lemma safe_frame:
  forall (R: assertion) (Q: postcond) J n c h h',
  safe n c h Q J -> hdisjoint h h' -> R h' ->
  safe n c (hunion h h') (fun v => Q v ** R) J.
Proof.
move=>? Q J; elim=>[|n IH] c h h' HS ??.
- by apply: safe_zero.
case: {-2}_ _ {-2}_ {-2}_ {-2}_ / HS (erefl (S n)) (erefl h) (erefl Q) (erefl J)=>//.
- move=>??????? EH ??; apply: safe_done.
  by exists h, h'; do!split=>//; rewrite -EH.
move=>?????? ACC IMM ST [EN] EH EQ EJ; apply: safe_step=>//.
- move=>? HI; move: (ACC _ HI); rewrite EH /hunion /=.
  by case: (h _).
- move=>hf hj ? D3 ->?; rewrite EH in D3 *.
  move: D3; rewrite /hdisj3 !hdisjoint_union_l; case; case=>??[[??]?].
  apply: (IMM (hunion h' hf) hj)=>//; rewrite EH.
  - rewrite /hdisj3 !hdisjoint_union_r.
    by do!split=>//; rewrite hdisjoint_sym.
  rewrite hunion_assoc (hunion_comm _ h');
    last by rewrite hdisjoint_union_l; split; rewrite hdisjoint_sym.
  by rewrite hunion_assoc (hunion_comm h') // hdisjoint_sym.
move=>hf hj ??? D3 ->? R; rewrite EH in R D3.
move: D3; rewrite /hdisj3 !hdisjoint_union_l; case; case=>??[[??]?].
case: (ST (hunion h' hf) hj _ _ _ _ _ _ R)=>//; rewrite ?EH.
- rewrite /hdisj3 !hdisjoint_union_r.
  by do!split=>//; rewrite hdisjoint_sym.
- rewrite hunion_assoc (hunion_comm _ h');
    last by rewrite hdisjoint_union_l; split; rewrite hdisjoint_sym.
  by rewrite hunion_assoc (hunion_comm h').
move=>h1'[hj'][D3'][E'][?]S'; rewrite E' in R.
move: D3'; rewrite /hdisj3 !hdisjoint_union_r; case=>?[[??][??]].
exists (hunion h1' h'), hj'; do!split=>//.
- by rewrite hdisjoint_union_l; split=>//; rewrite hdisjoint_sym.
- by rewrite hdisjoint_union_l.
- by rewrite E' hunion_assoc -(hunion_assoc h') (hunion_comm hj' h') // hunion_assoc.
by rewrite EN EQ EJ in S' *; apply: IH.
Qed.

Lemma triple_frame: forall J P c Q R,
  J ⊢ ⦃ P ⦄ c ⦃ Q ⦄ ->
  J ⊢ ⦃ P ** R ⦄ c ⦃ fun v => Q v ** R ⦄.
Proof.
move=>????? H ??[?][?][?][?][?]->.
by apply: safe_frame=>//; apply: H.
Qed.

(** *** The frame rule for invariants *)

Lemma safe_frame_invariant:
  forall Q (J J': invariant) n c h,
  safe n c h Q J ->
  safe n c h Q (J ** J').
Proof.
move=>Q J ?; elim=>[|n IH] c h HS; first by apply: safe_zero.
case: {-2}_ _ _ {-2}_ {-2}_ / HS (erefl (S n)) (erefl Q) (erefl J)=>//.
- by move=>?????????; apply: safe_done.
move=>??????? IMM ST [EN] EQ EJ; apply: safe_step=>//.
- move=>hf ?? D3 ->[hj1][hj2][?][?][?] EHJ; rewrite {}EHJ in D3 *.
  move: D3; rewrite /hdisj3 !hdisjoint_union_r !hdisjoint_union_l; case; case=>??[?[??]].
  apply: (IMM (hunion hj2 hf) hj1)=>//.
  - by rewrite /hdisj3 !hdisjoint_union_r.
  by rewrite hunion_assoc.
move=>hf ???? D3 ->[hj1][hj2][?][?][?] EHJ R; rewrite {}EHJ in D3 R.
move: D3; rewrite /hdisj3 !hdisjoint_union_r !hdisjoint_union_l; case; case=>??[?[??]].
case: (ST (hunion hj2 hf) hj1 _ _ _ _ _ _ R)=>//.
- by rewrite /hdisj3 !hdisjoint_union_r.
- by rewrite hunion_assoc.
move=>h1'[hj1'][D3'][EH'][?] S; rewrite {}EH' in R *.
move: D3'; rewrite /hdisj3 !hdisjoint_union_r; case=>?[[??][??]].
exists h1', (hunion hj1' hj2); do!split=>//.
- by rewrite hdisjoint_union_r.
- by rewrite hdisjoint_union_l.
- by rewrite hunion_assoc.
- by exists hj1', hj2.
by rewrite {}EQ {}EJ {}EN in S *; apply IH.
Qed.

Lemma triple_frame_invariant: forall J J' P c Q,
  J ⊢ ⦃ P ⦄ c ⦃ Q ⦄ ->
  J ** J' ⊢ ⦃ P ⦄ c ⦃ Q ⦄.
Proof.
by move=>????? H ???; apply/safe_frame_invariant/H.
Qed.

(** *** Atomic commands *)

Lemma triple_atomic: forall J P c (Q: postcond),
  emp ⊢ ⦃ P ** J ⦄ c ⦃ fun v => Q v ** J ⦄ ->
  J ⊢ ⦃ P ⦄ ATOMIC c ⦃ Q ⦄.
Proof.
move=>J ? c Q TR n h ?; elim: n; first by exact: safe_zero.
move=>??; apply: safe_step=>//.
- move=>hf hj ? D3 -> ? HE.
  move: D3; rewrite /hdisj3; case=>?[??].
  case: {-2}_ / HE (erefl (ATOMIC c, hunion h (hunion hj hf)))=>//???? S HER [EC EH]; rewrite {}EC {}EH in S.
  case: (star_starN S)=>n1; rewrite -hunion_assoc -(hunion_empty hf) => SS.
  case: (safe_redN _ _ _ (fun v => Q v ** J) emp _ _ _ _ SS).
  - by apply: TR; exists h, hj.
  - by rewrite /emp.
  - by rewrite /hdisj3 !hdisjoint_union_l; do!split=>//; try by [left|right].
  move=>?[?][D3][EH'][?] HS; rewrite {}EH' in HER.
  by apply: (safe_not_erroneous _ _ _ _ _ _ _ HS D3).
move=>hf hj ? c' h' D3 ->? R.
move: D3; rewrite {1}/hdisj3; case=>?[??].
case: {-2}_ {-1}_ / R (erefl (ATOMIC c, hunion h (hunion hj hf))) (erefl (c', h'))=>// ???? S [EC EH][->->].
  rewrite {}EC {}EH in S.
case: (star_starN S)=>n1; rewrite -hunion_assoc -(hunion_empty hf) => {S}SS.
case: (safe_redN _ _ _ (fun v => Q v ** J) emp _ _ _ _ SS).
- by apply: TR; exists h, hj.
- by rewrite /emp.
- by rewrite /hdisj3 !hdisjoint_union_l; do!split=>//; try by [left|right].
move=>h1'[hj'][D3][EH'][HE] HS; rewrite {}EH' in SS *.
case: (safe_pure_inv _ _ _ _ _ HS)=>{HS}h1''[hj''][?][?][?]EH''; rewrite {}EH'' in D3 SS *.
move: D3; rewrite {1}/hdisj3 !hdisjoint_union_l; case; case=>??[[??]?].
exists h1'', hj''; do!split=>//.
- by rewrite hunion_assoc HE hunion_empty.
by apply: safe_pure.
Qed.

(** *** Sharing some state in the invariant *)

Lemma safe_share:
  forall Q (J J': invariant) n c h h',
  safe n c h Q (J ** J') ->
  hdisjoint h h' -> J' h' ->
  safe n c (hunion h h') (fun v => Q v ** J') J.
Proof.
move=>Q J J'; elim=>[|n IH] ? h h' HS ??; first by exact: safe_zero.
case: {-2}_ _ {-2}_ {-2}_ {-2}_ / HS (erefl (S n)) (erefl h) (erefl Q) (erefl (J ** J'))=>//.
- move=>????? HQ ? EH ??; rewrite {}EH in HQ *.
  by apply: safe_done; exists h, h'.
move=>?????? ACC IMM ST [EN] EH EQ EJ; rewrite {}EH {}EJ in IMM ACC ST *.
apply: safe_step=>//.
- by move=>? /ACC /=; case: (h _).
- move=>hf hj ? D3 ->?.
  move: D3; rewrite {1}/hdisj3 !hdisjoint_union_l; case; case=>??[[??]?].
  apply: (IMM hf (hunion h' hj)).
  - by rewrite {1}/hdisj3 hdisjoint_union_l hdisjoint_union_r; do!split=>//; rewrite hdisjoint_sym.
  - by rewrite !hunion_assoc.
  - rewrite hunion_comm; last by rewrite hdisjoint_sym.
    by exists hj, h'; do!split=>//; rewrite hdisjoint_sym.
move=>hf hj ??? D3 ->? R.
move: D3; rewrite {1}/hdisj3 !hdisjoint_union_l; case; case=>??[[??]?].
case: (ST hf (hunion h' hj) _ _ _ _ _ _ R).
- by rewrite {1}/hdisj3 hdisjoint_union_l hdisjoint_union_r.
- by rewrite !hunion_assoc.
- rewrite hunion_comm; last by rewrite hdisjoint_sym.
  by exists hj, h'; do!split=>//; rewrite hdisjoint_sym.
move=>h1'[?][D3][EH'][[hj1'][hj2'][?][?][?]EX] S; rewrite {}EH' {}EX in R D3 *.
move: D3; rewrite {1}/hdisj3 hdisjoint_union_l hdisjoint_union_r; case; case=>??[?][??].
exists (hunion h1' hj2'), hj1'; do!split=>//.
- by rewrite hdisjoint_union_l; split=>//; rewrite hdisjoint_sym.
- by rewrite hdisjoint_union_l; split=>//; rewrite hdisjoint_sym.
- rewrite !hunion_assoc (hunion_comm _ hj2'); last by rewrite hdisjoint_sym.
  rewrite -(hunion_assoc hj1') (hunion_comm hj2') // hdisjoint_union_r; split=>//.
  by rewrite hdisjoint_sym.
by rewrite EN EQ in S *; apply: IH.
Qed.

Lemma triple_share: forall J J' P c Q,
  J ** J' ⊢ ⦃ P ⦄ c ⦃ Q ⦄ ->
  J ⊢ ⦃ P ** J' ⦄ c ⦃ fun v => Q v ** J' ⦄.
Proof.
move=>????? H ??[?][?][?][?][?]->; apply: safe_share=>//.
by apply: H.
Qed.

(** *** Sequential commands *)

Lemma triple_pure: forall J P Q v,
  P -->> Q v ->
  J ⊢ ⦃ P ⦄ PURE v ⦃ Q ⦄.
Proof. by move=>???? H ???; apply/safe_pure/H. Qed.

Lemma safe_let:
  forall (Q R: postcond) (J: invariant) f n c h,
  safe n c h Q J ->
  (forall v n' h', Q v h' -> (n' < n)%N -> safe n' (f v) h' R J) ->
  safe n (LET c f) h R J.
Proof.
move=>??? f; elim=>[|n IH] c h S1 S2; first by exact: safe_zero.
apply: safe_step=>//.
- by move=>? /=; apply/safe_immacc/S1.
- move=>?? h1 D3 EH ? HE.
  case: {-2}_ / HE (erefl (LET c f, h1))=>// ??? HE [EC ? EH1]; rewrite {}EC {}EH1 {}EH in HE.
  by apply: (safe_not_erroneous _ _ _ _ _ _ _ S1 D3).
move=>hf hj ? c' h' ? -> ? R.
case: {-2}_ {-1}_ / R (erefl (LET c f, hunion h (hunion hj hf))) (erefl (c', h'))=>//.
- move=>??? [EC ->->][->->].
  exists h, hj; do!split=>//.
  by apply: S2=>//; apply: safe_pure_inv; rewrite EC; exact: S1.
move=>????? R [EC->EF][->->]; rewrite {}EC {}EF in R.
case: (safe_red _ _ _ _ _ _ _ _ _ R S1)=>// h1'[hj'][?][->][?]?.
exists h1', hj'; do!split=>//.
by apply: IH=>// ?????; apply/S2/ltnW.
Qed.

Lemma triple_let:
  forall c f (J: invariant) (P: precond) (Q R: postcond),
  J ⊢ ⦃ P ⦄ c ⦃ Q ⦄ ->
  (forall v, J ⊢ ⦃ Q v ⦄ f v ⦃ R ⦄) ->
  J ⊢ ⦃ P ⦄ LET c f ⦃ R ⦄.
Proof.
move=>???? Q ? H H0 ???; apply: (safe_let Q); first by apply: H.
by move=>?????; apply: H0.
Qed.

Corollary triple_seq:
  forall c1 c2 (J: invariant) (P Q: precond) (R: postcond),
  J ⊢ ⦃ P ⦄ c1 ⦃ fun _ => Q ⦄ ->
  J ⊢ ⦃ Q ⦄ c2 ⦃ R ⦄ ->
  J ⊢ ⦃ P ⦄ SEQ c1 c2 ⦃ R ⦄.
Proof. by move=>?????? H ?; apply: triple_let; first by exact: H. Qed.

(** *** Conditionals and loops *)

Lemma safe_ifthenelse:
  forall n b c1 c2 h Q J,
  (b != 0 -> safe n c1 h Q J) ->
  (b == 0 -> safe n c2 h Q J) ->
  safe (S n) (IFTHENELSE b c1 c2) h Q J.
Proof.
move=>? b c1 c2 h ????; apply: safe_step=>//.
- move=>?? h1 ??? HE.
  by case: {-1}_ / HE (erefl (IFTHENELSE b c1 c2, h1)).
move=>hf hj ? c' h' ? -> ? R.
case: {-2}_ {-1}_ / R (erefl (IFTHENELSE b c1 c2, hunion h (hunion hj hf))) (erefl (c', h'))=>// ???? [->->->->][->->].
exists h,hj; do!split=>//.
by case/boolP: (_ == _).
Qed.

Lemma triple_ifthenelse: forall J b c1 c2 P Q,
  J ⊢ ⦃ (b != 0) //\\ P ⦄ c1 ⦃ Q ⦄ ->
  J ⊢ ⦃ (b == 0) //\\ P ⦄ c2 ⦃ Q ⦄ ->
  J ⊢ ⦃ P ⦄ IFTHENELSE b c1 c2 ⦃ Q ⦄.
Proof.
move=>?????? H1 H2 n ??; case: n; first by exact: safe_zero.
by move=>?; apply: safe_ifthenelse=>?; [apply: H1| apply: H2].
Qed.

Lemma triple_repeat: forall J P c Q,
  J ⊢ ⦃ P ⦄ c ⦃ Q ⦄ ->
  Q 0 -->> P ->
  J ⊢ ⦃ P ⦄ REPEAT c ⦃ fun v => (v != 0) //\\ Q v ⦄.
Proof.
move=>?? c Q H1 H2; elim=>[|n IH] h ?; first by exact: safe_zero.
apply: safe_step=>//.
- move=>?? h1 ??? HE.
  by case: {-1}_ / HE (erefl (REPEAT c, h1)).
move=>hf hj ? c' h' ? -> ? R.
case: {-2}_ {-1}_ / R (erefl (REPEAT c, hunion h (hunion hj hf))) (erefl (c', h'))=>// ?? [->->][->->].
exists h,hj; do!split=>//.
apply: (safe_let Q); first by apply: H1.
move=>?; case=>[|n'] ?? Hn; first by exact: safe_zero.
apply: safe_ifthenelse=>EV.
- by case: n' Hn=>[?|??]; [exact: safe_zero|apply: safe_done].
apply: (safe_mono n); last by do 2!apply: ltnW.
by apply/IH/H2; move/eqP: EV=><-.
Qed.

(** *** Parallel composition *)

Lemma safe_par:
  forall (J: invariant) (Q1 Q2: assertion) n c1 h1 c2 h2,
  safe n c1 h1 (fun _ => Q1) J ->
  safe n c2 h2 (fun _ => Q2) J ->
  hdisjoint h1 h2 ->
  safe n (PAR c1 c2) (hunion h1 h2) (fun _ => Q1 ** Q2) J.
Proof.
move=>???; elim=>[|n IH] c1 h1 c2 h2 S1 S2 HD; first by exact: safe_zero.
apply: safe_step=>//.
- by move=>? /= /orP; case; [move: S1| move: S2]=>/safe_immacc/[apply]; case: (h1 _).
- move=>hf hj ? D3 ->? HE.
  move: D3; rewrite {1}/hdisj3 !hdisjoint_union_l; case; case=>??[[??]?].
  case: {-2}_ / HE (erefl (PAR c1 c2, hunion (hunion h1 h2) (hunion hj hf)))=>//.
  - move=>??? l /andP [IM1 IM2][EC1 EC2] ?; rewrite {}EC1 in IM1; rewrite {}EC2 in IM2.
    move: (safe_immacc _ _ _ _ _ _ S1 IM1); move: (safe_immacc _ _ _ _ _ _ S2 IM2).
    by case: (HD l).
  - move=>??? HE [EC1 _ EH1]; rewrite {}EC1 {}EH1 in HE.
    case: (safe_not_erroneous _ _ _ _ _ hj (hunion h2 hf) S1)=>//.
    - by rewrite {1}/hdisj3 !hdisjoint_union_r; do!split=>//; rewrite hdisjoint_sym.
    rewrite hunion_assoc in HE; rewrite -(hunion_comm hj); last by rewrite hdisjoint_union_r; split=>//; rewrite hdisjoint_sym.
    by rewrite hunion_assoc (hunion_comm hj).
  move=>??? HE [_ EC2 EH1]; rewrite {}EC2 {}EH1 in HE.
  case: (safe_not_erroneous _ _ _ _ _ hj (hunion h1 hf) S2)=>//.
  - by rewrite {1}/hdisj3 !hdisjoint_union_r; do!split=>//; rewrite hdisjoint_sym.
  rewrite -(hunion_comm h1) // hunion_assoc  in HE.
  rewrite -(hunion_comm hj); last by rewrite hdisjoint_union_r; split=>//; rewrite hdisjoint_sym.
  by rewrite hunion_assoc (hunion_comm hj).
move=>hf hj ? c' h' D3 ->? R.
case: {-2}_ {-1}_ / R (erefl (PAR c1 c2, hunion (hunion h1 h2) (hunion hj hf))) (erefl (c', h'))=>//.
- (* c1 and c2 are PURE *)
  move=>???[EC1 EC2 ->][->->]; rewrite -{}EC1 in S1; rewrite -{}EC2 in S2.
  move/safe_pure_inv: S1=>H1; move/safe_pure_inv: S2=>H2.
  exists (hunion h1 h2), hj; do!split=>//.
  by apply: safe_pure; exists h1, h2.
- (* c1 reduces *)
  move=>????? R [EC1 EC2 EH1][->->]; rewrite {}EC1 {}EC2 {}EH1 in R *.
  move: D3; rewrite {1}/hdisj3 !hdisjoint_union_l; case; case=>??[[??]?].
  rewrite hunion_assoc -(hunion_comm h2) in R; last by rewrite hdisjoint_union_r.
  rewrite hunion_assoc in R.
  case (safe_red _ _ _ _ _ _ _ _ _ R S1)=>//.
  - by rewrite {1}/hdisj3 !hdisjoint_union_r; do!split=>//; rewrite hdisjoint_sym.
  move=>h1'[hj'][D3'][->][?]?.
  move: D3'; rewrite {1}/hdisj3 !hdisjoint_union_r; case=>?[[??][??]].
  exists (hunion h1' h2), hj'; do!split=>//.
  - by rewrite hdisjoint_union_l; split=>//; rewrite hdisjoint_sym.
  - by rewrite hdisjoint_union_l.
  - rewrite hunion_assoc -(hunion_comm h2); last by rewrite hdisjoint_union_r; split=>//; rewrite hdisjoint_sym.
    by rewrite hunion_assoc.
  by apply: IH=>//; apply: (safe_mono (S n)).
(* c2 reduces *)
move=>????? R [EC1 EC2 EH1][->->]; rewrite {}EC1 {}EC2 {}EH1 in R *.
move: D3; rewrite {1}/hdisj3 !hdisjoint_union_l; case; case=>??[[??]?].
rewrite -(hunion_comm h1) // hunion_assoc -(hunion_comm h1) in R; last by rewrite hdisjoint_union_r.
rewrite hunion_assoc in R.
case (safe_red _ _ _ _ _ _ _ _ _ R S2)=>//.
- by rewrite {1}/hdisj3 !hdisjoint_union_r; do!split=>//; rewrite hdisjoint_sym.
move=>h2'[hj'][D3'][->][?]?.
move: D3'; rewrite {1}/hdisj3 !hdisjoint_union_r; case=>?[[??][??]].
exists (hunion h2' h1), hj'; do!split=>//.
- by rewrite hdisjoint_union_l; split=>//; rewrite hdisjoint_sym.
- by rewrite hdisjoint_union_l.
- rewrite hunion_assoc -(hunion_comm h1); last by rewrite hdisjoint_union_r; split=>//; rewrite hdisjoint_sym.
  by rewrite hunion_assoc.
rewrite hunion_comm; last by rewrite hdisjoint_sym.
apply: IH=>//; last by rewrite hdisjoint_sym.
by apply: (safe_mono (S n)).
Qed.

Lemma triple_par: forall J P1 c1 Q1 P2 c2 Q2,
  J ⊢ ⦃ P1 ⦄ c1 ⦃ fun _ => Q1 ⦄ ->
  J ⊢ ⦃ P2 ⦄ c2 ⦃ fun _ => Q2 ⦄ ->
  J ⊢ ⦃ P1 ** P2 ⦄ PAR c1 c2 ⦃ fun _ => Q1 ** Q2 ⦄.
Proof.
move=>??????? H1 H2 ??[?][?][?][?][?]->.
by apply: safe_par=>//; [apply: H1| apply: H2].
Qed.

(** *** The "small rules" for heap operations *)

Lemma triple_get: forall J l v,
  J ⊢ ⦃ contains l v ⦄ GET l ⦃ fun v' => (v' == v) //\\ contains l v ⦄.
Proof.
move=>? l v n h H.
have L: h l = Some v by apply: contains_eq.
case: n; first by exact: safe_zero.
move=>?; apply: safe_step=>//.
- by move=>? /= /eqP ->; rewrite L.
- move=>hf hj ??->? HE.
  case: {-2}_ / HE (erefl (GET l, hunion h (hunion hj hf)))=>// ?? E [EL EH].
  by rewrite {}EL {}EH /= L in E.
move=>hf hj ? c' h' ?->? R.
case: {-2}_ {-1}_ / R (erefl (GET l, hunion h (hunion hj hf))) (erefl (c', h'))=>// ??? E [EL EH][->->].
rewrite {}EL EH /= L /= in E; case: E=><-.
exists h, hj; do!split=>//.
by apply: safe_pure.
Qed.

Lemma triple_set: forall J l v,
  J ⊢ ⦃ valid l ⦄ SET l v ⦃ fun _ => contains l v ⦄.
Proof.
move=>? l v n h [v0 H].
have L: h l = Some v0 by apply: contains_eq.
case: n; first by exact: safe_zero.
move=>?; apply: safe_step=>//.
- by move=>? /= /eqP ->; rewrite L.
- move=>hf hj ??->? HE.
  case: {-2}_ / HE (erefl (SET l v, hunion h (hunion hj hf)))=>// ??? E [EL _ EH].
  by rewrite {}EL {}EH /= L in E.
move=>hf hj ? c' h' D3 ->? R.
case: {-2}_ {-1}_ / R (erefl (SET l v, hunion h (hunion hj hf))) (erefl (c', h'))=>// ??? E [->->->][->->].
rewrite H in D3; move: D3; rewrite {1}/hdisj3 /=; case=>HDJ [HDF ?].
exists (hsing l v), hj; do!split=>//.
- by move=>l0; move: (HDJ l0)=>/=; case: eqP=>?; case=>//; [right|left|left].
- by move=>l0; move: (HDF l0)=>/=; case: eqP=>?; case=>//; [right|left|left].
- by rewrite H; apply: heap_extensionality=>? /=; case: eqP.
by apply: safe_pure.
Qed.

Fixpoint valid_N (l: addr) (sz: nat) : assertion :=
  match sz with O => emp | S sz => valid l ** valid_N (l + 1) sz end.

Remark valid_N_init:
  forall sz l,
  (valid_N l sz) (hinit l sz hempty).
Proof.
elim=>[|sz IH] l /=; first by rewrite /emp.
exists (hsing l 0), (hinit (l + 1) sz hempty); do!split=>//.
- by exists 0.
- move=>? /=; case: eqP; [move=><-; right| left]=>//.
  by rewrite hinit_outside //; lia.
by apply: heap_extensionality=>? /=; case: eqP.
Qed.

Lemma triple_alloc: forall J sz,
  J ⊢ ⦃ emp ⦄ ALLOC sz ⦃ fun l => (l != 0) //\\ valid_N l sz ⦄.
Proof.
move=>? sz n ?->; case: n; first by exact: safe_zero.
move=>?; apply: safe_step=>//.
- move=>hf hj ??; rewrite hunion_empty=>->? HE.
  by case: {-2}_ / HE (erefl (ALLOC sz, hunion hj hf)).
move=>hf hj ? c' h' D3; rewrite hunion_empty=>-> ? R.
move: D3; rewrite {1}/hdisj3; case=>_[_ ?].
case: {-2}_ {-1}_ / R (erefl (ALLOC sz, hunion hj hf)) (erefl (c', h'))=>// ?? l H ?[ES EH2][->->]; rewrite {}ES {}EH2 in H *.
have INEQ: forall l0, (l <= l0 < l + sz%:Z \/ l0 < l \/ l + sz%:Z <= l0) by lia.
have D: hdisjoint (hinit l sz hempty) (hunion hj hf).
- move=>l0.
  by case: (INEQ l0)=>?; [right;apply: H | left; apply: hinit_outside].
exists (hinit l sz hempty), hj; split.
- rewrite {1}/hdisj3; do!split=>//; move=>x; case: (D x)=>/=; try by [left];
  by case: (hj _)=>//; right.
do!split=>//.
- apply: heap_extensionality=>l0 /=.
  by case: (INEQ l0)=>?; [rewrite !hinit_inside | rewrite !hinit_outside].
by apply: safe_pure; split=>//; exact: valid_N_init.
Qed.

Lemma triple_free: forall J l,
  J ⊢ ⦃ valid l ⦄ FREE l ⦃ fun _ => emp ⦄.
Proof.
move=>? l n h [v0 H].
have L: h l = Some v0 by apply: contains_eq.
case: n; first by exact: safe_zero.
move=>?; apply: safe_step=>//=.
- by move=>? /eqP ->; rewrite L.
- move=>hf hj ??->? HE.
  case: {-2}_ / HE (erefl (FREE l, hunion h (hunion hj hf)))=>// ?? E [EL EH].
  by rewrite {}EL {}EH /= L /= in E.
move=>hf hj ? c' h' D3 ->? R.
move: D3; rewrite {1}/hdisj3; case=>HDJ [HDF ?].
case: {-2}_ {-1}_ / R (erefl (FREE l, hunion h (hunion hj hf))) (erefl (c', h'))=>// ?? E [EL EH][->->]; rewrite {}EL {}EH in E *.
rewrite H in E.
exists hempty, hj; do!split=>//; try by left.
- rewrite H; apply: heap_extensionality=>? /=; case: eqP=>// <-.
  by move: (HDF l) (HDJ l); rewrite L; case=>// ->; case=>// ->.
by apply: safe_pure.
Qed.

(** *** Structural rules *)

Lemma triple_consequence_pre: forall P' J P c Q,
  J ⊢ ⦃ P' ⦄ c ⦃ Q ⦄ ->
  P -->> P' ->
  J ⊢ ⦃ P ⦄ c ⦃ Q ⦄.
Proof.
by move=>????? H H1 ???; apply/H/H1.
Qed.

Lemma safe_consequence:
  forall (Q Q': postcond) (J: invariant),
  (forall v, Q' v -->> Q v) ->
  forall n c h,
  safe n c h Q' J ->
  safe n c h Q J.
Proof.
move=>? Q' J HQ; elim=>[|n IH] c ? HS; first by exact: safe_zero.
case: {-2}_ _ _ {-2}_ {-2}_ / HS (erefl (S n)) (erefl Q') (erefl J)=>//.
- move=>????? H ? EQ ?; rewrite {}EQ in H.
  by apply/safe_done/HQ.
- move=>???????? ST [EN] EQ EJ.
  apply: safe_step=>// ????? D3 -> ? R.
  case: (ST _ _ _ _ _ D3 _ _ R)=>// h1'[hj'][?][?][?] S.
  exists h1', hj'; do!split=>//.
  rewrite {}EN {}EJ {}EQ in S *.
  by apply: IH.
Qed.

Lemma triple_consequence_post:
  forall Q' J P c Q,
  J ⊢ ⦃ P ⦄ c ⦃ Q' ⦄ ->
  (forall v, Q' v -->> Q v) ->
  J ⊢ ⦃ P ⦄ c ⦃ Q ⦄.
Proof. by move=>????? H ????; apply/safe_consequence/H. Qed.

Lemma triple_exists_pre: forall {X: Type} J (P: X -> assertion) c Q,
  (forall v, J ⊢ ⦃ P v ⦄ c ⦃ Q ⦄) ->
  J ⊢ ⦃ aexists P ⦄ c ⦃ Q ⦄.
Proof. by move=>????? H ??[v ?]; apply: (H v). Qed.

Lemma triple_simple_conj_pre: forall J (P1: Prop) P2 c Q,
  (P1 -> J ⊢ ⦃ P2 ⦄ c ⦃ Q ⦄) ->
  J ⊢ ⦃ P1 //\\ P2 ⦄ c ⦃ Q ⦄.
Proof. by move=>????? H ??[??]; apply: H. Qed.

Lemma triple_or: forall J P c Q P' Q',
  J ⊢ ⦃ P ⦄ c ⦃ Q ⦄ -> J ⊢ ⦃ P' ⦄ c ⦃ Q' ⦄ ->
  J ⊢ ⦃ aor P P' ⦄ c ⦃ fun v => aor (Q v) (Q' v) ⦄.
Proof.
move=>?????? H1 H2 ??[?|?].
- by apply/safe_consequence/H1=>// ???; left.
- by apply/safe_consequence/H2=>// ???; right.
Qed.

Lemma safe_and: forall J Q Q',
  precise J ->
  forall n c h,
  safe n c h Q J -> safe n c h Q' J -> safe n c h (fun v => aand (Q v) (Q' v)) J.
Proof.
move=>J Q Q' HP; elim=>[|n IH] c h HS1 HS2; first by exact: safe_zero.
case: {-2}_ {-2}_ {-2}_ {-2}_ {-2}_ / HS1 (erefl (S n)) (erefl c) (erefl h) (erefl Q)  (erefl J)=>//;
case: {-2}_ {-2}_ {-2}_ {-2}_ {-2}_ / HS2 (erefl (S n)) (erefl c) (erefl h) (erefl Q') (erefl J)=>//.
- move=>????? Q1 ?? EH1 ??????? Q2 ? [EV] EH2 ??; rewrite {}EH2 {}EH1 {}EV in Q1 Q2 *.
  by apply: safe_done.
- by move=>????? NP ??????????????? EC; rewrite -EC in NP.
- by move=>???????????????? NP ???? EC; rewrite EC in NP.
- move=>???????? ST1 [EN1] EC1 _ EQ1 EJ1 ???????? ST2 [EN2] EC2 EH2 EQ2 EJ2.
  apply: safe_step=>// hf ???? D3 -> HJ R.
  rewrite {}EC2 in R ST2; rewrite {}EH2 in D3 R ST2; rewrite EJ2 in HJ ST2.
  case: (ST1 _ _ _ _ _ D3 _ _ R)=>// h1' [hj' ][]; rewrite {1}/hdisj3; case =>?[??][E' ][HJ' ]S1.
  case: (ST2 _ _ _ _ _ D3 _ _ R)=>// h1''[hj''][]; rewrite {1}/hdisj3; case =>?[??][E''][HJ'']S2.
  rewrite E' in E''.
  have EQJ': hj' = hj''.
  - rewrite EJ1 in HJ' HJ''.
    apply: (HP _ (hunion h1' hf) _ (hunion h1'' hf))=>//.
    - by rewrite hdisjoint_union_r; split=>//; rewrite hdisjoint_sym.
    - by rewrite hdisjoint_union_r; split=>//; rewrite hdisjoint_sym.
    do 2!(rewrite (hunion_comm hf); last by rewrite hdisjoint_sym).
    rewrite -!hunion_assoc.
    rewrite (hunion_comm h1'); last by rewrite hdisjoint_union_r.
    by rewrite (hunion_comm h1''); last by rewrite hdisjoint_union_r.
  have EQ1': h1' = h1''.
  - apply: (hunion_invert_l _ _ (hunion hj' hf))=>//.
    - by rewrite -EQJ' in E''.
    - by rewrite hdisjoint_union_r.
    by rewrite EQJ' hdisjoint_union_r.
  exists h1', hj'; do!split=>//.
  - by rewrite EJ2.
  rewrite {}EN2 {}EN1 {}EJ2 {}EJ1 {}EQ2 {}EQ1 in S1 S2 *; rewrite -{}EQ1' in S2.
  by apply: IH.
Qed.

Lemma triple_and: forall J P c Q P' Q',
  precise J ->
  J ⊢ ⦃ P ⦄ c ⦃ Q ⦄ -> J ⊢ ⦃ P' ⦄ c ⦃ Q' ⦄ ->
  J ⊢ ⦃ aand P P' ⦄ c ⦃ fun v => aand (Q v) (Q' v) ⦄.
Proof. by move=>??????? H1 H2 ??[??]; apply: safe_and=>//; [apply: H1| apply: H2]. Qed.

(** * 3. Mutual exclusion *)

(** ** 3.1.  Binary semaphores *)

(** A binary semaphore is a memory location that contains 0 if it is empty
    and 1 if it is busy. *)

Definition sem_invariant (lck: addr) (R: assertion) : assertion :=
  aexists (fun v => contains lck v ** (if v == 0 then emp else R)).

(** Acquiring a semaphore (the P operation) is achieved by atomically
    setting it to 0 until its previous value was not 0. *)

Definition SWAP (l: addr) (new_v: int) : com :=
  ATOMIC (LET (GET l) (fun old_v => SEQ (SET l new_v) (PURE old_v))).

Definition ACQUIRE (lck: addr) : com :=
  REPEAT (SWAP lck 0).

(** Releasing a semaphore (the V operation) is achieved by atomically
    setting it to 1. *)

Definition RELEASE (lck: addr) : com :=
  ATOMIC (SET lck 1).

Lemma triple_swap:
  forall lck R,
  sem_invariant lck R ⊢ ⦃ emp ⦄ SWAP lck 0 ⦃ fun v => if v == 0 then emp else R ⦄.
Proof.
move=>lck R; apply: triple_atomic.
rewrite sepconj_emp {1}/sem_invariant.
apply: triple_exists_pre=>v.
apply: (triple_let _ _ _ _ (fun v' => ((v' == v) //\\ contains lck v) ** (if v == 0 then emp else R))).
- by apply/triple_frame/triple_get.
move=>?; rewrite lift_pureconj; apply: triple_simple_conj_pre=>/eqP ->.
apply: (triple_seq _ _ _ _ (contains lck 0 ** (if v == 0 then emp else R))).
- apply/triple_frame/(triple_consequence_pre (valid lck)); first by exact: triple_set.
  by move=>? ->; exists v.
apply: triple_pure; rewrite /sem_invariant => ??.
rewrite sepconj_comm lift_aexists; exists 0.
by rewrite eq_refl -(sepconj_comm emp) sepconj_emp.
Qed.

Lemma triple_acquire:
  forall lck R,
  sem_invariant lck R ⊢ ⦃ emp ⦄ ACQUIRE lck ⦃ fun _ => R ⦄.
Proof.
move=>? R.
apply (triple_consequence_post (fun v => (v != 0) //\\ (if v == 0 then emp else R))).
- apply: triple_repeat; first by exact: triple_swap.
  by rewrite eq_refl.
by move=>??[]; case: eqP.
Qed.

Lemma triple_release:
  forall lck R,
  precise R ->
  sem_invariant lck R ⊢ ⦃ R ⦄ RELEASE lck ⦃ fun _ => emp ⦄.
Proof.
move=>lck R ?; apply: triple_atomic.
rewrite sepconj_comm {1}/sem_invariant lift_aexists.
apply: triple_exists_pre=>v; rewrite sepconj_assoc.
apply: (triple_consequence_post (fun _ => contains lck 1 ** (if v == 0 then emp else R) ** R)).
- apply/triple_frame/(triple_consequence_pre (valid lck)); first by exact: triple_set.
  by move=>? ->; exists v.
move=>_ ? P.
rewrite sepconj_emp; exists 1=>/=.
apply/sepconj_imp_r/P.
case: eqP=>?; first by rewrite sepconj_emp.
by apply: sepconj_self.
Qed.

(** ** 3.2.  Critical regions *)

(** A critical region is a command that is run in mutual exclusion,
    while holding the associated lock. *)

Definition CRITREGION (lck: addr) (c: com) :=
  SEQ (ACQUIRE lck) (LET c (fun v => SEQ (RELEASE lck) (PURE v))).

Lemma triple_critregion:
  forall lck R c P Q,
  precise R ->
  emp ⊢ ⦃ P ** R ⦄ c ⦃ fun v => Q v ** R ⦄ ->
  sem_invariant lck R ⊢ ⦃ P ⦄ CRITREGION lck c ⦃ Q ⦄.
Proof.
move=>? R ? P Q ? H0; apply: (triple_seq _ _ _ _ (R ** P)).
- by rewrite -{1}(sepconj_emp P); apply/triple_frame/triple_acquire.
apply: triple_let.
- rewrite sepconj_comm -[sem_invariant _ _]sepconj_emp.
  by apply: triple_frame_invariant; exact: H0.
move=>v /=; apply: (triple_seq _ _ _ _ (emp ** Q v)).
- by rewrite sepconj_comm; apply/triple_frame/triple_release.
by rewrite sepconj_emp; apply: triple_pure.
Qed.

(** ** 3.3. Conditional critical regions *)

(** A conditional critical region (CCR), as introduced by
    Brinch-Hansen and Hoare, is a command [c] that is run in mutual
    exclusion but only when a condition [b] is true. *)

Definition CCR (lck: addr) (b: com) (c: com) :=
  REPEAT (SEQ (ACQUIRE lck)
              (LET b (fun v => IFTHENELSE v (SEQ c (SEQ (RELEASE lck) (PURE 1)))
                                            (SEQ (RELEASE lck) (PURE 0))))).

Lemma triple_ccr:
  forall lck R b c B P Q,
  precise R ->
  emp ⊢ ⦃ P ** R ⦄ b ⦃ fun v => if v == 0 then P ** R else B ⦄ ->
  emp ⊢ ⦃ B ⦄ c ⦃ fun _ => Q ** R ⦄ ->
  sem_invariant lck R ⊢ ⦃ P ⦄ CCR lck b c ⦃ fun _ => Q ⦄.
Proof.
move=>? R ??? P Q ? H1 H2.
pose Qloop := fun v : int => if v == 0 then P else Q.
apply: (triple_consequence_post (fun v => (v != 0) //\\ Qloop v));
  last by move=>?? []; rewrite /Qloop; case: eqP.
apply: triple_repeat; last by rewrite /Qloop eq_refl.
apply: (triple_seq _ _ _ _ (R ** P)).
- by rewrite -{1}(sepconj_emp P); apply/triple_frame/triple_acquire.
rewrite sepconj_comm; apply: triple_let.
- by rewrite -[sem_invariant _ _]sepconj_emp; apply/triple_frame_invariant/H1.
move=>?; apply: triple_ifthenelse.
- (* B succeeded *)
  apply: triple_seq.
  - apply: triple_consequence_pre.
    - by rewrite -[sem_invariant _ _]sepconj_emp; apply/triple_frame_invariant/H2.
    by move=>?[]; case: eqP.
  apply: (triple_seq _ _ _ _ (emp ** Q)).
  - by rewrite {1}sepconj_comm; apply/triple_frame/triple_release.
  by apply: triple_pure; rewrite sepconj_emp /Qloop.
(* B failed *)
apply: (triple_consequence_pre (P ** R)); last by move=>?[->].
apply: (triple_seq _ _ _ _ (emp ** P)).
- by rewrite {1}sepconj_comm; apply/triple_frame/triple_release.
by apply: triple_pure; rewrite sepconj_emp /Qloop.
Qed.

(** * 4. The producer/consumer problem *)

(** 4.1.  With a one-place buffer and binary semaphores *)

Module ProdCons1.

Definition PRODUCE (buff free busy: addr) (data: int) : com :=
  SEQ (ACQUIRE free)
      (SEQ (SET buff data)
           (RELEASE busy)).

Definition CONSUME (buff free busy: addr) : com :=
  SEQ (ACQUIRE busy)
      (LET (GET buff) (fun data =>
           (SEQ (RELEASE free) (PURE data)))).

Definition buffer_invariant (R: int -> assertion) (buff free busy: addr) :=
    sem_invariant free (valid buff)
 ** sem_invariant busy (aexists (fun v => contains buff v ** R v)).

Remark precise_buffer_invariant: forall (R: int -> assertion) buff,
  (forall v, precise (R v)) ->
  precise (aexists (fun v => contains buff v ** R v)).
Proof.
move=>???; apply: aexists_precise.
by apply: sepconj_param_precise=>//; apply: contains_param_precise.
Qed.

Lemma triple_consume: forall R buff free busy,
  buffer_invariant R buff free busy ⊢
           ⦃ emp ⦄ CONSUME buff free busy ⦃ fun v => R v ⦄.
Proof.
move=>R ???; apply: triple_seq.
- rewrite /buffer_invariant sepconj_comm.
  by apply/triple_frame_invariant/triple_acquire.
apply: triple_exists_pre=>v; apply: triple_let.
- by apply/triple_frame/triple_get.
move=>? /=; rewrite lift_pureconj; apply: triple_simple_conj_pre=>/eqP->.
apply: (triple_seq _ _ _ _ (emp ** R v)).
- rewrite /buffer_invariant; apply/triple_frame_invariant/triple_frame.
  apply: triple_consequence_pre; first by apply/triple_release/valid_precise.
  by move=>??; exists v.
by apply: triple_pure; rewrite sepconj_emp.
Qed.

Lemma triple_produce: forall (R: int -> assertion) buff free busy data,
  (forall v, precise (R v)) ->
  buffer_invariant R buff free busy ⊢
           ⦃ R data ⦄ PRODUCE buff free busy data ⦃ fun _ => emp ⦄.
Proof.
move=>R buff ?? data ?.
apply: (triple_seq _ _ _ _ (valid buff ** R data)).
- rewrite /buffer_invariant; apply: triple_frame_invariant.
  rewrite -{1}(sepconj_emp (R data)); apply: triple_frame.
  by exact: triple_acquire.
apply: (triple_seq _ _ _ _ (contains buff data ** R data)).
- by apply/triple_frame/triple_set.
rewrite /buffer_invariant sepconj_comm; apply: triple_frame_invariant.
apply: triple_consequence_pre.
- by apply/triple_release/precise_buffer_invariant.
by move=>??; exists data.
Qed.

End ProdCons1.

(** ** 4.2. With an unbounded buffer implemented as a list *)

Module ProdCons2.

Definition PRODUCE (buff: addr) (data: int) : com :=
  LET (ALLOC 2) (fun a =>
    SEQ (SET a data)
        (ATOMIC (LET (GET buff) (fun prev =>
                   SEQ (SET (a + 1) prev) (SET buff a))))).

Definition POP (buff: addr) : com :=
  REPEAT (ATOMIC (
    LET (GET buff) (fun b =>
        IFTHENELSE b
          (LET (GET (b + 1)) (fun next => SEQ (SET buff next) (PURE b)))
          (PURE 0)))).

Definition CONSUME (buff: addr) : com :=
  LET (POP buff) (fun b =>
  LET (GET b) (fun data =>
    SEQ (FREE b) (SEQ (FREE (b + 1)) (PURE data)))).

Fixpoint list_invariant (R: int -> assertion) (l: seq int) (p: addr) : assertion :=
  match l with
  | nil => (p == 0) //\\ emp
  | x :: l => (p != 0) //\\ aexists (fun q => contains p x ** contains (p + 1) q ** R x ** list_invariant R l q)
  end.

Definition buffer_invariant (R: int -> assertion) (buff: addr) : assertion :=
  aexists (fun l => aexists (fun p => contains buff p ** list_invariant R l p)).

Lemma triple_produce: forall R buff data,
  buffer_invariant R buff ⊢
           ⦃ R data ⦄ PRODUCE buff data ⦃ fun _ => emp ⦄.
Proof.
move=>R ? data; apply: triple_let.
- by rewrite -(sepconj_emp (R data)); apply/triple_frame/triple_alloc.
move=>a /=; rewrite lift_pureconj; apply: triple_simple_conj_pre=>?.
rewrite !sepconj_assoc sepconj_emp.
apply: (triple_seq _ _ _ _ (contains a data ** valid (a + 1) ** R data)).
- by apply/triple_frame/triple_set.
apply: triple_atomic; rewrite sepconj_comm /buffer_invariant.
rewrite lift_aexists; apply: triple_exists_pre=>l.
rewrite lift_aexists; apply: triple_exists_pre=>p.
rewrite sepconj_assoc; apply: triple_let.
- by apply/triple_frame/triple_get.
move=>? /=; rewrite lift_pureconj; apply: triple_simple_conj_pre=>/eqP->.
apply: triple_seq.
- rewrite (sepconj_pick3 (valid (a + 1))) sepconj_pick2.
  apply (triple_frame _ _ _ (fun _: int => contains (a + 1) p)). (* `apply:` fails for some reason *)
  by exact: triple_set.
rewrite sepconj_pick2; apply: triple_consequence_post.
- apply/triple_frame/triple_consequence_pre; first by exact: triple_set.
  by move=>??; exists p.
move=>? /=; rewrite sepconj_emp.
rewrite -(sepconj_swap3 (list_invariant R l p)) (sepconj_pick2 (contains a data)).
move=>h A; exists (data :: l), a.
move: h A; apply: sepconj_imp_r=>?? /=; split=>//.
by exists p.
Qed.

Lemma triple_pop: forall R buff,
  buffer_invariant R buff ⊢
           ⦃ emp ⦄ POP buff ⦃ fun p => aexists (fun x => contains p x ** valid (p + 1) ** R x) ⦄.
Proof.
move=>R buff.
pose Qloop := fun p => if p == 0 then emp else aexists (fun x => contains p x ** valid (p + 1) ** R x).
apply: (triple_consequence_post (fun p => (p != 0) //\\ Qloop p));
  last by rewrite /Qloop=>??[]; case: eqP.
apply: triple_repeat; last by rewrite /Qloop eq_refl.
apply: triple_atomic; rewrite sepconj_emp.
apply: triple_exists_pre=>l.
apply: triple_exists_pre=>p.
apply: triple_let.
- by apply/triple_frame/triple_get.
move=>? /=; rewrite lift_pureconj; apply: triple_simple_conj_pre=>/eqP->.
apply: triple_ifthenelse.
- apply: triple_simple_conj_pre=>NZ; rewrite sepconj_comm.
  case: l=>[|x l] /=; rewrite lift_pureconj; apply: triple_simple_conj_pre=>H0; first by rewrite H0 in NZ.
  rewrite lift_aexists; apply: triple_exists_pre=>t.
  apply: triple_let.
  - by rewrite !sepconj_assoc sepconj_pick2; apply/triple_frame/triple_get.
  move=>? /=; rewrite lift_pureconj; apply: triple_simple_conj_pre=>/eqP->.
  rewrite -!sepconj_assoc sepconj_comm !sepconj_assoc.
  apply: triple_seq.
  - apply (triple_frame _ _ _ (fun _: int => contains buff t)). (* `apply:` fails for some reason *)
    apply: triple_consequence_pre; first by exact: triple_set.
    by move=>??; exists p.
  apply: triple_pure; rewrite /Qloop; move/negPf: NZ=>->.
  rewrite (sepconj_pick2 (contains p x)) -(sepconj_pick3 (contains buff t)) -(sepconj_pick2 (contains buff t)).
  move=>? H; rewrite lift_aexists; exists x; rewrite !sepconj_assoc.
  apply/sepconj_imp_r/H=>h' B.
  apply: (sepconj_imp_l (contains (p + 1) t)); first by move=>??; exists t.
  move: h' B; apply/sepconj_imp_r/sepconj_imp_r=>??.
  by exists l, t.
apply: triple_simple_conj_pre=>_; apply: triple_pure.
rewrite /Qloop eq_refl sepconj_emp=>??.
by exists l,p.
Qed.

Lemma triple_consume: forall R buff,
  buffer_invariant R buff ⊢
           ⦃ emp ⦄ CONSUME buff ⦃ fun data => R data ⦄.
Proof.
move=>??; apply: triple_let; first by exact: triple_pop.
move=>? /=; apply: triple_exists_pre=>p.
apply: triple_let; first by apply/triple_frame/triple_get.
move=>? /=; rewrite lift_pureconj; apply: triple_simple_conj_pre=>/eqP->.
apply: triple_seq.
- apply (triple_frame _ _ _ (fun _ => emp)). (* `apply:` fails for some reason *)
  apply: triple_consequence_pre; first by exact: triple_free.
  by move=>??; exists p.
rewrite sepconj_emp; apply: triple_seq.
- apply (triple_frame _ _ _ (fun _ => emp)). (* `apply:` fails for some reason *)
  by exact: triple_free.
by apply: triple_pure; rewrite sepconj_emp.
Qed.

End ProdCons2.

/-
Copyright (c) 2017 Daniel Selsam. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Daniel Selsam

Certified graph transformation that "reparameterizes" a specific occurrence of a stochastic choice.
-/
import .util .tensor .tfacts .compute_grad .graph .tactics .ops .predicates .lemmas .env

namespace certigrad
open list

section algebra
open T

lemma mvn_transform {shape : S} (μ σ x : T shape) (H_σ : σ > 0) :
  mvn_pdf μ σ x = (prod σ⁻¹) * mvn_pdf 0 1 ((x - μ) / σ) :=
calc  mvn_pdf μ σ x
    = prod ((sqrt ((2 * pi shape) * square σ))⁻¹ * exp ((- 2⁻¹) * (square $ (x - μ) / σ))) : rfl
... = prod ((sqrt (2 * pi shape) * σ)⁻¹ * exp ((- 2⁻¹) * (square $ (x - μ) / σ))) : by rw [sqrt_mul, sqrt_square]
... = prod (((sqrt (2 * pi shape))⁻¹ * σ⁻¹) * exp ((- 2⁻¹) * (square $ (x - μ) / σ))) : by rw [T.mul_inv_pos (sqrt_pos two_pi_pos) H_σ]
... = (prod σ⁻¹) * prod ((sqrt (2 * pi shape))⁻¹ * exp ((- 2⁻¹) * (square $ (x - μ) / σ))) : by simp [prod_mul]
... = (prod σ⁻¹) * prod ((sqrt ((2 * pi shape) * square 1))⁻¹ * exp ((- 2⁻¹) * (square ((((x - μ) / σ) - 0) / 1)))) : by simp [T.div_one, square]
... = (prod σ⁻¹) * mvn_pdf 0 1 ((x - μ) / σ) : rfl

end algebra

open sprog

lemma mvn_reparam_same {shape oshape : S} {μ σ : T shape} (f : dvec T [shape] → T oshape) : σ > 0 →
E (prim (rand.op.mvn shape) ⟦μ, σ⟧) f
=
E (bind (prim (rand.op.mvn_std shape) ⟦⟧) (λ (x : dvec T [shape]), ret ⟦(x^.head * σ) + μ⟧)) f :=
assume (H_σ_pos : σ > 0),
begin
simp only [E.E_bind, E.E_ret],
dunfold E rand.op.mvn rand.op.pdf T.dintegral dvec.head rand.pdf.mvn rand.pdf.mvn_std,
simp only [λ x, mvn_transform μ σ x H_σ_pos],

assert H : ∀ (x : T shape), ((σ * x + μ + -μ) / σ) = x,
  { intro x, simp only [add_assoc, add_neg_self, add_zero], rw mul_comm, rw -T.mul_div_mul_alt, rw T.div_self H_σ_pos, rw mul_one},
definev g : T shape → T oshape := λ (x : T shape), T.mvn_pdf 0 1 ((x - μ) / σ) ⬝ f ⟦x⟧,
assert H_rhs : ∀ (x : T shape), T.mvn_pdf 0 1 x ⬝ f ⟦x * σ + μ⟧ = g (σ * x + μ),
{ intro x, dsimp, rw H, simp },

rw funext H_rhs,
rw T.integral_scale_shift_var g,
dsimp,
simp [T.smul_group]
end

def reparameterize_pre (eshape : S) : list node → env → Prop
| [] inputs := true
| (⟨⟨ref, shape⟩, [⟨μ, .(shape)⟩, ⟨σ, .(shape)⟩], operator.rand (rand.op.mvn .(shape))⟩::nodes) inputs :=
  eshape = shape ∧ σ ≠ μ ∧ 0 < env.get (σ, shape) inputs
| (⟨ref, parents, operator.det op⟩::nodes) inputs := reparameterize_pre nodes (env.insert ref (op^.f (env.get_ks parents inputs)) inputs)
| (⟨ref, parents, operator.rand op⟩::nodes) inputs := ∀ x, reparameterize_pre nodes (env.insert ref x inputs)

def reparameterize (fname : ID) : list node → list node
| [] := []

| (⟨⟨ident, shape⟩, [⟨μ, .(shape)⟩, ⟨σ, .(shape)⟩], operator.rand (rand.op.mvn .(shape))⟩::nodes) :=

 (⟨(fname, shape), [],                                       operator.rand (rand.op.mvn_std shape)⟩
::⟨(ident, shape),   [(fname, shape), (σ, shape), (μ, shape)], operator.det (ops.mul_add shape)⟩
::nodes)

| (n::nodes) := n :: reparameterize nodes

theorem reparameterize_correct (costs : list ID) :
∀ (nodes : list node) (inputs : env) (fref : reference),
  reparameterize_pre fref.2 nodes inputs →
  uniq_ids nodes inputs →
  all_parents_in_env inputs nodes →
  (¬ env.has_key fref inputs) →  fref ∉ map node.ref nodes →
  (fref.1 ∉ costs) →
E (graph.to_dist (λ env₀, ⟦sum_costs env₀ costs⟧) inputs (reparameterize fref.1 nodes)) dvec.head
=
E (graph.to_dist (λ env₀, ⟦sum_costs env₀ costs⟧) inputs nodes) dvec.head

| [] _ _ _ _ _ _ _ _ := rfl

| (⟨⟨ident, shape⟩, [⟨μ, .(shape)⟩, ⟨σ, .(shape)⟩], operator.rand (rand.op.mvn .(shape))⟩::nodes) inputs fref H_pre H_uids H_ps_in_env H_fresh₁ H_fresh₂ H_not_cost :=
begin
dunfold reparameterize,
assertv H_eshape : fref.2 = shape := H_pre^.left,
assert H_fref : fref = (fref.1, shape),
{ clear reparameterize_correct, cases fref with fref₁ fref₂, dsimp at H_eshape, rw H_eshape },

assertv H_σ_μ : σ ≠ μ := H_pre^.right^.left,

dunfold graph.to_dist operator.to_dist,
dsimp,
simp [E.E_bind],
erw (mvn_reparam_same _ H_pre^.right^.right),
simp [E.E_bind, E.E_ret],
dunfold dvec.head,
dsimp,
apply congr_arg, apply funext, intro x,

assertv H_μ_in : env.has_key (μ, shape) inputs := H_ps_in_env^.left (μ, shape) (mem_cons_self _ _),
assertv H_σ_in : env.has_key (σ, shape) inputs := H_ps_in_env^.left (σ, shape) (mem_cons_of_mem _ (mem_cons_self _ _)),
assertv H_ident_nin : ¬ env.has_key (ident, shape) inputs := H_uids^.left,

assertv H_μ_neq_ident : (μ, shape) ≠ (ident, shape) := env_in_nin_ne H_μ_in H_ident_nin,
assertv H_σ_neq_ident : (σ, shape) ≠ (ident, shape) := env_in_nin_ne H_σ_in H_ident_nin,

assertv H_μ_neq_fref : (μ, shape) ≠ (fref.1, shape) := eq.rec_on H_fref (env_in_nin_ne H_μ_in H_fresh₁),
assertv H_σ_neq_fref : (σ, shape) ≠ (fref.1, shape) := eq.rec_on H_fref (env_in_nin_ne H_σ_in H_fresh₁),
assertv H_ident_neq_fref : (ident, shape) ≠ (fref.1, shape) := eq.rec_on H_fref (mem_not_mem_neq mem_of_cons_same H_fresh₂),

dunfold env.get_ks,
tactic.dget_dinsert,

rw (env.insert_insert_flip _ _ _ H_ident_neq_fref),
dsimp,

definev fval : T shape := dvec.head x,
definev fval_inputs : env := env.insert (ident, shape)
                                        (det.op.f (ops.mul_add shape)
                                                  ⟦dvec.head x, (env.get (σ, shape) inputs : T shape), (env.get (μ, shape) inputs : T shape)⟧)
                                         inputs,

assertv H_ps_in_env_next : all_parents_in_env fval_inputs nodes := H_ps_in_env^. right _,
assertv H_fresh₁_next : ¬ env.has_key (fref.1, shape) fval_inputs :=
  eq.rec_on H_fref (env_not_has_key_insert (eq.rec_on (eq.symm H_fref) $ ne.symm H_ident_neq_fref) H_fresh₁),

assertv H_fresh₂_next : (fref.1, shape) ∉ map node.ref nodes := eq.rec_on H_fref (not_mem_of_not_mem_cons H_fresh₂),

erw (@to_dist_congr_insert costs nodes fval_inputs (fref.1, shape) fval H_ps_in_env_next H_fresh₁_next H_fresh₂_next H_not_cost),
dsimp,
dunfold det.op.f,
rw [add_comm, mul_comm],
reflexivity
end

| (⟨(ref, shape), [], operator.det op⟩::nodes) inputs fref H_pre H_uids H_ps_in_env H_fresh₁ H_fresh₂ H_not_cost :=
begin
dunfold reparameterize graph.to_dist operator.to_dist,
simp [E.E_bind, E.E_ret],
definev x : T shape := op^.f (env.get_ks [] inputs),
assertv H_pre_next : reparameterize_pre fref.2 nodes (env.insert (ref, shape) x inputs) := by apply H_pre,
assertv H_ps_in_env_next : all_parents_in_env (env.insert (ref, shape) x inputs) nodes := H_ps_in_env^.right _,
assertv H_fresh₁_next : ¬ env.has_key fref (env.insert (ref, shape) x inputs) := env_not_has_key_insert (ne_of_not_mem_cons H_fresh₂) H_fresh₁,
assertv H_fresh₂_next : fref ∉ map node.ref nodes := not_mem_of_not_mem_cons H_fresh₂,
apply (reparameterize_correct _ _ fref H_pre_next (H_uids^.right _) H_ps_in_env_next H_fresh₁_next H_fresh₂_next H_not_cost)
end

| (⟨(ref, shape), [], operator.rand op⟩::nodes) inputs fref H_pre H_uids H_ps_in_env H_fresh₁ H_fresh₂ H_not_cost :=
begin
dunfold reparameterize graph.to_dist,
simp [E.E_bind],
apply congr_arg, apply funext, intro x,
assertv H_pre_next : reparameterize_pre fref.2 nodes (env.insert (ref, shape) (dvec.head x) inputs) := by apply H_pre,
assertv H_ps_in_env_next : all_parents_in_env (env.insert (ref, shape) (dvec.head x) inputs) nodes := H_ps_in_env^.right x^.head,
assertv H_fresh₁_next : ¬ env.has_key fref (env.insert (ref, shape) x^.head inputs) := env_not_has_key_insert (ne_of_not_mem_cons H_fresh₂) H_fresh₁,
assertv H_fresh₂_next : fref ∉ map node.ref nodes := not_mem_of_not_mem_cons H_fresh₂,
apply (reparameterize_correct _ _ fref H_pre_next (H_uids^.right _) H_ps_in_env_next H_fresh₁_next H_fresh₂_next H_not_cost)
end

| (⟨(ref, shape), [(parent₁, shape₁)], operator.det op⟩::nodes) inputs fref H_pre H_uids H_ps_in_env H_fresh₁ H_fresh₂ H_not_cost :=
begin
dunfold reparameterize graph.to_dist operator.to_dist,
simp [E.E_bind, E.E_ret],
definev x : T shape := det.op.f op (env.get_ks [(parent₁, shape₁)] inputs),
assertv H_pre_next : reparameterize_pre fref.2 nodes (env.insert (ref, shape) x inputs) := by apply H_pre,
assertv H_ps_in_env_next : all_parents_in_env (env.insert (ref, shape) x inputs) nodes := H_ps_in_env^.right x,
assertv H_fresh₁_next : ¬ env.has_key fref (env.insert (ref, shape) x inputs) := env_not_has_key_insert (ne_of_not_mem_cons H_fresh₂) H_fresh₁,
assertv H_fresh₂_next : fref ∉ map node.ref nodes := not_mem_of_not_mem_cons H_fresh₂,
apply (reparameterize_correct _ _ fref H_pre_next (H_uids^.right _) H_ps_in_env_next H_fresh₁_next H_fresh₂_next H_not_cost)
end

| (⟨(ref, shape), [(parent₁, shape₁), (parent₂, shape₂)], operator.det op⟩::nodes) inputs fref H_pre H_uids H_ps_in_env H_fresh₁ H_fresh₂ H_not_cost :=
begin
dunfold reparameterize graph.to_dist operator.to_dist,
simp [E.E_bind, E.E_ret],
definev x : T shape := det.op.f op (env.get_ks [(parent₁, shape₁), (parent₂, shape₂)] inputs),
assertv H_pre_next : reparameterize_pre fref.2 nodes (env.insert (ref, shape) x inputs) := by apply H_pre,
assertv H_ps_in_env_next : all_parents_in_env (env.insert (ref, shape) x inputs) nodes := H_ps_in_env^.right x,
assertv H_fresh₁_next : ¬ env.has_key fref (env.insert (ref, shape) x inputs) := env_not_has_key_insert (ne_of_not_mem_cons H_fresh₂) H_fresh₁,
assertv H_fresh₂_next : fref ∉ map node.ref nodes := not_mem_of_not_mem_cons H_fresh₂,
apply (reparameterize_correct _ _ fref H_pre_next (H_uids^.right _) H_ps_in_env_next H_fresh₁_next H_fresh₂_next H_not_cost)
end

| (⟨(ref, shape), (parent₁, shape₁) :: (parent₂, shape₂) :: (parent₃, shape₃) :: parents, operator.det op⟩::nodes) inputs fref H_pre H_uids H_ps_in_env H_fresh₁ H_fresh₂ H_not_cost :=
begin
dunfold reparameterize graph.to_dist operator.to_dist,
simp [E.E_bind, E.E_ret],
definev x : T shape := det.op.f op (env.get_ks ((parent₁, shape₁) :: (parent₂, shape₂) :: (parent₃, shape₃) :: parents) inputs),
assertv H_pre_next : reparameterize_pre fref.2 nodes (env.insert (ref, shape) x inputs) := by apply H_pre,
assertv H_ps_in_env_next : all_parents_in_env (env.insert (ref, shape) x inputs) nodes := H_ps_in_env^.right x,
assertv H_fresh₁_next : ¬ env.has_key fref (env.insert (ref, shape) x inputs) := env_not_has_key_insert (ne_of_not_mem_cons H_fresh₂) H_fresh₁,
assertv H_fresh₂_next : fref ∉ map node.ref nodes := not_mem_of_not_mem_cons H_fresh₂,
apply (reparameterize_correct _ _ fref H_pre_next (H_uids^.right _) H_ps_in_env_next H_fresh₁_next H_fresh₂_next H_not_cost)
end

def reparam : graph → graph
| g := ⟨reparameterize (ID.str label.ε) g^.nodes, g^.costs, g^.targets, g^.inputs⟩

end certigrad

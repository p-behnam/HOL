open preamble intSimps;
open MiniMLTheory Print_astTheory;

val _ = new_theory "Print_astTermination";

(* ----------------- Termination proofs for Print_astTheory --------------- *)

fun register name def ind = 
  let val _ = save_thm (name ^ "_def", def);
      val _ = save_thm (name ^ "_ind", ind);
      val _ = computeLib.add_persistent_funs [(name ^ "_def", def)];
  in
    ()
  end


val (num_to_string_def, num_to_string_ind) =
  tprove_no_defn ((num_to_string_def, num_to_string_ind),
  wf_rel_tac `measure (\(x,y).x)` >>
  srw_tac [ARITH_ss] []);
val _ = register "num_to_string" num_to_string_def num_to_string_ind;

val (spaces_def, spaces_ind) =
  tprove_no_defn ((spaces_def, spaces_ind),
  wf_rel_tac `measure (\(x,y).x)` >>
  srw_tac [ARITH_ss] []);
val _ = register "spaces" spaces_def spaces_ind;

val (join_trees_def, join_trees_ind) =
  tprove_no_defn ((join_trees_def, join_trees_ind),
  wf_rel_tac `measure (\(_,x).LENGTH x)` >>
  srw_tac [ARITH_ss] []);
val _ = register "join_trees" join_trees_def join_trees_ind;

val (pat_to_tok_tree_def, pat_to_tok_tree_ind) =
  tprove_no_defn ((pat_to_tok_tree_def, pat_to_tok_tree_ind),
  wf_rel_tac `measure (\(_,x). pat_size x)` >>
  rw [] >|
  [decide_tac,
   induct_on `v8` >>
       rw [] >>
       fs [pat_size_def] >>
       decide_tac]);
val _ = register "pat_to_tok_tree" pat_to_tok_tree_def pat_to_tok_tree_ind;

val (exp_to_tok_tree_def, exp_to_tok_tree_ind) =
  tprove_no_defn ((exp_to_tok_tree_def, exp_to_tok_tree_ind),
  wf_rel_tac `measure (\x. case x of INL (_,_,e) => exp_size e
                                   | INR (INL (_,_,p,e)) => exp_size e + 1
                                   | INR (INR (_,_,v1,v2,e)) => exp_size e + 1)` >>
  rw [] >>
  TRY (induct_on `funs`) >>
  TRY (induct_on `pes`) >>
  TRY (induct_on `es`) >>
  TRY (induct_on `v33`) >>
  rw [exp_size_def] >>
  fs [exp_size_def] >>
  rw [exp_size_def] >>
  decide_tac);
val _ = register "exp_to_tok_tree" exp_to_tok_tree_def exp_to_tok_tree_ind;

val (type_to_tok_tree_def, type_to_tok_tree_ind) =
  tprove_no_defn ((type_to_tok_tree_def, type_to_tok_tree_ind),
  wf_rel_tac `measure t_size` >>
  srw_tac [ARITH_ss] [] >>
  cases_on `ts` >>
  fs [] >>
  induct_on `t` >>
  rw [] >>
  fs [t_size_def] >>
  decide_tac);

val _ = register "type_to_tok_tree" type_to_tok_tree_def type_to_tok_tree_ind;

val tok_to_string_def =
  save_thm ("tok_to_string_def",SIMP_RULE (srw_ss()) [] tok_to_string_def);

val _ = 
  computeLib.add_persistent_funs [("tok_to_string_def", tok_to_string_def)];

val _ = export_theory ();

structure smallfootParser :> smallfootParser =
struct

(*
quietdec := true;
loadPath := 
            (concat Globals.HOLDIR "/examples/separationLogic/src") :: 
            (concat Globals.HOLDIR "/examples/separationLogic/src/smallfoot") :: 
            !loadPath;

map load ["finite_mapTheory", "smallfootTheory", "Parser", "Lexer","Lexing", "Nonstdio"
	  "Parsetree"];
show_assums := true;
*)

open HolKernel Parse boolLib finite_mapTheory smallfootTheory smallfootSyntax
     Parsetree;


(*
quietdec := false;
*)


fun createLexerStream (is : BasicIO.instream) =
  Lexing.createLexer (fn buff => fn n => Nonstdio.buff_input is buff 0 n)


fun parseExprPlain lexbuf =
    let val expr = Parser.program Lexer.token lexbuf
    in
	Parsing.clearParser();
	expr
    end
    handle exn => (Parsing.clearParser(); raise exn);

fun parse file =
    let val is     = Nonstdio.open_in_bin file
        val lexbuf = createLexerStream is
	val expr   = parseExprPlain lexbuf
	             handle exn => (BasicIO.close_in is; raise exn)
    in 
        BasicIO.close_in is;
	expr
    end

(*
val file = "/home/tuerk/Downloads/smallfoot/EXAMPLES/business2.sf";
val file = "/home/tt291/Downloads/smallfoot/EXAMPLES/business2.sf";

val prog = parse file;
*)


exception smallfoot_unsupported_feature_exn of string;


fun smallfoot_p_expression2term (Pexp_ident x) =
   let
      val var_term = string2smallfoot_var x;
      val term = mk_comb(smallfoot_p_var_term, var_term) 
   in 
      (term, HOLset.add (empty_tmset, var_term))
   end
| smallfoot_p_expression2term (Pexp_num n) =
     (mk_comb(smallfoot_p_const_term, numLib.term_of_int n), empty_tmset)
| smallfoot_p_expression2term (Pexp_prefix _) =
	Raise (smallfoot_unsupported_feature_exn "Pexp_prefix") 
| smallfoot_p_expression2term (Pexp_infix (opstring, e1, e2)) =
	let
		val opterm = if (opstring = "-") then smallfoot_p_sub_term else
			if (opstring = "+") then smallfoot_p_add_term else
			if (opstring = "==") then smallfoot_p_equal_term else
			if (opstring = "!=") then smallfoot_p_unequal_term else
			if (opstring = "<=") then smallfoot_p_lesseq_term else
			if (opstring = "<") then smallfoot_p_less_term else
			if (opstring = ">=") then smallfoot_p_greater_term else
			if (opstring = ">") then smallfoot_p_greatereq_term else
			Raise (smallfoot_unsupported_feature_exn ("Pexp_infix "^opstring));
		val (t1,vs1) = smallfoot_p_expression2term e1;
		val (t2,vs2) = smallfoot_p_expression2term e2;
	in
		(list_mk_comb (opterm, [t1, t2]), HOLset.union (vs1, vs2))
	end;



fun smallfoot_a_expression2term (Aexp_ident v) =
    let
	val var_term = string2smallfoot_var v;
    in
	(mk_comb(smallfoot_ae_var_term, string2smallfoot_var v),
	 HOLset.add (empty_tmset, var_term))
    end
| smallfoot_a_expression2term (Aexp_num n) =
	(if n = 0 then smallfoot_ae_null_term else
  	mk_comb(smallfoot_ae_const_term, numLib.term_of_int n),
	 empty_tmset)
| smallfoot_a_expression2term _ =
	Raise (smallfoot_unsupported_feature_exn "Aexp");




(*
val aexp1 = Aexp_ident "test";
val aexp2 = Aexp_num 0;
val aexp3 = Aexp_num 5;
val tag = "tl";
val tagL = "l";
val tagR = "r";

val ap1 = Aprop_equal(aexp1, aexp2);
val ap2 = Aprop_false;
val ap3 = Aprop_infix ("<", aexp2, aexp1);


val pl = [(tagL, aexp1), (tagR, aexp2)]
*)


val tag_a_expression_fmap_emp_term = ``FEMPTY:(smallfoot_tag |-> smallfoot_a_expression)``;
val tag_a_expression_fmap_update_term = ``FUPDATE:(smallfoot_tag |-> smallfoot_a_expression)->
(smallfoot_tag # smallfoot_a_expression)->(smallfoot_tag |-> smallfoot_a_expression)``;


fun tag_a_expression_list2term [] = (tag_a_expression_fmap_emp_term,empty_tmset) |
      tag_a_expression_list2term ((tag,aexp1)::l) =
		let
			val tag_term = string2smallfoot_tag tag;
			val (exp_term,new_var_set) = smallfoot_a_expression2term aexp1;
			val p = pairLib.mk_pair (tag_term,exp_term);
			val (rest,rest_var_set) = tag_a_expression_list2term l;
			val comb_term = list_mk_comb (tag_a_expression_fmap_update_term, [rest, p]);
			val comb_var_set = HOLset.union (new_var_set, rest_var_set);
		in
                        (comb_term, comb_var_set)
		end;



fun smallfoot_a_space_pred2term (Aspred_list (tag,aexp1)) =
        let
	    val (exp_term, var_set) = smallfoot_a_expression2term aexp1;
            val list_term = list_mk_comb(smallfoot_ap_list_term, [string2smallfoot_tag tag, 
			     exp_term]);
        in
            (list_term, var_set)
        end
|     smallfoot_a_space_pred2term (Aspred_listseg (tag,aexp1,aexp2)) =
        let
	    val (exp_term1, var_set1) = smallfoot_a_expression2term aexp1;
	    val (exp_term2, var_set2) = smallfoot_a_expression2term aexp2;
	    val comb_term = list_mk_comb(smallfoot_ap_list_seg_term, [string2smallfoot_tag tag, 
			     exp_term1, exp_term2]);
        in
            (comb_term, HOLset.union (var_set1, var_set2))
        end
|     smallfoot_a_space_pred2term (Aspred_dlseg _) =
  	Raise (smallfoot_unsupported_feature_exn ("Aspred_dl_seg"))
	
|     smallfoot_a_space_pred2term (Aspred_tree (tagL,tagR,aexp1)) =
        let
	    val (exp_term, var_set) = smallfoot_a_expression2term aexp1;
            val comb_term = list_mk_comb(smallfoot_ap_bintree_term, [
     			     pairLib.mk_pair(string2smallfoot_tag tagL, string2smallfoot_tag tagR), 
			     exp_term])
        in
            (comb_term, var_set)
        end
|     smallfoot_a_space_pred2term (Aspred_empty) =
	(smallfoot_ap_emp_term, empty_tmset)
|     smallfoot_a_space_pred2term (Aspred_pointsto (aexp1, pl)) =
        let
	    val (term1, var_set1) = smallfoot_a_expression2term aexp1;
	    val (term2, var_set2) = tag_a_expression_list2term pl;
	    val comb_term = list_mk_comb(smallfoot_ap_points_to_term, [term1, term2]); 
        in
            (comb_term, HOLset.union (var_set1,var_set2))
        end;






fun list_mk_comb___with_vars op_term sub_fun l =
    let
	val term_var_l = map sub_fun l;
        val (termL, setL) = unzip term_var_l;
        val set_union = foldr HOLset.union empty_tmset setL;
        val term = list_mk_comb (op_term, termL);
    in
        (term, set_union)
    end;

(*
val t = 
Aprop_ifthenelse(Aprop_equal(Aexp_ident "y", Aexp_ident "x"),
                 Aprop_spred(Aspred_list("tl", Aexp_ident "x")),
                 Aprop_spred(Aspred_list("tl", Aexp_ident "x")))

fun dest_ifthenelse (Aprop_ifthenelse (Aprop_equal (aexp1, aexp2), ap1,ap2)) =
  (aexp1, aexp2, ap1, ap2)


val (aexp1, aexp2, ap1, ap2) = dest_ifthenelse t
*)


fun smallfoot_a_proposition2term (Aprop_infix (opString, aexp1, aexp2)) =
	let
		val op_term = if (opString = "<") then smallfoot_ap_less_term else
				       if (opString = "<=") then smallfoot_ap_lesseq_term else
				       if (opString = ">") then smallfoot_ap_greater_term else
				       if (opString = ">=") then smallfoot_ap_greatereq_term else
		  		       Raise (smallfoot_unsupported_feature_exn ("Aexp_infix "^opString))
	in
		list_mk_comb___with_vars op_term smallfoot_a_expression2term [aexp1,aexp2]
	end
| smallfoot_a_proposition2term (Aprop_equal (aexp1, aexp2)) =
	list_mk_comb___with_vars smallfoot_ap_equal_term smallfoot_a_expression2term [aexp1,aexp2]
| smallfoot_a_proposition2term (Aprop_not_equal (aexp1, aexp2)) =
	list_mk_comb___with_vars smallfoot_ap_unequal_term smallfoot_a_expression2term [aexp1,aexp2]
| smallfoot_a_proposition2term (Aprop_false) =
	(smallfoot_ap_false_term, empty_tmset)
| smallfoot_a_proposition2term (Aprop_ifthenelse (Aprop_equal (aexp1, aexp2), ap1,ap2)) =
        let
           val (exp1_term, exp1_set) = smallfoot_a_expression2term aexp1;
           val (exp2_term, exp2_set) = smallfoot_a_expression2term aexp2;
           val (prop1_term, prop1_set) = smallfoot_a_proposition2term ap1;
           val (prop2_term, prop2_set) = smallfoot_a_proposition2term ap2;
	   val t = list_mk_comb (smallfoot_ap_cond_term, [exp1_term, exp2_term, prop1_term, prop2_term])
           val set_union = foldr HOLset.union exp1_set [exp2_set, prop1_set, prop2_set];
        in
	   (t, set_union) 
        end
| smallfoot_a_proposition2term (Aprop_ifthenelse (_, ap2,ap3)) =
  Raise (smallfoot_unsupported_feature_exn "Currently only equality checks are allowed as conditions in propositions")
| smallfoot_a_proposition2term (Aprop_star (ap1, ap2)) =
	list_mk_comb___with_vars smallfoot_ap_star_term smallfoot_a_proposition2term [ap1,ap2]
| smallfoot_a_proposition2term (Aprop_spred sp) =
	smallfoot_a_space_pred2term sp;




(*
	
val v = "var_name";
val n = 33;
val expr = Pexp_num 3;
val expr1 = Pexp_num 1;
val expr2 = Pexp_num 2;
val tag = "tag";
val cond = Pexp_infix("<", Pexp_num 2, Pexp_ident v)

val stm1 = Pstm_new v;
val stm2 = Pstm_dispose (Pexp_ident v);

val stmL = [Pstm_fldlookup (v, expr, tag), Pstm_assign (v, expr), Pstm_new v]

val name = "proc_name";
val rp = ["x", "y", "z"];
val vp = [expr1, expr2];

*)


fun smallfoot_fcall2term (name, (rp, vp)) =
	let
		val name_term = stringLib.fromMLstring name;

		val var_list = map string2smallfoot_var rp;
		val rp_term = listLib.mk_list (var_list, Type `:smallfoot_var`);

		val (exp_list, exp_varset_list) = unzip (map smallfoot_p_expression2term vp);
		val vp_term = listLib.mk_list (exp_list, Type `:smallfoot_p_expression`)
		
		val arg_term = pairLib.mk_pair (rp_term, vp_term);
		val arg_varset = HOLset.addList (foldr HOLset.union empty_tmset exp_varset_list,
						 var_list);
	in
		(list_mk_comb(smallfoot_prog_procedure_call_term, [name_term, arg_term]),
		 arg_varset, empty_tmset)
	end


(*
val t =
 Pstm_parallel_fcall("proc",
                                            ([], [Pexp_ident "x", Pexp_num 4]),
                                            "proc",
                                            ([],
                                             [Pexp_ident "z", Pexp_num 5]));

fun dest_Pstm_parallel_fcall (Pstm_parallel_fcall(name1,(rp1,vp1),name2,(rp2,vp2))) =
(name1,(rp1,vp1),name2,(rp2,vp2));

val (name1,(rp1,vp1),name2,(rp2,vp2)) = dest_Pstm_parallel_fcall t;

*)

fun smallfoot_parallel_fcall2term (name1, (rp1, vp1), name2, (rp2,vp2)) =
	let
		val name1_term = stringLib.fromMLstring name1;
		val name2_term = stringLib.fromMLstring name2;

		val var1_list = map string2smallfoot_var rp1;
		val rp1_term = listLib.mk_list (var1_list, Type `:smallfoot_var`);

		val var2_list = map string2smallfoot_var rp2;
		val rp2_term = listLib.mk_list (var2_list, Type `:smallfoot_var`);

		val (exp_list1, exp1_varset_list) = unzip (map smallfoot_p_expression2term vp1);
		val vp1_term = listLib.mk_list (exp_list1, Type `:smallfoot_p_expression`)

		val (exp_list2, exp2_varset_list) = unzip (map smallfoot_p_expression2term vp2);
		val vp2_term = listLib.mk_list (exp_list2, Type `:smallfoot_p_expression`)
		
		val arg1_term = pairLib.mk_pair (rp1_term, vp1_term);
		val arg2_term = pairLib.mk_pair (rp2_term, vp2_term);

		val arg_varset = HOLset.addList (foldr HOLset.union empty_tmset (exp1_varset_list @ exp2_varset_list),
						 (var1_list @ var2_list));
	in
		(list_mk_comb(smallfoot_prog_parallel_procedure_call_term, [name1_term, arg1_term,name2_term, arg2_term]),
		 arg_varset, empty_tmset)
	end




fun unzip3 [] = ([],[],[])
  | unzip3 ((a,b,c)::L) =
    let
	val (aL,bL,cL) = unzip3 L;
    in 
       (a::aL, b::bL, c::cL)
    end;



(*
  val (wp,rp,d_opt,Pterm) = (write_var_set,read_var_set,SOME arg_refL,preCond);
*)

fun mk_smallfoot_prop_input wp rp d_opt Pterm =
    let
	val (d_list,rp) = if isSome d_opt then
		        let
			    val d_list = valOf d_opt;
		            val rp = HOLset.addList(rp,d_list);
                            val rp = HOLset.difference (rp, wp);
			in
			    (d_list,rp)
			end
                     else
			let
                            val rp = HOLset.difference (rp, wp);
			    val d_list = append (HOLset.listItems wp) (HOLset.listItems rp);
			in
			    (d_list, rp)
			end;
        val d = listLib.mk_list(d_list,Type `:smallfoot_var`);
	val rp_term = pred_setSyntax.prim_mk_set (HOLset.listItems rp, Type `:smallfoot_var`);
	val wp_term = pred_setSyntax.prim_mk_set (HOLset.listItems wp, Type `:smallfoot_var`);
        val wp_rp_pair_term = pairLib.mk_pair (wp_term, rp_term);
    in
        list_mk_comb (smallfoot_prop_input_ap_distinct_term, [wp_rp_pair_term, d, Pterm])
    end;



(*returns the term, the set of read variables and a set of written variables*)
fun smallfoot_p_statement2term (Pstm_assign (v, expr)) =
    let
        val var_term = string2smallfoot_var v;
        val (exp_term, read_var_set) = smallfoot_p_expression2term expr;
        val comb_term = list_mk_comb (smallfoot_prog_assign_term, [var_term, exp_term]);
	val write_var_set = HOLset.add (empty_tmset, var_term);
    in
        (comb_term, read_var_set, write_var_set)
    end
| smallfoot_p_statement2term (Pstm_fldlookup (v, expr, tag)) =
    let
        val var_term = string2smallfoot_var v;
        val (exp_term, read_var_set) = smallfoot_p_expression2term expr;
        val comb_term = list_mk_comb (smallfoot_prog_field_lookup_term, [var_term, exp_term, string2smallfoot_tag tag]);
	val write_var_set = HOLset.add (empty_tmset, var_term);
    in
        (comb_term, read_var_set, write_var_set)
    end
| smallfoot_p_statement2term (Pstm_fldassign (expr1, tag, expr2)) =
    let
        val (exp_term1, read_var_set1) = smallfoot_p_expression2term expr1;
        val (exp_term2, read_var_set2) = smallfoot_p_expression2term expr2;
        val comb_term = list_mk_comb (smallfoot_prog_field_assign_term, [exp_term1, string2smallfoot_tag tag, exp_term2]);
	val read_var_set = HOLset.union (read_var_set1, read_var_set2);
	val write_var_set = empty_tmset;
    in
        (comb_term, read_var_set, write_var_set)
    end
| smallfoot_p_statement2term (Pstm_new v) =
    let
        val var_term = string2smallfoot_var v;
        val comb_term = mk_comb (smallfoot_prog_new_term, var_term);
	val write_var_set = HOLset.add (empty_tmset, var_term);
        val read_var_set = empty_tmset;
    in
        (comb_term, read_var_set, write_var_set)
    end  
| smallfoot_p_statement2term (Pstm_dispose expr) =
    let
        val (exp_term, read_var_set) = smallfoot_p_expression2term expr;
        val comb_term = mk_comb (smallfoot_prog_dispose_term, exp_term);
	val write_var_set = empty_tmset;
    in
        (comb_term, read_var_set, write_var_set)
    end  
| smallfoot_p_statement2term (Pstm_block stmL) =
	let
		val (termL, read_var_setL, write_var_setL) = unzip3 (map smallfoot_p_statement2term stmL);		
		val list_term = listLib.mk_list (termL, Type `:smallfoot_prog`);
		val comb_term = mk_comb (smallfoot_prog_block_term, list_term);
                val read_var_set = foldr HOLset.union empty_tmset read_var_setL;
                val write_var_set = foldr HOLset.union empty_tmset write_var_setL;
	in
           (comb_term, read_var_set, write_var_set)
        end
| smallfoot_p_statement2term (Pstm_if (cond, stm1, stm2)) =
	let
		val (c_term, c_read_var_set) = smallfoot_p_expression2term cond;
		val (stm1_term,read_var_set1,write_var_set1) = smallfoot_p_statement2term stm1;
		val (stm2_term,read_var_set2,write_var_set2) = smallfoot_p_statement2term stm2;
		val comb_term = list_mk_comb (smallfoot_prog_cond_term, [c_term, stm1_term, stm2_term]);
                val read_var_set = HOLset.union (c_read_var_set, HOLset.union (read_var_set1, read_var_set2));
		val write_var_set = HOLset.union (write_var_set1, write_var_set2);
	in
           (comb_term, read_var_set, write_var_set)
        end

| smallfoot_p_statement2term (Pstm_while (i, cond, stm1)) =
	let
		val (i_opt,i_read_var_set) = 
		       if isSome i then
			  let
		            val (prop_term, prop_varset) = smallfoot_a_proposition2term (valOf i);
		          in
			    (SOME prop_term, prop_varset)
                          end
		       else (NONE, empty_tmset);

		val (stm1_term, stm_read_var_set, stm_write_var_set) = smallfoot_p_statement2term stm1;
		val (c_term, c_read_var_set) = smallfoot_p_expression2term cond;
                val read_var_set = HOLset.union (c_read_var_set, HOLset.union (i_read_var_set, stm_read_var_set));
		val write_var_set = stm_write_var_set;


		val op_term = if (isSome i_opt) then
				  let
				      val prop_term = mk_smallfoot_prop_input write_var_set read_var_set NONE (valOf i_opt);
				  in
                                      mk_comb (smallfoot_prog_while_with_invariant_term, prop_term)
				  end
			      else smallfoot_prog_while_term;
                val comb_term = list_mk_comb (op_term, [c_term, stm1_term]); 
	in
           (comb_term, read_var_set, write_var_set)
        end
| smallfoot_p_statement2term (Pstm_withres _) =
       Raise (smallfoot_unsupported_feature_exn ("Pstm_withres"))
| smallfoot_p_statement2term (Pstm_fcall(name,args)) =
       smallfoot_fcall2term (name, args)
| smallfoot_p_statement2term (Pstm_parallel_fcall(name1,args1,name2,args2)) =
       smallfoot_parallel_fcall2term (name1, args1, name2, args2);



(*
val dummy_fundecl =
Pfundecl("proc", ([], ["x", "y"]),
                       SOME(Aprop_spred(Aspred_pointsto(Aexp_ident "x", []))),
                       [],
                       [Pstm_fldassign(Pexp_ident "x", "tl", Pexp_ident "y")],
                       SOME(Aprop_spred(Aspred_pointsto(Aexp_ident "x",
                                                        [("tl",
                                                          Aexp_ident "y")]))))


fun destPfundecl (Pfundecl(funname, (ref_args, val_args), preCond, localV, 
	fun_body, postCond)) =
	(funname, (ref_args, val_args), preCond, localV, 
	fun_body, postCond);

val (funname, (ref_args, val_args), preCondOpt, localV, 
	fun_body, postCondOpt) = destPfundecl dummy_fundecl;

val var = "y";
val term = fun_body_term; 
*)





fun mk_el_list n v = 
List.tabulate (n, (fn n => list_mk_icomb (listLib.el_tm, [numLib.term_of_int n, v])))

fun mk_dest_pair_list 0 v = [v]
  | mk_dest_pair_list n v =
    (pairLib.mk_fst v) :: mk_dest_pair_list (n-1) (pairLib.mk_snd v);




fun list_variant l [] = [] |
      list_variant l (v::vL) =
	let
		val v' = variant l v;
	in
		v'::(list_variant (v'::l) vL)
	end;




(*
   fun dest_Pfundecl (Pfundecl(funname, (ref_args, val_args), preCondOpt, localV, 
	fun_body, postCondOpt)) = (funname, (ref_args, val_args), preCondOpt, localV, 
	fun_body, postCondOpt);


   val (funname, (ref_args, val_args), preCondOpt, localV, 
	fun_body, postCondOpt) = dest_Pfundecl ((el 1 (program_item_decl)));

*)





fun Pfundecl2hol (Pfundecl(funname, (ref_args, val_args), preCondOpt, localV, 
	fun_body, postCondOpt)) = 
let
	val (fun_body_term, read_var_set_body, write_var_set_body) = smallfoot_p_statement2term (Pstm_block fun_body)
	val fun_body_local_var_term = foldr smallfoot_mk_local_var fun_body_term localV;

	val used_vars = ref (free_vars fun_body_local_var_term);
        fun mk_new_var x = let
	                      val v = variant (!used_vars) (mk_var x);
		              val _ = used_vars := v::(!used_vars);
		           in v end;
	val arg_ref_term = mk_new_var ("arg_refL", Type `:smallfoot_var list`);
	val arg_val_term = mk_new_var ("arg_valL", Type `:num list`);
	val arg_term = pairLib.mk_pair (arg_ref_term, arg_val_term);
	val arg_valL = mk_el_list (length val_args) arg_val_term;

	val fun_body_val_args_term = foldr smallfoot_mk_val_arg fun_body_local_var_term (zip val_args arg_valL);

	val arg_refL = mk_el_list (length ref_args) arg_ref_term;
	val arg_ref_varL = map string2smallfoot_var ref_args;
	val arg_ref_subst = map (fn (vt, s) => (vt |-> s)) (zip arg_ref_varL arg_refL)
	val fun_body_final_term = subst arg_ref_subst fun_body_val_args_term;
	val fun_term = pairLib.mk_pabs (pairLib.mk_pair(arg_ref_term, arg_val_term), fun_body_final_term);

	val (preCond, read_var_set_preCond) = if isSome preCondOpt then smallfoot_a_proposition2term (valOf preCondOpt) else (smallfoot_ap_emp_term,empty_tmset);
	val (postCond, read_var_set_postCond) = if isSome postCondOpt then smallfoot_a_proposition2term (valOf postCondOpt) else (smallfoot_ap_emp_term, empty_tmset);

	val arg_val_varL = map (fn s => mk_comb (smallfoot_ae_var_term, string2smallfoot_var s)) val_args;
	val arg_val_expL = map (fn c => mk_comb (smallfoot_ae_const_term, c)) arg_valL;
	val arg_val_subst = map (fn (vt, s) => (vt |-> s)) (zip arg_val_varL arg_val_expL);

        val localV_set = HOLset.addList (empty_tmset, map string2smallfoot_var (append localV val_args));
        val write_var_set = HOLset.difference (write_var_set_body, localV_set);
        val read_var_set = let
	        val set1 =  HOLset.union (read_var_set_preCond, HOLset.union (read_var_set_postCond, read_var_set_body));
                val set2 = HOLset.difference (set1, write_var_set);
                val set3 = HOLset.difference (set2, localV_set);
                in set3 end;
	val preCond2 = mk_smallfoot_prop_input write_var_set read_var_set (SOME arg_ref_varL) preCond;
	val postCond2 = mk_smallfoot_prop_input write_var_set read_var_set (SOME arg_ref_varL) postCond;

	val preCond3 = subst (append arg_val_subst arg_ref_subst) preCond2;
	val postCond3 = subst (append arg_val_subst arg_ref_subst) postCond2;


	val cond_free_var_list = 
	       let
	          val set1 = HOLset.addList(empty_tmset, free_vars preCond3);
	          val set2 = HOLset.addList(set1, free_vars postCond3);
		  val set3 = HOLset.delete (set2, arg_ref_term) handle HOLset.NotFound => set2;
		  val set4 = HOLset.delete (set3, arg_val_term) handle HOLset.NotFound => set3;
	       in
		  HOLset.listItems set4
               end;
	val _ = if (List.all (fn t => (type_of t = numLib.num)) cond_free_var_list) then () else
		raise smallfoot_unsupported_feature_exn (
		      "All free variables in specifications have to represent smallfoot constants!");
	
        val free_var_names_list_term = listLib.mk_list (map (stringLib.fromMLstring o fst o dest_var) cond_free_var_list, 
                                       stringLib.string_ty);
	val free_vars_term = mk_new_var ("fvL", listLib.mk_list_type numLib.num);
        val free_vars_subst_terms = mk_el_list (length cond_free_var_list) free_vars_term;
	val free_vars_subst = map (fn (vt, s) => (vt |-> s)) (zip cond_free_var_list free_vars_subst_terms);
	val preCond4 = subst free_vars_subst preCond3;
	val postCond4 = subst free_vars_subst postCond3;

	    

	val preCond5 = pairLib.mk_pabs (free_vars_term, preCond4);
	val postCond5 = pairLib.mk_pabs (free_vars_term, postCond4);

	val preCond6 = pairLib.mk_pabs (arg_term, preCond5);
	val postCond6 = pairLib.mk_pabs (arg_term, postCond5);

	val ref_arg_names = listLib.mk_list (map stringLib.fromMLstring ref_args, stringLib.string_ty);
        val val_args_const = map (fn s => s ^ "_const") val_args;
	val val_arg_names = listLib.mk_list (map stringLib.fromMLstring val_args_const, stringLib.string_ty);


	val wrapped_preCond = list_mk_icomb (smallfoot_input_preserve_names_wrapper_term,
		[ref_arg_names, val_arg_names,
		 free_var_names_list_term,
		 preCond6]);
in
	(funname, fun_term, wrapped_preCond, postCond6)
end |
 Pfundecl2hol _ = Raise (smallfoot_unsupported_feature_exn ("resource description"));

fun p_item___is_fun_decl (Pfundecl _) = true |
     p_item___is_fun_decl _ = false;

(*
val prog2 = parse file
fun dest_Pprogram (Pprogram (ident_decl, program_item_decl)) = 
	(ident_decl, program_item_decl);

val (ident_decl, program_item_decl) = dest_Pprogram prog2;
*)



fun Pprogram2term (Pprogram (ident_decl, program_item_decl)) =
	let
		(*ignore ident_decl*)

		val fun_decl_list = filter p_item___is_fun_decl program_item_decl;
		val fun_decl_parseL = map Pfundecl2hol fun_decl_list

		fun mk_pair_terms (s, fun_body, pre, post) =
			pairLib.list_mk_pair [stringLib.fromMLstring s, fun_body, pre, post];
		val fun_decl_parse_pairL = map mk_pair_terms fun_decl_parseL;
		val input = listLib.mk_list (fun_decl_parse_pairL, type_of (hd fun_decl_parse_pairL));

	in
		mk_icomb (smallfoot_input_file_term, input)
	end;




val parse_smallfoot_file = Pprogram2term o parse;

end
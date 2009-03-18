structure compilerLib :> compilerLib =
struct
  
open HolKernel boolLib bossLib Parse;
open wordsTheory wordsLib addressTheory;
open prog_armLib prog_ppcLib prog_x86Lib decompilerLib;

open codegenLib helperLib codegen_x86Lib;

val COMPILER_TAC = 
    SIMP_TAC bool_ss [LET_DEF]
    THEN REWRITE_TAC [WORD_CMP_NORMALISE] 
    THEN REWRITE_TAC [WORD_HIGHER,WORD_GREATER,WORD_HIGHER_EQ,
           WORD_GREATER_EQ,GSYM WORD_NOT_LOWER,GSYM WORD_NOT_LESS] 
    THEN SIMP_TAC std_ss [WORD_MUL_LSL,word_mul_n2w,word_add_n2w,NOT_IF,
           WORD_OR_CLAUSES]
    THEN CONV_TAC (EVAL_ANY_MATCH_CONV word_patterns)
    THEN SIMP_TAC bool_ss [WORD_SUB_RZERO, WORD_ADD_0, 
                      AC WORD_ADD_COMM WORD_ADD_ASSOC,
                      AC WORD_MULT_COMM WORD_MULT_ASSOC,
                      AC WORD_AND_COMM WORD_AND_ASSOC,
                      AC WORD_OR_COMM WORD_OR_ASSOC,
                      AC WORD_XOR_COMM WORD_XOR_ASSOC];

val doing = ref T;
val target = "arm"

fun compile target tm = let
  val _ = (doing := tm)
  val (tools,target,model_name,s) = 
    if mem target ["arm","ARM"] then (arm_tools,"arm","ARM_MODEL",[]) else 
    if mem target ["x86","i32","386"] then (x86_tools,"x86","X86_MODEL",to_x86_regs) else 
    if mem target ["ppc","Power","PowerPC"] then (ppc_tools,"ppc","PPC_MODEL",[]) else hd []
  val (code,len) = generate_code target model_name true tm  
  fun append' [] = "" | append' (x::xs) = x ^ "\n" ^ append' xs
  val x = fst (dest_eq tm)
  val name = fst (dest_const (repeat car x)) handle e => fst (dest_var (repeat car x))
  val qcode = [QUOTE (append' code)] : term quotation
  val in_tm = cdr x
  fun ends (FUN_IF (_,c1,c2)) = ends c1 @ ends c2
    | ends (FUN_LET (_,_,c)) = ends c
    | ends (FUN_COND (_,c)) = ends c
    | ends (FUN_VAL t) = if is_var t orelse pairSyntax.is_pair t then [t] else []
  val out_tm2 = hd (ends (tm2ftree (cdr tm)))
  val (in_tm,out_tm) = (subst s in_tm, subst s out_tm2)
  val function_in_out = SOME (in_tm,out_tm)
  val qcode = ([QUOTE (append' code)]) : term Lib.frag list
  val (th1,th2) = basic_decompile tools name function_in_out qcode
  val _ = print "Proving equivalence, "
  val const = (repeat car o fst o dest_eq o concl o hd o CONJUNCTS) th2
  val tm = subst [ repeat car x |-> const ] tm
  val pre = if is_conj (concl th2) then (last o CONJUNCTS) th2 else TRUTH
  val th3 = prove(tm,
    REPEAT STRIP_TAC
    THEN CONV_TAC (RATOR_CONV (ONCE_REWRITE_CONV [th2]))
    THEN COMPILER_TAC)    
  val _ = add_compiler_assignment out_tm2 (fst (dest_eq tm)) name len model_name
  val _ = print "done.\n"
  in (th1,th3,pre) end

fun compile_all_aux tm = let
  val x = fst (dest_eq tm)
  val name = fst (dest_const (repeat car x)) handle e => fst (dest_var (repeat car x))
  val targets = ["arm","x86","ppc"]
  fun compile_each tm [] = []
    | compile_each tm (target::ts) = let
    val (th,_,_) = compile target tm
    val base = fetch "-" (name ^ "_base_def")
    val step = fetch "-" (name ^ "_step_def")
    val guard = fetch "-" (name ^ "_guard_def")
    val side = fetch "-" (name ^ "_side_def")
    val main = fetch "-" (name ^ "")
    val main_pre = fetch "-" (name ^ "_pre")
    val def = fetch "-" (name ^ "_def")
    val pre = fetch "-" (name ^ "_pre_def")
    val tm = concl def
    in (target,th,def,pre,[main,main_pre],[base,step,guard,side]) 
       :: compile_each tm ts end
  val xs = compile_each tm targets
  val (_,_,def,pre,tops,parts) = last xs  
  fun prove_eq (target,th,pre,def,xtops,xparts) = let
    val f = (repeat car o fst o dest_eq o concl o SPEC_ALL) 
    val goal = mk_conj(mk_eq(f (hd xtops), f (hd tops)),
                       mk_eq(f (last xtops), f (last tops)))
    val lemma = prove(goal,
      REWRITE_TAC (xtops @ tops)
      THEN MATCH_MP_TAC tailrecTheory.TAILREC_EQ_THM 
      THEN REPEAT STRIP_TAC
      THEN SIMP_TAC std_ss [FUN_EQ_THM,pairTheory.FORALL_PROD]  
      THEN REWRITE_TAC (xparts @ parts)
      THEN COMPILER_TAC)  
    val _ = echo 1 (" " ^ target)
    in (target, ONCE_REWRITE_RULE [lemma] th) end
  val _ = echo 1 "\nJoining definitions:"
  val ys = map prove_eq xs
  val _ = echo 1 ".\n"
  val thms = map snd ys
  val _ = add_compiled (map snd ys)
  in (ys,def,pre) end; 

fun compile_all tm = let
  val _ = set_abbreviate_code true
  fun compile_each [] = []
    | compile_each (tm::tms) = let
    val x = car (fst (dest_eq tm))
    val (ys,def,pre) = compile_all_aux tm    
    val x2 = (car o fst o dest_eq o concl o SPEC_ALL) def
    val tms = map (subst [x |-> x2]) tms
    in (ys,def,pre) :: compile_each tms end
  val tms = list_dest dest_conj tm
  val xs = compile_each tms
  val f = REWRITE_RULE [] o foldr (uncurry CONJ) TRUTH
  val defs = f (map (fn (x,y,z) => y) xs)
  val pres = f (map (fn (x,y,z) => z) xs)
  val (ys,_,_) = last xs 
  val _ = set_abbreviate_code false
  val ys = map (fn (n,th) => (n,UNABBREV_CODE_RULE th)) ys  
  in (ys,defs,pres) end

end;
structure decompilerLib :> decompilerLib =
struct
  
open HolKernel boolLib bossLib Parse;

open prog_ppcLib prog_x86Lib prog_armLib;

open listTheory wordsTheory pred_setTheory arithmeticTheory wordsLib pairTheory;
open set_sepTheory progTheory helperLib addressTheory;


(* ------------------------------------------------------------------------------ *)
(* Decompilation stages:                                                          *)
(*   1. derive SPEC theorem for each machine instruction                          *)
(*   2. extract control flow graph                                                *)
(*   3. for each code segment:                                                    *)
(*        a. compose SPEC theorems for one-pass through the code                  *)
(*        b. merge one-pass theorems into one theorem                             *)
(*        c. extract the function describing the code                             *)
(*   4. store and return result of decompilation                                  *)
(* ------------------------------------------------------------------------------ *)

(* decompiler's memory *)

val decompiler_memory = ref ([]:(string * (thm * int * int option)) list)
val decompiler_finalise = ref (I:(thm * thm -> thm * thm))
val code_abbreviations = ref ([]:thm list);
val abbreviate_code = ref (false:bool);

fun add_decompiled (name,th,code_len,code_exit) =
  (decompiler_memory := (name,(th,code_len,code_exit)) :: !decompiler_memory);

fun add_code_abbrev thms = (code_abbreviations := thms @ !code_abbreviations);
fun set_abbreviate_code b  = (abbreviate_code := b);
fun get_abbreviate_code () = (!abbreviate_code);

(* general set-up *)

val _ = map Parse.hide ["r0","r1","r2","r3","r4","r5","r6","r7","r8","r9"];
val _ = set_echo 5;


(* ------------------------------------------------------------------------------ *)
(* Various helper functions                                                       *)
(* ------------------------------------------------------------------------------ *)

fun take n [] = []
  | take n (x::xs) = if n = 0 then [] else x :: take (n-1) xs

fun drop n [] = []
  | drop n (x::xs) = if n = 0 then x::xs else drop (n-1) xs

fun take_until p [] = []
  | take_until p (x::xs) = if p x then [] else x:: take_until p xs 

fun diff xs ys = filter (fn x => not (mem x ys)) xs
fun subset xs ys = (diff xs ys = [])
fun same_set xs ys = subset xs ys andalso subset ys xs
fun disjoint xs ys = diff xs ys = xs

fun negate tm = dest_neg tm handle e => mk_neg tm
fun the (SOME x) = x | the NONE = hd []

fun dest_tuple tm = 
  let val (x,y) = pairSyntax.dest_pair tm in x :: dest_tuple y end handle e => [tm];

fun mk_tuple_abs (v,tm) = 
  if v = ``()`` then 
    (subst [mk_var("x",type_of tm) |-> tm] (inst [``:'a``|->type_of tm] ``\():unit.x:'a``))
 else pairSyntax.list_mk_pabs([v],tm) 

fun dest_sep_cond tm = 
  if (fst o dest_const o fst o dest_comb) tm = "cond" 
  then snd (dest_comb tm) else hd [];

fun n_times 0 f x = x | n_times n f x = n_times (n-1) f (f x) 

fun replace_char c str = 
  String.translate (fn x => if x = c then str else implode [x]);

fun REPLACE_CONV th tm = let
  val th = SPEC_ALL th
  val (i,j) = match_term ((fst o dest_eq o concl) th) tm
  in INST i (INST_TYPE j th) end

(* expands pairs ``(x,y,z) = f`` --> (x = FST f) /\ (y = FST (SND f)) /\ (z = ...) *)
fun expand_conv tm = let
  val cc = RAND_CONV (REPLACE_CONV (GSYM pairTheory.PAIR))
  val cc = cc THENC REPLACE_CONV pairTheory.PAIR_EQ
  val th = cc tm
  in CONV_RULE (RAND_CONV (RAND_CONV expand_conv)) th end handle e => REFL tm

fun list_mk_pair xs = pairSyntax.list_mk_pair xs handle e => ``()``
fun list_dest_pair tm = let val (x,y) = pairSyntax.dest_pair tm 
 in list_dest_pair x @ list_dest_pair y end handle e => [tm]

fun list_union [] xs = xs
  | list_union (y::ys) xs = 
      if mem y xs then list_union ys xs else list_union ys (y::xs);

fun quote_to_strings q = let (* turns a quote `...` into a list of strings *)
  fun get_QUOTE (QUOTE t) = t | get_QUOTE _ = hd []
  val xs = explode (get_QUOTE (hd q))
  fun strip_comments l [] = []
    | strip_comments l (x::xs) =
        if x = #"(" then strip_comments (l+1) xs else
        if x = #")" then strip_comments (l-1) xs else
        if 0 < l    then strip_comments l xs else x :: strip_comments l xs
  fun strip_space [] = []
    | strip_space (x::xs) = 
        if mem x [#" ",#"\t",#"\n"] then strip_space xs else x::xs
  fun lines [] [] = [] 
    | lines xs [] = [implode (strip_space (rev xs))]
    | lines xs (y::ys) = 
        if mem y [#"\n",#"|"] 
        then implode (strip_space (rev xs)) :: lines [] ys 
        else lines (y::xs) ys   
  val ys = (rev o strip_space o rev o strip_space o strip_comments 0) xs
  in lines [] ys end;  

val quote_to_hex_list: term quotation -> string list = 
  map (replace_char #" " "") o quote_to_strings

fun remove_primes th = let
  fun last s = substring(s,size s-1,1)
  fun delete_last_prime s = if last s = "'" then substring(s,0,size(s)-1) else hd []
  fun foo [] ys i = i
    | foo (x::xs) ys i = let 
      val name = (fst o dest_var) x 
      val new_name = repeat delete_last_prime name
      in if name = new_name then foo xs (x::ys) i else let 
        val new_var = mk_var(new_name,type_of x)
        in foo xs (new_var::ys) ((x |-> new_var) :: i) end end
  val i = foo (free_varsl (concl th :: hyp th)) [] []
  in INST i th end

fun append_lists [] = [] | append_lists (x::xs) = x @ append_lists xs 

fun get_tools th = let 
  val (x,_,_,_) = dest_spec (concl th)
  in if fst (dest_const x) = "ARM_MODEL" then arm_tools else
     if fst (dest_const x) = "PPC_MODEL" then ppc_tools else
     if fst (dest_const x) = "X86_MODEL" then x86_tools else hd [] end

fun get_pc th = let val (_,_,_,x) = get_tools th in x end;
fun get_status th = let val (_,_,x,_) = get_tools th in x end;     

fun get_output_list def = let
  val tm = (concl o last o CONJUNCTS o SPEC_ALL) def
  val (fm,tm) = dest_eq tm
  val t = (tm2ftree) tm 
  fun ftree2res (FUN_VAL tm) = [tm]
    | ftree2res (FUN_IF (tm,x,y)) = ftree2res x @ ftree2res y
    | ftree2res (FUN_LET (tm,tn,x)) = ftree2res x 
    | ftree2res (FUN_COND (tm,x)) = ftree2res x
  val res = filter (fn x => not (x = fm)) (ftree2res t)
  val result = dest_tuple (hd res)
  fun deprime x = mk_var(replace_char #"'" "" (fst (dest_var x)), type_of x) handle e => x
  in pairSyntax.list_mk_pair(map deprime result) end;

(* ------------------------------------------------------------------------------ *)
(* Implementation of STAGE 1                                                      *)
(* ------------------------------------------------------------------------------ *)

(* formatting *)

fun DISCH_ALL_AS_SINGLE_IMP th = let
  val th = RW [AND_IMP_INTRO] (DISCH_ALL th)
  in if is_imp (concl th) then th else DISCH ``T`` th end

fun replace_abbrev_vars tm = let
  fun f v = v |-> mk_var((Substring.string o hd o tl o Substring.tokens (fn x => x = #"@") o 
                    Substring.all o fst o dest_var) v, type_of v) handle e => v |-> v
  in subst (map f (free_vars tm)) tm end

fun name_for_abbrev tm = 
  if is_const (cdr (car tm)) andalso is_const(car (car tm)) handle e => false then 
    (to_lower o fst o dest_const o cdr o car) tm
  else if can (match_term ``(f ((n2w n):'a word) (x:'c)):'d``) tm then
    "r" ^ ((int_to_string o numSyntax.int_of_term o cdr o cdr o car) tm)  
  else fst (dest_var (repeat cdr tm)) handle e =>
       fst (dest_var (find_term is_var tm)) handle e =>
       fst (dest_const (repeat car (get_sep_domain tm)));

fun raw_abbreviate2 (var_name,y,tm) th = let
  val y = mk_eq(mk_var(var_name,type_of y),y)
  val cc = UNBETA_CONV tm THENC (RAND_CONV) (fn t => GSYM (ASSUME y)) THENC BETA_CONV
  val th = CONV_RULE (RAND_CONV cc) th
  in th end;

fun raw_abbreviate (var_name,y,tm) th = let
  val y = mk_eq(mk_var(var_name,type_of y),y)
  val cc = UNBETA_CONV tm THENC (RAND_CONV o RAND_CONV) (fn t => GSYM (ASSUME y)) THENC BETA_CONV
  val th = CONV_RULE (RAND_CONV cc) th
  in th end;

fun abbreviate (var_name,tm) th = raw_abbreviate (var_name,cdr tm,tm) th

fun ABBREV_POSTS dont_abbrev_list prefix th = let
  fun dont_abbrev tm = mem tm dont_abbrev_list 
  val (th,b) = let
    val (_,_,_,q) = dest_spec (concl th)
    val xs = list_dest dest_star q
    fun next_abbrev [] = hd [] 
      | next_abbrev (tm::xs) = 
      if (is_var (cdr tm) andalso (name_for_abbrev tm = fst (dest_var (cdr tm))))
         handle e => false then next_abbrev xs else 
      if (prefix ^ (name_for_abbrev tm) = fst (dest_var (cdr tm))) 
         handle e => false then next_abbrev xs else 
      if can dest_sep_hide tm then next_abbrev xs else 
      if dont_abbrev (car tm) then next_abbrev xs else
        (prefix ^ name_for_abbrev tm,tm)
    val th = abbreviate (next_abbrev xs) th     
    in (th,true) end handle e => (th,false)
  in if b then ABBREV_POSTS dont_abbrev_list prefix th else th end;

fun ABBREV_PRECOND prefix th = let
  val th = RW [SPEC_MOVE_COND] (SIMP_RULE (bool_ss++sep_cond_ss) [] th)
  val tm = (fst o dest_imp o concl) th
  val v = mk_var(prefix^"cond",``:bool``)
  val thx = SYM (BETA_CONV (mk_comb(mk_abs(v,v),tm)))
  val th = CONV_RULE ((RATOR_CONV o RAND_CONV) (fn tm => thx)) th
  val th = SIMP_RULE (bool_ss++sep_cond_ss) [] (RW [precond_def] (UNDISCH th))
  in th end handle e => th;

fun ABBREV_ALL dont_abbrev_list prefix = 
  ABBREV_PRECOND prefix o ABBREV_POSTS dont_abbrev_list prefix;

fun ABBREV_CALL prefix th = let
  val (_,_,_,q) = (dest_spec o concl) th
  val (x,tm) = pairSyntax.dest_anylet q
  val (x,y) = hd x
  val ys = map (fn v => mk_var(prefix^(fst (dest_var v)),type_of v)) (dest_tuple x)
  val thi = ASSUME (mk_eq(pairSyntax.list_mk_pair ys, y))
  val th = CONV_RULE (RAND_CONV (RAND_CONV (fn tm => GSYM thi))) (RW [LET_DEF] th)
  val th = RW [FST,SND] (PairRules.PBETA_RULE (RW [LET_DEF] th))
  in ABBREV_PRECOND prefix th end handle e => ABBREV_PRECOND prefix th;

fun UNABBREV_ALL th = let
  fun remove_abbrev th = let
    val th = CONV_RULE ((RATOR_CONV o RAND_CONV) expand_conv) th
    val th = RW [GSYM AND_IMP_INTRO] th
    val (x,y) = (dest_eq o fst o dest_imp o concl) th
    in MP (INST [x|->y] th) (REFL y) end 
    handle e => UNDISCH (CONV_RULE ((RATOR_CONV o RAND_CONV) BETA_CONV) th)
    handle e => UNDISCH th
  in repeat remove_abbrev (DISCH_ALL th) end;


(* derive SPEC theorems *)

fun pair_apply f ((th1,x1:int,x2:int option),NONE) = ((f th1,x1,x2),NONE)
  | pair_apply f ((th1,x1,x2),SOME (th2,y1:int,y2:int option)) = 
      ((f th1,x1,x2),SOME (f th2,y1,y2))

fun jump_apply f NONE = NONE | jump_apply f (SOME x) = SOME (f x);

fun pair_jump_apply (f:int->int) ((th1,x1:int,x2:int option),NONE) = ((th1,x1,jump_apply f x2),NONE)
  | pair_jump_apply f ((th1:thm,x1,x2),SOME (th2:thm,y1:int,y2:int option)) = 
      ((th1,x1,jump_apply f x2),SOME (th2,y1,jump_apply f y2));

fun parse_renamer instruction = let
  val xs = Substring.tokens (fn x => x = #"/") (Substring.all instruction)
  in if length xs < 2 then (instruction,fn x => x) else (Substring.string (hd xs),fn th => let
    val vs = free_vars (concl th) 
    val vs = filter (fn v => mem (fst (dest_var v)) ["f","df"]) vs
    fun make_new_name v = ((implode o rev o tl o rev o explode o fst o dest_var) v) ^ Substring.string (hd (tl xs))
    val s = map (fn v => v |-> mk_var(make_new_name v,type_of v)) vs
    in INST s th end) end;

fun introduce_guards thms = let
  val pattern = (fst o dest_eq o concl o SPEC_ALL) cond_def  
  fun intro (n,(th1,i1,j1),NONE) = (n,(th1,i1,j1),NONE) 
    | intro (n,(th1,i1,j1),SOME (th2,i2,j2)) = let
    val t1 = cdr (find_term (can (match_term pattern)) (concl th1))
    val t2 = cdr (find_term (can (match_term pattern)) (concl th2))
    val h = RW [SPEC_MOVE_COND] o SIMP_RULE (bool_ss++sep_cond_ss) []
    val (th1,th2) = (h th1,h th2)
    val rw = SPEC (numSyntax.term_of_int n) GUARD_def
    val f1 = CONV_RULE ((RATOR_CONV o RAND_CONV) (ONCE_REWRITE_CONV [GSYM rw]))
    val f2 = CONV_RULE ((RATOR_CONV o RAND_CONV o RAND_CONV) (ONCE_REWRITE_CONV [GSYM rw]))
    val (th1,th2) = if is_neg t1 then (f2 th1,f1 th2) else (f1 th1, f2 th2)
    val h2 = RW [GSYM SPEC_MOVE_COND]
    val (th1,th2) = (h2 th1,h2 th2)
    in (n,(th1,i1,j1),SOME (th2,i2,j2)) end
  val thms = map intro thms
  in thms end

fun derive_individual_specs tools (code:string list) = let
  val (f,_,hide_th,pc) = tools
  fun get_model_status_list th = 
    (map dest_sep_hide o list_dest dest_star o snd o dest_eq o concl) th handle e => []
  val dont_abbrev_list = pc :: get_model_status_list hide_th  
  fun get_specs (instruction,(n,ys)) = 
    if (substring(instruction,0,7) = "insert:" handle e => false) then let
      val name = substring(instruction,7,length (explode instruction) - 7)
      val (name,(th,i,j)) = hd (filter (fn (x,y) => x = name) (!decompiler_memory))
      val th = RW [sidecond_def,hide_th,STAR_ASSOC] th
      val th = ABBREV_CALL ("s"^(int_to_string n)^"@") th
      val _ = echo 1 "  (insert command)\n"
      in (n+1,(ys @ [(n,(th,i,j),NONE)])) end
    else let
      val (instruction, renamer) = parse_renamer instruction
      val _ = echo 1 ("  "^instruction^":")
      val i = int_to_string n
      val g = RW [precond_def] o ABBREV_ALL dont_abbrev_list ("s"^i^"@") o renamer
      val (x,y) = pair_apply g (f instruction)
      val _ = echo 1 ".\n"
      in (n+1,(ys @ [(n,x,y)])) end
  val _ = echo 1 "\nDeriving specifications for individual instructions.\n"
  val res = snd (foldl get_specs (1,[]) code)
  val res = introduce_guards res
  fun calc_addresses i [] = []
    | calc_addresses i ((n:int,(th1:thm,l1,j1),y)::xs)  = let
    val (x,y) = pair_jump_apply (fn j => i+j) ((th1,l1,j1),y)
    in (i,x,y) :: calc_addresses (i+l1) xs end
  val res = calc_addresses 0 res
  val _ = echo 1 "\n"
  in res end;

fun stage_1 tools qcode = let  
  val code = filter (fn x => not (x = "")) (quote_to_hex_list qcode)
  val thms = derive_individual_specs tools code
  in thms end;


(* ------------------------------------------------------------------------------ *)
(* Implementation of STAGE 2                                                      *)
(* ------------------------------------------------------------------------------ *)

fun extract_graph thms = let  
  fun extract_jumps (i,(_,_,j),NONE) = [(i,j)]
    | extract_jumps (i,(_,_,j),SOME (_,_,k)) = [(i,j),(i,k)]
  val jumps = append_lists (map extract_jumps thms)
  in jumps end;

fun all_distinct [] = []
  | all_distinct (x::xs) = x :: all_distinct (filter (fn z => not (x = z)) xs)

fun drop_until P [] = []
  | drop_until P (x::xs) = if P x then x::xs else drop_until P xs

fun jumps2edges jumps = let
  fun h (i,NONE) = []
    | h (i,SOME j) = [(i,j)] 
  in append_lists (map h jumps) end;
  
fun extract_loops jumps = let  
  (* find all possible paths *)
  val edges = jumps2edges jumps
  fun all_paths_from edges i prefix = let
    fun f [] = []
      | f ((k,j)::xs) = if i = k then j :: f xs else f xs
    val next = all_distinct (f edges)  
    val prefix = prefix @ [i]
    val xs = map (fn x => if mem x prefix then [prefix @ [x]] else 
                          all_paths_from edges x prefix) next
    val xs = if xs = [] then [[prefix]] else xs
    in append_lists xs end
  val paths = all_paths_from edges 0 []
  (* get looping points *)
  fun is_loop xs = mem (last xs) (butlast xs)
  val loops = all_distinct (map last (filter is_loop paths))
  (* find loop bodies and tails *)  
  fun loop_body_tail i = let
    val bodies = filter (fn xs => last xs = i) paths
    val bodies = filter is_loop bodies
    val bodies = map (drop_until (fn x => x = i) o butlast) bodies
    val bodies = all_distinct (append_lists bodies)
    val tails = filter (fn xs => mem i xs andalso not (last xs = i)) paths
    val tails = map (drop_until (fn x => x = i)) tails
    in (i,bodies,tails) end
  val summaries = map loop_body_tail loops
  (* clean loop tails *)
  fun clean_tails (i,xs,tails) = let
    val tails = map (drop_until (fn x => not (mem x xs))) tails
    val tails = filter (fn xs => not (xs = [])) tails
    in (i,xs,tails) end
  val zs = map clean_tails summaries
  (* merge combined loops *)
  val zs = map (fn (x,y,z) => ([x],y,z)) zs
  fun find_and_merge zs = let
    val ls = append_lists (map (fn (x,y,z) => x) zs)    
    val qs = map (fn (x,y,z) => (x,y,map hd z)) zs
    fun f ys = filter (fn x => mem x ls andalso (not (mem x ys)))
    val qs = map (fn (x,y,z) => (x,all_distinct (f x y @ f x z))) qs
    fun cross [] ys = []
      | cross (x::xs) ys = map (fn y => (x,y)) ys @ cross xs ys
    val edges = append_lists (map (fn (x,y) => cross x y) qs)
    val paths = map (fn i => all_paths_from edges i []) ls
    val goals = map (fn (x,y) => (y,x)) edges
    fun sat_goal ((i,j),path) = (hd path = i) andalso (mem j (tl path))
    val (i,j) = fst (hd (filter sat_goal (cross goals (append_lists paths))))
    val (p1,q1,x1) = hd (filter (fn (x,y,z) => mem i x) zs)
    val (p2,q2,x2) = hd (filter (fn (x,y,z) => mem j x) zs)
    val (p,q,x) = (p1 @ p2, all_distinct (q1 @ q2), x1 @ x2)
    val zs = (p,q,x) :: filter (fn (x,y,z) => not (mem i x) andalso not (mem j x)) zs
    val zs = map clean_tails zs
    in zs end  
  val zs = repeat find_and_merge zs
  (* attempt to find common exit point *)
  fun mem_all x [] = true
    | mem_all x (xs::xss) = mem x xs andalso mem_all x xss 
  fun find_exit_points (x,y,z) = let
    val q = hd (filter (fn x => mem_all x (tl z)) (hd z))
    in (x,[q]) end handle Empty => (x,all_distinct (map hd z))
  val zs = map find_exit_points zs
  (* finalise *)
  val exit = (all_distinct o map last o filter (not o is_loop)) paths
  val zero = ([0],exit)  
  val zs = if filter (fn (x,y) => mem 0 x andalso subset exit y) zs = [] then zs @ [zero] else zs
  fun list_before x y [] = true
    | list_before x y (z::zs) = if z = y then false else
                                if z = x then true else list_before x y zs
  fun compare (xs,_) (ys,_) = let
    val x = hd xs  
    val y = hd ys
    val p = hd (filter (fn xs => mem x xs andalso mem y xs) paths)   
    in not (list_before x y p) end handle Empty => false 
  val loops = sort compare zs
  (* final states should still be optimised *)
  in loops end;

fun stage_12 tools qcode = let
  val thms = stage_1 tools qcode
  val jumps = extract_graph thms
  val loops = extract_loops jumps
  in (thms,loops) end;


(* ------------------------------------------------------------------------------ *)
(* Implementation of STAGE 3                                                      *)
(* ------------------------------------------------------------------------------ *)

(* STAGE 3, part a -------------------------------------------------------------- *)

(* functions for composing SPEC theorems *)

fun spec_pre th = let
  val (_,p,_,_) = dest_spec (concl th) in (list_dest dest_star p, type_of p) end;
fun spec_post th = let
  val (_,_,_,q) = dest_spec (concl th) in (list_dest dest_star q, type_of q) end;

fun spec_post_and_pre th1 th2 = let
  val (_,_,_,q) = dest_spec (concl th1)
  val (_,p,_,_) = dest_spec (concl th2)
  in (list_dest dest_star q, list_dest dest_star p, type_of q) end;

fun find_composition1 th1 th2 = let
  val (q,p,ty) = spec_post_and_pre th1 th2
  fun get_match_term tm = replace_abbrev_vars (get_sep_domain tm)
  fun mm x y = get_match_term x = get_match_term y
  fun fetch_match x [] zs = hd []
    | fetch_match x (y::ys) zs = 
        if mm x y then (y, rev zs @ ys) else fetch_match x ys (y::zs)
  fun partition [] ys (xs1,xs2,ys1) = (rev xs1, rev xs2, rev ys1, ys)
    | partition (x::xs) ys (xs1,xs2,ys1) =
        let val (y,zs) = fetch_match x ys [] in
          partition xs zs (x::xs1, xs2, y::ys1)
        end handle e =>
          partition xs ys (xs1, x::xs2, ys1)
  val (xs1,xs2,ys1,ys2) = partition q p ([],[],[])
  val tm1 = mk_star (list_mk_star xs1 ty, list_mk_star xs2 ty)
  val tm2 = mk_star (list_mk_star ys1 ty, list_mk_star ys2 ty)
  val th1 = CONV_RULE (POST_CONV (MOVE_STAR_CONV tm1)) th1    
  val th2 = CONV_RULE (PRE_CONV (MOVE_STAR_CONV tm2)) th2 
  val th = MATCH_MP SPEC_FRAME_COMPOSE (DISCH_ALL_AS_SINGLE_IMP th2)   
  val th = MATCH_MP th (DISCH_ALL_AS_SINGLE_IMP th1)   
  val th = UNDISCH_ALL (PURE_REWRITE_RULE [GSYM AND_IMP_INTRO,AND_CLAUSES] th)
  val th = SIMP_RULE std_ss [INSERT_UNION_EQ,UNION_EMPTY,word_arith_lemma1,
             word_arith_lemma2,word_arith_lemma3,word_arith_lemma4,SEP_CLAUSES] th
  in remove_primes th end;

fun find_composition2 th1 th2 = let
  val (q,p,ty) = spec_post_and_pre th1 th2
  val post_not_hidden = map get_sep_domain (filter (not o can dest_sep_hide) q)
  val pre_not_hidden  = map get_sep_domain (filter (not o can dest_sep_hide) p)
  fun f (d:term,(zs,to_be_hidden)) = 
    if not (can dest_sep_hide d) then (zs,to_be_hidden) else
      (zs,filter (fn x => get_sep_domain d = x) zs @ to_be_hidden)
  val hide_from_post = snd (foldr f (post_not_hidden,[]) p) 
  val hide_from_pre  = snd (foldr f (pre_not_hidden,[]) q) 
  val th1 = foldr (uncurry HIDE_POST_RULE) th1 hide_from_post
  val th2 = foldr (uncurry HIDE_PRE_RULE) th2 hide_from_pre
  in find_composition1 th1 th2 end;

val SPEC_COMPOSE = find_composition2;    


(* functions for deriving one-pass theorems *)

datatype mc_tree = 
    LEAF of thm * int
  | SEQ of term list * mc_tree 
  | BRANCH of term * mc_tree * mc_tree;

fun basic_find_composition th1 (th2,l2,j2) = let
  val th = remove_primes (SPEC_COMPOSE th1 th2)
  val th = RW [WORD_CMP_NORMALISE] th
  val th = RW [GSYM WORD_NOT_LOWER, GSYM WORD_NOT_LESS] th
  fun h x = (fst o dest_eq) x handle e => (fst o dest_abs o car) x
  fun f [] ys = ys | f (x::xs) ys = f xs (h x :: ys handle e => ys) 
  val th2_hyps = f (hyp th2) []
  fun g tm = mem (h tm) th2_hyps handle e => false
  val lets = filter g (hyp th) 
  in ((th,l2,j2),lets) end

fun find_cond_composition th1 NONE = hd [] 
  | find_cond_composition th1 (SOME (th2,l2,j2)) = let
  val th = RW [SPEC_MOVE_COND] th2
  val th = if concl th = T then hd [] else th
  val th = if not (is_imp (concl th)) then th else
             CONV_RULE ((RATOR_CONV o RAND_CONV) (ONCE_REWRITE_CONV [GSYM CONTAINER_def])) th
  val th = RW [GSYM SPEC_MOVE_COND] th
  val ((th,l,j),lets) = basic_find_composition th1 (th,l2,j2)
  val th = SIMP_RULE (bool_ss++sep_cond_ss) [SEP_CLAUSES] th
  val th = RW [SPEC_MOVE_COND,GSYM AND_IMP_INTRO] th
  fun imps tm xs = let val (x,y) = dest_imp tm in imps y (x::xs) end handle e => xs
  fun is_CONTAINER tm = (fst o dest_const o car) tm = "CONTAINER" handle e => false
  val xs = filter is_CONTAINER (imps (concl th) [])
  val th = RW [GSYM SPEC_MOVE_COND,CONTAINER_def] th
  in let val cond = snd (dest_comb (hd xs)) in 
     let val cond = dest_neg cond in (cond,(th,l,j)) end 
     handle e => (mk_neg cond,(th,l,j)) end 
     handle e => (``F:bool``,(th,l,j)) end;

fun remove_guard tm = 
  (cdr o concl o REWRITE_CONV [GUARD_def]) tm handle UNCHANGED => tm;

fun tree_composition (th,i:int,thms,entry,exit,conds,firstTime) =
  if i = entry andalso not firstTime then LEAF (th,i) else
  if i = exit then LEAF (th,i) else let
    val (_,thi1,thi2) = hd (filter (fn (x,y,z) => x = i) thms)
    in let (* try composing second branch *)
       val (cond,(th2,_,i2)) = find_cond_composition th thi2
       val cond' = remove_guard cond
       in if mem (negate cond') conds 
          then (* case: only second branch possible *)
               tree_composition (th2,the i2,thms,entry,exit,conds,false)
          else if mem cond' conds then hd [] 
          else (* case: both branches possible *) let
            val ((th1,_,i1),lets) = basic_find_composition th thi1
            val t1 = tree_composition (th1,the i1,thms,entry,exit,cond'::conds,false)
            val t2 = tree_composition (th2,the i2,thms,entry,exit,negate cond'::conds,false)
            val t1 = if length lets = 0 then t1 else SEQ (lets,t1)
            in BRANCH (cond,t1,t2) end end
       handle e => (* case: only first branch possible *) let 
       val ((th,_,i),lets) = basic_find_composition th thi1
       val result = tree_composition (th,the i,thms,entry,exit,conds,false)
       in if length lets = 0 then result else SEQ (lets,result) end end

fun map_spectree f (LEAF (thm,i)) = LEAF (f thm,i)
  | map_spectree f (SEQ (x,t)) = SEQ(x, map_spectree f t)
  | map_spectree f (BRANCH (j,t1,t2)) = BRANCH (j, map_spectree f t1, map_spectree f t2)

fun generate_spectree thms (entry,exit) = let 
  val (_,(th,_,_),_) = hd thms
  val hide_th = get_status th
  fun apply_to_th f (i,(th,k,l),NONE) = (i,(f th,k,l),NONE)
    | apply_to_th f (i,(th,k,l),SOME (th2,k2,l2)) = (i,(f th,k,l),SOME (f th2,k2,l2))
  val thms = map (apply_to_th (RW [hide_th])) thms
  val (i,(th,_,_),_) = hd thms
  val (m,_,_,_) = dest_spec (concl th)
  val (th,i,conds,firstTime) = (Q.SPECL [`emp`,`{}`] (ISPEC m SPEC_REFL),entry,[]:term list,true)
  val _ = echo 1 "Forward simulation,"
  val t = tree_composition (th,i,thms,entry,exit,conds,firstTime)
  val t = map_spectree (HIDE_STATUS_RULE true hide_th) t
  in t end;

(* STAGE 3, part b -------------------------------------------------------------- *)

(* merge spectree theorems *)

fun strip_tag v = let
  val vs = (drop_until (fn x => x = #"@") o explode o fst o dest_var) v
  in if vs = [] then (fst o dest_var) v else implode (tl vs) end

fun ABBREV_NEW th = let
  val pc = get_pc th
  val tm = find_term (can (match_term (mk_comb(pc,genvar(``:word32``))))) (cdr (concl th))
  val th = abbreviate ("new@p",tm) th
  fun is_new_var v = (implode o take 4 o explode o fst o dest_var) v = "new@"
  val ws = (filter (not o is_new_var) o free_vars o cdr o concl) th
  fun one(v,th) = raw_abbreviate2 ("new@" ^ strip_tag v,v,v) th
  val th = foldr one th ws
  val th = UNDISCH (RW [SPEC_MOVE_COND,AND_IMP_INTRO,GSYM CONJ_ASSOC] (DISCH_ALL th))
  in th end

fun remove_tags tm = 
  subst (map (fn v => v |-> mk_var(strip_tag v,type_of v)) (free_vars tm)) tm

fun MERGE guard th1 th2 = let
  (* fill in preconditions *)
  val p = get_pc th1
  val (_,p1,_,q1) = dest_spec (concl th1)
  val (_,p2,_,q2) = dest_spec (concl th2)
  val xs1 = filter (fn x => not (p = get_sep_domain x)) (list_dest dest_star q1)
  val xs2 = filter (fn x => not (p = get_sep_domain x)) (list_dest dest_star q2)
  val xs1 = map remove_tags xs1
  val xs2 = map remove_tags xs2
  val zs1 = map get_sep_domain xs1
  val zs2 = map get_sep_domain xs2
  val ys1 = filter (fn x => not (mem (get_sep_domain x) zs1)) xs2
  val ys2 = filter (fn x => not (mem (get_sep_domain x) zs2)) xs1
  val th1 = SPEC (list_mk_star ys1 (type_of p1)) (MATCH_MP SPEC_FRAME th1)
  val th2 = SPEC (list_mk_star ys2 (type_of p2)) (MATCH_MP SPEC_FRAME th2)
  val th1 = RW [SEP_CLAUSES,STAR_ASSOC] th1 
  val th2 = RW [SEP_CLAUSES,STAR_ASSOC] th2
  (* unhide relevant preconditions *)
  val (_,p1,_,q1) = dest_spec (concl th1)
  val (_,p2,_,q2) = dest_spec (concl th2)
  val xs1 = filter (fn x => not (p = get_sep_domain x)) (list_dest dest_star p1)
  val xs2 = filter (fn x => not (p = get_sep_domain x)) (list_dest dest_star p2)
  val ys1 = map dest_sep_hide (filter (can dest_sep_hide) xs1)
  val ys2 = map dest_sep_hide (filter (can dest_sep_hide) xs2)
  val zs1 = (filter (not o can dest_sep_hide) xs1)
  val zs2 = (filter (not o can dest_sep_hide) xs2)
  val qs1 = filter (fn x => mem (car x) ys1) zs2
  val qs2 = filter (fn x => mem (car x) ys2) zs1
  val th1 = foldr (uncurry UNHIDE_PRE_RULE) th1 qs1
  val th2 = foldr (uncurry UNHIDE_PRE_RULE) th2 qs2
  (* hide relevant postconditions *)
  val (_,p1,_,q1) = dest_spec (concl th1)
  val (_,p2,_,q2) = dest_spec (concl th2)
  val xs1 = filter (fn x => not (p = get_sep_domain x)) (list_dest dest_star q1)
  val xs2 = filter (fn x => not (p = get_sep_domain x)) (list_dest dest_star q2)
  val ys1 = map dest_sep_hide (filter (can dest_sep_hide) xs1)
  val ys2 = map dest_sep_hide (filter (can dest_sep_hide) xs2)
  val zs1 = map car (filter (not o can dest_sep_hide) xs1)
  val zs2 = map car (filter (not o can dest_sep_hide) xs2)
  val qs1 = filter (fn x => mem x ys1) zs2
  val qs2 = filter (fn x => mem x ys2) zs1
  val th1 = foldr (uncurry HIDE_POST_RULE) th1 qs2
  val th2 = foldr (uncurry HIDE_POST_RULE) th2 qs1
  (* abbreviate posts *)
  val f = CONV_RULE (PRE_CONV (SIMP_CONV (bool_ss++star_ss) []) THENC
                     POST_CONV (SIMP_CONV (bool_ss++star_ss) []) THENC
                     REWRITE_CONV [STAR_ASSOC])
  val th1 = f (ABBREV_NEW th1)
  val th2 = f (ABBREV_NEW th2)
  (* do the merge *)
  fun g x = PURE_REWRITE_RULE [AND_IMP_INTRO] o DISCH x o DISCH_ALL
  val th = MATCH_MP SPEC_COMBINE (g guard th1)
  val th = MATCH_MP th (g (mk_neg guard) th2)
  val th = UNDISCH (RW [UNION_IDEMPOT] th)
  in th end;

val SORT_CODE_CONV = let
  fun RAW_SORT_CONV tm = let
    val ys = list_dest pred_setSyntax.dest_union tm
    fun word_to_int tm =
      if can (match_term ``(p:'a word) + n2w n``) tm then
        (numSyntax.int_of_term o cdr o cdr) tm
      else if can (match_term ``(p:'a word) - n2w n``) tm then
        0 - (numSyntax.int_of_term o cdr o cdr) tm
      else 0
    fun measure tm = 
      if can (match_term ``SING_SET ((p:'a word),x:'b)``) tm then
        word_to_int ((fst o dest_pair o cdr) tm)
      else let
        val x = find_terms (fn x => type_of x = ``:word32``) (cdr tm)
        in hd (filter (fn x => not (x = 0)) (map word_to_int x) @ [0]) end
      handle e => 0
    val xs = sort (fn x => fn y => measure x < measure y) ys
    val ty = (hd o snd o dest_type o type_of o hd) xs
    val tm2 = foldr (pred_setSyntax.mk_union) (pred_setSyntax.mk_empty ty) xs
    val lemma = prove(mk_eq(tm,tm2),
      SIMP_TAC std_ss [UNION_EMPTY,AC UNION_ASSOC UNION_COMM])
    in lemma end
  in (REWRITE_CONV [SING_SET_INTRO]
      THENC RAW_SORT_CONV
      THENC REWRITE_CONV [UNION_CANCEL]
      THENC REWRITE_CONV [SING_SET_def]
      THENC REWRITE_CONV [INSERT_UNION_EQ,UNION_EMPTY]) end;
  
fun merge_spectree_thm (LEAF (th,i)) = let
      val th = SIMP_RULE (bool_ss++sep_cond_ss) [] th
      val th = UNDISCH (RW [SPEC_MOVE_COND,AND_IMP_INTRO] (DISCH_ALL th))
      in (th,LEAF (TRUTH,i)) end
  | merge_spectree_thm (SEQ (tms,t)) = let
      val (th,t) = merge_spectree_thm t
      in (th,SEQ (tms,t)) end
  | merge_spectree_thm (BRANCH (guard,t1,t2)) = let
      val (th1,t1') = merge_spectree_thm t1
      val (th2,t2') = merge_spectree_thm t2
      val th = MERGE guard th1 th2
      in (th,BRANCH (guard,t1',t2')) end

fun UNABBREV_CODE_RULE th = let
  val rw = (!code_abbreviations)
  val c = REWRITE_CONV rw THENC
          SIMP_CONV std_ss [word_arith_lemma1] THENC
          REWRITE_CONV [INSERT_UNION_EQ,UNION_EMPTY]
  val th = CONV_RULE ((RATOR_CONV o RAND_CONV) c) th
  in th end;

fun ABBREV_CODE_RULE name th = 
  if not (get_abbreviate_code ()) then th else let
  val (m,_,c,_) = (dest_spec o concl o SPEC_ALL) th
  val model_name = (to_lower o implode o take_until (fn x => x = #"_") o explode o fst o dest_const) m
  val x = list_mk_pair (free_vars c)
  val def_name = name ^ "_" ^ model_name
  val v = mk_var(def_name,type_of(mk_pabs(x,c)))
  val code_def = new_definition(def_name ^ "_def",mk_eq(mk_comb(v,x),c))
  val th = CONV_RULE ((RATOR_CONV o RAND_CONV) 
           (ONCE_REWRITE_CONV [GSYM code_def])) (UNDISCH_ALL th)
  val _ = add_code_abbrev [code_def]
  in th end;

fun merge_spectree name t = let
  val _ = echo 1 " merging cases,"
  val (th,_) = merge_spectree_thm t
  val th = MERGE ``T`` th th 
  val th = UNDISCH_ALL (remove_primes (DISCH_ALL th))
  val th = CONV_RULE (RATOR_CONV (RAND_CONV SORT_CODE_CONV)) th 
  val th = ABBREV_CODE_RULE name th
  in th end


(* STAGE 3, part c -------------------------------------------------------------- *)

(* clean the theorem *)

fun tagged_var_to_num v = let
  fun drop_until p [] = []
    | drop_until p (x::xs) = if p x then x::xs else drop_until p xs 
  val xs = (take_until (fn x => x = #"@") o explode o fst o dest_var) v
  val xs = drop_until (fn x => mem x [#"0",#"1",#"2",#"3",#"4",#"5",#"6",#"7",#"8",#"9"]) xs
  val s = implode xs
  val s = if s = "" then "100000" else s
  in string_to_int s end

fun init_clean th = let
  fun side2guard_conv tm = 
    if not (can (match_term ``(\x.x:bool) y``) tm) 
    then NO_CONV tm else let
      val v = (numSyntax.term_of_int o tagged_var_to_num o fst o dest_abs o car) tm
      in (BETA_CONV THENC ONCE_REWRITE_CONV [GSYM (SPEC v GUARD_def)]) tm end     
  val th = RW [PUSH_IF_LEMMA,GSYM CONJ_ASSOC] (DISCH_ALL th)
  val th = CONV_RULE (DEPTH_CONV side2guard_conv) (DISCH_ALL th)
  val th = CONV_RULE ((RATOR_CONV o RAND_CONV) 
                     (SIMP_CONV bool_ss [GSYM CONJ_ASSOC,NOT_IF])) th
  val th = remove_primes th
  in th end;

fun guard_to_num tm = (numSyntax.int_of_term o cdr o car) tm
fun assum_to_num tm = 
  if is_cond tm then 100000 else
  if can (match_term ``GUARD b x``) tm then guard_to_num tm else
  if can (match_term ``~(GUARD b x)``) tm then guard_to_num (cdr tm) else
    (hd o map tagged_var_to_num o free_vars o fst o dest_eq) tm

fun push_if_inwards th = let
  fun drop_until p [] = []
    | drop_until p (x::xs) = if p x then x::xs else drop_until p xs 
  fun strip_names v = let
    val vs = (drop_until (fn x => x = #"@") o explode o fst o dest_var) v
    in if vs = [] then (fst o dest_var) v else implode vs end
  fun sort_seq tms = let
    val xs = all_distinct (map assum_to_num tms)
    val xs = sort (fn x => fn y => x <= y) xs
    val xs = map (fn x => filter (fn tm => x = assum_to_num tm) tms) xs
    fun internal_sort ys = let
      val zs = filter (fn tm => can (match_term ``GUARD b x``) tm orelse
                                can (match_term ``~(GUARD b x)``) tm) ys          
      val ys = diff ys zs
      fun comp tm1 tm2 = let
        val (defs,_) = dest_eq tm1
        val (_,refs) = dest_eq tm2
        in disjoint (map strip_names (free_vars defs))        
                    (map strip_names (free_vars refs)) end
      fun f [] = []
        | f [x] = [x]
        | f (x::y::ys) = if comp x y then x :: f (y::ys) else y :: f (x::ys)      
      in zs @ f ys end
    in append_lists (map internal_sort xs) end
  fun PUSH_IF_TERM tm = let
    val (b,t1,t2) = dest_cond tm
    val t1 = PUSH_IF_TERM t1
    val t2 = PUSH_IF_TERM t2
    val xs1 = list_dest dest_conj t1
    val xs2 = list_dest dest_conj t2
    val i = guard_to_num b
    val ys1 = filter (fn x => assum_to_num x < i) xs1
    val ys2 = filter (fn x => assum_to_num x < i) xs2
    val _ = if same_set ys1 ys2 then () else hd []
    val zs1 = sort_seq (diff xs1 ys1)
    val zs2 = sort_seq (diff xs2 ys2)
    val q = mk_cond(b,list_mk_conj zs1,list_mk_conj zs2)
    val goal = list_mk_conj(sort_seq ys1 @ [q])
    in goal end handle HOL_ERR _ => 
    list_mk_conj(sort_seq (list_dest dest_conj tm))
  val th = RW [NOT_IF] (DISCH_ALL th)
  val tm = (fst o dest_imp o concl) th
  val goal = mk_imp(PUSH_IF_TERM tm,tm)
  val simp = SIMP_CONV pure_ss [AC CONJ_ASSOC CONJ_COMM]
  val lemma = prove(goal,
    REWRITE_TAC [PUSH_IF_LEMMA]
    THEN CONV_TAC (RAND_CONV simp THENC (RATOR_CONV o RAND_CONV) simp)
    THEN REWRITE_TAC [])
  val th = DISCH_ALL (MP th (UNDISCH lemma))
  val th = CONV_RULE ((RATOR_CONV o RAND_CONV) (SIMP_CONV bool_ss [GUARD_EQ_ZERO])) th
  in th end;

fun list_dest_exists tm ys = let 
  val (v,y) = dest_exists tm
  in list_dest_exists y (v::ys) end handle e => (rev ys, tm)

(* val tm = ``?x. (x = y + 5) /\ x < z /\ t < x`` *)
(* val tm = ``?z. (z = x + 5)`` *)

fun INST_EXISTS_CONV tm = let
  val (v,rest) = dest_exists tm
  val (x,rest) = dest_conj rest
  val (x,y) = dest_eq x
  val th = ISPECL [mk_abs(v,rest),y] UNWIND_THM2
  val th = CONV_RULE (RAND_CONV BETA_CONV) th
  val th = CONV_RULE ((RATOR_CONV o RAND_CONV o RAND_CONV) 
             (ALPHA_CONV v THENC ABS_CONV (RAND_CONV BETA_CONV))) th
  in if x = v then th else NO_CONV tm end handle HOL_ERR _ => let
  val (v,rest) = dest_exists tm
  val (x,y) = dest_eq rest
  val th = GEN_ALL (SIMP_CONV std_ss [] ``?x:'a. x = a``)
  val th = ISPEC y th
  val th = CONV_RULE ((RATOR_CONV o RAND_CONV o RAND_CONV) 
             (ALPHA_CONV v)) th
  in if x = v then th else NO_CONV tm end
   
(* val tm = ``!x. foo (FST x, SND (SND x)) = FST (SND x)`` *)

val EXPAND_FORALL_CONV = let
  fun EXPAND_FORALL_ONCE_CONV tm = 
    ((QUANT_CONV (UNBETA_CONV (fst (dest_forall tm))) THENC
      ONCE_REWRITE_CONV [FORALL_PROD] THENC
      (QUANT_CONV o QUANT_CONV) BETA_CONV)) tm
    handle HOL_ERR _ => ALL_CONV tm;
  in (REPEATC (DEPTH_CONV EXPAND_FORALL_ONCE_CONV)) end
  
(* val tm = ``?x. let (y,z,q) = foo t in y + x + z + 5 = 8 - q`` *)

fun PUSH_EXISTS_LET_CONV tm = let
  val (v,n) = dest_exists tm
  val (x,rest) = pairSyntax.dest_anylet n
  val tm2 = pairSyntax.mk_anylet(x,mk_exists(v,rest))
  val goal = mk_eq(tm,tm2)
  val c = (RATOR_CONV o RATOR_CONV) (REWRITE_CONV [LET_DEF]) THENC
          RATOR_CONV BETA_CONV THENC BETA_CONV THENC
          REPEATC (REWRITE_CONV [UNCURRY_DEF] THENC 
                   RATOR_CONV BETA_CONV) THENC BETA_CONV
  val thi = prove(goal,
    SPEC_TAC (snd (hd x),genvar(type_of (snd (hd x))))
    THEN CONV_TAC EXPAND_FORALL_CONV THEN REPEAT STRIP_TAC
    THEN CONV_TAC ((RAND_CONV) c)
    THEN CONV_TAC ((RATOR_CONV o RAND_CONV o QUANT_CONV) c)
    THEN REWRITE_TAC [])
  in thi end handle e => NO_CONV tm;

(* val tm = ``?x y z. if (q = 4) then (x + 1 = 6) else (y - 8 = z)`` *)

fun PUSH_EXISTS_COND_CONV tm = let
  val (vs,n) = list_dest_exists tm []
  val _ = if vs = [] then hd [] else ()
  val (b,x1,x2) = dest_cond n
  val tm2 = mk_cond(b,list_mk_exists(vs,x1),list_mk_exists(vs,x2))
  val thi = prove(mk_eq(tm,tm2),Cases_on [ANTIQUOTE b] THEN ASM_REWRITE_TAC [])
  in thi end handle e => NO_CONV tm;

(* val tm = ``?x y z. (q = 4) /\ (x + 1 = 6)`` *)

fun PUSH_EXISTS_CONJ_CONV tm = let
  val (vs,n) = list_dest_exists tm []
  val xs = (list_dest dest_conj n)
  val _ = if disjoint (free_vars (hd xs)) vs then () else hd []
  val tm2 = mk_conj(hd xs,list_mk_exists(vs,list_mk_conj(tl xs))) 
  fun PULL_EXISTS_CONV tm = let
    val (x,y) = dest_conj tm
    val (v,y) = dest_exists y  
    val th = ISPEC (mk_abs(v,y)) (SPEC x (GSYM RIGHT_EXISTS_AND_THM))
    val th = CONV_RULE (RAND_CONV (
        RAND_CONV (ALPHA_CONV v) THENC
        QUANT_CONV (RAND_CONV BETA_CONV)) THENC
      (RATOR_CONV o RAND_CONV) (
        RAND_CONV (RAND_CONV (ALPHA_CONV v) THENC
                   QUANT_CONV BETA_CONV))) th
    in th end handle HOL_ERR _ => NO_CONV tm 
  val thi = GSYM (REPEATC (ONCE_DEPTH_CONV PULL_EXISTS_CONV) tm2) 
  in thi end handle Empty => NO_CONV tm; 

(* val tm = ``?x y z. 5 = 6 + t`` *)

fun PUSH_EXISTS_EMPTY_CONV tm = let
  fun DELETE_EXISTS_CONV tm = let
    val (v,rest) = dest_exists tm
    val _ = if mem v (free_vars rest) then hd [] else ()
    val w = genvar(``:bool``)
    val th = INST_TYPE [``:'a``|->type_of v] (SPEC w boolTheory.EXISTS_SIMP)  
    val th = CONV_RULE ((RATOR_CONV o RAND_CONV o RAND_CONV) (ALPHA_CONV v)) th    
    in INST [w |-> rest] th end handle Empty => NO_CONV tm
  val th = DEPTH_CONV DELETE_EXISTS_CONV tm
  in if (is_exists o cdr o concl) th then NO_CONV tm else th end 

(* val tm = ``?x y z. ((x,z) = HD [(5,7)]) /\ (x + 1 = 6)`` *)

fun LET_INTRO_CONV tm = let
  val (vs,n) = list_dest_exists tm []
  val xs = (list_dest dest_conj n)
  val (lhs,rhs) = dest_eq (hd xs)
  val ys = dest_tuple lhs
  val _ = if filter (fn x => not (mem x vs)) ys = [] then () else hd []
  val new_vs = filter (fn x => not (mem x ys)) vs
  val g2 = list_mk_exists(new_vs,list_mk_conj (tl xs))
  val goal = pairSyntax.mk_anylet([(lhs,rhs)],g2)
  val goal = mk_eq(tm,goal)
  fun FIX_EXISTS_CONV ws tm = let
    val (vs,n) = list_dest_exists tm []
    val goal = mk_eq(tm,list_mk_exists(ws,n))   
    fun AUTO_EXISTS_TAC (k,goal) = 
      EXISTS_TAC (fst (dest_exists goal)) (k,goal)
    val lemma = prove(goal,
      EQ_TAC THEN STRIP_TAC THEN REPEAT AUTO_EXISTS_TAC
      THEN REPEAT STRIP_TAC THEN ASM_REWRITE_TAC [])
    in lemma end
  val th = prove(goal,
    CONV_TAC ((RATOR_CONV o RAND_CONV) (FIX_EXISTS_CONV (new_vs @ rev ys)))
    THEN SPEC_TAC (rhs,genvar(type_of rhs))
    THEN CONV_TAC EXPAND_FORALL_CONV
    THEN PURE_REWRITE_TAC [PAIR_EQ,LET_DEF,GSYM CONJ_ASSOC]    
    THEN REPEAT STRIP_TAC
    THEN NTAC (length ys + 3) (PURE_REWRITE_TAC [UNCURRY_DEF]
                               THEN CONV_TAC (ONCE_DEPTH_CONV BETA_CONV))
    THEN NTAC (length ys) 
         (CONV_TAC (RATOR_CONV (ONCE_DEPTH_CONV INST_EXISTS_CONV)))
    THEN REWRITE_TAC [])
  in th end handle Empty => NO_CONV tm;

fun DEPTH_EXISTS_CONV c tm = 
  if is_exists tm then (c THENC DEPTH_EXISTS_CONV c) tm else
  if can (match_term ``GUARD n x``) tm then ALL_CONV tm else
  if is_comb tm then (RATOR_CONV (DEPTH_EXISTS_CONV c) THENC
                      RAND_CONV (DEPTH_EXISTS_CONV c)) tm else
  if is_abs tm then ABS_CONV (DEPTH_EXISTS_CONV c) tm else ALL_CONV tm;

val problem = ref T;
val attempt = ref T;

val tm = !attempt

fun introduce_lets th = let
  val th = init_clean th
  val th = push_if_inwards th
  val (lhs,rhs) = (dest_imp o concl) th  
  val vs = diff (free_vars lhs) (free_vars rhs)  
  val th = CONV_RULE ((RATOR_CONV o RAND_CONV) (ONCE_REWRITE_CONV [GSYM CONTAINER_def])) th
  val th = SIMP_RULE bool_ss [LEFT_FORALL_IMP_THM] (GENL vs th)
  val th = RW1 [CONTAINER_def] th
  val c = DEPTH_EXISTS_CONV ((fn tm => (attempt := tm; NO_CONV tm)) ORELSEC
                             LET_INTRO_CONV ORELSEC
                             PUSH_EXISTS_CONJ_CONV ORELSEC
                             PUSH_EXISTS_COND_CONV ORELSEC
                             PUSH_EXISTS_EMPTY_CONV ORELSEC 
                             (fn tm => (print "\n\nERROR: Unable to turn into let expression:\n\n"; print_term tm; print "\n\n"; (problem := tm); NO_CONV tm)))
  val th = CONV_RULE ((RATOR_CONV o RAND_CONV) c) th
  in th end;

fun raw_tm2ftree tm = let
  val (x,y) = dest_conj tm
  val _ = if can (match_term ``GUARD b x``) x then () else hd []
  in FUN_COND (x,raw_tm2ftree y) end handle e => let
  val (b,x,y) = dest_cond tm
  in FUN_IF (b,raw_tm2ftree x,raw_tm2ftree y) end handle e => let
  val (x,y) = pairSyntax.dest_anylet tm
  val z = raw_tm2ftree y
  fun g((x,y),z) = FUN_LET (x,y,z)
  in foldr g z x end handle e => FUN_VAL tm;

val var_sorter = let (* sorts in alphabetical order except for r1,r2,r3 which will come first *)
  fun dest_reg_var s = let
    val xs = explode s
    in if hd xs = #"r" then string_to_int (implode (tl xs)) else hd [] end
  val is_reg_var = can dest_reg_var
  fun name_of_var tm = let
    val s = fst (dest_var tm)
    in if s = "eax" then "r0" else    
       if s = "ecx" then "r1" else    
       if s = "edx" then "r2" else    
       if s = "ebx" then "r3" else    
       if s = "esp" then "r4" else    
       if s = "ebp" then "r5" else    
       if s = "esi" then "r6" else    
       if s = "edi" then "r7" else s end  
  fun cmp tm1 tm2 = let
    val s1 = name_of_var tm1
    val s2 = name_of_var tm2
    in if is_reg_var s1 = is_reg_var s2 
       then (dest_reg_var s1 < dest_reg_var s2 handle e => s1 < s2)
       else is_reg_var s1 end
  in sort cmp end

fun leaves (FUN_VAL tm)      f = FUN_VAL (f tm)
  | leaves (FUN_COND (c,t))  f = FUN_COND (c, leaves t f)
  | leaves (FUN_IF (a,b,c))  f = FUN_IF (a, leaves b f, leaves c f)
  | leaves (FUN_LET (v,y,t)) f = FUN_LET (v, y, leaves t f)

fun erase_conds (FUN_VAL tm) = FUN_VAL tm
  | erase_conds (FUN_COND (c,t)) = erase_conds t
  | erase_conds (FUN_IF (a,b,c)) = FUN_IF (a,erase_conds b,erase_conds c)
  | erase_conds (FUN_LET (x,y,t)) = FUN_LET (x,y,erase_conds t)

val REMOVE_TAGS_CONV = let
  val alpha_lemma = prove(``!b:bool. (b = T) ==> b``,Cases THEN REWRITE_TAC []);
  fun REMOVE_TAG_CONV tm = let
    val (v,x) = dest_abs tm  
    val xs = free_vars x 
    fun d [] = hd []
      | d (x::xs) = if x = #"@" then implode xs else d xs
    fun strip_tag v = mk_var((d o explode o fst o dest_var) v, type_of v)
    fun add_prime v = mk_var(fst (dest_var v) ^ "'", type_of v)
    fun is_ok v = not (mem v xs)
    fun UNTIL g f x = if g x then x else UNTIL g f (f x)
    val w = UNTIL is_ok add_prime (strip_tag v) 
    val thi = SIMP_CONV std_ss [FUN_EQ_THM] (mk_eq(tm,mk_abs(w,subst [v|->w] x)))
    in MATCH_MP alpha_lemma thi end handle Empty => NO_CONV tm
  in (DEPTH_CONV REMOVE_TAG_CONV THENC REWRITE_CONV [GUARD_def]) end

fun EXPAND_BASIC_LET_CONV tm = let
  val (xs,x) = pairSyntax.dest_anylet tm
  val (lhs,rhs) = hd xs 
  val ys = dest_tuple lhs
  val zs = dest_tuple rhs
  val _ = if length zs = length ys then () else hd []
  fun every p [] = true
    | every p (x::xs) = if p x then every p xs else hd []
  val _ = every (fn x => every is_var (list_dest dest_conj x)) zs
  in (((RATOR_CONV o RATOR_CONV) (REWRITE_CONV [LET_DEF]))
      THENC DEPTH_CONV PairRules.PBETA_CONV) tm end
  handle Empty => NO_CONV tm

fun STRIP_FORALL_TAC (hs,tm) =  
  if is_forall tm then STRIP_TAC (hs,tm) else NO_TAC (hs,tm)

fun SPEC_AND_REWRITE_TAC x = 
  SPEC_TAC (x,genvar(type_of x)) 
  THEN SIMP_TAC pure_ss [FORALL_PROD] 
  THEN CONV_TAC (DEPTH_CONV EXPAND_BASIC_LET_CONV) 
  THEN REPEAT STRIP_FORALL_TAC

fun SPEC_AND_CASES_TAC x = 
  SPEC_TAC (x,genvar(type_of x)) THEN Cases THEN REWRITE_TAC []
  
fun AUTO_DECONSTRUCT_TAC finder (hs,goal) = let
  val tm = finder goal
  in if is_cond tm then let
       val (b,_,_) = dest_cond tm
       in SPEC_AND_CASES_TAC b (hs,goal) end
     else if is_let tm then let
       val (v,c) = (hd o fst o pairSyntax.dest_anylet) tm       
       val c = if not (type_of c = ``:bool``) then c else
         (find_term (can (match_term ``GUARD x b``)) c handle e => c)  
       in SPEC_AND_REWRITE_TAC c (hs,goal) end 
     else (REWRITE_TAC [] THEN NO_TAC) (hs,goal) end

fun simplify_and_define name x_in rhs = let
  val ty = mk_type("fun",[type_of x_in, type_of rhs])
  val rw = REMOVE_TAGS_CONV rhs handle HOL_ERR _ => REFL rhs
  val tm = mk_eq(mk_comb(mk_var(name,ty),x_in),cdr (concl rw))
  val def = SPEC_ALL (new_definition(name ^ "_def", tm))
  in CONV_RULE (RAND_CONV (fn tm => GSYM rw)) def end

fun pull_T (FUN_VAL tm) = FUN_VAL tm
  | pull_T (FUN_COND tm) = FUN_COND tm
  | pull_T (FUN_IF (tm,x,y)) = let
      val x' = pull_T x
      val y' = pull_T y
      in if ((x' = FUN_VAL ``T:bool``) andalso (y' = FUN_VAL ``T:bool``)) orelse (x' = y') 
         then x' else FUN_IF (tm,x',y') end
  | pull_T (FUN_LET (tm,tn,x)) = let
      val x' = pull_T x
      val vs = free_vars (ftree2tm x')
      val ws = free_vars tm
      in if filter (fn v => mem v ws) vs = [] then x' else FUN_LET (tm,tn,x') end

fun simplify_pre pre th = let
  val ft = pull_T (tm2ftree ((cdr o concl) pre))
  val goal = mk_comb((car o concl) pre, ftree2tm ft)
  in if not (ft = FUN_VAL ``T``) then (th,pre) else let
    val new_pre = (prove(goal,
      REWRITE_TAC []
      THEN ONCE_REWRITE_TAC [pre]
      THEN REPEAT (AUTO_DECONSTRUCT_TAC I)))
    val th = RW [new_pre,SEP_CLAUSES] th
    in (th,new_pre) end end

fun introduce_post_let th = let
  val (x,y) = (dest_comb o cdr o concl) th
  val (x,z) = pairSyntax.dest_pabs x
  val tm = pairSyntax.mk_anylet([(x,y)],z)
  val th1 = GSYM (SIMP_CONV std_ss [LET_DEF] tm)
  in CONV_RULE (RAND_CONV (ONCE_REWRITE_CONV [th1])) 
       (SIMP_RULE std_ss [] th) end handle e => th;

fun REMOVE_VARS_FROM_THM vs th = let
  fun REMOVE_FROM_LHS (v,th) = let
    val th = SIMP_RULE pure_ss [LEFT_FORALL_IMP_THM] (GEN v th)
    val c = DEPTH_EXISTS_CONV ((fn tm => (attempt := tm; NO_CONV tm)) ORELSEC
                               PUSH_EXISTS_COND_CONV ORELSEC
                               PUSH_EXISTS_LET_CONV ORELSEC
                               PUSH_EXISTS_CONJ_CONV ORELSEC 
                               INST_EXISTS_CONV)
    val th = CONV_RULE ((RATOR_CONV o RAND_CONV) c) th  
    in th end
  in foldr REMOVE_FROM_LHS th vs end

fun HIDE_POST_VARS vs th = let
  fun hide_one (v,th) = let
    val (_,_,_,q) = (dest_spec o concl) th    
    val tm = hd (filter (mem v o free_vars) (list_dest dest_star q))      
    in HIDE_POST_RULE (car tm) th end handle Empty => th
  val th = RW [GSYM SPEC_MOVE_COND] th
  val th = foldr hide_one th vs 
  val th = RW [SPEC_MOVE_COND] th
  val th = RW [] (DISCH_ALL th)
  val th = REMOVE_VARS_FROM_THM vs th
  in th end;

fun HIDE_PRE_VARS vs th1 = let
  fun hide_one (v,th) = let
    val (_,q,_,_) = (dest_spec o concl) th    
    val tm = hd (filter (mem v o free_vars) (list_dest dest_star q))      
    in HIDE_PRE_RULE (car tm) th end handle Empty => th
  val th1 = CONV_RULE ((RATOR_CONV o RAND_CONV) (ONCE_REWRITE_CONV [GSYM CONTAINER_def])) th1
  val th1 = UNDISCH_ALL th1
  val th1 = foldr hide_one th1 vs 
  val th1 = RW [CONTAINER_def] (DISCH_ALL th1)
  in th1 end;

fun SORT_SEP_CONV tm = let
  fun remove_tags tm = 
    subst (map (fn v => v |-> mk_var(strip_tag v,type_of v)) (free_vars tm)) tm
  val xs = list_dest dest_star tm
  fun compare tm1 tm2 = let
    val s1 = term_to_string (remove_tags (get_sep_domain tm1))
    val s2 = term_to_string (remove_tags (get_sep_domain tm2))
    in if size s2 < size s1 then 1 < 2 else
       if size s1 < size s2 then 2 < 1 else 
       if not (s1 = s2) then s1 < s2 else
         term_to_string (remove_tags tm1) < term_to_string (remove_tags tm2) end
  val tm2 = list_mk_star (sort compare xs) (type_of tm)
  val thi = prove(mk_eq(tm,tm2),SIMP_TAC (bool_ss++star_ss) [])
  in thi end;

fun extract_function name th entry exit function_in_out = let
  val _ = echo 1 " extracting,"
  fun is_new_var v = (implode o take 4 o explode o fst o dest_var) v = "new@"
  val output = (filter (not o is_new_var) o free_vars o cdr o concl) th
  fun drop_until p [] = []
    | drop_until p (x::xs) = if p x then x::xs else drop_until p xs 
  fun strip_names v = let
    val vs = (tl o drop_until (fn x => x = #"@") o explode o fst o dest_var) v
    in if vs = [] then (fst o dest_var) v else implode vs end 
    handle Empty => (fst o dest_var) v
  fun new_abbrev (v,th) = let
    val th = RW [GSYM SPEC_MOVE_COND] (DISCH_ALL th)
    val n = "new@" ^ strip_names v
    val th = raw_abbreviate2 (n,v,v) th
    val th = RW [SPEC_MOVE_COND,AND_IMP_INTRO] (DISCH_ALL th)
    val th = RW [PUSH_IF_LEMMA] th 
    in th end
  val th = foldr new_abbrev th output
  val th = introduce_lets th
  val th = INST [mk_var("new@p",``:word32``) |-> mk_var("set@p",``:word32``)] th
  val th = INST [mk_var("eip",``:word32``) |-> mk_var("p",``:word32``)] th
  val t = raw_tm2ftree ((cdr o car o concl o RW [WORD_ADD_0]) th)  
  (* extract base, step, side, input, output *)
  fun gen_pc n = if n = 0 then ``p:word32`` else
    subst [mk_var("n",``:num``) |-> numSyntax.term_of_int n] ``(p:word32) + n2w n`` 
  val entry_tm = gen_pc 0
  val exit_tm = gen_pc (exit - entry)
  val final_node = mk_eq(mk_var("set@p",``:word32``),exit_tm)
  fun is_terminal_node tm = can (find_term (fn x => x = final_node)) tm
  val side = ftree2tm (leaves t (fn x => mk_var("cond",``:bool``)))
  val side = subst [mk_var("cond",``:bool``) |-> ``T``] side
  val side = (cdr o concl o REWRITE_CONV []) side handle UNCHANGED => side
  val t2 = erase_conds t
  val guard = ftree2tm (leaves t2 
    (fn x => if is_terminal_node x then ``F:bool`` else ``T:bool``))
  val output = (filter is_new_var o free_vars o cdr o cdr o concl) th
  fun strip_tag v = mk_var((implode o drop 4 o explode o fst o dest_var) v, type_of v)
  val output = var_sorter (map strip_tag output)
  fun rm_pc tm = let
    val xs = find_terms (fn x => fst (dest_eq x) = mk_var("set@p",``:word32``) handle HOL_ERR _ => false) tm
    in subst (map (fn x => x |-> T) xs) tm end
  val iii = (list_mk_pair o var_sorter o filter (not o is_new_var) o 
               free_vars o rm_pc o ftree2tm o leaves t)
            (fn x => if is_terminal_node x then x else ``T:bool``)
  val input = (var_sorter o filter (not o is_new_var) o filter (fn v => not (v = mk_var("cond",``:bool``))) o
               free_vars o rm_pc o ftree2tm o leaves t)
           (fn x => if is_terminal_node x then x else mk_eq(iii,iii))
  val input = if input = [] then [mk_var("()",``:unit``)] else input
  fun set_input_output NONE = (input,output) 
    | set_input_output (SOME (ix,ox)) = (dest_tuple ix, dest_tuple ox)
  val (input,output) = set_input_output function_in_out
  fun new_into_subst tm = let
    val vs = list_dest dest_conj tm
    in subst (map (fn x => let val (x,y) = dest_eq x in (strip_tag x) |-> y end) vs) end
  val x_in = list_mk_pair input
  val x_out = list_mk_pair output
  val base = ftree2tm (leaves t2 (fn x => if is_terminal_node x then new_into_subst x x_out else mk_arb (type_of x_out)))
  val step = ftree2tm (leaves t2 (fn x => new_into_subst x x_in))
  fun add_new_tag v = mk_var("new@" ^ fst (dest_var v), type_of v)
  val new_output = list_mk_pair (map add_new_tag output)
  val new_input = list_mk_pair (map add_new_tag input)
  (* define the component functions *)
  val side_def  = simplify_and_define (name ^ "_side") x_in side
  val guard_def = simplify_and_define (name ^ "_guard") x_in guard
  val base_def  = simplify_and_define (name ^ "_base") x_in base
  val step_def  = simplify_and_define (name ^ "_step") x_in step
  val get_name  = repeat car o cdr o car o concl o SPEC_ALL 
  val thi = ISPEC (get_name step_def) tailrecTheory.TAILREC_def
  val thi = ISPEC (get_name base_def) thi
  val thi = ISPEC (get_name guard_def) thi
  val tmi = (car o fst o dest_eq o concl o SPEC_ALL) thi
  val main_def = new_definition(name, mk_eq(mk_var(name,type_of tmi),tmi))
  val thi = ISPEC (get_name step_def) tailrecTheory.TAILREC_PRE_def
  val thi = ISPEC (get_name guard_def) thi
  val thi = ISPEC (get_name side_def) thi
  val tmi = (car o fst o dest_eq o concl o SPEC_ALL) thi
  val pre_def = new_definition(name ^ "_pre", mk_eq(mk_var(name ^ "_pre",type_of tmi),tmi))
  val _ = tailrecLib.tailrec_add_to_simpsets
            (main_def,pre_def,step_def,base_def,guard_def,side_def)
  (* derive the official extracted definitions *)
  val main_lhs = mk_comb(get_name main_def, x_in)
  val main_rhs = ftree2tm (leaves t2 (fn x => new_into_subst x 
                   (if is_terminal_node x then x_out else main_lhs)))
  val pre_lhs = mk_comb(get_name pre_def, x_in)
  val pre_rhs = ftree2tm (leaves t (fn x => new_into_subst x 
                   (if is_terminal_node x then mk_var("cond",``:bool``) else mk_conj(pre_lhs,mk_var("cond",``:bool``)))))
  val pre_rhs = subst [mk_var("cond",``:bool``) |-> ``T``] pre_rhs
  val pre_rhs = (cdr o concl o REWRITE_CONV []) pre_rhs handle UNCHANGED => pre_rhs
  val main_tm = mk_eq(main_lhs,main_rhs)    
  val pre_tm = mk_eq(pre_lhs,pre_rhs)    
  val tac = 
    CONV_TAC (RATOR_CONV (REWRITE_CONV [main_def,pre_def]))
    THEN ONCE_REWRITE_TAC [tailrecTheory.TAILREC_THM]
    THEN ONCE_REWRITE_TAC [tailrecTheory.TAILREC_PRE_THM]
    THEN REWRITE_TAC [GSYM main_def,GSYM pre_def]  
    THEN REWRITE_TAC [base_def,side_def,guard_def,step_def]
    THEN REPEAT (AUTO_DECONSTRUCT_TAC cdr)
    THEN SIMP_TAC std_ss [] THEN EQ_TAC THEN SIMP_TAC std_ss []
  val main_thm = CONV_RULE REMOVE_TAGS_CONV (prove(main_tm,tac))  
  val pre_thm = CONV_RULE REMOVE_TAGS_CONV (prove(pre_tm,tac))  
  (* prove lemmas for final proof *)
  val _ = echo 1 " proving certificate,"
  val (th1,th2) = (th,th)
  val finder = hd o list_dest dest_conj o fst o dest_imp
  val tac2 = 
    REWRITE_TAC [side_def,guard_def,base_def,step_def]
    THEN REPEAT (AUTO_DECONSTRUCT_TAC finder)
    THEN SIMP_TAC std_ss []
  val lemma1 = let
    val th1 = INST [mk_var("set@p",``:word32``) |-> exit_tm] th1
    val th1 = RW [] th1
    val post = (free_vars o cdr o snd o dest_imp o concl) th1
    val top = (free_vars o fst o dest_imp o concl) th1
    val new_top = filter is_new_var top
    val vs = diff new_top (dest_tuple new_output @ output)
    val th1 = HIDE_POST_VARS vs th1
    val pre = (free_vars o cdr o car o car o snd o dest_imp o concl) th1
    val ws = diff pre (mk_var("p",``:word32``)::input)
    val tm = (fst o dest_imp o concl o DISCH_ALL) th1
    val get_lhs = (fst o dest_eq o concl o SPEC_ALL) 
    val tm2 = list_mk_conj [get_lhs side_def,mk_neg(get_lhs guard_def),
                            mk_eq(new_output,get_lhs base_def)]
    val goal = mk_imp(tm2,tm)
    val lemma = UNDISCH (prove(goal,tac2))
    val lemma1 = DISCH_ALL (MP th1 lemma)
    val lemma1 = HIDE_PRE_VARS ws lemma1
    in lemma1 end
  val lemma2 = let
    val th2 = INST [mk_var("set@p",``:word32``) |-> entry_tm] th2
    val th2 = RW [WORD_ADD_0] th2
    val post = (free_vars o cdr o snd o dest_imp o concl) th1
    val top = (free_vars o fst o dest_imp o concl) th1
    val new_top = filter is_new_var top    
    val vs = diff new_top (dest_tuple new_input)
    val th2 = HIDE_POST_VARS vs th2
    val pre = (free_vars o cdr o car o car o snd o dest_imp o concl) th2
    val vs = diff pre (mk_var("p",``:word32``)::input)
    val tm = (fst o dest_imp o concl o DISCH_ALL) th2
    val get_lhs = (fst o dest_eq o concl o SPEC_ALL) 
    val tm2 = list_mk_conj [get_lhs side_def,get_lhs guard_def,
                            mk_eq(new_input,get_lhs step_def)]
    val goal = mk_imp(tm2,tm)
    val lemma = UNDISCH (prove(goal,tac2))
    val lemma2 = DISCH_ALL (MP th2 lemma)
    val lemma2 = HIDE_PRE_VARS vs lemma2
    in lemma2 end
  val sort_conv = PRE_CONV SORT_SEP_CONV THENC POST_CONV SORT_SEP_CONV
  val lemma1 = CONV_RULE (RAND_CONV sort_conv) lemma1
  val lemma2 = CONV_RULE (RAND_CONV sort_conv) lemma2
  (* certificate theorem *)
  fun remove_new_tags tm = let
    val vs = filter is_new_var (free_vars tm)
    in subst (map (fn v => v |-> strip_tag v) vs) tm end
  val thi = ISPEC (get_name step_def) SPEC_TAILREC
  val thi = ISPEC (get_name base_def) thi
  val thi = ISPEC (get_name guard_def) thi
  val thi = ISPEC (get_name side_def) thi
  val thi = RW [GSYM main_def, GSYM pre_def] thi
  val (m,p,c,q) = (dest_spec o concl o UNDISCH_ALL) lemma1
  val thi = ISPEC (mk_pabs(x_in,p)) thi
  val thi = ISPEC (mk_pabs(x_out,remove_new_tags q)) thi
  val thi = ISPEC c thi
  val thi = ISPEC m thi
  val goal = (snd o dest_imp o concl) thi
(*
  set_goal([],goal)
*)
  val th = prove(goal,
    MATCH_MP_TAC thi THEN STRIP_TAC 
    THEN ONCE_REWRITE_TAC [EQ_SYM_EQ]
    THEN SIMP_TAC std_ss [FORALL_PROD]
    THEN ONCE_REWRITE_TAC [EQ_SYM_EQ]
    THENL [    
      REPEAT STRIP_TAC
      THEN MATCH_MP_TAC (GEN_ALL (RW [WORD_ADD_0] lemma2))
      THEN ASM_SIMP_TAC std_ss [] THEN Q.EXISTS_TAC `x`
      THEN ASM_REWRITE_TAC [],
      REPEAT STRIP_TAC
      THEN MATCH_MP_TAC (GEN_ALL (RW [WORD_ADD_0] lemma1))
      THEN ASM_SIMP_TAC std_ss [] THEN Q.EXISTS_TAC `x`
      THEN ASM_REWRITE_TAC []])
  val th = SIMP_RULE pure_ss [FORALL_PROD] th
  val th = SPECL input th
  val th = RW [GSYM SPEC_MOVE_COND] th 
  val th = introduce_post_let th  
  val th = INST [mk_var("()",``:unit``) |-> ``():unit``] th
  val _ = echo 1 " done.\n"
  val _ = save_thm(name ^ "_def",main_thm)
  val _ = save_thm(name ^ "_pre_def",pre_thm)
  in (th,main_thm,pre_thm) end;  


(* ------------------------------------------------------------------------------ *)
(* Implementation of STAGE 4                                                      *)
(* ------------------------------------------------------------------------------ *)

fun prepare_for_reuse n (th,i,j) = let
  val prefix = ("s"^(int_to_string n)^"@") 
  in (n,(ABBREV_CALL prefix th,i,j),NONE) end;

fun decompile_part name thms (entry,exit) (function_in_out: (term * term) option) = let
  val t = generate_spectree thms (entry,exit)
  val th = merge_spectree name t
  val (th,def,pre) = extract_function name th entry exit function_in_out
  val (th,pre) = simplify_pre pre th
  val (th,def) = (!decompiler_finalise) (th,def)
  in (def,pre,th) end;

fun decompile (tools :decompiler_tools) name (qcode :term quotation) = let
  val (thms,loops) = stage_12 tools qcode
  val loops = map (fn (x,y) => (hd x, hd y)) loops
  fun decompile_all thms (defs,pres) [] prev = (LIST_CONJ defs,LIST_CONJ pres,prev)
    | decompile_all thms (defs,pres) ((entry,exit)::loops) prev = let
      val part_name = if length loops = 0 then name else (name ^ int_to_string (length loops))
      val function_in_out = (NONE: (term * term) option)
      val (def,pre,result) = decompile_part part_name thms (entry,exit) function_in_out 
      val thms = prepare_for_reuse entry (result,0,SOME exit) :: thms
      in decompile_all thms (def::defs,pre::pres) loops result end
  val (def,pre,result) = decompile_all thms ([],[]) loops TRUTH
(*    
  val (entry,exit)::loops = loops
*)  
  val exit = snd (last loops)
  val _ = add_decompiled (name,result,exit,SOME exit)
  in (result,CONJ def pre) end;

val decompile_arm = decompile arm_tools
val decompile_ppc = decompile ppc_tools
val decompile_x86 = decompile x86_tools

fun basic_decompile (tools :decompiler_tools) name function_in_out (qcode :term quotation) = let
  val (thms,loops) = stage_12 tools qcode
  val (entry,exit) = (fn (x,y) => (hd x, hd y)) (last loops)
  val (def,pre,result) = decompile_part name thms (entry,exit) function_in_out
  val _ = add_decompiled (name,result,exit,SOME exit)
  in (result,CONJ def pre) end;

val basic_decompile_arm = basic_decompile arm_tools
val basic_decompile_ppc = basic_decompile ppc_tools
val basic_decompile_x86 = basic_decompile x86_tools

end;
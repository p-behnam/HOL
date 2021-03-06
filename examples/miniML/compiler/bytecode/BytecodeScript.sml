(* generated by Lem from bytecode.lem *)
open bossLib Theory Parse res_quanTheory
open finite_mapTheory listTheory pairTheory pred_setTheory integerTheory
open set_relationTheory sortingTheory stringTheory wordsTheory

val _ = new_theory "Bytecode"

(* --- Syntax --- *)

val _ = Hol_datatype `

  bc_stack_op =
    Pop                     (* pop top of stack *)
  | Pops of num             (* pop n elements under stack top *)
  | Shift of num => num      (* shift top n elements down k places *)
  | PushInt of int          (* push num onto stack *)
  | Cons of num => num       (* push new cons with tag m and n elements *)
  | Load of num             (* push stack[n+1] *)
  | Store of num            (* pop and store in stack[n+1] *)
  | El of num               (* read field n of cons block *)
  | TagEquals of num        (* test tag from cons block or number *)
  | IsNum | Equal           (* more tests *)
  | Add | Sub | Mult | Div2 | Mod2 | Less`;
  (* arithmetic *)

val _ = Hol_datatype `

  bc_inst =
    Stack of bc_stack_op
  | Jump of num             (* jump to location n *)
  | JumpNil of num          (* conditional jump to location n *)
  | Call of num             (* call location n *)
  | JumpPtr                 (* jump based on code pointer *)
  | CallPtr                 (* call based on code pointer *)
  | Return                  (* pop return address, jump *)
  | Exception               (* restore stack, jump *)
  | Ref                     (* create a new ref cell *)
  | Deref                   (* dereference a ref cell *)
  | Update`;
                  (* update a ref cell *)

(* --- Semantics --- *)

(* move to lem *)
(*val num_to_int : num -> int*)
(*val drop : forall 'a. num -> 'a list -> 'a list*)

 val bool_to_int_defn = Hol_defn "bool_to_int" `

(bool_to_int T = & 1)
/\
(bool_to_int F = & 0)`;

val _ = Defn.save_defn bool_to_int_defn;

(* the stack is a list of elements of bc_value *)

val _ = Hol_datatype `

  bc_value =
    Number of int                  (* integer *)
  | Block of num => bc_value list   (* cons block: tag and payload *)
  | CodePtr of num                 (* code pointer *)
  | RefPtr of num`;
                  (* pointer to ref cell *)

val _ = Hol_datatype `

  bc_state =
   <| (* main state components *)
      stack : bc_value list;
      code : bc_inst list ;
      pc : num ;
      refs : (num, bc_value) fmap ;
      exstack : (num # num) list ;
      (* artificial state components *)
      inst_length : bc_inst -> num
   |>`;


(* fetching the next instruction from the code *)

 val bc_fetch_aux_defn = Hol_defn "bc_fetch_aux" `

(bc_fetch_aux [] len (n:num) = NONE)
/\
(bc_fetch_aux (x::xs) len n =
  if n = 0 then SOME x else
    if n < len x + 1 then NONE else
      bc_fetch_aux xs len (n - (len x + 1)))`;

val _ = Defn.save_defn bc_fetch_aux_defn;

val _ = Define `
 (bc_fetch s = bc_fetch_aux s.code s.inst_length s.pc)`;


(* most instructions just bump the pc along, for this we use bump_pc *)

val _ = Define `
 (bump_pc s = (case bc_fetch s of
  NONE => s
| SOME x =>  s with<| pc := s.pc + s.inst_length x + 1 |>
))`;


(* next state relation *)

val _ = Hol_reln `
(! x xs. T ==>
bc_stack_op Pop (x::xs) (xs))
/\
(! x ys xs. T ==>
bc_stack_op (Pops (LENGTH ys)) (x::ys++xs) (x::xs))
/\
(! ys zs xs. T ==>
bc_stack_op (Shift (LENGTH ys) (LENGTH zs)) (ys++(zs++xs)) (ys++xs))
/\
(! n xs. T ==>
bc_stack_op (PushInt n) (xs) (Number n::xs))
/\
(! tag ys xs. T ==>
bc_stack_op (Cons tag (LENGTH ys)) (ys++xs) (Block tag (REVERSE ys)::xs))
/\
(! k xs. k < LENGTH xs ==>
bc_stack_op (Load k) xs (EL  k  xs::xs))
/\
(! y ys x xs. T ==>
bc_stack_op (Store (LENGTH ys)) (y::ys++x::xs) (ys++y::xs))
/\
(! k tag ys xs. k < LENGTH ys ==>
bc_stack_op (El k) ((Block tag ys)::xs) (EL  k  ys::xs))
/\
(! t tag ys xs. T ==>
bc_stack_op (TagEquals t) ((Block tag ys)::xs) (Number (bool_to_int (tag = t))::xs))
/\
(! t i xs. T ==>
bc_stack_op (TagEquals t) ((Number i)::xs) (Number (bool_to_int (i = & t))::xs))
/\
(! x xs. T ==>
bc_stack_op IsNum (x::xs) (Number (bool_to_int (? n. x = Number n))::xs))
/\
(! x2 x1 xs. T ==>
bc_stack_op Equal (x2::x1::xs) (Number (bool_to_int (x1 = x2))::xs))
/\
(! n m xs. T ==>
bc_stack_op Less (Number n::Number m::xs) (Number (bool_to_int (int_lt m n))::xs))
/\
(! n m xs. T ==>
bc_stack_op Add  (Number n::Number m::xs) (Number (int_add m n)::xs))
/\
(! n m xs. T ==>
bc_stack_op Sub  (Number n::Number m::xs) (Number ((int_sub) m n)::xs))
/\
(! n m xs. T ==>
bc_stack_op Mult (Number n::Number m::xs) (Number (int_mul m n)::xs))
/\
(! m xs. T ==>
bc_stack_op Div2 (Number m::xs) (Number (int_div m (& 2))::xs))
/\
(! m xs. T ==>
bc_stack_op Mod2 (Number m::xs) (Number (int_mod m (& 2))::xs))`;

val _ = Hol_reln `
(! s b ys.
(bc_fetch s = SOME (Stack b))
/\ bc_stack_op b (s.stack) ys
==>
bc_next s (bump_pc s with<| stack := ys|>)) (* parens throughout: lem sucks *)
/\
(! s n.
(bc_fetch s = SOME (Jump n)) (* parens: ugh...*)
==>
bc_next s (s with<| pc := n|>))
/\
(! s n x xs s'.
(bc_fetch s = SOME (JumpNil n))
/\ (s.stack = x::xs)
/\ (s' = (s with<| stack := xs|>))
==>
bc_next s (if x = Number (& 0) then bump_pc s' else s' with<| pc := n|>))
/\
(! s n x xs.
(bc_fetch s = SOME (Call n))
/\ (s.stack = x::xs)
==>
bc_next s (s with<| pc := n; stack := x::CodePtr ((bump_pc s).pc)::xs|>))
/\
(! s ptr x xs.
(bc_fetch s = SOME CallPtr)
/\ (s.stack = CodePtr ptr::x::xs)
==>
bc_next s (s with<| pc := ptr; stack := x::CodePtr ((bump_pc s).pc)::xs|>))
/\
(! s ptr xs.
(bc_fetch s = SOME JumpPtr)
/\ (s.stack = CodePtr ptr::xs)
==>
bc_next s (s with<| pc := ptr; stack := xs|>))
/\
(! s x n xs.
(bc_fetch s = SOME Return)
/\ (s.stack = x::CodePtr n::xs)
==>
bc_next s (s with<| pc := n; stack := x::xs|>))
/\
(! s p m es x xs.
(bc_fetch s = SOME Exception)
/\ (s.stack = x::xs)
/\ (s.exstack = (p,m)::es)
/\ m <= LENGTH xs
==>
bc_next s (s with<| pc := p; stack := x::DROP (LENGTH xs - m) xs|>))
/\
(! s x xs ptr.
(bc_fetch s = SOME Ref)
/\ (s.stack = x::xs)
/\ ~  ( ptr IN FDOM  s.refs)
==>
bc_next s (bump_pc s with<| stack := (RefPtr ptr)::xs; refs := FUPDATE  s.refs ( ptr, x)|>))
/\
(! s ptr xs.
(bc_fetch s = SOME Deref)
/\ (s.stack = (RefPtr ptr)::xs)
/\  ptr IN FDOM  s.refs
==>
bc_next s (bump_pc s with<| stack := FAPPLY  s.refs  ptr::xs|>))
/\
(! s x ptr xs.
(bc_fetch s = SOME Update)
/\ (s.stack = x::(RefPtr ptr)::xs)
/\  ptr IN FDOM  s.refs
==>
bc_next s (bump_pc s with<| stack := xs; refs := FUPDATE  s.refs ( ptr, x)|>))`;
val _ = export_theory()


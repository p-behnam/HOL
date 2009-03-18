signature quantHeuristicsLib =
sig
  include Abbrev


(*some general conversions, that might be useful
  in other context as well *)
  val TOP_ONCE_REWRITE_CONV        : thm list -> conv;
  val NEG_NEG_INTRO_CONV           : conv;
  val NEG_NEG_ELIM_CONV            : conv;
  val NOT_FORALL_LIST_CONV         : conv;
  val NOT_EXISTS_LIST_CONV         : conv;
  val STRIP_NUM_QUANT_CONV         : int -> conv -> conv;
  val BOUNDED_NOT_EXISTS_LIST_CONV : int -> conv;
  val BOUNDED_REPEATC              : int -> conv -> conv;

  val EXISTS_NOT_LIST_CONV         : conv;
  val FORALL_NOT_LIST_CONV         : conv;
  val QUANT_SIMP_CONV              : conv;

  val NOT_OR_CONV                  : conv;
  val NOT_AND_CONV                 : conv;
  val AND_NOT_CONV                 : conv;
  val OR_NOT_CONV                  : conv;


  val DISCH_ASM_CONV_TAC           : conv -> tactic;
  val DISCH_ASM_CONSEQ_CONV_TAC    : ConseqConv.directed_conseq_conv -> tactic;

(*Guesses*)

  datatype guess =
    (*A guess with no particular reason at all, no justification. This
      is for example used by EXISTS_TAC.

      guess_general (i, [fv1,...,fvn])

      can be used to proof

      ?fv1 ... fvn. P i ==> ?v. P v   and
      !v. P v ==> !fv1 ... fvn. P i

      or if one want's to use equations 

      ?v. P v = (?fv1 ... fvn. P i) \/ 
                   ?v. (!fv1 ... fvn. ~(i = v)) /\ (P v)  and

      !v. P v = (!fv1 ... fvn. P i) /\
		   (!v. (?fv1 ... fvn. ~(i = v)) ==> P v)


      These two possibilies are always available and
      choosen if the other guesses don't provide a theorem.
    *)
    guess_general of term * term list 

    (*i makes P i false

      This can be used to proof
      !v. P v = F

      If a theorem is provided it has to be of the form 
      !fv1 ... fvn. ~(P i)
    *)
  | guess_false of term * term list * (unit -> thm) option 

    (*i makes P i true

      This can be used to proof
      ?v. P v = T

      The theorem has to be of the form 
      !fv1 ... fvn. P i
    *)
  | guess_true of term * term list * (unit -> thm) option 

    (*if i does satisfy P then all other i' as well

      This can be used to proof
      !v. P v = !fv1 ... fvn. P i


      The theorem has to be of the form 
      (!fv1 ... fvn. P i) ==> !v. P v
    *)
  | guess_only_not_possible of term * term list * (unit -> thm) option 

    (*if i does not satisfy P then all other i' don't as well

      This can be used to proof
      ?v. P v = ?fv1 ... fvn. P i

      The theorem has to be of the form 
      (!fv1 ... fvn. ~(P i)) ==> !v. ~(P v)
    *)
  | guess_only_possible of term * term list * (unit -> thm) option

    (*all instantiations except i do not satisfy P 

      This can be used to proof
      ?v. P v = ?fv1 ... fvn. P i

      The theorem has to be of the form 
      !v. (!fv1 ... fvn. ~(v = i)) ==> ~P v
    *)
  | guess_others_not_possible of term * term list * (unit -> thm) option 

    (*all instantiations except i do not satisfy P 

      This can be used to proof
      !v. P v = !fv1 ... fvn. P i

      The theorem has to be of the form 
      !v. (!fv1 ... fvn. ~(v = i)) ==> P v
    *)
  | guess_others_satisfied of term * term list * (unit -> thm) option;


  val is_guess_general             : guess -> bool
  val is_guess_true                : bool -> guess -> bool
  val is_guess_false               : bool -> guess -> bool
  val is_guess_only_possible       : bool -> guess -> bool
  val is_guess_only_not_possible   : bool -> guess -> bool
  val is_guess_others_not_possible : bool -> guess -> bool
  val is_guess_others_satisfied    : bool -> guess -> bool

  val guess_set_thm_opt            : (unit -> thm) option -> guess -> guess
  val guess_remove_thm             : guess -> guess
  val make_guess_thm_term          : term -> term -> guess -> term option
  val make_guess_thm_opt           : term -> term -> guess -> conv -> (unit -> thm) option
  val make_set_guess_thm_opt       : term -> term -> guess -> conv -> guess

  (*Warning: this one is for debugging only. It uses mk_thm to
    create the thm added to the guess*)
  val make_guess_thm_opt___dummy : term -> term -> guess -> (unit -> thm) option
  val make_set_guess_thm_opt___dummy : term -> term -> guess -> guess


  val guess_extract : guess -> term * term list * (unit -> thm) option
  val guess_to_string : bool -> guess -> string


  (*guesses are organised in collections. They are used to
    store the different types of guesses separately. Moreover,
    rewrite theorems, that might come in handy, are there as well.*)
  type guess_collection = 
   {rewrites            : thm list,
    general             : guess list,
    true                : guess list,
    false               : guess list,
    only_possible       : guess list,
    only_not_possible   : guess list,
    others_not_possible : guess list,
    others_satisfied    : guess list}
    

  val empty_guess_collection   : guess_collection;
  val is_empty_guess_collection   : guess_collection -> bool;
  val guess_collection_append  : guess_collection -> guess_collection -> guess_collection;
  val guess_collection_flatten : guess_collection list -> guess_collection;
  val guess_list2collection    : thm list * guess list -> guess_collection;
  val guess_collection2list    : guess_collection -> thm list * guess list;
  val guess_collection___get_only_possible_weaken : guess_collection -> guess list;
  val guess_collection___get_only_not_possible_weaken : guess_collection -> guess list;

  val check_guess        : term -> term -> guess -> bool
  val correct_guess      : term -> term -> guess -> guess option
  val correct_guess_list : term -> term -> guess list -> guess list;
  val correct_guess_collection :
     term -> term -> guess_collection -> guess_collection


  val term_variant : term list -> term list -> term -> term * term list



  exception QUANT_INSTANTIATE_HEURISTIC___no_guess_exp;

(*Some types*)
  type quant_heuristic = term list -> term -> term -> guess_collection;
  type quant_heuristic_combine_argument = 
     (thm list * thm list * thm list * conv list * (quant_heuristic -> quant_heuristic) list);
  type quant_heuristic_cache;


  val mk_quant_heuristic_cache : unit -> quant_heuristic_cache;



(*Heuristics that might be useful to write own ones*)
  val QUANT_INSTANTIATE_HEURISTIC___REWRITE :
  quant_heuristic -> term list -> term -> thm -> guess_collection
  val QUANT_INSTANTIATE_HEURISTIC___CONV :
  conv -> quant_heuristic -> quant_heuristic;
  val QUANT_INSTANTIATE_HEURISTIC___EQUATION_distinct : thm list -> quant_heuristic -> quant_heuristic;
  val QUANT_INSTANTIATE_HEURISTIC___EQUATION_cases : thm -> quant_heuristic -> quant_heuristic;

  val QUANT_INSTANTIATE_HEURISTIC___max_rec_depth : int ref

  val QUANT_INSTANTIATE_HEURISTIC___COMBINE :    
    ((quant_heuristic -> quant_heuristic) list) -> quant_heuristic_cache ref option -> quant_heuristic;


  val COMBINE_HEURISTIC_FUNS : (unit -> guess_collection) list -> guess_collection;



(*The most important functions *)

  val PURE_QUANT_INSTANTIATE_CONV : conv;
  val QUANT_INSTANTIATE_CONV      : conv;

  val EXT_PURE_QUANT_INSTANTIATE_CONV : quant_heuristic_cache ref option ->
      bool -> bool -> quant_heuristic_combine_argument -> conv;
  val EXT_QUANT_INSTANTIATE_CONV : quant_heuristic_cache ref option ->
      bool -> bool -> quant_heuristic_combine_argument -> conv;

  val EXT_PURE_QUANT_INSTANTIATE_CONSEQ_CONV :  quant_heuristic_cache ref option ->
      bool -> quant_heuristic_combine_argument -> ConseqConv.directed_conseq_conv;
  val EXT_QUANT_INSTANTIATE_CONSEQ_CONV :  quant_heuristic_cache ref option ->
      bool -> quant_heuristic_combine_argument -> ConseqConv.directed_conseq_conv;

  val PURE_QUANT_INSTANTIATE_TAC      : tactic;
  val QUANT_INSTANTIATE_TAC           : tactic;
  val ASM_PURE_QUANT_INSTANTIATE_TAC  : tactic;
  val ASM_QUANT_INSTANTIATE_TAC       : tactic;



  val QUANT_TAC : (string * Parse.term Lib.frag list * Parse.term Parse.frag list list) list
   -> tactic;





(*functions to add stuff to QUANT_INSTANTIATE_CONV*)


  val quant_heuristic___get_combine_argument :
     unit -> quant_heuristic_combine_argument
  val quant_heuristic___clear_combine_argument : 
     unit -> unit
  val quant_heuristic___add_combine_argument :
     quant_heuristic_combine_argument -> unit;

  val quant_heuristic___add_distinct_thms : thm list -> unit;
  val quant_heuristic___add_cases_thms    : thm list -> unit;
  val quant_heuristic___add_rewrite_thms  : thm list -> unit;
  val quant_heuristic___add_rewrite_convs : conv list -> unit;
  val quant_heuristic___add_heuristic     : (quant_heuristic -> quant_heuristic) -> unit;

  val TypeBase___quant_heuristic_argument : hol_type list -> quant_heuristic_combine_argument

  val empty_quant_heuristic_combine_argument : quant_heuristic_combine_argument;

  val COMBINE___QUANT_HEURISTIC_COMBINE_ARGUMENT :
     quant_heuristic_combine_argument -> quant_heuristic_combine_argument ->
     quant_heuristic_combine_argument;

  val COMBINE___QUANT_HEURISTIC_COMBINE_ARGUMENTS :
     quant_heuristic_combine_argument list -> quant_heuristic_combine_argument;



(* Traces *)
(* "QUANT_INSTANTIATE_HEURISTIC" can be used to get debug information on
   how guesses are obtained *)



end
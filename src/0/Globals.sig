(* ===================================================================== *)
(* FILE          : Globals.sig                                           *)
(* DESCRIPTION   : Signature for global flags.                           *)
(*                                                                       *)
(* AUTHOR        : Ken Larsen, University of Cambridge                   *)
(*                 Based on globals.sig by                               *)
(*                 (c) Konrad Slind, University of Calgary               *)
(* DATE          : September 22, 1997                                    *)
(* ===================================================================== *)


signature Globals =
sig

  val HOLDIR                 : string
  val release                : string
  val version                : int

  val show_types             : bool ref
  val show_numeral_types     : bool ref
  val show_assums            : bool ref
  val show_tags              : bool ref
  val show_axioms            : bool ref
  val show_scrub             : bool ref
  val linewidth              : int ref
  val max_print_depth        : int ref
  val type_pp_prefix         : string ref
  val type_pp_suffix         : string ref
  val term_pp_prefix         : string ref
  val term_pp_suffix         : string ref
  val goal_line              : string ref
  val old                    : (string -> string) ref
  val pp_flags               : {show_types         : bool ref,
                                show_numeral_types : bool ref}

  val priming                : string option ref
  val guessing_tyvars        : bool ref
  val guessing_overloads     : bool ref
  val notify_on_tyvar_guess  : bool ref

end

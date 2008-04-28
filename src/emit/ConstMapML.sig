signature ConstMapML =
sig

  type constmap
  
  type hol_type = Type.hol_type
  type term     = Term.term

  val theConstMap  : unit -> constmap
  val prim_insert  : Term.term * (string * string * Type.hol_type) -> unit
  val insert       : Term.term -> unit
  val apply        : Term.term -> string * string * Type.hol_type

  val iconst       : string list * string * string -> term
end
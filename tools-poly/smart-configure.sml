(*quietdec := true;
app load ["Mosml", "Process", "Path", "FileSys", "Timer", "Real", "Int",
          "Bool", "OS"] ;
open Mosml;
*)
val _ = PolyML.Compiler.prompt1:="";
val _ = PolyML.Compiler.prompt2:="";
val _ = PolyML.print_depth 0;
val _ = use "poly/poly-init.ML";

(* utility functions *)
fun readdir s = let
  val ds = OS.FileSys.openDir s
  fun recurse acc =
      case OS.FileSys.readDir ds of
        NONE => acc
      | SOME s => recurse (s::acc)
in
  recurse [] before OS.FileSys.closeDir ds
end;

fun mem x [] = false
  | mem x (h::t) = x = h orelse mem x t

fun frontlast [] = raise Fail "frontlast: failure"
  | frontlast [h] = ([], h)
  | frontlast (h::t) = let val (f,l) = frontlast t in (h::f, l) end;

(* returns a function of type unit -> int, which returns time elapsed in
   seconds since the call to start_timer() *)
fun start_timer() = let
  val timer = Timer.startRealTimer()
in
  fn () => let
       val time_now = Timer.checkRealTimer timer
     in
       Real.floor (Time.toReal time_now)
     end handle Time.Time => 0
end

(* busy loop sleeping *)
fun delay limit action = let
  val timer = start_timer()
  fun loop last = let
    val elapsed = timer()
  in
    if elapsed = last then loop last
    else (action elapsed; if elapsed >= limit then () else loop elapsed)
  end
in
  action 0; loop 0
end;

fun determining s =
    (print (s^" "); delay 1 (fn _ => ()));

(* action starts here *)
print "\nHOL smart configuration.\n\n";

print "Determining configuration parameters: ";
determining "OS";

val currentdir = OS.FileSys.getDir()

val OS = let
  val {vol,...} = OS.Path.fromString currentdir
in
  if vol = "" then (* i.e. Unix *)
    case Mosml.run "uname" ["-a"] "" of
      Success s => if String.isPrefix "Linux" s then
                     "linux"
                   else if String.isPrefix "SunOS" s then
                     "solaris"
                   else if String.isPrefix "Darwin" s then
                     "macosx"
                   else
                     "unix"
    | Failure s => (print "\nRunning uname failed with message: ";
                    print s;
                    OS.Process.exit OS.Process.failure)
  else "winNT"
end;

(*
determining "mosmldir";

val mosmldir = let
  val libdir = hd (!Meta.loadPath)
  val {arcs, isAbs, vol} = OS.Path.fromString libdir
  val _ = isAbs orelse
          (print "\n\n*** ML library directory not specified with absolute";
           print "filename --- aborting\n";
           OS.Process.exit OS.Process.failure)
  val (arcs', lib) = frontlast arcs
  val _ =
      if lib <> "lib" then
        print "\nMosml library directory (from loadPath) not .../lib -- weird!\n"
      else ()
  val candidate =
      OS.Path.toString {arcs = arcs' @ ["bin"], isAbs = true, vol = vol}
in
  candidate
end;
*)


determining "holdir";

val holdir = let
  val cdir_files = readdir currentdir
in
  if mem "sigobj" cdir_files andalso mem "std.prelude" cdir_files then
    currentdir
  else if mem "smart-configure.sml" cdir_files andalso
          mem "configure.sml" cdir_files
  then let
      val {arcs, isAbs, vol} = OS.Path.fromString currentdir
      val (arcs', _) = frontlast arcs
    in
      OS.Path.toString {arcs = arcs', isAbs = isAbs, vol = vol}
    end
  else (print "\n\n*** Couldn't determine holdir; ";
        print "please run me from the root HOL directory\n";
        OS.Process.exit OS.Process.failure)
end;

determining "dynlib_available";

(*
val dynlib_available = (load "Dynlib"; true) handle _ => false;
*)

val dynlib_available = false;

print "\n";

val _ = let
  val override = OS.Path.concat(holdir, "config-override")
in
  if OS.FileSys.access (override, [OS.FileSys.A_READ]) then
    (print "\n[Using override file!]\n\n";
     use override)
  else ()
end;



fun verdict (prompt, value) =
    (print (StringCvt.padRight #" " 20 (prompt^":"));
     print value;
     print "\n");

verdict ("OS", OS);
(*verdict ("mosmldir", mosmldir);*)
verdict ("holdir", holdir);
verdict ("dynlib_available", Bool.toString dynlib_available);

(*
val _ = let
  val mosml' = if OS = "winNT" then "mosmlc.exe" else "mosmlc"
in
  if OS.FileSys.access (OS.Path.concat(mosmldir, mosml'), [OS.FileSys.A_EXEC]) then
    ()
  else (print ("\nCouldn't find executable mosmlc in "^mosmldir^"\n");
        print ("Giving up - please use config-override file to fix\n");
        OS.Process.exit OS.Process.failure)
end;
*)

print "\nConfiguration will begin with above values.  If they are wrong\n";
print "press Control-C.\n\n";

delay 3
      (fn n => print ("\rWill continue in "^Int.toString (3 - n)^" seconds."))
      handle Interrupt => (print "\n"; OS.Process.exit OS.Process.failure);

print "\n";

val configfile = OS.Path.concat (OS.Path.concat (holdir, "tools-poly"), "configure.sml");


use configfile;
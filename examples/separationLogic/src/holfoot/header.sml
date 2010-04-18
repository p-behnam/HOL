local 
   val holfoot_base_dir = Globals.HOLDIR ^ "/examples/separationLogic/src/holfoot/";
   val use_polyml = (Systeml.ML_SYSNAME = "poly") andalso
     (mem "holfoot.state" (Portable.listDir (holfoot_base_dir^"poly")) handle SysErr _ => false)
   val mldir = if use_polyml then "poly" else "mosml";
   val usefile = concat [holfoot_base_dir, mldir, "/header.sml"];
in
   val _ = use usefile;   
end;
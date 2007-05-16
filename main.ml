open Common open Commonop

(*****************************************************************************)
(* Flags *)
(*****************************************************************************)
(* can't put "standard.iso" for iso_file because the user may want to
 * launch spatch from any directory and so to be more consistent,
 * better to not put a default value here.
 *)
let cocci_file = ref ""
let iso_file   = ref "" 

let default_output_file = ref "/tmp/output.c"
let reentrant = ref false 
let save_output_file = ref false (* if true, stores output in file.cocci_res *)

let dir = ref false

(* test mode *)
let test_mode = ref false
let testall_mode = ref false

(* action mode *)
let action = ref "" 

(* works with -test but also in "normal" spatch mode *)
let compare_with_expected = ref false


let save_tmp_files = ref false

let timeout = ref (None : int option)

(* if set then will not do certain finalize so faster to go back in replay *)
let debugger = ref false

(*****************************************************************************)
(* Profiles *)
(*****************************************************************************)

(* pair of  (list of flags to set true, list of flags to set false *)
let quiet_profile = (
  [
    Flag.show_diff;
  ],
  [
    Flag.show_c;
    Flag.show_cocci;
    Flag.show_flow;
    Flag.show_before_fixed_flow;
    Flag.show_ctl_tex;
    Flag.show_ctl_text;
    Flag.show_transinfo;
    Flag.show_binding_in_out;
    Flag.show_misc;
    Flag_engine.show_misc;
    Flag_parsing_cocci.show_SP;
    Flag_ctl.verbose_ctl_engine;
    Flag_engine.debug_engine;
    Flag_parsing_c.verbose_parsing;
    Flag_parsing_c.verbose_type;
  ])

(*****************************************************************************)
(* The spatch options *)
(*****************************************************************************)

let usage_msg = 
  "Usage: " ^ basename Sys.argv.(0) ^ 
    " -sp_file <SP> <infile> -o <outfile> [-iso_file <iso>] [options]" ^ 
    "\n" ^ "Options are:"

(* forward reference trick *)
let short_usage_func = ref (fun () -> ())
let long_usage_func  = ref (fun () -> ())


(* The short_options are user-oriented. The other options are for
 * the developers of coccinelle or advanced-users that know
 * quite well the underlying semantics of coccinelle.
 *)
   
(* will be printed when use only ./spatch. For the rest you have to
 * use -longhelp to see them. 
 *)
let short_options = [ 
  "-sp_file",  Arg.Set_string cocci_file, " <file> the semantic patch file";
  "-iso_file", Arg.Set_string iso_file,   " <file> the iso file";

  "-o", Arg.Set_string default_output_file,
  "   <file> the output file (default=" ^ !default_output_file ^ ")";

  "-sgrep", Arg.Set Flag_parsing_cocci.sgrep_mode, 
  "    sgrep mode (sgrep for semantic grep)";
  "-partial_match",        Arg.Set Flag_ctl.partial_match, 
  "    report partial matches of the SP on the C file";

  "-dir", Arg.Set dir, 
  "    <dirname> process all files in directory recursively";

  "-version",   Arg.Unit (fun () -> 
    pr2 "version: $Date$";
    raise (Common.UnixExit 0)
    ), " ";
  "-longhelp", Arg.Unit (fun () -> 
    !long_usage_func();
    raise (Common.UnixExit 0)
    ), 
  "    see all the available options in different categories";
  "-shorthelp", Arg.Unit (fun () -> 
    !short_usage_func();
    raise (Common.UnixExit 0)
  ), 
  "    see short list of options";
    
]

(* the format is a list of triples:
 *  (title of section * (optional) explanation of sections * option list
 *)
let other_options = [
  "output file options",
  "",
  [ 
    "-save_output_file",  Arg.Set save_output_file, 
    "   save output in <cfile>.cocci_res";
    "-reentrant",         Arg.Set reentrant, 
    "   choose a default unique/safe output file in /tmp";
  ];


  "alias and obsolete options", 
  "",
  [ 
    "-cocci_file", Arg.Set_string cocci_file, 
    "   <file> the semantic patch file";
    "-c", Arg.Set_string cocci_file,     " short option of -cocci_file";
    "-i", Arg.Set_string iso_file,       " short option of -iso_file";
  ];

  "most useful show options", 
  "",
  [
    "-no_show_diff"           , Arg.Clear Flag.show_diff, " ";
    "-show_flow"              , Arg.Set Flag.show_flow,        " ";
    "-no_show_ctl_text"       , Arg.Clear Flag.show_ctl_text,  " ";
    (* works in conjunction with -show_ctl *)
    "-ctl_inline_let",        Arg.Set Flag.inline_let_ctl, " ";
    "-ctl_show_mcodekind",    Arg.Set Flag.show_mcodekind_in_ctl, " ";
    "-show_binding_in_out",     Arg.Set Flag.show_binding_in_out, " ";
    "-no_show_transinfo"      , Arg.Clear Flag.show_transinfo, " ";
    "-no_show_misc",   Arg.Unit (fun () -> 
      Flag.show_misc := false;
      Flag_engine.show_misc := false;
    ), " ";
  ];

  "verbose subsystems options",  
  "",
  [
    "-verbose_ctl_engine",   Arg.Set Flag_ctl.verbose_ctl_engine, " ";
    "-verbose_engine",       Arg.Set Flag_engine.debug_engine,    " ";
    "-no_parse_error_msg", Arg.Clear Flag_parsing_c.verbose_parsing, " ";
    "-no_type_error_msg",  Arg.Clear Flag_parsing_c.verbose_type, " ";
  ];

  "other show options",
  "",
  [
    "-show_c"                 , Arg.Set Flag.show_c,           " ";
    "-show_cocci"             , Arg.Set Flag.show_cocci,       " ";
    "-show_before_fixed_flow" , Arg.Set Flag.show_before_fixed_flow,  " ";
    "-show_ctl_tex"           , Arg.Set Flag.show_ctl_tex,     " ";
    "-show_SP_julia"       ,    Arg.Set Flag_parsing_cocci.show_SP,  " ";
  ];

  "debug C parsing",
  "",
  [
    "-debug_cpp",          Arg.Set  Flag_parsing_c.debug_cpp, " ";
    "-debug_lexer",        Arg.Set  Flag_parsing_c.debug_lexer , " ";
    "-debug_etdt",         Arg.Set  Flag_parsing_c.debug_etdt , "  ";
    "-debug_typedef",      Arg.Set  Flag_parsing_c.debug_typedef, "  ";

    "-debug_cfg",          Arg.Set  Flag_parsing_c.debug_cfg , "  ";
  ];

  "shortcut for enabling/disabling a set of debugging options at once",
  "",
  [
    (* todo: other profile ? *)
    "-quiet",   Arg.Unit (fun () -> 
      let (set_to_true, set_to_false) = quiet_profile in
      List.iter (fun x -> x := false) set_to_false;
      List.iter (fun x -> x := true) set_to_true;
    ), " ";
  ];

  "bench options",
  "",
  [
    "-profile",          Arg.Set  Common.profile , 
    "   gather timing information about the main coccinelle functions";
    "-bench", Arg.Int (function x -> Flag_ctl.bench := x), 
    "   <level> for profiling the CTL engine";
    "-timeout",              Arg.Int (fun x -> timeout := Some x), 
    "   <sec> timeout in seconds";
  ];



  "change of algorithm options",
  "", 
  [  
    "-popl", Arg.Set Flag.popl, 
    "    simplified SmPL, for the popl paper";

    "-loop",              Arg.Set Flag_ctl.loop_in_src_code,    " ";
    "-l1",                Arg.Clear Flag_parsing_c.label_strategy_2, " ";
    "-casse_initialisation", Arg.Set Flag_parsing_c.casse_initialisation," ";
    "-ifdef",              Arg.Set Flag_parsing_c.ifdef_to_if, 
    "   convert ifdef to if (buggy!)";
    "-add_typedef_root",   Arg.Set Flag_parsing_c.add_typedef_root, " ";
    "-nong",               Arg.Clear Flag_parsing_c.next_gen_parsing,
    "   don't use the next-gen parsing";
  ];

  "misc options",
  "",
  [
    "-save_tmp_files",   Arg.Set save_tmp_files,   " ";
    "-debugger",         Arg.Set debugger , 
    "   option to set if launch spatch in ocamldebug";
  ];



  "test mode and test options (works with tests/)",
  "The test options don't work with the -sp_file and so on.",
  [
    "-test",    Arg.Set test_mode, 
    "   <file> launch spatch on tests/file.[c,cocci]";
    "-testall", Arg.Set testall_mode, 
    "   launch spatch on all files in tests/ having a .res";
    "-compare_with_expected", Arg.Set compare_with_expected, 
    "   use also file.res"; 
  ];

  "action mode",
  ("The action options don't work with the -sp_file and so on." ^ "\n" ^
   "It's for the other (internal) uses of the spatch program." ^ "\n" ^
   "possibles actions are:
     tokens <file> 
     parse_c <file> 
     parse_cocci <file> 
     control_flow <file> or <file:function>
     parse_unparse <file>
     typeur <file> 
     compare_c <file1> <file2>" ^ "\n" ^
   "so to test the C parser, do -action parse_c foo.c"
  ),
  [ 
    "-action", Arg.Set_string action , 
    "   <action> [args]  (default_value = " ^ !action ^")"
  ];

]


let all_options = 
  short_options ++ List.concat (List.map Common.thd3 other_options)
 

(* I don't want the -help and --help that are appended by Arg.align *)
let arg_align2 xs =
  Arg.align xs +> List.rev +> Common.drop 2 +> List.rev
  

let short_usage () =
 begin
  Arg.usage (Arg.align short_options) usage_msg; 
  pr2 "";
  pr2 "Example of use:";
  pr2 "  ./spatch -sp_file foo.cocci foo.c -o /tmp/newfoo.c";
  pr2 "";
 end

let long_usage () = 
 begin
  pr2 usage_msg;
  pr2 "";
  (("main options", "", short_options)::other_options) +> List.iter 
    (fun (title, explanations, xs) -> 
      pr2 title;
      pr2_xxxxxxxxxxxxxxxxx();
      if explanations <> "" 
      then begin pr2 explanations; pr2 "" end;
      arg_align2 xs +> List.iter (fun (key,action,s) -> pr2 ("  " ^ key ^ s));
      pr2 "";
    );
 end
      

let _ = short_usage_func := short_usage
let _ = long_usage_func := long_usage


(*****************************************************************************)
(* The actions *)
(*****************************************************************************)

let actions_dispatch action xs = 
  match action, xs with
  | "tokens_c", [file] -> 
      if not (file =~ ".*\\.c") 
      then pr2 "warning: seems not a .c file";

      Flag_parsing_c.debug_lexer := true; 
      Flag_parsing_c.verbose_parsing := true;

      Parse_c.tokens file +> Common.pr2gen
        
  | "parse_c", x::xs -> 
      Flag_parsing_c.debug_cpp := true;
      Flag_parsing_c.debug_typedef := true;

      let fullxs = 
        if !dir
        then Common.cmd_to_list ("find " ^(join " " (x::xs)) ^" -name \"*.c\"")
        else x::xs 
      in
      
      let stat_list = ref [] in
      let newscore  = Common.empty_score () in

      fullxs +> List.iter (fun file -> 
        if not (file =~ ".*\\.c") 
        then pr2 "warning: seems not a .c file";

        pr2 ("PARSING: " ^ file);

        let (_x, stat) = Parse_c.parse_print_error_heuristic file in

        Common.push2 stat stat_list;
        let s = 
          sprintf "bad = %d, timeout = %B" 
            stat.Parse_c.bad stat.Parse_c.have_timeout
        in
        if stat.Parse_c.bad = 0 && not stat.Parse_c.have_timeout
        then Hashtbl.add newscore file (Common.Ok)
        else Hashtbl.add newscore file (Common.Pb s)
      );

      if not (null !stat_list) 
      then Parse_c.print_parsing_stat_list !stat_list;

      if !dir
      then begin 
        pr2 "--------------------------------";
        pr2 "regression testing  information";
        pr2 "--------------------------------";
        let file = Str.global_replace (Str.regexp "/") "__" x in
        Common.regression_testing newscore 
          ("/tmp/score_parsing__" ^ file ^ ".marshalled");
      end
        



  | "parse_cocci", [file] -> 
      if not (file =~ ".*\\.cocci") 
      then pr2 "warning: seems not a .cocci file";

      let iso_file = if !iso_file = "" then None else Some !iso_file in

      let (xs,_,_) = Parse_cocci.process file iso_file false in
      xs +> List.iter Pretty_print_cocci.unparse


  (* file can be   "foo.c"  or "foo.c:main" *)
  | "show_flow", [file] 
  | "control_flow", [file] -> 

      let (file, specific_func) = 
        if file =~ "\\(.*\\.c\\):\\(.*\\)"
        then let (a,b) = matched2 file in a, Some b
        else file, None
      in

      if not (file =~ ".*\\.c") 
      then pr2 "warning: seems not a .c file";

      let (program, _stat) = Parse_c.parse_print_error_heuristic file in

      program +> List.iter (fun (e,_) -> 
        match e with
        | Ast_c.Definition (((funcs, _, _, c),_) as def)  -> 
            pr2 funcs;
            let relevant_function = 
              match specific_func with
              | None -> true
              | Some s -> s = funcs
            in
                
            if relevant_function
            then 
              (* old: Flow_to_ast.test !Flag.show_flow def *)
              (try 
                  let flow = Ast_to_flow.ast_to_control_flow def in
                  Ast_to_flow.deadcode_detection flow;
                  let fixed = Ctlcocci_integration.fix_flow_ctl flow in
                  Ograph_extended.print_ograph_extended fixed
                    ("/tmp/" ^ funcs ^ ".dot")
                  
               with Ast_to_flow.Error (x) -> Ast_to_flow.report_error x
              )
        | _ -> ()
      )

  | "parse_unparse", [file] -> 
      if not (file =~ ".*\\.c") 
      then pr2 "warning: seems not a .c file";

      let (program2, _stat) = Parse_c.parse_print_error_heuristic file in
      let program2_with_ppmethod = 
        program2 +> List.map (fun x -> x, Unparse_c.PPnormal)
      in
      Unparse_c.pp_program program2_with_ppmethod !default_output_file;
      Common.command2 ("cat " ^ !default_output_file);


  | "typeur", [file] -> 
      if not (file =~ ".*\\.c") 
      then pr2 "warning: seems not a .c file";

      Flag_parsing_c.pretty_print_type_info := true;

      let (program2, _stat) =  Parse_c.parse_print_error_heuristic file in
      let program2 =
        program2 
        +> Common.unzip 
        +> (fun (program, infos) -> 
          Type_annoter_c.annotate_program Type_annoter_c.initial_env
            program +> List.map fst,
          infos
        )
        +> Common.uncurry Common.zip
      in
      let program2_with_ppmethod = 
        program2 +> List.map (fun x -> x, Unparse_c.PPnormal)
      in
      Unparse_c.pp_program program2_with_ppmethod !default_output_file;
      Common.command2 ("cat " ^ !default_output_file);

  (* used by generic_makefile now *)
  | "compare_c", [file1;file2] -> 
      let (correct, diffxs) = Compare_c.compare_default file1 file2 in
      let res = Compare_c.compare_result_to_bool correct in
      if res 
      then raise (Common.UnixExit 0)
      else raise (Common.UnixExit (-1))

  | "compare_c_hardcoded", _ -> 
      Compare_c.compare_default 
        "parsing_c/tests/compare1.c" 
        "parsing_c/tests/compare2.c" 
        (*
          "parsing_c/tests/equal_modulo1.c" 
          "parsing_c/tests/equal_modulo2.c" 
        *)
      +> Compare_c.compare_result_to_string 
      +> pr2


  | "regression_info_failed", [] -> 
      let newscore  = Common.empty_score () in
      let oks = 
        Common.cmd_to_list ("find -name \"*.ok\"") 
        ++
        Common.cmd_to_list ("find -name \"*.spatch_ok\"")
      in
      let failed = Common.cmd_to_list ("find -name \"*.failed\"") in

      if null (oks ++ failed) 
      then failwith "no ok/failed file, you certainly did a make clean"
      else begin
        oks +> List.iter (fun s -> 
          Hashtbl.add newscore (Filename.chop_extension s)  Common.Ok
        );
        failed +> List.iter (fun s -> 
          Hashtbl.add newscore (Filename.chop_extension s) (Common.Pb "fail")
        );
        pr2 "--------------------------------";
        pr2 "regression testing  information";
        pr2 "--------------------------------";
        Common.regression_testing newscore ("score_failed.marshalled")
      end


  | "xxx", _ -> 
      Format.print_newline();
      Format.printf "@[<v 5>--@,--@,@[<v 5>--@,--@,@]--@,--@,@]";
      Format.print_newline();
      Format.printf "@[<v>(---@[<v>(---@[<v>(---@,)@]@,)@]@,)@]";

  | _ -> failwith "no action for this or too few arguments for this action"

  
(*****************************************************************************)
(* The coccinelle main entry point *)
(*****************************************************************************)
let main () = 
  begin
    let args = ref [] in

    Arg.parse (Arg.align all_options) (fun x -> args := x::!args) usage_msg;
    args := List.rev !args;

    if !iso_file <> "" 
    then iso_file := Common.adjust_extension_if_needed !iso_file ".iso";
    if !cocci_file <> ""
    then cocci_file := Common.adjust_extension_if_needed !cocci_file ".cocci";

    let timeout_fn =
      match !timeout with
      | Some x -> Common.timeout_function x
      |	None -> (function f -> f()) 
    in
    timeout_fn                       (fun () -> 

    (* must be done after Arg.parse, because Common.profile is set by it *)
    Common.profile_code "Main total" (fun () -> 

    (match (!args) with

    (* --------------------------------------------------------- *)
    (* The test framework. Works with tests/  *)
    (* --------------------------------------------------------- *)
    | [x] when !test_mode    -> 
        let output_file =
          if !reentrant 
          then Common.new_temp_file "cocci-output" ".c" 
          else !default_output_file
        in
        Testing.testone x !compare_with_expected !iso_file output_file

    | []  when !testall_mode -> 
        Testing.testall !iso_file

    (* --------------------------------------------------------- *)
    (* Actions, useful to debug subpart of coccinelle *)
    (* --------------------------------------------------------- *)
    | xs when !action <> "" -> actions_dispatch !action xs

    (* --------------------------------------------------------- *)
    (* This is the main entry *)
    (* --------------------------------------------------------- *)
    | x::xs -> 

        if (!cocci_file = "") 
        then failwith "I need a cocci file,  use -sp_file <file>";


        (* todo?: for iso could try to go back the parent dir recursively to
         * find the standard.iso 
         *)
        let cocci_file = !cocci_file in
        let iso_file = if !iso_file = "" then None else Some !iso_file in

        let fullxs = 
          if !dir 
          then Common.cmd_to_list ("find "^(join " " (x::xs))^" -name \"*.c\"")
          else x::xs 
        in

        fullxs +> List.iter (fun cfile -> 
          pr2 ("HANDLING: " ^ cfile);

          let cfile = Common.adjust_extension_if_needed cfile ".c" in

          let base = if cfile =~ "\\(.*\\).c$" then matched1 cfile else cfile
          in 
          let generated_file = 
            if !reentrant 
            then Common.new_temp_file "cocci-output" ".c" 
            else !default_output_file
          in
          
          let expected_res = base ^ ".res" in
          let saved = cfile ^ ".cocci_res" in

          (try Cocci.full_engine cfile (cocci_file, iso_file) generated_file
           with e -> 
              if !dir 
              then pr2 ("EXN:" ^ Printexc.to_string e)
              else raise e
          );
          
	  Ctlcocci_integration.print_bench();

	  if !save_output_file 
          then Common.command2 ("cp " ^ generated_file ^ " " ^ saved);

          if !compare_with_expected 
          then 
            let (correct, diffxs) = 
              Compare_c.compare_default generated_file expected_res 
            in
            pr2 (Compare_c.compare_result_to_string (correct, diffxs));
            if (List.length fullxs = 1)
            then 
              let res = Compare_c.compare_result_to_bool correct in
              if res 
              then raise (Common.UnixExit 0)
              else raise (Common.UnixExit (-1))

        ) (* iter *)

    (* --------------------------------------------------------- *)
    (* empty entry *)
    (* --------------------------------------------------------- *)
    | [] -> short_usage()
        
   )
  ));
  end

(*****************************************************************************)
let _ =
  if not (!Sys.interactive) then 
    Common.exn_to_real_unixexit (fun () -> 

      Sys.set_signal Sys.sigint (Sys.Signal_handle   (fun _ -> 
        pr2 "C-c intercepted, will do some cleaning before exiting";
        raise (Common.UnixExit (-1))
      ));

      (* The finalize below makes it tedious to go back to exn when use
       * 'back' in the debugger. Hence this special case. *)
      if Sys.argv +> Array.to_list +> List.exists (fun x -> x ="-debugger")
      then main ()
      else 

        Common.finalize          (fun ()-> 
         Common.pp_do_in_zero_box (fun () -> 
           main ();
           Ctlcocci_integration.print_bench();
           Common.profile_diagnostic ();
         ))
        (fun()-> if not !save_tmp_files then Common.erase_temp_files ())
    )
      

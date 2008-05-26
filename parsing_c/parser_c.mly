%{
open Common

open Ast_c

module LP = Lexer_parser
open Lexer_parser (* for the fields *)

open Semantic_c (* Semantic exn *)


(*****************************************************************************)
(* Wrappers *)
(*****************************************************************************)
let warning s v = 
  if !Flag_parsing_c.verbose_parsing 
  then Common.warning ("PARSING: " ^ s) v
  else v


let pr2 s = 
  if !Flag_parsing_c.verbose_parsing 
  then Common.pr2 s

(*****************************************************************************)
(* Parse helpers functions *)
(*****************************************************************************)

(*-------------------------------------------------------------------------- *)
(* Type related *)
(*-------------------------------------------------------------------------- *)

type shortLong      = Short  | Long | LongLong

type decl = { 
  storageD: storagebis wrap;
  typeD: ((sign option) * (shortLong option) * (typeCbis option)) wrap;
  qualifD: typeQualifierbis wrap;
  inlineD: bool             wrap;
  (* note: have a full_info: parse_info list; to remember ordering
   * between storage, qualifier, type ? well this info is already in
   * the Ast_c.info, just have to sort them to get good order *)
} 

let nullDecl = {
  storageD = NoSto, [];
  typeD = (None, None, None), [];
  qualifD = nullQualif;
  inlineD = false, [];
}
let fake_pi = Common.fake_parse_info

let addStorageD  = function 
  | ((x,ii), ({storageD = (NoSto,[])} as v)) -> { v with storageD = (x, [ii]) }
  | ((x,ii), ({storageD = (y, ii2)} as v)) ->  
      if x = y then warning "duplicate storage classes" v
      else raise (Semantic ("multiple storage classes", fake_pi))

let addInlineD  = function 
  | ((true,ii), ({inlineD = (false,[])} as v)) -> { v with inlineD=(true,[ii])}
  | ((true,ii), ({inlineD = (true, ii2)} as v)) -> warning "duplicate inline" v
  | _ -> raise Impossible


let addTypeD     = function 
  | ((Left3 Signed,ii)   ,({typeD = ((Some Signed,  b,c),ii2)} as v)) -> 
      warning "duplicate 'signed'"   v
  | ((Left3 UnSigned,ii) ,({typeD = ((Some UnSigned,b,c),ii2)} as v)) -> 
      warning "duplicate 'unsigned'" v
  | ((Left3 _,ii),        ({typeD = ((Some _,b,c),ii2)} as _v)) -> 
      raise (Semantic ("both signed and unsigned specified", fake_pi))
  | ((Left3 x,ii),        ({typeD = ((None,b,c),ii2)} as v))   -> 
      {v with typeD = (Some x,b,c),ii ++ ii2}

  | ((Middle3 Short,ii),  ({typeD = ((a,Some Short,c),ii2)} as v)) -> 
      warning "duplicate 'short'" v

      
  (* gccext: long long allowed *)
  | ((Middle3 Long,ii),   ({typeD = ((a,Some Long ,c),ii2)} as v)) -> 
      { v with typeD = (a, Some LongLong, c),ii++ii2 }
  | ((Middle3 Long,ii),   ({typeD = ((a,Some LongLong ,c),ii2)} as v)) -> 
      warning "triplicate 'long'" v

  | ((Middle3 _,ii),      ({typeD = ((a,Some _,c),ii2)} as _v)) -> 
      raise (Semantic ("both long and short specified", fake_pi))
  | ((Middle3 x,ii),      ({typeD = ((a,None,c),ii2)} as v))  -> 
      {v with typeD = (a, Some x,c),ii++ii2}

  | ((Right3 t,ii),       ({typeD = ((a,b,Some _),ii2)} as _v)) -> 
      raise (Semantic ("two or more data types", fake_pi))
  | ((Right3 t,ii),       ({typeD = ((a,b,None),ii2)} as v))   -> 
      {v with typeD = (a,b, Some t),ii++ii2}


let addQualif = function
  | ({const=true},   ({const=true} as x)) ->   warning "duplicate 'const'" x
  | ({volatile=true},({volatile=true} as x))-> warning "duplicate 'volatile'" x
  | ({const=true},    v) -> {v with const=true}
  | ({volatile=true}, v) -> {v with volatile=true}
  | _ -> internal_error "there is no noconst or novolatile keyword"

let addQualifD ((qu,ii), ({qualifD = (v,ii2)} as x)) =
  { x with qualifD = (addQualif (qu, v),ii::ii2) }


(*-------------------------------------------------------------------------- *)
(* Declaration/Function related *)
(*-------------------------------------------------------------------------- *)


(* stdC: type section, basic integer types (and ritchie)
 * To understand the code, just look at the result (right part of the PM) 
 * and go back.
 *)
let (fixDeclSpecForDecl: decl -> (fullType * (storage wrap)))  = function
 {storageD = (st,iist); 
  qualifD = (qu,iiq); 
  typeD = (ty,iit); 
  inlineD = (inline,iinl);
  } -> 
  (
   ((qu, iiq),
   (match ty with 
 | (None,None,None)       -> warning "type defaults to 'int'" (defaultInt, [])
 | (None, None, Some t)   -> (t, iit)
	 
 | (Some sign,   None, (None| Some (BaseType (IntType (Si (_,CInt))))))  -> 
     BaseType(IntType (Si (sign, CInt))), iit
 | ((None|Some Signed),Some x,(None|Some(BaseType(IntType (Si (_,CInt)))))) -> 
     BaseType(IntType (Si (Signed, [Short,CShort; Long, CLong; LongLong, CLongLong] +> List.assoc x))), iit
 | (Some UnSigned, Some x, (None| Some (BaseType (IntType (Si (_,CInt))))))-> 
     BaseType(IntType (Si (UnSigned, [Short,CShort; Long, CLong; LongLong, CLongLong] +> List.assoc x))), iit
 | (Some sign,   None, (Some (BaseType (IntType CChar))))   -> BaseType(IntType (Si (sign, CChar2))), iit
 | (None, Some Long,(Some(BaseType(FloatType CDouble))))    -> BaseType (FloatType (CLongDouble)), iit

 | (Some _,_, Some _) ->  
     (*mine*)
     raise (Semantic ("signed, unsigned valid only for char and int", fake_pi))
 | (_,Some _,(Some(BaseType(FloatType (CFloat|CLongDouble))))) -> 
     raise (Semantic ("long or short specified with floatint type", fake_pi))
 | (_,Some Short,(Some(BaseType(FloatType CDouble)))) ->
     raise (Semantic ("the only valid combination is long double", fake_pi))
       
 | (_, Some _, Some _) -> 
     (* mine *)
     raise (Semantic ("long, short valid only for int or float", fake_pi)) 

     (* if do short uint i, then gcc say parse error, strange ? it is
      * not a parse error, it is just that we dont allow with typedef
      * either short/long or signed/unsigned. In fact, with
      * parse_typedef_fix2 (with et() and dt()) now I say too parse
      * error so this code is executed only when do short struct
      * {....} and never with a typedef cos now we parse short uint i
      * as short ident ident => parse error (cos after first short i
      * pass in dt() mode) *)
   ))
     ,((st, inline),iist++iinl)
  )

let fixDeclSpecForParam = function ({storageD = (st,iist)} as r) -> 
  let ((qu,ty) as v,_st) = fixDeclSpecForDecl r in
  match st with
  | (Sto Register) -> (v, true), iist
  | NoSto -> (v, false), iist
  | _ -> 
      raise 
        (Semantic ("storage class specified for parameter of function", 
                  fake_pi))

let fixDeclSpecForFuncDef x =
  let (returnType,storage) = fixDeclSpecForDecl x in
  (match fst (unwrap storage) with
  | StoTypedef -> 
      raise (Semantic ("function definition declared 'typedef'", fake_pi))
  | x -> (returnType, storage)
  )

(* parameter: (this is the context where we give parameter only when
 * in func DEFINITION not in funct DECLARATION) We must have a name.
 * This function ensure that we give only parameterTypeDecl with well
 * formed Classic constructor todo?: do we accept other declaration
 * in ? so I must add them to the compound of the deffunc. I dont
 * have to handle typedef pb here cos C forbid to do VF f { ... }
 * with VF a typedef of func cos here we dont see the name of the
 * argument (in the typedef)
 *)
let (fixOldCDecl: fullType -> fullType) = fun ty ->
  match snd ty with
  | ((FunctionType (fullt, (params, (b, iib)))),iifunc) -> 

      (* stdC: If the prototype declaration declares a parameter for a
       * function that you are defining (it is part of a function
       * definition), then you must write a name within the declarator.
       * Otherwise, you can omit the name. *)
      (match params with
      | [((reg, None, ((_qua, (BaseType Void,_)))),_), _] ->  
          ty
      | params -> 
          (params +> List.iter (function 
          | (((b, None, _),  ii1),ii2) -> 
              (* if majuscule, then certainly macro-parameter *)
              pr2 ("SEMANTIC:parameter name omitted, but I continue"); 
	  | _ -> ()
          );
           ty)
      )
        (* todo? can we declare prototype in the decl or structdef,
           ... => length <> but good kan meme *)
  | _ -> 
      (* gcc say parse error but dont see why *)
      raise (Semantic ("seems this is not a function", fake_pi)) 


let fixFunc = function
  | ((
      (s,iis), 
      (nQ, (FunctionType (fullt, (params,bool)),iifunc)), 
      (st,iist)
    ), 
    (cp,iicp)) -> 
      let iistart = Ast_c.fakeInfo () in
      assert (nQ =*= nullQualif);
      (match params with
      | [((reg, None, ((_qua, (BaseType Void,_)))),_), _] ->  ()
      | params -> 
          params +> List.iter (function 
          | (((bool, Some s, fullt), _), _) -> ()
	  | _ -> ()
                (* failwith "internal errror: fixOldCDecl not good" *)
          ));
      (* it must be nullQualif,cos parser construct only this*)
      (s, (fullt, (params, bool)), st, cp), 
      ([iis]++iifunc++iicp++[iistart]++iist) 
  | _ -> 
      raise 
        (Semantic 
            ("you are trying to do a function definition but you dont give " ^
             "any parameter", fake_pi))


(*-------------------------------------------------------------------------- *)
(* parse_typedef_fix2 *)
(*-------------------------------------------------------------------------- *)

let dt s () = 
  if !Flag_parsing_c.debug_etdt then pr2 ("<" ^ s); 
  LP.disable_typedef ()

let et s () = 
  if !Flag_parsing_c.debug_etdt then pr2 (">" ^ s);  
  LP.enable_typedef ()


let fix_add_params_ident = function
  | ((s, (nQ, (FunctionType (fullt, (params, bool)),_)), st)) ->  

      (match params with
      | [((reg, None, ((_qua, (BaseType Void,_)))),_), _] ->  ()
      | params -> 
        params +> List.iter (function 
         | (((bool, Some s, fullt), _), _) -> 
            LP.add_ident s
	 | _ -> 
             ()
             (* failwith "internal errror: fixOldCDecl not good" *)
      )) 
  | _ -> ()

(*-------------------------------------------------------------------------- *)
(* shortcuts *)
(*-------------------------------------------------------------------------- *)

let mk_e e ii = ((e, Ast_c.noType()), ii)
    
%}

/*****************************************************************************/

/* Some tokens are not even used in this file because they are filtered
 * in some intermediate phase. But they still must be declared because
 * ocamllex may generate them, or some intermediate phase may also
 * generate them (like some functions in parsing_hacks.ml)
 */

%token <Ast_c.info> TUnknown /* unrecognized token */

%token <Ast_c.info> TComment TCommentSpace TCommentNewline

/* cppext: extra tokens */

%token <Ast_c.info> TDefine
%token <(string * Ast_c.info)> TDefParamVariadic
%token <Ast_c.info> TCppEscapedNewline /* disappear after fix_tokens_define */
%token <Ast_c.info> TOParDefine        /* appear    after fix_tokens_define */
%token <(string * Ast_c.info)> TIdentDefine /* same */
%token <Ast_c.info>            TDefEOL      /* same */

/* used only in lexer_c, then transformed in comment or splitted in tokens */
%token <(string * string * bool ref * Ast_c.info)> TInclude
/* tokens coming from above, generated in parse_c from TInclude, etc */
%token <(Ast_c.info * bool ref)>          TIncludeStart
%token <(string * Ast_c.info)> TIncludeFilename



%token <Ast_c.info> TIfdef TIfdefelse TIfdefelif TEndif
%token <(bool * Ast_c.info)> TIfdefBool TIfdefMisc TIfdefVersion


%token <Ast_c.info> TCommentMisc
%token <(Ast_c.cppcommentkind * Ast_c.info)> TCommentCpp

/* appear  after fix_tokens_cpp */
%token <Ast_c.info>            TMacroStmt
%token <Ast_c.info>            TMacroString /* no need value for the moment */
%token <(string * Ast_c.info)> TMacroDecl
%token <Ast_c.info>            TMacroDeclConst 
%token <(string * Ast_c.info)> TMacroIterator
/* %token <(string * Ast_c.info)> TMacroTop */
%token <Ast_c.info> TCParEOL   /* appear after parsing_hack */

%token <Ast_c.info> TAction


/* the normal tokens */


%token <string * Ast_c.info>                     TInt
%token <(string * Ast_c.floatType) * Ast_c.info> TFloat
%token <(string * Ast_c.isWchar) * Ast_c.info>   TChar
%token <(string * Ast_c.isWchar) * Ast_c.info>   TString

%token <string * Ast_c.info> TIdent TypedefIdent



%token <Ast_c.info> TOPar TCPar TOBrace TCBrace TOCro TCCro 
%token <Ast_c.info> TDot TComma TPtrOp 
%token <Ast_c.info> TInc TDec
%token <Ast_c.assignOp * Ast_c.info> TAssign 
%token <Ast_c.info> TEq
%token <Ast_c.info> TWhy  TTilde TBang
%token <Ast_c.info> TEllipsis
%token <Ast_c.info> TDotDot

%token <Ast_c.info> TPtVirg
%token <Ast_c.info> 
       TOrLog TAndLog TOr TXor TAnd  TEqEq TNotEq TInf TSup TInfEq TSupEq
       TShl TShr 
       TPlus TMinus TMul TDiv TMod 

%token <Ast_c.info>
       Tchar Tshort Tint Tdouble Tfloat Tlong Tunsigned Tsigned Tvoid
       Tauto Tregister Textern Tstatic 
       Ttypedef 
       Tconst Tvolatile
       Tstruct Tunion Tenum 
       Tbreak Telse Tswitch Tcase Tcontinue Tfor Tdo Tif  Twhile Treturn
       Tgoto Tdefault
       Tsizeof  

/* gccext: extra tokens */
%token <Ast_c.info> Tasm
%token <Ast_c.info> Tattribute
%token <Ast_c.info> Tinline
%token <Ast_c.info> Ttypeof


%token <Ast_c.info> EOF


%left TOrLog
%left TAndLog
%left TOr
%left TXor
%left TAnd 
%left TEqEq TNotEq
%left TInf TSup TInfEq TSupEq 
%left TShl TShr
%left TPlus TMinus
%left TMul TDiv TMod 

%start main celem statement expr type_name
%type <Ast_c.program> main
%type <Ast_c.toplevel> celem

%type <Ast_c.statement> statement
%type <Ast_c.expression> expr
%type <Ast_c.fullType> type_name

%%
/*****************************************************************************/
/* TOC:
expression
statement
declaration, types, initializers, struct, enum
xxx_list, xxx_opt
cpp directives
celem (=~ main)
*/
/*****************************************************************************/

/* no more used now that use error recovery */
main:  translation_unit EOF     { $1 }

translation_unit: 
 | external_declaration                  
     { !LP._lexer_hint.toplevel <- true;   [$1] }
 | translation_unit external_declaration
     { !LP._lexer_hint.toplevel <- true; $1 ++ [$2] }



/*****************************************************************************/
/* expr */
/*****************************************************************************/

expr: 
 | assign_expr             { $1 }
 | expr TComma assign_expr { mk_e (Sequence ($1,$3)) [$2] }

/* bugfix: in C grammar they put unary_expr, but in fact it must be 
 * cast_expr, otherwise (int *) xxx = &yy; is not allowed
 */
assign_expr: 
 | cond_expr                     { $1 }
 | cast_expr TAssign assign_expr { mk_e(Assignment ($1,fst $2,$3)) [snd $2]}
 | cast_expr TEq     assign_expr { mk_e(Assignment ($1,SimpleAssign,$3)) [$2]}

/* gccext: allow optional then part hence gcc_opt_expr 
 * buyfix: in C grammar they put TDotDot cond_expr, but in fact it must be
 * assign_expr, otherwise   pnp ? x : x = 0x388  is not allowed
 */
cond_expr: 
 | arith_expr                                     
     { $1 }
 | arith_expr TWhy gcc_opt_expr TDotDot assign_expr 
     { mk_e (CondExpr ($1,$3,$5)) [$2;$4] } 


arith_expr: 
 | cast_expr                     { $1 }
 | arith_expr TMul    arith_expr { mk_e(Binary ($1, Arith Mul,      $3)) [$2] }
 | arith_expr TDiv    arith_expr { mk_e(Binary ($1, Arith Div,      $3)) [$2] }
 | arith_expr TMod    arith_expr { mk_e(Binary ($1, Arith Mod,      $3)) [$2] }
 | arith_expr TPlus   arith_expr { mk_e(Binary ($1, Arith Plus,     $3)) [$2] }
 | arith_expr TMinus  arith_expr { mk_e(Binary ($1, Arith Minus,    $3)) [$2] }
 | arith_expr TShl    arith_expr { mk_e(Binary ($1, Arith DecLeft,  $3)) [$2] }
 | arith_expr TShr    arith_expr { mk_e(Binary ($1, Arith DecRight, $3)) [$2] }
 | arith_expr TInf    arith_expr { mk_e(Binary ($1, Logical Inf,    $3)) [$2] }
 | arith_expr TSup    arith_expr { mk_e(Binary ($1, Logical Sup,    $3)) [$2] }
 | arith_expr TInfEq  arith_expr { mk_e(Binary ($1, Logical InfEq,  $3)) [$2] }
 | arith_expr TSupEq  arith_expr { mk_e(Binary ($1, Logical SupEq,  $3)) [$2] }
 | arith_expr TEqEq   arith_expr { mk_e(Binary ($1, Logical Eq,     $3)) [$2] }
 | arith_expr TNotEq  arith_expr { mk_e(Binary ($1, Logical NotEq,  $3)) [$2] }
 | arith_expr TAnd    arith_expr { mk_e(Binary ($1, Arith And,      $3)) [$2] }
 | arith_expr TOr     arith_expr { mk_e(Binary ($1, Arith Or,       $3)) [$2] }
 | arith_expr TXor    arith_expr { mk_e(Binary ($1, Arith Xor,      $3)) [$2] }
 | arith_expr TAndLog arith_expr { mk_e(Binary ($1, Logical AndLog, $3)) [$2] }
 | arith_expr TOrLog  arith_expr { mk_e(Binary ($1, Logical OrLog,  $3)) [$2] }

cast_expr: 
 | unary_expr                        { $1 }
 | topar2 type_name tcpar2 cast_expr { mk_e(Cast ($2, $4)) [$1;$3] }

unary_expr: 
 | postfix_expr                    { $1 }
 | TInc unary_expr                 { mk_e(Infix ($2, Inc))    [$1] }
 | TDec unary_expr                 { mk_e(Infix ($2, Dec))    [$1] }
 | unary_op cast_expr              { mk_e(Unary ($2, fst $1)) [snd $1] }
 | Tsizeof unary_expr              { mk_e(SizeOfExpr ($2))    [$1] }
 | Tsizeof topar2 type_name tcpar2 { mk_e(SizeOfType ($3))    [$1;$2;$4] }

unary_op: 
 | TAnd   { GetRef,     $1 }
 | TMul   { DeRef,      $1 }
 | TPlus  { UnPlus,     $1 }
 | TMinus { UnMinus,    $1 }
 | TTilde { Tilde,      $1 }
 | TBang  { Not,        $1 }
 /* gccext: have that a lot in old kernel to get address of local label.
  * cf gcc manual "local labels as values".
  */
 | TAndLog { GetRefLabel, $1 }



postfix_expr: 
 | primary_expr               { $1 }
 | postfix_expr TOCro expr TCCro                
     { mk_e(ArrayAccess ($1, $3)) [$2;$4] }
 | postfix_expr TOPar argument_list TCPar  
     { mk_e(FunCall ($1, $3)) [$2;$4] }
 | postfix_expr TOPar  TCPar  { mk_e(FunCall ($1, [])) [$2;$3] }
 | postfix_expr TDot   ident  { mk_e(RecordAccess   ($1,fst $3)) [$2;snd $3] }
 | postfix_expr TPtrOp ident  { mk_e(RecordPtAccess ($1,fst $3)) [$2;snd $3] }
 | postfix_expr TInc          { mk_e(Postfix ($1, Inc)) [$2] }
 | postfix_expr TDec          { mk_e(Postfix ($1, Dec)) [$2] }

 /* gccext: also called compound literals */
 | topar2 type_name tcpar2 TOBrace TCBrace 
     { mk_e(Constructor ($2, [])) [$1;$3;$4;$5] }
 | topar2 type_name tcpar2 TOBrace initialize_list gcc_comma_opt TCBrace
     { mk_e(Constructor ($2, List.rev $5)) ([$1;$3;$4;$7] ++ $6) }

primary_expr: 
 | TIdent  { mk_e(Ident  (fst $1)) [snd $1] }
 | TInt    { mk_e(Constant (Int    (fst $1))) [snd $1] }
 | TFloat  { mk_e(Constant (Float  (fst $1))) [snd $1] }
 | TString { mk_e(Constant (String (fst $1))) [snd $1] }
 | TChar   { mk_e(Constant (Char   (fst $1))) [snd $1] }
 | TOPar expr TCPar { mk_e(ParenExpr ($2)) [$1;$3] }  /* forunparser: */

 /* gccext: cppext: */
 | string_elem string_list { mk_e(Constant (MultiString)) ($1 ++ $2) }

 /* gccext: allow statement as expressions via ({ statement }) */
 | TOPar compound TCPar  { mk_e(StatementExpr ($2)) [$1;$3] } 




/* cppext: */
argument: 
 | assign_expr { Left $1 }
 | parameter_decl { Right (ArgType $1)  }
 | action_higherordermacro { Right (ArgAction $1) }

action_higherordermacro: 
 | taction_list 
     { if null $1
       then ActMisc [Ast_c.fakeInfo()]
       else ActMisc $1
     }


/*----------------------------*/
/* workarounds */
/*----------------------------*/

/* Why this ? why not s/ident/TIdent ?  cos there is multiple namespace in C, 
 * so a label can have the same name that a typedef, same for field and tags
 * hence sometimes the use of ident  insteat of TIdent.
 */
ident: 
 | TIdent       { $1 }
 | TypedefIdent { $1 }

/* would like evalInt $1 but require too much info */
const_expr: cond_expr { $1  }


topar2: TOPar { et "topar2" (); $1  }
tcpar2: TCPar { et "tcpar2" (); $1 (*TODO? et ? sure ? c pas dt plutot ? *) } 



/*****************************************************************************/
/* statement */
/*****************************************************************************/

statement: 
 | labeled         { Labeled      (fst $1), snd $1 }
 | compound        { Compound     (fst $1), snd $1 }
 | expr_statement  { ExprStatement(fst $1), snd $1 }
 | selection       { Selection    (fst $1), snd $1 ++ [fakeInfo()] }
 | iteration       { Iteration    (fst $1), snd $1 ++ [fakeInfo()] }
 | jump TPtVirg    { Jump         (fst $1), snd $1 ++ [$2] }

 /* gccext: */
 | Tasm TOPar asmbody TCPar TPtVirg             { Asm $3, [$1;$2;$4;$5] }
 | Tasm Tvolatile TOPar asmbody TCPar TPtVirg   { Asm $4, [$1;$2;$3;$5;$6] }

 /* cppext: */
 | TMacroStmt { MacroStmt, [$1] }
 | TMacroStmt TPtVirg { MacroStmt, [$1;$2] }




/* note that case 1: case 2: i++;    would be correctly parsed, but with 
 * a Case  (1, (Case (2, i++)))  :(  
 */
labeled: 
 | ident            TDotDot statement   { Label (fst $1, $3),  [snd $1; $2] }
 | Tcase const_expr TDotDot statement   { Case ($2, $4),       [$1; $3] }
 | Tcase const_expr TEllipsis const_expr TDotDot statement 
     { CaseRange ($2, $4, $6), [$1;$3;$5] } /* gccext: allow range */
 | Tdefault         TDotDot statement   { Default $3,             [$1; $2] } 

 /* gccext:  allow toto: }
  * generate each 30 shift/Reduce conflicts,  mais ca va, ca fait ce qu'il
  * faut
  */
 | ident            TDotDot 
     { Label (fst $1, (ExprStatement None, [])), [snd $1; $2] }
 | Tcase const_expr TDotDot { Case ($2, (ExprStatement None, [])), [$1;$3] }   
 | Tdefault         TDotDot { Default (ExprStatement None, []),    [$1; $2] }  





compound: tobrace compound2 tcbrace { $2, [$1; $3]  }

tobrace: TOBrace                     {  LP.new_scope (); $1 }
tcbrace: TCBrace                     {  LP.del_scope (); $1 }

/* old:
compound2: 
 |                            { ([],[]) }
 |  statement_list            { ([], $1) }
 |  decl_list                 { ($1, []) }
 |  decl_list statement_list  { ($1,$2) }

statement_list: stat_or_decl_list { $1 }
*/


/* cppext: because of cpp, some stuff look like declaration but are in
 * fact statement but too hard to figure out, and if parse them as
 * expression, then we force to have first decls and then exprs, then
 * will have a parse error. So easier to let mix decl/statement.
 * Morover it helps to not make such a difference between decl and
 * statement for further coccinelle phases to factorize code.
*/
compound2:  
 |                   { ([]) }
 | stat_or_decl_list { $1 }

stat_or_decl: 
 | decl      { Decl $1, [] }
 | statement { $1 }
  /* cppext: */
 | TIfdef stat_or_decl_list TIfdefelse stat_or_decl_list TEndif 
     { Selection (Ifdef ($2, $4)), [$1;$3;$5;fakeInfo()] }
 | TIfdef stat_or_decl_list TEndif 
     { Selection (Ifdef ($2, [])), [$1;$3;fakeInfo()] }
  /* gccext: */
 | function_definition { NestedFunc $1, [] }






expr_statement: 
 | TPtVirg      { None,    [$1] }
 | expr TPtVirg { Some $1, [$2] }

selection: 
 | Tif TOPar expr TCPar statement                 
     { If ($3, $5, (ExprStatement None, [])),   [$1;$2;$4] }
 | Tif TOPar expr TCPar statement Telse statement 
     { If ($3, $5, $7),  [$1;$2;$4;$6] }
 | Tswitch TOPar expr TCPar statement             
     { Switch ($3,$5),   [$1;$2;$4]  }

iteration: 
 | Twhile TOPar expr TCPar statement                             
     { While ($3,$5),                [$1;$2;$4] }
 | Tdo statement Twhile TOPar expr TCPar TPtVirg                 
     { DoWhile ($2,$5),              [$1;$3;$4;$6;$7] }
 | Tfor TOPar expr_statement expr_statement TCPar statement
     { For ($3,$4,(None, []),$6),    [$1;$2;$5]}
 | Tfor TOPar expr_statement expr_statement expr TCPar statement
     { For ($3,$4,(Some $5, []),$7), [$1;$2;$6] }
 /* cppext: */
 | TMacroIterator TOPar argument_list TCPar statement
     { MacroIteration (fst $1, $3, $5), [snd $1;$2;$4] }
 | TMacroIterator TOPar TCPar statement
     { MacroIteration (fst $1, [], $4), [snd $1;$2;$3] }

/* the ';' in the caller grammar rule will be appended to the infos */
jump: 
 | Tgoto ident  { Goto (fst $2),  [$1;snd $2] } 
 | Tcontinue    { Continue,       [$1] }
 | Tbreak       { Break,          [$1] }
 | Treturn      { Return,         [$1] } 
 | Treturn expr { ReturnExpr $2,  [$1] }
 | Tgoto TMul expr { GotoComputed $3, [$1;$2] }



/*----------------------------*/
/* gccext: */
/*----------------------------*/
string_elem:
 | TString { [snd $1] }
 /* cppext:  ex= printk (KERN_INFO "xxx" UTS_RELEASE)  */
 | TMacroString { [$1] }


asmbody: 
 | string_list colon_asm_list  { $1, $2 }
 | string_list { $1, [] } /* in old kernel */


colon_asm: TDotDot colon_option_list { Colon $2, [$1]   }

colon_option: 
 | TString                      { ColonMisc, [snd $1] }
 | TString TOPar asm_expr TCPar { ColonExpr $3, [snd $1; $2;$4] } 
 /* cppext: certainly a macro */
 | TOCro TIdent TCCro TString TOPar asm_expr TCPar
     { ColonExpr $6, [$1;snd $2;$3;snd $4; $5; $7 ] }
 | TIdent                       { ColonMisc, [snd $1] }
 | /* empty */                  { ColonMisc, [] }

asm_expr: assign_expr { $1 }

       

/*****************************************************************************/
/* declaration, types, initializers */
/*****************************************************************************/

decl2: 
 | decl_spec TPtVirg
     { let (returnType,storage) = fixDeclSpecForDecl $1 in 
       let iistart = Ast_c.fakeInfo () in
       DeclList ([(None, returnType, unwrap storage),[]],  
                ($2::iistart::snd storage))
     } 
 | decl_spec init_declarator_list TPtVirg 
     { let (returnType,storage) = fixDeclSpecForDecl $1 in
       let iistart = Ast_c.fakeInfo () in
       DeclList (
         ($2 +> List.map (fun ((((s,iis),f), ini), iivirg) -> 
           let ini, iini = 
             match ini with
             | None -> None, []
             | Some (ini, iini) -> Some ini, [iini]
           in
	   if fst (unwrap storage) = StoTypedef 
	   then LP.add_typedef s;
           (Some ((s, ini), iis::iini), f returnType, unwrap storage),
           iivirg 
         )
         ),  ($3::iistart::snd storage))
     } 
 /* cppext: */

 | TMacroDecl TOPar argument_list TCPar TPtVirg 
     { MacroDecl ((fst $1, $3), [snd $1;$2;$4;$5;fakeInfo()]) }
 | Tstatic TMacroDecl TOPar argument_list TCPar TPtVirg 
     { MacroDecl ((fst $2, $4), [snd $2;$3;$5;$6;fakeInfo();$1]) }
 | Tstatic TMacroDeclConst TMacroDecl TOPar argument_list TCPar TPtVirg 
     { MacroDecl ((fst $3, $5), [snd $3;$4;$6;$7;fakeInfo();$1;$2])}



decl_spec2: 
 | storage_class_spec      { {nullDecl with storageD = (fst $1, [snd $1]) } }
 | type_spec               { addTypeD ($1,nullDecl) }
 | type_qualif             { {nullDecl with qualifD  = (fst $1, [snd $1]) } }
 | Tinline                 { {nullDecl with inlineD = (true, [$1]) } }
 | storage_class_spec decl_spec2 { addStorageD ($1, $2) }
 | type_spec          decl_spec2 { addTypeD    ($1, $2) }
 | type_qualif        decl_spec2 { addQualifD  ($1, $2) }
 | Tinline            decl_spec2 { addInlineD ((true, $1), $2) }

/* can simplify by putting all in _opt ? must have at least one otherwise
 *  decl_list is ambiguous ? (no cos have ';' between decl) 
 */


storage_class_spec: 
 | Tstatic      { Sto Static,  $1 }
 | Textern      { Sto Extern,  $1 }
 | Tauto        { Sto Auto,    $1 }
 | Tregister    { Sto Register,$1 }
 | Ttypedef     { StoTypedef,  $1 }

type_spec2: 
 | Tvoid                { Right3 (BaseType Void),            [$1] }
 | Tchar                { Right3 (BaseType (IntType CChar)), [$1]}
 | Tint                 { Right3 (BaseType (IntType (Si (Signed,CInt)))), [$1]}
 | Tfloat               { Right3 (BaseType (FloatType CFloat)),  [$1]}
 | Tdouble              { Right3 (BaseType (FloatType CDouble)), [$1] }
 | Tshort               { Middle3 Short,  [$1]}
 | Tlong                { Middle3 Long,   [$1]}
 | Tsigned              { Left3 Signed,   [$1]}
 | Tunsigned            { Left3 UnSigned, [$1]}
 | struct_or_union_spec { Right3 (fst $1), snd $1 }
 | enum_spec            { Right3 (fst $1), snd $1 }

 /* parse_typedef_fix1: cant put: TIdent {} cos it make the grammar 
  * ambigue, generate lots of conflicts => we must 
  * use some tricks: we make the lexer and parser cooperate, cf lexerParser.ml.
  * 
  * parse_typedef_fix2: this is not enough, and you must use 
  * parse_typedef_fix2 to fully manage typedef problems in grammar.
  */                            
 | TypedefIdent   { Right3 (TypeName (fst $1,Ast_c.noTypedefDef())), [snd $1]}

 | Ttypeof TOPar assign_expr TCPar { Right3 (TypeOfExpr ($3)), [$1;$2;$4] }
 | Ttypeof TOPar type_name  TCPar  { Right3 (TypeOfType ($3)), [$1;$2;$4] }


type_qualif: 
 | Tconst    { {const=true  ; volatile=false}, $1 }
 | Tvolatile { {const=false ; volatile=true},  $1 }



/*----------------------------*/
/* workarounds */
/*----------------------------*/

decl:      decl2         { et "decl" (); $1 }
decl_spec: decl_spec2    { dt "declspec" (); $1  }
type_spec: type_spec2    { dt "type" (); $1   }






/*---------------------------------------------------------------------------*/
/* for struct and also typename */
/* cant put decl_spec cos no storage is allowed for field struct */
spec_qualif_list2: 
 | type_spec                    { addTypeD ($1, nullDecl) }
 | type_qualif                  { {nullDecl with qualifD = (fst $1,[snd $1])}}
 | type_spec   spec_qualif_list { addTypeD ($1,$2)   }
 | type_qualif spec_qualif_list { addQualifD ($1,$2) }

spec_qualif_list: spec_qualif_list2            {  dt "spec_qualif" (); $1 }
 	     
/*---------------------------------------------------------------------------*/
init_declarator: init_declarator2  { dt "init" (); $1 }

init_declarator2:  
 | declaratori                  { ($1, None) }
 | declaratori teq initialize   { ($1, Some ($3, $2)) }



/*----------------------------*/
/* workarounds */
/*----------------------------*/
declaratori: 
 | declarator
     { LP.add_ident (fst (fst $1)); $1 }
 /* gccext: */
 | declarator gcc_asm_decl     
     { LP.add_ident (fst (fst $1)); $1 }

teq: TEq  { et "teq" (); $1 }



/*----------------------------*/
/* gccext: */
/*----------------------------*/

gcc_asm_decl: 
 | Tasm TOPar asmbody TCPar              {  }
 | Tasm Tvolatile TOPar asmbody TCPar   {  }





/*---------------------------------------------------------------------------*/

/* declarator return a couple: 
 *  (name, partial type (a function to be applied to return type)) 
 *
 * when int* f(int) we must return Func(Pointer int,int) and not
 * Pointer (Func(int,int) 
 */

declarator: 
 | pointer direct_d { (fst $2, fun x -> x +> $1 +> (snd $2)  ) }
 | direct_d         { $1  }


pointer: 
 | TMul                          { fun x ->(nQ,         (Pointer x,     [$1]))}
 | TMul type_qualif_list         { fun x ->($2.qualifD, (Pointer x,     [$1]))}
 | TMul pointer                  { fun x ->(nQ,         (Pointer ($2 x),[$1]))}
 | TMul type_qualif_list pointer { fun x ->($2.qualifD, (Pointer ($3 x),[$1]))}

type_qualif_list: 
 | type_qualif                  { {nullDecl with qualifD = (fst $1,[snd $1])} }
 | type_qualif_list type_qualif { addQualifD ($2,$1) }

direct_d: 
 | TIdent                                  
     { ($1, fun x -> x) }
 | TOPar declarator TCPar      /* forunparser: old: $2 */ 
     { (fst $2, fun x -> (nQ, (ParenType ((snd $2) x), [$1;$3]))) }
 | direct_d tocro            tccro         
     { (fst $1,fun x->(snd $1) (nQ,(Array (None,x),         [$2;$3]))) }
 | direct_d tocro const_expr tccro
     { (fst $1,fun x->(snd $1) (nQ,(Array (Some $3,x),      [$2;$4])))}
 | direct_d topar            tcpar
     { (fst $1,
       fun x->(snd $1) 
         (nQ,(FunctionType (x,(([],(false, [])))),[$2;$3])))
     }
 | direct_d topar parameter_type_list tcpar
     { (fst $1,fun x->(snd $1) (nQ,(FunctionType (x, $3),   [$2;$4]))) }


parameter_type_list: 
 | parameter_list                  { ($1, (false, []))}
 | parameter_list TComma TEllipsis { ($1, (true,  [$2;$3])) }


parameter_decl2: 
 | decl_spec declaratorp
     { let ((returnType,hasreg),iihasreg) = fixDeclSpecForParam $1 
       in 
       (hasreg, Some (fst (fst $2)), ((snd $2) returnType)),    
        (iihasreg ++ [snd (fst $2)]) 
     }
 | decl_spec abstract_declarator
     { let ((returnType,hasreg), iihasreg) = fixDeclSpecForParam $1 
       in (hasreg, None, ($2 returnType)),      (iihasreg ++ []) 
     }
 | decl_spec
     { let ((returnType,hasreg), iihasreg) = fixDeclSpecForParam $1 
       in (hasreg, None, returnType),           (iihasreg ++ []) 
     }


/*----------------------------*/
/* workarounds */
/*----------------------------*/

tocro: TOCro { et "tocro" ();$1 }
tccro: TCCro { dt "tccro" ();$1 }

topar: TOPar 
     { LP.new_scope ();et "topar" (); 
       !LP._lexer_hint.parameterDeclaration <- true; $1  
     }
tcpar: TCPar 
     { LP.del_scope ();dt "tcpar" (); 
       !LP._lexer_hint.parameterDeclaration <- false; $1  
     }

parameter_decl: parameter_decl2 { et "param" ();  $1 }

declaratorp: declarator 
     { LP.add_ident (fst (fst $1)); $1 }


/*---------------------------------------------------------------------------*/
type_name: 
 | spec_qualif_list                     
     { let (returnType, _) = fixDeclSpecForDecl $1 in  returnType }
 | spec_qualif_list abstract_declarator 
     { let (returnType, _) = fixDeclSpecForDecl $1 in $2 returnType }


abstract_declarator: 
 | pointer                            { $1 }
 |         direct_abstract_declarator { $1 }
 | pointer direct_abstract_declarator { fun x -> x +> $2 +> $1 }

direct_abstract_declarator: 
 | TOPar abstract_declarator TCPar /* forunparser: old: $2 */
     { (fun x -> (nQ, (ParenType ($2 x), [$1;$3]))) }

 | TOCro            TCCro                            
     { fun x ->   (nQ, (Array (None, x),      [$1;$2]))}
 | TOCro const_expr TCCro                            
     { fun x ->   (nQ, (Array (Some $2, x),   [$1;$3]))}
 | direct_abstract_declarator TOCro            TCCro 
     { fun x ->$1 (nQ, (Array (None, x),      [$2;$3])) }
 | direct_abstract_declarator TOCro const_expr TCCro
     { fun x ->$1 (nQ, (Array (Some $3,x),    [$2;$4])) }
 | TOPar TCPar                                       
     { fun x ->   (nQ, (FunctionType (x, ([], (false,  []))),   [$1;$2])) }
 | TOPar parameter_type_list TCPar
     { fun x ->   (nQ, (FunctionType (x, $2),           [$1;$3]))}
 | direct_abstract_declarator TOPar TCPar
     { fun x ->$1 (nQ, (FunctionType (x, (([], (false, [])))),[$2;$3])) }
 | direct_abstract_declarator TOPar parameter_type_list TCPar
     { fun x -> $1 (nQ, (FunctionType (x, $3), [$2;$4])) }
			  
/*---------------------------------------------------------------------------*/
initialize: 
 | assign_expr                                    
     { InitExpr $1,                [] }
 | tobrace_ini initialize_list gcc_comma_opt_struct  TCBrace
     { InitList (List.rev $2),     [$1;$4]++$3 }
 | tobrace_ini TCBrace
     { InitList [],       [$1;$2] } /* gccext: */


/* opti: This time we use the weird order of non-terminal which requires in 
 * the "caller" to do a List.rev cos quite critical. With this wierd order it
 * allows yacc to use a constant stack space instead of exploding if we do a 
 * initialize2 Tcomma initialize_list.
 */
initialize_list: 
 | initialize2                        { [$1,   []] }
 | initialize_list TComma initialize2 { ($3,  [$2])::$1 }


/* gccext: condexpr and no assign_expr cos can have ambiguity with comma */
initialize2: 
 | cond_expr 
     { InitExpr $1,   [] } 
 | tobrace_ini initialize_list gcc_comma_opt_struct TCBrace
     { InitList (List.rev $2),   [$1;$4]++$3 }
 | tobrace_ini TCBrace
     { InitList [],  [$1;$2]  }

 /* gccext: labeled elements */
 | designator_list TEq initialize2 
     { InitDesignators ($1, $3), [$2] }
 /* gccext: old format */
 | ident TDotDot initialize2
     { InitFieldOld (fst $1, $3),     [snd $1; $2] } /* in old kernel */
 | TOCro const_expr TCCro initialize2
     { InitIndexOld ($2, $4),    [$1;$3] }


designator: 
 | TDot ident 
     { DesignatorField (fst $2), [$1;snd $2] } 
 | TOCro const_expr TCCro 
     { DesignatorIndex ($2),  [$1;$3] }
 | TOCro const_expr TEllipsis const_expr TCCro 
     { DesignatorRange ($2, $4),  [$1;$3;$5] }


/*----------------------------*/
/* workarounds */
/*----------------------------*/

gcc_comma_opt_struct: 
 | TComma {  [$1] } 
 | /* */  {  [Ast_c.fakeInfo() +> Ast_c.rewrap_str ","]  }


tobrace_ini: TOBrace { !LP._lexer_hint.toplevel <- false; $1 }






/*---------------------------------------------------------------------------*/
s_or_u_spec2: 
 | struct_or_union 
     ident tobrace_struct struct_decl_list_gcc tcbrace_struct
     { StructUnion (fst $1, Some (fst $2), $4),  [snd $1;snd $2;$3;$5]  }
 | struct_or_union       tobrace_struct struct_decl_list_gcc tcbrace_struct
     { StructUnion (fst $1, None, $3), [snd $1;$2;$4] }
 | struct_or_union ident       
     { StructUnionName (fst $1, fst $2), [snd $1;snd $2] }

struct_or_union2: 
 | Tstruct   { Struct, $1 }
 | Tunion    { Union, $1 }



struct_decl2: 
 | spec_qualif_list struct_declarator_list TPtVirg 
     { 
       let (returnType,storage) = fixDeclSpecForDecl $1 in
       if fst (unwrap storage) <> NoSto 
       then internal_error "parsing dont allow this";
       
       FieldDeclList ($2 +> (List.map (fun (f, iivirg) ->     
         f returnType, iivirg))
       ),    [$3]
         (* dont need to check if typedef or func initialised cos
            grammar dont allow typedef nor initialiser in struct 
         *)
     }


 |  spec_qualif_list TPtVirg 
     { 
       (* gccext: allow empty elements if it is a structdef or enumdef *)
       let (returnType,storage) = fixDeclSpecForDecl $1 in
       if fst (unwrap storage) <> NoSto 
       then internal_error "parsing dont allow this";
       
       FieldDeclList [(Simple (None, returnType), []) , []], [$2]
     }
 | TPtVirg { EmptyField, [$1]  }



struct_declarator: 
 | declaratorsd                    
     { (fun x -> Simple   (Some (fst (fst $1)), (snd $1) x), [snd (fst $1)]) }
 | dotdot const_expr2            
     { (fun x -> BitField (None, x, $2),              [$1]) }
 | declaratorsd dotdot const_expr2 
     { (fun x -> BitField (Some (fst(fst $1)),
                          ((snd $1) x), 
                          $3),
                          [snd (fst $1);$2]) 
     }


/*----------------------------*/
/* workarounds */
/*----------------------------*/
tobrace_struct: TOBrace 
     { !LP._lexer_hint.toplevel <- false; 
       !LP._lexer_hint.structDefinition <- !LP._lexer_hint.structDefinition +1;
       $1 
     }
tcbrace_struct: TCBrace 
     {
       !LP._lexer_hint.structDefinition <- !LP._lexer_hint.structDefinition -1;
       $1
     }

declaratorsd: declarator 
  { (*also ? LP.add_ident (fst (fst $1)); *) $1 }



struct_or_union_spec: s_or_u_spec2 { dt "su" (); $1 }
struct_or_union: struct_or_union2 { et "su" (); $1 }
struct_decl: struct_decl2  { et "struct" (); $1 }

dotdot: TDotDot  { et "dotdot" (); $1 }
const_expr2: const_expr { dt "const_expr2" (); $1 }

struct_decl_list_gcc: 
 | struct_decl_list  { $1 } 
 | /* empty */       { [] } /* gccext: allow empty struct */


/*---------------------------------------------------------------------------*/
enum_spec: 
 | Tenum        tobrace_enum enumerator_list gcc_comma_opt TCBrace 
     { Enum (None,    $3),           [$1;$2;$5] ++ $4 }
 | Tenum ident  tobrace_enum enumerator_list gcc_comma_opt TCBrace
     { Enum (Some (fst $2), $4),     [$1; snd $2; $3;$6] ++ $5 }
 | Tenum ident                                                
     { EnumName (fst $2),       [$1; snd $2] }

enumerator: 
 | idente                 { (fst $1, None),      [snd $1]    }
 | idente  TEq const_expr { (fst $1, Some $3),   [snd $1; $2] }



/*----------------------------*/
/* workarounds */
/*----------------------------*/

idente: ident { LP.add_ident (fst $1); $1 }

tobrace_enum: TOBrace { !LP._lexer_hint.toplevel <- false; $1 }



/*****************************************************************************/
/* xxx_list, xxx_opt */
/*****************************************************************************/


/*
decl_list: 
 | decl           { [$1]   }
 | decl_list decl { $1 ++ [$2] }

statement_list: 
 | statement { [$1] }
 | statement_list statement { $1 ++ [$2] }
*/

stat_or_decl_list: 
 | stat_or_decl { [$1] }                          
 | stat_or_decl_list stat_or_decl { $1 ++ [$2] }




string_list: 
 | string_elem { $1 }
 | string_list string_elem { $1 ++ $2 } 

colon_asm_list: 
 | colon_asm { [$1] }
 | colon_asm_list colon_asm  { $1 ++ [$2] }

colon_option_list: 
 | colon_option { [$1, []] } 
 | colon_option_list TComma colon_option { $1 ++ [$3, [$2]] }



argument_list: 
 | argument                           { [$1, []] }
 | argument_list TComma argument { $1 ++ [$3,    [$2]] }

/*
expression_list:
 | assign_expr { [$1, []] }
 | expression_list TComma assign_expr { $1 ++ [$3,   [$2]] }
*/


struct_decl_list: 
 | struct_decl                   { [$1] }
 | struct_decl_list struct_decl  { $1 ++ [$2] }


struct_declarator_list: 
 | struct_declarator                               { [$1,           []] }
 | struct_declarator_list TComma struct_declarator { $1 ++ [$3,     [$2]] }


enumerator_list: 
 | enumerator                        { [$1,          []]   }
 | enumerator_list TComma enumerator { $1 ++ [$3,    [$2]] }


init_declarator_list: 
 | init_declarator                             { [$1,   []] }
 | init_declarator_list TComma init_declarator { $1 ++ [$3,     [$2]] }


parameter_list: 
 | parameter_decl                       { [$1, []] }
 | parameter_list TComma parameter_decl { $1 ++ [$3,  [$2]] }

taction_list: 
 | /* empty */ { [] }
 | TAction { [$1] }
 | taction_list TAction { $1 ++ [$2] }

param_define_list: 
 | /* empty */ { [] }
 | param_define                           { [$1, []] }
 | param_define_list TComma param_define  { $1 ++ [$3, [$2]] }

designator_list: 
 | designator { [$1] }
 | designator_list designator { $1 ++ [$2] }


/* gccext:  which allow a trailing ',' in enum, as in perl */
gcc_comma_opt: 
 | TComma {  [$1] } 
 | /* */  {  []  }

/*
gcc_opt_virg:
 | TPtVirg { }
 |  { }
*/

gcc_opt_expr: 
 | expr        { Some $1 }
 | /* empty */ { None  }

/*
opt_ptvirg:
 | TPtVirg { [$1] }
 | { [] }
*/


/*****************************************************************************/
/* cpp directives */
/*****************************************************************************/

/* cppext: */
cpp_directives: 

 | TIdent TOPar argument_list TCPar TPtVirg
     { MacroTop (fst $1, $3,    [snd $1;$2;$4;$5]) } 

 /* TCParEOL to fix the end-of-stream bug of ocamlyacc */
 | TIdent TOPar argument_list TCParEOL
     { MacroTop (fst $1, $3,    [snd $1;$2;$4;fakeInfo()]) } 

  /* ex: EXPORT_NO_SYMBOLS; */
 | TIdent TPtVirg { EmptyDef [snd $1;$2] }

 | TIncludeStart TIncludeFilename 
     { 
       let (i1, in_ifdef) = $1 in
       let (s, i2) = $2 in

       let inc_file = 
         match () with
         | _ when s =~ "^\"\\(.*\\)\"$" -> 
             Local (Common.split "/" (matched1 s))
         | _ when s =~ "^\\<\\(.*\\)\\>$" -> 
             NonLocal (Common.split "/" (matched1 s))
         | _ -> 
             Wierd s 
       in
       Include ((inc_file, [i1;i2]), (Ast_c.noRelPos(), !in_ifdef)) 
     }

 | TDefine TIdentDefine define_val TDefEOL 
     { Define ((fst $2, [$1; snd $2;$4]), (DefineVar, $3)) }

 /* The TOParDefine is introduced to avoid ambiguity with previous rule.
  * A TOParDefine was a TOPar that was just next to the ident.
  */
 | TDefine TIdentDefine TOParDefine param_define_list TCPar define_val TDefEOL
     { Define 
         ((fst $2, [$1; snd $2;$7]), 
           (DefineFunc ($4, [$3;$5]), $6)) 
     }


/* perhaps better to use assign_expr ? but in that case need 
 * do a assign_expr_of_string in parse_c
 */
define_val: 
 | expr      { DefineExpr $1 }
 | statement { DefineStmt $1 }
 | decl      { DefineStmt (Decl $1, []) }
 | TypedefIdent { DefineType (nQ,(TypeName(fst $1,noTypedefDef()),[snd $1]))}
 | function_definition { DefineFunction $1 }

 | Tdo statement Twhile TOPar TInt TCPar 
     {
       if fst $5 <> "0" 
       then pr2 "WIERD: in macro and have not a while(0)";
       DefineDoWhileZero ($2,  [$1;$3;$4;snd $5;$6])
     }
 | /* empty */ { DefineEmpty }

param_define:
 | TIdent               { fst $1, [snd $1] } 
 | TypedefIdent         { fst $1, [snd $1] } 
 | TDefParamVariadic    { fst $1, [snd $1] } 
 | TEllipsis            { "...", [$1] }
 /* they reuse keywords :(  */
 | Tregister            { "register", [$1] }


/*****************************************************************************/
/* celem */
/*****************************************************************************/

external_declaration: 
 | function_definition               { Definition $1 }
 | decl                              { Declaration $1 }

function_definition: function_def    { fixFunc $1 }

function_def: start_fun compound      { LP.del_scope(); ($1, $2) }

start_fun: start_fun2                        
  { LP.new_scope(); 
    fix_add_params_ident $1; 
    !LP._lexer_hint.toplevel <- false;  
    $1 
  }

start_fun2: decl_spec declaratorfd  
     { let (returnType,storage) = fixDeclSpecForFuncDef $1 in
       (fst $2, fixOldCDecl ((snd $2) returnType) , storage) 
     }

celem: 
 | external_declaration                         { $1 }
 | cpp_directives                               { $1 }

 /* can have asm declaration at toplevel */
 | Tasm TOPar asmbody TCPar TPtVirg             { EmptyDef [] } 

 /* in ~/kernels/src/linux-2.5.2/drivers/isdn/hisax/isdnl3.c sometimes
  * the function ends with }; instead of just } 
  * can also remove this rule and report "parse error" pb to morton
  */
 | TPtVirg    { EmptyDef [$1] } 

         
 | EOF        { FinalDef $1 } 


/*----------------------------*/
/* workarounds */
/*----------------------------*/
declaratorfd: declarator { et "declaratorfd" (); $1 }



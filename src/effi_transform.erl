%% effi_transform.erl — Compile-time parse transform for effi bindings.
%%
%% Usage: add to your module:
%%
%%   -module(my_lib).
%%   -compile({parse_transform, effi_transform}).
%%
%%   -effi_lib("libm.so.6").
%%   -effi_fun({sqrt,  double,  [double]}).
%%   -effi_fun({pow,   double,  [double, double]}).
%%   -effi_fun({floor, double,  [double]}).
%%
%% The transform generates:
%%
%%   (1) A private '$effi_lib$'/0 function that loads the library lazily
%%       via persistent_term on first call.
%%
%%   (2) One public wrapper function per -effi_fun:
%%         sqrt(Arg0) ->
%%             case effi:call('$effi_lib$'(), "sqrt", double, [{double, Arg0}]) of
%%                 {ok, R} -> R;
%%                 {error, E} -> error(E)
%%             end.
%%
%%   (3) An -export attribute covering all generated functions.
%%
%% Attribute formats:
%%
%%   -effi_lib(LibPath).
%%     LibPath : string, e.g. "libm.so.6"
%%
%%   -effi_fun({FuncName, RetType, [ArgType]}).
%%     FuncName : atom — used as both Erlang name and C symbol
%%     RetType  : type atom (void | int32 | double | pointer | ...)
%%     [ArgType]: list of type atoms
%%
%%   -effi_fun({{ErlName, "c_name"}, RetType, [ArgType]}).
%%     ErlName  : atom for the Erlang function
%%     "c_name" : C symbol to look up via dlsym

-module(effi_transform).
-export([parse_transform/2]).

parse_transform(Forms, _Opts) ->
    LibPath  = find_attr(effi_lib, Forms),
    FunSpecs = find_all_attr(effi_fun, Forms),

    case LibPath =:= undefined andalso FunSpecs =:= [] of
        true  -> Forms;  %% nothing to do
        false -> transform(Forms, LibPath, FunSpecs)
    end.

transform(Forms, LibPath, RawSpecs) ->
    ModName = find_module(Forms),
    Specs   = [parse_fun_spec(S) || S <- RawSpecs],

    %% Validate
    case LibPath =:= undefined andalso Specs =/= [] of
        true  -> error({effi_transform, missing_effi_lib, ModName});
        false -> ok
    end,

    %% Strip effi_* module attributes
    Clean = [F || F <- Forms, not is_effi_attr(F)],

    %% Generate new forms
    Generated =
        gen_exports(Specs) ++
        gen_lib_loader(ModName, LibPath) ++
        [gen_fun_wrapper(S) || S <- Specs],

    insert_before_funs(Clean, Generated).

%% -------------------------------------------------------------------------
%% Attribute extraction
%% -------------------------------------------------------------------------

find_module(Forms) ->
    case [M || {attribute, _, module, M} <- Forms] of
        [M | _] -> M;
        []      -> undefined
    end.

find_attr(Name, Forms) ->
    case [V || {attribute, _, N, V} <- Forms, N =:= Name] of
        [V | _] -> V;
        []      -> undefined
    end.

find_all_attr(Name, Forms) ->
    [V || {attribute, _, N, V} <- Forms, N =:= Name].

is_effi_attr({attribute, _, effi_lib, _}) -> true;
is_effi_attr({attribute, _, effi_fun, _}) -> true;
is_effi_attr(_) -> false.

%% -------------------------------------------------------------------------
%% Fun spec parsing
%%
%% Returns {ErlName :: atom, CName :: string, RetType :: atom, ArgTypes :: [atom]}
%% -------------------------------------------------------------------------

parse_fun_spec({Name, Ret, Args}) when is_atom(Name) ->
    {Name, atom_to_list(Name), Ret, Args};
parse_fun_spec({{ErlName, CName}, Ret, Args})
  when is_atom(ErlName), is_list(CName) ->
    {ErlName, CName, Ret, Args}.

%% -------------------------------------------------------------------------
%% Code generation (produces Erlang AST forms)
%% -------------------------------------------------------------------------

%% Line 0 for all generated code (standard practice for transforms)
-define(L, 0).

gen_exports(Specs) ->
    Exports = [{ErlName, length(ArgTypes)}
               || {ErlName, _CName, _Ret, ArgTypes} <- Specs],
    case Exports of
        [] -> [];
        _  -> [attr(export, Exports)]
    end.

%% Generate:
%%   '$effi_lib$'() ->
%%       case persistent_term:get({effi_lib, ModName}, undefined) of
%%           {Lib_} -> Lib_;
%%           undefined ->
%%               {ok, Lib_} = effi:load(LibPath),
%%               persistent_term:put({effi_lib, ModName}, {Lib_}),
%%               Lib_
%%       end.
gen_lib_loader(ModName, LibPath) ->
    Key = tup([atm(effi_lib), atm(ModName)]),

    LoadedClause = clause(
        [tup([var('Lib_')])],
        [var('Lib_')]),

    UndefClause = clause(
        [atm(undefined)],
        [match(tup([atm(ok), var('Lib_')]),
               rcall(effi, load, [str(LibPath)])),
         rcall(persistent_term, put, [Key, tup([var('Lib_')])]),
         var('Lib_')]),

    Body = [{'case', ?L,
             rcall(persistent_term, get, [Key, atm(undefined)]),
             [LoadedClause, UndefClause]}],

    [func('$effi_lib$', 0, [clause([], Body)])].

%% Generate wrapper function for one -effi_fun spec:
%%   FuncName(Arg0, Arg1, ...) ->
%%       case effi:call('$effi_lib$'(), "c_name", RetType,
%%                      [{T0, Arg0}, {T1, Arg1}, ...]) of
%%           {ok, R_} -> R_;
%%           {error, E_} -> error(E_)
%%       end.
gen_fun_wrapper({ErlName, CName, RetType, ArgTypes}) ->
    Arity  = length(ArgTypes),
    ArgVars = [var(arg_var(I)) || I <- lists:seq(0, Arity - 1)],
    ArgPairs = mk_list([tup([atm(T), var(arg_var(I))])
                        || {T, I} <- lists:zip(ArgTypes, lists:seq(0, Arity - 1))]),
    CallExpr = rcall(effi, call,
                     [lcall('$effi_lib$', []),
                      str(CName),
                      atm(RetType),
                      ArgPairs]),
    OkClause  = clause([tup([atm(ok),    var('R_')])], [var('R_')]),
    ErrClause = clause([tup([atm(error), var('E_')])],
                       [rcall(erlang, error, [var('E_')])]),
    Body = [{'case', ?L, CallExpr, [OkClause, ErrClause]}],
    func(ErlName, Arity, [clause(ArgVars, Body)]).

arg_var(I) -> list_to_atom("Arg" ++ integer_to_list(I)).

%% -------------------------------------------------------------------------
%% AST construction helpers
%% -------------------------------------------------------------------------

atm(A)        -> {atom,    ?L, A}.
var(N)        -> {var,     ?L, N}.
str(S)        -> {string,  ?L, S}.
tup(Es)       -> {tuple,   ?L, Es}.
match(P, E)   -> {match,   ?L, P, E}.

mk_list([])      -> {nil, ?L};
mk_list([H | T]) -> {cons, ?L, H, mk_list(T)}.

lcall(F, Args) ->
    {call, ?L, atm(F), Args}.

rcall(M, F, Args) ->
    {call, ?L, {remote, ?L, atm(M), atm(F)}, Args}.

clause(Pats, Body) ->
    {clause, ?L, Pats, [], Body}.

func(Name, Arity, Clauses) ->
    {function, ?L, Name, Arity, Clauses}.

attr(Name, Value) ->
    {attribute, ?L, Name, Value}.

%% -------------------------------------------------------------------------
%% Insert generated forms before the first function definition
%% -------------------------------------------------------------------------

insert_before_funs(Forms, NewForms) ->
    {Before, After} =
        lists:splitwith(fun(F) -> element(1, F) =/= function end, Forms),
    Before ++ NewForms ++ After.

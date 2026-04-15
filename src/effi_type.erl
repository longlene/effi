%% effi_type.erl — Type registry and C struct layout engine.
%%
%% Stores struct/union/enum/typedef definitions in a named ETS table.
%% Layout (field offsets, padding, total size) is computed once at
%% definition time using System V AMD64 ABI alignment rules.
%%
%% Supported type specs:
%%
%%   Primitives  : void | int8 | uint8 | int16 | uint16 | int32 | uint32
%%               | int64 | uint64 | float | double | pointer | string | bool
%%
%%   Composites  : {array, ElemType, N}          — fixed-size C array
%%               | {ptr, PointeeType}             — typed pointer (same as pointer)
%%               | SomeName                       — named registered type
%%
%% The table is created lazily on first access; no OTP application needed.

-module(effi_type).

-export([
    %% Registration
    defcstruct/2,   %% (Name, [{FieldName, TypeSpec}])
    defcunion/2,    %% (Name, [{FieldName, TypeSpec}])
    defcenum/2,     %% (Name, [Atom] | [{Atom, Int}])
    defctype/2,     %% (Name, TypeSpec)   — typedef alias

    %% Query
    lookup/1,           %% Name -> TypeInfo | not_found
    sizeof/1,           %% TypeSpec -> Bytes
    alignof/1,          %% TypeSpec -> Bytes
    field_info/2,       %% (StructName, FieldName) -> {Type, Offset} | not_found
    enum_to_int/2,      %% (EnumName, Atom) -> integer()
    enum_to_atom/2      %% (EnumName, Int)  -> atom() | Int
]).

-define(TABLE, effi_type_registry).

%% -------------------------------------------------------------------------
%% Internal: ETS lifecycle
%% -------------------------------------------------------------------------

ensure_table() ->
    try ets:new(?TABLE, [named_table, public, set, {read_concurrency, true}])
    catch error:badarg -> ok   %% already exists
    end.

put_type(Name, Info) ->
    ensure_table(),
    ets:insert(?TABLE, {Name, Info}),
    ok.

%% -------------------------------------------------------------------------
%% Registration API
%% -------------------------------------------------------------------------

%% defcstruct(Name, [{FieldName, TypeSpec}]) -> ok
-spec defcstruct(atom(), [{atom(), term()}]) -> ok.
defcstruct(Name, Fields) ->
    {Size, Align, LayoutFields} = compute_struct_layout(Fields),
    put_type(Name, {struct, Size, Align, LayoutFields}).

%% defcunion(Name, [{FieldName, TypeSpec}]) -> ok
-spec defcunion(atom(), [{atom(), term()}]) -> ok.
defcunion(Name, Fields) ->
    {Size, Align, LayoutFields} = compute_union_layout(Fields),
    put_type(Name, {union, Size, Align, LayoutFields}).

%% defcenum(Name, [Atom] | [{Atom, Int}]) -> ok
-spec defcenum(atom(), list()) -> ok.
defcenum(Name, Values) ->
    Pairs = normalize_enum(Values),
    ToInt  = maps:from_list(Pairs),
    ToAtom = maps:from_list([{V, K} || {K, V} <- Pairs]),
    put_type(Name, {enum, ToInt, ToAtom}).

%% defctype(Name, TypeSpec) -> ok
-spec defctype(atom(), term()) -> ok.
defctype(Name, TypeSpec) ->
    put_type(Name, {typedef, TypeSpec}).

%% -------------------------------------------------------------------------
%% Query API
%% -------------------------------------------------------------------------

-spec lookup(atom()) -> term() | not_found.
lookup(Name) ->
    ensure_table(),
    case ets:lookup(?TABLE, Name) of
        [{Name, Info}] -> Info;
        []             -> not_found
    end.

%% sizeof(TypeSpec) -> non_neg_integer()
-spec sizeof(term()) -> non_neg_integer().
sizeof({array, T, N})    -> sizeof(T) * N;
sizeof({ptr, _})         -> sizeof(pointer);
sizeof(T) when is_atom(T) ->
    case prim_size(T) of
        undefined ->
            case lookup(T) of
                {struct,  S, _, _} -> S;
                {union,   S, _, _} -> S;
                {typedef, Target}  -> sizeof(Target);
                {enum, _, _}       -> sizeof(int32);  %% enums are int32 by default
                not_found          -> error({unknown_type, T})
            end;
        S -> S
    end.

%% alignof(TypeSpec) -> pos_integer()
-spec alignof(term()) -> pos_integer().
alignof({array, T, _N}) -> alignof(T);
alignof({ptr, _})       -> alignof(pointer);
alignof(T) when is_atom(T) ->
    case prim_align(T) of
        undefined ->
            case lookup(T) of
                {struct,  _, A, _} -> A;
                {union,   _, A, _} -> A;
                {typedef, Target}  -> alignof(Target);
                {enum, _, _}       -> alignof(int32);
                not_found          -> error({unknown_type, T})
            end;
        A -> A
    end.

%% field_info(StructOrUnionName, FieldName) -> {TypeSpec, Offset} | not_found
-spec field_info(atom(), atom()) -> {term(), non_neg_integer()} | not_found.
field_info(TypeName, FieldName) ->
    case lookup(TypeName) of
        {struct, _, _, Fields} -> find_field(Fields, FieldName);
        {union,  _, _, Fields} -> find_field(Fields, FieldName);
        _                      -> not_found
    end.

%% enum_to_int(EnumName, Atom) -> integer()
-spec enum_to_int(atom(), atom()) -> integer().
enum_to_int(EnumName, Atom) ->
    {enum, ToInt, _} = lookup(EnumName),
    case maps:find(Atom, ToInt) of
        {ok, V} -> V;
        error   -> error({bad_enum_value, EnumName, Atom})
    end.

%% enum_to_atom(EnumName, Int) -> atom() | Int
-spec enum_to_atom(atom(), integer()) -> atom() | integer().
enum_to_atom(EnumName, Int) ->
    {enum, _, ToAtom} = lookup(EnumName),
    maps:get(Int, ToAtom, Int).

%% -------------------------------------------------------------------------
%% Layout computation
%% -------------------------------------------------------------------------

compute_struct_layout(Fields) ->
    {FinalOff, MaxAlign, RevFields} =
        lists:foldl(fun({FName, FType}, {Off, MA, Acc}) ->
            FAlign = alignof(FType),
            FSize  = sizeof(FType),
            AlignedOff = align_up(Off, FAlign),
            {AlignedOff + FSize, max(MA, FAlign), [{FName, FType, AlignedOff} | Acc]}
        end, {0, 1, []}, Fields),
    TotalSize = align_up(FinalOff, MaxAlign),
    {TotalSize, MaxAlign, lists:reverse(RevFields)}.

compute_union_layout(Fields) ->
    {MaxSize, MaxAlign, RevFields} =
        lists:foldl(fun({FName, FType}, {MS, MA, Acc}) ->
            {max(MS, sizeof(FType)), max(MA, alignof(FType)),
             [{FName, FType, 0} | Acc]}
        end, {0, 1, []}, Fields),
    TotalSize = align_up(MaxSize, MaxAlign),
    {TotalSize, MaxAlign, lists:reverse(RevFields)}.

%% -------------------------------------------------------------------------
%% Helpers
%% -------------------------------------------------------------------------

align_up(N, 1) -> N;
align_up(N, A) -> (N + A - 1) band (bnot (A - 1)).

find_field([], _) -> not_found;
find_field([{Name, Type, Offset} | _], Name) -> {Type, Offset};
find_field([_ | Rest], Name) -> find_field(Rest, Name).

normalize_enum(Values) ->
    {Pairs, _} = lists:mapfoldl(
        fun(A, I) when is_atom(A)      -> {{A, I}, I + 1};
           ({A, V}, _I) when is_atom(A) -> {{A, V}, V + 1}
        end, 0, Values),
    Pairs.

%% Primitive sizes (bytes). Returns undefined for unknown atoms.
prim_size(void)    -> 0;
prim_size(bool)    -> 1;
prim_size(int8)    -> 1;   prim_size(uint8)   -> 1;
prim_size(int16)   -> 2;   prim_size(uint16)  -> 2;
prim_size(int32)   -> 4;   prim_size(uint32)  -> 4;
prim_size(int64)   -> 8;   prim_size(uint64)  -> 8;
prim_size(float)   -> 4;
prim_size(double)  -> 8;
prim_size(pointer) -> 8;
prim_size(string)  -> 8;
prim_size(_)       -> undefined.

%% Primitive alignments (equal to size for all standard C types on x86-64).
prim_align(void)   -> 1;
prim_align(bool)   -> 1;
prim_align(T)      ->
    case prim_size(T) of
        undefined -> undefined;
        0         -> 1;
        S         -> S
    end.

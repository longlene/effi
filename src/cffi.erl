%% cffi.erl — Erlang CFFI public API
%%
%% Quick start:
%%
%%   %% Primitive call
%%   {ok, Lib} = cffi:load("libm.so.6"),
%%   {ok, 2.0} = cffi:call(Lib, "sqrt", double, [{double, 4.0}]),
%%
%%   %% Define a struct, allocate, read/write fields
%%   cffi:defcstruct(point, [{x, double}, {y, double}]),
%%   Ptr = cffi:alloc_struct(point),
%%   cffi:struct_write(Ptr, point, x, 1.5),
%%   cffi:struct_write(Ptr, point, y, 2.5),
%%   #{x := 1.5, y := 2.5} = cffi:struct_to_map(Ptr, point),
%%   cffi:free(Ptr).
%%
%% Type specs:
%%   Primitive : void | bool | int8 | uint8 | int16 | uint16
%%             | int32 | uint32 | int64 | uint64 | float | double
%%             | pointer | string
%%   Composite : {array, ElemType, N} | {ptr, PointeeType}
%%             | RegisteredName

-module(cffi).

-export([
    %% Library
    load/1,

    %% Type definitions (delegated to cffi_type)
    defcstruct/2,
    defcunion/2,
    defcenum/2,
    defctype/2,

    %% Calling C functions
    call/3,     %% call(Lib, Func, RetType)
    call/4,     %% call(Lib, Func, RetType, [{ArgType, ArgVal}])
    call_va/5,  %% call_va(Lib, Func, RetType, NFixed, [{ArgType, ArgVal}])

    %% Memory allocation
    alloc/1,        %% alloc(Bytes)
    alloc_type/1,   %% alloc_type(TypeAtom)   → sizeof(Type) bytes
    alloc_type/2,   %% alloc_type(TypeAtom, N) → N×sizeof(Type) bytes
    alloc_struct/1, %% alloc_struct(StructName)
    free/1,

    %% Raw memory read / write
    read/2,         %% read(Ptr, TypeSpec)
    write/3,        %% write(Ptr, TypeSpec, Value)
    read_bytes/2,
    write_bytes/2,

    %% Struct / union field access
    field_ptr/3,        %% field_ptr(Ptr, StructName, FieldName) -> Ptr
    struct_read/3,      %% struct_read(Ptr, StructName, FieldName) -> Value
    struct_write/4,     %% struct_write(Ptr, StructName, FieldName, Value) -> ok
    struct_to_map/2,    %% struct_to_map(Ptr, StructName) -> map()
    map_to_struct/3,    %% map_to_struct(Ptr, StructName, map()) -> ok

    %% Array element access
    array_ptr/3,    %% array_ptr(Ptr, ElemType, Index) -> Ptr
    array_read/3,   %% array_read(Ptr, ElemType, Index) -> Value
    array_write/4,  %% array_write(Ptr, ElemType, Index, Value) -> ok

    %% Pointer utilities
    ptr_add/2,
    null/0,
    is_null/1,
    type_size/1,
    align_of/1,

    %% Scoped allocation
    with_alloc/2,   %% with_alloc(Bytes, fun(Ptr) -> R) -> R
    with_alloc/3    %% with_alloc(Type, Count, fun(Ptr) -> R) -> R
]).

%% -------------------------------------------------------------------------
%% Type definitions
%% -------------------------------------------------------------------------

-spec defcstruct(atom(), [{atom(), term()}]) -> ok.
defcstruct(Name, Fields) -> cffi_type:defcstruct(Name, Fields).

-spec defcunion(atom(), [{atom(), term()}]) -> ok.
defcunion(Name, Fields) -> cffi_type:defcunion(Name, Fields).

-spec defcenum(atom(), list()) -> ok.
defcenum(Name, Values) -> cffi_type:defcenum(Name, Values).

-spec defctype(atom(), term()) -> ok.
defctype(Name, TypeSpec) -> cffi_type:defctype(Name, TypeSpec).

%% -------------------------------------------------------------------------
%% Library loading
%% -------------------------------------------------------------------------

-spec load(string() | binary()) -> {ok, reference()} | {error, term()}.
load(Path) ->
    cffi_nif:lib_open(to_list(Path)).

%% -------------------------------------------------------------------------
%% Calling C functions
%% -------------------------------------------------------------------------

-spec call(reference(), string() | binary(), term()) ->
    {ok, term()} | {error, term()}.
call(Lib, Func, RetType) ->
    call(Lib, Func, RetType, []).

%% call/4 resolves registered types (enums, typedefs) before dispatching
%% to the NIF, and converts the return value back for enum/typedef ret types.
-spec call(reference(), string() | binary(), term(), list()) ->
    {ok, term()} | {error, term()}.
call(Lib, Func, RetType, Args) ->
    NifRetType = resolve_type_for_nif(RetType),
    NifArgs = [resolve_arg_for_nif(A) || A <- Args],
    case cffi_nif:call(Lib, to_list(Func), NifRetType, NifArgs) of
        {ok, Val} -> {ok, unmarshal_ret(RetType, Val)};
        Err       -> Err
    end.

%% call_va/5 — variadic C function call.
%%
%%   NFixed: count of fixed (non-variadic) arguments.
%%           Must satisfy 1 =< NFixed =< length(Args).
%%   Variadic float args are automatically promoted to double per C rules.
%%
%%   Example:
%%     {ok, N} = cffi:call_va(Lib, "snprintf", int32, 3,
%%                 [{pointer, Buf}, {uint64, BufSize},
%%                  {string, "x=%d y=%.2f"},
%%                  {int32, 42}, {double, 3.14}])
-spec call_va(reference(), string() | binary(), term(), pos_integer(), list()) ->
    {ok, term()} | {error, term()}.
call_va(Lib, Func, RetType, NFixed, Args) ->
    NifRetType = resolve_type_for_nif(RetType),
    NifArgs    = [resolve_arg_for_nif(A) || A <- Args],
    case cffi_nif:call_va(Lib, to_list(Func), NifRetType, NFixed, NifArgs) of
        {ok, Val} -> {ok, unmarshal_ret(RetType, Val)};
        Err       -> Err
    end.

%% -------------------------------------------------------------------------
%% Memory allocation
%% -------------------------------------------------------------------------

-spec alloc(pos_integer()) -> reference().
alloc(Bytes) when is_integer(Bytes), Bytes > 0 ->
    cffi_nif:mem_alloc(Bytes).

-spec alloc_type(term()) -> reference().
alloc_type(Type) -> alloc_type(Type, 1).

-spec alloc_type(term(), pos_integer()) -> reference().
alloc_type(Type, Count) when is_integer(Count), Count > 0 ->
    cffi_nif:mem_alloc(cffi_type:sizeof(Type) * Count).

-spec alloc_struct(atom()) -> reference().
alloc_struct(StructName) ->
    cffi_nif:mem_alloc(cffi_type:sizeof(StructName)).

-spec free(reference()) -> ok | {error, term()}.
free(Ptr) ->
    cffi_nif:mem_free(Ptr).

%% -------------------------------------------------------------------------
%% Raw memory read / write
%%
%% read/2 handles registered types:
%%   enum       → integer read, then mapped to atom
%%   typedef    → resolved to underlying type
%%   struct/union → returns a borrowed ptr (sub-object access)
%%   array      → returns a borrowed ptr to first element
%%   primitive  → delegated to NIF directly
%% -------------------------------------------------------------------------

-spec read(reference(), term()) -> term().
read(Ptr, Type) ->
    case cffi_type:lookup(resolve_typedef(Type)) of
        not_found ->
            cffi_nif:mem_read(Ptr, primitive_type(Type));
        {enum, _, ToAtom} ->
            Int = cffi_nif:mem_read(Ptr, int32),
            maps:get(Int, ToAtom, Int);
        {struct, _, _, _} ->
            Ptr;    %% return pointer to the sub-struct
        {union,  _, _, _} ->
            Ptr;
        {typedef, Inner} ->
            read(Ptr, Inner)
    end.

-spec write(reference(), term(), term()) -> ok | {error, term()}.
write(Ptr, Type, Value) ->
    case cffi_type:lookup(resolve_typedef(Type)) of
        not_found ->
            cffi_nif:mem_write(Ptr, primitive_type(Type), Value);
        {enum, ToInt, _} ->
            Int = case Value of
                A when is_atom(A) ->
                    case maps:find(A, ToInt) of
                        {ok, V} -> V;
                        error   -> error({bad_enum_value, Type, A})
                    end;
                N when is_integer(N) -> N
            end,
            cffi_nif:mem_write(Ptr, int32, Int);
        {typedef, Inner} ->
            write(Ptr, Inner, Value)
    end.

-spec read_bytes(reference(), pos_integer()) -> binary().
read_bytes(Ptr, Size) -> cffi_nif:mem_read_bytes(Ptr, Size).

-spec write_bytes(reference(), binary()) -> ok.
write_bytes(Ptr, Bytes) -> cffi_nif:mem_write_bytes(Ptr, Bytes).

%% -------------------------------------------------------------------------
%% Struct / union field access
%% -------------------------------------------------------------------------

%% Return a borrowed pointer to a named field within a struct/union.
-spec field_ptr(reference(), atom(), atom()) -> reference().
field_ptr(Ptr, TypeName, FieldName) ->
    case cffi_type:field_info(TypeName, FieldName) of
        {_Type, Offset} -> cffi_nif:ptr_add(Ptr, Offset);
        not_found       -> error({unknown_field, TypeName, FieldName})
    end.

-spec struct_read(reference(), atom(), atom()) -> term().
struct_read(Ptr, TypeName, FieldName) ->
    case cffi_type:field_info(TypeName, FieldName) of
        {FType, Offset} ->
            FPtr = cffi_nif:ptr_add(Ptr, Offset),
            read(FPtr, FType);
        not_found ->
            error({unknown_field, TypeName, FieldName})
    end.

-spec struct_write(reference(), atom(), atom(), term()) -> ok.
struct_write(Ptr, TypeName, FieldName, Value) ->
    case cffi_type:field_info(TypeName, FieldName) of
        {FType, Offset} ->
            FPtr = cffi_nif:ptr_add(Ptr, Offset),
            write(FPtr, FType, Value);
        not_found ->
            error({unknown_field, TypeName, FieldName})
    end.

%% Read all fields of a struct into a map #{field_name => value}.
-spec struct_to_map(reference(), atom()) -> map().
struct_to_map(Ptr, TypeName) ->
    Fields = struct_fields(TypeName),
    maps:from_list([
        begin
            FPtr = cffi_nif:ptr_add(Ptr, Offset),
            {FName, read(FPtr, FType)}
        end
        || {FName, FType, Offset} <- Fields
    ]).

%% Write map values into struct fields (unmentioned fields are unchanged).
-spec map_to_struct(reference(), atom(), map()) -> ok.
map_to_struct(Ptr, TypeName, Map) ->
    Fields = struct_fields(TypeName),
    lists:foreach(fun({FName, FType, Offset}) ->
        case maps:find(FName, Map) of
            {ok, Val} ->
                FPtr = cffi_nif:ptr_add(Ptr, Offset),
                write(FPtr, FType, Val);
            error -> ok
        end
    end, Fields).

%% -------------------------------------------------------------------------
%% Array element access
%% -------------------------------------------------------------------------

-spec array_ptr(reference(), term(), non_neg_integer()) -> reference().
array_ptr(Ptr, ElemType, Index) ->
    cffi_nif:ptr_add(Ptr, cffi_type:sizeof(ElemType) * Index).

-spec array_read(reference(), term(), non_neg_integer()) -> term().
array_read(Ptr, ElemType, Index) ->
    read(array_ptr(Ptr, ElemType, Index), ElemType).

-spec array_write(reference(), term(), non_neg_integer(), term()) -> ok.
array_write(Ptr, ElemType, Index, Value) ->
    write(array_ptr(Ptr, ElemType, Index), ElemType, Value).

%% -------------------------------------------------------------------------
%% Pointer utilities
%% -------------------------------------------------------------------------

-spec ptr_add(reference(), integer()) -> reference().
ptr_add(Ptr, Offset) -> cffi_nif:ptr_add(Ptr, Offset).

-spec null() -> reference().
null() -> cffi_nif:ptr_null().

-spec is_null(reference()) -> boolean().
is_null(Ptr) -> cffi_nif:ptr_is_null(Ptr).

-spec type_size(term()) -> non_neg_integer().
type_size(Type) -> cffi_type:sizeof(Type).

-spec align_of(term()) -> pos_integer().
align_of(Type) -> cffi_type:alignof(Type).

%% -------------------------------------------------------------------------
%% Scoped allocation
%% -------------------------------------------------------------------------

-spec with_alloc(pos_integer(), fun((reference()) -> R)) -> R.
with_alloc(Bytes, Fun) ->
    Ptr = alloc(Bytes),
    try Fun(Ptr)
    after free(Ptr)
    end.

-spec with_alloc(term(), pos_integer(), fun((reference()) -> R)) -> R.
with_alloc(Type, Count, Fun) ->
    with_alloc(cffi_type:sizeof(Type) * Count, Fun).

%% -------------------------------------------------------------------------
%% Internal helpers
%% -------------------------------------------------------------------------

%% Resolve typedef chains to a base type name.
resolve_typedef(T) when is_atom(T) ->
    case cffi_type:lookup(T) of
        {typedef, Inner} -> resolve_typedef(Inner);
        _                -> T
    end;
resolve_typedef(T) -> T.

%% Map a type spec to the NIF-level primitive type atom.
%% Composites and registered types collapse to their NIF equivalent.
primitive_type({array, _, _}) -> pointer;
primitive_type({ptr, _})      -> pointer;
primitive_type(T) when is_atom(T) ->
    case cffi_type:lookup(T) of
        {struct, _, _, _} -> pointer;
        {union,  _, _, _} -> pointer;
        {enum,   _, _}    -> int32;
        {typedef, Inner}  -> primitive_type(Inner);
        not_found         -> T    %% assume primitive, NIF will validate
    end.

%% For call/4: map user-facing type+value to NIF {type, value} pair.
resolve_arg_for_nif({Type, Value}) ->
    NifType = resolve_type_for_nif(Type),
    NifVal  = resolve_value_for_nif(Type, Value),
    {NifType, NifVal}.

resolve_type_for_nif(Type) ->
    case resolve_typedef(Type) of
        T when is_atom(T) ->
            case cffi_type:lookup(T) of
                {enum,   _, _}    -> int32;
                {struct, _, _, _} -> pointer;
                {union,  _, _, _} -> pointer;
                {typedef, Inner}  -> resolve_type_for_nif(Inner);
                _                 -> T
            end;
        {array, _, _} -> pointer;
        {ptr,   _}    -> pointer
    end.

resolve_value_for_nif(Type, Value) ->
    case cffi_type:lookup(resolve_typedef(Type)) of
        {enum, ToInt, _} when is_atom(Value) ->
            case maps:find(Value, ToInt) of
                {ok, V} -> V;
                error   -> error({bad_enum_value, Type, Value})
            end;
        _ ->
            Value
    end.

%% For call/4 return: convert NIF value back to user-facing type.
unmarshal_ret(RetType, Val) ->
    case cffi_type:lookup(resolve_typedef(RetType)) of
        {enum, _, ToAtom} when is_integer(Val) ->
            maps:get(Val, ToAtom, Val);
        {typedef, Inner} ->
            unmarshal_ret(Inner, Val);
        _ ->
            Val
    end.

%% Extract field list from a registered struct/union.
struct_fields(TypeName) ->
    case cffi_type:lookup(TypeName) of
        {struct, _, _, Fields} -> Fields;
        {union,  _, _, Fields} -> Fields;
        not_found -> error({unknown_type, TypeName})
    end.

to_list(S) when is_list(S)   -> S;
to_list(B) when is_binary(B) -> binary_to_list(B).

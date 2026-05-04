%% cffi_port.erl — Port-safe CFFI: C code runs in a separate OS process.
%%
%% API mirrors cffi.erl. Use this when safety > speed:
%% a crash in the C library kills the port process, not the BEAM VM.
%%
%% Quick start:
%%
%%   {ok, Lib} = cffi_port:load("libm.so.6"),
%%   {ok, 2.0} = cffi_port:call(Lib, "sqrt", double, [{double, 4.0}]),
%%
%%   Ptr = cffi_port:alloc(Lib, 16),
%%   ok  = cffi_port:write(Ptr, int32, 42),
%%   42  = cffi_port:read(Ptr, int32),
%%   ok  = cffi_port:free(Ptr).
%%
%% Key differences from cffi.erl:
%%   - alloc/2 takes the Lib handle (to know which port process to use)
%%   - Pointers are {port_ptr, Pid, Addr} — opaque, not NIF resources
%%   - Library handles are {port_lib, Pid, Handle} tuples
%%   - One OS process per cffi_port:load/1 call (isolated per library)
%%   - If the port crashes: call returns {error, port_crashed}
%%
%% Type resolution (enum/typedef) is handled the same as cffi.erl via cffi_type.

-module(cffi_port).
-behaviour(gen_server).

%% Public API
-export([
    load/1, close/1,
    lib_pid/1, lib_port/1,
    call/3, call/4, call_va/5,
    alloc/2, alloc_type/2, alloc_type/3, alloc_struct/2,
    free/1,
    read/2, write/3,
    read_bytes/2, write_bytes/2,
    ptr_add/2, null/1, is_null/1,
    field_ptr/3,
    struct_read/3, struct_write/4,
    struct_to_map/2, map_to_struct/3,
    array_ptr/3, array_read/3, array_write/4,
    with_alloc/3, with_alloc/4
]).

%% gen_server
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

%% -------------------------------------------------------------------------
%% Wire protocol constants (must match cffi_port.c)
%% -------------------------------------------------------------------------

-define(OP_LOAD_LIB,    1).
-define(OP_CALL,        2).
-define(OP_ALLOC,       3).
-define(OP_FREE,        4).
-define(OP_READ,        5).
-define(OP_WRITE,       6).
-define(OP_READ_BYTES,  7).
-define(OP_WRITE_BYTES, 8).
-define(OP_CALL_VA,     9).

-define(PT_VOID,    0).
-define(PT_INT8,    1).
-define(PT_UINT8,   2).
-define(PT_INT16,   3).
-define(PT_UINT16,  4).
-define(PT_INT32,   5).
-define(PT_UINT32,  6).
-define(PT_INT64,   7).
-define(PT_UINT64,  8).
-define(PT_FLOAT,   9).
-define(PT_DOUBLE,  10).
-define(PT_POINTER, 11).
-define(PT_STRING,  12).
-define(PT_BOOL,    13).

-define(STATUS_OK,  0).
-define(STATUS_ERR, 1).

%% -------------------------------------------------------------------------
%% State
%% -------------------------------------------------------------------------

-record(state, {
    port    :: port(),
    seq     :: non_neg_integer(),
    %% {From, SeqNum, RespKind}  where RespKind = typed | raw_bytes
    waiting :: undefined | {gen_server:from(), non_neg_integer(), typed | raw_bytes}
}).

-type port_lib() :: {port_lib, pid(), non_neg_integer()}.
-type port_ptr() :: {port_ptr, pid(), non_neg_integer()}.

%% -------------------------------------------------------------------------
%% Public API
%% -------------------------------------------------------------------------

%% load/1 — starts a dedicated port process for this library.
-spec load(string() | binary()) -> {ok, port_lib()} | {error, term()}.
load(Path) ->
    case gen_server:start(?MODULE, [], []) of
        {ok, Pid} ->
            case gen_server:call(Pid, {load_lib, to_list(Path)}, 30000) of
                {ok, Handle} -> {ok, {port_lib, Pid, Handle}};
                {error, _} = Err -> gen_server:stop(Pid), Err
            end;
        {error, _} = Err -> Err
    end.

%% close/1 — stop the gen_server (and the port subprocess).
-spec close(port_lib()) -> ok.
close({port_lib, Pid, _}) ->
    gen_server:stop(Pid).

%% lib_pid/1, lib_port/1 — introspection helpers (mainly for tests).
-spec lib_pid(port_lib()) -> pid().
lib_pid({port_lib, Pid, _}) -> Pid.

-spec lib_port(port_lib()) -> port().
lib_port({port_lib, Pid, _}) ->
    gen_server:call(Pid, get_port, 5000).

-spec call(port_lib(), string() | binary(), term()) ->
    {ok, term()} | {error, term()}.
call(Lib, Func, RetType) ->
    call(Lib, Func, RetType, []).

-spec call(port_lib(), string() | binary(), term(), list()) ->
    {ok, term()} | {error, term()}.
call({port_lib, Pid, Handle}, Func, RetType, Args) ->
    NifRetType = resolve_type(RetType),
    NifArgs    = [resolve_arg(A) || A <- Args],
    Req = {call, Handle, to_list(Func), NifRetType, NifArgs},
    try gen_server:call(Pid, Req, 30000) of
        {ok, Val} -> {ok, unmarshal_ret(Pid, RetType, Val)};
        Err       -> Err
    catch
        exit:{noproc, _}  -> {error, port_crashed};
        exit:{normal, _}  -> {error, port_crashed};
        exit:{{port_crashed, _}, _} -> {error, port_crashed}
    end.

%% call_va/5 — variadic C function call (port safe mode).
%%
%%   NFixed: count of fixed (non-variadic) arguments.
%%   Variadic float args are promoted to double automatically.
-spec call_va(port_lib(), string() | binary(), term(), pos_integer(), list()) ->
    {ok, term()} | {error, term()}.
call_va({port_lib, Pid, Handle}, Func, RetType, NFixed, Args)
  when is_integer(NFixed), NFixed >= 1 ->
    NifRetType = resolve_type(RetType),
    NifArgs    = [resolve_arg(A) || A <- Args],
    Req = {call_va, Handle, to_list(Func), NifRetType, NFixed, NifArgs},
    try gen_server:call(Pid, Req, 30000) of
        {ok, Val} -> {ok, unmarshal_ret(Pid, RetType, Val)};
        Err       -> Err
    catch
        exit:{noproc, _}             -> {error, port_crashed};
        exit:{normal, _}             -> {error, port_crashed};
        exit:{{port_crashed, _}, _}  -> {error, port_crashed}
    end.

-spec alloc(port_lib(), pos_integer()) -> port_ptr().
alloc({port_lib, Pid, _}, Bytes) when is_integer(Bytes), Bytes > 0 ->
    {ok, Addr} = gen_server:call(Pid, {alloc, Bytes}, 10000),
    {port_ptr, Pid, Addr}.

-spec alloc_type(port_lib(), term()) -> port_ptr().
alloc_type(Lib, Type) -> alloc_type(Lib, Type, 1).

-spec alloc_type(port_lib(), term(), pos_integer()) -> port_ptr().
alloc_type(Lib, Type, Count) ->
    alloc(Lib, cffi_type:sizeof(Type) * Count).

-spec alloc_struct(port_lib(), atom()) -> port_ptr().
alloc_struct(Lib, StructName) ->
    alloc(Lib, cffi_type:sizeof(StructName)).

-spec free(port_ptr()) -> ok.
free({port_ptr, Pid, Addr}) ->
    gen_server:call(Pid, {free, Addr}, 10000).

-spec read(port_ptr(), term()) -> term().
read({port_ptr, Pid, Addr} = Ptr, Type) ->
    case cffi_type:lookup(resolve_typedef(Type)) of
        not_found ->
            {ok, Val} = gen_server:call(Pid, {read, Addr, type_code(Type)}, 10000),
            Val;
        {enum, _, ToAtom} ->
            {ok, Int} = gen_server:call(Pid, {read, Addr, ?PT_INT32}, 10000),
            maps:get(Int, ToAtom, Int);
        {struct, _, _, _} -> Ptr;
        {union,  _, _, _} -> Ptr;
        {typedef, Inner}  -> read(Ptr, Inner)
    end.

-spec write(port_ptr(), term(), term()) -> ok.
write({port_ptr, Pid, Addr} = Ptr, Type, Value) ->
    case cffi_type:lookup(resolve_typedef(Type)) of
        not_found ->
            gen_server:call(Pid, {write, Addr, type_code(Type), Value}, 10000);
        {enum, ToInt, _} ->
            Int = case Value of
                A when is_atom(A)    ->
                    case maps:find(A, ToInt) of
                        {ok, V} -> V;
                        error   -> error({bad_enum_value, Type, A})
                    end;
                N when is_integer(N) -> N
            end,
            gen_server:call(Pid, {write, Addr, ?PT_INT32, Int}, 10000);
        {typedef, Inner} ->
            write(Ptr, Inner, Value)
    end.

-spec read_bytes(port_ptr(), pos_integer()) -> binary().
read_bytes({port_ptr, Pid, Addr}, Size) ->
    {ok, Data} = gen_server:call(Pid, {read_bytes, Addr, Size}, 10000),
    Data.

-spec write_bytes(port_ptr(), binary()) -> ok.
write_bytes({port_ptr, Pid, Addr}, Bytes) ->
    gen_server:call(Pid, {write_bytes, Addr, Bytes}, 10000).

-spec ptr_add(port_ptr(), integer()) -> port_ptr().
ptr_add({port_ptr, Pid, Addr}, Offset) ->
    {port_ptr, Pid, Addr + Offset}.

-spec null(port_lib()) -> port_ptr().
null({port_lib, Pid, _}) -> {port_ptr, Pid, 0}.

-spec is_null(port_ptr()) -> boolean().
is_null({port_ptr, _, 0})   -> true;
is_null({port_ptr, _, _})   -> false.

%% -------------------------------------------------------------------------
%% Struct / union field access  (same logic as cffi.erl, uses local ops)
%% -------------------------------------------------------------------------

-spec field_ptr(port_ptr(), atom(), atom()) -> port_ptr().
field_ptr(Ptr, TypeName, FieldName) ->
    case cffi_type:field_info(TypeName, FieldName) of
        {_Type, Offset} -> ptr_add(Ptr, Offset);
        not_found       -> error({unknown_field, TypeName, FieldName})
    end.

-spec struct_read(port_ptr(), atom(), atom()) -> term().
struct_read(Ptr, TypeName, FieldName) ->
    case cffi_type:field_info(TypeName, FieldName) of
        {FType, Offset} -> read(ptr_add(Ptr, Offset), FType);
        not_found       -> error({unknown_field, TypeName, FieldName})
    end.

-spec struct_write(port_ptr(), atom(), atom(), term()) -> ok.
struct_write(Ptr, TypeName, FieldName, Value) ->
    case cffi_type:field_info(TypeName, FieldName) of
        {FType, Offset} -> write(ptr_add(Ptr, Offset), FType, Value);
        not_found       -> error({unknown_field, TypeName, FieldName})
    end.

-spec struct_to_map(port_ptr(), atom()) -> map().
struct_to_map(Ptr, TypeName) ->
    Fields = struct_fields(TypeName),
    maps:from_list([{FName, read(ptr_add(Ptr, Off), FType)}
                    || {FName, FType, Off} <- Fields]).

-spec map_to_struct(port_ptr(), atom(), map()) -> ok.
map_to_struct(Ptr, TypeName, Map) ->
    Fields = struct_fields(TypeName),
    lists:foreach(fun({FName, FType, Off}) ->
        case maps:find(FName, Map) of
            {ok, V} -> write(ptr_add(Ptr, Off), FType, V);
            error   -> ok
        end
    end, Fields).

%% -------------------------------------------------------------------------
%% Array access
%% -------------------------------------------------------------------------

-spec array_ptr(port_ptr(), term(), non_neg_integer()) -> port_ptr().
array_ptr(Ptr, ElemType, Index) ->
    ptr_add(Ptr, cffi_type:sizeof(ElemType) * Index).

-spec array_read(port_ptr(), term(), non_neg_integer()) -> term().
array_read(Ptr, ElemType, Index) ->
    read(array_ptr(Ptr, ElemType, Index), ElemType).

-spec array_write(port_ptr(), term(), non_neg_integer(), term()) -> ok.
array_write(Ptr, ElemType, Index, Value) ->
    write(array_ptr(Ptr, ElemType, Index), ElemType, Value).

%% -------------------------------------------------------------------------
%% Scoped allocation
%% -------------------------------------------------------------------------

-spec with_alloc(port_lib(), pos_integer(), fun((port_ptr()) -> R)) -> R.
with_alloc(Lib, Bytes, Fun) ->
    Ptr = alloc(Lib, Bytes),
    try Fun(Ptr)
    after free(Ptr)
    end.

-spec with_alloc(port_lib(), term(), pos_integer(), fun((port_ptr()) -> R)) -> R.
with_alloc(Lib, Type, Count, Fun) ->
    with_alloc(Lib, cffi_type:sizeof(Type) * Count, Fun).

%% -------------------------------------------------------------------------
%% gen_server callbacks
%% -------------------------------------------------------------------------

init([]) ->
    PrivDir = code:priv_dir(cffi),
    Exe = filename:join(PrivDir, "cffi_port"),
    Port = open_port({spawn_executable, Exe},
                     [{packet, 4}, binary, exit_status, use_stdio]),
    {ok, #state{port = Port, seq = 0, waiting = undefined}}.

handle_call(get_port, _From, S) ->
    {reply, S#state.port, S};

handle_call(Req, From, #state{waiting = undefined} = S) ->
    {Payload, Kind, S1} = encode_request(Req, S),
    port_command(S1#state.port, Payload),
    SeqNum = S#state.seq,
    {noreply, S1#state{waiting = {From, SeqNum, Kind}}};

handle_call(Req, From, #state{waiting = _} = S) ->
    %% Serialise: queue by re-enqueueing after a tiny delay.
    %% For production use, a proper queue would be better.
    erlang:send_after(1, self(), {retry, Req, From}),
    {noreply, S}.

handle_cast(_Msg, S) -> {noreply, S}.

handle_info({Port, {data, Data}},
            #state{port = Port, waiting = {From, _Seq, Kind}} = S) ->
    Result = case Kind of
        raw_bytes -> decode_raw_response(Data);
        typed     -> decode_response(Data)
    end,
    gen_server:reply(From, Result),
    {noreply, S#state{waiting = undefined}};

handle_info({retry, Req, From}, S) ->
    %% Retry after previous request completed
    handle_call(Req, From, S);

handle_info({Port, {exit_status, Status}}, #state{port = Port, waiting = W} = S) ->
    case W of
        {From, _, _} -> gen_server:reply(From, {error, {port_crashed, Status}});
        undefined    -> ok
    end,
    {stop, {port_crashed, Status}, S#state{waiting = undefined}};

handle_info({'EXIT', Port, Reason}, #state{port = Port, waiting = W} = S) ->
    case W of
        {From, _, _} -> gen_server:reply(From, {error, {port_exited, Reason}});
        undefined    -> ok
    end,
    {stop, {port_exited, Reason}, S#state{waiting = undefined}};

handle_info(_Info, S) -> {noreply, S}.

terminate(_Reason, #state{port = Port}) ->
    catch port_close(Port),
    ok.

code_change(_OldVsn, S, _Extra) -> {ok, S}.

%% -------------------------------------------------------------------------
%% Request encoding
%% -------------------------------------------------------------------------

encode_request({load_lib, Path}, S) ->
    PBin = list_to_binary(Path),
    Len  = byte_size(PBin),
    Payload = <<(S#state.seq):32, ?OP_LOAD_LIB:8, Len:16, PBin/binary>>,
    {Payload, typed, S#state{seq = S#state.seq + 1}};

encode_request({call, Handle, FuncName, RetType, Args}, S) ->
    FBin  = list_to_binary(FuncName),
    FLen  = byte_size(FBin),
    Nargs = length(Args),
    ArgsBin = iolist_to_binary([encode_typed(T, V) || {T, V} <- Args]),
    RetCode = type_code(RetType),
    Payload = <<(S#state.seq):32, ?OP_CALL:8,
                Handle:64, FLen:16, FBin/binary,
                RetCode:8, Nargs:16, ArgsBin/binary>>,
    {Payload, typed, S#state{seq = S#state.seq + 1}};

encode_request({call_va, Handle, FuncName, RetType, NFixed, Args}, S) ->
    FBin    = list_to_binary(FuncName),
    FLen    = byte_size(FBin),
    Nargs   = length(Args),
    ArgsBin = iolist_to_binary([encode_typed(T, V) || {T, V} <- Args]),
    RetCode = type_code(RetType),
    Payload = <<(S#state.seq):32, ?OP_CALL_VA:8,
                Handle:64, FLen:16, FBin/binary,
                RetCode:8, NFixed:16, Nargs:16, ArgsBin/binary>>,
    {Payload, typed, S#state{seq = S#state.seq + 1}};

encode_request({alloc, Bytes}, S) ->
    Payload = <<(S#state.seq):32, ?OP_ALLOC:8, Bytes:64>>,
    {Payload, typed, S#state{seq = S#state.seq + 1}};

encode_request({free, Addr}, S) ->
    Payload = <<(S#state.seq):32, ?OP_FREE:8, Addr:64>>,
    {Payload, typed, S#state{seq = S#state.seq + 1}};

encode_request({read, Addr, TypeCode}, S) ->
    Payload = <<(S#state.seq):32, ?OP_READ:8, Addr:64, TypeCode:8>>,
    {Payload, typed, S#state{seq = S#state.seq + 1}};

encode_request({write, Addr, TypeCode, Value}, S) ->
    ValBin = encode_value(TypeCode, Value),
    Payload = <<(S#state.seq):32, ?OP_WRITE:8, Addr:64, TypeCode:8, ValBin/binary>>,
    {Payload, typed, S#state{seq = S#state.seq + 1}};

encode_request({read_bytes, Addr, Size}, S) ->
    Payload = <<(S#state.seq):32, ?OP_READ_BYTES:8, Addr:64, Size:32>>,
    {Payload, raw_bytes, S#state{seq = S#state.seq + 1}};

encode_request({write_bytes, Addr, Bytes}, S) ->
    Len = byte_size(Bytes),
    Payload = <<(S#state.seq):32, ?OP_WRITE_BYTES:8, Addr:64, Len:32, Bytes/binary>>,
    {Payload, typed, S#state{seq = S#state.seq + 1}}.

%% Encode {TypeAtom, Value} as <<TypeCode:8, ValueBytes>>
encode_typed(Type, Value) ->
    Code = type_code(Type),
    <<Code:8, (encode_value(Code, Value))/binary>>.

encode_value(?PT_VOID,    _)     -> <<>>;
encode_value(?PT_BOOL,    true)  -> <<1:8>>;
encode_value(?PT_BOOL,    false) -> <<0:8>>;
encode_value(?PT_BOOL,    N)     -> <<(N band 1):8>>;
encode_value(?PT_INT8,    V)     -> <<V:8/signed>>;
encode_value(?PT_UINT8,   V)     -> <<V:8/unsigned>>;
encode_value(?PT_INT16,   V)     -> <<V:16/signed-big>>;
encode_value(?PT_UINT16,  V)     -> <<V:16/unsigned-big>>;
encode_value(?PT_INT32,   V)     -> <<V:32/signed-big>>;
encode_value(?PT_UINT32,  V)     -> <<V:32/unsigned-big>>;
encode_value(?PT_INT64,   V)     -> <<V:64/signed-big>>;
encode_value(?PT_UINT64,  V)     -> <<V:64/unsigned-big>>;
encode_value(?PT_FLOAT,   V)     -> <<V:32/float-big>>;
encode_value(?PT_DOUBLE,  V)     -> <<V:64/float-big>>;
encode_value(?PT_POINTER, null)  -> <<0:64>>;
encode_value(?PT_POINTER, {port_ptr, _, Addr}) -> <<Addr:64>>;
encode_value(?PT_STRING,  null)  -> <<16#FFFFFFFF:32>>;
encode_value(?PT_STRING,  B) when is_binary(B) -> <<(byte_size(B)):32, B/binary>>;
encode_value(?PT_STRING,  L) when is_list(L)   ->
    B = list_to_binary(L), <<(byte_size(B)):32, B/binary>>.

%% -------------------------------------------------------------------------
%% Response decoding
%% -------------------------------------------------------------------------

decode_response(<<_Seq:32, ?STATUS_ERR:8, Msg/binary>>) ->
    {error, Msg};
decode_response(<<_Seq:32, ?STATUS_OK:8>>) ->
    ok;
decode_response(<<_Seq:32, ?STATUS_OK:8, Handle:64>>) ->
    {ok, Handle};
decode_response(<<_Seq:32, ?STATUS_OK:8, TypeCode:8, Rest/binary>>) ->
    {ok, decode_typed(TypeCode, Rest)};
decode_response(<<_Seq:32, ?STATUS_OK:8, Data/binary>>) ->
    {ok, Data}.

%% raw_bytes: the C op_read_bytes sends <<seq:32, STATUS_OK:8, data...>>
%% The raw data must NOT be interpreted as a typed value.
decode_raw_response(<<_Seq:32, ?STATUS_ERR:8, Msg/binary>>) ->
    {error, Msg};
decode_raw_response(<<_Seq:32, ?STATUS_OK:8, Data/binary>>) ->
    {ok, Data}.

decode_typed(?PT_VOID,    _)                                        -> ok;
decode_typed(?PT_BOOL,    <<V:8, _/binary>>)                        -> V =/= 0;
decode_typed(?PT_INT8,    <<V:8/signed, _/binary>>)                 -> V;
decode_typed(?PT_UINT8,   <<V:8/unsigned, _/binary>>)               -> V;
decode_typed(?PT_INT16,   <<V:16/signed-big, _/binary>>)            -> V;
decode_typed(?PT_UINT16,  <<V:16/unsigned-big, _/binary>>)          -> V;
decode_typed(?PT_INT32,   <<V:32/signed-big, _/binary>>)            -> V;
decode_typed(?PT_UINT32,  <<V:32/unsigned-big, _/binary>>)          -> V;
decode_typed(?PT_INT64,   <<V:64/signed-big, _/binary>>)            -> V;
decode_typed(?PT_UINT64,  <<V:64/unsigned-big, _/binary>>)          -> V;
decode_typed(?PT_FLOAT,   <<V:32/float-big, _/binary>>)             -> V;
decode_typed(?PT_DOUBLE,  <<V:64/float-big, _/binary>>)             -> V;
decode_typed(?PT_POINTER, <<0:64, _/binary>>)                       -> null;
decode_typed(?PT_POINTER, <<Addr:64/unsigned-big, _/binary>>)       -> {raw_ptr, Addr};
decode_typed(?PT_STRING,  <<16#FFFFFFFF:32/unsigned-big, _/binary>>) -> null;
decode_typed(?PT_STRING,  <<Len:32/unsigned-big, Data:Len/bytes, _/binary>>) -> Data;
decode_typed(_, _)                                                  -> undefined.

%% -------------------------------------------------------------------------
%% Type helpers (enum/typedef resolution, same logic as cffi.erl)
%% -------------------------------------------------------------------------

type_code(void)    -> ?PT_VOID;
type_code(bool)    -> ?PT_BOOL;
type_code(int8)    -> ?PT_INT8;
type_code(uint8)   -> ?PT_UINT8;
type_code(int16)   -> ?PT_INT16;
type_code(uint16)  -> ?PT_UINT16;
type_code(int32)   -> ?PT_INT32;
type_code(uint32)  -> ?PT_UINT32;
type_code(int64)   -> ?PT_INT64;
type_code(uint64)  -> ?PT_UINT64;
type_code(float)   -> ?PT_FLOAT;
type_code(double)  -> ?PT_DOUBLE;
type_code(pointer) -> ?PT_POINTER;
type_code(string)  -> ?PT_STRING;
type_code(T) ->
    case cffi_type:lookup(T) of
        {enum, _, _}    -> ?PT_INT32;
        {typedef, Inner} -> type_code(Inner);
        _               -> ?PT_POINTER   %% structs/unions passed as pointer
    end.

resolve_typedef(T) when is_atom(T) ->
    case cffi_type:lookup(T) of
        {typedef, Inner} -> resolve_typedef(Inner);
        _                -> T
    end;
resolve_typedef(T) -> T.

resolve_type(Type) ->
    case resolve_typedef(Type) of
        T when is_atom(T) ->
            case cffi_type:lookup(T) of
                {enum, _, _}     -> int32;
                {typedef, Inner} -> resolve_type(Inner);
                _                -> T
            end;
        T -> T
    end.

resolve_arg({Type, Value}) ->
    NifType = resolve_type(Type),
    NifVal  = case cffi_type:lookup(resolve_typedef(Type)) of
        {enum, ToInt, _} when is_atom(Value) ->
            case maps:find(Value, ToInt) of
                {ok, V} -> V;
                error   -> error({bad_enum_value, Type, Value})
            end;
        _ -> Value
    end,
    {NifType, NifVal}.

unmarshal_ret(Pid, RetType, Val) ->
    case cffi_type:lookup(resolve_typedef(RetType)) of
        {enum, _, ToAtom} when is_integer(Val) ->
            maps:get(Val, ToAtom, Val);
        {typedef, Inner} ->
            unmarshal_ret(Pid, Inner, Val);
        _ ->
            %% Wrap raw pointer addresses returned by C as port_ptr
            case Val of
                {raw_ptr, Addr} -> {port_ptr, Pid, Addr};
                Other           -> Other
            end
    end.

struct_fields(TypeName) ->
    case cffi_type:lookup(TypeName) of
        {struct, _, _, Fields} -> Fields;
        {union,  _, _, Fields} -> Fields;
        not_found -> error({unknown_type, TypeName})
    end.

to_list(S) when is_list(S)   -> S;
to_list(B) when is_binary(B) -> binary_to_list(B).

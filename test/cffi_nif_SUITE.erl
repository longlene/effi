%% cffi_nif_SUITE.erl — Common Test suite for NIF mode (cffi / cffi_nif).
%%
%% Covers:
%%   t_load            — cffi:load/1, bad path
%%   t_call_math       — cffi:call/4 with libm (sqrt, pow, floor)
%%   t_call_void       — void return type
%%   t_alloc_rw        — alloc/free, read/write for all integer/float types
%%   t_ptr_null        — null/0, is_null/1, ptr_add/2
%%   t_read_write_bytes — read_bytes/write_bytes round-trip
%%   t_typedef         — defctype / typedef alias resolution in calls
%%   t_enum            — defcenum, read/write enum atoms, bad atom error
%%   t_struct          — defcstruct, field layout, struct_read/write, struct_to_map
%%   t_union           — defcunion, overlapping fields
%%   t_nested_struct   — struct with a struct field
%%   t_array           — array_read/write, array_ptr
%%   t_with_alloc      — with_alloc/2,3 scope management
%%   t_callback        — C→Erlang callback via cffi_callback (qsort)
%%   t_varargs         — cffi:call_va/5 with snprintf

-module(cffi_nif_SUITE).
-compile([export_all, nowarn_export_all]).
-include_lib("common_test/include/ct.hrl").

all() ->
    [t_load, t_call_math, t_call_void, t_alloc_rw,
     t_ptr_null, t_read_write_bytes,
     t_typedef, t_enum, t_struct, t_union, t_nested_struct,
     t_array, t_with_alloc, t_callback, t_varargs].

init_per_suite(Config) -> Config.
end_per_suite(_Config) -> ok.

%% The cffi_type ETS table is owned by the process that creates it.
%% CT runs init_per_testcase and the test case function in the SAME
%% process, so types registered here are visible throughout the case.
init_per_testcase(_TC, Config) ->
    _ = cffi:defctype(my_double, double),
    _ = cffi:defctype(real, my_double),
    _ = cffi:defcenum(color, [red, green, blue]),
    _ = cffi:defcstruct(point2d, [{x, double}, {y, double}]),
    _ = cffi:defcunion(int_or_float, [{i, int32}, {f, float}]),
    _ = cffi:defcstruct(rect, [{tl, point2d}, {br, point2d}]),
    Config.

end_per_testcase(_TC, _Config) -> ok.

%% -------------------------------------------------------------------------
%% t_load
%% -------------------------------------------------------------------------

t_load(_Config) ->
    {ok, Lib} = cffi:load("libm.so.6"),
    true = is_reference(Lib),
    {error, _} = cffi:load("/no/such/lib.so").

%% -------------------------------------------------------------------------
%% t_call_math — primitive calls against libm
%% -------------------------------------------------------------------------

t_call_math(_Config) ->
    {ok, Lib} = cffi:load("libm.so.6"),
    {ok, 2.0} = cffi:call(Lib, "sqrt",  double, [{double, 4.0}]),
    {ok, 8.0} = cffi:call(Lib, "pow",   double, [{double, 2.0}, {double, 3.0}]),
    {ok, 3.0} = cffi:call(Lib, "floor", double, [{double, 3.7}]),
    {error, {not_found, _}} = cffi:call(Lib, "no_such_fn", double, []).

%% -------------------------------------------------------------------------
%% t_call_void — void return: cffi:call always returns {ok, Val};
%%               for void functions Val is the atom ok.
%% -------------------------------------------------------------------------

t_call_void(_Config) ->
    {ok, Libc} = cffi:load("libc.so.6"),
    %% malloc → valid pointer
    {ok, Ptr} = cffi:call(Libc, "malloc", pointer, [{uint64, 16}]),
    false = cffi:is_null(Ptr),
    %% free the pointer via libc's free; void return → {ok, ok}
    {ok, ok} = cffi:call(Libc, "free", void, [{pointer, Ptr}]).

%% -------------------------------------------------------------------------
%% t_alloc_rw — read/write for every primitive type
%% -------------------------------------------------------------------------

t_alloc_rw(_Config) ->
    Cases = [
        {int8,   -42},
        {uint8,  200},
        {int16,  -1000},
        {uint16, 60000},
        {int32,  -100000},
        {uint32, 3000000000},
        {int64,  -9000000000000},
        {uint64, 18000000000000000000},
        {float,  1.5},    %% exact in float32
        {double, 3.14159265358979}
    ],
    lists:foreach(fun({Type, Val}) ->
        Ptr = cffi:alloc(8),
        ok  = cffi:write(Ptr, Type, Val),
        Got = cffi:read(Ptr, Type),
        case Type of
            float  -> true = abs(Got - Val) < 1.0e-5;
            double -> true = abs(Got - Val) < 1.0e-10;
            _      -> Got = Val
        end,
        cffi:free(Ptr)
    end, Cases).

%% -------------------------------------------------------------------------
%% t_ptr_null
%% -------------------------------------------------------------------------

t_ptr_null(_Config) ->
    Null  = cffi:null(),
    true  = cffi:is_null(Null),
    Ptr   = cffi:alloc(8),
    false = cffi:is_null(Ptr),
    Ptr2  = cffi:ptr_add(Ptr, 4),
    false = cffi:is_null(Ptr2),
    cffi:free(Ptr).

%% -------------------------------------------------------------------------
%% t_read_write_bytes
%% -------------------------------------------------------------------------

t_read_write_bytes(_Config) ->
    Data = <<"hello, world!">>,
    Ptr  = cffi:alloc(byte_size(Data)),
    ok   = cffi:write_bytes(Ptr, Data),
    Data = cffi:read_bytes(Ptr, byte_size(Data)),
    cffi:free(Ptr).

%% -------------------------------------------------------------------------
%% t_typedef — typedef aliases are transparent in call/read/write
%% -------------------------------------------------------------------------

t_typedef(_Config) ->
    %% Types defined in init_per_suite: my_double → double, real → my_double
    {ok, Lib} = cffi:load("libm.so.6"),
    {ok, 2.0} = cffi:call(Lib, "sqrt", real, [{real, 4.0}]),
    Ptr = cffi:alloc(8),
    ok  = cffi:write(Ptr, real, 1.5),
    1.5 = cffi:read(Ptr, real),
    cffi:free(Ptr).

%% -------------------------------------------------------------------------
%% t_enum — defcenum, atom↔int marshaling
%% -------------------------------------------------------------------------

t_enum(_Config) ->
    %% color enum defined in init_per_suite
    Ptr = cffi:alloc(4),
    ok    = cffi:write(Ptr, color, green),
    green = cffi:read(Ptr, color),
    %% Integer write, atom read back
    ok   = cffi:write(Ptr, color, 2),
    blue = cffi:read(Ptr, color),
    %% Bad atom → error/1 raised
    {'EXIT', {{bad_enum_value, color, purple}, _}} =
        (catch cffi:write(Ptr, color, purple)),
    cffi:free(Ptr).

%% -------------------------------------------------------------------------
%% t_struct — layout, field access, struct_to_map / map_to_struct
%% -------------------------------------------------------------------------

t_struct(_Config) ->
    %% point2d defined in init_per_suite
    16 = cffi:type_size(point2d),
    8  = cffi:align_of(point2d),

    Ptr = cffi:alloc_struct(point2d),
    ok  = cffi:struct_write(Ptr, point2d, x, 1.5),
    ok  = cffi:struct_write(Ptr, point2d, y, 2.5),
    1.5 = cffi:struct_read(Ptr, point2d, x),
    2.5 = cffi:struct_read(Ptr, point2d, y),

    #{x := 1.5, y := 2.5} = cffi:struct_to_map(Ptr, point2d),

    ok   = cffi:map_to_struct(Ptr, point2d, #{x => 0.0, y => -1.0}),
    X0   = cffi:struct_read(Ptr, point2d, x),
    true = abs(X0) < 1.0e-15,
    -1.0 = cffi:struct_read(Ptr, point2d, y),
    cffi:free(Ptr).

%% -------------------------------------------------------------------------
%% t_union — overlapping fields share the same address
%% -------------------------------------------------------------------------

t_union(_Config) ->
    %% int_or_float defined in init_per_suite
    4 = cffi:type_size(int_or_float),
    Ptr = cffi:alloc(4),
    ok = cffi:struct_write(Ptr, int_or_float, i, 42),
    42 = cffi:struct_read(Ptr, int_or_float, i),
    cffi:free(Ptr).

%% -------------------------------------------------------------------------
%% t_nested_struct — struct with a struct-typed field
%% -------------------------------------------------------------------------

t_nested_struct(_Config) ->
    %% rect defined in init_per_suite; depends on point2d
    32 = cffi:type_size(rect),    %% 2 × point2d(16)

    Ptr   = cffi:alloc_struct(rect),
    TlPtr = cffi:field_ptr(Ptr, rect, tl),
    BrPtr = cffi:field_ptr(Ptr, rect, br),

    ok = cffi:struct_write(TlPtr, point2d, x, 0.0),
    ok = cffi:struct_write(TlPtr, point2d, y, 0.0),
    ok = cffi:struct_write(BrPtr, point2d, x, 10.0),
    ok = cffi:struct_write(BrPtr, point2d, y, 20.0),

    10.0 = cffi:struct_read(BrPtr, point2d, x),
    20.0 = cffi:struct_read(BrPtr, point2d, y),
    cffi:free(Ptr).

%% -------------------------------------------------------------------------
%% t_array — array_ptr/read/write
%% -------------------------------------------------------------------------

t_array(_Config) ->
    N   = 5,
    Ptr = cffi:alloc_type(int32, N),
    lists:foreach(fun(I) ->
        ok = cffi:array_write(Ptr, int32, I, I * I)
    end, lists:seq(0, N - 1)),
    Squares = [cffi:array_read(Ptr, int32, I) || I <- lists:seq(0, N - 1)],
    [0, 1, 4, 9, 16] = Squares,
    cffi:free(Ptr).

%% -------------------------------------------------------------------------
%% t_with_alloc — scoped allocation; pointer freed after block
%% -------------------------------------------------------------------------

t_with_alloc(_Config) ->
    12345 = cffi:with_alloc(8, fun(Ptr) ->
        ok = cffi:write(Ptr, int64, 12345),
        cffi:read(Ptr, int64)
    end),
    3.0 = cffi:with_alloc(double, 3, fun(Ptr) ->
        [cffi:array_write(Ptr, double, I, float(I)) || I <- [0, 1, 2]],
        lists:sum([cffi:array_read(Ptr, double, I) || I <- [0, 1, 2]])
    end).

%% -------------------------------------------------------------------------
%% t_callback — C→Erlang callback: qsort with a comparator
%% -------------------------------------------------------------------------

t_callback(_Config) ->
    {ok, Libc} = cffi:load("libc.so.6"),

    Vals = [5, 3, 8, 1, 2],
    N    = length(Vals),
    Arr  = cffi:alloc_type(int32, N),
    lists:foreach(fun({I, V}) -> cffi:array_write(Arr, int32, I, V)
                  end, lists:zip(lists:seq(0, N - 1), Vals)),

    %% Comparator: (const void*, const void*) → int  (pointers to int32)
    {ok, Cb} = cffi_callback:new(int32, [pointer, pointer],
        fun(PA, PB) ->
            A = cffi:read(PA, int32),
            B = cffi:read(PB, int32),
            if A < B -> -1; A > B -> 1; true -> 0 end
        end),
    FnPtr = cffi_callback:func_ptr(Cb),

    {ok, ok} = cffi:call(Libc, "qsort", void,
                   [{pointer, Arr},
                    {uint64,  N},
                    {uint64,  4},     %% sizeof(int32)
                    {pointer, FnPtr}]),

    Sorted = [cffi:array_read(Arr, int32, I) || I <- lists:seq(0, N - 1)],
    [1, 2, 3, 5, 8] = Sorted,

    cffi_callback:free(Cb),
    cffi:free(Arr).

%% -------------------------------------------------------------------------
%% t_varargs — cffi:call_va/5 with snprintf
%% -------------------------------------------------------------------------

t_varargs(_Config) ->
    {ok, Libc} = cffi:load("libc.so.6"),
    Buf = cffi:alloc(64),

    {ok, 2} = cffi:call_va(Libc, "snprintf", int32, 3,
                  [{pointer, Buf}, {uint64, 64}, {string, "%d"}, {int32, 42}]),
    <<"42">> = trim_nul(cffi:read_bytes(Buf, 3)),

    {ok, 4} = cffi:call_va(Libc, "snprintf", int32, 3,
                  [{pointer, Buf}, {uint64, 64}, {string, "%.2f"}, {double, 3.14}]),
    <<"3.14">> = trim_nul(cffi:read_bytes(Buf, 5)),

    {ok, 5} = cffi:call_va(Libc, "snprintf", int32, 3,
                  [{pointer, Buf}, {uint64, 64}, {string, "%d+%d=%d"},
                   {int32, 1}, {int32, 2}, {int32, 3}]),
    <<"1+2=3">> = trim_nul(cffi:read_bytes(Buf, 6)),

    cffi:free(Buf).

%% -------------------------------------------------------------------------
%% Helpers
%% -------------------------------------------------------------------------

trim_nul(Bin) -> binary:part(Bin, 0, byte_size(Bin) - 1).

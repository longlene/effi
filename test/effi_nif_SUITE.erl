%% effi_nif_SUITE.erl — Common Test suite for NIF mode (effi / effi_nif).
%%
%% Covers:
%%   t_load            — effi:load/1, bad path
%%   t_call_math       — effi:call/4 with libm (sqrt, pow, floor)
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
%%   t_callback        — C→Erlang callback via effi_callback (qsort)
%%   t_varargs         — effi:call_va/5 with snprintf

-module(effi_nif_SUITE).
-compile([export_all, nowarn_export_all]).
-include_lib("common_test/include/ct.hrl").

all() ->
    [t_load, t_call_math, t_call_void, t_alloc_rw,
     t_ptr_null, t_read_write_bytes,
     t_typedef, t_enum, t_struct, t_union, t_nested_struct,
     t_array, t_with_alloc, t_callback, t_varargs].

init_per_suite(Config) -> Config.
end_per_suite(_Config) -> ok.

%% The effi_type ETS table is owned by the process that creates it.
%% CT runs init_per_testcase and the test case function in the SAME
%% process, so types registered here are visible throughout the case.
init_per_testcase(_TC, Config) ->
    _ = effi:defctype(my_double, double),
    _ = effi:defctype(real, my_double),
    _ = effi:defcenum(color, [red, green, blue]),
    _ = effi:defcstruct(point2d, [{x, double}, {y, double}]),
    _ = effi:defcunion(int_or_float, [{i, int32}, {f, float}]),
    _ = effi:defcstruct(rect, [{tl, point2d}, {br, point2d}]),
    Config.

end_per_testcase(_TC, _Config) -> ok.

%% -------------------------------------------------------------------------
%% t_load
%% -------------------------------------------------------------------------

t_load(_Config) ->
    {ok, Lib} = effi:load("libm.so.6"),
    true = is_reference(Lib),
    {error, _} = effi:load("/no/such/lib.so").

%% -------------------------------------------------------------------------
%% t_call_math — primitive calls against libm
%% -------------------------------------------------------------------------

t_call_math(_Config) ->
    {ok, Lib} = effi:load("libm.so.6"),
    {ok, 2.0} = effi:call(Lib, "sqrt",  double, [{double, 4.0}]),
    {ok, 8.0} = effi:call(Lib, "pow",   double, [{double, 2.0}, {double, 3.0}]),
    {ok, 3.0} = effi:call(Lib, "floor", double, [{double, 3.7}]),
    {error, {not_found, _}} = effi:call(Lib, "no_such_fn", double, []).

%% -------------------------------------------------------------------------
%% t_call_void — void return: effi:call always returns {ok, Val};
%%               for void functions Val is the atom ok.
%% -------------------------------------------------------------------------

t_call_void(_Config) ->
    {ok, Libc} = effi:load("libc.so.6"),
    %% malloc → valid pointer
    {ok, Ptr} = effi:call(Libc, "malloc", pointer, [{uint64, 16}]),
    false = effi:is_null(Ptr),
    %% free the pointer via libc's free; void return → {ok, ok}
    {ok, ok} = effi:call(Libc, "free", void, [{pointer, Ptr}]).

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
        Ptr = effi:alloc(8),
        ok  = effi:write(Ptr, Type, Val),
        Got = effi:read(Ptr, Type),
        case Type of
            float  -> true = abs(Got - Val) < 1.0e-5;
            double -> true = abs(Got - Val) < 1.0e-10;
            _      -> Got = Val
        end,
        effi:free(Ptr)
    end, Cases).

%% -------------------------------------------------------------------------
%% t_ptr_null
%% -------------------------------------------------------------------------

t_ptr_null(_Config) ->
    Null  = effi:null(),
    true  = effi:is_null(Null),
    Ptr   = effi:alloc(8),
    false = effi:is_null(Ptr),
    Ptr2  = effi:ptr_add(Ptr, 4),
    false = effi:is_null(Ptr2),
    effi:free(Ptr).

%% -------------------------------------------------------------------------
%% t_read_write_bytes
%% -------------------------------------------------------------------------

t_read_write_bytes(_Config) ->
    Data = <<"hello, world!">>,
    Ptr  = effi:alloc(byte_size(Data)),
    ok   = effi:write_bytes(Ptr, Data),
    Data = effi:read_bytes(Ptr, byte_size(Data)),
    effi:free(Ptr).

%% -------------------------------------------------------------------------
%% t_typedef — typedef aliases are transparent in call/read/write
%% -------------------------------------------------------------------------

t_typedef(_Config) ->
    %% Types defined in init_per_suite: my_double → double, real → my_double
    {ok, Lib} = effi:load("libm.so.6"),
    {ok, 2.0} = effi:call(Lib, "sqrt", real, [{real, 4.0}]),
    Ptr = effi:alloc(8),
    ok  = effi:write(Ptr, real, 1.5),
    1.5 = effi:read(Ptr, real),
    effi:free(Ptr).

%% -------------------------------------------------------------------------
%% t_enum — defcenum, atom↔int marshaling
%% -------------------------------------------------------------------------

t_enum(_Config) ->
    %% color enum defined in init_per_suite
    Ptr = effi:alloc(4),
    ok    = effi:write(Ptr, color, green),
    green = effi:read(Ptr, color),
    %% Integer write, atom read back
    ok   = effi:write(Ptr, color, 2),
    blue = effi:read(Ptr, color),
    %% Bad atom → error/1 raised
    {'EXIT', {{bad_enum_value, color, purple}, _}} =
        (catch effi:write(Ptr, color, purple)),
    effi:free(Ptr).

%% -------------------------------------------------------------------------
%% t_struct — layout, field access, struct_to_map / map_to_struct
%% -------------------------------------------------------------------------

t_struct(_Config) ->
    %% point2d defined in init_per_suite
    16 = effi:type_size(point2d),
    8  = effi:align_of(point2d),

    Ptr = effi:alloc_struct(point2d),
    ok  = effi:struct_write(Ptr, point2d, x, 1.5),
    ok  = effi:struct_write(Ptr, point2d, y, 2.5),
    1.5 = effi:struct_read(Ptr, point2d, x),
    2.5 = effi:struct_read(Ptr, point2d, y),

    #{x := 1.5, y := 2.5} = effi:struct_to_map(Ptr, point2d),

    ok   = effi:map_to_struct(Ptr, point2d, #{x => 0.0, y => -1.0}),
    X0   = effi:struct_read(Ptr, point2d, x),
    true = abs(X0) < 1.0e-15,
    -1.0 = effi:struct_read(Ptr, point2d, y),
    effi:free(Ptr).

%% -------------------------------------------------------------------------
%% t_union — overlapping fields share the same address
%% -------------------------------------------------------------------------

t_union(_Config) ->
    %% int_or_float defined in init_per_suite
    4 = effi:type_size(int_or_float),
    Ptr = effi:alloc(4),
    ok = effi:struct_write(Ptr, int_or_float, i, 42),
    42 = effi:struct_read(Ptr, int_or_float, i),
    effi:free(Ptr).

%% -------------------------------------------------------------------------
%% t_nested_struct — struct with a struct-typed field
%% -------------------------------------------------------------------------

t_nested_struct(_Config) ->
    %% rect defined in init_per_suite; depends on point2d
    32 = effi:type_size(rect),    %% 2 × point2d(16)

    Ptr   = effi:alloc_struct(rect),
    TlPtr = effi:field_ptr(Ptr, rect, tl),
    BrPtr = effi:field_ptr(Ptr, rect, br),

    ok = effi:struct_write(TlPtr, point2d, x, 0.0),
    ok = effi:struct_write(TlPtr, point2d, y, 0.0),
    ok = effi:struct_write(BrPtr, point2d, x, 10.0),
    ok = effi:struct_write(BrPtr, point2d, y, 20.0),

    10.0 = effi:struct_read(BrPtr, point2d, x),
    20.0 = effi:struct_read(BrPtr, point2d, y),
    effi:free(Ptr).

%% -------------------------------------------------------------------------
%% t_array — array_ptr/read/write
%% -------------------------------------------------------------------------

t_array(_Config) ->
    N   = 5,
    Ptr = effi:alloc_type(int32, N),
    lists:foreach(fun(I) ->
        ok = effi:array_write(Ptr, int32, I, I * I)
    end, lists:seq(0, N - 1)),
    Squares = [effi:array_read(Ptr, int32, I) || I <- lists:seq(0, N - 1)],
    [0, 1, 4, 9, 16] = Squares,
    effi:free(Ptr).

%% -------------------------------------------------------------------------
%% t_with_alloc — scoped allocation; pointer freed after block
%% -------------------------------------------------------------------------

t_with_alloc(_Config) ->
    12345 = effi:with_alloc(8, fun(Ptr) ->
        ok = effi:write(Ptr, int64, 12345),
        effi:read(Ptr, int64)
    end),
    3.0 = effi:with_alloc(double, 3, fun(Ptr) ->
        [effi:array_write(Ptr, double, I, float(I)) || I <- [0, 1, 2]],
        lists:sum([effi:array_read(Ptr, double, I) || I <- [0, 1, 2]])
    end).

%% -------------------------------------------------------------------------
%% t_callback — C→Erlang callback: qsort with a comparator
%% -------------------------------------------------------------------------

t_callback(_Config) ->
    {ok, Libc} = effi:load("libc.so.6"),

    Vals = [5, 3, 8, 1, 2],
    N    = length(Vals),
    Arr  = effi:alloc_type(int32, N),
    lists:foreach(fun({I, V}) -> effi:array_write(Arr, int32, I, V)
                  end, lists:zip(lists:seq(0, N - 1), Vals)),

    %% Comparator: (const void*, const void*) → int  (pointers to int32)
    {ok, Cb} = effi_callback:new(int32, [pointer, pointer],
        fun(PA, PB) ->
            A = effi:read(PA, int32),
            B = effi:read(PB, int32),
            if A < B -> -1; A > B -> 1; true -> 0 end
        end),
    FnPtr = effi_callback:func_ptr(Cb),

    {ok, ok} = effi:call(Libc, "qsort", void,
                   [{pointer, Arr},
                    {uint64,  N},
                    {uint64,  4},     %% sizeof(int32)
                    {pointer, FnPtr}]),

    Sorted = [effi:array_read(Arr, int32, I) || I <- lists:seq(0, N - 1)],
    [1, 2, 3, 5, 8] = Sorted,

    effi_callback:free(Cb),
    effi:free(Arr).

%% -------------------------------------------------------------------------
%% t_varargs — effi:call_va/5 with snprintf
%% -------------------------------------------------------------------------

t_varargs(_Config) ->
    {ok, Libc} = effi:load("libc.so.6"),
    Buf = effi:alloc(64),

    {ok, 2} = effi:call_va(Libc, "snprintf", int32, 3,
                  [{pointer, Buf}, {uint64, 64}, {string, "%d"}, {int32, 42}]),
    <<"42">> = trim_nul(effi:read_bytes(Buf, 3)),

    {ok, 4} = effi:call_va(Libc, "snprintf", int32, 3,
                  [{pointer, Buf}, {uint64, 64}, {string, "%.2f"}, {double, 3.14}]),
    <<"3.14">> = trim_nul(effi:read_bytes(Buf, 5)),

    {ok, 5} = effi:call_va(Libc, "snprintf", int32, 3,
                  [{pointer, Buf}, {uint64, 64}, {string, "%d+%d=%d"},
                   {int32, 1}, {int32, 2}, {int32, 3}]),
    <<"1+2=3">> = trim_nul(effi:read_bytes(Buf, 6)),

    effi:free(Buf).

%% -------------------------------------------------------------------------
%% Helpers
%% -------------------------------------------------------------------------

trim_nul(Bin) -> binary:part(Bin, 0, byte_size(Bin) - 1).

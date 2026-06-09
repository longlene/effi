%% cffi_port_SUITE.erl — Common Test suite for cffi_port (port safe mode).

-module(cffi_port_SUITE).
-compile([export_all, nowarn_export_all]).

-include_lib("common_test/include/ct.hrl").

all() ->
    [t_load, t_sqrt, t_alloc_rw, t_struct_rw, t_array, t_crash_isolation].

init_per_suite(Config) ->
    Config.

end_per_suite(_Config) -> ok.

%% -------------------------------------------------------------------------
%% t_load: open libm, verify we get a port_lib back, then close.
%% -------------------------------------------------------------------------
t_load(_Config) ->
    {ok, Lib} = cffi_port:load(libname(libm)),
    {port_lib, Pid, _Handle} = Lib,
    true = is_pid(Pid),
    ok = cffi_port:close(Lib).

%% -------------------------------------------------------------------------
%% t_sqrt: call sqrt(4.0) → 2.0
%% -------------------------------------------------------------------------
t_sqrt(_Config) ->
    {ok, Lib} = cffi_port:load(libname(libm)),
    {ok, 2.0} = cffi_port:call(Lib, "sqrt", double, [{double, 4.0}]),
    {ok, R}   = cffi_port:call(Lib, "sqrt", double, [{double, 2.0}]),
    true      = abs(R - 1.41421356) < 1.0e-6,
    ok = cffi_port:close(Lib).

%% -------------------------------------------------------------------------
%% t_alloc_rw: alloc, write int32, read it back, free.
%%
%% Note: alloc/2 returns {port_ptr,...} directly (no {ok,...} wrapper).
%%       read/2, write/3, free/1 operate on port_ptr.
%% -------------------------------------------------------------------------
t_alloc_rw(_Config) ->
    {ok, Lib} = cffi_port:load(libname(libm)),
    Ptr = cffi_port:alloc(Lib, 4),
    ok  = cffi_port:write(Ptr, int32, 42),
    42  = cffi_port:read(Ptr, int32),
    ok  = cffi_port:free(Ptr),
    ok  = cffi_port:close(Lib).

%% -------------------------------------------------------------------------
%% t_struct_rw: write two int32 fields, read back with ptr_add.
%% -------------------------------------------------------------------------
t_struct_rw(_Config) ->
    {ok, Lib} = cffi_port:load(libname(libm)),
    Ptr = cffi_port:alloc(Lib, 8),
    ok  = cffi_port:write(Ptr, int32, 10),
    P1  = cffi_port:ptr_add(Ptr, 4),
    ok  = cffi_port:write(P1, int32, 20),
    10  = cffi_port:read(Ptr, int32),
    20  = cffi_port:read(P1, int32),
    ok  = cffi_port:free(Ptr),
    ok  = cffi_port:close(Lib).

%% -------------------------------------------------------------------------
%% t_array: write a double array, call cbrt on each element.
%% -------------------------------------------------------------------------
t_array(_Config) ->
    {ok, Lib} = cffi_port:load(libname(libm)),
    Vals = [1.0, 8.0, 27.0],
    Ptr  = cffi_port:alloc(Lib, 8 * length(Vals)),
    lists:foldl(fun(V, P) ->
        ok = cffi_port:write(P, double, V),
        cffi_port:ptr_add(P, 8)
    end, Ptr, Vals),
    %% Read back, call cbrt, check result equals 1.0, 2.0, 3.0
    lists:foldl(fun(Expected, P) ->
        V    = cffi_port:read(P, double),
        {ok, Cb} = cffi_port:call(Lib, "cbrt", double, [{double, V}]),
        true = abs(Cb - Expected) < 1.0e-10,
        cffi_port:ptr_add(P, 8)
    end, Ptr, [1.0, 2.0, 3.0]),
    ok = cffi_port:free(Ptr),
    ok = cffi_port:close(Lib).

%% -------------------------------------------------------------------------
%% t_crash_isolation: kill the port OS process — VM must survive.
%% -------------------------------------------------------------------------
t_crash_isolation(_Config) ->
    {ok, Lib} = cffi_port:load(libname(libm)),
    {port_lib, Pid, _} = Lib,
    Port = cffi_port:lib_port(Lib),
    {os_pid, OsPid} = erlang:port_info(Port, os_pid),
    os:cmd("kill -9 " ++ integer_to_list(OsPid)),
    timer:sleep(200),
    %% Next call should return an error — not crash the VM
    Res = cffi_port:call(Lib, "sqrt", double, [{double, 4.0}]),
    true = case Res of
               {error, _} -> true;
               _           -> false
           end,
    %% Server process should be dead by now
    false = is_process_alive(Pid),
    ct:comment("VM survived port crash: ~p", [Res]).

libname(libm) -> case os:type() of {unix, darwin} -> "libm.dylib"; _ -> "libm.so.6" end.

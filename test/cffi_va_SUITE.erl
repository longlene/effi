%% cffi_va_SUITE.erl — Common Test suite for variadic function support.
%%
%% Tests both NIF mode (cffi:call_va) and port mode (cffi_port:call_va).
%% Uses snprintf(3) as the canonical variadic target: writes to a caller-
%% supplied buffer, so we can verify the output without capturing stdout.

-module(cffi_va_SUITE).
-compile([export_all, nowarn_export_all]).
-include_lib("common_test/include/ct.hrl").

all() ->
    [t_nif_int, t_nif_float, t_nif_string, t_nif_multi,
     t_port_int, t_port_float, t_port_string].

%% -------------------------------------------------------------------------
%% NIF mode tests
%% -------------------------------------------------------------------------

t_nif_int(_Config) ->
    {ok, Lib} = cffi:load("libc.so.6"),
    Buf = cffi:alloc(64),
    %% snprintf(buf, 64, "%d", 42)  →  "42"  (returns 2)
    {ok, 2} = cffi:call_va(Lib, "snprintf", int32, 3,
                  [{pointer, Buf}, {uint64, 64},
                   {string, "%d"},
                   {int32, 42}]),
    <<"42">> = read_cstr(Buf, 3),
    cffi:free(Buf).

t_nif_float(_Config) ->
    {ok, Lib} = cffi:load("libc.so.6"),
    Buf = cffi:alloc(64),
    %% snprintf(buf, 64, "%.3f", 3.14159)  →  "3.142"  (returns 5)
    {ok, 5} = cffi:call_va(Lib, "snprintf", int32, 3,
                  [{pointer, Buf}, {uint64, 64},
                   {string, "%.3f"},
                   {double, 3.14159}]),
    <<"3.142">> = read_cstr(Buf, 6),
    cffi:free(Buf).

t_nif_string(_Config) ->
    {ok, Lib} = cffi:load("libc.so.6"),
    Buf = cffi:alloc(64),
    {ok, 5} = cffi:call_va(Lib, "snprintf", int32, 3,
                  [{pointer, Buf}, {uint64, 64},
                   {string, "%s"},
                   {string, "hello"}]),
    <<"hello">> = read_cstr(Buf, 6),
    cffi:free(Buf).

t_nif_multi(_Config) ->
    {ok, Lib} = cffi:load("libc.so.6"),
    Buf = cffi:alloc(64),
    %% snprintf(buf, 64, "%d+%d=%d", 1, 2, 3)  →  "1+2=3"  (returns 5)
    {ok, 5} = cffi:call_va(Lib, "snprintf", int32, 3,
                  [{pointer, Buf}, {uint64, 64},
                   {string, "%d+%d=%d"},
                   {int32, 1}, {int32, 2}, {int32, 3}]),
    <<"1+2=3">> = read_cstr(Buf, 6),
    cffi:free(Buf).

%% -------------------------------------------------------------------------
%% Port mode tests
%% -------------------------------------------------------------------------

t_port_int(_Config) ->
    {ok, Lib} = cffi_port:load("libc.so.6"),
    Buf = cffi_port:alloc(Lib, 64),
    {ok, 2} = cffi_port:call_va(Lib, "snprintf", int32, 3,
                  [{pointer, Buf}, {uint64, 64},
                   {string, "%d"},
                   {int32, 42}]),
    <<"42">> = port_read_cstr(Lib, Buf, 3),
    cffi_port:free(Buf),
    cffi_port:close(Lib).

t_port_float(_Config) ->
    {ok, Lib} = cffi_port:load("libc.so.6"),
    Buf = cffi_port:alloc(Lib, 64),
    {ok, 5} = cffi_port:call_va(Lib, "snprintf", int32, 3,
                  [{pointer, Buf}, {uint64, 64},
                   {string, "%.3f"},
                   {double, 3.14159}]),
    <<"3.142">> = port_read_cstr(Lib, Buf, 6),
    cffi_port:free(Buf),
    cffi_port:close(Lib).

t_port_string(_Config) ->
    {ok, Lib} = cffi_port:load("libc.so.6"),
    Buf = cffi_port:alloc(Lib, 64),
    {ok, 5} = cffi_port:call_va(Lib, "snprintf", int32, 3,
                  [{pointer, Buf}, {uint64, 64},
                   {string, "%s"},
                   {string, "hello"}]),
    <<"hello">> = port_read_cstr(Lib, Buf, 6),
    cffi_port:free(Buf),
    cffi_port:close(Lib).

%% -------------------------------------------------------------------------
%% Helpers
%% -------------------------------------------------------------------------

%% Read N bytes from a NIF pointer, strip trailing null.
read_cstr(Ptr, Len) ->
    Bin = cffi:read_bytes(Ptr, Len),
    binary:part(Bin, 0, byte_size(Bin) - 1).

%% Read N bytes via port, strip trailing null.
port_read_cstr(Lib, Ptr, Len) ->
    Bin = cffi_port:read_bytes(Ptr, Len),
    _ = Lib,  %% not needed; Ptr encodes the pid
    binary:part(Bin, 0, byte_size(Bin) - 1).

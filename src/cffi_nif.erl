%% cffi_nif.erl — NIF stub module.
%%
%% Do not call these functions directly; use cffi.erl instead.
%% All real work is in c_src/cffi_nif.c loaded via on_load.

-module(cffi_nif).
-on_load(init/0).

-export([
    lib_open/1,
    call/4,
    call_va/5,
    mem_alloc/1,
    mem_free/1,
    mem_read/2,
    mem_write/3,
    mem_read_bytes/2,
    mem_write_bytes/2,
    ptr_add/2,
    ptr_null/0,
    ptr_is_null/1,
    type_size/1,
    callback_new/3,
    callback_return/2
]).

init() ->
    PrivDir = code:priv_dir(cffi),
    erlang:load_nif(filename:join(PrivDir, "cffi_nif"), 0).

lib_open(_Path)                       -> erlang:nif_error(not_loaded).
call(_Lib, _Fn, _Ret, _Args)          -> erlang:nif_error(not_loaded).
call_va(_Lib, _Fn, _Ret, _NF, _Args) -> erlang:nif_error(not_loaded).
mem_alloc(_Size)             -> erlang:nif_error(not_loaded).
mem_free(_Ptr)               -> erlang:nif_error(not_loaded).
mem_read(_Ptr, _Type)        -> erlang:nif_error(not_loaded).
mem_write(_Ptr, _Type, _Val) -> erlang:nif_error(not_loaded).
mem_read_bytes(_Ptr, _Size)  -> erlang:nif_error(not_loaded).
mem_write_bytes(_Ptr, _Bin)  -> erlang:nif_error(not_loaded).
ptr_add(_Ptr, _Off)          -> erlang:nif_error(not_loaded).
ptr_null()                   -> erlang:nif_error(not_loaded).
ptr_is_null(_Ptr)            -> erlang:nif_error(not_loaded).
type_size(_Type)             -> erlang:nif_error(not_loaded).
callback_new(_Ret,_Args,_Pid)-> erlang:nif_error(not_loaded).
callback_return(_CbId,_Ret)  -> erlang:nif_error(not_loaded).

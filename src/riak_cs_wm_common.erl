%% -------------------------------------------------------------------
%%
%% Copyright (c) 2007-2012 Basho Technologies, Inc.  All Rights Reserved.
%%
%% -------------------------------------------------------------------

-module(riak_cs_wm_common).

-export([init/1,
         service_available/2,
         service_available/3,
         forbidden/2,
         content_types_accepted/2,
         content_types_provided/2,
         valid_entity_length/2,
         malformed_request/2,
         to_xml/2,
         accept_body/2,
         allowed_methods/2,
         delete_resource/2,
         finish_request/2]).

-export([default_allowed_methods/0,
         default_content_types/2,
         default_finish_request/2,
         default_init/1,
         default_authorize/2,
         default_malformed_request/2,
         default_valid_entity_length/2,
         default_delete_resource/2]).

-include("riak_cs.hrl").
-include_lib("webmachine/include/webmachine.hrl").

%% ===================================================================
%% Webmachine callbacks
%% ===================================================================

init(Config) ->
    Mod = proplists:get_value(submodule, Config),
    dt_entry(Mod, <<"init">>),
    %% Check if authentication is disabled and set that in the context.
    AuthBypass = proplists:get_value(auth_bypass, Config),
    AuthModule = proplists:get_value(auth_module, Config),
    Exports = orddict:from_list(Mod:module_info(exports)),
    ExportsFun = exports_fun(Exports),
    Ctx = #context{auth_bypass=AuthBypass,
                   auth_module=AuthModule,
                   exports_fun=ExportsFun,
                   start_time=os:timestamp(),
                   submodule=Mod},
    resource_call(Mod, init, [Ctx], ExportsFun(init)).


-spec service_available(term(), term()) -> {true, term(), term()}.
service_available(RD, Ctx=#context{submodule=Mod}) ->
    dt_entry(Mod, <<"service_available">>),
    case riak_cs_utils:riak_connection() of
        {ok, Pid} ->
            {true, RD, Ctx#context{riakc_pid=Pid}};
        {error, _Reason} ->
            {false, RD, Ctx}
    end.

service_available(Pool, RD, Ctx) ->
    case riak_cs_utils:riak_connection(Pool) of
        {ok, Pid} ->
            {true, RD, Ctx#context{riakc_pid=Pid}};
        {error, _Reason} ->
            {false, RD, Ctx}
    end.

-spec malformed_request(term(), term()) -> {false, term(), term()}.
malformed_request(RD, Ctx=#context{submodule=Mod,
                                   exports_fun=ExportsFun}) ->
    dt_entry(Mod, <<"malformed_request">>),
    resource_call(Mod,
                  malformed_request,
                  [RD, Ctx],
                  ExportsFun(malformed_request)).

-spec valid_entity_length(term(), term()) -> {boolean(), term(), term()}.
valid_entity_length(RD, Ctx=#context{submodule=Mod, exports_fun=ExportsFun}) ->
    resource_call(Mod,
                  valid_entity_length,
                  [RD, Ctx],
                  ExportsFun(valid_entity_length)).

forbidden(RD, Ctx=#context{auth_module=AuthMod, submodule=Mod, riakc_pid=RiakPid}) ->
    dt_entry(Mod, <<"forbidden">>),
    {UserKey, AuthData} = AuthMod:identify(RD, Ctx),
    AuthResult = case riak_cs_utils:get_user(UserKey, RiakPid) of
                     {ok, {User, UserObj}} when User?RCS_USER.status =:= enabled ->
                         authenticate(User, UserObj, RD, Ctx, AuthData);
                     {ok, _} -> %% disabled account, we are going to 403
                         {error, bad_auth};
                     {error, NE} when NE =:= not_found;
                                      NE =:= no_user_key ->
                         {error, NE};
                     {error, R} ->
                         %% other failures, like Riak fetch timeout, be loud about
                         _ = lager:error("Retrieval of user record for ~p failed. Reason: ~p",
                                         [UserKey, R]),
                         {error, R}
                 end,
    AnonOk = true, %% TODO: need to call submodule to determine if anonymous request is ok
    case post_authentication(AuthResult, RD, Ctx, fun authorize/2, AnonOk) of
        {false, _RD2, Ctx2} = FalseRet ->
            dt_return(Mod, <<"forbidden">>, [], [riak_cs_wm_utils:extract_name(Ctx2#context.user), <<"false">>]),
            FalseRet;
        {Rsn, _RD2, Ctx2} = Ret ->
            Reason =
                case Rsn of
                    {halt, Code} -> Code;
                    _            -> -1
                end,
            dt_return(Mod, <<"forbidden">>, [Reason], [riak_cs_wm_utils:extract_name(Ctx2#context.user), <<"true">>]),
            Ret
    end.

%% @doc Get the list of methods a resource supports.
-spec allowed_methods(term(), term()) -> {[atom()], term(), term()}.
allowed_methods(RD, Ctx=#context{submodule=Mod,
                                 exports_fun=ExportsFun}) ->
    dt_entry(Mod, <<"allowed_methods">>),
    Methods = resource_call(Mod,
                            allowed_methods,
                            [],
                            ExportsFun(allowed_methods)),
    {Methods, RD, Ctx}.

-spec content_types_accepted(term(), term()) ->
    {[{string(), atom()}], term(), term()}.
content_types_accepted(RD, Ctx=#context{submodule=Mod,
                                        exports_fun=ExportsFun}) ->
    dt_entry(Mod, <<"content_types_accepted">>),
    resource_call(Mod,
                  content_types_accepted,
                  [RD,Ctx],
                  ExportsFun(content_types_accepted)).

-spec content_types_provided(term(), term()) ->
    {[{string(), atom()}], term(), term()}.
content_types_provided(RD, Ctx=#context{submodule=Mod,
                                        exports_fun=ExportsFun}) ->
    dt_entry(Mod, <<"content_types_provided">>),
    resource_call(Mod,
                  content_types_provided,
                  [RD,Ctx],
                  ExportsFun(content_types_provided)).

-spec delete_resource(term(), term()) -> {boolean() | {halt, term()}, term(), #context{}}.
delete_resource(RD, Ctx=#context{submodule=Mod,exports_fun=ExportsFun}) ->
    resource_call(Mod,
                  delete_resource,
                  [RD,Ctx],
                  ExportsFun(delete_resource)).


-spec to_xml(term(), term()) ->
    {binary() | {'halt', term()}, term(), #context{}}.
to_xml(RD, Ctx=#context{user=User,
                        submodule=Mod,
                        exports_fun=ExportsFun}) ->
    dt_entry(Mod, <<"to_xml">>),
    dt_entry_service(Mod, <<"service_get_buckets">>),
    Res = resource_call(Mod,
                        to_xml,
                        [RD, Ctx],
                        ExportsFun(to_xml)),
    dt_return(Mod, <<"to_xml">>, [], [riak_cs_wm_utils:extract_name(User), <<"service_get_buckets">>]),
    dt_return_service(Mod, <<"service_get_buckets">>, [], [riak_cs_wm_utils:extract_name(User)]),
    Res.

-spec accept_body(term(), term()) ->
    {boolean() | {'halt', term()}, term(), #context{}}.
accept_body(RD, Ctx=#context{submodule=Mod,exports_fun=ExportsFun}) -> %% TODO: add in dtrace
    resource_call(Mod,
                  accept_body,
                  [RD, Ctx],
                  ExportsFun(accept_body)).



finish_request(RD, Ctx=#context{riakc_pid=undefined,
                                submodule=Mod,
                                exports_fun=ExportsFun}) ->
    dt_entry(Mod, <<"finish_request">>, [0], []),
    Res = resource_call(Mod,
                        finish_request,
                        [RD, Ctx],
                        ExportsFun(finish_request)),
    dt_return(Mod, <<"finish_request">>, [0], []),
    Res;
finish_request(RD, Ctx=#context{submodule=Mod,
                                exports_fun=ExportsFun}) ->
    dt_entry(Mod, <<"finish_request">>, [1], []),
    Res = resource_call(Mod,
                        finish_request,
                        [RD, Ctx],
                        ExportsFun(finish_request)),
    dt_return(Mod, <<"finish_request">>, [1], []),
    Res.

%% ===================================================================
%% Helper functions
%% ===================================================================

-spec authorize(term(), term()) -> {boolean(),term(),term()}.
authorize(RD,Ctx=#context{submodule=Mod, exports_fun=ExportsFun}) ->
    resource_call(Mod, authorize, [RD,Ctx], ExportsFun(authorize)).

-spec authenticate(rcs_user(), riakc_obj:riakc_obj(), term(), term(), term()) ->
                          {ok, rcs_user(), riakc_obj:riakc_obj()} | {error, term()}.
authenticate(User, UserObj, RD, Ctx=#context{auth_module=AuthMod}, AuthData) ->
    case AuthMod:authenticate(User, AuthData, RD, Ctx) of
        ok ->
            {ok, User, UserObj};
        {error, _Reason} ->
            {error, bad_auth}
    end.

-spec exports_fun(orddict:new()) -> function().
exports_fun(Exports) ->
    fun(Function) ->
            orddict:is_key(Function, Exports)
    end.

resource_call(Mod, Fun, Args, true) ->
    erlang:apply(Mod, Fun, Args);
resource_call(_Mod, Fun, Args, false) ->
    erlang:apply(?MODULE, default(Fun), Args).

%% ===================================================================
%% Helper Functions Copied from riak_cs_wm_utils that should be removed from that module
%% ===================================================================

post_authentication({ok, User, UserObj}, RD, Ctx, Authorize, _) ->
    %% given keyid and signature matched, proceed
    Authorize(RD, Ctx#context{user=User,
                              user_object=UserObj});
post_authentication({error, no_user_key}, RD, Ctx, Authorize, true) ->
    %% no keyid was given, proceed anonymously
    lager:info("No user key"),
    Authorize(RD, Ctx);
post_authentication({error, no_user_key}, RD, Ctx, _, false) ->
    %% no keyid was given, deny access
    lager:info("No user key, deny"),
    deny_access(RD, Ctx);
post_authentication({error, bad_auth}, RD, Ctx, _, _) ->
    %% given keyid was found, but signature didn't match
    lager:info("bad_auth"),
    deny_access(RD, Ctx);
post_authentication({error, _Reason}, RD, Ctx, _, _) ->
    %% no matching keyid was found, or lookup failed
    lager:info("other"),
    deny_invalid_key(RD, Ctx).

%% @doc Produce an access-denied error message from a webmachine
%% resource's `forbidden/2' function.
deny_access(RD, Ctx) ->
    riak_cs_s3_response:api_error(access_denied, RD, Ctx).

%% @doc Prodice an invalid-access-keyid error message from a
%% webmachine resource's `forbidden/2' function.
deny_invalid_key(RD, Ctx) ->
    riak_cs_s3_response:api_error(invalid_access_key_id, RD, Ctx).


%% ===================================================================
%% Resource function defaults
%% ===================================================================

default(init) ->
    default_init;
default(allowed_methods) ->
    default_allowed_methods;
default(content_types_accepted) ->
    default_content_types;
default(content_types_provided) ->
    default_content_types;
default(malformed_request) ->
    default_malformed_request;
default(valid_entity_length) ->
    default_valid_entity_length;
default(delete_resource) ->
    default_delete_resource;
default(authorize) ->
    default_authorize;
default(finish_request) ->
    default_finish_request;
default(_) ->
    undefined.

default_init(Ctx) ->
    {ok, Ctx}.

default_malformed_request(RD, Ctx) ->
    {false, RD, Ctx}.

default_valid_entity_length(RD, Ctx) ->
    {true, RD, Ctx}. 

default_content_types(RD, Ctx) ->
    {[], RD, Ctx}.

default_delete_resource(RD, Ctx) ->
    {false, RD, Ctx}.

default_allowed_methods() ->
    [].

default_finish_request(RD, Ctx=#context{riakc_pid=undefined}) ->
    {true, RD, Ctx};
default_finish_request(RD, Ctx=#context{riakc_pid=RiakPid}) ->
    riak_cs_utils:close_riak_connection(RiakPid),
    {true, RD, Ctx#context{riakc_pid=undefined}}.

%% @doc this function will be called by `post_authenticate/2` if the user successfully
%% authenticates and the submodule does not provide an implementation
%% of authorize/2. The default implementation does not perform any authorization
%% and simply returns false to signify the request is not fobidden
-spec default_authorize(term(), term()) -> {false, term(), term()}.
default_authorize(RD, Ctx) ->
    {false, RD, Ctx}.


%% ===================================================================
%% DTrace functions
%% ===================================================================

dt_entry(Mod, Func) ->
    dt_entry(Mod, Func, [], []).

dt_entry(Mod, Func, Ints, Strings) ->
    riak_cs_dtrace:dtrace(?DT_WM_OP, 1, Ints, Mod, Func, Strings).

dt_entry_service(Mod, Func) ->
    dt_entry_service(Mod, Func, [], []).

dt_entry_service(Mod, Func, Ints, Strings) ->
    riak_cs_dtrace:dtrace(?DT_SERVICE_OP, 1, Ints, Mod, Func, Strings).

dt_return(Mod, Func, Ints, Strings) ->
    riak_cs_dtrace:dtrace(?DT_WM_OP, 2, Ints, Mod, Func, Strings).

dt_return_service(Mod, Func, Ints, Strings) ->
    riak_cs_dtrace:dtrace(?DT_SERVICE_OP, 2, Ints, Mod, Func, Strings).
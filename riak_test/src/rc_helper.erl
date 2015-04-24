%% ---------------------------------------------------------------------
%%
%% Copyright (c) 2007-2014 Basho Technologies, Inc.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% ---------------------------------------------------------------------

-module(rc_helper).
-compile(export_all).
-include_lib("eunit/include/eunit.hrl").
-include_lib("riak_pb/include/riak_pb_kv_codec.hrl").

to_riak_bucket(objects, CSBucket) ->
    %%  or make version switch here.
    <<"0o:", (stanchion_utils:md5(CSBucket))/binary>>;
to_riak_bucket(blocks, CSBucket) ->
    %%  or make version switch here.
    <<"0b:", (stanchion_utils:md5(CSBucket))/binary>>;
to_riak_bucket(_, CSBucket) ->
    CSBucket.

to_riak_key(objects, CsKey) ->
    CsKey;
to_riak_key(blocks, {UUID, Seq}) ->
    <<UUID/binary, Seq:32>>;
to_riak_key(Kind, _) ->
    error({not_yet_implemented, Kind}).

-spec get_riakc_obj([term()], objects | blocks, binary(), term()) -> term().
get_riakc_obj(RiakNodes, Kind, CsBucket, Opts) ->
    {Pbc, Key} = case Kind of
                     objects ->
                         {rtcs:pbc(RiakNodes, Kind, CsBucket), Opts};
                     blocks ->
                         {CsKey, UUID, Seq} = Opts,
                         {rtcs:pbc(RiakNodes, Kind, {CsBucket, CsKey, UUID}),
                          {UUID, Seq}}
                   end,
    RiakBucket = to_riak_bucket(Kind, CsBucket),
    RiakKey = to_riak_key(Kind, Key),
    Result = riakc_pb_socket:get(Pbc, RiakBucket, RiakKey),
    riakc_pb_socket:stop(Pbc),
    Result.

-spec update_riakc_obj([term()], objects | blocks, binary(), term(), riakc_obj:riakc_obj()) -> term().
update_riakc_obj(RiakNodes, ObjectKind, CsBucket, CsKey, NewObj) ->
    NewMD = riakc_obj:get_metadata(NewObj),
    NewValue = riakc_obj:get_value(NewObj),
    Pbc = rtcs:pbc(RiakNodes, ObjectKind, CsBucket),
    RiakBucket = to_riak_bucket(ObjectKind, CsBucket),
    RiakKey = to_riak_key(ObjectKind, CsKey),
    Result = case riakc_pb_socket:get(Pbc, RiakBucket, RiakKey, [deletedvclock]) of
                 {ok, OldObj} ->
                     Updated = riakc_obj:update_value(
                                 riakc_obj:update_metadata(OldObj, NewMD), NewValue),
                     riakc_pb_socket:put(Pbc, Updated);
                 {error, notfound} ->
                     Obj = riakc_obj:new(RiakBucket, RiakKey, NewValue),
                     Updated = riakc_obj:update_metadata(Obj, NewMD),
                     riakc_pb_socket:put(Pbc, Updated)
             end,
    riakc_pb_socket:stop(Pbc),
    Result.

%% => [binary()]
list_keys(RiakNodes, ObjectKind, CsBucket) ->
    Pbc = rtcs:pbc(RiakNodes, ObjectKind, CsBucket),
    RiakBucket = to_riak_bucket(ObjectKind, CsBucket),
    try
        riakc_pb_socket:list_keys(Pbc, RiakBucket)
    after
        riakc_pb_socket:stop(Pbc)
    end.

%% => [{B, K}]
filter_tombstones(RiakNodes, ObjectKind, CsBucket, Keys) ->
    Pbc = rtcs:pbc(RiakNodes, ObjectKind, CsBucket),
    RiakBucket = to_riak_bucket(ObjectKind, CsBucket),
    try
        GetObjectFun =
            fun(Key) ->
                    riakc_pb_socket:get(Pbc, RiakBucket, Key)
            end,
        FilterTombstoneFun =
            fun({ok,Obj}) ->
                    lager:debug("~p siblings in key ~p",
                                [riakc_obj:value_count(Obj),
                                 riakc_obj:key(Obj)]),
                    Contents0 = riakc_obj:get_contents(Obj),
                    %% Strip for visibility
                    Contents = [{MD, <<"deadbeef">>} || {MD, _} <- Contents0],
                    lager:debug("Are they all tombstone?: ~p",
                                [lists:map(fun has_tombstone/1, Contents)]),
                    AllTombstone = lists:all(fun has_tombstone/1, Contents),
                    not AllTombstone;
               ({error, notfound}) ->
                    false;
               (_Error) ->
                    true
            end,
        ToBkFun =
            fun({ok, Obj}) ->
                    {riakc_obj:bucket(Obj), riakc_obj:key(Obj)}
            end,
        lists:map(ToBkFun,
                  lists:filter(FilterTombstoneFun, lists:map(GetObjectFun, Keys)))
    after
        riakc_pb_socket:stop(Pbc)
    end.

has_tombstone({_, <<>>}) -> true;
has_tombstone({MD, _}) -> dict:is_key(?MD_DELETED, MD);
has_tombstone(_) -> false.

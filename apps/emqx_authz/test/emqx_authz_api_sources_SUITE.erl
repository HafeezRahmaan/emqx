%%--------------------------------------------------------------------
%% Copyright (c) 2020-2022 EMQ Technologies Co., Ltd. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%% http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%--------------------------------------------------------------------

-module(emqx_authz_api_sources_SUITE).

-compile(nowarn_export_all).
-compile(export_all).

-import(emqx_dashboard_api_test_helpers, [request/3, uri/1]).

-include_lib("eunit/include/eunit.hrl").
-include_lib("common_test/include/ct.hrl").
-include_lib("emqx/include/emqx_placeholder.hrl").

-define(MONGO_SINGLE_HOST, "mongo").
-define(MYSQL_HOST, "mysql:3306").
-define(PGSQL_HOST, "pgsql").
-define(REDIS_SINGLE_HOST, "redis").

-define(SOURCE1, #{
    <<"type">> => <<"http">>,
    <<"enable">> => true,
    <<"url">> => <<"https://fake.com:443/acl?username=", ?PH_USERNAME/binary>>,
    <<"headers">> => #{},
    <<"method">> => <<"get">>,
    <<"request_timeout">> => <<"5s">>
}).
-define(SOURCE2, #{
    <<"type">> => <<"mongodb">>,
    <<"enable">> => true,
    <<"mongo_type">> => <<"single">>,
    <<"server">> => <<?MONGO_SINGLE_HOST>>,
    <<"w_mode">> => <<"unsafe">>,
    <<"pool_size">> => 1,
    <<"database">> => <<"mqtt">>,
    <<"ssl">> => #{<<"enable">> => false},
    <<"collection">> => <<"fake">>,
    <<"selector">> => #{<<"a">> => <<"b">>}
}).
-define(SOURCE3, #{
    <<"type">> => <<"mysql">>,
    <<"enable">> => true,
    <<"server">> => <<?MYSQL_HOST>>,
    <<"pool_size">> => 1,
    <<"database">> => <<"mqtt">>,
    <<"username">> => <<"xx">>,
    <<"password">> => <<"ee">>,
    <<"auto_reconnect">> => true,
    <<"ssl">> => #{<<"enable">> => false},
    <<"query">> => <<"abcb">>
}).
-define(SOURCE4, #{
    <<"type">> => <<"postgresql">>,
    <<"enable">> => true,
    <<"server">> => <<?PGSQL_HOST>>,
    <<"pool_size">> => 1,
    <<"database">> => <<"mqtt">>,
    <<"username">> => <<"xx">>,
    <<"password">> => <<"ee">>,
    <<"auto_reconnect">> => true,
    <<"ssl">> => #{<<"enable">> => false},
    <<"query">> => <<"abcb">>
}).
-define(SOURCE5, #{
    <<"type">> => <<"redis">>,
    <<"enable">> => true,
    <<"servers">> => <<?REDIS_SINGLE_HOST, ",127.0.0.1:6380">>,
    <<"pool_size">> => 1,
    <<"database">> => 0,
    <<"password">> => <<"ee">>,
    <<"auto_reconnect">> => true,
    <<"ssl">> => #{<<"enable">> => false},
    <<"cmd">> => <<"HGETALL mqtt_authz:", ?PH_USERNAME/binary>>
}).
-define(SOURCE6, #{
    <<"type">> => <<"file">>,
    <<"enable">> => true,
    <<"rules">> =>
        <<
            "{allow,{username,\"^dashboard?\"},subscribe,[\"$SYS/#\"]}."
            "\n{allow,{ipaddr,\"127.0.0.1\"},all,[\"$SYS/#\",\"#\"]}."
        >>
}).

-define(MATCH_RSA_KEY, <<"-----BEGIN RSA PRIVATE KEY", _/binary>>).
-define(MATCH_CERT, <<"-----BEGIN CERTIFICATE", _/binary>>).

all() ->
    emqx_common_test_helpers:all(?MODULE).

groups() ->
    [].

init_per_suite(Config) ->
    ok = stop_apps([emqx_resource, emqx_connector]),
    meck:new(emqx_resource, [non_strict, passthrough, no_history, no_link]),
    meck:expect(emqx_resource, create_local, fun(_, _, _, _) -> {ok, meck_data} end),
    meck:expect(emqx_resource, health_check, fun(St) -> {ok, St} end),
    meck:expect(emqx_resource, remove_local, fun(_) -> ok end),
    meck:expect(
        emqx_authz,
        acl_conf_file,
        fun() ->
            emqx_common_test_helpers:deps_path(emqx_authz, "etc/acl.conf")
        end
    ),

    ok = emqx_common_test_helpers:start_apps(
        [emqx_conf, emqx_authz, emqx_dashboard],
        fun set_special_configs/1
    ),
    ok = start_apps([emqx_resource, emqx_connector]),
    Config.

end_per_suite(_Config) ->
    {ok, _} = emqx:update_config(
        [authorization],
        #{
            <<"no_match">> => <<"allow">>,
            <<"cache">> => #{<<"enable">> => <<"true">>},
            <<"sources">> => []
        }
    ),
    %% resource and connector should be stop first,
    %% or authz_[mysql|pgsql|redis..]_SUITE would be failed
    ok = stop_apps([emqx_resource, emqx_connector]),
    emqx_common_test_helpers:stop_apps([emqx_dashboard, emqx_authz, emqx_conf]),
    meck:unload(emqx_resource),
    ok.

set_special_configs(emqx_dashboard) ->
    emqx_dashboard_api_test_helpers:set_default_config();
set_special_configs(emqx_authz) ->
    {ok, _} = emqx:update_config([authorization, cache, enable], false),
    {ok, _} = emqx:update_config([authorization, no_match], deny),
    {ok, _} = emqx:update_config([authorization, sources], []),
    ok;
set_special_configs(_App) ->
    ok.

init_per_testcase(t_api, Config) ->
    meck:new(emqx_misc, [non_strict, passthrough, no_history, no_link]),
    meck:expect(emqx_misc, gen_id, fun() -> "fake" end),

    meck:new(emqx, [non_strict, passthrough, no_history, no_link]),
    meck:expect(
        emqx,
        data_dir,
        fun() ->
            {data_dir, Data} = lists:keyfind(data_dir, 1, Config),
            Data
        end
    ),
    Config;
init_per_testcase(_, Config) ->
    Config.

end_per_testcase(t_api, _Config) ->
    meck:unload(emqx_misc),
    meck:unload(emqx),
    ok;
end_per_testcase(_, _Config) ->
    ok.

%%------------------------------------------------------------------------------
%% Testcases
%%------------------------------------------------------------------------------

t_api(_) ->
    {ok, 200, Result1} = request(get, uri(["authorization", "sources"]), []),
    ?assertEqual([], get_sources(Result1)),

    [
        begin
            {ok, 204, _} = request(post, uri(["authorization", "sources"]), Source)
        end
     || Source <- lists:reverse([?SOURCE2, ?SOURCE3, ?SOURCE4, ?SOURCE5, ?SOURCE6])
    ],
    {ok, 204, _} = request(post, uri(["authorization", "sources"]), ?SOURCE1),

    Snd = fun({_, Val}) -> Val end,
    LookupVal = fun LookupV(List, RestJson) ->
        case List of
            [Name] -> Snd(lists:keyfind(Name, 1, RestJson));
            [Name | NS] -> LookupV(NS, Snd(lists:keyfind(Name, 1, RestJson)))
        end
    end,
    EqualFun = fun(RList) ->
        fun({M, V}) ->
            ?assertEqual(
                V,
                LookupVal(
                    [<<"metrics">>, M],
                    RList
                )
            )
        end
    end,
    AssertFun =
        fun(ResultJson) ->
            {ok, RList} = emqx_json:safe_decode(ResultJson),
            MetricsList = [
                {<<"failed">>, 0},
                {<<"matched">>, 0},
                {<<"rate">>, 0.0},
                {<<"rate_last5m">>, 0.0},
                {<<"rate_max">>, 0.0},
                {<<"success">>, 0}
            ],
            lists:map(EqualFun(RList), MetricsList)
        end,

    {ok, 200, Result2} = request(get, uri(["authorization", "sources"]), []),
    Sources = get_sources(Result2),
    ?assertMatch(
        [
            #{<<"type">> := <<"http">>},
            #{<<"type">> := <<"mongodb">>},
            #{<<"type">> := <<"mysql">>},
            #{<<"type">> := <<"postgresql">>},
            #{<<"type">> := <<"redis">>},
            #{<<"type">> := <<"file">>}
        ],
        Sources
    ),
    ?assert(filelib:is_file(emqx_authz:acl_conf_file())),

    {ok, 204, _} = request(
        put,
        uri(["authorization", "sources", "http"]),
        ?SOURCE1#{<<"enable">> := false}
    ),
    {ok, 200, Result3} = request(get, uri(["authorization", "sources", "http"]), []),
    ?assertMatch(#{<<"type">> := <<"http">>, <<"enable">> := false}, jsx:decode(Result3)),

    Keyfile = emqx_common_test_helpers:app_path(
        emqx,
        filename:join(["etc", "certs", "key.pem"])
    ),
    Certfile = emqx_common_test_helpers:app_path(
        emqx,
        filename:join(["etc", "certs", "cert.pem"])
    ),
    Cacertfile = emqx_common_test_helpers:app_path(
        emqx,
        filename:join(["etc", "certs", "cacert.pem"])
    ),

    {ok, 204, _} = request(
        put,
        uri(["authorization", "sources", "mongodb"]),
        ?SOURCE2#{
            <<"ssl">> => #{
                <<"enable">> => <<"true">>,
                <<"cacertfile">> => Cacertfile,
                <<"certfile">> => Certfile,
                <<"keyfile">> => Keyfile,
                <<"verify">> => <<"verify_none">>
            }
        }
    ),
    {ok, 200, Result4} = request(get, uri(["authorization", "sources", "mongodb"]), []),
    {ok, 200, Status4} = request(get, uri(["authorization", "sources", "mongodb", "status"]), []),
    AssertFun(Status4),
    ?assertMatch(
        #{
            <<"type">> := <<"mongodb">>,
            <<"ssl">> := #{
                <<"enable">> := <<"true">>,
                <<"cacertfile">> := ?MATCH_CERT,
                <<"certfile">> := ?MATCH_CERT,
                <<"keyfile">> := ?MATCH_RSA_KEY,
                <<"verify">> := <<"verify_none">>
            }
        },
        jsx:decode(Result4)
    ),

    {ok, Cacert} = file:read_file(Cacertfile),
    {ok, Cert} = file:read_file(Certfile),
    {ok, Key} = file:read_file(Keyfile),

    {ok, 204, _} = request(
        put,
        uri(["authorization", "sources", "mongodb"]),
        ?SOURCE2#{
            <<"ssl">> => #{
                <<"enable">> => <<"true">>,
                <<"cacertfile">> => Cacert,
                <<"certfile">> => Cert,
                <<"keyfile">> => Key,
                <<"verify">> => <<"verify_none">>
            }
        }
    ),
    {ok, 200, Result5} = request(get, uri(["authorization", "sources", "mongodb"]), []),
    {ok, 200, Status5} = request(get, uri(["authorization", "sources", "mongodb", "status"]), []),
    AssertFun(Status5),
    ?assertMatch(
        #{
            <<"type">> := <<"mongodb">>,
            <<"ssl">> := #{
                <<"enable">> := <<"true">>,
                <<"cacertfile">> := ?MATCH_CERT,
                <<"certfile">> := ?MATCH_CERT,
                <<"keyfile">> := ?MATCH_RSA_KEY,
                <<"verify">> := <<"verify_none">>
            }
        },
        jsx:decode(Result5)
    ),

    #{
        ssl := #{
            cacertfile := SavedCacertfile,
            certfile := SavedCertfile,
            keyfile := SavedKeyfile
        }
    } = emqx_authz:lookup(mongodb),

    ?assert(filelib:is_file(SavedCacertfile)),
    ?assert(filelib:is_file(SavedCertfile)),
    ?assert(filelib:is_file(SavedKeyfile)),

    {ok, 204, _} = request(
        put,
        uri(["authorization", "sources", "mysql"]),
        ?SOURCE3#{<<"server">> := <<"192.168.1.100:3306">>}
    ),

    {ok, 204, _} = request(
        put,
        uri(["authorization", "sources", "postgresql"]),
        ?SOURCE4#{<<"server">> := <<"fake">>}
    ),
    {ok, 204, _} = request(
        put,
        uri(["authorization", "sources", "redis"]),
        ?SOURCE5#{
            <<"servers">> := [
                <<"192.168.1.100:6379">>,
                <<"192.168.1.100:6380">>
            ]
        }
    ),

    lists:foreach(
        fun(#{<<"type">> := Type}) ->
            {ok, 204, _} = request(
                delete,
                uri(["authorization", "sources", binary_to_list(Type)]),
                []
            )
        end,
        Sources
    ),
    {ok, 200, Result6} = request(get, uri(["authorization", "sources"]), []),
    ?assertEqual([], get_sources(Result6)),
    ?assertEqual([], emqx:get_config([authorization, sources])),
    ok.

t_move_source(_) ->
    {ok, _} = emqx_authz:update(replace, [?SOURCE1, ?SOURCE2, ?SOURCE3, ?SOURCE4, ?SOURCE5]),
    ?assertMatch(
        [
            #{type := http},
            #{type := mongodb},
            #{type := mysql},
            #{type := postgresql},
            #{type := redis}
        ],
        emqx_authz:lookup()
    ),

    {ok, 204, _} = request(
        post,
        uri(["authorization", "sources", "postgresql", "move"]),
        #{<<"position">> => <<"front">>}
    ),
    ?assertMatch(
        [
            #{type := postgresql},
            #{type := http},
            #{type := mongodb},
            #{type := mysql},
            #{type := redis}
        ],
        emqx_authz:lookup()
    ),

    {ok, 204, _} = request(
        post,
        uri(["authorization", "sources", "http", "move"]),
        #{<<"position">> => <<"rear">>}
    ),
    ?assertMatch(
        [
            #{type := postgresql},
            #{type := mongodb},
            #{type := mysql},
            #{type := redis},
            #{type := http}
        ],
        emqx_authz:lookup()
    ),

    {ok, 204, _} = request(
        post,
        uri(["authorization", "sources", "mysql", "move"]),
        #{<<"position">> => <<"before:postgresql">>}
    ),
    ?assertMatch(
        [
            #{type := mysql},
            #{type := postgresql},
            #{type := mongodb},
            #{type := redis},
            #{type := http}
        ],
        emqx_authz:lookup()
    ),

    {ok, 204, _} = request(
        post,
        uri(["authorization", "sources", "mongodb", "move"]),
        #{<<"position">> => <<"after:http">>}
    ),
    ?assertMatch(
        [
            #{type := mysql},
            #{type := postgresql},
            #{type := redis},
            #{type := http},
            #{type := mongodb}
        ],
        emqx_authz:lookup()
    ),

    ok.

get_sources(Result) ->
    maps:get(<<"sources">>, jsx:decode(Result), []).

data_dir() -> emqx:data_dir().

start_apps(Apps) ->
    lists:foreach(fun application:ensure_all_started/1, Apps).

stop_apps(Apps) ->
    lists:foreach(fun application:stop/1, Apps).
%% -------------------------------------------------------------------
%%
%% Copyright (c) 2013 Carlos Gonzalez Florido.  All Rights Reserved.
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
%% -------------------------------------------------------------------

%% @doc UAC process helper functions
-module(nksip_uac_lib).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([send_any/4, send_dialog/4]).
-export([make/5, proxy_make/3, make_cancel/2, make_ack/2, make_ack/1, is_stateless/2]).
-include("nksip.hrl").
 

%% ===================================================================
%% Public
%% ===================================================================


-spec send_any(nksip:app_id(), nksip:method(), 
               nksip:user_uri() | nksip_dialog:spec() | nksip_subscription:id(),
               nksip_lib:optslist()) ->
    nksip_uac:result() | nksip_uac:ack_result() | {error, nksip_uac:error()}.

% R: requests
% S: responses
% D: dialogs
% U: subscriptions

send_any(AppId, Method, UriOrDialog, Opts) ->
    case UriOrDialog of
        <<Class, $_, _/binary>> when Class==$R; Class==$S; Class==$D; Class==$U ->
            send_dialog(AppId, Method, UriOrDialog, Opts);
        UserUri ->
            nksip_call:send(AppId, Method, UserUri, Opts)
    end.


%% @private
-spec send_dialog(nksip:app_id(), nksip:method(), 
                  nksip_dialog:spec() | nksip_subscription:id(),
                  nksip_lib:optslist()) ->
    nksip_uac:result() | nksip_uac:ack_result() | {error, nksip_uac:error()}.

send_dialog(AppId, Method, <<Class, $_, _/binary>>=Id, Opts)
            when Class==$R; Class==$S; Class==$D; Class==$U ->
    case nksip_dialog:id(AppId, Id) of
        <<>> -> 
            {error, unknown_dialog};
        DialogId when Class==$U ->
            nksip_call:send_dialog(AppId, DialogId, Method, [{subscription_id, Id}|Opts]);
        DialogId ->
            nksip_call:send_dialog(AppId, DialogId, Method, Opts)
    end.


%% @doc Generates a new request.
%% See {@link nksip_uac} for the decription of most options.
-spec make(nksip:app_id(), nksip:method(), nksip:user_uri(), 
           nksip_lib:optslist(), nksip_lib:optslist()) ->    
    {ok, nksip:request(), nksip_lib:optslist()} | {error, term()}.
    
make(AppId, Method, Uri, Opts, Config) ->
    try
        case nksip_parse:uris(Uri) of
            [RUri] -> ok;
            _ -> RUri = throw(invalid_uri)
        end,
        case nksip_parse:uri_method(RUri, Method) of
            {Method1, RUri1} -> ok;
            error -> Method1 = RUri1 = throw(invalid_uri)
        end,
        FromTag = nksip_lib:uid(),
        DefFrom = #uri{user = <<"user">>, domain = <<"nksip">>, 
                  ext_opts = [{<<"tag">>, FromTag}]},
        DefTo = RUri1#uri{port=0, opts=[], headers=[], ext_opts=[], ext_headers=[]},
        Req1 = #sipmsg{
            id = nksip_lib:uid(),
            class = {req, Method1},
            app_id = AppId,
            ruri = RUri1#uri{headers=[], ext_opts=[], ext_headers=[]},
            from = {DefFrom, FromTag},
            to = {DefTo, <<>>},
            call_id = nksip_lib:luid(),
            cseq = {nksip_config:cseq(), Method1},
            forwards = 70,
            transport = #transport{},
            start = nksip_lib:l_timestamp()
        },
        ConfigOpts = get_config_opts(Config, false),
        {Req2, ReqOpts1} = parse_opts(ConfigOpts, Req1, [], Config),
        Req3 = case RUri of
            #uri{headers=[]} -> Req2;
            #uri{headers=Headers} -> nksip_parse_header:headers(Headers, Req2, post)
        end,
        {Req4, ReqOpts2} = parse_opts(Opts, Req3, ReqOpts1, Config),
        ReqOpts3 = case 
            (Method=='INVITE' orelse Method=='SUBSCRIBE' orelse
             Method=='NOTIFY' orelse Method=='REFER' orelse Method=='UPDATE')
            andalso Req4#sipmsg.contacts==[]
            andalso not lists:member(contact, ReqOpts2)
        of  
            true -> [contact|ReqOpts2];
            false -> ReqOpts2
        end,
        {ok, Req4, ReqOpts3}
    catch
        throw:Throw -> {error, Throw}
    end.


%% @private 
-spec proxy_make(nksip:request(), nksip_lib:optslist(), nksip_lib:optslist()) ->    
    {ok, nksip:request(), nksip_lib:optslist()} | {error, term()}.
    
proxy_make(Req, Opts, Config) ->
    try
        Req1 = case Req#sipmsg.ruri of
            #uri{headers=[]} -> Req;
            #uri{headers=Headers} -> nksip_parse_header:headers(Headers, Req, post)
        end,
        ConfigOpts = get_config_opts(Config, true),
        {Req2, ReqOpts1} = parse_opts(ConfigOpts, Req1, [], Config),
        {Req3, ReqOpts2} = parse_opts(Opts, Req2, ReqOpts1, Config),
        ReqOpts3 = case nksip_outbound:proxy_opts(Req3, ReqOpts2) of
            {ok, ProxyOpts} -> ProxyOpts;
            {error, OutError} -> throw({reply, OutError})
        end,
        Req4 = remove_local_routes(Req3),
        {ok, Req4, ReqOpts3}
    catch
        throw:Throw -> {error, Throw}
    end.


%% @private
get_config_opts(Config, Proxy) ->
    [
        O || O <- Config, 
        case O of
            no_100 -> true;
            {local_host, _} -> true;
            {local_host6, _} -> true;
            {pass, _} -> true;
            {from, _} when not Proxy -> true;
            {route, _} when not Proxy -> true;
            _ -> false
        end
    ].


%% @private
remove_local_routes(#sipmsg{app_id=AppId, routes=Routes}=Req) ->
    case do_remove_local_routes(AppId, Routes) of
        Routes -> Req;
        Routes1 -> Req#sipmsg{routes=Routes1}
    end.


%% @private
do_remove_local_routes(_AppId, []) ->
    [];

do_remove_local_routes(AppId, [Route|RestRoutes]) ->
    case nksip_transport:is_local(AppId, Route) of
        true -> do_remove_local_routes(AppId, RestRoutes);
        false -> [Route|RestRoutes]
    end.




%% @doc Generates a <i>CANCEL</i> request from an <i>INVITE</i> request.
-spec make_cancel(nksip:request(), nksip:error_reason()|undefined) ->
    nksip:request().

make_cancel(Req, Reason) ->
    #sipmsg{
        class = {req, _}, 
        cseq = {CSeq, _}, 
        vias = [Via|_], 
        headers = Hds
    } = Req,
    Headers1 = nksip_lib:extract(Hds, <<"route">>),
    Headers2 = case Reason of
        undefined ->
            Headers1;
        Reason ->
            case nksip_unparse:error_reason(Reason) of
                error -> Headers1;
                BinReason -> [{<<"reason">>, BinReason}|Headers1]
            end
    end,
    Req#sipmsg{
        class = {req, 'CANCEL'},
        id = nksip_lib:uid(),
        cseq = {CSeq, 'CANCEL'},
        forwards = 70,
        vias = [Via],
        headers = Headers2,
        contacts = [],
        content_type = undefined,
        require = [],
        supported = [],
        expires = undefined,
        event = undefined,
        body = <<>>
    }.


%% @doc Generates an <i>ACK</i> request from an <i>INVITE</i> request and a response
-spec make_ack(nksip:request(), nksip:response()) ->
    nksip:request().

make_ack(Req, #sipmsg{to=To}) ->
    make_ack(Req#sipmsg{to=To}).


%% @private
-spec make_ack(nksip:request()) ->
    nksip:request().

make_ack(#sipmsg{vias=[Via|_], cseq={CSeq, _}}=Req) ->
    Req#sipmsg{
        class = {req, 'ACK'},
        id = nksip_lib:uid(),
        vias = [Via],
        cseq = {CSeq, 'ACK'},
        forwards = 70,
        routes = [],
        contacts = [],
        headers = [],
        content_type = undefined,
        require = [],
        supported = [],
        expires = undefined,
        event = undefined,
        body = <<>>
    }.


%% @doc Checks if a response is a stateless response
-spec is_stateless(nksip:response(), binary()) ->
    boolean().

is_stateless(Resp, GlobalId) ->
    #sipmsg{vias=[#via{opts=Opts}|_]} = Resp,
    case nksip_lib:get_binary(<<"branch">>, Opts) of
        <<"z9hG4bK", Branch/binary>> ->
            case binary:split(Branch, <<"-">>) of
                [BaseBranch, NkSip] ->
                    case nksip_lib:hash({BaseBranch, GlobalId, stateless}) of
                        NkSip -> true;
                        _ -> false
                    end;
                _ ->
                    false
            end;
        _ ->
            false
    end.




%% @private
-spec parse_opts(nksip_lib:optslist(), nksip:request(), 
            nksip_lib:optslist(), nksip_lib:optslist()) ->
    {nksip:request(), nksip_lib:optslist()}.


parse_opts([], Req, Opts, _Config) ->
    {Req, Opts};

parse_opts([Term|Rest], Req, Opts, Config) ->
    #sipmsg{class={req, Method}} = Req,
    Op = case Term of
        
        ignore ->
            ignore;

        % Header manipulation
        {add, Name, Value} -> {add, Name, Value};
        {add, {Name, Value}} -> {add, Name, Value};
        {replace, Name, Value} -> {replace, Name, Value};
        {replace, {Name, Value}} -> {replace, Name, Value};
        {insert, Name, Value} -> {insert, Name, Value};
        {insert, {Name, Value}} -> {insert, Name, Value};

        {Name, Value} when Name==from; Name==to; Name==call_id;
                           Name==content_type; Name==require; Name==supported; 
                           Name==expires; Name==contact; Name==route; 
                           Name==reason; Name==event ->
            {replace, Name, Value};

        % Special parameters
        to_as_from ->
            case lists:keymember(from, 1, Rest) of
                false ->
                    #sipmsg{from={From, _}} = Req,
                    {replace, <<"To">>, From#uri{ext_opts=[]}};
                _ ->
                    move_to_last
            end;
        {body, Body} ->
            case lists:keymember(content_type, 1, Rest) of
                false ->
                    ContentType = case Req#sipmsg.content_type of
                        undefined when is_binary(Body) -> undefined;
                        undefined when is_list(Body), is_integer(hd(Body)) -> undefined;
                        undefined when is_record(Body, sdp) -> <<"application/sdp">>;
                        undefined -> <<"application/nksip.ebf.base64">>;
                        CT0 -> CT0
                    end,
                    {update, Req#sipmsg{body=Body, content_type=ContentType}, Opts};
                true ->
                    move_to_last
            end;
        {cseq_num, CSeq} when is_integer(CSeq), CSeq>0, CSeq<4294967296 ->
            #sipmsg{cseq={_, CSeqMethod}} = Req,
            {update, Req#sipmsg{cseq={CSeq, CSeqMethod}}, Opts};
        {min_cseq, MinCSeq} ->
            case lists:keymember(cseq_num, 1, Rest) of
                false -> 
                    #sipmsg{cseq={OldCSeq, CSeqMethod}} =Req,
                    case is_integer(MinCSeq) of
                        true when MinCSeq > OldCSeq -> 
                            {update, Req#sipmsg{cseq={MinCSeq, CSeqMethod}}, Opts};
                        true -> 
                            ignore;
                        false -> 
                            throw({invalid, min_cseq})
                    end;
                true ->
                    move_to_last
            end;

        %% Pass-through options
        _ when Term==contact; Term==record_route; Term==path; Term==get_request;
               Term==get_response; Term==auto_2xx_ack; Term==async; Term==no_100;
               Term==stateless; Term==no_dialog; Term==no_auto_expire;
               Term==follow_redirects ->
            {update, Req, [Term|Opts]};
        {Name, Value} when Name==pass; Name==record_flow; Name==route_flow ->
            {update, Req, [{Name, Value}|Opts]};
        {meta, List} when is_list(List) ->
            {update, Req, [{meta,List}|Opts]};
        {local_host, Host} ->
            {update, Req, [{local_host, nksip_lib:to_host(Host)}|Opts]};
        {local_host6, Host} ->
            case nksip_lib:to_ip(Host) of
                {ok, HostIp6} -> 
                    % Ensure it is enclosed in `[]'
                    {update, Req, [{local_host6, nksip_lib:to_host(HostIp6, true)}|Opts]};
                error -> 
                    {update, Req, [{local_host6, nksip_lib:to_binary(Host)}|Opts]}
            end;
        {callback, Fun} when is_function(Fun, 1) ->
            {update, Req, [{callback, Fun}|Opts]};
        {prack_callback, Fun} when is_function(Fun, 2) ->
            {update, Req, [{prack_callback, Fun}|Opts]};
        {reg_id, RegId} when is_integer(RegId), RegId>0 ->
            {update, Req, [{reg_id, RegId}|Opts]};
        {refer_subscription_id, Refer} when is_binary(Refer) ->
            {update, Req, [{refer_subscription_id, Refer}|Opts]};

        %% Automatic header generation (replace existing headers)
        user_agent ->
            {replace, <<"user-agent">>, <<"NkSIP ", ?VERSION>>};
        supported ->
            Supported = nksip_lib:get_value(supported, Config, ?SUPPORTED),
            {replace, <<"supported">>, Supported};
        allow ->        
            Allow = case nksip_lib:get_value(allow, Config) of
                undefined ->
                    case lists:member(registrar, Config) of
                        true -> <<(?ALLOW)/binary, ",REGISTER">>;
                        false -> ?ALLOW
                    end;
                Allow0 ->
                    Allow0
            end,
            {replace, <<"allow">>, Allow};
        accept ->
            Accept = case nksip_lib:get_value(accept, Config) of
                undefined when Method=='INVITE'; Method=='UPDATE'; Method=='PRACK' ->
                    <<"application/sdp">>;
                undefined ->
                    ?ACCEPT;
                Accept0 ->
                    Accept0
            end, 
            {replace, <<"accept">>, Accept};
        date ->
            Date = nksip_lib:to_binary(httpd_util:rfc1123_date()),
            {replace, <<"date">>, Date};
        allow_event ->
            case nksip_lib:get_value(events, Config) of
                undefined -> ignore;
                Events -> {replace, <<"allow-event">>, Events}
            end;

        % Timer options
        {min_se, SE} when is_binary(SE); is_integer(SE) ->
            {replace, <<"min-se">>, SE};
        {session_expires, SE} when is_integer(SE) ->
            {retry, {session_expires, {SE, undefined}}};
        {session_expires, {SE, Refresh}} when is_integer(SE) ->
            case nksip_config:get_cached(min_session_expires, Config) of
                MinSE when SE<MinSE -> 
                    throw({invalid, session_expires});
                _ when Refresh==undefined -> 
                    {replace, <<"session-expires">>, SE};
                _ when Refresh==uac; Refresh==uas -> 
                    {replace, <<"session-expires">>, {SE, [{<<"refresher">>, Refresh}]}};
                _ ->
                    throw({invalid, session_expires})
            end;

        % Event options
        {subscription_state, ST} when Method=='NOTIFY'->
            Value = case ST of
                {active, undefined} -> 
                    <<"active">>;
                {active, Expires} when is_integer(Expires), Expires>0 ->
                    {<<"active">>, [{<<"expires">>, nksip_lib:to_binary(Expires)}]};
                {pending, undefined} -> 
                    <<"pending">>;
                {pending, Expires} when is_integer(Expires), Expires>0 ->
                    {<<"pending">>, [{<<"expires">>, nksip_lib:to_binary(Expires)}]};
                {terminated, Reason, undefined} when is_atom(Reason) ->
                    {<<"terminated">>, [{<<"reason">>, nksip_lib:to_binary(Reason)}]};
                {terminated, Reason, Retry} when is_atom(Reason), is_integer(Retry) ->
                    {<<"terminated">>, [
                        {<<"reason">>, nksip_lib:to_binary(Reason)},
                        {<<"retry-after">>, Retry}]};
                _ ->
                    throw({invalid, subscription_state})
            end,
            {replace, <<"subscription-state">>, Value};

        % Publish options
        {sip_etag, ETag} ->
            {replace, <<"sip-etag">>, nksip_lib:to_binary(ETag)};

        {Name, _} ->
            throw({invalid, Name});
        _ ->
            throw({invalid, Term})
    end,
    case Op of
        {add, AddName, AddValue} ->
            PName = nksip_parse_header:name(AddName), 
            PReq = nksip_parse_header:parse(PName, AddValue, Req, post),
            parse_opts(Rest, PReq, Opts, Config);
        {replace, RepName, RepValue} ->
            PName = nksip_parse_header:name(RepName), 
            PReq = nksip_parse_header:parse(PName, RepValue, Req, replace),
            parse_opts(Rest, PReq, Opts, Config);
        {insert, InsName, InsValue} ->
            PName = nksip_parse_header:name(InsName), 
            PReq = nksip_parse_header:parse(PName, InsValue, Req, pre),
            parse_opts(Rest, PReq, Opts, Config);
        {update, UpdReq, UpdOpts} -> 
            parse_opts(Rest, UpdReq, UpdOpts, Config);
        {retry, RetTerm} ->
            parse_opts([RetTerm|Rest], Req, Opts, Config);
        move_to_last ->
            parse_opts(Rest++[Term], Req, Opts, Config);
        ignore ->
            parse_opts(Rest, Req, Opts, Config)
    end.





%% ===================================================================
%% EUnit tests
%% ===================================================================


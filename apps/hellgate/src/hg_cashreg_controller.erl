-module(hg_cashreg_controller).

-include_lib("cashreg_proto/include/cashreg_proto_proxy_provider_thrift.hrl").
-include_lib("cashreg_proto/include/cashreg_proto_processing_thrift.hrl").

-define(NS, <<"cashreg">>).

-export([process_callback/2]).

%% Woody handler called by hg_woody_wrapper

-behaviour(hg_woody_wrapper).
-export([handle_function/3]).

%% Machine callbacks

-behaviour(hg_machine).
-export([namespace     /0]).
-export([init          /2]).
-export([process_signal/3]).
-export([process_call  /3]).

% Types
-record(st, {
    receipt_params  :: undefined | receipt_params(),
    proxy           :: undefined | proxy(),
    session         :: undefined | session()
}).
% -type st() :: #st{}.

-type session() :: #{
    status      := undefined | suspended | finished,
    result      => session_result(),
    proxy_state => proxy_state()
}.

-type receipt_params()      :: cashreg_proto_main_thrift:'ReceiptParams'().
-type proxy()               :: cashreg_proto_main_thrift:'Proxy'().
-type receipt_id()          :: cashreg_proto_main_thrift:'ReceiptID'().
-type proxy_state()         :: cashreg_proto_main_thrift:'ProxyState'().
-type session_result()      :: cashreg_proto_processing_thrift:'SessionResult'().
-type tag()                 :: cashreg_proto_proxy_provider_thrift:'CallbackTag'().
-type callback()            :: cashreg_proto_main_thrift:'Callback'().
-type callback_response()   :: _.

%% Woody handler

-spec handle_function(woody:func(), woody:args(), hg_woody_wrapper:handler_opts()) ->
    term() | no_return().

handle_function(Func, Args, Opts) ->
    scoper:scope(cashreg,
        fun() -> handle_function_(Func, Args, Opts) end
    ).
handle_function_('CreateReceipt', [ReceiptInfo, ProxyOptions], _Opts) ->
    ReceiptID = hg_utils:unique_id(),
    ok = set_meta(ReceiptID),
    ok = start(ReceiptID, [ReceiptInfo, ProxyOptions]),
    ReceiptID.

%%

set_meta(ID) ->
    scoper:add_meta(#{id => ID}).

start(ID, Args) ->
    map_start_error(hg_machine:start(?NS, ID, Args)).

map_start_error({ok, _}) ->
    ok;
map_start_error({error, Reason}) ->
    error(Reason).

-include("cashreg_events.hrl").

%% hg_machine callbacks

-spec namespace() ->
    hg_machine:ns().
namespace() ->
    ?NS.

-spec init(receipt_id(), [receipt_params() | proxy()]) ->
    hg_machine:result().
init(_ReceiptID, [ReceiptParams, Proxy]) ->
    ReceiptProxyResult = register_receipt(ReceiptParams, Proxy),
    Changes1 = [?created(ReceiptParams, Proxy), ?session_changed(?session_started())],
    {Changes2, Action, Receipt} = handle_proxy_result(ReceiptProxyResult, hg_machine_action:new()),
    Changes = Changes1 ++ Changes2,
    handle_result(finish_processing({Changes, Action, Receipt}, #st{})).

register_receipt(ReceiptParams, Proxy) ->
    ReceiptContext = construct_receipt_context(ReceiptParams, Proxy),
    Session = construct_session(),
    {ok, ReceiptProxyResult} = hg_cashreg_provider:register_receipt(ReceiptContext, Session, Proxy),
    ReceiptProxyResult.

-spec process_signal(hg_machine:signal(), hg_machine:history(), hg_machine:auxst()) ->
    hg_machine:result().
process_signal(Signal, History, _AuxSt) ->
    handle_result(handle_signal(Signal, collapse_history(unmarshal(History)))).

handle_signal(timeout, St) ->
    process_timeout(St).

process_timeout(#st{session = #{status := Status}} = St) ->
    Action = hg_machine_action:new(),
    case Status of
        undefined ->
            process(Action, St);
        suspended ->
            process_callback_timeout(Action, St)
    end.

process(
    Action,
    #st{
        receipt_params = ReceiptParams,
        proxy = Proxy
    } = St
) ->
    ReceiptProxyResult = register_receipt(ReceiptParams, Proxy),
    Result = handle_proxy_result(ReceiptProxyResult, Action),
    finish_processing(Result, St).

process_callback_timeout(Action, St) ->
    Result = handle_proxy_callback_timeout(Action),
    finish_processing(Result, St).

handle_proxy_callback_timeout(Action) ->
    Changes = [
        ?session_finished(?session_failed({
            receipt_registration_failure, #cashreg_main_ReceiptRegistrationFailure{code = <<"0">>}
        }))
    ],
    make_proxy_result(Changes, Action).

make_proxy_result(Changes, Action) ->
    make_proxy_result(Changes, Action, undefined).

make_proxy_result(Changes, Action, Receipt) ->
    {wrap_session_events(Changes), Action, Receipt}.

wrap_session_events(SessionEvents) ->
    [?session_changed(Ev) || Ev <- SessionEvents].

-spec process_call({callback, tag(), _}, hg_machine:history(), hg_machine:auxst()) ->
    {hg_machine:response(), hg_machine:result()}.
process_call(Call, History, _AuxSt) ->
    St = collapse_history(unmarshal(History)),
    try handle_result(handle_call(Call, St)) catch
        throw:Exception ->
            {{exception, Exception}, #{}}
    end.

handle_call({callback, Callback}, St) ->
    dispatch_callback(Callback, St).

dispatch_callback(
    {provider, Callback},
    #st{
        receipt_params = ReceiptParams,
        proxy = Proxy,
        session = #{status := suspended, proxy_state := ProxyState}
    } = St
) ->
    Action = hg_machine_action:new(),
    ReceiptContext = construct_receipt_context(ReceiptParams, Proxy),
    {ok, CallbackResult} = hg_cashreg_provider:handle_receipt_callback(
        Callback,
        ReceiptContext,
        construct_session(ProxyState),
        Proxy
    ),
    {Response, Result} = handle_callback_result(CallbackResult, Action),
    maps:merge(#{response => Response}, finish_processing(Result, St));
dispatch_callback(_Callback, _St) ->
    throw(invalid_callback).

handle_result(Params) ->
    Result = handle_result_changes(Params, handle_result_action(Params, #{})),
    case maps:find(response, Params) of
        {ok, Response} ->
            {{ok, Response}, Result};
        error ->
            Result
    end.

handle_result_changes(#{changes := Changes = [_ | _]}, Acc) ->
    Acc#{events => [marshal(Changes)]};
handle_result_changes(#{}, Acc) ->
    Acc.

handle_result_action(#{action := Action}, Acc) ->
    Acc#{action => Action}.
% handle_result_action(#{}, Acc) ->
%     Acc.

collapse_history(History) ->
    lists:foldl(
        fun ({_ID, _, Events}, St0) ->
            lists:foldl(fun apply_change/2, St0, Events)
        end,
        #st{},
        History
    ).

apply_changes(Changes, St) ->
    lists:foldl(fun apply_change/2, St, Changes).

apply_change(Event, undefined) ->
    apply_change(Event, #st{});

apply_change(?created(ReceiptParams, Proxy), St) ->
    St#st{
        receipt_params = ReceiptParams,
        proxy = Proxy
    };
apply_change(?registered(_Receipt), St) ->
    St;
apply_change(?failed(_Failure), St) ->
    St;

apply_change(?session_changed(Event), #st{session = Session0} = St) ->
    Session1 = merge_session_change(Event, Session0),
    St#st{session = Session1}.

merge_session_change(?session_started(), _) ->
    #{status => undefined};
merge_session_change(?session_finished(Result), Session) ->
    Session#{status := finished, result => Result};
merge_session_change(?session_suspended(_Tag), Session) ->
    Session#{status := suspended};
merge_session_change(?proxy_st_changed(ProxyState), Session) ->
    Session#{proxy_state => ProxyState}.

-spec process_callback(tag(), {provider, callback()}) ->
    {ok, callback_response()} | {error, invalid_callback | notfound | failed} | no_return().

process_callback(Tag, Callback) ->
    case hg_machine:call(?NS, {tag, Tag}, {callback, Callback}) of
        {ok, {ok, _} = Ok} ->
            Ok;
        {ok, {exception, invalid_callback}} ->
            {error, invalid_callback};
        {error, _} = Error ->
            Error
    end.

update_proxy_state(undefined) ->
    [];
update_proxy_state(ProxyState) ->
    [?proxy_st_changed(ProxyState)].

handle_proxy_intent(#'cashreg_prxprv_FinishIntent'{status = {success, _}}, Action) ->
    Events = [?session_finished(?session_succeeded())],
    {Events, Action};
handle_proxy_intent(#'cashreg_prxprv_FinishIntent'{status = {failure, Error}}, Action) ->
    Events = [?session_finished(?session_failed(Error))],
    {Events, Action};
handle_proxy_intent(#'cashreg_prxprv_SleepIntent'{timer = Timer}, Action0) ->
    Action = hg_machine_action:set_timer(Timer, Action0),
    Events = [],
    {Events, Action};
handle_proxy_intent(#'cashreg_prxprv_SuspendIntent'{tag = Tag, timeout = Timer}, Action0) ->
    Action = hg_machine_action:set_timer(Timer, hg_machine_action:set_tag(Tag, Action0)),
    Events = [?session_suspended(Tag)],
    {Events, Action}.

handle_callback_result(
    #cashreg_prxprv_ReceiptCallbackResult{result = ProxyResult, response = Response},
    Action
) ->
    {Response, handle_proxy_callback_result(ProxyResult, hg_machine_action:unset_timer(Action))}.

handle_proxy_result(
    #cashreg_prxprv_ReceiptProxyResult{
        intent = {_Type, Intent},
        next_state = ProxyState
    },
    Action0
) ->
    Changes1 = update_proxy_state(ProxyState),
    {Changes2, Action} = handle_proxy_intent(Intent, Action0),
    Changes = Changes1 ++ Changes2,
    case Intent of
        #cashreg_prxprv_FinishIntent{status = {'success', #cashreg_prxprv_Success{receipt = Receipt}}} ->
            make_proxy_result(Changes, Action, Receipt);
        _ ->
            make_proxy_result(Changes, Action)
    end.

handle_proxy_callback_result(
    #cashreg_prxprv_ReceiptCallbackProxyResult{intent = {_Type, Intent}, next_state = ProxyState},
    Action0
) ->
    Changes1 = update_proxy_state(ProxyState),
    {Changes2, Action} = handle_proxy_intent(Intent, hg_machine_action:unset_timer(Action0)),
    {wrap_session_events(Changes1 ++ Changes2), Action, undefined}; % FIX ME
handle_proxy_callback_result(
    #cashreg_prxprv_ReceiptCallbackProxyResult{intent = undefined, next_state = ProxyState},
    Action
) ->
    Changes = update_proxy_state(ProxyState),
    {wrap_session_events(Changes), Action, undefined}. % FIX ME

finish_processing({Changes, Action, Receipt}, St) ->
    #st{session = Session} = apply_changes(Changes, St),
    case Session of
        #{status := finished, result := ?session_succeeded()} ->
            #{
                changes => Changes ++ [?registered(Receipt)],
                action  => Action
            };
        #{status := finished, result := ?session_failed(Failure)} ->
            #{
                changes => Changes ++ [?failed(Failure)],
                action  => Action
            };
        #{} ->
            #{
                changes => Changes,
                action  => Action
            }
    end.

construct_receipt_context(ReceiptParams, Proxy) ->
    #cashreg_prxprv_ReceiptContext{
        receipt_params = ReceiptParams,
        options = Proxy#cashreg_main_Proxy.options
    }.

construct_session() ->
    #cashreg_prxprv_Session{
        state = undefined
    }.
construct_session(State) ->
    #cashreg_prxprv_Session{
        state = State
    }.

marshal(Data) ->
    {bin, term_to_binary(Data)}.

unmarshal({ID, Dt, {bin, Binary}}) ->
    {ID, Dt, binary_to_term(Binary)};
unmarshal(Events) ->
    [unmarshal(Event) || Event <- Events].

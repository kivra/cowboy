%% Copyright (c) 2011-2017, Loïc Hoguin <essen@ninenines.eu>
%% Copyright (c) 2011, Anthony Ramine <nox@dev-extend.eu>
%%
%% Permission to use, copy, modify, and/or distribute this software for any
%% purpose with or without fee is hereby granted, provided that the above
%% copyright notice and this permission notice appear in all copies.
%%
%% THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
%% WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
%% MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
%% ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
%% WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
%% ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
%% OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

-module(cowboy_req).

%% Request.
-export([method/1]).
-export([version/1]).
-export([peer/1]).
-export([sock/1]).
-export([cert/1]).
-export([scheme/1]).
-export([host/1]).
-export([host_info/1]).
-export([port/1]).
-export([path/1]).
-export([path_info/1]).
-export([qs/1]).
-export([parse_qs/1]).
-export([match_qs/2]).
-export([uri/1]).
-export([uri/2]).
-export([binding/2]).
-export([binding/3]).
-export([bindings/1]).
-export([header/2]).
-export([header/3]).
-export([headers/1]).
-export([parse_header/2]).
-export([parse_header/3]).
-export([parse_cookies/1]).
-export([match_cookies/2]).

%% Request body.
-export([has_body/1]).
-export([body_length/1]).
-export([read_body/1]).
-export([read_body/2]).
-export([read_urlencoded_body/1]).
-export([read_urlencoded_body/2]).
%% @todo read_and_match_urlencoded_body?

%% Multipart.
-export([read_part/1]).
-export([read_part/2]).
-export([read_part_body/1]).
-export([read_part_body/2]).

%% Response.
-export([set_resp_cookie/3]).
-export([set_resp_cookie/4]).
-export([resp_header/2]).
-export([resp_header/3]).
-export([resp_headers/1]).
-export([set_resp_header/3]).
-export([set_resp_headers/2]).
-export([has_resp_header/2]).
-export([delete_resp_header/2]).
-export([set_resp_body/2]).
%% @todo set_resp_body/3 with a ContentType or even Headers argument, to set content headers.
-export([has_resp_body/1]).
-export([inform/2]).
-export([inform/3]).
-export([reply/2]).
-export([reply/3]).
-export([reply/4]).
-export([stream_reply/2]).
-export([stream_reply/3]).
%% @todo stream_body/2 (nofin)
-export([stream_body/3]).
%% @todo stream_event/2,3
-export([stream_trailers/2]).
-export([push/3]).
-export([push/4]).

%% Internal.
-export([response_headers/2]).

%% @todo Get rid of this type, use cow_cookie directly.
-type cookie_opts() :: map().
-export_type([cookie_opts/0]).

-type read_body_opts() :: #{
	length => non_neg_integer() | infinity,
	period => non_neg_integer(),
	timeout => timeout()
}.
-export_type([read_body_opts/0]).

%% While sendfile allows a Len of 0 that means "everything past Offset",
%% Cowboy expects the real length as it is used as metadata.
%% @todo We should probably explicitly reject it.
-type resp_body() :: iodata()
	| {sendfile, non_neg_integer(), non_neg_integer(), file:name_all()}.
-export_type([resp_body/0]).

-type push_opts() :: #{
	method => binary(),
	scheme => binary(),
	host => binary(),
	port => binary(),
	qs => binary()
}.
-export_type([push_opts/0]).

-type req() :: map(). %% @todo #{
%	ref := ranch:ref(),
%	pid := pid(),
%	streamid := cowboy_stream:streamid(),
%	peer := {inet:ip_address(), inet:port_number()},
%
%	method := binary(), %% case sensitive
%	version := cowboy:http_version() | atom(),
%	scheme := binary(), %% <<"http">> or <<"https">>
%	host := binary(), %% lowercase; case insensitive
%	port := inet:port_number(),
%	path := binary(), %% case sensitive
%	qs := binary(), %% case sensitive
%	headers := cowboy:http_headers(),
%
%	host_info => cowboy_router:tokens(),
%	path_info => cowboy_router:tokens(),
%	bindings => cowboy_router:bindings(),
%
%	has_body := boolean(),
%	has_read_body => true,
%	body_length := undefined | non_neg_integer()
%
%% @todo resp_*
%}.
-export_type([req/0]).

%% Request.

-spec method(req()) -> binary().
method(#{method := Method}) ->
	Method.

-spec version(req()) -> cowboy:http_version().
version(#{version := Version}) ->
	Version.

-spec peer(req()) -> {inet:ip_address(), inet:port_number()}.
peer(#{peer := Peer}) ->
	Peer.

-spec sock(req()) -> {inet:ip_address(), inet:port_number()}.
sock(#{sock := Sock}) ->
	Sock.

-spec cert(req()) -> binary() | undefined.
cert(#{cert := Cert}) ->
	Cert.

-spec scheme(req()) -> binary().
scheme(#{scheme := Scheme}) ->
	Scheme.

-spec host(req()) -> binary().
host(#{host := Host}) ->
	Host.

%% @todo The host_info is undefined if cowboy_router isn't used. Do we want to crash?
-spec host_info(req()) -> cowboy_router:tokens() | undefined.
host_info(#{host_info := HostInfo}) ->
	HostInfo.

-spec port(req()) -> inet:port_number().
port(#{port := Port}) ->
	Port.

-spec path(req()) -> binary().
path(#{path := Path}) ->
	Path.

%% @todo The path_info is undefined if cowboy_router isn't used. Do we want to crash?
-spec path_info(req()) -> cowboy_router:tokens() | undefined.
path_info(#{path_info := PathInfo}) ->
	PathInfo.

-spec qs(req()) -> binary().
qs(#{qs := Qs}) ->
	Qs.

%% @todo Might be useful to limit the number of keys.
-spec parse_qs(req()) -> [{binary(), binary() | true}].
parse_qs(#{qs := Qs}) ->
	try
		cow_qs:parse_qs(Qs)
	catch _:_ ->
		erlang:raise(exit, {request_error, qs,
			'Malformed query string; application/x-www-form-urlencoded expected.'
		}, erlang:get_stacktrace())
	end.

-spec match_qs(cowboy:fields(), req()) -> map().
match_qs(Fields, Req) ->
	case filter(Fields, kvlist_to_map(Fields, parse_qs(Req))) of
		{ok, Map} ->
			Map;
		{error, Errors} ->
			exit({request_error, {match_qs, Errors},
				'Query string validation constraints failed for the reasons provided.'})
	end.

-spec uri(req()) -> iodata().
uri(Req) ->
	uri(Req, #{}).

-spec uri(req(), map()) -> iodata().
uri(#{scheme := Scheme0, host := Host0, port := Port0,
		path := Path0, qs := Qs0}, Opts) ->
	Scheme = case maps:get(scheme, Opts, Scheme0) of
		S = undefined -> S;
		S -> iolist_to_binary(S)
	end,
	Host = maps:get(host, Opts, Host0),
	Port = maps:get(port, Opts, Port0),
	Path = maps:get(path, Opts, Path0),
	Qs = maps:get(qs, Opts, Qs0),
	Fragment = maps:get(fragment, Opts, undefined),
	[uri_host(Scheme, Scheme0, Port, Host), uri_path(Path), uri_qs(Qs), uri_fragment(Fragment)].

uri_host(_, _, _, undefined) -> <<>>;
uri_host(Scheme, Scheme0, Port, Host) ->
	case iolist_size(Host) of
		0 -> <<>>;
		_ -> [uri_scheme(Scheme), <<"//">>, Host, uri_port(Scheme, Scheme0, Port)]
	end.

uri_scheme(undefined) -> <<>>;
uri_scheme(Scheme) ->
	case iolist_size(Scheme) of
		0 -> Scheme;
		_ -> [Scheme, $:]
	end.

uri_port(_, _, undefined) -> <<>>;
uri_port(undefined, <<"http">>, 80) -> <<>>;
uri_port(undefined, <<"https">>, 443) -> <<>>;
uri_port(<<"http">>, _, 80) -> <<>>;
uri_port(<<"https">>, _, 443) -> <<>>;
uri_port(_, _, Port) ->
	[$:, integer_to_binary(Port)].

uri_path(undefined) -> <<>>;
uri_path(Path) -> Path.

uri_qs(undefined) -> <<>>;
uri_qs(Qs) ->
	case iolist_size(Qs) of
		0 -> Qs;
		_ -> [$?, Qs]
	end.

uri_fragment(undefined) -> <<>>;
uri_fragment(Fragment) ->
	case iolist_size(Fragment) of
		0 -> Fragment;
		_ -> [$#, Fragment]
	end.

-ifdef(TEST).
uri1_test() ->
	<<"http://localhost/path">> = iolist_to_binary(uri(#{
		scheme => <<"http">>, host => <<"localhost">>, port => 80,
		path => <<"/path">>, qs => <<>>})),
	<<"http://localhost:443/path">> = iolist_to_binary(uri(#{
		scheme => <<"http">>, host => <<"localhost">>, port => 443,
		path => <<"/path">>, qs => <<>>})),
	<<"http://localhost:8080/path">> = iolist_to_binary(uri(#{
		scheme => <<"http">>, host => <<"localhost">>, port => 8080,
		path => <<"/path">>, qs => <<>>})),
	<<"http://localhost:8080/path?dummy=2785">> = iolist_to_binary(uri(#{
		scheme => <<"http">>, host => <<"localhost">>, port => 8080,
		path => <<"/path">>, qs => <<"dummy=2785">>})),
	<<"https://localhost/path">> = iolist_to_binary(uri(#{
		scheme => <<"https">>, host => <<"localhost">>, port => 443,
		path => <<"/path">>, qs => <<>>})),
	<<"https://localhost:8443/path">> = iolist_to_binary(uri(#{
		scheme => <<"https">>, host => <<"localhost">>, port => 8443,
		path => <<"/path">>, qs => <<>>})),
	<<"https://localhost:8443/path?dummy=2785">> = iolist_to_binary(uri(#{
		scheme => <<"https">>, host => <<"localhost">>, port => 8443,
		path => <<"/path">>, qs => <<"dummy=2785">>})),
	ok.

uri2_test() ->
	Req = #{
		scheme => <<"http">>, host => <<"localhost">>, port => 8080,
		path => <<"/path">>, qs => <<"dummy=2785">>
	},
	<<"http://localhost:8080/path?dummy=2785">> = iolist_to_binary(uri(Req, #{})),
	%% Disable individual components.
	<<"//localhost:8080/path?dummy=2785">> = iolist_to_binary(uri(Req, #{scheme => undefined})),
	<<"/path?dummy=2785">> = iolist_to_binary(uri(Req, #{host => undefined})),
	<<"http://localhost/path?dummy=2785">> = iolist_to_binary(uri(Req, #{port => undefined})),
	<<"http://localhost:8080?dummy=2785">> = iolist_to_binary(uri(Req, #{path => undefined})),
	<<"http://localhost:8080/path">> = iolist_to_binary(uri(Req, #{qs => undefined})),
	<<"http://localhost:8080/path?dummy=2785">> = iolist_to_binary(uri(Req, #{fragment => undefined})),
	<<"http://localhost:8080">> = iolist_to_binary(uri(Req, #{path => undefined, qs => undefined})),
	<<>> = iolist_to_binary(uri(Req, #{host => undefined, path => undefined, qs => undefined})),
	%% Empty values.
	<<"//localhost:8080/path?dummy=2785">> = iolist_to_binary(uri(Req, #{scheme => <<>>})),
	<<"//localhost:8080/path?dummy=2785">> = iolist_to_binary(uri(Req, #{scheme => ""})),
	<<"//localhost:8080/path?dummy=2785">> = iolist_to_binary(uri(Req, #{scheme => [<<>>]})),
	<<"/path?dummy=2785">> = iolist_to_binary(uri(Req, #{host => <<>>})),
	<<"/path?dummy=2785">> = iolist_to_binary(uri(Req, #{host => ""})),
	<<"/path?dummy=2785">> = iolist_to_binary(uri(Req, #{host => [<<>>]})),
	<<"http://localhost:8080?dummy=2785">> = iolist_to_binary(uri(Req, #{path => <<>>})),
	<<"http://localhost:8080?dummy=2785">> = iolist_to_binary(uri(Req, #{path => ""})),
	<<"http://localhost:8080?dummy=2785">> = iolist_to_binary(uri(Req, #{path => [<<>>]})),
	<<"http://localhost:8080/path">> = iolist_to_binary(uri(Req, #{qs => <<>>})),
	<<"http://localhost:8080/path">> = iolist_to_binary(uri(Req, #{qs => ""})),
	<<"http://localhost:8080/path">> = iolist_to_binary(uri(Req, #{qs => [<<>>]})),
	<<"http://localhost:8080/path?dummy=2785">> = iolist_to_binary(uri(Req, #{fragment => <<>>})),
	<<"http://localhost:8080/path?dummy=2785">> = iolist_to_binary(uri(Req, #{fragment => ""})),
	<<"http://localhost:8080/path?dummy=2785">> = iolist_to_binary(uri(Req, #{fragment => [<<>>]})),
	%% Port is integer() | undefined.
	{'EXIT', _} = (catch iolist_to_binary(uri(Req, #{port => <<>>}))),
	{'EXIT', _} = (catch iolist_to_binary(uri(Req, #{port => ""}))),
	{'EXIT', _} = (catch iolist_to_binary(uri(Req, #{port => [<<>>]}))),
	%% Update components.
	<<"https://localhost:8080/path?dummy=2785">> = iolist_to_binary(uri(Req, #{scheme => "https"})),
	<<"http://example.org:8080/path?dummy=2785">> = iolist_to_binary(uri(Req, #{host => "example.org"})),
	<<"http://localhost:123/path?dummy=2785">> = iolist_to_binary(uri(Req, #{port => 123})),
	<<"http://localhost:8080/custom?dummy=2785">> = iolist_to_binary(uri(Req, #{path => "/custom"})),
	<<"http://localhost:8080/path?smart=42">> = iolist_to_binary(uri(Req, #{qs => "smart=42"})),
	<<"http://localhost:8080/path?dummy=2785#intro">> = iolist_to_binary(uri(Req, #{fragment => "intro"})),
	%% Interesting combinations.
	<<"http://localhost/path?dummy=2785">> = iolist_to_binary(uri(Req, #{port => 80})),
	<<"https://localhost/path?dummy=2785">> = iolist_to_binary(uri(Req, #{scheme => "https", port => 443})),
	ok.
-endif.

-spec binding(atom(), req()) -> any() | undefined.
binding(Name, Req) ->
	binding(Name, Req, undefined).

-spec binding(atom(), req(), Default) -> any() | Default when Default::any().
binding(Name, #{bindings := Bindings}, Default) when is_atom(Name) ->
	case Bindings of
		#{Name := Value} -> Value;
		_ -> Default
	end;
binding(Name, _, Default) when is_atom(Name) ->
	Default.

-spec bindings(req()) -> cowboy_router:bindings().
bindings(#{bindings := Bindings}) ->
	Bindings;
bindings(_) ->
	#{}.

-spec header(binary(), req()) -> binary() | undefined.
header(Name, Req) ->
	header(Name, Req, undefined).

-spec header(binary(), req(), Default) -> binary() | Default when Default::any().
header(Name, #{headers := Headers}, Default) ->
	maps:get(Name, Headers, Default).

-spec headers(req()) -> cowboy:http_headers().
headers(#{headers := Headers}) ->
	Headers.

-spec parse_header(binary(), Req) -> any() when Req::req().
parse_header(Name = <<"content-length">>, Req) ->
	parse_header(Name, Req, 0);
parse_header(Name = <<"cookie">>, Req) ->
	parse_header(Name, Req, []);
parse_header(Name, Req) ->
	parse_header(Name, Req, undefined).

-spec parse_header(binary(), Req, any()) -> any() when Req::req().
parse_header(Name, Req, Default) ->
	try
		parse_header(Name, Req, Default, parse_header_fun(Name))
	catch _:_ ->
		erlang:raise(exit, {request_error, {header, Name},
			'Malformed header. Please consult the relevant specification.'
		}, erlang:get_stacktrace())
	end.

parse_header_fun(<<"accept">>) -> fun cow_http_hd:parse_accept/1;
parse_header_fun(<<"accept-charset">>) -> fun cow_http_hd:parse_accept_charset/1;
parse_header_fun(<<"accept-encoding">>) -> fun cow_http_hd:parse_accept_encoding/1;
parse_header_fun(<<"accept-language">>) -> fun cow_http_hd:parse_accept_language/1;
parse_header_fun(<<"authorization">>) -> fun cow_http_hd:parse_authorization/1;
parse_header_fun(<<"connection">>) -> fun cow_http_hd:parse_connection/1;
parse_header_fun(<<"content-length">>) -> fun cow_http_hd:parse_content_length/1;
parse_header_fun(<<"content-type">>) -> fun cow_http_hd:parse_content_type/1;
parse_header_fun(<<"cookie">>) -> fun cow_cookie:parse_cookie/1;
parse_header_fun(<<"expect">>) -> fun cow_http_hd:parse_expect/1;
parse_header_fun(<<"if-match">>) -> fun cow_http_hd:parse_if_match/1;
parse_header_fun(<<"if-modified-since">>) -> fun cow_http_hd:parse_if_modified_since/1;
parse_header_fun(<<"if-none-match">>) -> fun cow_http_hd:parse_if_none_match/1;
parse_header_fun(<<"if-unmodified-since">>) -> fun cow_http_hd:parse_if_unmodified_since/1;
parse_header_fun(<<"range">>) -> fun cow_http_hd:parse_range/1;
parse_header_fun(<<"sec-websocket-extensions">>) -> fun cow_http_hd:parse_sec_websocket_extensions/1;
parse_header_fun(<<"sec-websocket-protocol">>) -> fun cow_http_hd:parse_sec_websocket_protocol_req/1;
parse_header_fun(<<"upgrade">>) -> fun cow_http_hd:parse_upgrade/1;
parse_header_fun(<<"x-forwarded-for">>) -> fun cow_http_hd:parse_x_forwarded_for/1.

parse_header(Name, Req, Default, ParseFun) ->
	case header(Name, Req) of
		undefined -> Default;
		Value -> ParseFun(Value)
	end.

-spec parse_cookies(req()) -> [{binary(), binary()}].
parse_cookies(Req) ->
	parse_header(<<"cookie">>, Req).

-spec match_cookies(cowboy:fields(), req()) -> map().
match_cookies(Fields, Req) ->
	case filter(Fields, kvlist_to_map(Fields, parse_cookies(Req))) of
		{ok, Map} ->
			Map;
		{error, Errors} ->
			exit({request_error, {match_cookies, Errors},
				'Cookie validation constraints failed for the reasons provided.'})
	end.

%% Request body.

-spec has_body(req()) -> boolean().
has_body(#{has_body := HasBody}) ->
	HasBody.

%% The length may not be known if HTTP/1.1 with a transfer-encoding;
%% or HTTP/2 with no content-length header. The length is always
%% known once the body has been completely read.
-spec body_length(req()) -> undefined | non_neg_integer().
body_length(#{body_length := Length}) ->
	Length.

-spec read_body(Req) -> {ok, binary(), Req} | {more, binary(), Req} when Req::req().
read_body(Req) ->
	read_body(Req, #{}).

-spec read_body(Req, read_body_opts()) -> {ok, binary(), Req} | {more, binary(), Req} when Req::req().
read_body(Req=#{has_body := false}, _) ->
	{ok, <<>>, Req};
read_body(Req=#{has_read_body := true}, _) ->
	{ok, <<>>, Req};
read_body(Req=#{pid := Pid, streamid := StreamID}, Opts) ->
	Length = maps:get(length, Opts, 8000000),
	Period = maps:get(period, Opts, 15000),
	Timeout = maps:get(timeout, Opts, Period + 1000),
	Ref = make_ref(),
	Pid ! {{Pid, StreamID}, {read_body, Ref, Length, Period}},
	receive
		{request_body, Ref, nofin, Body} ->
			{more, Body, Req};
		{request_body, Ref, fin, BodyLength, Body} ->
			{ok, Body, set_body_length(Req, BodyLength)}
	after Timeout ->
		exit(timeout)
	end.

set_body_length(Req=#{headers := Headers}, BodyLength) ->
	Req#{
		headers => Headers#{<<"content-length">> => integer_to_binary(BodyLength)},
		body_length => BodyLength,
		has_read_body => true
	}.

-spec read_urlencoded_body(Req) -> {ok, [{binary(), binary() | true}], Req} when Req::req().
read_urlencoded_body(Req) ->
	read_urlencoded_body(Req, #{length => 64000, period => 5000}).

-spec read_urlencoded_body(Req, read_body_opts()) -> {ok, [{binary(), binary() | true}], Req} when Req::req().
read_urlencoded_body(Req0, Opts) ->
	case read_body(Req0, Opts) of
		{ok, Body, Req} ->
			try
				{ok, cow_qs:parse_qs(Body), Req}
			catch _:_ ->
				erlang:raise(exit, {request_error, urlencoded_body,
					'Malformed body; application/x-www-form-urlencoded expected.'
				}, erlang:get_stacktrace())
			end;
		{more, Body, _} ->
			Length = maps:get(length, Opts, 64000),
			if
				byte_size(Body) < Length ->
					exit({request_error, timeout,
						'The request body was not received within the configured time.'});
				true ->
					exit({request_error, payload_too_large,
						'The request body is larger than allowed by configuration.'})
			end
	end.

%% Multipart.

-spec read_part(Req)
	-> {ok, cow_multipart:headers(), Req} | {done, Req}
	when Req::req().
read_part(Req) ->
	read_part(Req, #{length => 64000, period => 5000}).

-spec read_part(Req, read_body_opts())
	-> {ok, #{binary() => binary()}, Req} | {done, Req}
	when Req::req().
read_part(Req, Opts) ->
	case maps:is_key(multipart, Req) of
		true ->
			{Data, Req2} = stream_multipart(Req, Opts, headers),
			read_part(Data, Opts, Req2);
		false ->
			read_part(init_multipart(Req), Opts)
	end.

read_part(Buffer, Opts, Req=#{multipart := {Boundary, _}}) ->
	try cow_multipart:parse_headers(Buffer, Boundary) of
		more ->
			{Data, Req2} = stream_multipart(Req, Opts, headers),
			read_part(<< Buffer/binary, Data/binary >>, Opts, Req2);
		{more, Buffer2} ->
			{Data, Req2} = stream_multipart(Req, Opts, headers),
			read_part(<< Buffer2/binary, Data/binary >>, Opts, Req2);
		{ok, Headers0, Rest} ->
			Headers = maps:from_list(Headers0),
			%% Reject multipart content containing duplicate headers.
			true = map_size(Headers) =:= length(Headers0),
			{ok, Headers, Req#{multipart => {Boundary, Rest}}};
		%% Ignore epilogue.
		{done, _} ->
			{done, Req#{multipart => done}}
	catch _:_ ->
		erlang:raise(exit, {request_error, {multipart, headers},
			'Malformed body; multipart expected.'
		}, erlang:get_stacktrace())
	end.

-spec read_part_body(Req)
	-> {ok, binary(), Req} | {more, binary(), Req}
	when Req::req().
read_part_body(Req) ->
	read_part_body(Req, #{}).

-spec read_part_body(Req, read_body_opts())
	-> {ok, binary(), Req} | {more, binary(), Req}
	when Req::req().
read_part_body(Req, Opts) ->
	case maps:is_key(multipart, Req) of
		true ->
			read_part_body(<<>>, Opts, Req, <<>>);
		false ->
			read_part_body(init_multipart(Req), Opts)
	end.

read_part_body(Buffer, Opts, Req=#{multipart := {Boundary, _}}, Acc) ->
	Length = maps:get(length, Opts, 8000000),
	case byte_size(Acc) > Length of
		true ->
			{more, Acc, Req#{multipart => {Boundary, Buffer}}};
		false ->
			{Data, Req2} = stream_multipart(Req, Opts, body),
			case cow_multipart:parse_body(<< Buffer/binary, Data/binary >>, Boundary) of
				{ok, Body} ->
					read_part_body(<<>>, Opts, Req2, << Acc/binary, Body/binary >>);
				{ok, Body, Rest} ->
					read_part_body(Rest, Opts, Req2, << Acc/binary, Body/binary >>);
				done ->
					{ok, Acc, Req2};
				{done, Body} ->
					{ok, << Acc/binary, Body/binary >>, Req2};
				{done, Body, Rest} ->
					{ok, << Acc/binary, Body/binary >>,
						Req2#{multipart => {Boundary, Rest}}}
			end
	end.

init_multipart(Req) ->
	{<<"multipart">>, _, Params} = parse_header(<<"content-type">>, Req),
	case lists:keyfind(<<"boundary">>, 1, Params) of
		{_, Boundary} ->
			Req#{multipart => {Boundary, <<>>}};
		false ->
			exit({request_error, {multipart, boundary},
				'Missing boundary parameter for multipart media type.'})
	end.

stream_multipart(Req=#{multipart := done}, _, _) ->
	{<<>>, Req};
stream_multipart(Req=#{multipart := {_, <<>>}}, Opts, Type) ->
	case read_body(Req, Opts) of
		{more, Data, Req2} ->
			{Data, Req2};
		%% We crash when the data ends unexpectedly.
		{ok, <<>>, _} ->
			exit({request_error, {multipart, Type},
				'Malformed body; multipart expected.'});
		{ok, Data, Req2} ->
			{Data, Req2}
	end;
stream_multipart(Req=#{multipart := {Boundary, Buffer}}, _, _) ->
	{Buffer, Req#{multipart => {Boundary, <<>>}}}.

%% Response.

-spec set_resp_cookie(iodata(), iodata(), Req)
	-> Req when Req::req().
set_resp_cookie(Name, Value, Req) ->
	set_resp_cookie(Name, Value, Req, #{}).

%% The cookie name cannot contain any of the following characters:
%%   =,;\s\t\r\n\013\014
%%
%% The cookie value cannot contain any of the following characters:
%%   ,; \t\r\n\013\014
%% @todo Fix the cookie_opts() type.
-spec set_resp_cookie(binary(), iodata(), Req, cookie_opts())
	-> Req when Req::req().
set_resp_cookie(Name, Value, Req, Opts) ->
	Cookie = cow_cookie:setcookie(Name, Value, maps:to_list(Opts)),
	RespCookies = maps:get(resp_cookies, Req, #{}),
	Req#{resp_cookies => RespCookies#{Name => Cookie}}.

%% @todo We could add has_resp_cookie and delete_resp_cookie now.

-spec set_resp_header(binary(), iodata(), Req)
	-> Req when Req::req().
set_resp_header(Name, Value, Req=#{resp_headers := RespHeaders}) ->
	Req#{resp_headers => RespHeaders#{Name => Value}};
set_resp_header(Name,Value, Req) ->
	Req#{resp_headers => #{Name => Value}}.

-spec set_resp_headers(cowboy:http_headers(), Req)
	-> Req when Req::req().
set_resp_headers(Headers, Req=#{resp_headers := RespHeaders}) ->
	Req#{resp_headers => maps:merge(RespHeaders, Headers)};
set_resp_headers(Headers, Req) ->
	Req#{resp_headers => Headers}.

-spec resp_header(binary(), req()) -> binary() | undefined.
resp_header(Name, Req) ->
	resp_header(Name, Req, undefined).

-spec resp_header(binary(), req(), Default)
	-> binary() | Default when Default::any().
resp_header(Name, #{resp_headers := Headers}, Default) ->
	maps:get(Name, Headers, Default);
resp_header(_, #{}, Default) ->
	Default.

-spec resp_headers(req()) -> cowboy:http_headers().
resp_headers(#{resp_headers := RespHeaders}) ->
	RespHeaders;
resp_headers(#{}) ->
	#{}.

-spec set_resp_body(resp_body(), Req) -> Req when Req::req().
set_resp_body(Body, Req) ->
	Req#{resp_body => Body}.

-spec has_resp_header(binary(), req()) -> boolean().
has_resp_header(Name, #{resp_headers := RespHeaders}) ->
	maps:is_key(Name, RespHeaders);
has_resp_header(_, _) ->
	false.

-spec has_resp_body(req()) -> boolean().
has_resp_body(#{resp_body := {sendfile, _, _, _}}) ->
	true;
has_resp_body(#{resp_body := RespBody}) ->
	iolist_size(RespBody) > 0;
has_resp_body(_) ->
	false.

-spec delete_resp_header(binary(), Req)
	-> Req when Req::req().
delete_resp_header(Name, Req=#{resp_headers := RespHeaders}) ->
	Req#{resp_headers => maps:remove(Name, RespHeaders)}.

-spec inform(cowboy:http_status(), req()) -> ok.
inform(Status, Req) ->
	inform(Status, #{}, Req).

-spec inform(cowboy:http_status(), cowboy:http_headers(), req()) -> ok.
inform(_, _, #{has_sent_resp := _}) ->
	error(function_clause); %% @todo Better error message.
inform(Status, Headers, #{pid := Pid, streamid := StreamID})
		when is_integer(Status); is_binary(Status) ->
	Pid ! {{Pid, StreamID}, {inform, Status, Headers}},
	ok.

-spec reply(cowboy:http_status(), Req) -> Req when Req::req().
reply(Status, Req) ->
	reply(Status, #{}, Req).

-spec reply(cowboy:http_status(), cowboy:http_headers(), Req)
	-> Req when Req::req().
reply(Status, Headers, Req=#{resp_body := Body}) ->
	reply(Status, Headers, Body, Req);
reply(Status, Headers, Req) ->
	reply(Status, Headers, <<>>, Req).

-spec reply(cowboy:http_status(), cowboy:http_headers(), resp_body(), Req)
	-> Req when Req::req().
reply(_, _, _, #{has_sent_resp := _}) ->
	error(function_clause); %% @todo Better error message.
reply(Status, Headers, {sendfile, _, 0, _}, Req)
		when is_integer(Status); is_binary(Status) ->
	do_reply(Status, Headers#{
		<<"content-length">> => <<"0">>
	}, <<>>, Req);
reply(Status, Headers, SendFile = {sendfile, _, Len, _}, Req)
		when is_integer(Status); is_binary(Status) ->
	do_reply(Status, Headers#{
		<<"content-length">> => integer_to_binary(Len)
	}, SendFile, Req);
%% 204 responses must not include content-length. (RFC7230 3.3.1, RFC7230 3.3.2)
reply(Status=204, Headers, Body, Req) ->
	do_reply(Status, Headers, Body, Req);
reply(Status= <<"204",_/bits>>, Headers, Body, Req) ->
	do_reply(Status, Headers, Body, Req);
reply(Status, Headers, Body, Req)
		when is_integer(Status); is_binary(Status) ->
	do_reply(Status, Headers#{
		<<"content-length">> => integer_to_binary(iolist_size(Body))
	}, Body, Req).

%% Don't send any body for HEAD responses. While the protocol code is
%% supposed to enforce this rule, we prefer to avoid copying too much
%% data around if we can avoid it.
do_reply(Status, Headers, _, Req=#{pid := Pid, streamid := StreamID, method := <<"HEAD">>}) ->
	Pid ! {{Pid, StreamID}, {response, Status, response_headers(Headers, Req), <<>>}},
	done_replying(Req, true);
do_reply(Status, Headers, Body, Req=#{pid := Pid, streamid := StreamID}) ->
	Pid ! {{Pid, StreamID}, {response, Status, response_headers(Headers, Req), Body}},
	done_replying(Req, true).

done_replying(Req, HasSentResp) ->
	maps:without([resp_cookies, resp_headers, resp_body], Req#{has_sent_resp => HasSentResp}).

-spec stream_reply(cowboy:http_status(), Req) -> Req when Req::req().
stream_reply(Status, Req) ->
	stream_reply(Status, #{}, Req).

-spec stream_reply(cowboy:http_status(), cowboy:http_headers(), Req)
	-> Req when Req::req().
stream_reply(_, _, #{has_sent_resp := _}) ->
	error(function_clause);
stream_reply(Status, Headers=#{}, Req=#{pid := Pid, streamid := StreamID})
		when is_integer(Status); is_binary(Status) ->
	Pid ! {{Pid, StreamID}, {headers, Status, response_headers(Headers, Req)}},
	done_replying(Req, headers).

-spec stream_body(iodata(), fin | nofin, req()) -> ok.
%% Error out if headers were not sent.
%% Don't send any body for HEAD responses.
stream_body(_, _, #{method := <<"HEAD">>, has_sent_resp := headers}) ->
	ok;
%% Don't send a message if the data is empty, except for the
%% very last message with IsFin=fin.
stream_body(Data, IsFin=nofin, #{pid := Pid, streamid := StreamID, has_sent_resp := headers}) ->
	case iolist_size(Data) of
		0 -> ok;
		_ ->
			Pid ! {{Pid, StreamID}, {data, IsFin, Data}},
			ok
	end;
stream_body(Data, IsFin, #{pid := Pid, streamid := StreamID, has_sent_resp := headers}) ->
	Pid ! {{Pid, StreamID}, {data, IsFin, Data}},
	ok.

-spec stream_trailers(cowboy:http_headers(), req()) -> ok.
stream_trailers(Trailers, #{pid := Pid, streamid := StreamID, has_sent_resp := headers}) ->
	Pid ! {{Pid, StreamID}, {trailers, Trailers}},
	ok.

-spec push(binary(), cowboy:http_headers(), req()) -> ok.
push(Path, Headers, Req) ->
	push(Path, Headers, Req, #{}).

%% @todo Optimization: don't send anything at all for HTTP/1.0 and HTTP/1.1.
%% @todo Path, Headers, Opts, everything should be in proper binary,
%% or normalized when creating the Req object.
-spec push(iodata(), cowboy:http_headers(), req(), push_opts()) -> ok.
push(Path, Headers, #{pid := Pid, streamid := StreamID,
		scheme := Scheme0, host := Host0, port := Port0}, Opts) ->
	Method = maps:get(method, Opts, <<"GET">>),
	Scheme = maps:get(scheme, Opts, Scheme0),
	Host = maps:get(host, Opts, Host0),
	Port = maps:get(port, Opts, Port0),
	Qs = maps:get(qs, Opts, <<>>),
	Pid ! {{Pid, StreamID}, {push, Method, Scheme, Host, Port, Path, Qs, Headers}},
	ok.

%% Internal.

%% @todo What about set-cookie headers set through set_resp_header or reply?
-spec response_headers(Headers, req()) -> Headers when Headers::cowboy:http_headers().
response_headers(Headers0, Req) ->
	RespHeaders = maps:get(resp_headers, Req, #{}),
	Headers = maps:merge(#{
		<<"date">> => cowboy_clock:rfc1123(),
		<<"server">> => <<"Cowboy">>
	}, maps:merge(RespHeaders, Headers0)),
	%% The set-cookie header is special; we can only send one cookie per header.
	%% We send the list of values for many cookies in one key of the map,
	%% and let the protocols deal with it directly.
	case maps:get(resp_cookies, Req, undefined) of
		undefined -> Headers;
		RespCookies -> Headers#{<<"set-cookie">> => maps:values(RespCookies)}
	end.

%% Create map, convert keys to atoms and group duplicate keys into lists.
%% Keys that are not found in the user provided list are entirely skipped.
%% @todo Can probably be done directly while parsing.
kvlist_to_map(Fields, KvList) ->
	Keys = [case K of
		{Key, _} -> Key;
		{Key, _, _} -> Key;
		Key -> Key
	end || K <- Fields],
	kvlist_to_map(Keys, KvList, #{}).

kvlist_to_map(_, [], Map) ->
	Map;
kvlist_to_map(Keys, [{Key, Value}|Tail], Map) ->
	try binary_to_existing_atom(Key, utf8) of
		Atom ->
			case lists:member(Atom, Keys) of
				true ->
					case maps:find(Atom, Map) of
						{ok, MapValue} when is_list(MapValue) ->
							kvlist_to_map(Keys, Tail,
								Map#{Atom => [Value|MapValue]});
						{ok, MapValue} ->
							kvlist_to_map(Keys, Tail,
								Map#{Atom => [Value, MapValue]});
						error ->
							kvlist_to_map(Keys, Tail,
								Map#{Atom => Value})
					end;
				false ->
					kvlist_to_map(Keys, Tail, Map)
			end
	catch error:badarg ->
		kvlist_to_map(Keys, Tail, Map)
	end.

filter(Fields, Map0) ->
	filter(Fields, Map0, #{}).

%% Loop through fields, if value is missing and no default,
%% record the error; else if value is missing and has a
%% default, set default; otherwise apply constraints. If
%% constraint fails, record the error.
%%
%% When there is an error at the end, crash.
filter([], Map, Errors) ->
	case maps:size(Errors) of
		0 -> {ok, Map};
		_ -> {error, Errors}
	end;
filter([{Key, Constraints}|Tail], Map, Errors) ->
	filter_constraints(Tail, Map, Errors, Key, maps:get(Key, Map), Constraints);
filter([{Key, Constraints, Default}|Tail], Map, Errors) ->
	case maps:find(Key, Map) of
		{ok, Value} ->
			filter_constraints(Tail, Map, Errors, Key, Value, Constraints);
		error ->
			filter(Tail, Map#{Key => Default}, Errors)
	end;
filter([Key|Tail], Map, Errors) ->
	case maps:is_key(Key, Map) of
		true ->
			filter(Tail, Map, Errors);
		false ->
			filter(Tail, Map, Errors#{Key => required})
	end.

filter_constraints(Tail, Map, Errors, Key, Value0, Constraints) ->
	case cowboy_constraints:validate(Value0, Constraints) of
		{ok, Value} ->
			filter(Tail, Map#{Key => Value}, Errors);
		{error, Reason} ->
			filter(Tail, Map, Errors#{Key => Reason})
	end.

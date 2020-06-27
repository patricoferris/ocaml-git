(*
 * Copyright (c) 2013-2017 Thomas Gazagnaire <thomas@gazagnaire.org>
 * and Romain Calascibetta <romain.calascibetta@gmail.com>
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *)

open Lwt.Infix

let ( >!= ) = Lwt_result.bind_lwt_err
let ( >?= ) = Lwt_result.bind

module Default = struct
  let capabilites =
    [ `Multi_ack_detailed; `Thin_pack; `Side_band_64k; `Ofs_delta
    ; `Agent "git/2.0.0"; `Report_status; `No_done ]
end

module Option = struct
  let mem v x ~equal = match v with Some x' -> equal x x' | None -> false

  let value_exn v ~error =
    match v with Some v -> v | None -> Fmt.invalid_arg error

  let map_default f default = function Some v -> f v | None -> default
end

module type ENDPOINT = sig
  include Git.Sync.ENDPOINT

  type headers

  val headers : t -> headers
  val with_uri : Uri.t -> t -> t
end

module type CLIENT = sig
  type headers
  type body
  type resp
  type meth
  type endpoint
  type +'a io

  val call : ?headers:headers -> ?body:body -> meth -> endpoint -> resp io
end

module type FLOW = sig
  type raw
  type +'a io
  type i = (raw * int * int) option -> unit io
  type o = unit -> (raw * int * int) option io
end

module Lwt_cstruct_flow = struct
  type raw = Cstruct.t
  type +'a io = 'a Lwt.t
  type i = (raw * int * int) option -> unit io
  type o = unit -> (raw * int * int) option io
end

module type S = sig
  module Web : Web.S

  module Client :
    CLIENT
    with type headers = Web.HTTP.headers
     and type meth = Web.HTTP.meth
     and type resp = Web.resp

  module Endpoint :
    ENDPOINT with type t = Client.endpoint and type headers = Client.headers

  include Git.Sync.S with module Endpoint := Endpoint
end

module type COHTTP_S =
  S
  with type Web.req = Web_cohttp_lwt.req
   and type Web.resp = Web_cohttp_lwt.resp
   and type 'a Web.io = 'a Web_cohttp_lwt.io
   and type Web.raw = Web_cohttp_lwt.raw
   and type Web.uri = Web_cohttp_lwt.uri
   and type Web.Request.body = Web_cohttp_lwt.Request.body
   and type Web.Response.body = Web_cohttp_lwt.Response.body
   and type Web.HTTP.headers = Web_cohttp_lwt.HTTP.headers

module Make
    (W : Web.S
         with type +'a io = 'a Lwt.t
          and type raw = Cstruct.t
          and type uri = Uri.t
          and type Request.body = Lwt_cstruct_flow.i
          and type Response.body = Lwt_cstruct_flow.o)
    (C : CLIENT
         with type +'a io = 'a W.io
          and type headers = W.HTTP.headers
          and type body = Lwt_cstruct_flow.o
          and type meth = W.HTTP.meth
          and type resp = W.resp)
    (E : ENDPOINT with type t = C.endpoint and type headers = C.headers)
    (G : Git.S) =
struct
  module Web = W
  module Client = C
  module Store = G
  module Endpoint = E
  module Common = Git.Smart.Common (Store.Hash) (Store.Reference)
  module Decoder = Git.Smart.Decoder (Store.Hash) (Store.Reference) (Common)
  module Encoder = Git.Smart.Encoder (Store.Hash) (Store.Reference) (Common)

  type error =
    [`Smart of Decoder.error | `Store of Store.error | `Sync of string]

  let pp_error ppf = function
    | `Smart err -> Fmt.pf ppf "(`Smart %a)" Decoder.pp_error err
    | `Store err -> Fmt.pf ppf "(`Store %a)" Store.pp_error err
    | `Sync err -> Fmt.pf ppf "(`Sync %s)" err

  let src = Logs.Src.create "git.sync.http" ~doc:"logs git's sync http event"

  module Log = (val Logs.src_log src : Logs.LOG)

  let default_stdout raw =
    Log.info (fun l -> l "%S" (Cstruct.to_string raw)) ;
    Lwt.return ()

  let default_stderr raw =
    Log.err (fun l -> l "%S" (Cstruct.to_string raw)) ;
    Lwt.return ()

  let populate git ?(stdout = default_stdout) ?(stderr = default_stderr) stream
      =
    let cstruct_copy cs =
      let ln = Cstruct.len cs in
      let rt = Cstruct.create ln in
      Cstruct.blit cs 0 rt 0 ln ; rt
    in
    let stream', push = Lwt_stream.create () in
    let rec dispatch () =
      stream ()
      >>= function
      | Ok (`Out raw) -> stdout raw >>= dispatch
      | Ok (`Raw raw) ->
          Log.debug (fun l ->
              l "Retrieve a chunk of the PACK stream (length: %d)."
                (Cstruct.len raw) ) ;
          push (Some (cstruct_copy raw)) ;
          dispatch ()
      | Ok (`Err raw) -> stderr raw >>= dispatch
      | Ok `End ->
          Log.debug (fun l -> l "Retrieve end of the PACK stream.") ;
          push None ;
          Lwt.return (Ok ())
      | Error err -> Log.err (fun f -> f "It all went wrong for the first one!"); Lwt.return (Error (`Smart err))
    in
    dispatch ()
    >?= fun () ->
    Store.Pack.from git (fun () -> Lwt_stream.get stream')
    >!= fun err -> Lwt.return (`Store err)

  let producer ?(final = fun () -> Lwt.return None) state =
    let state' = ref (fun () -> state) in
    let go () =
      match !state' () with
      | Encoder.Write {buffer; off; len; continue} ->
          (state' := fun () -> continue len) ;
          Lwt.return (Some (buffer, off, len))
      | Encoder.Ok () ->
          (* ensure to jump only in this case (it's a concat stream). *)
          (state' := fun () -> Encoder.Ok ()) ;
          final ()
    in
    go

  let rec consume stream ?keep state =
    match state with
    | Decoder.Ok v -> Lwt.return (Ok v)
    | Decoder.Error {err; _} -> Lwt.return (Error err)
    | Decoder.Read {buffer; off; len; continue} -> (
        ( match keep with
        | Some (raw, off', len') -> Lwt.return (Some (raw, off', len'))
        | None -> stream () )
        >>= function
        | Some (raw, off', len') ->
            let len'' = min len len' in
            Cstruct.blit raw off' buffer off len'' ;
            if len' - len'' = 0 then consume stream (continue len'')
            else
              consume stream
                ~keep:(raw, off' + len'', len' - len'')
                (continue len'')
        | None -> Lwt.return (Error `Unexpected_end_of_input) )

  let extract endpoint =
    let uri = E.uri endpoint in
    ( Option.mem (Uri.scheme uri) "https" ~equal:String.equal
    , Option.value_exn ~error:"Invalid http(s) uri: no host" (Uri.host uri)
    , Uri.path_and_query uri
    , Uri.port uri
    , Uri.userinfo uri )

  let ls _ ?(capabilities = Default.capabilites) endpoint =
    let https, host, path, port, userinfo = extract endpoint in
    let scheme = if https then "https" else "http" in
    (* XXX(dinosaure): not sure if it's the best to rewrite [uri]. TODO! *)
    let uri =
      Uri.empty
      |> (fun uri -> Uri.with_scheme uri (Some scheme))
      |> (fun uri -> Uri.with_host uri (Some host))
      |> (fun uri ->
           Uri.with_path uri (String.concat "/" [path; "info"; "refs"]) )
      |> (fun uri -> Uri.with_port uri port)
      |> (fun uri -> Uri.with_userinfo uri userinfo)
      |> fun uri -> Uri.add_query_param uri ("service", ["git-upload-pack"])
    in
    Log.debug (fun l -> l "Launch the GET request to %a." Uri.pp_hum uri) ;
    let git_agent =
      List.fold_left
        (fun acc -> function `Agent s -> Some s | _ -> acc)
        None capabilities
      |> function
      | Some git_agent -> git_agent
      | None -> Fmt.invalid_arg "Expected an user agent in capabilities."
    in
    let headers =
      Option.map_default
        Web.HTTP.Headers.(def user_agent git_agent)
        Web.HTTP.Headers.(def user_agent git_agent empty)
        (Some (E.headers endpoint))
    in
    Client.call ~headers `GET (E.with_uri uri endpoint)
    >>= fun resp ->
    let decoder = Decoder.decoder () in
    consume (Web.Response.body resp)
      (Decoder.decode decoder
         (Decoder.HttpReferenceDiscovery "git-upload-pack"))
    >>= (function
        | Ok (Ok refs) -> Lwt.return_ok refs.Common.refs
        | Ok (Error (`Msg err)) -> Lwt.return_error (`Sync err)
        | Error _ ->
          let err = Cstruct.to_string (Decoder.extract_payload decoder) in
          Lwt.return (Error (`Sync err)))

  module SyncCommon :
    module type of Git.Sync.Common (Store) with module Store = Store =
    Git.Sync.Common (Store)

  type command = SyncCommon.command

  let pp_command = SyncCommon.pp_command
  let pp_fetch_one = SyncCommon.pp_fetch_one
  let pp_update_and_create = SyncCommon.pp_update_and_create

  open SyncCommon

  let push git ~push ?(capabilities = Default.capabilites) endpoint =
    let https, host, path, port, userinfo = extract endpoint in
    let scheme = if https then "https" else "http" in
    let uri =
      Uri.empty
      |> (fun uri -> Uri.with_scheme uri (Some scheme))
      |> (fun uri -> Uri.with_host uri (Some host))
      |> (fun uri ->
           Uri.with_path uri (String.concat "/" [path; "info"; "refs"]) )
      |> (fun uri -> Uri.with_port uri port)
      |> (fun uri -> Uri.with_userinfo uri userinfo)
      |> fun uri -> Uri.add_query_param uri ("service", ["git-receive-pack"])
    in
    Log.debug (fun l -> l "Launch the GET request to %a." Uri.pp_hum uri) ;
    let git_agent =
      List.fold_left
        (fun acc -> function `Agent s -> Some s | _ -> acc)
        None capabilities
      |> function
      | Some git_agent -> git_agent
      | None ->
          raise (Invalid_argument "Expected an user agent in capabilities.")
    in
    let headers =
      Option.map_default
        Web.HTTP.Headers.(def user_agent git_agent)
        Web.HTTP.Headers.(def user_agent git_agent empty)
        (Some (E.headers endpoint))
    in
    Client.call ~headers `GET (E.with_uri uri endpoint)
    >>= fun resp ->
    let decoder = Decoder.decoder () in
    let encoder = Encoder.encoder () in
    consume (Web.Response.body resp)
      (Decoder.decode decoder
         (Decoder.HttpReferenceDiscovery "git-receive-pack"))
    >>= function
    | Error err ->
        Log.err (fun l ->
            l "The HTTP decoder returns an error: %a." Decoder.pp_error err ) ;
        let err = Cstruct.to_string (Decoder.extract_payload decoder) in
        Lwt.return (Error (`Sync err))
    | Ok (Error (`Msg err)) -> Lwt.return_error (`Sync err)
    | Ok (Ok refs) -> (
        let common =
          List.filter
            (fun x -> List.exists (( = ) x) capabilities)
            refs.Common.capabilities
        in
        let sideband =
          if List.exists (( = ) `Side_band_64k) common then `Side_band_64k
          else if List.exists (( = ) `Side_band) common then `Side_band
          else `No_multiplexe
        in
        push refs.Common.refs
        >>= function
        | _, [] -> Lwt.return (Ok [])
        | shallow, commands -> (
            let req =
              Web.Request.v `POST ~path:[path; "git-receive-pack"]
                Web.HTTP.Headers.(
                  def content_type "application/x-git-receive-pack-request"
                    headers)
                (fun _ -> Lwt.return ())
            in
            Log.debug (fun l ->
                l "Send the request with these operations: %a."
                  Fmt.(hvbox (Dump.list pp_command))
                  commands ) ;
            packer ~window:(`Object 10) ~depth:50 ~ofs_delta:true git
              refs.Common.refs commands
            >>= function
            | Error err -> Lwt.return (Error (`Store err))
            | Ok (stream, _) -> (
                let stream () =
                  stream ()
                  >>= function
                  | Some buf -> Lwt.return (Some (buf, 0, Cstruct.len buf))
                  | None -> Lwt.return None
                in
                let x, r =
                  List.map
                    (function
                      | `Create (hash, reference) ->
                          Common.Create (hash, reference)
                      | `Delete (hash, reference) ->
                          Common.Delete (hash, reference)
                      | `Update (_of, _to, reference) ->
                          Common.Update (_of, _to, reference))
                    commands
                  |> fun commands -> List.hd commands, List.tl commands
                in
                Client.call
                  ~headers:
                    (Web.Request.headers req |> Web.HTTP.Headers.merge headers)
                  ~body:
                    (producer ~final:stream
                       (Encoder.encode encoder
                          (`HttpUpdateRequest
                            { Common.shallow
                            ; requests= `Raw (x, r)
                            ; capabilities })))
                  (Web.Request.meth req)
                  (E.with_uri
                     ( Web.Request.uri req
                     |> (fun uri -> Uri.with_scheme uri (Some scheme))
                     |> (fun uri -> Uri.with_host uri (Some host))
                     |> (fun uri -> Uri.with_port uri port)
                     |> (fun uri -> Uri.with_userinfo uri userinfo) )
                     endpoint)
                >>= fun resp ->
                let commands_refs =
                  List.map
                    (function
                      | `Create (_, s) -> s
                      | `Delete (_, s) -> s
                      | `Update (_, _, s) -> s)
                    commands
                  |> List.map Store.Reference.to_string
                in
                consume (Web.Response.body resp)
                  (Decoder.decode decoder
                     (Decoder.HttpReportStatus (commands_refs, sideband)))
                >>= function
                | Ok {Common.unpack= Ok (); commands} ->
                    Lwt.return (Ok commands)
                | Ok {Common.unpack= Error err; _} ->
                    Lwt.return (Error (`Sync err))
                | Error err -> Lwt.return (Error (`Smart err)) ) ) )

  let fetch git ?(shallow = []) ?(capabilities = Default.capabilites) ~notify:_
      ~negociate:(negociate, nstate) ~have ~want ?deepen endpoint =
    let https, host, path, port, userinfo = extract endpoint in
    let scheme = if https then "https" else "http" in
    let stdout = default_stdout in
    let stderr = default_stderr in
    let uri =
      Uri.empty
      |> (fun uri -> Uri.with_scheme uri (Some scheme))
      |> (fun uri -> Uri.with_host uri (Some host))
      |> (fun uri ->
           Uri.with_path uri (String.concat "/" [path; "info"; "refs"]) )
      |> (fun uri -> Uri.with_port uri port)
      |> (fun uri -> Uri.with_userinfo uri userinfo)
      |> fun uri -> Uri.add_query_param uri ("service", ["git-upload-pack"])
    in
    Log.debug (fun l -> l "Launch the GET request to %a." Uri.pp_hum uri) ;
    let git_agent =
      List.fold_left
        (fun acc -> function `Agent s -> Some s | _ -> acc)
        None capabilities
      |> function
      | Some git_agent -> git_agent
      | None -> Fmt.invalid_arg "Expected an user agent in capabilities."
    in
    let headers =
      Option.map_default
        Web.HTTP.Headers.(def user_agent git_agent)
        Web.HTTP.Headers.(def user_agent git_agent empty)
        (Some (E.headers endpoint))
    in
    Log.debug (fun l -> l "Send the GET (reference discovery) request.") ;
    Client.call ~headers `GET (E.with_uri uri endpoint)
    >>= fun resp ->
    let decoder = Decoder.decoder () in
    let encoder = Encoder.encoder () in
    let keeper = Lwt_mvar.create have in
    consume (Web.Response.body resp)
      (Decoder.decode decoder
         (Decoder.HttpReferenceDiscovery "git-upload-pack"))
    >>= function
    | Error err ->
        Log.err (fun l ->
            l "The HTTP decoder returns an error: %a." Decoder.pp_error err ) ;
        let err = Cstruct.to_string (Decoder.extract_payload decoder) in
        (* XXX(dinosaure): this is clearly an example of why Smart over HTTP is
           so bad. In this stage, HTTP response can be just a text without the
           PKT-line format. So, Smart decoder will fail BUT payload can inform
           user about what is going on. So it's an a random invalid input, it's
           a yet another well formed input which need to be /computed/. *)
        Lwt.return (Error (`Sync err))
    | Ok (Error (`Msg err)) -> Lwt.return_error (`Sync err)
    | Ok (Ok refs) -> (
        let common =
          List.filter
            (fun x -> List.exists (( = ) x) capabilities)
            refs.Common.capabilities
        in
        let sideband =
          if List.exists (( = ) `Side_band_64k) common then `Side_band_64k
          else if List.exists (( = ) `Side_band) common then `Side_band
          else `No_multiplexe
        in
        let ack_mode =
          if List.exists (( = ) `Multi_ack_detailed) common then
            `Multi_ack_detailed
          else if List.exists (( = ) `Multi_ack) common then `Multi_ack
          else `Ack
        in
        want refs.Common.refs
        >>= function
        | [] -> Lwt.return (Ok ([], 0))
        | first :: rest ->
            let negociation_request done_or_flush have =
              let pp_done_or_flush ppf = function
                | `Done -> Fmt.pf ppf "`Done"
                | `Flush -> Fmt.pf ppf "`Flush"
              in
              Log.debug (fun l ->
                  l "Send a POST negociation request (done:%a): %a."
                    pp_done_or_flush done_or_flush
                    (Fmt.Dump.list Store.Hash.pp)
                    (Store.Hash.Set.elements have) ) ;
              let req =
                Web.Request.v `POST ~path:[path; "git-upload-pack"]
                  Web.HTTP.Headers.(
                    def content_type "application/x-git-upload-pack-request"
                      headers)
                  (fun _ -> Lwt.return ())
              in
              Client.call
                ~headers:
                  (Web.Request.headers req |> Web.HTTP.Headers.merge headers)
                ~body:
                  (producer
                     (Encoder.encode encoder
                        (`HttpUploadRequest
                          ( done_or_flush
                          , { Common.want= snd first, List.map snd rest
                            ; capabilities
                            ; shallow
                            ; deep= deepen
                            ; has= Store.Hash.Set.elements have } ))))
                (Web.Request.meth req)
                (E.with_uri
                   ( Web.Request.uri req
                   |> (fun uri -> Uri.with_scheme uri (Some scheme))
                   |> (fun uri -> Uri.with_host uri (Some host))
                   |> (fun uri -> Uri.with_port uri port)
                   |> (fun uri -> Uri.with_userinfo uri userinfo) )
                   endpoint)
            in
            let negociation_result resp =
              consume (Web.Response.body resp)
                (Decoder.decode decoder Decoder.NegociationResult)
              >>= function
                      | Error err -> Log.err (fun f -> f "All went to shizzle here"); Lwt.return (Error (`Smart err))
              | Ok _ ->
                  (* TODO: check negociation result. *)
                  let stream () =
                    consume (Web.Response.body resp)
                      (Decoder.decode decoder (Decoder.PACK sideband))
                  in
                  Lwt_result.(
                    populate ~stdout ~stderr git stream
                    >>= fun (_, n) -> Lwt.return (Ok (first :: rest, n)))
            in
            if Store.Hash.Set.is_empty have then
              negociation_request `Done Store.Hash.Set.empty
              >>= negociation_result
            else
              negociation_request `Flush have
              >>= fun resp ->
              Log.debug (fun l -> l "Receiving the first negotiation response.") ;
              let rec loop ?(done_or_flush = `Flush) state resp =
                match done_or_flush with
                | `Done -> (
                    Lwt_mvar.take keeper
                    >>= fun has ->
                    Lwt_mvar.put keeper has
                    >>= fun () ->
                    Log.debug (fun l ->
                        l
                          "Receive the final negociation response from the \
                           server." ) ;
                    consume (Web.Response.body resp)
                      (Decoder.decode decoder
                         (Decoder.Negociation (have, ack_mode)))
                    >>= function
                            | Error err -> Log.err (fun f -> f "All went to shit here :("); Lwt.return (Error (`Smart err))
                    | Ok acks ->
                        Log.debug (fun l ->
                            l "Final ACK response received: %a." Common.pp_acks
                              acks ) ;
                        negociation_result resp )
                | `Flush -> (
                    Lwt_mvar.take keeper
                    >>= fun have ->
                    Lwt_mvar.put keeper have
                    >>= fun () ->
                    Log.debug (fun l -> l "Receiving a negotiation response.") ;
                    consume (Web.Response.body resp)
                      (Decoder.decode decoder
                         (Decoder.Negociation (have, ack_mode)))
                    >>= function
                            | Error err -> Log.err (fun f -> f "Maybe it all went to shit here?"); Lwt.return (Error (`Smart err))
                    | Ok acks -> (
                        Log.debug (fun l ->
                            l "ACK response received: %a." Common.pp_acks acks
                        ) ;
                        negociate acks state
                        >>= function
                        | `Ready, _ ->
                            Log.debug (fun l ->
                                l "Ready to download the PACK file." ) ;
                            negociation_result resp
                        | `Again have', state ->
                            Log.debug (fun l ->
                                l
                                  "Try again a new common trunk between the \
                                   client and the server." ) ;
                            Lwt_mvar.take keeper
                            >>= fun have ->
                            let have = Store.Hash.Set.union have have' in
                            Lwt_mvar.put keeper have
                            >>= fun () ->
                            negociation_request `Flush have >>= loop state
                        | `Done, _ ->
                            Lwt_mvar.take keeper
                            >>= fun _ ->
                            let have =
                              List.map (fun (hash, _) -> hash) acks.acks
                              |> Store.Hash.Set.of_list
                            in
                            Lwt_mvar.put keeper have
                            >>= fun () ->
                            negociation_request `Done have
                            >>= loop ~done_or_flush:`Done state ) )
              in
              loop nstate resp )

  let clone git ?(reference = Store.Reference.master) ?capabilities endpoint =
    let want_handler =
      want_handler git (fun reference' ->
          Lwt.return Store.Reference.(equal reference reference') )
    in
    let notify _ = Lwt.return_unit in
    fetch git ?capabilities
      ~negociate:((fun _ () -> Lwt.return (`Done, ())), ())
      ~notify ~have:Store.Hash.Set.empty ~want:want_handler endpoint
    >>= function
    | Ok ([(_, hash)], _) -> Lwt.return (Ok hash)
    | Ok (expect, _) ->
        Lwt.return
          (Error
             (`Sync
               (Fmt.strf "Unexpected result: %a."
                  (Fmt.hvbox
                     (Fmt.Dump.list
                        (Fmt.Dump.pair Store.Reference.pp Store.Hash.pp)))
                  expect)))
    | Error _ as err -> Lwt.return err

  module Negociator = Git.Negociator.Make (Store)

  let clone git ?capabilities ~reference:(local_ref, remote_ref) endpoint =
    clone git ?capabilities ~reference:remote_ref endpoint
    >?= fun hash' ->
    Store.Ref.write git local_ref (Store.Reference.Hash hash')
    >!= (fun err -> Lwt.return (`Store err))
    >?= fun () ->
    Store.Ref.write git Store.Reference.head (Store.Reference.Ref local_ref)
    >!= fun err -> Lwt.return (`Store err)

  let fetch_and_set_references git ?capabilities ~choose ~references endpoint =
    Negociator.find_common git
    >>= fun (have, state, continue) ->
    let continue ({acks; shallow; unshallow} : Negociator.acks) state =
      continue ({acks; shallow; unshallow} : Negociator.acks) state
    in
    let want_handler = want_handler git choose in
    let notify _ = Lwt.return_unit in
    fetch git ?capabilities ~notify ~negociate:(continue, state) ~have
      ~want:want_handler endpoint
    >?= fun (results, _) ->
    update_and_create git ~references results
    >!= fun err -> Lwt.return (`Store err)

  let fetch_all git ?capabilities ~references endpoint =
    let choose _ = Lwt.return true in
    fetch_and_set_references ~choose ?capabilities ~references git endpoint

  let fetch_some git ?capabilities ~references endpoint =
    let choose remote_ref =
      Lwt.return (Store.Reference.Map.mem remote_ref references)
    in
    fetch_and_set_references ~choose ?capabilities ~references git endpoint
    >?= fun (updated, missed, downloaded) ->
    if Store.Reference.Map.is_empty downloaded then
      Lwt.return (Ok (updated, missed))
    else (
      Log.err (fun l ->
          l "This case should not appear, we download: %a."
            Fmt.Dump.(list (pair Store.Reference.pp Store.Hash.pp))
            (Store.Reference.Map.bindings downloaded) ) ;
      Lwt.return (Ok (updated, missed)) )

  let fetch_one git ?capabilities ~reference:(remote_ref, local_refs) endpoint
      =
    let references = Store.Reference.Map.singleton remote_ref local_refs in
    let choose remote_ref =
      Lwt.return (Store.Reference.Map.mem remote_ref references)
    in
    fetch_and_set_references ~choose ?capabilities ~references git endpoint
    >?= fun (updated, missed, downloaded) ->
    if not (Store.Reference.Map.is_empty downloaded) then
      Log.err (fun l ->
          l "This case should not appear, we downloaded: %a."
            Fmt.Dump.(list (pair Store.Reference.pp Store.Hash.pp))
            (Store.Reference.Map.bindings downloaded) ) ;
    match Store.Reference.Map.(bindings updated, bindings missed) with
    | [], [_] -> Lwt.return (Ok `AlreadySync)
    | _ :: _, [] -> Lwt.return (Ok (`Sync updated))
    | [], missed ->
        Log.err (fun l ->
            l "This case should not appear, we missed too many references: %a."
              Fmt.Dump.(
                list (pair Store.Reference.pp (list Store.Reference.pp)))
              missed ) ;
        Lwt.return (Ok `AlreadySync)
    | _ :: _, missed ->
        Log.err (fun l ->
            l "This case should not appear, we missed too many references: %a."
              Fmt.Dump.(
                list (pair Store.Reference.pp (list Store.Reference.pp)))
              missed ) ;
        Lwt.return (Ok (`Sync updated))

  let update_and_create git ?capabilities ~references endpoint =
    let push_handler remote_refs =
      push_handler git references remote_refs >|= fun actions -> [], actions
    in
    push git ~push:push_handler ?capabilities endpoint
end

module CohttpMake
    (C : CLIENT
         with type +'a io = 'a Lwt.t
          and type headers = Web_cohttp_lwt.HTTP.headers
          and type body = Lwt_cstruct_flow.o
          and type meth = Web_cohttp_lwt.HTTP.meth
          and type resp = Web_cohttp_lwt.resp)
    (E : ENDPOINT with type t = C.endpoint and type headers = C.headers)
    (S : Git.S) =
  Make (Web_cohttp_lwt) (C) (E) (S)

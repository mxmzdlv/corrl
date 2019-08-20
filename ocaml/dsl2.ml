open Prelude
open Slot
open Yieldfail
open Core2
open Symantics
open Stat


module ContextRepr(T: BaseTypes) = struct
  open T
  open Hlists
  type (_,_) var = Bind: 'a shape repr -> ('a, 'a el_pat) var
  module Ctx = HList(struct type 'a t = ('a, 'a el_pat) var end)

  (* both phantom types must be part of the gadt definition, in order to properly inspect their shapes! *)
  type (_,_) ctx' =
    | Z: (unit,unit) ctx'
    | S: ('s,'a) ctx' -> ('b * 's, 'b el_pat * 'a) ctx'
  type ('s,'a) ctx = ('s,'a) ctx' * 's Ctx.hlist
  let from: 'a shape repr -> ('a, 'a el_pat) var = fun s -> Bind s
  let cnil: (unit,unit) ctx = (Z, Ctx.nil)
  let (@.): type s s' a b. (s,a) var -> (s', b) ctx -> (s * s', a * b) ctx =
    (fun v ctx ->
      match v, ctx with
      | (Bind _), (n,ctx) -> (S n, Ctx.cons v ctx))
end


(* Tagless interpreter denoting join patterns as cartesius computations.
   This version add instrumenation. *)
module Cartesius = struct
  open Hlists

  (* meta data*)
  type meta = Interval.time
  let merge: meta -> meta -> meta = Interval.(|@|)
  (* TODO this boilerplate should be abstracted *)
  module MCtx = HList(struct type 'a t = meta end)
  module MFold = HFOLD(MCtx)
  let merge_hlist metas =
    MFold.(fold { zero = Interval.tzero; succ = fun m next -> merge m (next ()) } metas)

  type 'a repr = 'a
  type 'a elem = 'a evt
  type 'a shape = 'a elem array
  type 'a el_pat = 'a repr * meta repr

  let elem (x,y) = evt x y
  let el_pat (Ev (a,t)) = (a,t)

  (* TODO: can we eliminate this boilerplate somehow? *)
  include StdContextRepr(struct type 'a elem = 'a evt type 'a repr = 'a type meta = Interval.time type 'a shape = 'a evt array type 'a el_pat = 'a repr * meta repr end)

  (* expressions *)
  let pair: 'a repr -> 'b repr -> ('a * 'b) repr  = fun x y -> (x,y)
  let bool: bool -> bool repr = fun b -> b

  (* patterns, next to metadata context, we pass a generative effect instance for yielding/failing *)
  type ('ctx, 'a) pat = 'ctx MCtx.hlist -> 'a yieldfail -> 'a el_pat
  let where: bool repr -> ('m, 'a) pat -> ('m, 'a) pat = fun b p meta yf -> if b then (p meta yf) else fail_mod yf
  let yield: 'a repr -> ('m, 'a) pat = fun v metas _ -> (v, (merge_hlist metas))

  (* extensions as slot-dependent restriction handlers *)
  type 'a handler = (unit -> 'a) -> 'a
  type 'ctx ext = 'ctx Slots.hlist -> 'ctx Suspensions.hlist -> unit handler
  let empty_ext: 'ctx ext = fun _ _ action -> action ()
  let (|++|): 'ctx ext -> 'ctx ext -> 'ctx ext = fun h h' ctx susp ->
    Handlers.((h ctx susp) |+| (h' ctx susp))

  (* turns yielded event tuples from hlist form into the naked tuple and meta data context, to be passed into the join pattern. *)
  let rec decompose: type s a. (s,a) ctx -> s Events.hlist -> a * s Counts.hlist * s MCtx.hlist = fun ctx tuple ->
    let open Evt in
    match ctx, tuple with
    | (Z, Ctx.Z), Events.Z -> ((), Counts.nil, MCtx.nil)
    | (S n, Ctx.S (_,xs)), Events.S ((Ev (e,t), count), es) ->
       let (next,cs,meta) = decompose (n,xs) es in
       (((e,t), next), Counts.(cons count cs), MCtx.cons t meta)

  let join: type s a b. (s, a) ctx -> s ext -> (a -> (s,b) pat) -> unit -> b shape repr = fun ctx ext body ->
    let decompose = decompose ctx in
    let (_,ctx) = ctx in
    let module M = HMAP(Ctx)(Slots) in
    let module MCR = HMAP(Ctx)(Arrays) in
    let module FC = HFOREACH(Counts) in
    let slots = M.map {M.f = fun _ -> mk_slot ()} ctx in
    let suspensions = mk_suspensions slots in
    let yf: b yieldfail = mk_yieldfail () in
    let module YF = (val yf) in
    let mailboxes = mk_mboxrefs slots in
    let join_handler = join_shape slots mailboxes (ext slots suspensions) (fun tuple ->
                           try
                             begin
                               let (vars,counts,metas) = decompose tuple in
                               let (payload,time) = (body vars metas yf) in
                               FC.(foreach { f = fun c -> c := Count.dec !c}) counts;
                               yield_mod yf (Evt.evt payload time)
                             end
                           with
                           | effect YF.Fail _ -> ())
    in
    let inputs = MCR.(map {f = fun (Bind r) -> r}) ctx in
    let streams = interleaved_bind slots mailboxes suspensions inputs in
    let out: b evt array = Array.init 0 (fun i -> Obj.magic i) in (*dummy value*)
    let sys_handler stat action =
      try action () with
      | effect (YF.Yield evt) k ->
         stat.n_output <- (Int64.add stat.n_output  1L);
         end_latency_sample stat;
         continue k ()
    in
    (fun () ->
      let stat = injectStat () in
      let _ = Async.async (fun () -> ((sys_handler stat) |+| join_handler) streams) in
      out)
end

open Prelude
open Slot
open Yieldfail
open Core2
open Symantics
open Stat

(* Generates the interleaved push iterations over n reactives *)
let interleaved_bind2: type a. a Slots.hlist -> a Suspensions.hlist -> a Reacts.hlist -> unit -> unit =
  let rec thunk_list: type a. a Slots.hlist -> a Suspensions.hlist -> a Reacts.hlist -> (unit -> unit) list =
    fun slots suspensions ->
    match slots, suspensions with
    | Slots.Z, Suspensions.Z -> (fun Reacts.Z -> [])
    | Slots.(S (s,ss)), Suspensions.(S (c,cs)) ->
       let module S = (val s) in
       let suspendable_strand r () =
         try (Reactive.eat (S.push) r) with
         | effect (S.Push x) k ->
            S.push x;
            c.guard (continue k)
       in
       let next = thunk_list ss cs in
       (fun Reacts.(S (r,rs)) ->
         (suspendable_strand r) :: (next rs))
  in (fun slots suspensions ->
      let mk_thunks = thunk_list slots suspensions in
      fun rs () -> Async.interleaved (Array.of_list (mk_thunks rs))) (* TODO: generate the array right away *)


(* Tagless interpreter denoting join patterns as cartesius computations *)
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
  type 'a shape = 'a elem r
  type 'a el_pat = 'a repr * meta repr

  let elem (x,y) = evt x y
  let el_pat (Ev (a,t)) = (a,t)
  let lift: 'a elem repr list -> 'a shape repr = fun evts ->
    Reactive.toR evts

  (* TODO: can we eliminate this boilerplate somehow? *)
  include StdContextRepr(struct type 'a elem = 'a evt type 'a repr = 'a type meta = Interval.time type 'a shape = 'a evt r type 'a el_pat = 'a repr * meta repr end)

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

  (* TODO: let the shape representation be thunks of reactives instead of reactives. *)
  let join: type s a b. (s, a) ctx -> s ext -> (a -> (s,b) pat) -> b shape repr = fun ctx ext body ->
    let decompose = decompose ctx in
    let (_,ctx) = ctx in
    let module M = HMAP(Ctx)(Slots) in
    let module MCR = HMAP(Ctx)(Reacts) in
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
    let out: b evt r = Reactive.create () in
    (* have local reifier for now, but could in principle plug into a larger runtime system *)
    let sys_handler action =
      let cursor = ref out in
      try action () with
      | effect (YF.Yield evt) k ->
         cursor := Reactive.resolve_next !cursor evt;
         continue k ()
    in
    let _ = Async.async (fun () -> (sys_handler |+| join_handler) streams) in
    out
end

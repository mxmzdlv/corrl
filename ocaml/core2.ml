open Prelude
open Hlists
open Slot
open Yieldfail
open Stat

module Reacts = HList(struct type 'a t = 'a evt r end)
module Events = HList(struct type 'a t = 'a evt * (Count.t ref) end)
module Counts = HList(struct type 'a t = Count.t ref end)
module Mailboxes = struct
  include HList(struct type 'a t = 'a mailbox end)
  let rec cart : type w r. r hlist -> (r Events.hlist -> w list) -> w list = fun h f ->
    match h with
    | Z -> f Events.nil
    | S (ls,h) ->
       List.concat @@ List.map (fun (x,c) ->
                          match !c with
                          | Fin i when i <= 0 -> []
                          | _ -> cart h (fun xs -> f Events.(cons (x,c) xs))) ls
end

(* TODO: these can be further abstracted to work with different codomain and force into different hlist type *)
module MailboxDrefs = struct
  include HList(struct type 'a t = unit -> 'a mailbox end)
  let rec force: type a. a hlist -> a Mailboxes.hlist =
    function
    | Z -> Mailboxes.nil
    | S (thunk,ts) -> Mailboxes.cons (thunk ()) (force ts)
end

module Slots = struct
  include HList(struct type 'a t = 'a slot end)
  (* Forget the concrete types of the slot hlist for uniform processing. *)
  let rec abstract: type a. a hlist -> slot_ex list =
    function
    | Z -> []
    | S (slot,hs) -> (Obj.magic slot) :: (abstract hs) (* It's weird that a cast is required in this scenario. *)

  (* Wrap effect thunks in list drefs. *)
  let rec mailboxes: type a. a hlist -> a MailboxDrefs.hlist =
    function
    | Z -> MailboxDrefs.nil
    | S (slot,hs) ->
       let module S = (val slot) in
       MailboxDrefs.cons (S.getMail) (mailboxes hs)
end

module MBoxRefs = struct
  include HList(struct type 'a t = 'a mailbox ref end)
end
let mk_mboxrefs: type a. a Slots.hlist -> a MBoxRefs.hlist = fun slots ->
  let module M = HMAP(Slots)(MBoxRefs) in
  M.map {M.f = fun _ -> ref []} slots
let mboxrefs_size ms =
  let module F = HFOLD(MBoxRefs) in
  F.fold { zero = 0; succ = (fun mbox n -> (List.length !mbox) + (n ())) } ms


(* For now, we give each slot the suspension capability by default. Ideally, such capabilities should be present
   only when required by an externally supplied restriction handler. *)
module Suspensions = struct
  include HList(struct type 'a t = Suspension.t end)
  let rec to_list: type a. a hlist -> Suspension.t list = function
    | Z -> []
    | S (s,ss) -> s :: (to_list ss)
end
let mk_suspensions: type a. a Slots.hlist -> a Suspensions.hlist = fun slots ->
  let module M = HMAP(Slots)(Suspensions) in
  M.map {M.f = fun _ -> Suspension.mk ()} slots

type 'a handler = (unit -> 'a) -> 'a

let h_gen () =
  let module SF = HFOLD(Slots) in
  (fun slots mk ->
  SF.(fold {zero = Handlers.id;
            succ = fun slot handler ->
                 (mk (abstract slot)) |+| (handler ())
                     }) slots)


(* Arity generic join implementation. *)
let rec memory: type a. a Slots.hlist -> a MBoxRefs.hlist -> (unit -> unit) -> unit =
 fun slots mboxrefs ->
  match slots, mboxrefs with
  | Slots.Z, MBoxRefs.Z -> (fun action -> action ())
  | Slots.(S (s,ss)), MBoxRefs.(S (m,ms)) ->
     let rest = memory ss ms in
     let module S = (val s) in
     let mem: S.t mailbox ref = m in
     (fun action ->
       try rest action with
       | effect (S.GetMail) k -> continue k !mem
       | effect (S.SetMail l) k -> mem := l; continue k ())

  (* Default behavior: enqueue each observed event notification in the corresponding mailbox. *)
let forAll slots =
  h_gen () slots (fun (s: (module SLOT)) ->
      let module S = (val s) in
      (fun action ->
        try action () with
        | effect (S.Push x) k ->
           S.(setMail (((x, (ref Count.Inf)) :: (getMail ()))));
           continue k (S.push x)))

let gc slots =
  let module SF = HFOREACH(Slots) in
  SF.(foreach { f = fun slot ->
                    let mbox = getMail_of slot () in
                    let mbox = (List.filter (fun (_,c) -> Count.lt_i 0 !c) mbox) in
                    setMail_of slot mbox
  }) slots


  (* Implements the generic cartesian product.  *)
let reify slots mboxes consumer =
  let stat = injectStat () in
  h_gen () slots (fun (s: (module SLOT)) ->
      let module S = (val s) in
      (fun action ->
        try action () with
        | effect (S.Push x) k ->
           let entry = List.find (fun (y,_) -> y = x) (S.getMail ()) in
           let mail = begin
               try MailboxDrefs.force mboxes with
               | effect (S.GetMail) k -> continue k [entry] (*TODO would make more sense if the life counter was offered already in the push message *)
             end
           in
           (* For simplicity, we supply a consumer function for the tuples. In the paper, we provisioned a dedicated trigger effect for signaling each tuple. *)
           List.iter consumer (Mailboxes.cart mail (fun x ->
                                   stat.n_tested <- stat.n_tested + 1;
                                   [x]));
           gc_time stat (fun () -> gc slots);
           continue k ()))

let join_shape slots mail restriction consumer =
  let module SMBD = HMAP(Slots)(MailboxDrefs) in
  let module FS = HFOLD(Slots) in
  let mboxes = SMBD.(map {f = fun s -> (getMail_of s) }) slots in
  (memory slots mail)
  |+| (reify slots mboxes consumer)
  |+| restriction
  |+| (forAll slots)

(* Generates the interleaved push iterations over n reactives *)
let interleaved_bind: type a. a Slots.hlist ->
                           a MBoxRefs.hlist ->
                           a Suspensions.hlist ->
                           a Reacts.hlist ->
                           unit -> unit = fun slots mail suspensions ->
  let active_strands = ref (Slots.length slots) in (* for termination checking *)
  let n_events = ref 0 in (* number of pushed events so far *)
  let stat = injectStat () in
  let rec thunk_list: type a. a Slots.hlist ->
                           a Suspensions.hlist ->
                           a Reacts.hlist ->
                           (unit -> unit) list = fun slots suspensions ->
    match slots, suspensions with
    | Slots.Z, Suspensions.Z -> (fun Reacts.Z -> [])
    | Slots.(S (s,ss)), Suspensions.(S (c,cs)) ->
       let module S = (val s) in
       let on_next ev =
         S.push ev;
         n_events += 1;
         mem_sample stat !n_events (fun () -> mboxrefs_size mail);
         begin_latency_sample stat !n_events
       in (* TODO: measurement code: latency, mailbox *)
       let on_done () =
         active_strands -= 1;
         if !active_strands = 0 then
           terminate ()
         else ()
       in
       let suspendable_strand r () =
         try (Reactive.eat_with on_next on_done r) with
         | effect (S.Push x) k ->
            S.push x;
            c.guard (continue k)
       in
       let next = thunk_list ss cs in
       (fun Reacts.(S (r,rs)) -> (suspendable_strand r) :: (next rs))
  in
  let mk_thunks = thunk_list slots suspensions in
      fun rs () -> Async.interleaved (Array.of_list (mk_thunks rs)) (* TODO: generate the array right away *)

(* TODOs: *)
(* More tests for the aligning handler
   Windows (medium)
   Optimizations in the tagless representation?
   Integrate external I/O (low)
*)
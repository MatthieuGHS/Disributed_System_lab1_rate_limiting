------------------------- MODULE RateLimiterNaive -------------------------
(***************************************************************************)
(* WRONG design, for comparison: the counter lives in a shared store, but  *)
(* the check is done by the worker in TWO steps, like Redis GET then SET   *)
(* instead of INCR:                                                        *)
(*   Get : read the counter        (one message to the store)              *)
(*   Set : if it was < L, write it + 1 and call the API (another message)  *)
(* Each step is atomic, but the pair is not: two workers can both read     *)
(* L-1 before either writes ("read-read-write-write" race).                *)
(* TLC must find the trace with L+1 calls.                                 *)
(*                                                                         *)
(* One IP, one window: enough to show the race.                            *)
(***************************************************************************)
EXTENDS Naturals

CONSTANTS Workers, L, MaxReq

VARIABLES
    count,   \* the shared counter (in the store)
    pc,      \* pc[w] \in {"idle", "read"}: where worker w is
    seen,    \* seen[w]: value read by w's Get
    sent,    \* sent[w]: requests already started by w (bound)
    calls    \* calls received by the API (the oracle)

vars == <<count, pc, seen, sent, calls>>

TypeOK ==
    /\ count \in Nat
    /\ pc \in [Workers -> {"idle", "read"}]
    /\ seen \in [Workers -> Nat]
    /\ sent \in [Workers -> 0..MaxReq]
    /\ calls \in Nat

Init ==
    /\ count = 0
    /\ pc = [w \in Workers |-> "idle"]
    /\ seen = [w \in Workers |-> 0]
    /\ sent = [w \in Workers |-> 0]
    /\ calls = 0

\* GET: the worker reads the counter.
Get(w) ==
    /\ pc[w] = "idle"
    /\ sent[w] < MaxReq
    /\ seen' = [seen EXCEPT ![w] = count]
    /\ pc' = [pc EXCEPT ![w] = "read"]
    /\ sent' = [sent EXCEPT ![w] = @ + 1]
    /\ UNCHANGED <<count, calls>>

\* SET: decides on the value read EARLIER, which may be stale by now.
Set(w) ==
    /\ pc[w] = "read"
    /\ IF seen[w] < L
       THEN /\ count' = seen[w] + 1
            /\ calls' = calls + 1
       ELSE UNCHANGED <<count, calls>>
    /\ pc' = [pc EXCEPT ![w] = "idle"]
    /\ UNCHANGED <<seen, sent>>

Next == \E w \in Workers : Get(w) \/ Set(w)

Spec == Init /\ [][Next]_vars

Safety == calls <= L
=============================================================================

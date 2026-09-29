---------------------------- MODULE RateLimiter ----------------------------
(***************************************************************************)
(* Global mode of the rate limiter (lib/rate_limiter/{worker,limiter}.ex). *)
(*                                                                         *)
(* Workers ask ONE shared Limiter actor for a decision, then call the API  *)
(* only if allowed. The API log is the oracle: at most L calls per IP and  *)
(* per window.                                                             *)
(*                                                                         *)
(* What is modelled, and how it maps to the Elixir code:                   *)
(*  - Send     : Worker.decide -> GenServer.call(Limiter, {:check, ip})    *)
(*               (a request with a fresh reference, like make_ref).        *)
(*  - Handle   : Limiter.handle_call({:check, ip}) = test AND increment in *)
(*               ONE action: an actor handles one message at a time.       *)
(*               This is the linearisation point.                          *)
(*  - Receive  : the worker gets the reply; if :allow it calls the API.    *)
(*  - Timeout  : GenServer.call gives up; the worker applies its policy.   *)
(*               Always enabled while waiting: we never know if the        *)
(*               Limiter is dead, slow, or cut off (partial synchrony).    *)
(*  - Discard  : a late reply (old reference) is dropped by the worker.    *)
(*  - Tick     : the Limiter's clock enters the next window.               *)
(*  - Crash    : crash with recovery: counters AND mailbox are lost; the   *)
(*               Limiter restarts in conservative mode (denies all until   *)
(*               the end of the current window).                           *)
(*  - DropReq, DropReply : omission / partition, a message is lost.        *)
(*                                                                         *)
(* Abstractions (and why they are safe):                                   *)
(*  - Time is counted in windows; only the Limiter's clock exists (the     *)
(*    workers send no timestamp), so there is a single clock variable.     *)
(*  - The code denies for a full window T after a restart, which covers    *)
(*    at least the rest of the current window: it allows LESS than this    *)
(*    model, so safety of the model implies safety of the code.            *)
(*  - The Worker -> API call is merged into Receive (a lost API call only  *)
(*    means fewer calls, which cannot break safety).                       *)
(*  - An API call is tagged with the window in which it was ALLOWED.       *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS
    Workers,     \* e.g. {w1, w2}
    IPs,         \* e.g. {a}
    L,           \* limit per IP and per window
    MaxWindow,   \* bound on time, so that TLC terminates
    MaxReq,      \* bound on requests per worker, idem
    Policy       \* "fail_closed" or "fail_open"

ASSUME L \in Nat /\ MaxWindow \in Nat /\ MaxReq \in Nat
ASSUME Policy \in {"fail_closed", "fail_open"}

VARIABLES
    clock,       \* current window of the Limiter's clock
    count,       \* count[ip]: Limiter counter for the current window
    recovering,  \* TRUE after a crash, until the end of the window
    toLimiter,   \* requests in flight / in the Limiter's mailbox
    toWorker,    \* replies in flight / in the workers' mailboxes
    wState,      \* wState[w] \in {"idle", "waiting"}
    ref,         \* ref[w]: reference of w's current (last) request
    wIp,         \* wIp[w]: IP of w's current request
    apiLog       \* every call received by the API (the oracle)

vars == <<clock, count, recovering, toLimiter, toWorker, wState, ref, wIp,
          apiLog>>

Refs      == 1..MaxReq
Windows   == 0..MaxWindow
Requests  == [w : Workers, ref : Refs, ip : IPs]
Replies   == [w : Workers, ref : Refs, ip : IPs, win : Windows,
              dec : {"allow", "deny"}]
LogEntries == [w : Workers, ref : Refs, ip : IPs, win : Windows]

TypeOK ==
    /\ clock \in Windows
    /\ count \in [IPs -> 0..L]
    /\ recovering \in BOOLEAN
    /\ toLimiter \in SUBSET Requests
    /\ toWorker \in SUBSET Replies
    /\ wState \in [Workers -> {"idle", "waiting"}]
    /\ ref \in [Workers -> 0..MaxReq]
    /\ wIp \in [Workers -> IPs]
    /\ apiLog \in SUBSET LogEntries

-----------------------------------------------------------------------------
(* Initial state: the first start is also treated as a recovery, like      *)
(* Limiter.init (blocked_until = now + recovery_ms).                       *)

Init ==
    /\ clock = 0
    /\ count = [ip \in IPs |-> 0]
    /\ recovering = TRUE
    /\ toLimiter = {}
    /\ toWorker = {}
    /\ wState = [w \in Workers |-> "idle"]
    /\ ref = [w \in Workers |-> 0]
    /\ wIp = [w \in Workers |-> CHOOSE ip \in IPs : TRUE]
    /\ apiLog = {}

-----------------------------------------------------------------------------
(* Worker w starts a request for ip: GenServer.call sends {:check, ip}.    *)
(* A worker serves one request at a time (it is a GenServer too).          *)
Send(w, ip) ==
    /\ wState[w] = "idle"
    /\ ref[w] < MaxReq
    /\ ref' = [ref EXCEPT ![w] = @ + 1]
    /\ wState' = [wState EXCEPT ![w] = "waiting"]
    /\ wIp' = [wIp EXCEPT ![w] = ip]
    /\ toLimiter' = toLimiter \cup {[w |-> w, ref |-> ref[w] + 1, ip |-> ip]}
    /\ UNCHANGED <<clock, count, recovering, toWorker, apiLog>>

(* The Limiter handles ONE message: test and increment together.           *)
(* Any message of the mailbox may be picked: the network does not keep    *)
(* the order between different senders.                                   *)
Handle(m) ==
    /\ m \in toLimiter
    /\ LET ok == ~recovering /\ count[m.ip] < L
       IN  /\ count' = IF ok THEN [count EXCEPT ![m.ip] = @ + 1] ELSE count
           /\ toWorker' = toWorker \cup
                 {[w |-> m.w, ref |-> m.ref, ip |-> m.ip, win |-> clock,
                   dec |-> IF ok THEN "allow" ELSE "deny"]}
    /\ toLimiter' = toLimiter \ {m}
    /\ UNCHANGED <<clock, recovering, wState, ref, wIp, apiLog>>

(* Worker receives the reply to its CURRENT request (^ref matches).        *)
Receive(r) ==
    /\ r \in toWorker
    /\ wState[r.w] = "waiting"
    /\ r.ref = ref[r.w]
    /\ apiLog' = IF r.dec = "allow"
                 THEN apiLog \cup {[w |-> r.w, ref |-> r.ref, ip |-> r.ip,
                                    win |-> r.win]}
                 ELSE apiLog
    /\ wState' = [wState EXCEPT ![r.w] = "idle"]
    /\ toWorker' = toWorker \ {r}
    /\ UNCHANGED <<clock, count, recovering, toLimiter, ref, wIp>>

(* The call times out. The worker cannot tell dead from slow: it applies   *)
(* its policy. fail_open calls the API without any decision; the call is   *)
(* tagged with the window the API sees, i.e. the current one.              *)
Timeout(w) ==
    /\ wState[w] = "waiting"
    /\ wState' = [wState EXCEPT ![w] = "idle"]
    /\ apiLog' = IF Policy = "fail_open"
                 THEN apiLog \cup {[w |-> w, ref |-> ref[w],
                                    ip |-> wIp[w], win |-> clock]}
                 ELSE apiLog
    /\ UNCHANGED <<clock, count, recovering, toLimiter, toWorker, ref, wIp>>

(* A late reply (the worker gave up or moved on) is dropped.               *)
Discard(r) ==
    /\ r \in toWorker
    /\ ~(wState[r.w] = "waiting" /\ r.ref = ref[r.w])
    /\ toWorker' = toWorker \ {r}
    /\ UNCHANGED <<clock, count, recovering, toLimiter, wState, ref, wIp, apiLog>>

(* Next window: fixed-window counters start again from 0, and the         *)
(* conservative recovery period is over.                                   *)
Tick ==
    /\ clock < MaxWindow
    /\ clock' = clock + 1
    /\ count' = [ip \in IPs |-> 0]
    /\ recovering' = FALSE
    /\ UNCHANGED <<toLimiter, toWorker, wState, ref, wIp, apiLog>>

(* Crash with recovery: volatile memory (counters, mailbox) is lost; the   *)
(* supervisor restarts the Limiter, which denies until the window ends.    *)
Crash ==
    /\ count' = [ip \in IPs |-> 0]
    /\ recovering' = TRUE
    /\ toLimiter' = {}
    /\ UNCHANGED <<clock, toWorker, wState, ref, wIp, apiLog>>

(* Omission / partition: a message is lost.                                *)
DropReq(m) ==
    /\ m \in toLimiter
    /\ toLimiter' = toLimiter \ {m}
    /\ UNCHANGED <<clock, count, recovering, toWorker, wState, ref, wIp, apiLog>>

DropReply(r) ==
    /\ r \in toWorker
    /\ toWorker' = toWorker \ {r}
    /\ UNCHANGED <<clock, count, recovering, toLimiter, wState, ref, wIp, apiLog>>

Next ==
    \/ \E w \in Workers, ip \in IPs : Send(w, ip)
    \/ \E m \in toLimiter : Handle(m) \/ DropReq(m)
    \/ \E r \in toWorker : Receive(r) \/ Discard(r) \/ DropReply(r)
    \/ \E w \in Workers : Timeout(w)
    \/ Tick
    \/ Crash

(* Fairness: an enabled Handle / Receive / Timeout cannot be postponed     *)
(* forever. The timeout is what guarantees an answer even if every         *)
(* message is lost ("look for a timeout and you'll find it").              *)
Fairness ==
    /\ \A w \in Workers : WF_vars(Timeout(w))
    /\ WF_vars(\E m \in toLimiter : Handle(m))
    /\ WF_vars(\E r \in toWorker : Receive(r))

Spec == Init /\ [][Next]_vars /\ Fairness

\* Same system, but nobody is forced to time out: Liveness must FAIL
\* (a lost request leaves its worker waiting forever).
SpecNoTimeout ==
    /\ Init /\ [][Next]_vars
    /\ WF_vars(\E m \in toLimiter : Handle(m))
    /\ WF_vars(\E r \in toWorker : Receive(r))

-----------------------------------------------------------------------------
(* Properties                                                              *)

\* Number of API calls for ip allowed in window win.
Calls(ip, win) == Cardinality({e \in apiLog : e.ip = ip /\ e.win = win})

\* SAFETY: never more than L calls per IP and per window.
Safety == \A ip \in IPs, win \in Windows : Calls(ip, win) <= L

\* SANITY (must be VIOLATED): the limit can actually be reached. Otherwise
\* Safety could hold for a silly reason (e.g. nothing is ever allowed).
LimitNeverReached == \A ip \in IPs, win \in Windows : Calls(ip, win) < L

\* LIVENESS: every request gets an answer (result or 429).
Liveness == \A w \in Workers : wState[w] = "waiting" ~> wState[w] = "idle"

-----------------------------------------------------------------------------
(* Inductive invariant.                                                    *)
(* Safety alone is NOT inductive: a state with L calls logged and          *)
(* count = 0 (not recovering) satisfies Safety, yet one Handle + Receive   *)
(* makes L+1. We must also say that the counter "knows" every allow        *)
(* already granted, whether it reached the API or is still in flight.      *)

\* Allows granted for (ip, win): logged at the API or still in flight.
Granted(ip, win) ==
      Calls(ip, win)
    + Cardinality({r \in toWorker : r.dec = "allow" /\ r.ip = ip /\ r.win = win})

IndInv ==
    /\ TypeOK
    \* nothing comes from the future
    /\ \A e \in apiLog : e.win <= clock
    /\ \A r \in toWorker : r.win <= clock
    \* strengthened safety: counts in-flight allows too
    /\ \A ip \in IPs, win \in Windows : Granted(ip, win) <= L
    \* the counter is an upper bound of what was granted in this window
    /\ ~recovering => \A ip \in IPs : Granted(ip, clock) <= count[ip]

\* Safety alone, as a candidate: TLC finds a counterexample to induction.
SafetyAlone == TypeOK /\ Safety

THEOREM Spec => []Safety
=============================================================================

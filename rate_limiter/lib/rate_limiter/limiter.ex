defmodule RateLimiter.Limiter do
  @moduledoc """
  Global limiter: fixed window, at most `limit` requests per IP
  per window of `window_ms` milliseconds.

  Test and increment happen in the same `handle_call`, which is atomic
  because a GenServer processes one message at a time.

  Conservative (re)start: counters are lost on a crash (crash-recovery
  model), so after *every* start the Limiter denies everything for
  `recovery_ms` (default: one full window). Any window that was open
  before the crash is over by then, so we can never exceed L.
  """
  use GenServer

  alias RateLimiter.FixedWindow

  # Cluster-wide name: reachable from any connected node.
  @name {:global, __MODULE__}

  # ---------- Client API (runs in the caller's process) ----------

  def start_link(opts) do
    name = Keyword.get(opts, :name, @name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  # A reply arriving after `timeout` is dropped by GenServer.call
  # (the caller's reply alias is deactivated), like our ^ref in step 2.
  def check(ip, server \\ @name, timeout \\ 5_000) do
    GenServer.call(server, {:check, ip}, timeout)
  end

  # ---------- Server callbacks (run in the Limiter process) ----------

  @impl true
  def init(opts) do
    window_ms = Keyword.fetch!(opts, :window_ms)
    recovery_ms = Keyword.get(opts, :recovery_ms, window_ms)

    state = %{
      limit: Keyword.fetch!(opts, :limit),
      window_ms: window_ms,
      blocked_until: now_ms() + recovery_ms,
      counts: %{}
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:check, ip}, _from, state) do
    if now_ms() < state.blocked_until do
      # Still recovering: fail closed.
      {:reply, :deny, state}
    else
      {decision, counts} = FixedWindow.check(state.counts, ip, state.limit, state.window_ms)
      {:reply, decision, %{state | counts: counts}}
    end
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end

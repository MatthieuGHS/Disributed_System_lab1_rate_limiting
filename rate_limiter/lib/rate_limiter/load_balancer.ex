defmodule RateLimiter.LoadBalancer do
  @moduledoc """
  Round-robin load balancer with sticky sessions: a new session gets the
  next worker, and then always stays on that worker.

  The LB only *routes*: the request itself goes from the client straight
  to the worker, so the LB does not serialize all traffic.
  """
  use GenServer

  alias RateLimiter.Worker

  # ---------- Client API (runs in the caller's process) ----------

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  def request(session, ip, account, lb \\ __MODULE__) do
    worker = GenServer.call(lb, {:route, session})
    Worker.request(worker, ip, account)
  end

  # ---------- Server callbacks (run in the LoadBalancer process) ----------

  @impl true
  def init(opts) do
    # Workers are local names (:worker_1) or {name, node} for remote ones.
    {:ok, %{workers: Keyword.fetch!(opts, :workers), next: 0, sticky: %{}}}
  end

  @impl true
  def handle_call({:route, session}, _from, state) do
    case Map.fetch(state.sticky, session) do
      {:ok, worker} ->
        {:reply, worker, state}

      :error ->
        worker = Enum.at(state.workers, rem(state.next, length(state.workers)))
        sticky = Map.put(state.sticky, session, worker)
        {:reply, worker, %{state | next: state.next + 1, sticky: sticky}}
    end
  end
end

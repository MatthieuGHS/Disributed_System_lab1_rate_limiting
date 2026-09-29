defmodule RateLimiter.Worker do
  @moduledoc """
  A web worker (like one uvicorn process). For each request it asks for a
  decision, then calls the API only if allowed.

    * `:global` mode: asks the shared Limiter (like Redis).
    * `:local` mode: uses its own counters, so it only sees its own traffic.

  If the Limiter does not answer within `timeout` ms (crashed, slow, or
  partitioned away), the worker cannot know what happened and applies
  its `policy`:

    * `:fail_closed` (default): deny, never exceed L (keeps C, loses A);
    * `:fail_open`: allow, stay available (keeps A, may exceed L).
  """
  use GenServer

  require Logger

  alias RateLimiter.{Api, FixedWindow, Limiter}

  # ---------- Client API (runs in the caller's process) ----------

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))
  end

  # A worker serves its queue one request at a time, and each may wait up to
  # `timeout` for the Limiter: callers must wait longer than that.
  def request(worker, ip, account) do
    GenServer.call(worker, {:request, ip, account}, 15_000)
  end

  # ---------- Server callbacks (run in the Worker process) ----------

  @impl true
  def init(opts) do
    state = %{
      id: Keyword.fetch!(opts, :id),
      mode: Keyword.fetch!(opts, :mode),
      limiter: Keyword.get(opts, :limiter, {:global, Limiter}),
      api: Keyword.get(opts, :api, {:global, Api}),
      policy: Keyword.get(opts, :policy, :fail_closed),
      timeout: Keyword.get(opts, :timeout, 200),
      # only used in :local mode
      limit: Keyword.get(opts, :limit),
      window_ms: Keyword.get(opts, :window_ms),
      counts: %{}
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:request, ip, account}, _from, state) do
    {decision, state} = decide(ip, state)

    case decision do
      :allow ->
        {:ok, data} = Api.call_api(ip, account, state.id, state.api)
        {:reply, {:ok, data}, state}

      :deny ->
        {:reply, {:error, 429}, state}
    end
  end

  defp decide(ip, %{mode: :global} = state) do
    {Limiter.check(ip, state.limiter, state.timeout), state}
  catch
    # Timeout, Limiter down or unreachable: all look the same from here.
    :exit, reason ->
      Logger.warning(
        "worker #{inspect(state.id)}: Limiter unavailable (#{short(reason)}), #{state.policy}"
      )

      {fallback(state.policy), state}
  end

  defp decide(ip, %{mode: :local} = state) do
    {decision, counts} = FixedWindow.check(state.counts, ip, state.limit, state.window_ms)
    {decision, %{state | counts: counts}}
  end

  defp fallback(:fail_closed), do: :deny
  defp fallback(:fail_open), do: :allow

  defp short({reason, _call}), do: inspect(reason)
  defp short(reason), do: inspect(reason)
end

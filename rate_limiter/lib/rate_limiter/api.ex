defmodule RateLimiter.Api do
  @moduledoc """
  The protected (paid) API. Logs every call it receives: this log is the
  test oracle ("at most L calls per IP and window").
  """
  use GenServer

  # Cluster-wide name: reachable from any connected node.
  @name {:global, __MODULE__}

  # ---------- Client API (runs in the caller's process) ----------

  def start_link(opts) do
    name = Keyword.get(opts, :name, @name)
    GenServer.start_link(__MODULE__, :ok, name: name)
  end

  def call_api(ip, account, worker_id, server \\ @name) do
    GenServer.call(server, {:call_api, ip, account, worker_id})
  end

  def log(server \\ @name), do: GenServer.call(server, :log)

  def reset(server \\ @name), do: GenServer.call(server, :reset)

  # ---------- Server callbacks (run in the Api process) ----------

  @impl true
  def init(:ok), do: {:ok, []}

  @impl true
  def handle_call({:call_api, ip, account, worker_id}, _from, log) do
    entry = %{ip: ip, account: account, worker: worker_id}
    {:reply, {:ok, :some_data}, [entry | log]}
  end

  def handle_call(:log, _from, log), do: {:reply, Enum.reverse(log), log}

  def handle_call(:reset, _from, _log), do: {:reply, :ok, []}
end

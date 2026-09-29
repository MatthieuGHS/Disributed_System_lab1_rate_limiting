defmodule RateLimiter.Cluster do
  @moduledoc """
  Starts the whole cluster from code with OTP's `:peer` module (OTP >= 25):
  one BEAM node per role, all on this machine.

  Must be called from a distributed node, e.g.

      ROLE=clients iex --sname clients -S mix
      iex> RateLimiter.Cluster.demo(:global, :fail_open)
  """

  @roles [limiter: "limiter", api: "api", w1: "worker", w2: "worker", w3: "worker", w4: "worker"]
  @worker_names [:w1, :w2, :w3, :w4]

  @doc """
  Starts the peer nodes. Options:

    * `:mode` - `:global` (default) or `:local`
    * `:policy` - `:fail_closed` (default) or `:fail_open`
    * `:limit`, `:window_ms` - L and T (default 5 per 10 s)
    * `:recovery_ms` - Limiter recovery period (default: one window)
    * `:log_level` - log level on the peers (default `:warning`)
    * `:quiet` - do not print "cluster up"

  Returns the pid of the process that owns the peers: they die with it.
  """
  def start(opts \\ [])

  def start(mode) when is_atom(mode), do: start(mode: mode)

  def start(opts) do
    unless Node.alive?(), do: raise("start this node with --sname")

    owner = self()

    holder =
      spawn(fn ->
        peers = for {name, role} <- @roles, do: start_peer(name, role, opts)
        nodes = Enum.map(peers, &elem(&1, 1))
        mesh(nodes)
        send(owner, {:cluster_up, self(), nodes})

        # Keep running: the peers are stopped when this process exits.
        receive do
          {:stop, from} ->
            Enum.each(peers, fn {pid, _node} -> :peer.stop(pid) end)
            send(from, :stopped)
        end
      end)

    ref = Process.monitor(holder)

    receive do
      {:DOWN, ^ref, :process, ^holder, reason} ->
        raise "cluster failed to start: #{inspect(reason)}"

      {:cluster_up, ^holder, nodes} ->
        Process.demonitor(ref, [:flush])
        :global.sync()
        unless opts[:quiet], do: IO.puts("cluster up: #{inspect(nodes)}")
        holder
    after
      30_000 -> raise "cluster did not start in time"
    end
  end

  def start(mode, policy), do: start(mode: mode, policy: policy)

  @doc "Stops every peer node and waits until their names are free again."
  def stop(holder) do
    send(holder, {:stop, self()})

    receive do
      :stopped -> wait_names_free(100)
    after
      10_000 -> {:error, :timeout}
    end
  end

  defp wait_names_free(0), do: {:error, :names_still_registered}

  defp wait_names_free(attempts) do
    {:ok, names} = :erl_epmd.names()
    ours = for {name, _} <- @roles, do: ~c"#{name}"

    if Enum.any?(names, fn {name, _port} -> name in ours end) do
      Process.sleep(50)
      wait_names_free(attempts - 1)
    else
      :ok
    end
  end

  @doc "The remote workers, as `{registered_name, node}` for the LoadBalancer."
  def workers, do: for(w <- @worker_names, do: {:worker, node_name(w)})

  @doc "Full node name of a role on this host, e.g. `node_name(:limiter)`."
  def node_name(name) do
    [_, host] = String.split(Atom.to_string(Node.self()), "@")
    :"#{name}@#{host}"
  end

  # ---------- Fault injection (for demos and tests) ----------

  @doc "Freezes the Limiter process: alive but never answers (slowness)."
  def slow_limiter, do: :sys.suspend(:global.whereis_name(RateLimiter.Limiter))

  def resume_limiter, do: :sys.resume(:global.whereis_name(RateLimiter.Limiter))

  @doc "Kills the Limiter process (its supervisor restarts it, counters lost)."
  def crash_limiter, do: Process.exit(:global.whereis_name(RateLimiter.Limiter), :kill)

  @doc "Cuts the Limiter node off from every other node (partition)."
  def partition_limiter do
    :erpc.cast(node_name(:limiter), fn -> for n <- Node.list(), do: Node.disconnect(n) end)
  end

  @doc "Heals the partition: reconnects the Limiter node to the cluster."
  def heal(attempts \\ 50) do
    limiter = node_name(:limiter)
    Node.connect(limiter)
    others = [Node.self() | Node.list()] -- [limiter]
    :erpc.call(limiter, fn -> Enum.each(others, &Node.connect/1) end)
    :global.sync()

    cond do
      :global.whereis_name(RateLimiter.Limiter) != :undefined -> :ok
      attempts == 0 -> {:error, :still_partitioned}
      # Right after a disconnect, 'global' may refuse to reconnect for a moment.
      true -> Process.sleep(100) && heal(attempts - 1)
    end
  end

  @doc """
  One command: start the cluster, wait for the Limiter recovery period,
  then run the attack scenario every window, forever.
  """
  def demo(mode \\ :global, policy \\ :fail_closed) do
    start(mode: mode, policy: policy)
    IO.puts("waiting for the Limiter recovery period...")
    Process.sleep(10_500)
    loop()
  end

  defp loop do
    RateLimiter.Client.attack()
    Process.sleep(10_000)
    loop()
  end

  # Connect every pair explicitly, so the mesh is complete before we start.
  defp mesh(nodes) do
    for n <- nodes do
      :erpc.call(n, fn ->
        Enum.each(nodes, &Node.connect/1)
        :global.sync()
      end)
    end
  end

  defp start_peer(name, role, opts) do
    # Give the peer the same code paths, so it can load our modules.
    code_paths = Enum.flat_map(:code.get_path(), &[~c"-pa", &1])

    # By default 'global' reacts to a partial partition by cutting even
    # more links (prevent_overlapping_partitions). Off here, so that
    # isolating the Limiter node isolates only that node.
    no_cascade = [~c"-kernel", ~c"prevent_overlapping_partitions", ~c"false"]

    # No `-kernel dist_auto_connect never` here: 'global' needs automatic
    # connections to finish its mesh, otherwise :global.sync/0 hangs.
    # A partition still holds: once the name is unregistered, nobody sends
    # to the Limiter node, so nothing triggers a reconnection.

    # Both levels: Elixir's Logger overrides the kernel one when it starts.
    level = ~c"#{Keyword.get(opts, :log_level, :warning)}"
    log_level = [~c"-kernel", ~c"logger_level", level, ~c"-logger", ~c"level", level]

    env =
      [
        {"ROLE", role},
        {"LIMIT_MODE", Keyword.get(opts, :mode, :global)},
        {"LIMIT_POLICY", Keyword.get(opts, :policy, :fail_closed)},
        {"LIMIT", opts[:limit]},
        {"LIMIT_WINDOW_MS", opts[:window_ms]},
        {"LIMIT_RECOVERY_MS", opts[:recovery_ms]}
      ]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Enum.map(fn {k, v} -> {String.to_charlist(k), ~c"#{v}"} end)

    {:ok, pid, node} =
      :peer.start_link(%{
        name: name,
        args: no_cascade ++ log_level ++ code_paths,
        # Control the peer over stdio, not over distribution: cutting the
        # network (partition) must not kill the node.
        connection: :standard_io,
        env: env
      })

    true = Node.connect(node)
    {:ok, _} = :erpc.call(node, Application, :ensure_all_started, [:rate_limiter])
    {pid, node}
  end
end

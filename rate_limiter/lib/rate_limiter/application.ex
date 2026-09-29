defmodule RateLimiter.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # ROLE selects what this node runs: limiter | api | worker | clients | none.
    # Unset: everything on one node (handy for iex).
    role = System.get_env("ROLE", "all")
    opts = [strategy: :one_for_one, name: RateLimiter.Supervisor]
    Supervisor.start_link(children(role), opts)
  end

  defp children("none"), do: []

  defp children("limiter") do
    limiter_opts = [limit: limit(), window_ms: window_ms()]

    limiter_opts =
      case System.get_env("LIMIT_RECOVERY_MS") do
        nil -> limiter_opts
        ms -> [recovery_ms: String.to_integer(ms)] ++ limiter_opts
      end

    [{RateLimiter.Limiter, limiter_opts}]
  end

  defp children("api"), do: [RateLimiter.Api]
  defp children("worker"), do: [worker(Node.self(), :worker)]

  # Clients node: the load balancer, routing to the remote worker nodes
  # listed in WORKERS (default: w1..w4 on this host).
  defp children("clients") do
    [host] = tl(String.split(Atom.to_string(Node.self()), "@"))

    workers =
      System.get_env("WORKERS", "w1,w2,w3,w4")
      |> String.split(",")
      |> Enum.map(&{:worker, :"#{&1}@#{host}"})

    [{RateLimiter.LoadBalancer, workers: workers}]
  end

  defp children("all") do
    workers = for i <- 1..4, do: worker(i, :"worker_#{i}")
    lb = {RateLimiter.LoadBalancer, workers: for(i <- 1..4, do: :"worker_#{i}")}
    children("limiter") ++ children("api") ++ workers ++ [lb]
  end

  defp worker(id, name) do
    mode = env("LIMIT_MODE", %{"global" => :global, "local" => :local}, "global")

    policy =
      env(
        "LIMIT_POLICY",
        %{"fail_closed" => :fail_closed, "fail_open" => :fail_open},
        "fail_closed"
      )

    Supervisor.child_spec(
      {RateLimiter.Worker,
       id: id, mode: mode, policy: policy, limit: limit(), window_ms: window_ms(), name: name},
      id: {:worker, id}
    )
  end

  # L requests per window of T ms (default: 5 per 10 s).
  defp limit, do: String.to_integer(System.get_env("LIMIT", "5"))
  defp window_ms, do: String.to_integer(System.get_env("LIMIT_WINDOW_MS", "10000"))

  # Reads an env var and maps it to one of the allowed atoms (crashes otherwise).
  defp env(var, allowed, default), do: Map.fetch!(allowed, System.get_env(var, default))
end

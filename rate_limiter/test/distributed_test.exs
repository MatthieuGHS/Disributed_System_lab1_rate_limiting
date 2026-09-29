defmodule RateLimiter.DistributedTest do
  @moduledoc """
  End-to-end tests on a real cluster: 6 peer nodes (limiter, api, w1..w4)
  started for each test. The oracle is the API log: what really reached
  the protected resource.
  """
  use ExUnit.Case

  alias RateLimiter.{Api, Client, Cluster, LoadBalancer}

  @moduletag :distributed
  @moduletag timeout: 120_000

  @limit 5

  # Starts a fresh cluster and a local load balancer routing to its workers.
  defp cluster(opts) do
    holder =
      Cluster.start(
        Keyword.merge([quiet: true, log_level: :emergency, limit: @limit, recovery_ms: 0], opts)
      )

    on_exit(fn -> Cluster.stop(holder) end)
    start_supervised!({LoadBalancer, workers: Cluster.workers()})
    :ok
  end

  defp api_calls(ip), do: Api.log() |> Enum.count(&(&1.ip == ip))

  # Long window: it never rolls over during a test.
  @window 60_000

  test "concurrency: same IP through 4 workers reaches the API exactly L times" do
    cluster(window_ms: @window)

    result = Client.run("6.6.6.6", ["alice"], ~w(s1 s2 s3 s4), 100)

    assert api_calls("6.6.6.6") == @limit
    assert result == %{ok: @limit, denied: 100 - @limit}
  end

  test "local mode is bypassed with several sessions (4 x L), global is not" do
    cluster(window_ms: @window, mode: :local)
    Client.run("6.6.6.6", ["alice"], ~w(s1 s2 s3 s4), 100)
    # Sticky round-robin: 4 sessions land on 4 workers, each allows L.
    assert api_calls("6.6.6.6") == 4 * @limit
  end

  test "several accounts on one IP do not help: the key is the IP" do
    cluster(window_ms: @window)
    Client.run("6.6.6.6", ~w(a1 a2 a3 a4 a5), ["s1"], 50)
    assert api_calls("6.6.6.6") == @limit
  end

  test "honest users are not affected by an attacker" do
    cluster(window_ms: @window)

    attacker = Task.async(fn -> Client.run("6.6.6.6", ~w(a b), ~w(s1 s2 s3 s4), 100) end)
    honest = Task.async(fn -> Client.run("1.1.1.1", ["carol"], ["s5"], 3) end)

    assert Task.await(honest, 30_000) == %{ok: 3, denied: 0}
    Task.await(attacker, 30_000)
    assert api_calls("6.6.6.6") == @limit
  end

  test "worker crash: it is restarted and the limit still holds" do
    cluster(window_ms: @window)
    Client.run("6.6.6.6", ["alice"], ~w(s1 s2 s3 s4), 8)

    # Kill the worker process on w2; its node supervisor restarts it.
    w2 = Cluster.node_name(:w2)
    old = :erpc.call(w2, Process, :whereis, [:worker])
    :erpc.call(w2, Process, :exit, [old, :kill])
    wait_until(fn -> :erpc.call(w2, Process, :whereis, [:worker]) not in [nil, old] end)

    result = Client.run("6.6.6.6", ["alice"], ~w(s1 s2 s3 s4), 40)

    # Liveness: every request got an answer. Safety: still L in total.
    assert result.ok + result.denied == 40
    assert api_calls("6.6.6.6") == @limit
  end

  test "Limiter crash mid-window: conservative restart never exceeds L" do
    # Short window, recovery = one full window (the real setting).
    cluster(window_ms: 2_000, recovery_ms: 2_000)
    Process.sleep(2_000)

    Client.run("6.6.6.6", ["alice"], ["s1"], 3)
    assert api_calls("6.6.6.6") == 3

    old = :global.whereis_name(RateLimiter.Limiter)
    Cluster.crash_limiter()
    wait_until(fn -> :global.whereis_name(RateLimiter.Limiter) not in [:undefined, old] end)

    # Counters are lost, yet nothing gets through in what is left of the window.
    result = Client.run("6.6.6.6", ["alice"], ~w(s1 s2 s3 s4), 40)
    assert result.ok == 0
    assert api_calls("6.6.6.6") <= @limit
  end

  test "partition + fail_closed: nobody passes (keeps C, loses A)" do
    cluster(window_ms: @window, policy: :fail_closed)
    Cluster.partition_limiter()
    wait_until(fn -> :global.whereis_name(RateLimiter.Limiter) == :undefined end)

    result = Client.run("6.6.6.6", ["alice"], ~w(s1 s2 s3 s4), 40)

    assert result == %{ok: 0, denied: 40}
    assert api_calls("6.6.6.6") == 0
  end

  test "partition + fail_open: everybody passes (keeps A, loses C)" do
    cluster(window_ms: @window, policy: :fail_open)
    Cluster.partition_limiter()
    wait_until(fn -> :global.whereis_name(RateLimiter.Limiter) == :undefined end)

    result = Client.run("6.6.6.6", ["alice"], ~w(s1 s2 s3 s4), 40)

    assert result == %{ok: 40, denied: 0}
    assert api_calls("6.6.6.6") > @limit
  end

  test "partition then heal: the Limiter is back and the limit is L again" do
    cluster(window_ms: @window)
    Cluster.partition_limiter()
    wait_until(fn -> :global.whereis_name(RateLimiter.Limiter) == :undefined end)
    assert Client.run("6.6.6.6", ["alice"], ~w(s1 s2 s3 s4), 20).ok == 0

    assert Cluster.heal() == :ok

    # The Limiter kept its (empty) counters: the partition did not crash it.
    result = Client.run("6.6.6.6", ["alice"], ~w(s1 s2 s3 s4), 40)
    assert result == %{ok: @limit, denied: 40 - @limit}
    assert api_calls("6.6.6.6") == @limit
  end

  test "slow Limiter beyond the timeout: every client still gets an answer" do
    cluster(window_ms: @window)
    Cluster.slow_limiter()

    # Liveness: all 20 get an answer (429, fail_closed) despite the Limiter.
    result = Client.run("6.6.6.6", ["alice"], ~w(s1 s2 s3 s4), 20)
    assert result == %{ok: 0, denied: 20}

    # The "gap": the 20 timed-out checks are still in the Limiter's mailbox.
    # Once resumed it handles them and counts them, although nobody waits
    # for the answers any more (late replies are dropped).
    Cluster.resume_limiter()
    assert Client.run("6.6.6.6", ["alice"], ["s1"], 1) == %{ok: 0, denied: 1}

    # Quota wasted by ghost requests (availability lost), but safe:
    # nothing reached the API.
    assert api_calls("6.6.6.6") == 0
  end

  defp wait_until(fun, attempts \\ 100) do
    cond do
      fun.() -> :ok
      attempts == 0 -> flunk("condition not met in time")
      true -> Process.sleep(50) && wait_until(fun, attempts - 1)
    end
  end
end

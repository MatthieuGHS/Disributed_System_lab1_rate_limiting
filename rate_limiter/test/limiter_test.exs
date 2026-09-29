defmodule RateLimiter.LimiterTest do
  use ExUnit.Case

  alias RateLimiter.Limiter

  # Long window so it never rolls over mid-test.
  @opts [limit: 3, window_ms: 60_000, name: nil]

  describe "normal behaviour" do
    setup do
      # Private instance per test; no recovery period so we can test the counter.
      %{server: start_supervised!({Limiter, [recovery_ms: 0] ++ @opts})}
    end

    test "L allows then deny", %{server: server} do
      assert Limiter.check("1.1.1.1", server) == :allow
      assert Limiter.check("1.1.1.1", server) == :allow
      assert Limiter.check("1.1.1.1", server) == :allow
      assert Limiter.check("1.1.1.1", server) == :deny
    end

    test "IPs are counted separately", %{server: server} do
      for _ <- 1..3, do: Limiter.check("1.1.1.1", server)
      assert Limiter.check("2.2.2.2", server) == :allow
    end
  end

  describe "conservative restart" do
    test "denies everything during the recovery period" do
      server = start_supervised!({Limiter, @opts})
      assert Limiter.check("1.1.1.1", server) == :deny
    end

    test "a crash inside a window does not let an IP exceed L" do
      # Short window; recovery defaults to one full window.
      start_supervised!({Limiter, limit: 3, window_ms: 500, name: :crash_limiter})
      Process.sleep(500)

      for _ <- 1..3, do: assert(Limiter.check("1.1.1.1", :crash_limiter) == :allow)

      old = Process.whereis(:crash_limiter)
      Process.exit(old, :kill)
      wait_for_restart(:crash_limiter, old)

      # Counters were wiped, yet a 4th request in the same window is denied.
      assert Limiter.check("1.1.1.1", :crash_limiter) == :deny
    end
  end

  defp wait_for_restart(name, old) do
    case Process.whereis(name) do
      pid when is_pid(pid) and pid != old ->
        pid

      _ ->
        Process.sleep(10)
        wait_for_restart(name, old)
    end
  end
end

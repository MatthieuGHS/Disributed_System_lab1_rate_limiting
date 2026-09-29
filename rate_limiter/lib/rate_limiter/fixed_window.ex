defmodule RateLimiter.FixedWindow do
  @moduledoc """
  Pure fixed-window algorithm, shared by the global Limiter and by
  workers in `:local` mode. Only the place where `counts` lives differs.
  """

  # Returns {:allow | :deny, new_counts}.
  def check(counts, ip, limit, window_ms) do
    key = {ip, current_window(window_ms)}
    count = Map.get(counts, key, 0)

    if count < limit do
      {:allow, Map.put(counts, key, count + 1)}
    else
      {:deny, counts}
    end
  end

  # Single source of time: the clock of the node running this code.
  defp current_window(window_ms) do
    div(System.monotonic_time(:millisecond), window_ms)
  end
end

defmodule RateLimiter.RawLimiter do
  @moduledoc """
  Hand-written limiter with spawn/send/receive (step 2, training code).
  No time window: only counts requests per IP.
  """

  def start(limit) do
    spawn(fn -> loop(%{}, limit) end)
  end

  def check(pid, ip) do
    ref = make_ref()
    send(pid, {:check, ip, self(), ref})

    receive do
      {^ref, res} -> res
    after
      1000 -> :timeout
    end
  end

  defp loop(state, limit) do
    receive do
      {:check, ip, from, ref} ->
        count = Map.get(state, ip, 0)

        new_state =
          if count < limit do
            send(from, {ref, :allow})
            Map.put(state, ip, count + 1)
          else
            send(from, {ref, :deny})
            state
          end

        loop(new_state, limit)
    end
  end
end

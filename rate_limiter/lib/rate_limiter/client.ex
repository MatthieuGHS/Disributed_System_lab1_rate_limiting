defmodule RateLimiter.Client do
  @moduledoc """
  Simulated users. A client is one IP with some accounts and sessions:

    * honest: 1 IP, 1 account, 1 session;
    * attacker: 1 IP, several accounts and several sessions, hoping
      the sessions land on different workers.
  """

  alias RateLimiter.{Api, LoadBalancer}

  @doc """
  Sends `requests` concurrent requests, spread over the client's
  sessions and accounts. Returns `%{ok: n, denied: n}`.
  """
  def run(ip, accounts, sessions, requests) do
    1..requests
    |> Task.async_stream(
      fn i ->
        session = Enum.at(sessions, rem(i, length(sessions)))
        account = Enum.at(accounts, rem(i, length(accounts)))
        LoadBalancer.request(session, ip, account)
      end, timeout: 30_000, max_concurrency: 100)
    |> Enum.reduce(%{ok: 0, denied: 0}, fn
      {:ok, {:ok, _}}, acc -> Map.update!(acc, :ok, &(&1 + 1))
      {:ok, {:error, 429}}, acc -> Map.update!(acc, :denied, &(&1 + 1))
    end)
  end

  @doc """
  Attack scenario: 1 IP, 2 accounts, 4 sessions, 40 requests, next to an
  honest user. Prints how many calls actually reached the API per IP.
  """
  def attack do
    Api.reset()
    attacker = Task.async(fn -> run("6.6.6.6", ["alice", "bob"], ~w(s1 s2 s3 s4), 40) end)
    honest = Task.async(fn -> run("1.1.1.1", ["carol"], ~w(s5), 10) end)
    results = %{attacker: Task.await(attacker), honest: Task.await(honest)}

    api_calls = Api.log() |> Enum.frequencies_by(& &1.ip)
    IO.inspect(results, label: "client view")
    IO.inspect(api_calls, label: "API calls per IP (oracle)")
    api_calls
  end
end

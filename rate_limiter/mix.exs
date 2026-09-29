defmodule RateLimiter.MixProject do
  use Mix.Project

  def project do
    [
      app: :rate_limiter,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      # :observer (+ :wx, :runtime_tools) so that :observer.start() works in iex
      extra_applications: [:logger, :runtime_tools, :wx, :observer],
      mod: {RateLimiter.Application, []}
    ]
  end

  # Tests start their own processes and peer nodes: the test node itself
  # must not run the application (it would register the global names).
  defp aliases, do: [test: "test --no-start"]

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # {:dep_from_hexpm, "~> 0.3.0"},
      # {:dep_from_git, git: "https://github.com/elixir-lang/my_dep.git", tag: "0.1.0"}
    ]
  end
end

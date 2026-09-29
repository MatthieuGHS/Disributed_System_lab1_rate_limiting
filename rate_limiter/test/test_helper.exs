# Distributed tests need this node to be part of a cluster.
System.cmd("epmd", ["-daemon"])
{:ok, _} = Node.start(:rl_test, :shortnames)

ExUnit.start()

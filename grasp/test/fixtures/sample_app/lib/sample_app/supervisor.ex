defmodule SampleApp.Supervisor do
  @moduledoc """
  A supervisor whose `init/1` is written *by hand*, with no children to start.

  The fixture never starts it:

    * `start_link/1` hands its options to `Supervisor.start_link/3`;
    * `init/1` answers `:one_for_one` over an empty list.
  """
  use Supervisor

  @doc "Starts the supervisor."
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts), do: Supervisor.start_link(__MODULE__, :ok, opts)

  @impl true
  def init(:ok), do: Supervisor.init([], strategy: :one_for_one)
end

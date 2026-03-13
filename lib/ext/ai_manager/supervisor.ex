defmodule FarmbotOS.AIManager.Supervisor do
  @moduledoc """
  Supervisor for the AI managed mode subsystem.

  Manages two child processes:
    - DataCollector: periodically gathers sensor data, photos,
      and bot state, then sends snapshots to a remote AI server.
    - CommandExecutor: receives AI-generated command lists and
      feeds them into the CeleryScript execution pipeline.
  """
  use Supervisor

  def start_link(args, opts \\ [name: __MODULE__]) do
    Supervisor.start_link(__MODULE__, args, opts)
  end

  @impl Supervisor
  def init(_args) do
    config = Application.get_env(:farmbot, __MODULE__) || []

    Keyword.get(config, :children, [
      FarmbotOS.AIManager.DataCollector,
      FarmbotOS.AIManager.CommandExecutor
    ])
    |> Supervisor.init(strategy: :one_for_one)
  end
end

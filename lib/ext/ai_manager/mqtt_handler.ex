defmodule FarmbotOS.AIManager.MQTTHandler do
  @moduledoc """
  Handles inbound MQTT messages on `bot/{device}/ai_commands`.

  This allows an AI cloud server to push commands to FarmBot in
  real time (instead of waiting for the next polling cycle).

  ## Expected payload

  JSON-encoded map:

      {
        "id": "unique-request-id",
        "actions": [
          {"type": "move", "x": 100, "y": 200, "z": 0},
          {"type": "photo"}
        ]
      }

  ## Response

  Published to `bot/{device}/ai_results`:

      {"id": "unique-request-id", "status": "ok", "results": [...]}
  """

  use GenServer

  require FarmbotOS.Logger
  require Logger

  alias FarmbotOS.{JSON, MQTT}
  alias FarmbotOS.AIManager.CommandExecutor
  alias __MODULE__, as: State

  defstruct client_id: "NOT_SET", username: "NOT_SET"

  def start_link(args, opts \\ [name: __MODULE__]) do
    GenServer.start_link(__MODULE__, args, opts)
  end

  def init(args) do
    state = %State{
      client_id: Keyword.fetch!(args, :client_id),
      username: Keyword.fetch!(args, :username)
    }

    {:ok, state}
  end

  def handle_info({:inbound, [_, _, "ai_commands"], payload}, state) do
    Task.Supervisor.start_child(
      FarmbotOS.Task.Supervisor,
      fn -> process_ai_payload(payload, state) end
    )

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp process_ai_payload(payload, state) do
    case JSON.decode(payload) do
      {:ok, %{"actions" => actions, "id" => req_id}} when is_list(actions) ->
        FarmbotOS.Logger.info(
          2,
          "AI push: #{length(actions)} commands (#{req_id})"
        )

        results = CommandExecutor.execute_commands(actions)
        send_reply(state, req_id, "ok", results)

      {:ok, %{"actions" => actions}} when is_list(actions) ->
        FarmbotOS.Logger.info(2, "AI push: #{length(actions)} commands")
        CommandExecutor.execute_commands(actions)

      {:ok, other} ->
        FarmbotOS.Logger.error(
          2,
          "AI push: unexpected format #{inspect(other)}"
        )

      {:error, reason} ->
        FarmbotOS.Logger.error(2, "AI push: JSON decode error #{inspect(reason)}")
    end
  rescue
    e ->
      Logger.error("AI push handler crash: #{Exception.message(e)}")
  end

  defp send_reply(state, req_id, status, results) do
    reply =
      JSON.encode!(%{
        id: req_id,
        status: status,
        results: format_results(results),
        timestamp: DateTime.to_iso8601(DateTime.utc_now())
      })

    topic = "bot/#{state.username}/ai_results"
    MQTT.publish(state.client_id, topic, reply)
  end

  defp format_results(results) when is_list(results) do
    Enum.map(results, fn
      :ok -> "ok"
      {:error, reason} -> "error: #{inspect(reason)}"
      other -> inspect(other)
    end)
  end

  defp format_results(_), do: []
end

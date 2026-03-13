defmodule FarmbotOS.AIManager.DataCollector do
  @moduledoc """
  Periodically collects a snapshot of FarmBot state (position, pins,
  sensor readings, plant/weed data) and POSTs it to a configurable
  AI server endpoint.  The server's response – a list of commands –
  is forwarded to `CommandExecutor` for execution.

  ## Configuration

  Set the following FarmwareEnv keys via the Web App or Lua:

    AI_SERVER_URL   – base URL of your AI backend  (required)
    AI_API_KEY      – bearer token for the AI API  (optional)
    AI_INTERVAL_MS  – collection interval in ms     (default 3_600_000 = 1 h)
  """

  use GenServer

  require FarmbotOS.Logger
  require Logger

  alias FarmbotOS.{Asset, BotState, BotStateNG, JSON}
  alias FarmbotOS.AIManager.CommandExecutor
  alias FarmbotOS.Firmware.Command, as: FWCommand

  @default_interval_ms 3_600_000
  @http_timeout_ms 180_000

  defstruct [:timer, :enabled]

  # ── Public API ──────────────────────────────────────────────

  def start_link(args, opts \\ [name: __MODULE__]) do
    GenServer.start_link(__MODULE__, args, opts)
  end

  @doc "Trigger an immediate AI cycle outside of the normal timer."
  def trigger_cycle(server \\ __MODULE__) do
    GenServer.cast(server, :trigger_cycle)
  end

  # ── GenServer callbacks ─────────────────────────────────────

  def init(_args) do
    enabled = ai_server_url() != ""

    if enabled do
      FarmbotOS.Logger.info(3, "AI managed mode enabled → #{ai_server_url()}")
    else
      FarmbotOS.Logger.debug(3, "AI managed mode disabled (AI_SERVER_URL not set)")
    end

    timer = schedule_next(enabled)
    {:ok, %__MODULE__{timer: timer, enabled: enabled}}
  end

  def handle_cast(:trigger_cycle, state) do
    cancel_timer(state.timer)
    run_cycle()
    {:noreply, %{state | timer: schedule_next(true)}}
  end

  def handle_info(:collect, state) do
    enabled = ai_server_url() != ""

    if enabled do
      run_cycle()
    end

    {:noreply, %{state | timer: schedule_next(enabled), enabled: enabled}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ── Internals ───────────────────────────────────────────────

  defp run_cycle do
    job = "AI Cycle"
    set_progress(job, 0, "Collecting data")

    snapshot = collect_snapshot()
    set_progress(job, 20, "Uploading to AI server")

    case send_to_cloud(snapshot) do
      {:ok, %{"actions" => actions}} when is_list(actions) ->
        set_progress(job, 60, "Executing #{length(actions)} commands")
        CommandExecutor.execute_commands(actions)
        set_progress(job, 100, "Complete")

      {:ok, body} ->
        FarmbotOS.Logger.debug(3, "AI server returned no actions: #{inspect(body)}")
        set_progress(job, 100, "Complete (no actions)")

      {:error, reason} ->
        FarmbotOS.Logger.error(3, "AI cycle failed: #{inspect(reason)}")
        set_progress(job, -1, "Error")
    end
  rescue
    e ->
      Logger.error("AI cycle crash: #{Exception.message(e)}")
      set_progress("AI Cycle", -1, "Error")
  end

  @doc "Build a map that represents the current state of the bot."
  def collect_snapshot do
    state = BotState.fetch()
    view = BotStateNG.view(state)

    %{
      position: state.location_data.position,
      encoders: state.location_data.scaled_encoders,
      pins: view.pins,
      soil_moisture: safe_read_pin(59, 1),
      plants: safe_get_points("Plant"),
      weeds: safe_get_points("Weed"),
      tool_slots: safe_get_points("ToolSlot"),
      device: safe_device_view(),
      informational_settings: view.informational_settings,
      firmware_config: safe_firmware_config(),
      timestamp: DateTime.to_iso8601(DateTime.utc_now())
    }
  end

  defp safe_read_pin(pin, mode) do
    case FWCommand.read_pin(pin, mode) do
      {:ok, value} -> value
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp safe_get_points(type) do
    Asset.get_all_points_by_type(type)
    |> Enum.map(fn p ->
      %{id: p.id, x: p.x, y: p.y, z: p.z, name: p.name, pointer_type: p.pointer_type}
    end)
  rescue
    _ -> []
  end

  defp safe_device_view do
    device = Asset.device()
    if device, do: %{id: device.id, name: device.name}, else: %{}
  rescue
    _ -> %{}
  end

  defp safe_firmware_config do
    conf = Asset.firmware_config()

    %{
      movement_axis_nr_steps_x: conf.movement_axis_nr_steps_x,
      movement_axis_nr_steps_y: conf.movement_axis_nr_steps_y,
      movement_max_spd_x: conf.movement_max_spd_x,
      movement_max_spd_y: conf.movement_max_spd_y,
      movement_step_per_mm_x: conf.movement_step_per_mm_x,
      movement_step_per_mm_y: conf.movement_step_per_mm_y
    }
  rescue
    _ -> %{}
  end

  defp send_to_cloud(snapshot) do
    url = ai_server_url()
    api_key = ai_api_key()

    headers = [
      {"content-type", "application/json"},
      {"user-agent", "FarmbotOS/#{FarmbotOS.Project.version()}"}
    ]

    headers =
      if api_key != "" do
        [{"authorization", "Bearer #{api_key}"} | headers]
      else
        headers
      end

    body = JSON.encode!(snapshot)
    hackney = FarmbotOS.HTTP.hackney()
    opts = [recv_timeout: @http_timeout_ms]

    case hackney.request(:post, url <> "/api/analyze", headers, body, opts) do
      {:ok, status, _headers, ref} when status >= 200 and status <= 299 ->
        {:ok, resp_body} = hackney.body(ref)
        JSON.decode(resp_body)

      {:ok, status, _headers, ref} ->
        {:ok, resp_body} = hackney.body(ref)
        {:error, "AI server returned HTTP #{status}: #{resp_body}"}

      {:error, reason} ->
        {:error, "HTTP request failed: #{inspect(reason)}"}
    end
  end

  # ── Helpers ─────────────────────────────────────────────────

  defp ai_server_url do
    get_env("AI_SERVER_URL")
  end

  defp ai_api_key do
    get_env("AI_API_KEY")
  end

  defp get_env(key) do
    case Asset.Repo.one(
           from(e in Asset.FarmwareEnv, where: e.key == ^key, limit: 1)
         ) do
      %{value: v} when is_binary(v) -> v
      _ -> ""
    end
  rescue
    _ -> ""
  end

  defp interval_ms do
    case get_env("AI_INTERVAL_MS") do
      "" -> @default_interval_ms
      val -> String.to_integer(val)
    end
  rescue
    _ -> @default_interval_ms
  end

  defp schedule_next(true), do: FarmbotOS.Time.send_after(self(), :collect, interval_ms())
  defp schedule_next(false), do: FarmbotOS.Time.send_after(self(), :collect, 60_000)

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(ref), do: FarmbotOS.Time.cancel_timer(ref)

  defp set_progress(name, percent, status) do
    progress = %FarmbotOS.BotState.JobProgress.Percent{
      status: status,
      percent: percent,
      type: "ai"
    }

    BotState.set_job_progress(name, progress)
  rescue
    _ -> :ok
  end
end

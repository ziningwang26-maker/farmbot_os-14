defmodule FarmbotOS.AIManager.CommandExecutor do
  @moduledoc """
  Receives a list of AI-generated command maps and executes them
  through FarmBot's existing CeleryScript / SysCall pipeline.

  ## Supported command types

  Each command is a map with a `"type"` key:

    %{"type" => "move",     "x" => 100, "y" => 200, "z" => 0, "speed" => 80}
    %{"type" => "water",    "x" => 100, "y" => 200, "z" => 0, "duration_ms" => 5000, "pin" => 8}
    %{"type" => "photo",    "x" => 100, "y" => 200, "z" => -20}
    %{"type" => "read_sensor", "pin" => 59, "mode" => 1}
    %{"type" => "write_pin",   "pin" => 8,  "value" => 1, "mode" => 0}
    %{"type" => "home",     "axis" => "all"}
    %{"type" => "find_home","axis" => "x"}
    %{"type" => "wait",     "ms" => 5000}
    %{"type" => "sequence", "id" => 42}
    %{"type" => "lua",      "script" => "move_absolute(0, 0, 0)"}
    %{"type" => "celery",   "ast" => %{...}}   -- raw CeleryScript AST
  """

  use GenServer

  require FarmbotOS.Logger
  require Logger

  alias FarmbotOS.Celery
  alias FarmbotOS.Celery.{AST, SysCallGlue}
  alias FarmbotOS.Firmware.Command, as: FWCommand
  alias FarmbotOS.{BotState, JSON}

  defstruct executing: false

  # ── Public API ──────────────────────────────────────────────

  def start_link(args, opts \\ [name: __MODULE__]) do
    GenServer.start_link(__MODULE__, args, opts)
  end

  @doc "Execute a list of AI command maps. Blocks until all are done."
  def execute_commands(commands, server \\ __MODULE__) when is_list(commands) do
    GenServer.call(server, {:execute, commands}, :infinity)
  end

  # ── GenServer callbacks ─────────────────────────────────────

  def init(_args) do
    {:ok, %__MODULE__{}}
  end

  def handle_call({:execute, commands}, _from, state) do
    results = do_execute_all(commands)
    {:reply, results, state}
  end

  # ── Execution ───────────────────────────────────────────────

  defp do_execute_all(commands) do
    total = length(commands)

    commands
    |> Enum.with_index(1)
    |> Enum.map(fn {cmd, idx} ->
      log_step(cmd, idx, total)
      set_progress(idx, total)

      result =
        try do
          execute_one(cmd)
        rescue
          e -> {:error, Exception.message(e)}
        catch
          _, e -> {:error, inspect(e)}
        end

      case result do
        :ok ->
          :ok

        {:error, reason} ->
          FarmbotOS.Logger.error(
            2,
            "AI command #{idx}/#{total} failed: #{inspect(reason)}"
          )

          {:error, reason}

        other ->
          other
      end
    end)
  end

  # ── Command implementations ─────────────────────────────────

  defp execute_one(%{"type" => "move"} = cmd) do
    x = to_float(cmd["x"])
    y = to_float(cmd["y"])
    z = to_float(cmd["z"])
    speed = to_float(cmd["speed"] || 100)
    SysCallGlue.move_absolute(x, y, z, speed)
  end

  defp execute_one(%{"type" => "water"} = cmd) do
    x = to_float(cmd["x"])
    y = to_float(cmd["y"])
    z = to_float(cmd["z"])
    pin = cmd["pin"] || 8
    duration = cmd["duration_ms"] || 3000

    with :ok <- SysCallGlue.move_absolute(x, y, z, 100),
         :ok <- SysCallGlue.write_pin(pin, 0, 1) do
      FarmbotOS.Time.sleep(duration)
      SysCallGlue.write_pin(pin, 0, 0)
    end
  end

  defp execute_one(%{"type" => "photo"} = cmd) do
    if cmd["x"] do
      x = to_float(cmd["x"])
      y = to_float(cmd["y"])
      z = to_float(cmd["z"])
      :ok = SysCallGlue.move_absolute(x, y, z, 100)
    end

    SysCallGlue.execute_script("take-photo", %{})
  end

  defp execute_one(%{"type" => "read_sensor"} = cmd) do
    pin = cmd["pin"] || 59
    mode = cmd["mode"] || 1

    case FWCommand.read_pin(pin, mode) do
      {:ok, _value} -> :ok
      error -> error
    end
  end

  defp execute_one(%{"type" => "write_pin"} = cmd) do
    SysCallGlue.write_pin(cmd["pin"], cmd["mode"] || 0, cmd["value"] || 0)
  end

  defp execute_one(%{"type" => "home"} = cmd) do
    axis = cmd["axis"] || "all"

    if axis == "all" do
      with :ok <- SysCallGlue.find_home("z"),
           :ok <- SysCallGlue.find_home("y") do
        SysCallGlue.find_home("x")
      end
    else
      SysCallGlue.find_home(axis)
    end
  end

  defp execute_one(%{"type" => "find_home"} = cmd) do
    SysCallGlue.find_home(cmd["axis"] || "x")
  end

  defp execute_one(%{"type" => "wait"} = cmd) do
    SysCallGlue.wait(cmd["ms"] || 1000)
  end

  defp execute_one(%{"type" => "sequence"} = cmd) do
    id = cmd["id"]

    case SysCallGlue.get_sequence(id) do
      %AST{} = ast ->
        ref = make_ref()
        Celery.execute(ast, ref)

        receive do
          {:csvm_done, ^ref, :ok} -> :ok
          {:csvm_done, ^ref, error} -> error
        after
          600_000 -> {:error, "Sequence #{id} timed out"}
        end

      error ->
        {:error, "Failed to load sequence #{id}: #{inspect(error)}"}
    end
  end

  defp execute_one(%{"type" => "lua"} = cmd) do
    SysCallGlue.perform_lua(cmd["script"], [], cmd["comment"] || "AI")
  end

  defp execute_one(%{"type" => "celery"} = cmd) do
    ast = cmd["ast"] |> AST.decode()
    ref = make_ref()
    Celery.execute(ast, ref)

    receive do
      {:csvm_done, ^ref, :ok} -> :ok
      {:csvm_done, ^ref, error} -> error
    after
      600_000 -> {:error, "CeleryScript execution timed out"}
    end
  end

  defp execute_one(%{"type" => type}) do
    {:error, "Unknown AI command type: #{inspect(type)}"}
  end

  defp execute_one(cmd) do
    {:error, "Invalid AI command format: #{inspect(cmd)}"}
  end

  # ── Helpers ─────────────────────────────────────────────────

  defp to_float(nil), do: 0.0
  defp to_float(n) when is_float(n), do: n
  defp to_float(n) when is_integer(n), do: n / 1
  defp to_float(n) when is_binary(n), do: String.to_float(n)

  defp log_step(cmd, idx, total) do
    type = cmd["type"] || "unknown"
    FarmbotOS.Logger.info(2, "AI #{idx}/#{total}: #{type}")
  end

  defp set_progress(idx, total) do
    percent = round(idx / total * 100)

    progress = %FarmbotOS.BotState.JobProgress.Percent{
      status: "Working",
      percent: percent,
      type: "ai"
    }

    BotState.set_job_progress("AI Execution", progress)
  rescue
    _ -> :ok
  end
end

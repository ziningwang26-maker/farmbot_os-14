# FarmBot OS v14 Architecture Reference

## Project Overview

FarmBot OS is an Elixir/OTP + Nerves embedded operating system for Raspberry Pi (rpi, rpi3, rpi4) that controls the FarmBot open-source farming robot. It is a monolithic Mix project (~206 .ex source files) using SQLite for local persistence and MQTT for real-time cloud communication.

## Tech Stack

| Layer | Technology |
|-------|-----------|
| Language | Elixir (~1.16) |
| Embedded Framework | Nerves (firmware packaging, OTA) |
| Database | SQLite3 (via Ecto + ecto_sqlite3) |
| MQTT | Tortoise311 (MQTT 3.1.1 client) |
| HTTP | :httpc + Hackney + Tesla |
| Serial Communication | circuits_uart (Arduino/Farmduino firmware) |
| GPIO | circuits_gpio, circuits_i2c |
| Scripting Engine | Luerl (Lua 5.3 embedded VM) |
| Web Configurator | Plug + Cowboy (HTTP) |
| Network Management | VintageNet (WiFi/Ethernet) |

## Directory Structure

```
farmbot_os-14/
├── config/          # Mix configuration (config.exs, target.exs, dev.exs, test.exs)
├── lib/             # Core source code (4 major modules)
│   ├── celery/      # CeleryScript compiler and execution engine
│   ├── core/        # Data asset models, BotState, config storage
│   ├── ext/         # External communication (MQTT, API sync, Bootstrap auth)
│   ├── firmware/    # Firmware communication (UART/GCode)
│   └── os/          # OS layer: Lua bindings, syscalls, configurator, init
├── platform/        # Platform-specific code
│   ├── host/        # Development machine (macOS/Linux) mock implementations
│   └── target/      # Real hardware (RPi): network, GPIO, LED
├── priv/            # Static assets (configurator Web UI, DB migrations)
├── rel/             # Nerves Release configuration
├── rootfs_overlay/  # Embedded filesystem overlay
└── test/            # Test code
```

## OTP Supervision Tree

Application entry: `FarmbotOS.start/2` in `lib/farmbot_os.ex`

```
FarmbotOS (Application, strategy: :one_for_one)
├── Asset.Repo              # SQLite Ecto Repo
├── EctoMigrator            # Auto DB migration
├── BotState.Supervisor     # Bot state management (one_for_all)
│   ├── BotState            # GenServer: in-memory state tree
│   ├── BotState.FileSystem # State persistence to filesystem
│   └── BotState.SchedulerUsageReporter
├── Bootstrap               # Auth bootstrapping (JWT token)
├── Configurator.Supervisor # Web configurator (first-time WiFi/account setup)
├── Init.Supervisor         # Pre-boot checks (filesystem, RTC)
├── Leds                    # LED status indicators
├── Celery.Scheduler        # CeleryScript scheduler (FarmEvent timed execution)
├── FirmwareEstopTimer      # Emergency stop timer
├── Platform.Supervisor     # Platform-specific subtree (network, etc.)
├── Asset.Supervisor        # Asset change listeners (ChangeSupervisor x8 + AssetMonitor)
├── Firmware.UARTObserver   # Serial port auto-detection
└── Task.Supervisor         # General async task pool
```

### Post-Authentication Subtree (started after Bootstrap succeeds)

```
Bootstrap.Supervisor
├── EagerLoader.Supervisor  # API data preloading (14 asset types)
├── DirtyWorker.Supervisor  # Local dirty data writeback to API (14 asset types)
├── MQTT.Supervisor         # MQTT connection and message handling
│   └── Tortoise311.Connection
│       └── MQTT Handler → TopicSupervisor
│           ├── PingHandler, RPCHandler, SyncHandler
│           ├── TerminalHandler, LogHandler
│           ├── BotStateHandler, TelemetryHandler
├── API.ImageUploader
├── Bootstrap.DropPasswordTask
└── API.Ping
```

## MQTT Communication

| Topic Pattern | Direction | Purpose |
|--------------|-----------|---------|
| `bot/{id}/from_clients` | Cloud→Device | Receive RPC commands |
| `bot/{id}/from_device` | Device→Cloud | Return RPC results |
| `bot/{id}/sync/#` | Cloud→Device | Data sync notifications |
| `bot/{id}/ping/#` | Bidirectional | Heartbeat |
| `bot/{id}/terminal_input` | Cloud→Device | Remote terminal |
| `bot/{id}/status` | Device→Cloud | Device status push |
| `bot/{id}/logs` | Device→Cloud | Log push |

## CeleryScript Execution Pipeline

```
JSON command (from MQTT/FarmEvent)
  → JSON.decode → AST.decode
  → Compiler.compile(ast, scope)  # Compile to Elixir anonymous functions
  → StepRunner.begin()            # Execute compiled functions step by step
  → SysCallGlue.xxx()            # Call actual system functions
```

## Firmware Communication (UART/GCode)

```
CeleryScript → SysCallGlue → SysCalls.Movement → Firmware.Command → UARTCore → circuits_uart → MCU
```

Key GCode commands: G00 (move), G28 (home), F11-F16 (find home/length), F41/F42 (write/read pin), E (e-stop).

## Data Synchronization

```
Cloud API ──HTTP GET──→ EagerLoader (preload to SQLite)
Cloud API ──MQTT sync──→ SyncHandler → update local SQLite
Local changes → DirtyWorker → HTTP POST/PUT → Cloud API
```

## Platform Abstraction

| Interface | Host (dev) | Target (RPi) |
|-----------|-----------|--------------|
| GPIO | StubGPIOHandler | CircuitsGPIOHandler |
| LED | StubHandler | CircuitsHandler |
| Network | FakeNetworkLayer | VintageNetworkLayer |
| System | Host.SystemTasks | Target.SystemTasks |

## Secondary Development Entry Points

1. **New CeleryScript command**: compiler in `lib/celery/compilers/`, delegate in `compiler.ex`, callback in `sys_call_glue.ex`, implementation in `lib/os/sys_calls/`
2. **New Lua function**: module in `lib/os/lua/`, signature `def func(args, lua) -> {[results], lua}`
3. **New sensor/peripheral**: GCode in `lib/firmware/command.ex`, side effects in `inbound_side_effects.ex`
4. **New MQTT handler**: subscribe in `MQTT.Supervisor`, route in `MQTT.handle_message/3`, create handler GenServer
5. **New API asset**: Ecto Schema in `lib/core/asset/`, register in EagerLoader + DirtyWorker supervisors

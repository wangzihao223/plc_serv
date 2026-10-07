# PLC Server

Elixir service for reading Siemens S7 DB bytes through a small C Port using Snap7.
Subscriptions share a periodic read for each identical `{PLC, DB, offset, length, interval}`
and send a message only when the bytes change.

Documentation: [design](docs/design.md), [system architecture](docs/system-architecture.md),
[interfaces](docs/interfaces.md), [HTTP API](docs/http-api.md), and
[event contract](docs/plc-events.md).

## Requirements

- Elixir 1.18+ and a C compiler (`cc` or `CC`)
- Snap7 shared library available at runtime (`libsnap7.so` on Linux or `snap7.dll` on Windows).
  On Linux, `PLC_SNAP7_LIBRARY` can point to a different library path.
- For S7-1200/1500 absolute DB access, enable PUT/GET communication and disable optimized
  block access on the DB being read.

## Run

```sh
PLC_HOST=192.168.0.10 PLC_RACK=0 PLC_SLOT=1 iex -S mix
```

`PLC_ID` defaults to `plc1`. No PLC worker starts when `PLC_HOST` is unset.

For multiple PLCs, configure `:devices` in `config/config.exs` instead of using
the single-device environment variables:

```elixir
import Config

config :plc_server, :devices, [
  [id: "line_a", host: "192.168.0.10", rack: 0, slot: 1],
  [id: "line_b", host: "192.168.0.11", rack: 0, slot: 1]
]
```

Each ID starts a separate supervised device process and C Port. A non-empty
`:devices` list takes precedence over `PLC_HOST`; duplicate IDs or invalid
entries prevent application startup.

```elixir
PlcServer.device_status("line_a")
# {:ok, %{device_id: "line_a", port: :running, last_io: :unknown, last_io_at: nil}}
```

`device_status/1` does not contact the PLC. `port` reports the local C Port,
while `last_io` is `:unknown`, `:ok`, or `{:error, reason}` from the most recent
read or write. It is not a live PLC connection check; a real PLC connection is
opened lazily on the first request.

Devices can also be changed while the application is running:

```elixir
PlcServer.add_device(id: "line_c", host: "192.168.0.12", rack: 0, slot: 1)
PlcServer.update_device("line_c", host: "192.168.0.13", rack: 0, slot: 1)
PlcServer.remove_device("line_c")
```

Runtime changes are saved to `plc_devices.term` in the current working directory.
Set `PLC_DEVICE_CONFIG_PATH` to an absolute writable path for deployments, or
configure `:device_config_path` in `config/config.exs`. On restart, a saved
snapshot takes precedence over `:devices` and `PLC_HOST`, including when the
saved list is empty. Remove the snapshot file to return to startup configuration.
An unreadable or invalid snapshot prevents startup rather than silently using
different devices. Configuration writes replace the file atomically; if saving
fails, the requested change is rejected.

Removing a device leaves existing block
subscriptions active; they report `:unknown_plc` on the next poll and recover
when the same ID is added again. An update keeps the ID, briefly replaces the
device process, and restores the old configuration if the new process cannot
start. It does not verify that the new PLC is physically reachable.
Requests still waiting when a device is removed or updated return
`{:error, :device_removed}` or `{:error, :device_reconfigured}`.

```elixir
PlcServer.read("plc1", 1, 0, 16)
PlcServer.subscribe("plc1", 1, 0, 16, 500)
flush()
# {:plc_event, %PlcService.Event{type: :data, value: <<...>>}}
```

The subscription belongs to the calling process and ends when that process exits.
Updates are delivered as `{:plc_event, %PlcService.Event{}}`; data events use
`type: :data`, and read failures use `type: :error` with `quality: :bad`.

## MQTT publishing

Run an external MQTT broker such as Mosquitto, then configure the PLC block streams
to publish in `config/config.exs`:

```elixir
config :plc_server, :mqtt,
  host: "127.0.0.1",
  port: 1883,
  client_id: "plc-server-1",
  qos: 0,
  retain: true,
  subscriptions: [
    [plc: "plc1", db: 1, offset: 0, length: 16, interval_ms: 500]
  ]
```

The adapter is disabled when `:mqtt` is unset. It subscribes to each configured
block and publishes JSON to that block's `plc/{device_id}/db/{db}/{offset}/{length}/{interval_ms}`
topic. Data bytes are Base64 encoded; errors carry a printable reason. The broker
retains the latest state by default. The client reconnects automatically and
publishes its latest event for each stream after reconnecting. Optional settings
include `username`, `password`, `retry_ms` and `connect_timeout_ms`.
MQTT publishing is one way only; it does not accept PLC write commands.

## HTTP API

External processes can read, write, query status, and manage PLC devices through
an optional HTTP JSON API. Enable it in `config/config.exs`:

```elixir
config :plc_server, :http, host: "127.0.0.1", port: 4000
```

It listens on localhost by default when configured. Binding to any other address
requires a bearer token, for example `token: "your-secret"`; clients then send
`Authorization: Bearer your-secret`. Keep the token outside source control in
deployments. The API is disabled when `:http` is unset.

```sh
curl -X POST http://127.0.0.1:4000/devices/plc1/read \
  -H 'Content-Type: application/json' \
  -d '{"db":1,"offset":0,"length":2}'
```

Raw bytes use Base64 in JSON. MQTT remains the event channel; HTTP handles
individual requests. See [docs/http-api.md](docs/http-api.md) for all routes and
request formats.

## Elixir reads, writes, and recovery

Reads return `{:ok, bytes}` or `{:error, reason}`. Snap7 errors appear as
`{:error, {:snap7, code}}`; `-1000` means the shared library could not be loaded.
If the C Port exits, waiting requests return `{:error, {:port_exit, reason}}` and the
device process restarts under its supervisor.
After three consecutive read or write timeouts, the device also restarts its Port.
The timed-out request returns `{:error, :timeout}`; other waiting requests receive
`{:error, {:port_timeout, 3}}`. A successful read or write clears the count.
Writes are not retried because their outcome may be unknown after a timeout.
Read errors are sent as `{:plc_event, %PlcService.Event{type: :error}}`.

The C Port supports `--mock` as its host for local protocol tests. It returns
deterministic bytes and does not contact a PLC.

Point reads use S7 big-endian decoding:

```elixir
PlcServer.read_point("plc1", %{db: 1, offset: 0, bit: 0, type: :bool})
PlcServer.read_point("plc1", %{db: 1, offset: 2, type: :int16})
PlcServer.read_point("plc1", %{db: 1, offset: 4, type: :float32})
PlcServer.read_point("plc1", %{db: 1, offset: 8, type: :string, size: 16})
```

Writes are serialized by the PLC device process:

```elixir
PlcServer.write_point("plc1", %{db: 1, offset: 2, type: :uint16}, 42)
PlcServer.write_points("plc1", [
  {%{db: 1, offset: 2, type: :uint16}, 42},
  {%{db: 1, offset: 4, type: :float32}, 36.5}
])
```

Bool point writes are serialized as one read-modify-write operation within the
device process, so concurrent callers of this service cannot overwrite each
other's bits. The same guarantee does not cover PLC logic or other clients
writing that byte.

For local testing, `--mock` keeps DB writes in memory until the Port exits. Unwritten
bytes retain their deterministic values. Faults can be injected through the device:

```elixir
PlcService.Device.mock_control("mock", :disconnect)
PlcService.Device.mock_control("mock", :reconnect)
PlcService.Device.mock_control("mock", :timeout_next)
```

The next read or write after `:timeout_next` receives no reply and returns
`{:error, :timeout}` after the device timeout. A disconnected mock returns
`{:error, {:snap7, -1002}}` for reads and writes. Mock controls are unavailable
for real PLC devices.

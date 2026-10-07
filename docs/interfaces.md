# PLC Server 接口总览

本页列出 Elixir API、点位格式、MQTT 事件、配置接口和内部 C Port 协议。外部进程的 HTTP 路由、请求与状态码见 [http-api.md](http-api.md)；内部订阅事件规则见 [plc-events.md](plc-events.md)。

## Elixir API

`plc` 或 `device_id` 是配置时指定的非空字符串。除订阅函数外，下表为同步调用；读写失败返回 `{:error, reason}`。调用方应识别具体错误，而非仅依赖 `inspect(reason)` 文本。

| 函数 | 输入 | 成功结果 | 说明 |
| --- | --- | --- | --- |
| `PlcServer.read/4` | `(plc, db, offset, length)` | `{:ok, binary}` | DB 原始字节。 |
| `PlcServer.read_point/2` | `(plc, point)` | `{:ok, value}` | 读取并按点位类型解码。 |
| `PlcServer.read_points/2` | `(plc, [point])` | `{:ok, [value]}` | 同一 DB 内连续或重叠范围合并读取；结果按输入顺序。 |
| `PlcServer.write_point/3` | `(plc, point, value)` | `{:ok, :written}` | Bool 使用设备进程内的位读改写。 |
| `PlcServer.write_points/2` | `(plc, [{point, value}])` | `{:ok, [:written, ...]}` | 顺序执行；中途失败不回滚已写点位。 |
| `PlcServer.device_status/1` | `(plc)` | `{:ok, status}` | 本地 Port 与最近 I/O，不主动连接 PLC。 |
| `PlcServer.add_device/1` | 设备 keyword 或 map | `{:ok, pid}` | 添加设备并保存配置。 |
| `PlcServer.update_device/2` | `(plc, 完整设备配置)` | `{:ok, pid}` | 替换配置，ID 保持不变。 |
| `PlcServer.remove_device/1` | `(plc)` | `:ok` | 删除设备并保存配置。 |
| `PlcServer.subscribe/5` | `(plc, db, offset, length, interval_ms)` | `{:ok, block_pid}` | 向调用进程发送原始字节事件。 |
| `PlcServer.subscribe_point/3` | `(plc, point, interval_ms)` | `{:ok, block_pid}` | 向调用进程发送解码点位事件。 |
| `PlcService.Device.write/4` | `(plc, db, offset, binary)` | `{:ok, :written}` | 底层原始字节写入；HTTP `/write` 使用此接口。 |

原始 DB 参数：`db` 为 `0..65535`，`offset` 为 `0..2147483647`，`length` 为 `1..65536`，且 `offset + length <= 2147483648`。写入数据必须是 1–65536 字节的 binary。订阅间隔最小 50 毫秒。`device_status/1` 返回 `%{device_id: id, port: :running | :down, last_io: :unknown | :ok | {:error, reason}, last_io_at: nil | integer}`；时间为 Unix 毫秒。

## 点位格式

Elixir 点位使用 atom 键和 atom 类型，例如 `%{db: 1, offset: 0, type: :uint16}`；HTTP 使用同名字符串键和类型字符串。点位读取和写入遵循 S7 大端序。

| `type` | 长度 | 附加字段 | 值 |
| --- | --- | --- | --- |
| `bool` | 1 字节 | `bit: 0..7` | `true` 或 `false`。 |
| `int16` / `uint16` | 2 字节 | 无 | 有符号/无符号整数。 |
| `int32` / `uint32` | 4 字节 | 无 | 有符号/无符号整数。 |
| `float32` | 4 字节 | 无 | IEEE 754 32 位浮点；写入需为 Elixir float。 |
| `string` | `size` 字节 | `size: 1..65536` | 写入不足时补零；读取到首个零字节结束。 |
| `bytes` | `size` 字节 | `size: 1..65536` | 写入长度必须等于 `size`；HTTP 值使用 Base64。 |

`offset + 点位长度` 不能超过 `2147483648`。整数写入还必须处于其类型的取值范围。Bool 位写只对经过同一设备进程的请求维持读改写串行化，其他 PLC 客户端及 PLC 逻辑不在此保证内。

测试环境可调用 `PlcService.Device.mock_control(plc, :disconnect | :reconnect | :timeout_next)` 注入故障；非 `--mock` 设备返回 `{:error, :not_mock}`。

## 内部订阅消息

`PlcServer.subscribe/5` 和 `subscribe_point/3` 将 `{:plc_event, %PlcService.Event{}}` 发送至**调用进程**邮箱。原始订阅的 `value` 为 binary；点位订阅的 `value` 为解码值。新订阅者可收到最近事件快照。订阅者进程退出后自动移除；同一流没有订阅者时 Block 停止。事件字段、顺序、错误与恢复规则见 [plc-events.md](plc-events.md)。

## MQTT 发布接口

配置的原始 DB 块事件发布到 `plc/{encoded_device_id}/db/{db}/{offset}/{length}/{interval_ms}`。设备 ID 中不属于 URI unreserved 的字符会百分号编码。消息载荷为 UTF-8 JSON，例如：

```json
{
  "type": "data",
  "topic": "plc/plc1/db/1/0/2/500",
  "device_id": "plc1",
  "address": {"db": 1, "offset": 0, "length": 2},
  "value": "AAE=",
  "value_encoding": "base64",
  "sequence": 1,
  "timestamp": 1782000000000,
  "quality": "good",
  "reason": "initial",
  "stream_id": "example-stream"
}
```

错误事件的 `type` 为 `error`，`quality` 为 `bad`，`reason` 为 `read_failed`，`value` 为 `inspect(error_reason)` 文本，`value_encoding` 为 `inspect`。`sequence` 在同一 `stream_id` 内递增；重放或重发可带相同编号。默认 QoS 0、retained 开启；也可配置 QoS 1。Broker 断线期间只缓存在内存中每条 topic 的最新事件，重连后重发。MQTT 没有命令订阅、历史查询或应用级确认。

## 配置接口

```elixir
config :plc_server, :devices, [
  [id: "plc1", host: "192.168.0.10", rack: 0, slot: 1, timeout: 5_000]
]

config :plc_server, :mqtt,
  host: "127.0.0.1",
  port: 1883,
  client_id: "plc-server-1",
  qos: 0,
  retain: true,
  subscriptions: [[plc: "plc1", db: 1, offset: 0, length: 2, interval_ms: 500]]

config :plc_server, :http, host: "127.0.0.1", port: 4000
```

设备必填 `id`、`host`、`rack`、`slot`；`rack` 与 `slot` 各为 `0..255`。可选 `timeout`（毫秒，默认 5000）、`max_consecutive_timeouts`（默认 3）和 `port_path`。设备 ID 必须唯一。运行时设备操作会写入 `:device_config_path` 或 `PLC_DEVICE_CONFIG_PATH` 指定的快照文件，默认 `plc_devices.term`。快照优先于静态 `:devices`；空快照同样有效。没有快照且未配置非空 `:devices` 时，兼容 `PLC_HOST`、`PLC_ID`、`PLC_RACK`、`PLC_SLOT`。

MQTT 必填非空 `host` 和至少一条 `subscriptions`；订阅项需要 `plc`、`db`、`offset`、`length`、`interval_ms`。可选 `port`（1883）、`client_id`（随机生成）、`username`、`password`、`qos`（0 或 1）、`retain`（true）、`retry_ms`（5000）和 `connect_timeout_ms`（3000，用于发布调用等待）。当前 MQTT 订阅清单在启动时读取，不支持运行时增删。

HTTP 可选 `host`（默认 `127.0.0.1`，须是数字 IP）、`port`（默认 4000）和 `token`。监听地址不是 `127.0.0.1` 或 `::1` 时必须配置非空 `token`；Bearer 令牌适用于全部路由，包括 `/health`。HTTP 和 MQTT 未配置时均不启动。

## 内部 C Port 协议

这是 BEAM 与其子进程之间的私有协议，不是外部接入接口。`Port.open` 使用 `{:packet, 4}`：每个方向的帧前缀为 **4 字节无符号大端帧长**，帧长不包含前缀本身。

| 帧 | 内容（全部大端） |
| --- | --- |
| 请求 | `request_id:u32`、`opcode:u8`、`db:u16`、`offset:u32`、`size:u32`、可选 `data:size bytes`。 |
| 成功响应 | `request_id:u32`、`status:u8 = 0`、读取时的 `data:size bytes`；写入或 mock 控制时无 payload。 |
| 失败响应 | `request_id:u32`、`status:u8 = 1`、`error_code:i32`。 |

`opcode=1` 读取，`opcode=2` 写入，`opcode=3` 仅 mock 模式控制断线、重连和下一次请求超时。控制帧用 `db=1` 表示断线、`db=2` 表示重连、`db=3` 表示下一次请求超时；Elixir 端设置 `offset=0`、`size=1`。写请求必须带 `size` 字节数据；请求的固定内容长为 15 字节。C Port 校验帧长和参数，非法帧使子进程退出。Snap7 错误码直接返回；内置负值包括 `-1000`（库不可用）、`-1001`（创建客户端失败）。Mock 使用 `-1002` 表示断线，`-1003` 表示控制命令无效，`-1004` 表示分配模拟写入内存失败。

# PLC 订阅事件契约（v1）

本文定义 `plc_server` 的 DB 订阅语义，供应用内 Elixir 进程以及 MQTT 适配器使用。内部可按 `{device_id, db, offset, length, interval_ms}` 订阅原始字节，也可用 `subscribe_point/3` 订阅解码点位；当前 MQTT 适配器只发布配置的原始字节流。

> 本文描述内部订阅及 MQTT 发布行为；WebSocket 适配器尚未实现。

## 事件模型

内部消息统一为 `{:plc_event, %PlcService.Event{}}`。一条块订阅流由完整的 `{device_id, db, offset, length, interval_ms}` 标识。不同轮询周期是不同流，可能分别读取同一段 DB。

| 字段 | 约定 |
| --- | --- |
| `type` | `:data` 或 `:error`。恢复成功仍是 `:data`。 |
| `topic` | `plc/{device_id}/db/{db}/{offset}/{length}/{interval_ms}`，标识一条块订阅流。 |
| `device_id` | 配置中的 PLC ID。 |
| `address` | `%{db: db, offset: offset, length: length}`；数据和错误事件均需携带。 |
| `value` | 原始块数据事件是 `binary`，点位数据事件是解码值；错误事件是标准化错误原因。 |
| `sequence` | 同一流的一次生命周期内，从 1 开始，对每条**新发布**的事件递增 1；没有事件就不递增。 |
| `timestamp` | 生成事件时的 Unix 毫秒时间戳；重放已有事件时保持原值。它不是 PLC 内部采样时间。 |
| `quality` | 数据事件为 `:good`，错误事件为 `:bad`。 |
| `metadata.reason` | 数据事件为 `:initial`、`:change` 或 `:recovered`；错误事件为 `:read_failed`。 |
| `metadata.stream_id` | 每次 Block 进程启动生成的新标识；与 `sequence` 一起区分进程重启前后的事件。 |

`metadata` 是 map。`topic` 中的设备 ID 使用 URI 转义，避免 ID 中的 `/` 破坏层级。

## 发布规则

| 情况 | 行为 |
| --- | --- |
| 首次读取成功 | 向当前所有订阅者发布 `:data`，`metadata.reason: :initial`，即使字节全为零。 |
| 随后读取成功且字节变化 | 发布 `:data`，`metadata.reason: :change`，包含**完整订阅范围**的字节，不只包含变化的部分。 |
| 随后读取成功且字节未变化 | 不发布事件。 |
| 首次读取失败，或从成功转为失败 | 发布一次 `:error`，`metadata.reason: :read_failed`。 |
| 连续读取失败 | 保留最近错误状态，不在每次轮询重复发布同类错误；若错误原因变化，再发布一条 `:error`。 |
| 失败后首次读取成功 | 发布 `:data`，`metadata.reason: :recovered`，即使字节与故障前相同。 |
| C Port 或设备进程重启 | 下次读取结果遵循上述失败/恢复规则；不凭进程重启本身推断 PLC 已断线。 |

`{:error, reason}` 表示本次读取失败，不自动等同于 PLC 物理断线。设备级连接状态和健康事件应单独定义，不由块事件的 `:quality` 代替。轮询间隔从**本次读取完成**后开始计算；它不是严格固定的采样时钟。

## 订阅与重放

- 首个订阅者加入时立即开始读取；首次成功或失败会发出相应事件。
- 后续订阅者加入已有流时，立即向该订阅者重放最近一条事件，包含成功数据或当前错误。重放不触发 PLC 读取，不给其他订阅者发消息，也不增加 `sequence`；`timestamp` 和 `metadata` 保持原样。
- 同一进程重复订阅同一流只保留一份订阅，不重复发送事件。
- 订阅进程退出后自动移除；没有订阅者时停止流。重新创建的流使用新的 `stream_id`，`sequence` 从 1 重新开始。
- 事件按同一 Block 进程的发布顺序进入每个订阅者邮箱。内部 `send/2` 不提供确认、持久化或跨进程故障后的补发；消费者需要用 `{stream_id, sequence}` 识别重复或缺口，并在需要时重新订阅获取快照。

## 示例

```elixir
{:plc_event,
 %PlcService.Event{
   type: :data,
   topic: "plc/plc1/db/1/0/2/500",
   device_id: "plc1",
   address: %{db: 1, offset: 0, length: 2},
   value: <<0, 1>>,
   sequence: 1,
   timestamp: 1_782_000_000_000,
   quality: :good,
   metadata: %{reason: :initial, stream_id: "example-stream"}
 }}
```

## MQTT 发布

配置方式见 README。适配器将每条已配置原始 DB 流的内部事件发布到同名 MQTT topic，载荷为 JSON，包含 `type`、`topic`、`device_id`、`address`、`value`、`value_encoding`、`sequence`、`timestamp`、`quality`、`reason` 和 `stream_id`。数据事件的 `value` 是 Base64 字符串，`value_encoding` 为 `base64`；错误事件的 `value` 是 Elixir 可打印原因字符串，`value_encoding` 为 `inspect`。

默认使用 QoS 0 和 retained 消息。Broker 重连后，适配器重新发送每条流最近的事件；期间只保存每条流最新的一条事件，不保存完整历史。MQTT 发布仅用于观察，不接收写命令，也不提供应用级确认或持久化。订阅者可用 `{stream_id, sequence}` 识别重复或缺口。

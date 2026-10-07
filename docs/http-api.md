# HTTP JSON 接口

HTTP 适用于外部进程的一次性读写、状态查询和设备管理；连续变化通知使用 [MQTT 事件](interfaces.md)。HTTP 监听默认关闭。配置后默认只监听 `127.0.0.1:4000`：

```elixir
config :plc_server, :http, host: "127.0.0.1", port: 4000
```

`host` 必须是数字 IPv4 或 IPv6 地址。监听地址不是 `127.0.0.1` 或 `::1` 时必须配置非空 `token`；配置令牌后，每个请求（包括 `/health`）都要携带 `Authorization: Bearer <token>`。服务本身没有 HTTPS；跨主机访问时应在前面放 TLS 反向代理。请求体上限为 1 MiB。响应均为 `application/json`；请求体使用 JSON 对象。路径里的 `:id` 是设备 ID，含特殊字符时由客户端进行 URL 编码。

## 路由一览

| 方法 | 路径 | 用途 | 成功状态 |
| --- | --- | --- | --- |
| GET | `/health` | HTTP 服务存活检查，不检查 PLC 或 Broker。 | 200 |
| GET | `/devices` | 列出当前设备连接配置。 | 200 |
| GET | `/devices/:id/status` | 查询本地 Port 与最近 I/O。 | 200 |
| POST | `/devices` | 新增设备并持久化。 | 201 |
| PUT | `/devices/:id` | 用完整配置替换设备并持久化。 | 200 |
| DELETE | `/devices/:id` | 移除设备并持久化。 | 200 |
| POST | `/devices/:id/read` | 读取 DB 原始字节。 | 200 |
| POST | `/devices/:id/write` | 写入 DB 原始字节。 | 200 |
| POST | `/devices/:id/read_point` | 读取并解码单个点位。 | 200 |
| POST | `/devices/:id/write_point` | 编码并写入单个点位。 | 200 |
| POST | `/devices/:id/read_points` | 批量读取点位。 | 200 |
| POST | `/devices/:id/write_points` | 按顺序批量写入点位。 | 200 |

未知路径或方法返回 `404` 和 `{"error":"not_found"}`。接口未启用时没有 HTTP 监听。

## 健康与设备

`GET /health` 返回 `{"status":"ok"}`。它只能证明 HTTP 进程能够响应，不能证明 PLC 在线。`GET /devices` 返回 `{"devices":[{"id":"plc1","host":"192.168.0.10","rack":0,"slot":1},...]}`；每项还可能包含 `timeout`、`max_consecutive_timeouts` 和 `port_path`。`GET /devices/plc1/status` 的示例：

```json
{"device_id":"plc1","port":"running","last_io":"ok","last_io_at":1782000000000}
```

`port` 为 `running` 或 `down`；`last_io` 为 `unknown`、`ok` 或 Elixir 错误项的可打印文本，例如 `"{:error, {:snap7, -1002}}"`；`last_io_at` 在没有 I/O 时为 `null`，否则为 Unix 毫秒。查询**不主动连接 PLC**。

新增设备的请求体是完整配置：

```json
{"id":"plc1","host":"192.168.0.10","rack":0,"slot":1,"timeout":5000}
```

`POST /devices` 返回 `{"device_id":"plc1"}`。`PUT /devices/plc1` 使用相同字段，但 ID 由 URL 决定，请求体仍需提供 `host`、`rack` 和 `slot`；它是完整替换，不是部分更新。`DELETE /devices/plc1` 返回同样的 `device_id`。设备 ID 必须唯一，`rack` 和 `slot` 在 `0..255`；运行时变更写入快照文件，持久化失败会拒绝变更。设备进程启动成功不表示真实 PLC 已连接。

## 原始 DB 读写

`POST /devices/plc1/read` 的请求与响应：

```json
{"db":1,"offset":0,"length":2}
```

```json
{"value":"AAE=","value_encoding":"base64"}
```

`POST /devices/plc1/write` 的请求为 `{"db":1,"offset":0,"value":"AAE="}`，成功返回 `{"result":"written"}`。写入的 `value` 必须是有效 Base64，解码后长度为 1–65536 字节。`db` 为 `0..65535`，`offset` 为 `0..2147483647`；读长度为 1–65536，且结束位置不得超过 `2147483648`。HTTP JSON 的原始字节始终使用 Base64，不直接放二进制。

## 点位读写

点位请求包含 `db`、`offset` 和 `type`。支持 `bool`、`int16`、`uint16`、`int32`、`uint32`、`float32`、`string`、`bytes`；`bool` 还需 `bit`（0–7），`string` 和 `bytes` 还需 `size`（1–65536）。有符号/无符号整数遵循各自位宽；`float32` 写入需为 JSON 小数；`string` 写入不足时在 PLC 内补零，读取到首个零字节为止；`bytes` 的 `value` 为 Base64 且解码长度须等于 `size`。

例如读取 Bool：

```sh
curl -X POST http://127.0.0.1:4000/devices/plc1/read_point \
  -H 'Content-Type: application/json' \
  -d '{"db":1,"offset":0,"type":"bool","bit":0}'
```

响应为 `{"value":true}` 或 `{"value":false}`。写入时改用 `/write_point` 并加入 `"value":true`，成功返回 `{"result":"written"}`。`bytes` 点位读取返回 `{"value":"AAE=","value_encoding":"base64"}`；其他类型的响应只有 `value`。

批量读取使用 `{"points":[{"db":1,"offset":0,"type":"uint16"},{"db":1,"offset":2,"type":"bool","bit":0}]}`，响应形如 `{"values":[{"value":258},{"value":false}]}`，顺序与输入一致。同一 DB 内连续或重叠范围可能合并为一次底层读取。批量写入的每个点位对象还需 `value`，响应如 `{"results":["written","written"]}`；写入逐项执行，中途失败不会撤销之前已成功的写入。

## 错误与调用语义

错误响应统一形如 `{"error":"unknown_plc"}`。单一 atom 原因使用名称，复合原因使用 Elixir `inspect` 文本；复合文本仅供诊断，不保证可作为稳定机器错误码。当前状态码映射如下：

| 状态 | 场景 |
| --- | --- |
| 400 | 无效 JSON、参数、点位、值或设备配置。 |
| 401 | 配置了令牌但请求未提供正确 Bearer 值。 |
| 404 | 路由不存在或设备 ID 不存在。 |
| 409 | 设备已存在，或目标设备不由运行时设备监督器管理。 |
| 413 | 请求体超过 1 MiB。 |
| 502 | Snap7 错误或 C Port 异常退出。 |
| 504 | 请求超时或连续超时触发 Port 重启。 |
| 500 | 其他内部错误，包括部分配置文件操作失败。 |

读写请求采用同步响应。写请求超时后，其是否已到达 PLC 可能未知；服务不会自动重试写入，调用方也应先确认现场状态再决定是否重试。Bool 的读改写仅对通过本服务的请求串行化，不是 PLC 侧事务。设备更新或移除可能使等待中的请求分别返回 `device_reconfigured` 或 `device_removed`。

defmodule PlcService.Event do
  @moduledoc "PLC 订阅事件结构；字段与发布规则见 docs/plc-events.md。"

  @enforce_keys [:type, :topic, :device_id, :sequence, :timestamp]
  defstruct [
    :type,
    :topic,
    :device_id,
    :address,
    :value,
    :sequence,
    :timestamp,
    :quality,
    :metadata
  ]

  @doc "创建带当前系统时间的 PLC 事件。"
  def new(attrs) when is_map(attrs) do
    struct!(__MODULE__, Map.put_new(attrs, :timestamp, System.system_time(:millisecond)))
  end
end

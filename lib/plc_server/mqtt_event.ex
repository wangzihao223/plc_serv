defmodule PlcServer.MqttEvent do
  @moduledoc "将 PLC 事件编码为 MQTT 消费者可读取的 JSON。"

  @doc "数据值使用 Base64，错误原因使用字符串。"
  def encode(%PlcService.Event{} = event) do
    {value, encoding} =
      if event.type == :data do
        {Base.encode64(event.value), "base64"}
      else
        {inspect(event.value), "inspect"}
      end

    Jason.encode!(%{
      type: event.type,
      topic: event.topic,
      device_id: event.device_id,
      address: event.address,
      value: value,
      value_encoding: encoding,
      sequence: event.sequence,
      timestamp: event.timestamp,
      quality: event.quality,
      reason: event.metadata.reason,
      stream_id: event.metadata.stream_id
    })
  end
end

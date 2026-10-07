defmodule PlcServer.MqttHandler do
  @moduledoc "Tortoise311 连接使用的空消息处理器；PLC Server 只发布消息。"
  use Tortoise311.Handler
end

defmodule PlcServer.MqttAdapterTest do
  use ExUnit.Case, async: false
  import Bitwise

  test "publishes a retained JSON event to a broker" do
    start_supervised!({PlcService.Device, id: "mqtt_mock", host: "--mock", rack: 0, slot: 1})
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listener)
    parent = self()

    broker =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 2_000)
        {0x10, _connect} = packet(socket)
        :ok = :gen_tcp.send(socket, <<0x20, 2, 0, 0>>)
        {flags, body} = packet(socket)
        send(parent, {:published, flags, body})
        :gen_tcp.close(socket)
      end)

    client_id = "plc-test-#{System.unique_integer([:positive])}"

    config = %{
      host: "127.0.0.1",
      port: port,
      client_id: client_id,
      username: nil,
      password: nil,
      qos: 0,
      retain: true,
      retry_ms: 100,
      connect_timeout_ms: 1_000,
      streams: [{"mqtt_mock", 1, 0, 1, 60_000}]
    }

    start_supervised!({PlcServer.MqttAdapter, config})

    assert_receive {:published, 0x31, <<topic_length::16, rest::binary>>}, 2_000
    <<topic::binary-size(^topic_length), payload::binary>> = rest
    assert topic == "plc/mqtt_mock/db/1/0/1/60000"

    assert %{"value" => "AQ==", "value_encoding" => "base64", "sequence" => 1} =
             Jason.decode!(payload)

    Task.await(broker)
    :gen_tcp.close(listener)
  end

  defp packet(socket) do
    {:ok, <<flags>>} = :gen_tcp.recv(socket, 1, 2_000)
    length = remaining_length(socket, 0, 1)
    {:ok, body} = :gen_tcp.recv(socket, length, 2_000)
    {flags, body}
  end

  defp remaining_length(socket, value, multiplier) do
    {:ok, <<byte>>} = :gen_tcp.recv(socket, 1, 2_000)
    next = value + (byte &&& 127) * multiplier
    if byte < 128, do: next, else: remaining_length(socket, next, multiplier * 128)
  end
end

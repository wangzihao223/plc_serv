defmodule PlcServerTest do
  use ExUnit.Case, async: false

  setup do
    start_supervised!(
      {PlcService.Device, id: "mock", host: "--mock", rack: 0, slot: 1, timeout: 250}
    )

    :ok
  end

  test "reads DB bytes through the C Port" do
    assert PlcServer.read("mock", 3, 2, 4) == {:ok, <<5, 6, 7, 8>>}
    assert PlcServer.read("mock", 3, -1, 4) == {:error, :invalid_read}
    assert PlcServer.read("mock", 3, 2_147_483_647, 2) == {:error, :invalid_read}
    assert PlcServer.read("missing", 3, 2, 4) == {:error, :unknown_plc}
  end

  test "batch reads contiguous points with one logical result per input" do
    assert {:ok, [true, 1286, 117_967_114]} =
             PlcServer.read_points("mock", [
               %{db: 3, offset: 2, bit: 0, type: :bool},
               %{db: 3, offset: 2, type: :uint16},
               %{db: 3, offset: 4, type: :int32}
             ])
  end

  test "writes persist across overlapping reads and preserve other bits" do
    assert PlcServer.write_point("mock", %{db: 3, offset: 2, type: :uint16}, 0x1234) ==
             {:ok, :written}

    assert PlcServer.read("mock", 3, 1, 3) == {:ok, <<4, 0x12, 0x34>>}

    assert PlcServer.write_point("mock", %{db: 3, offset: 2, bit: 0, type: :bool}, true) ==
             {:ok, :written}

    assert PlcServer.read("mock", 3, 2, 2) == {:ok, <<0x13, 0x34>>}

    assert PlcServer.write_point("mock", %{db: 3, offset: 2, bit: 0, type: :bool}, false) ==
             {:ok, :written}

    assert PlcServer.read("mock", 3, 2, 2) == {:ok, <<0x12, 0x34>>}
  end

  test "concurrent bit writes preserve every bit in one byte" do
    for _ <- 1..20 do
      assert PlcService.Device.write("mock", 0, 0, <<0>>) == {:ok, :written}

      writers =
        Enum.map(0..7, fn bit ->
          Task.async(fn ->
            receive do
              :write ->
                PlcServer.write_point("mock", %{db: 0, offset: 0, bit: bit, type: :bool}, true)
            end
          end)
        end)

      Enum.each(writers, &send(&1.pid, :write))
      Enum.each(writers, fn writer -> assert Task.await(writer) == {:ok, :written} end)
      assert PlcServer.read("mock", 0, 0, 1) == {:ok, <<255>>}
    end
  end

  test "failed bit reads release the device for later requests" do
    config = %{db: 0, offset: 0, bit: 0, type: :bool}
    assert :ok = PlcService.Device.mock_control("mock", :timeout_next)
    assert PlcServer.write_point("mock", config, true) == {:error, :timeout}
    assert PlcServer.read("mock", 0, 0, 1) == {:ok, <<0>>}

    assert :ok = PlcService.Device.mock_control("mock", :disconnect)
    assert PlcServer.write_point("mock", config, true) == {:error, {:snap7, -1002}}
    assert :ok = PlcService.Device.mock_control("mock", :reconnect)
    assert PlcServer.write_point("mock", config, true) == {:ok, :written}
  end

  test "port exit replies to a pending request and restarts the device" do
    [{device, _}] = Registry.lookup(PlcServer.Registry, {:device, "mock"})
    port = :sys.get_state(device).port
    assert :ok = PlcService.Device.mock_control("mock", :timeout_next)
    request = Task.async(fn -> PlcServer.read("mock", 3, 2, 1) end)
    await_until(fn -> map_size(:sys.get_state(device).pending) == 1 end)

    :erlang.exit(port, :kill)

    assert {:error, {:port_exit, _}} = Task.await(request)

    await_until(fn ->
      case Registry.lookup(PlcServer.Registry, {:device, "mock"}) do
        [{new_device, _}] -> new_device != device
        [] -> false
      end
    end)

    assert PlcServer.read("mock", 3, 2, 1) == {:ok, <<5>>}
  end

  test "port exit replies to requests queued behind a bit write" do
    [{device, _}] = Registry.lookup(PlcServer.Registry, {:device, "mock"})
    port = :sys.get_state(device).port
    assert :ok = PlcService.Device.mock_control("mock", :timeout_next)

    bit_write =
      Task.async(fn ->
        PlcServer.write_point("mock", %{db: 0, offset: 0, bit: 0, type: :bool}, true)
      end)

    await_until(fn -> :sys.get_state(device).bit_write end)
    queued_read = Task.async(fn -> PlcServer.read("mock", 3, 2, 1) end)
    await_until(fn -> :queue.len(:sys.get_state(device).queued) == 1 end)

    :erlang.exit(port, :kill)

    assert {:error, {:port_exit, _}} = Task.await(bit_write)
    assert {:error, {:port_exit, _}} = Task.await(queued_read)
  end

  test "subscription recovers after its pending read loses the port" do
    assert {:ok, block} = PlcServer.subscribe("mock", 3, 2, 1, 200)
    assert_receive {:plc_event, %PlcService.Event{type: :data, sequence: 1}}, 1_000
    [{device, _}] = Registry.lookup(PlcServer.Registry, {:device, "mock"})
    port = :sys.get_state(device).port
    assert :ok = PlcService.Device.mock_control("mock", :timeout_next)
    send(block, :poll)
    await_until(fn -> map_size(:sys.get_state(device).pending) == 1 end)

    :erlang.exit(port, :kill)

    assert_receive {:plc_event,
                    %PlcService.Event{
                      type: :error,
                      value: {:port_exit, _},
                      sequence: 2,
                      metadata: %{reason: :read_failed}
                    }},
                   1_000

    await_until(fn ->
      case Registry.lookup(PlcServer.Registry, {:device, "mock"}) do
        [{new_device, _}] -> new_device != device
        [] -> false
      end
    end)

    assert Process.alive?(block)

    assert_receive {:plc_event,
                    %PlcService.Event{
                      type: :data,
                      value: <<5>>,
                      sequence: 3,
                      metadata: %{reason: :recovered}
                    }},
                   1_000
  end

  test "consecutive timeouts restart the device and successful reads reset the count" do
    start_supervised!(
      Supervisor.child_spec(
        {PlcService.Device,
         id: "timeout",
         host: "--mock",
         rack: 0,
         slot: 1,
         timeout: 150,
         max_consecutive_timeouts: 2},
        id: :timeout_device
      )
    )

    [{device, _}] = Registry.lookup(PlcServer.Registry, {:device, "timeout"})
    assert :ok = PlcService.Device.mock_control("timeout", :timeout_next)
    assert PlcServer.read("timeout", 3, 2, 1) == {:error, :timeout}

    assert PlcServer.read("timeout", 3, 2, 1) == {:ok, <<5>>}

    assert :ok = PlcService.Device.mock_control("timeout", :timeout_next)
    assert PlcServer.read("timeout", 3, 2, 1) == {:error, :timeout}
    assert Process.alive?(device)

    assert :ok = PlcService.Device.mock_control("timeout", :timeout_next)
    assert PlcServer.read("timeout", 3, 2, 1) == {:error, :timeout}

    await_until(fn ->
      case Registry.lookup(PlcServer.Registry, {:device, "timeout"}) do
        [{new_device, _}] -> new_device != device
        [] -> false
      end
    end)

    assert PlcServer.read("timeout", 3, 2, 1) == {:ok, <<5>>}
  end

  test "subscription automatically recovers after timeout restarts the port" do
    start_supervised!(
      Supervisor.child_spec(
        {PlcService.Device,
         id: "timeout_sub",
         host: "--mock",
         rack: 0,
         slot: 1,
         timeout: 150,
         max_consecutive_timeouts: 1},
        id: :timeout_sub_device
      )
    )

    assert {:ok, block} = PlcServer.subscribe("timeout_sub", 3, 2, 1, 200)
    assert_receive {:plc_event, %PlcService.Event{type: :data, sequence: 1}}, 1_000
    assert :ok = PlcService.Device.mock_control("timeout_sub", :timeout_next)
    send(block, :poll)

    assert_receive {:plc_event, %PlcService.Event{type: :error, value: :timeout, sequence: 2}},
                   1_000

    assert Process.alive?(block)

    assert_receive {:plc_event,
                    %PlcService.Event{
                      type: :data,
                      value: <<5>>,
                      sequence: 3,
                      metadata: %{reason: :recovered}
                    }},
                   1_000
  end

  test "batch writes stop at the first invalid value" do
    assert PlcServer.write_points("mock", [
             {%{db: 3, offset: 2, type: :uint16}, 42},
             {%{db: 3, offset: 4, type: :uint16}, -1},
             {%{db: 3, offset: 6, type: :uint16}, 99}
           ]) == {:error, :invalid_value}

    assert PlcServer.read("mock", 3, 2, 6) == {:ok, <<0, 42, 7, 8, 9, 10>>}
  end

  test "mock disconnect, reconnect and timeout affect real requests" do
    assert :ok = PlcService.Device.mock_control("mock", :disconnect)
    assert PlcServer.read("mock", 3, 2, 1) == {:error, {:snap7, -1002}}

    assert PlcServer.write_point("mock", %{db: 3, offset: 2, type: :uint16}, 42) ==
             {:error, {:snap7, -1002}}

    assert :ok = PlcService.Device.mock_control("mock", :reconnect)
    assert :ok = PlcService.Device.mock_control("mock", :timeout_next)
    assert PlcServer.read("mock", 3, 2, 1) == {:error, :timeout}
    assert PlcServer.read("mock", 3, 2, 1) == {:ok, <<5>>}
  end

  test "subscription publishes changed data after a mock write" do
    assert {:ok, _block} = PlcServer.subscribe("mock", 3, 2, 2, 50)
    assert_receive {:plc_event, %PlcService.Event{metadata: %{reason: :initial}}}, 1_000

    assert PlcServer.write_point("mock", %{db: 3, offset: 2, type: :uint16}, 42) ==
             {:ok, :written}

    assert_receive {:plc_event,
                    %PlcService.Event{
                      value: <<0, 42>>,
                      sequence: 2,
                      metadata: %{reason: :change}
                    }},
                   1_000
  end

  test "subscribes with decoded point values" do
    config = %{db: 3, offset: 2, type: :uint16}
    assert {:ok, _block} = PlcServer.subscribe_point("mock", config, 50)
    assert_receive {:plc_event, %PlcService.Event{type: :data, value: 1286}}, 1_000
  end

  test "shares block polling and sends only changed snapshots" do
    assert {:ok, block} = PlcServer.subscribe("mock", 3, 2, 4, 50)
    assert {:ok, ^block} = PlcServer.subscribe("mock", 3, 2, 4, 50)

    assert_receive {:plc_event,
                    %PlcService.Event{
                      type: :data,
                      topic: "plc/mock/db/3/2/4/50",
                      address: %{db: 3, offset: 2, length: 4},
                      value: <<5, 6, 7, 8>>,
                      sequence: 1,
                      quality: :good,
                      metadata: %{reason: :initial, stream_id: stream_id}
                    }},
                   1_000

    assert is_binary(stream_id)
    refute_receive {:plc_event, _}, 150
  end

  test "replays the latest event only to a new subscriber" do
    assert {:ok, block} = PlcServer.subscribe("mock", 3, 2, 4, 50)
    assert_receive {:plc_event, event}, 1_000
    parent = self()

    spawn(fn ->
      send(parent, {:subscription, PlcServer.Block.subscribe(block)})

      receive do
        {:plc_event, replayed} -> send(parent, {:replayed, replayed})
      end
    end)

    assert_receive {:subscription, {:ok, ^block}}, 1_000
    assert_receive {:replayed, ^event}, 1_000
    refute_receive {:plc_event, _}, 150
  end

  test "publishes one error per reason and recovers with unchanged bytes" do
    assert {:ok, block} = PlcServer.subscribe("mock", 3, 2, 4, 60_000)
    assert_receive {:plc_event, initial}, 1_000
    send(block, {:poll_result, {:error, :timeout}})

    assert_receive {:plc_event,
                    %PlcService.Event{
                      type: :error,
                      topic: "plc/mock/db/3/2/4/60000",
                      address: %{db: 3, offset: 2, length: 4},
                      value: :timeout,
                      sequence: 2,
                      quality: :bad,
                      metadata: %{reason: :read_failed, stream_id: stream_id}
                    }},
                   1_000

    assert stream_id == initial.metadata.stream_id
    send(block, {:poll_result, {:error, :timeout}})
    refute_receive {:plc_event, _}, 50
    send(block, {:poll_result, {:error, :disconnected}})

    assert_receive {:plc_event,
                    %PlcService.Event{
                      type: :error,
                      value: :disconnected,
                      sequence: 3,
                      metadata: %{reason: :read_failed}
                    }},
                   1_000

    send(block, {:poll_result, {:ok, <<5, 6, 7, 8>>}})

    assert_receive {:plc_event,
                    %PlcService.Event{
                      type: :data,
                      value: <<5, 6, 7, 8>>,
                      sequence: 4,
                      quality: :good,
                      metadata: %{reason: :recovered, stream_id: ^stream_id}
                    }},
                   1_000

    send(block, {:poll_result, {:ok, <<5, 6, 7, 9>>}})

    assert_receive {:plc_event,
                    %PlcService.Event{
                      type: :data,
                      value: <<5, 6, 7, 9>>,
                      sequence: 5,
                      metadata: %{reason: :change}
                    }},
                   1_000
  end

  test "replays an initial error and publishes recovery when the device appears" do
    assert {:ok, block} = PlcServer.subscribe("late", 3, 2, 4, 60_000)

    assert_receive {:plc_event,
                    %PlcService.Event{
                      type: :error,
                      value: :unknown_plc,
                      sequence: 1,
                      metadata: %{reason: :read_failed}
                    } = error_event},
                   1_000

    parent = self()

    spawn(fn ->
      {:ok, ^block} = PlcServer.Block.subscribe(block)

      receive do
        {:plc_event, replayed} -> send(parent, {:replayed, replayed})
      end
    end)

    assert_receive {:replayed, ^error_event}, 1_000

    start_supervised!(
      Supervisor.child_spec(
        {PlcService.Device, id: "late", host: "--mock", rack: 0, slot: 1},
        id: :late_device
      )
    )

    send(block, :poll)

    assert_receive {:plc_event,
                    %PlcService.Event{
                      type: :data,
                      value: <<5, 6, 7, 8>>,
                      sequence: 2,
                      metadata: %{reason: :recovered}
                    }},
                   1_000
  end

  defp await_until(condition, attempts \\ 100)
  defp await_until(condition, 0), do: assert(condition.())

  defp await_until(condition, attempts) do
    if condition.() do
      :ok
    else
      Process.sleep(10)
      await_until(condition, attempts - 1)
    end
  end
end

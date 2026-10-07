defmodule PlcServer.DeviceManagerTest do
  use ExUnit.Case, async: false

  setup do
    previous_path = Application.get_env(:plc_server, :device_config_path, :unset)
    path = Path.join(System.tmp_dir!(), "plc_devices_test_#{System.unique_integer()}.term")
    Application.put_env(:plc_server, :device_config_path, path)

    on_exit(fn ->
      Enum.each(
        ["runtime", "replace", "unchanged", "rollback", "pending_remove", "pending_update"],
        &PlcServer.remove_device/1
      )

      File.rm(path)

      if previous_path == :unset do
        Application.delete_env(:plc_server, :device_config_path)
      else
        Application.put_env(:plc_server, :device_config_path, previous_path)
      end
    end)

    :ok
  end

  test "add and remove a device without losing its subscriptions" do
    assert {:ok, _pid} =
             PlcServer.add_device(id: "runtime", host: "--mock", rack: 0, slot: 1)

    assert PlcServer.add_device(id: "runtime", host: "--mock", rack: 0, slot: 1) ==
             {:error, :already_exists}

    assert {:ok, block} = PlcServer.subscribe("runtime", 3, 2, 1, 50)
    assert_receive {:plc_event, %PlcService.Event{type: :data, sequence: 1}}, 1_000

    assert :ok = PlcServer.remove_device("runtime")
    assert PlcServer.device_status("runtime") == {:error, :unknown_plc}

    assert_receive {:plc_event,
                    %PlcService.Event{type: :error, value: :unknown_plc, sequence: 2}},
                   1_000

    assert Process.alive?(block)

    assert {:ok, _pid} =
             PlcServer.add_device(%{id: "runtime", host: "--mock", rack: 0, slot: 1})

    assert_receive {:plc_event,
                    %PlcService.Event{
                      type: :data,
                      value: <<5>>,
                      sequence: 3,
                      metadata: %{reason: :recovered}
                    }},
                   1_000
  end

  test "update replaces a device and retains its ID" do
    assert {:ok, old_pid} =
             PlcServer.add_device(id: "replace", host: "--mock", rack: 0, slot: 1)

    assert PlcServer.write_point("replace", %{db: 3, offset: 2, type: :uint16}, 42) ==
             {:ok, :written}

    assert {:ok, new_pid} =
             PlcServer.update_device("replace", host: "--mock", rack: 0, slot: 1)

    refute new_pid == old_pid
    assert PlcServer.read("replace", 3, 2, 2) == {:ok, <<5, 6>>}
    assert {:ok, %{device_id: "replace", last_io: :ok}} = PlcServer.device_status("replace")
  end

  test "invalid updates leave the current device running" do
    assert {:ok, pid} =
             PlcServer.add_device(id: "unchanged", host: "--mock", rack: 0, slot: 1)

    assert PlcServer.update_device("unchanged", host: "", rack: 0, slot: 1) ==
             {:error, :invalid_device_config}

    assert Process.alive?(pid)
    assert PlcServer.read("unchanged", 3, 2, 1) == {:ok, <<5>>}
  end

  test "failed replacement restores the previous device" do
    assert {:ok, old_pid} =
             PlcServer.add_device(id: "rollback", host: "--mock", rack: 0, slot: 1)

    missing_port = Path.join(System.tmp_dir!(), "missing_plc_port_#{System.unique_integer()}")

    assert {:error, {:update_failed, _}} =
             PlcServer.update_device("rollback",
               host: "--mock",
               rack: 0,
               slot: 1,
               port_path: missing_port
             )

    [{new_pid, _}] = Registry.lookup(PlcServer.Registry, {:device, "rollback"})
    refute new_pid == old_pid
    assert PlcServer.read("rollback", 3, 2, 1) == {:ok, <<5>>}
    assert {:ok, [saved]} = PlcServer.DeviceConfig.load()
    assert saved[:id] == "rollback"
    refute Keyword.has_key?(saved, :port_path)
  end

  test "device changes persist as a complete startup snapshot" do
    assert {:ok, _} = PlcServer.add_device(id: "runtime", host: "--mock", rack: 0, slot: 1)
    assert {:ok, [saved]} = PlcServer.DeviceConfig.load()
    assert saved[:id] == "runtime"
    assert PlcServer.Application.configured_devices() == {:ok, [saved]}

    assert {:ok, _} = PlcServer.update_device("runtime", host: "--mock", rack: 1, slot: 2)
    assert {:ok, [updated]} = PlcServer.DeviceConfig.load()
    assert updated[:rack] == 1
    assert updated[:slot] == 2
    assert PlcServer.Application.configured_devices() == {:ok, [updated]}

    assert :ok = PlcServer.remove_device("runtime")
    assert PlcServer.DeviceConfig.load() == {:ok, []}
    assert PlcServer.Application.configured_devices() == {:ok, []}
  end

  test "manager restart keeps the saved runtime configuration" do
    assert {:ok, _} = PlcServer.add_device(id: "runtime", host: "--mock", rack: 0, slot: 1)
    manager = Process.whereis(PlcServer.DeviceManager)
    Process.exit(manager, :kill)

    await_until(fn ->
      case Process.whereis(PlcServer.DeviceManager) do
        nil -> false
        new_manager -> new_manager != manager
      end
    end)

    assert PlcServer.remove_device("runtime") == :ok
    assert PlcServer.DeviceConfig.load() == {:ok, []}
  end

  test "a damaged snapshot is reported instead of silently ignored" do
    File.write!(PlcServer.DeviceConfig.path(), "invalid snapshot")
    assert PlcServer.Application.configured_devices() == {:error, :invalid_device_config_file}
  end

  test "a persistence error leaves the runtime configuration unchanged" do
    original_path = PlcServer.DeviceConfig.path()
    directory = Path.join(System.tmp_dir!(), "plc_config_dir_#{System.unique_integer()}")
    File.mkdir_p!(directory)
    Application.put_env(:plc_server, :device_config_path, directory)

    try do
      assert {:error, {:config_write_failed, _}} =
               PlcServer.add_device(id: "runtime", host: "--mock", rack: 0, slot: 1)

      assert PlcServer.device_status("runtime") == {:error, :unknown_plc}
    after
      Application.put_env(:plc_server, :device_config_path, original_path)
      File.rmdir(directory)
    end
  end

  test "removing a device returns an error to pending callers" do
    assert {:ok, device} =
             PlcServer.add_device(id: "pending_remove", host: "--mock", rack: 0, slot: 1)

    assert :ok = PlcService.Device.mock_control("pending_remove", :timeout_next)
    request = Task.async(fn -> PlcServer.read("pending_remove", 3, 2, 1) end)
    await_until(fn -> map_size(:sys.get_state(device).pending) == 1 end)

    assert :ok = PlcServer.remove_device("pending_remove")
    assert Task.await(request) == {:error, :device_removed}
  end

  test "updating a device returns an error to pending callers" do
    assert {:ok, device} =
             PlcServer.add_device(id: "pending_update", host: "--mock", rack: 0, slot: 1)

    assert :ok = PlcService.Device.mock_control("pending_update", :timeout_next)
    request = Task.async(fn -> PlcServer.read("pending_update", 3, 2, 1) end)
    await_until(fn -> map_size(:sys.get_state(device).pending) == 1 end)

    assert {:ok, new_device} =
             PlcServer.update_device("pending_update", host: "--mock", rack: 0, slot: 1)

    refute new_device == device
    assert Task.await(request) == {:error, :device_reconfigured}
    assert PlcServer.read("pending_update", 3, 2, 1) == {:ok, <<5>>}
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

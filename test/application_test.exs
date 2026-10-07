defmodule PlcServer.ApplicationTest do
  use ExUnit.Case, async: false

  setup do
    previous = Application.get_env(:plc_server, :devices, :unset)
    previous_path = Application.get_env(:plc_server, :device_config_path, :unset)
    path = Path.join(System.tmp_dir!(), "plc_app_config_test_#{System.unique_integer()}.term")
    Application.put_env(:plc_server, :device_config_path, path)

    on_exit(fn ->
      File.rm(path)

      if previous_path == :unset do
        Application.delete_env(:plc_server, :device_config_path)
      else
        Application.put_env(:plc_server, :device_config_path, previous_path)
      end

      if previous == :unset do
        Application.delete_env(:plc_server, :devices)
      else
        Application.put_env(:plc_server, :devices, previous)
      end
    end)

    :ok
  end

  test "configured devices start independently and report their last IO" do
    Application.put_env(:plc_server, :devices, [
      [id: "line_a", host: "--mock", rack: 0, slot: 1],
      [id: "line_b", host: "--mock", rack: 0, slot: 1]
    ])

    assert {:ok, [first, second]} = PlcServer.Application.device_specs()
    assert first.id != second.id
    start_supervised!(first)
    start_supervised!(second)

    assert {:ok, %{port: :running, last_io: :unknown, last_io_at: nil}} =
             PlcServer.device_status("line_a")

    assert PlcServer.write_point("line_a", %{db: 3, offset: 2, type: :uint16}, 42) ==
             {:ok, :written}

    assert PlcServer.read("line_a", 3, 2, 2) == {:ok, <<0, 42>>}
    assert PlcServer.read("line_b", 3, 2, 2) == {:ok, <<5, 6>>}

    assert {:ok, %{device_id: "line_a", last_io: :ok, last_io_at: checked_at}} =
             PlcServer.device_status("line_a")

    assert is_integer(checked_at)
    assert :ok = PlcService.Device.mock_control("line_a", :disconnect)
    assert PlcServer.read("line_a", 3, 2, 1) == {:error, {:snap7, -1002}}

    assert {:ok, %{last_io: {:error, {:snap7, -1002}}}} =
             PlcServer.device_status("line_a")

    assert {:ok, %{last_io: :ok}} = PlcServer.device_status("line_b")
    assert PlcServer.device_status("missing") == {:error, :unknown_plc}
  end

  test "duplicate and invalid device configurations fail before startup" do
    Application.put_env(:plc_server, :devices, [
      [id: "same", host: "--mock", rack: 0, slot: 1],
      [id: "same", host: "--mock", rack: 0, slot: 1]
    ])

    assert PlcServer.Application.device_specs() == {:error, {:duplicate_device_id, "same"}}

    Application.put_env(:plc_server, :devices, [[id: "bad", host: "", rack: 0, slot: 1]])
    assert PlcServer.Application.device_specs() == {:error, :invalid_device_config}
  end

  test "single-device environment variables remain supported" do
    Application.delete_env(:plc_server, :devices)
    variables = ["PLC_HOST", "PLC_ID", "PLC_RACK", "PLC_SLOT"]
    previous = Enum.map(variables, &{&1, System.get_env(&1)})

    on_exit(fn ->
      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    System.put_env("PLC_HOST", "--mock")
    System.put_env("PLC_ID", "legacy")
    System.put_env("PLC_RACK", "0")
    System.put_env("PLC_SLOT", "1")

    assert {:ok, [spec]} = PlcServer.Application.device_specs()
    start_supervised!(spec)
    assert PlcServer.read("legacy", 3, 2, 1) == {:ok, <<5>>}
  end
end

defmodule PlcServer.DeviceConfig do
  @moduledoc "在本地文件中保存运行时设备配置快照。"

  @version 1

  @doc "返回配置文件路径；相对路径按当前工作目录解析。"
  def path do
    configured_path =
      Application.get_env(:plc_server, :device_config_path) ||
        System.get_env("PLC_DEVICE_CONFIG_PATH") || "plc_devices.term"

    Path.expand(configured_path)
  end

  @doc "读取快照；文件不存在时返回 `{:ok, nil}`。"
  def load do
    case File.read(path()) do
      {:ok, binary} -> decode(binary)
      {:error, :enoent} -> {:ok, nil}
      {:error, reason} -> {:error, {:config_read_failed, reason}}
    end
  end

  @doc "原子替换设备配置快照。"
  def save(devices) when is_list(devices) do
    destination = path()
    temporary = "#{destination}.tmp.#{System.unique_integer([:positive, :monotonic])}"
    binary = :erlang.term_to_binary({:plc_server_devices, @version, devices})

    result =
      with :ok <- File.mkdir_p(Path.dirname(destination)),
           :ok <- File.write(temporary, binary, [:binary]),
           :ok <- File.rename(temporary, destination) do
        :ok
      end

    if result != :ok, do: File.rm(temporary)

    case result do
      :ok -> :ok
      {:error, reason} -> {:error, {:config_write_failed, reason}}
    end
  end

  defp decode(binary) do
    case :erlang.binary_to_term(binary, [:safe]) do
      {:plc_server_devices, @version, devices} when is_list(devices) -> {:ok, devices}
      _ -> {:error, :invalid_device_config_file}
    end
  rescue
    ArgumentError -> {:error, :invalid_device_config_file}
  end
end

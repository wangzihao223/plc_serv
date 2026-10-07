defmodule PlcServer do
  @moduledoc "读取西门子 S7 的 DB 字节，并让相同块的订阅者共享轮询。"

  @doc "同步读取指定 PLC 的 DB 原始字节，返回 `{:ok, bytes}` 或 `{:error, reason}`。"
  def read(plc, db, offset, length), do: PlcService.Device.read(plc, db, offset, length)

  @doc "查询设备进程及最近一次读写的状态；不主动访问 PLC。"
  def device_status(plc), do: PlcService.Device.status(plc)

  @doc "运行时添加一台 PLC，并持久化设备列表。"
  def add_device(opts), do: PlcServer.DeviceManager.add_device(opts)

  @doc "运行时移除并持久化一台 PLC；已有订阅继续轮询。"
  def remove_device(plc), do: PlcServer.DeviceManager.remove_device(plc)

  @doc "运行时替换并持久化指定 PLC 的连接配置；启动失败时恢复旧配置。"
  def update_device(plc, opts), do: PlcServer.DeviceManager.update_device(plc, opts)

  @doc "读取并解码一个点位配置。"
  def read_point(plc, config) do
    with :ok <- PlcService.Point.validate(config),
         length <- PlcService.Point.byte_length(config),
         {:ok, bytes} <- read(plc, config.db, config.offset, length),
         {:ok, value} <- PlcService.Point.decode(bytes, config) do
      {:ok, value}
    end
  end

  @doc "编码并写入一个点位。Bool 写入只生成目标 bit，适合 PC 独占的字节区域。"
  def write_point(plc, config, value) do
    with :ok <- PlcService.Point.validate(config),
         result <- write_point_value(plc, config, value) do
      result
    end
  end

  @doc "按输入顺序串行写入多个点位；任一点失败时停止并返回错误。"
  def write_points(plc, writes) when is_list(writes) do
    Enum.reduce_while(writes, {:ok, []}, fn {config, value}, {:ok, results} ->
      case write_point(plc, config, value) do
        {:ok, result} -> {:cont, {:ok, [result | results]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, results} -> {:ok, Enum.reverse(results)}
      error -> error
    end
  end

  defp write_point_value(plc, %{type: :bool, bit: bit} = config, value) when is_boolean(value) do
    PlcService.Device.write_bit(plc, config.db, config.offset, bit, value)
  end

  defp write_point_value(plc, config, value) do
    with {:ok, bytes} <- PlcService.Point.encode(value, config) do
      PlcService.Device.write(plc, config.db, config.offset, bytes)
    end
  end

  @doc "批量读取点位；同一 DB 中连续或重叠的范围会合并为一次读取。"
  def read_points(plc, configs) when is_list(configs) do
    with :ok <- validate_points(configs),
         entries <- Enum.with_index(configs),
         chunks <- build_chunks(entries),
         {:ok, chunk_values} <- read_chunks(plc, chunks) do
      entries
      |> Enum.map(fn {config, index} ->
        chunk = Enum.find(chunks, &MapSet.member?(&1.indexes, index))
        bytes = Map.fetch!(chunk_values, chunk.key)
        start = config.offset - chunk.offset
        length = PlcService.Point.byte_length(config)
        PlcService.Point.decode(binary_part(bytes, start, length), config)
      end)
      |> collect_results()
    end
  end

  defp validate_points(configs) do
    Enum.reduce_while(configs, :ok, fn config, :ok ->
      case PlcService.Point.validate(config) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp build_chunks(entries) do
    entries
    |> Enum.group_by(fn {config, _} -> config.db end)
    |> Enum.flat_map(fn {_db, db_entries} ->
      db_entries
      |> Enum.sort_by(fn {config, _} -> config.offset end)
      |> Enum.reduce([], fn {config, index}, chunks ->
        offset = config.offset
        finish = offset + PlcService.Point.byte_length(config)

        case chunks do
          [%{finish: chunk_finish} = chunk | rest]
          when offset <= chunk_finish ->
            [
              %{
                chunk
                | finish: max(chunk_finish, finish),
                  indexes: MapSet.put(chunk.indexes, index)
              }
              | rest
            ]

          _ ->
            [
              %{
                key: make_ref(),
                db: config.db,
                offset: offset,
                finish: finish,
                indexes: MapSet.new([index])
              }
              | chunks
            ]
        end
      end)
      |> Enum.map(fn chunk -> Map.put(chunk, :length, chunk.finish - chunk.offset) end)
    end)
  end

  defp read_chunks(plc, chunks) do
    Enum.reduce_while(chunks, {:ok, %{}}, fn chunk, {:ok, values} ->
      case read(plc, chunk.db, chunk.offset, chunk.length) do
        {:ok, bytes} -> {:cont, {:ok, Map.put(values, chunk.key, bytes)}}
        error -> {:halt, error}
      end
    end)
  end

  defp collect_results(results) do
    Enum.reduce_while(results, {:ok, []}, fn
      {:ok, value}, {:ok, values} -> {:cont, {:ok, values ++ [value]}}
      error, _ -> {:halt, error}
    end)
  end

  @doc "订阅指定 DB 范围；相同参数复用一个 Block 进程，变化时向调用进程发消息。"
  def subscribe(plc, db, offset, length, interval_ms) do
    start_subscription({plc, db, offset, length, interval_ms})
  end

  @doc "订阅并解码一个点位；事件的 value 是 Bool、整数、浮点或字符串。"
  def subscribe_point(plc, config, interval_ms) do
    with :ok <- PlcService.Point.validate(config) do
      key =
        {plc, config.db, config.offset, PlcService.Point.byte_length(config), interval_ms, config}

      start_subscription(key)
    end
  end

  defp start_subscription(key) do
    spec = {PlcServer.Block, key: key}

    case DynamicSupervisor.start_child(PlcServer.BlockSupervisor, spec) do
      {:ok, pid} -> PlcServer.Block.subscribe(pid)
      {:error, {:already_started, pid}} -> PlcServer.Block.subscribe(pid)
      other -> other
    end
  end
end

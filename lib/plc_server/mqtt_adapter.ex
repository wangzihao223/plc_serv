defmodule PlcServer.MqttAdapter do
  @moduledoc "将配置的 PLC 块订阅事件发布到 MQTT Broker。"
  use GenServer
  require Logger

  @retry_ms 5_000

  @doc "读取并验证可选的 MQTT 配置。"
  def config do
    case Application.get_env(:plc_server, :mqtt) do
      nil -> {:ok, nil}
      [] -> {:ok, nil}
      config -> normalize_config(config)
    end
  end

  @doc "启动发布适配器。"
  def start_link(config), do: GenServer.start_link(__MODULE__, config, name: __MODULE__)

  @impl true
  def init(config) do
    Process.flag(:trap_exit, true)
    {:ok, _} = Tortoise311.Events.register(config.client_id, :status)
    send(self(), :subscribe_all)
    send(self(), :connect)

    {:ok, %{config: config, client: nil, connected: false, latest: %{}, blocks: %{}}}
  end

  @impl true
  def handle_info(:subscribe_all, state) do
    {:noreply, Enum.reduce(state.config.streams, state, &subscribe_stream/2)}
  end

  def handle_info({:subscribe, stream}, state) do
    {:noreply, subscribe_stream(stream, state)}
  end

  def handle_info(:connect, %{client: nil} = state) do
    config = state.config

    options = [
      client_id: config.client_id,
      server: {Tortoise311.Transport.Tcp, host: config.host, port: config.port},
      handler: {PlcServer.MqttHandler, []},
      backoff: [min_interval: config.retry_ms, max_interval: config.retry_ms]
    ]

    options = if config.username, do: options ++ [user_name: config.username], else: options
    options = if config.password, do: options ++ [password: config.password], else: options

    case Tortoise311.Connection.start_link(options) do
      {:ok, client} ->
        {:noreply, %{state | client: client}}

      {:error, reason} ->
        Logger.warning("MQTT client start failed: #{inspect(reason)}")
        Process.send_after(self(), :connect, config.retry_ms)
        {:noreply, state}
    end
  end

  def handle_info(:connect, state), do: {:noreply, state}

  def handle_info({:plc_event, event}, state) do
    state = %{state | latest: Map.put(state.latest, event.topic, event)}
    {:noreply, publish_event(event, state)}
  end

  def handle_info(
        {{Tortoise311, client_id}, :status, :up},
        %{config: %{client_id: client_id}} = state
      ) do
    {:noreply, flush_latest(%{state | connected: true})}
  end

  def handle_info(
        {{Tortoise311, client_id}, :status, status},
        %{config: %{client_id: client_id}} = state
      )
      when status in [:down, :terminated] do
    {:noreply, %{state | connected: false}}
  end

  def handle_info(
        {{Tortoise311, client_id}, _reference, result},
        %{config: %{client_id: client_id}} = state
      ) do
    if match?({:error, _}, result), do: Logger.warning("MQTT publish failed: #{inspect(result)}")
    {:noreply, state}
  end

  def handle_info({:EXIT, client, reason}, %{client: client} = state) do
    Logger.warning("MQTT client stopped: #{inspect(reason)}")
    Process.send_after(self(), :connect, state.config.retry_ms)
    {:noreply, %{state | client: nil, connected: false}}
  end

  def handle_info({:EXIT, _client, _reason}, state), do: {:noreply, state}

  def handle_info({:DOWN, reference, :process, _pid, _reason}, state) do
    case Map.pop(state.blocks, reference) do
      {nil, _} ->
        {:noreply, state}

      {{stream, _block}, blocks} ->
        Process.send_after(self(), {:subscribe, stream}, state.config.retry_ms)
        {:noreply, %{state | blocks: blocks}}
    end
  end

  defp subscribe_stream(stream, state) do
    {plc, db, offset, length, interval_ms} = stream

    case PlcServer.subscribe(plc, db, offset, length, interval_ms) do
      {:ok, block} ->
        if Enum.any?(state.blocks, fn {_, {existing, pid}} ->
             existing == stream and pid == block
           end) do
          state
        else
          reference = Process.monitor(block)
          %{state | blocks: Map.put(state.blocks, reference, {stream, block})}
        end

      error ->
        Logger.warning("MQTT PLC subscription failed: #{inspect(error)}")
        Process.send_after(self(), {:subscribe, stream}, state.config.retry_ms)
        state
    end
  end

  defp publish_event(_event, %{connected: false} = state), do: state

  defp publish_event(event, state) do
    result =
      try do
        Tortoise311.publish(
          state.config.client_id,
          event.topic,
          PlcServer.MqttEvent.encode(event),
          qos: state.config.qos,
          retain: state.config.retain,
          timeout: state.config.connect_timeout_ms
        )
      catch
        :exit, reason -> {:error, reason}
      end

    case result do
      :ok ->
        state

      {:ok, _} ->
        state

      {:error, reason} ->
        Logger.warning("MQTT publish failed: #{inspect(reason)}")
        %{state | connected: false}
    end
  end

  defp flush_latest(state) do
    state.latest
    |> Map.values()
    |> Enum.sort_by(& &1.topic)
    |> Enum.reduce(state, &publish_event/2)
  end

  defp normalize_config(config) do
    config = if is_map(config), do: Map.to_list(config), else: config

    if is_list(config) and Keyword.keyword?(config) do
      host = config[:host]
      port = Keyword.get(config, :port, 1883)
      streams = config[:subscriptions]
      qos = Keyword.get(config, :qos, 0)
      retry_ms = Keyword.get(config, :retry_ms, @retry_ms)
      connect_timeout_ms = Keyword.get(config, :connect_timeout_ms, 3_000)

      with true <- is_binary(host) and host != "" and is_integer(port) and port in 1..65_535,
           true <- qos in 0..1 and is_boolean(Keyword.get(config, :retain, true)),
           true <-
             is_integer(retry_ms) and retry_ms > 0 and
               is_integer(connect_timeout_ms) and connect_timeout_ms > 0,
           true <-
             valid_text?(config[:client_id]) and valid_text?(config[:username]) and
               valid_text?(config[:password]),
           {:ok, normalized_streams} <- normalize_streams(streams) do
        client_id =
          config[:client_id] ||
            "plc-server-#{Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)}"

        {:ok,
         %{
           host: host,
           port: port,
           client_id: client_id,
           username: config[:username],
           password: config[:password],
           qos: qos,
           retain: Keyword.get(config, :retain, true),
           retry_ms: retry_ms,
           connect_timeout_ms: connect_timeout_ms,
           streams: Enum.uniq(normalized_streams)
         }}
      else
        _ -> {:error, :invalid_mqtt_config}
      end
    else
      {:error, :invalid_mqtt_config}
    end
  end

  defp normalize_streams(streams) when is_list(streams) and streams != [] do
    Enum.reduce_while(streams, {:ok, []}, fn stream, {:ok, valid} ->
      stream = if is_map(stream), do: Map.to_list(stream), else: stream

      if is_list(stream) and Keyword.keyword?(stream) do
        plc = stream[:plc]
        db = stream[:db]
        offset = stream[:offset]
        length = stream[:length]
        interval_ms = stream[:interval_ms]

        if is_binary(plc) and plc != "" and is_integer(db) and db in 0..65_535 and
             is_integer(offset) and offset in 0..2_147_483_647 and is_integer(length) and
             length in 1..65_536 and offset <= 2_147_483_648 - length and
             is_integer(interval_ms) and interval_ms >= 50 do
          {:cont, {:ok, [{plc, db, offset, length, interval_ms} | valid]}}
        else
          {:halt, {:error, :invalid_mqtt_config}}
        end
      else
        {:halt, {:error, :invalid_mqtt_config}}
      end
    end)
    |> case do
      {:ok, valid} -> {:ok, Enum.reverse(valid)}
      error -> error
    end
  end

  defp normalize_streams(_), do: {:error, :invalid_mqtt_config}

  defp valid_text?(nil), do: true
  defp valid_text?(value), do: is_binary(value) and value != ""
end

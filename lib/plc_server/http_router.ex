defmodule PlcServer.HttpRouter do
  @moduledoc "为外部进程提供 PLC 读写、状态查询和设备管理 HTTP API。"
  use Plug.Router

  @point_types %{
    "bool" => :bool,
    "int16" => :int16,
    "uint16" => :uint16,
    "int32" => :int32,
    "uint32" => :uint32,
    "float32" => :float32,
    "string" => :string,
    "bytes" => :bytes
  }
  @device_fields %{
    "id" => :id,
    "host" => :host,
    "rack" => :rack,
    "slot" => :slot,
    "timeout" => :timeout,
    "max_consecutive_timeouts" => :max_consecutive_timeouts,
    "port_path" => :port_path
  }

  plug(:authorize)
  plug(:match)
  plug(:dispatch)

  get "/health" do
    json(conn, 200, %{status: "ok"})
  end

  get "/devices" do
    devices = Enum.map(PlcServer.DeviceManager.list_devices(), &Map.new/1)
    json(conn, 200, %{devices: devices})
  end

  get "/devices/:id/status" do
    respond(conn, PlcServer.device_status(id), &status_body/1)
  end

  post "/devices" do
    body_request(conn, fn body ->
      with {:ok, config} <- device_config(body),
           {:ok, _pid} <- PlcServer.add_device(config) do
        {:created, %{device_id: Keyword.fetch!(config, :id)}}
      end
    end)
  end

  put "/devices/:id" do
    body_request(conn, fn body ->
      with {:ok, config} <- device_config(Map.put(body, "id", id)),
           {:ok, _pid} <- PlcServer.update_device(id, config) do
        {:ok, %{device_id: id}}
      end
    end)
  end

  delete "/devices/:id" do
    respond(conn, PlcServer.remove_device(id), fn :ok -> %{device_id: id} end)
  end

  post "/devices/:id/read" do
    body_request(conn, fn body ->
      with {:ok, db} <- integer(body, "db"),
           {:ok, offset} <- integer(body, "offset"),
           {:ok, length} <- integer(body, "length"),
           {:ok, bytes} <- PlcServer.read(id, db, offset, length) do
        {:ok, %{value: Base.encode64(bytes), value_encoding: "base64"}}
      end
    end)
  end

  post "/devices/:id/write" do
    body_request(conn, fn body ->
      with {:ok, db} <- integer(body, "db"),
           {:ok, offset} <- integer(body, "offset"),
           {:ok, bytes} <- base64(body["value"]),
           {:ok, :written} <- PlcService.Device.write(id, db, offset, bytes) do
        {:ok, %{result: "written"}}
      end
    end)
  end

  post "/devices/:id/read_point" do
    body_request(conn, fn body ->
      with {:ok, point} <- point_config(body),
           {:ok, value} <- PlcServer.read_point(id, point) do
        {:ok, point_value(point, value)}
      end
    end)
  end

  post "/devices/:id/write_point" do
    body_request(conn, fn body ->
      with {:ok, point} <- point_config(body),
           {:ok, value} <- write_value(point, body),
           {:ok, :written} <- PlcServer.write_point(id, point, value) do
        {:ok, %{result: "written"}}
      end
    end)
  end

  post "/devices/:id/read_points" do
    body_request(conn, fn body ->
      case body["points"] do
        points when is_list(points) ->
          with {:ok, configs} <- point_configs(points),
               {:ok, values} <- PlcServer.read_points(id, configs) do
            {:ok, %{values: Enum.zip_with(configs, values, &point_value/2)}}
          end

        _ ->
          {:error, :invalid_parameter}
      end
    end)
  end

  post "/devices/:id/write_points" do
    body_request(conn, fn body ->
      case body["points"] do
        points when is_list(points) ->
          with {:ok, writes} <- point_writes(points),
               {:ok, results} <- PlcServer.write_points(id, writes) do
            {:ok, %{results: Enum.map(results, &to_string/1)}}
          end

        _ ->
          {:error, :invalid_parameter}
      end
    end)
  end

  match _ do
    json(conn, 404, %{error: "not_found"})
  end

  defp authorize(conn, _opts) do
    case PlcServer.Http.config() do
      {:ok, %{token: nil}} ->
        conn

      {:ok, %{token: token}} ->
        case Plug.Conn.get_req_header(conn, "authorization") do
          ["Bearer " <> supplied] ->
            if Plug.Crypto.secure_compare(supplied, token) do
              conn
            else
              conn |> json(401, %{error: "unauthorized"}) |> Plug.Conn.halt()
            end

          _ ->
            conn |> json(401, %{error: "unauthorized"}) |> Plug.Conn.halt()
        end

      _ ->
        conn
    end
  end

  defp body_request(conn, callback) do
    case Plug.Conn.read_body(conn, length: 1_048_576) do
      {:ok, body, conn} ->
        case Jason.decode(body) do
          {:ok, data} when is_map(data) ->
            case callback.(data) do
              {:created, value} -> json(conn, 201, value)
              result -> respond(conn, result, & &1)
            end

          _ ->
            json(conn, 400, %{error: "invalid_json"})
        end

      {:more, _, conn} ->
        json(conn, 413, %{error: "body_too_large"})

      {:error, _} ->
        json(conn, 400, %{error: "invalid_body"})
    end
  end

  defp respond(conn, {:ok, value}, encode), do: json(conn, 200, encode.(value))
  defp respond(conn, :ok, encode), do: json(conn, 200, encode.(:ok))

  defp respond(conn, {:error, reason}, _encode) do
    json(conn, error_status(reason), %{error: error_text(reason)})
  end

  defp json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end

  defp device_config(body) do
    config =
      @device_fields
      |> Enum.reduce([], fn {field, key}, acc ->
        if Map.has_key?(body, field), do: [{key, body[field]} | acc], else: acc
      end)

    PlcServer.Application.normalize_device(config)
    |> case do
      {:ok, normalized} -> {:ok, normalized}
      error -> error
    end
  end

  defp point_config(%{"type" => type} = body) do
    with {:ok, point_type} <- Map.fetch(@point_types, type),
         {:ok, db} <- integer(body, "db"),
         {:ok, offset} <- integer(body, "offset") do
      point = %{type: point_type, db: db, offset: offset}
      point = if Map.has_key?(body, "bit"), do: Map.put(point, :bit, body["bit"]), else: point
      point = if Map.has_key?(body, "size"), do: Map.put(point, :size, body["size"]), else: point

      case PlcService.Point.validate(point) do
        :ok -> {:ok, point}
        error -> error
      end
    else
      :error -> {:error, :invalid_point}
      error -> error
    end
  end

  defp point_config(_), do: {:error, :invalid_point}

  defp point_configs(points) do
    collect(points, &point_config/1)
  end

  defp point_writes(points) do
    collect(points, fn body ->
      with {:ok, point} <- point_config(body),
           {:ok, value} <- write_value(point, body) do
        {:ok, {point, value}}
      end
    end)
  end

  defp collect(items, fun) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, values} ->
      case fun.(item) do
        {:ok, value} -> {:cont, {:ok, [value | values]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  defp write_value(%{type: :bytes}, body), do: base64(body["value"])
  defp write_value(_, %{"value" => value}), do: {:ok, value}
  defp write_value(_, _), do: {:error, :invalid_value}

  defp point_value(%{type: :bytes}, value),
    do: %{value: Base.encode64(value), value_encoding: "base64"}

  defp point_value(_, value), do: %{value: value}

  defp integer(body, field) do
    case body[field] do
      value when is_integer(value) -> {:ok, value}
      _ -> {:error, :invalid_parameter}
    end
  end

  defp base64(value) when is_binary(value) do
    case Base.decode64(value) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> {:error, :invalid_value}
    end
  end

  defp base64(_), do: {:error, :invalid_value}

  defp status_body(status) do
    status
    |> Map.update!(:port, &to_string/1)
    |> Map.update!(:last_io, &error_text/1)
  end

  defp error_status(reason)
       when reason in [
              :invalid_parameter,
              :invalid_read,
              :invalid_write,
              :invalid_point,
              :invalid_value,
              :missing_bit,
              :invalid_size,
              :invalid_device_config
            ],
       do: 400

  defp error_status(:unknown_plc), do: 404
  defp error_status(reason) when reason in [:already_exists, :unmanaged_device], do: 409
  defp error_status(:timeout), do: 504
  defp error_status({:snap7, _}), do: 502
  defp error_status({:port_exit, _}), do: 502
  defp error_status({:port_timeout, _}), do: 504
  defp error_status(_), do: 500

  defp error_text(value) when is_atom(value), do: Atom.to_string(value)
  defp error_text(value), do: inspect(value)
end

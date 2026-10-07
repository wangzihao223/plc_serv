defmodule PlcServer.HttpRouterTest do
  use ExUnit.Case, async: false
  import Plug.Test

  setup do
    start_supervised!({PlcService.Device, id: "http_mock", host: "--mock", rack: 0, slot: 1})
    :ok
  end

  test "reads and writes mock PLC values through JSON" do
    assert {200, %{"value" => "BQY="}} =
             request(:post, "/devices/http_mock/read", %{db: 3, offset: 2, length: 2})

    assert {200, %{"result" => "written"}} =
             request(:post, "/devices/http_mock/write_point", %{
               db: 3,
               offset: 2,
               type: "uint16",
               value: 42
             })

    assert {200, %{"value" => 42}} =
             request(:post, "/devices/http_mock/read_point", %{
               db: 3,
               offset: 2,
               type: "uint16"
             })

    assert {200, %{"result" => "written"}} =
             request(:post, "/devices/http_mock/write_point", %{
               db: 3,
               offset: 2,
               bit: 0,
               type: "bool",
               value: true
             })

    assert {200, %{"value" => true}} =
             request(:post, "/devices/http_mock/read_point", %{
               db: 3,
               offset: 2,
               bit: 0,
               type: "bool"
             })
  end

  test "validates requests and reports missing devices" do
    assert {400, %{"error" => "invalid_point"}} =
             request(:post, "/devices/http_mock/read_point", %{
               db: 1,
               offset: 0,
               type: "unknown"
             })

    assert {400, %{"error" => "invalid_parameter"}} =
             request(:post, "/devices/http_mock/read_points", %{points: "invalid"})

    assert {404, %{"error" => "unknown_plc"}} =
             request(:get, "/devices/missing/status")
  end

  test "adds and removes a persisted device through HTTP" do
    previous_path = Application.get_env(:plc_server, :device_config_path, :unset)

    path =
      Path.join(System.tmp_dir!(), "plc_http_test_#{System.unique_integer([:positive])}.term")

    Application.put_env(:plc_server, :device_config_path, path)

    on_exit(fn ->
      PlcServer.remove_device("http_runtime")
      File.rm(path)

      if previous_path == :unset do
        Application.delete_env(:plc_server, :device_config_path)
      else
        Application.put_env(:plc_server, :device_config_path, previous_path)
      end
    end)

    assert {201, %{"device_id" => "http_runtime"}} =
             request(:post, "/devices", %{
               id: "http_runtime",
               host: "--mock",
               rack: 0,
               slot: 1
             })

    assert {200, %{"device_id" => "http_runtime", "port" => "running"}} =
             request(:get, "/devices/http_runtime/status")

    assert {200, %{"devices" => devices}} = request(:get, "/devices")
    assert Enum.any?(devices, &(&1["id"] == "http_runtime"))

    assert {200, %{"device_id" => "http_runtime"}} =
             request(:delete, "/devices/http_runtime")
  end

  test "requires a bearer token when configured" do
    Application.put_env(:plc_server, :http, host: "127.0.0.1", port: 4000, token: "secret")
    on_exit(fn -> Application.delete_env(:plc_server, :http) end)

    assert {401, %{"error" => "unauthorized"}} = request(:get, "/health")

    conn =
      conn(:get, "/health")
      |> Plug.Conn.put_req_header("authorization", "Bearer secret")
      |> PlcServer.HttpRouter.call([])

    assert conn.status == 200
    assert Jason.decode!(conn.resp_body) == %{"status" => "ok"}
  end

  test "rejects public binding without a token" do
    Application.put_env(:plc_server, :http, host: "0.0.0.0", port: 4000)
    on_exit(fn -> Application.delete_env(:plc_server, :http) end)
    assert PlcServer.Http.config() == {:error, :invalid_http_config}
  end

  defp request(method, path, body \\ nil) do
    payload = if body == nil, do: "", else: Jason.encode!(body)
    response = conn(method, path, payload) |> PlcServer.HttpRouter.call([])
    {response.status, Jason.decode!(response.resp_body)}
  end
end

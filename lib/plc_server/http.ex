defmodule PlcServer.Http do
  @moduledoc "验证可选的 HTTP 监听配置。"

  def config do
    case Application.get_env(:plc_server, :http) do
      nil -> {:ok, nil}
      [] -> {:ok, nil}
      config -> normalize(config)
    end
  end

  defp normalize(config) when is_map(config), do: normalize(Map.to_list(config))

  defp normalize(config) when is_list(config) do
    if Keyword.keyword?(config) do
      host = Keyword.get(config, :host, "127.0.0.1")
      port = Keyword.get(config, :port, 4000)
      token = config[:token]

      with true <- is_binary(host),
           {:ok, ip} <- :inet.parse_address(String.to_charlist(host)),
           true <- is_integer(port) and port in 1..65_535,
           true <- is_nil(token) or (is_binary(token) and token != ""),
           true <- ip in [{127, 0, 0, 1}, {0, 0, 0, 0, 0, 0, 0, 1}] or is_binary(token) do
        {:ok, %{ip: ip, port: port, token: token}}
      else
        _ -> {:error, :invalid_http_config}
      end
    else
      {:error, :invalid_http_config}
    end
  end

  defp normalize(_), do: {:error, :invalid_http_config}
end

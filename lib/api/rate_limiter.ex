defmodule Lanyard.Api.RateLimiter do
  import Plug.Conn

  @table :lanyard_rate_limits
  @limit 60
  @window 60

  def init(opts), do: opts

  def call(conn, _opts) do
    bypass = System.get_env("LANYARD_API_KEY_BYPASS")

    case get_req_header(conn, "authorization") do
      [^bypass] when not is_nil(bypass) and bypass != "" ->
        conn

      _ ->
        ensure_table()
        key = conn.remote_ip |> :inet.ntoa() |> to_string()
        now = System.system_time(:second)
        window = div(now, @window)

        cleanup(window)

        count =
          case :ets.lookup(@table, {key, window}) do
            [{_, c}] -> c
            [] -> 0
          end

        remaining = @limit - count - 1

        if count >= @limit do
          conn
          |> put_resp_header("x-ratelimit-limit", "#{@limit}")
          |> put_resp_header("x-ratelimit-remaining", "0")
          |> put_resp_header("retry-after", "#{@window - rem(now, @window)}")
          |> put_resp_content_type("application/json")
          |> send_resp(429, Jason.encode!(%{success: false, error: %{code: "rate_limited", message: "Too many requests"}}))
          |> halt()
        else
          :ets.insert(@table, {{key, window}, count + 1})

          conn
          |> put_resp_header("x-ratelimit-limit", "#{@limit}")
          |> put_resp_header("x-ratelimit-remaining", "#{max(remaining, 0)}")
        end
    end
  end

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined -> :ets.new(@table, [:named_table, :public, :set])
      _ -> :ok
    end
  end

  defp cleanup(current_window) do
    :ets.select_delete(@table, [{{{"_", :"$1"}, :_}, [{:<, :"$1", current_window - 1}], [true]}])
  end
end


defmodule Lanyard.Api.Router do
  import Plug.Conn

  alias Lanyard.Api.Routes.V1
alias Lanyard.Api.Routes.V2
  alias Lanyard.Api.Routes.Discord
  alias Lanyard.Api.Routes.Metrics
  alias Lanyard.Api.Util
  alias Lanyard.Api.Quicklinks

  use Plug.Router
  use Plug.ErrorHandler

  @supported_quicktypes ["png", "gif", "webp", "jpg", "jpeg"]

  plug(Corsica,
    origins: "*",
    max_age: 600,
    allow_methods: :all,
    allow_headers: :all
  )

  plug(Lanyard.Api.RateLimiter)
  plug(:track_request)
  plug(:match)
  plug(:dispatch)

  def track_request(conn, _opts) do
    start = System.monotonic_time()

    register_before_send(conn, fn conn ->
      elapsed =
        System.convert_time_unit(System.monotonic_time() - start, :native, :microsecond) /
          1_000_000

      Lanyard.Metrics.Collector.observe(
        :histogram,
        :lanyard_http_request_duration_seconds,
        elapsed
      )

      stat =
        cond do
          is_nil(conn.status) ->
            nil

          conn.status >= 200 && conn.status < 300 ->
            :lanyard_2xx_responses

          conn.status >= 300 && conn.status < 400 ->
            :lanyard_3xx_responses

          conn.status == 404 ->
            :lanyard_404_responses

          conn.status >= 400 && conn.status < 500 ->
            :lanyard_4xx_responses

          conn.status >= 500 ->
            :lanyard_5xx_responses

          true ->
            nil
        end

      if stat, do: Lanyard.Metrics.Collector.inc(:counter, stat)

      conn
    end)
  end

  @impl Plug.ErrorHandler
  def handle_errors(conn, _error) do
    Lanyard.Metrics.Collector.inc(:counter, :lanyard_http_exceptions_total)

    send_resp(conn, conn.status, "Internal Server Error")
  end

  get "/docs" do
    docs = %{
      v1: %{
        users: "/v1/users/:id",
        me: "/v1/users/@me",
        kv: ["/v1/users/:id/kv", "/v1/users/:id/kv/:field"]
      },
      v2: %{
        users: "/v2/users/:id (extended info)",
        me: "/v2/users/@me",
        kv: ["/v2/users/:id/kv", "/v2/users/:id/kv/:field"]
      },
      socket: "/socket",
      discord: "/discord",
      metrics: "/metrics"
    }

    Util.respond(conn, {:ok, docs})
  end

  get "/status" do
    status = %{
      monitored_user_count: GenRegistry.count(Lanyard.Presence),
      node: Node.self(),
      uptime_seconds: :erlang.statistics(:wall_clock) |> elem(0) |> div(1000)
    }

    Util.respond(conn, {:ok, status})
  end

  get "/openapi" do
    spec = %{
      openapi: "3.0.0",
      info: %{title: "Lanyard API", version: "2.0"},
      paths: %{
        "/v1/users/{id}": %{"get" => %{"summary" => "Get presence"}},
        "/v2/users/{id}": %{"get" => %{"summary" => "Get extended presence"}},
        "/v2/users": %{"get" => %{"summary" => "List monitored users"}},
        "/docs": %{"get" => %{"summary" => "API docs"}},
        "/status": %{"get" => %{"summary" => "Server status"}},
        "/update": %{"get" => %{"summary" => "Changelog"}}
      }
    }

    Util.respond(conn, {:ok, spec})
  end

  get "/health" do
    Util.respond(conn, {:ok, %{status: "ok"}})
  end

  get "/" do
    response = %{
      info:
        "This is a Custome Version of Lanyard",
      monitored_user_count: GenRegistry.count(Lanyard.Presence),
      discord_invite: "https://discord.gg/QtsEBNghkX"
    }

    Util.respond(conn, {:ok, response})
  end

  get "/update" do
    update = %{
      version: "v2",
      changes: [
        "Added /v2 API with extended presence info",
        "Added /v2/users/:id returning raw discord presence and user data",
        "Added /docs endpoint listing all API paths",
        "Added /update endpoint summarizing changes"
      ]
    }

    Util.respond(conn, {:ok, update})
  end

  get "/socket" do
    %Plug.Conn{query_params: params} = fetch_query_params(conn)

    try do
      conn
      |> WebSockAdapter.upgrade(Lanyard.SocketHandler, params, timeout: 60_000)
      |> halt()
    rescue
      WebSockAdapter.UpgradeError ->
        Lanyard.Metrics.Collector.inc(:counter, :lanyard_socket_closes_total, ["upgrade_failed"])

        conn
        |> Util.respond({:error, 400, :upgrade_failed, "Request failed to upgrade"})
        |> halt()

      # i would image this is effectively useless as only the Upgrade could throw
      other ->
        reraise other, __STACKTRACE__
    end
  end

  forward("/v1", to: V1)
  forward("/v2", to: V2)
  forward("/discord", to: Discord)
  forward("/metrics", to: Metrics)

  get _ do
    quicktype = String.split(conn.request_path, ".") |> Enum.at(-1)

    cond do
      Enum.member?(@supported_quicktypes, quicktype) ->
        Quicklinks.DiscordCdn.proxy_image(conn)

      true ->
        Util.not_found(conn)
    end
  end

  options _ do
    conn
    |> send_resp(204, "")
  end

  match _ do
    Util.not_found(conn)
  end
end

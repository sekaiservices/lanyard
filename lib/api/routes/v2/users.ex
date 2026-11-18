defmodule Lanyard.Api.Routes.V2.Users do
  alias Lanyard.Api.Util
  alias Lanyard.Presence
  alias Lanyard.Connectivity.Redis

  use Plug.Router

  plug(:match)
  plug(:dispatch)

  get "/@me" do
    key = Util.authorization_header(conn)

    if key == nil do
      Util.no_permission(conn)
    else
      case Redis.get("api_key:#{key}") do
        user_id when is_binary(user_id) ->
          Util.respond(conn, Presence.get_extended_presence(user_id))

        _ ->
          Util.no_permission(conn)
      end
    end
  end

  get "/activities/:game_id/users" do
    %Plug.Conn{params: %{"game_id" => game_id}} = conn

    ids = GenRegistry.reduce(Lanyard.Presence, [], fn {id, _pid}, acc -> [id | acc] end)

    matching =
      Enum.reduce(ids, [], fn id, acc ->
        case Presence.get_pretty_presence(id) do
          {:ok, p} ->
            activities = p.activities || []

            if Enum.any?(activities, fn a -> to_string(a["id"] || a[:id]) == game_id end) do
              [id | acc]
            else
              acc
            end

          _ ->
            acc
        end
      end)

    Util.respond(conn, {:ok, matching})
  end

  get "/" do
    conn = fetch_query_params(conn)
    params = conn.query_params
    page = String.to_integer(Map.get(params, "page", "1"))
    limit = String.to_integer(Map.get(params, "limit", "50"))
    query = Map.get(params, "query")

    ids =
      GenRegistry.reduce(Lanyard.Presence, [], fn {id, _pid}, acc -> [id | acc] end)

    ids =
      if query && query != "" do
        q = String.downcase(query)

        Enum.filter(ids, fn id ->
          case Presence.get_pretty_presence(id) do
            {:ok, p} ->
              name = String.downcase(get_in(p, [:discord_user, "username"]) || "")
              activities = p.activities || []
              act_names = Enum.map(activities, fn a -> String.downcase(a["name"] || a[:name] || "") end)

              String.contains?(name, q) or Enum.any?(act_names, &String.contains?(&1, q))

            _ ->
              false
          end
        end)
      else
        ids
      end

    total = length(ids)
    offset = (page - 1) * limit
    page_ids = ids |> Enum.drop(offset) |> Enum.take(limit)

    Util.respond(conn, {:ok, %{page: page, limit: limit, total: total, users: page_ids}})
  end

  post "/bulk" do
    {:ok, body, conn} = Plug.Conn.read_body(conn)

    case Jason.decode(body) do
      {:ok, %{"ids" => ids}} when is_list(ids) ->
        results =
          Enum.reduce(ids, %{}, fn id, acc ->
            case Presence.get_pretty_presence(id) do
              {:ok, p} -> Map.put(acc, id, p)
              _ -> Map.put(acc, id, nil)
            end
          end)

        Util.respond(conn, {:ok, results})

      _ ->
        Util.respond(conn, {:error, 400, :invalid_body, "body must contain ids array"})
    end
  end

  post "/:id/refresh" do
    %Plug.Conn{params: %{"id" => user_id}} = conn

    case Presence.get_pretty_presence(user_id) do
      {:ok, p} ->
        # Invalidate cache by forcing rebuild from raw presence
        case Presence.get_presence(user_id) do
          {:ok, raw} ->
            {:ok, rebuilt} = Presence.build_pretty_presence(raw)
            Util.respond(conn, {:ok, rebuilt})

          _ ->
            Util.respond(conn, {:ok, p})
        end

      err ->
        Util.respond(conn, err)
    end
  end

  get "/:id/history" do
    %Plug.Conn{params: %{"id" => user_id}} = conn

    history =
      case Lanyard.Connectivity.Redis.lrange("lanyard_history:#{user_id}", 0, 49) do
        list when is_list(list) -> list
        _ -> []
      end

    Util.respond(conn, {:ok, history})
  end

  get "/:id" do
    %Plug.Conn{params: %{"id" => user_id}} = conn

    Util.respond(conn, Presence.get_extended_presence(user_id))
  end

  patch "/:id/kv" do
    {:ok, body, conn} = Plug.Conn.read_body(conn)

    case validate_resource_access(conn) do
      {:ok, user_id} ->
        try do
          {:ok, parsed} = Jason.decode(body)

          case Lanyard.KV.Interface.multiset(user_id, parsed) do
            {:ok} ->
              Util.respond(conn, {:ok})

            {:error, reason} ->
              Util.respond(conn, {:error, :kv_validation_failed, reason})
          end
        rescue
          _e ->
            Util.respond(conn, {:error, :invalid_kv_value, "body must be an object"})
        end

      :no_permission ->
        Util.no_permission(conn)
    end
  end

  put "/:id/kv/:field" do
    %Plug.Conn{params: %{"field" => field}} = conn

    {:ok, put_body, conn} = Plug.Conn.read_body(conn)

    case validate_resource_access(conn) do
      {:ok, user_id} ->
        case Lanyard.KV.Interface.set(String.to_integer(user_id), field, put_body) do
          {:ok, _v} ->
            Util.respond(conn, {:ok})

          {:error, reason} ->
            Util.respond(conn, {:error, :kv_validation_failed, reason})
        end

      :no_permission ->
        Util.no_permission(conn)
    end
  end

  delete "/:id/kv/:field" do
    %Plug.Conn{params: %{"field" => field}} = conn

    case validate_resource_access(conn) do
      {:ok, user_id} ->
        Lanyard.KV.Interface.del(String.to_integer(user_id), field)
        Util.respond(conn, {:ok})

      :no_permission ->
        Util.no_permission(conn)
    end
  end

  match _ do
    Util.not_found(conn)
  end

  defp validate_resource_access(conn) do
    %Plug.Conn{params: %{"id" => id}} = conn
    key = Util.authorization_header(conn)

    if key == nil do
      :no_permission
    else
      case Redis.get("api_key:#{key}") do
        resolved_id when is_binary(resolved_id) and (id == "@me" or id == resolved_id) ->
          if Presence.monitored?(resolved_id), do: {:ok, resolved_id}, else: :no_permission

        _ ->
          :no_permission
      end
    end
  end
end

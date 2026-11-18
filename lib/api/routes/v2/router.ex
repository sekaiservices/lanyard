defmodule Lanyard.Api.Routes.V2 do
  alias Lanyard.Api.Util
  alias Lanyard.Api.Routes.V2.Users

  use Plug.Router

  plug(:match)
  plug(:dispatch)

  forward("/users", to: Users)

  match _ do
    Util.not_found(conn)
  end
end

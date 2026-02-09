defmodule ExClamavServer.Repo do
  use Ecto.Repo,
    otp_app: :ex_clamav_server,
    adapter: Ecto.Adapters.Postgres
end

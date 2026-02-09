defmodule ExClamavServer.Release do
  @moduledoc """
  Release tasks for ExClamavServer.

  This module provides functions that can be called from the release binary
  to perform administrative tasks such as database migrations without needing
  Mix installed in the production image.

  ## Usage

      # From the release binary
      bin/ex_clamav_server eval "ExClamavServer.Release.migrate()"

      # Or from the entrypoint script
      /app/bin/ex_clamav_server eval "ExClamavServer.Release.migrate()"
  """

  @app :ex_clamav_server

  @doc """
  Runs all pending Ecto migrations.
  """
  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  @doc """
  Rolls back the last migration for each repo.
  """
  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  @doc """
  Creates the database for each repo if it doesn't exist.
  """
  def create do
    load_app()

    for repo <- repos() do
      case repo.__adapter__().storage_up(repo.config()) do
        :ok -> :ok
        {:error, :already_up} -> :ok
        {:error, term} -> {:error, term}
      end
    end
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.ensure_all_started(:ssl)
    Application.load(@app)
  end
end

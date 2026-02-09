defmodule ExClamavServer.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection to test
  the REST API endpoints via `Plug.Test`.

  It sets up the Ecto sandbox for database access and
  provides helpers for building and dispatching test
  connections through the router.

  The sandbox is set to `{:shared, self()}` mode so that
  background tasks spawned by `ScanWorker.scan_async/1`
  (via `Task.Supervisor`) can access the same DB connection
  without explicit `allow` calls. This means ConnCase tests
  must NOT use `async: true`.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # Import Plug test helpers (use Plug.Test is deprecated)
      import Plug.Test
      import Plug.Conn

      alias ExClamavServer.Repo
      alias ExClamavServer.Router

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import ExClamavServer.ConnCase

      @opts Router.init([])

      @doc false
      defp call(conn) do
        Router.call(conn, @opts)
      end

      @doc false
      defp json_response(conn) do
        conn.resp_body |> Jason.decode!()
      end
    end
  end

  setup tags do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(ExClamavServer.Repo, shared: not tags[:async])

    # Use shared sandbox mode so that async tasks spawned by ScanWorker
    # (via Task.Supervisor) can access the database connection owned by
    # the test process. Without this, those tasks crash with
    # DBConnection.OwnershipError because they run in separate processes.
    Ecto.Adapters.SQL.Sandbox.mode(ExClamavServer.Repo, {:shared, self()})

    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)

    :ok
  end

  @doc """
  Creates a multipart file upload conn for POST /upload.

  ## Parameters

    - `filename` — the original filename to simulate
    - `content` — the binary content of the file
    - `content_type` — the MIME type (default: "application/octet-stream")

  ## Example

      conn = upload_conn("test.txt", "hello world")
      conn = call(conn)
      assert conn.status == 202
  """
  def upload_conn(filename, content, content_type \\ "application/octet-stream") do
    # Create a temporary file to simulate Plug.Upload
    tmp_dir = System.tmp_dir!()
    tmp_path = Path.join(tmp_dir, "upload_test_#{:erlang.unique_integer([:positive])}")
    File.write!(tmp_path, content)

    upload = %Plug.Upload{
      path: tmp_path,
      filename: filename,
      content_type: content_type
    }

    conn =
      Plug.Test.conn(:post, "/upload", %{"file" => upload})
      |> Plug.Conn.put_req_header("content-type", "multipart/form-data")

    conn
  end

  @doc """
  Inserts a scan job directly into the database for testing GET endpoints.

  Returns the inserted `ScanJob` struct.
  """
  def insert_scan_job!(attrs \\ %{}) do
    defaults = %{
      reference_id: "scan_" <> (Ecto.UUID.generate() |> String.replace("-", "")),
      original_filename: "test_file.txt",
      stored_path: "/tmp/fake/test_file.txt",
      file_size: 1024,
      content_type: "text/plain",
      status: "pending"
    }

    merged = Map.merge(defaults, attrs)

    {:ok, job} = ExClamavServer.ScanJob.create(merged)
    job
  end
end

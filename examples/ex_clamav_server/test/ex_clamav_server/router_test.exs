defmodule ExClamavServer.RouterTest do
  use ExClamavServer.ConnCase

  alias ExClamavServer.ScanJob

  # ==========================================================================
  # POST /upload
  # ==========================================================================
  describe "POST /upload" do
    test "returns 202 with reference_id for a valid file upload" do
      conn = upload_conn("hello.txt", "hello world") |> call()

      assert conn.status == 202
      assert {"content-type", "application/json; charset=utf-8"} in conn.resp_headers

      body = json_response(conn)
      assert body["status"] == "ok"

      data = body["data"]
      assert is_binary(data["reference_id"])
      assert String.starts_with?(data["reference_id"], "scan_")
      assert data["original_filename"] == "hello.txt"
      assert data["file_size"] == 11
      assert data["status"] == "pending"
      assert is_binary(data["created_at"])
    end

    test "stores the scan job in the database" do
      conn = upload_conn("stored.txt", "persist me") |> call()
      assert conn.status == 202

      body = json_response(conn)
      reference_id = body["data"]["reference_id"]

      job = ScanJob.get_by_reference_id(reference_id)
      assert job != nil
      assert job.original_filename == "stored.txt"
      assert job.file_size == 10
      assert job.status in ["pending", "in_progress"]
    end

    test "returns 400 when no file is provided" do
      conn =
        conn(:post, "/upload", %{})
        |> Plug.Conn.put_req_header("content-type", "multipart/form-data")
        |> call()

      assert conn.status == 400

      body = json_response(conn)
      assert body["status"] == "error"
      assert body["error"]["code"] == "bad_request"
      assert body["error"]["message"] =~ "No file uploaded"
    end

    test "returns 400 for an empty file" do
      conn = upload_conn("empty.txt", "") |> call()

      assert conn.status == 400

      body = json_response(conn)
      assert body["status"] == "error"
      assert body["error"]["code"] == "bad_request"
      assert body["error"]["message"] =~ "empty"
    end

    test "returns 413 when file exceeds max upload size" do
      # Temporarily set a tiny max upload size
      original = Application.get_env(:ex_clamav_server, :max_upload_size)
      Application.put_env(:ex_clamav_server, :max_upload_size, 5)

      on_exit(fn ->
        if original do
          Application.put_env(:ex_clamav_server, :max_upload_size, original)
        else
          Application.delete_env(:ex_clamav_server, :max_upload_size)
        end
      end)

      conn = upload_conn("big.txt", "this is way too large") |> call()

      assert conn.status == 413

      body = json_response(conn)
      assert body["status"] == "error"
      assert body["error"]["code"] == "payload_too_large"
      assert body["error"]["message"] =~ "exceeds maximum upload size"
    end

    test "each upload gets a unique reference_id" do
      conn1 = upload_conn("a.txt", "aaa") |> call()
      conn2 = upload_conn("b.txt", "bbb") |> call()

      assert conn1.status == 202
      assert conn2.status == 202

      ref1 = json_response(conn1)["data"]["reference_id"]
      ref2 = json_response(conn2)["data"]["reference_id"]

      assert ref1 != ref2
    end

    test "sanitizes dangerous filenames" do
      conn = upload_conn("../../etc/passwd", "sneaky content") |> call()

      assert conn.status == 202

      body = json_response(conn)
      # The original filename is preserved in the response for display,
      # but the stored path should be sanitized
      data = body["data"]
      assert is_binary(data["reference_id"])

      job = ScanJob.get_by_reference_id(data["reference_id"])
      refute String.contains?(job.stored_path, "..")
    end
  end

  # ==========================================================================
  # GET /upload/:reference_id
  # ==========================================================================
  describe "GET /upload/:reference_id" do
    test "returns scan job in pending status" do
      job = insert_scan_job!(%{status: "pending"})

      conn = conn(:get, "/upload/#{job.reference_id}") |> call()

      assert conn.status == 200

      body = json_response(conn)
      assert body["status"] == "ok"

      data = body["data"]
      assert data["reference_id"] == job.reference_id
      assert data["status"] == "pending"
      assert data["original_filename"] == job.original_filename
      assert data["file_size"] == job.file_size
      refute Map.has_key?(data, "result")
    end

    test "returns scan job in in_progress status" do
      job = insert_scan_job!(%{status: "in_progress"})

      conn = conn(:get, "/upload/#{job.reference_id}") |> call()

      assert conn.status == 200

      data = json_response(conn)["data"]
      assert data["reference_id"] == job.reference_id
      assert data["status"] == "in_progress"
    end

    test "returns completed clean scan with result" do
      job = insert_scan_job!(%{status: "pending"})
      {:ok, job} = ScanJob.mark_completed(job, "clean")

      conn = conn(:get, "/upload/#{job.reference_id}") |> call()

      assert conn.status == 200

      data = json_response(conn)["data"]
      assert data["reference_id"] == job.reference_id
      assert data["status"] == "completed"
      assert data["result"] == "clean"
      refute Map.has_key?(data, "virus_name")
    end

    test "returns completed virus_found scan with virus name" do
      job = insert_scan_job!(%{status: "pending"})
      {:ok, job} = ScanJob.mark_completed(job, "virus_found", "Win.Test.EICAR_HDB-1")

      conn = conn(:get, "/upload/#{job.reference_id}") |> call()

      assert conn.status == 200

      data = json_response(conn)["data"]
      assert data["status"] == "completed"
      assert data["result"] == "virus_found"
      assert data["virus_name"] == "Win.Test.EICAR_HDB-1"
    end

    test "returns failed scan with error message" do
      job = insert_scan_job!(%{status: "pending"})
      {:ok, _job} = ScanJob.mark_failed(job, "File not found")

      conn = conn(:get, "/upload/#{job.reference_id}") |> call()

      assert conn.status == 200

      data = json_response(conn)["data"]
      assert data["status"] == "failed"
      assert data["error_message"] == "File not found"
    end

    test "returns 404 for unknown reference_id" do
      conn = conn(:get, "/upload/scan_nonexistent_00000000000000") |> call()

      assert conn.status == 404

      body = json_response(conn)
      assert body["status"] == "error"
      assert body["error"]["code"] == "not_found"
      assert body["error"]["message"] =~ "not found"
    end

    test "returns 404 for empty reference_id path" do
      conn = conn(:get, "/upload/") |> call()

      # Plug.Router won't match "/upload/" to "/upload/:reference_id"
      # so this will hit the catch-all
      assert conn.status == 404
    end
  end

  # ==========================================================================
  # GET /health
  # ==========================================================================
  describe "GET /health" do
    test "returns health response with expected structure" do
      # In test mode, ClamAV engine is not started, so the health check
      # should gracefully report unhealthy but still return a valid response.
      Application.put_env(:ex_clamav_server, :start_time, DateTime.utc_now())

      conn = conn(:get, "/health") |> call()

      # May be 200 or 503 depending on engine availability
      assert conn.status in [200, 503]

      body = json_response(conn)
      assert body["status"] == "ok"

      data = body["data"]
      assert is_boolean(data["healthy"])
      assert is_integer(data["uptime_seconds"])
      assert is_binary(data["uptime_human"])
      assert is_binary(data["instance"])

      # ClamAV sub-object should be present
      clamav = data["clamav"]
      assert is_map(clamav)
      assert Map.has_key?(clamav, "library_version")
      assert Map.has_key?(clamav, "database_version")
      assert Map.has_key?(clamav, "update_interval_seconds")
    end

    test "returns 503 when engine is not available" do
      # With :skip_clamav true, no scan engine is running,
      # so the health check should detect the engine as unavailable.
      Application.put_env(:ex_clamav_server, :start_time, DateTime.utc_now())

      conn = conn(:get, "/health") |> call()

      assert conn.status == 503

      data = json_response(conn)["data"]
      assert data["healthy"] == false
      assert data["clamav"]["database_version"] == "unavailable"
    end

    test "reports uptime based on start_time" do
      two_minutes_ago = DateTime.add(DateTime.utc_now(), -120, :second)
      Application.put_env(:ex_clamav_server, :start_time, two_minutes_ago)

      conn = conn(:get, "/health") |> call()
      data = json_response(conn)["data"]

      # Uptime should be approximately 120 seconds (allow 5s tolerance)
      assert data["uptime_seconds"] >= 118
      assert data["uptime_seconds"] <= 125
      assert data["uptime_human"] =~ "m"
    end

    test "reports zero uptime when start_time is nil" do
      Application.delete_env(:ex_clamav_server, :start_time)

      conn = conn(:get, "/health") |> call()
      data = json_response(conn)["data"]

      assert data["uptime_seconds"] == 0
    end
  end

  # ==========================================================================
  # Catch-all / unknown routes
  # ==========================================================================
  describe "unknown routes" do
    test "returns 404 for GET on unmatched path" do
      conn = conn(:get, "/nonexistent") |> call()

      assert conn.status == 404

      body = json_response(conn)
      assert body["status"] == "error"
      assert body["error"]["code"] == "not_found"
      assert body["error"]["message"] =~ "does not exist"
    end

    test "returns 404 for PUT /upload" do
      conn = conn(:put, "/upload") |> call()

      assert conn.status == 404

      body = json_response(conn)
      assert body["status"] == "error"
    end

    test "returns 404 for DELETE /upload/:id" do
      conn = conn(:delete, "/upload/scan_123") |> call()

      assert conn.status == 404
    end

    test "returns 404 for nested unknown paths" do
      conn = conn(:get, "/upload/scan_123/extra/path") |> call()

      assert conn.status == 404
    end
  end

  # ==========================================================================
  # Response format consistency
  # ==========================================================================
  describe "response format" do
    test "all success responses have status ok and data key" do
      Application.put_env(:ex_clamav_server, :start_time, DateTime.utc_now())

      job = insert_scan_job!()

      for {method, path} <- [{:get, "/health"}, {:get, "/upload/#{job.reference_id}"}] do
        conn = conn(method, path) |> call()
        body = json_response(conn)

        assert body["status"] == "ok",
               "Expected status 'ok' for #{method} #{path}, got: #{inspect(body["status"])}"

        assert is_map(body["data"]),
               "Expected 'data' map for #{method} #{path}"
      end
    end

    test "all error responses have status error and error object" do
      for {method, path} <- [
            {:get, "/nope"},
            {:get, "/upload/scan_does_not_exist_0000000000"},
            {:post, "/upload"}
          ] do
        conn =
          if method == :post do
            conn(method, path, %{})
            |> Plug.Conn.put_req_header("content-type", "multipart/form-data")
          else
            conn(method, path)
          end

        conn = call(conn)
        body = json_response(conn)

        assert body["status"] == "error",
               "Expected status 'error' for #{method} #{path}, got: #{inspect(body["status"])}"

        assert is_map(body["error"]),
               "Expected 'error' map for #{method} #{path}"

        assert is_binary(body["error"]["code"]),
               "Expected 'error.code' string for #{method} #{path}"

        assert is_binary(body["error"]["message"]),
               "Expected 'error.message' string for #{method} #{path}"
      end
    end

    test "all responses have application/json content type" do
      Application.put_env(:ex_clamav_server, :start_time, DateTime.utc_now())

      conns = [
        conn(:get, "/health") |> call(),
        conn(:get, "/upload/scan_nope_00000000000000000000") |> call(),
        conn(:get, "/nonexistent") |> call()
      ]

      for c <- conns do
        content_type =
          Enum.find_value(c.resp_headers, fn
            {"content-type", val} -> val
            _ -> nil
          end)

        assert content_type =~ "application/json",
               "Expected application/json, got: #{inspect(content_type)} for #{c.request_path}"
      end
    end
  end

  # ==========================================================================
  # POST /upload — full lifecycle integration
  # ==========================================================================
  describe "upload + status lifecycle" do
    test "uploaded file can be immediately queried via GET" do
      # Upload
      post_conn = upload_conn("lifecycle.txt", "test content here") |> call()
      assert post_conn.status == 202

      reference_id = json_response(post_conn)["data"]["reference_id"]

      # Immediately query
      get_conn = conn(:get, "/upload/#{reference_id}") |> call()
      assert get_conn.status == 200

      data = json_response(get_conn)["data"]
      assert data["reference_id"] == reference_id
      assert data["original_filename"] == "lifecycle.txt"
      # Status should be pending or in_progress (scan task may have started)
      assert data["status"] in ["pending", "in_progress", "completed", "failed"]
    end

    test "completed scan result persists across queries" do
      job = insert_scan_job!(%{status: "pending"})
      {:ok, _} = ScanJob.mark_completed(job, "clean")

      # Query multiple times
      for _i <- 1..3 do
        conn = conn(:get, "/upload/#{job.reference_id}") |> call()
        assert conn.status == 200

        data = json_response(conn)["data"]
        assert data["status"] == "completed"
        assert data["result"] == "clean"
      end
    end
  end
end

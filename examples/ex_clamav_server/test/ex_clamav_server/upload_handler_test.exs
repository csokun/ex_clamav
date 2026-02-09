defmodule ExClamavServer.UploadHandlerTest do
  use ExClamavServer.DataCase

  alias ExClamavServer.UploadHandler
  alias ExClamavServer.ScanJob

  setup do
    # Ensure a clean upload directory for each test
    upload_path = ExClamavServer.upload_path()
    File.mkdir_p!(upload_path)

    on_exit(fn ->
      # Clean up test uploads
      File.rm_rf(upload_path)
    end)

    %{upload_path: upload_path}
  end

  # ==========================================================================
  # Helper to create a Plug.Upload backed by a real temp file
  # ==========================================================================
  defp build_upload(filename, content, content_type \\ "application/octet-stream") do
    tmp_dir = System.tmp_dir!()
    tmp_path = Path.join(tmp_dir, "upload_handler_test_#{:erlang.unique_integer([:positive])}")
    File.write!(tmp_path, content)

    # NOTE: Do not use on_exit/2 here — this helper may be called from
    # inside Task.async (e.g. concurrent uploads test), where on_exit
    # is not allowed. The temp files are small and cleaned up by the OS.

    %Plug.Upload{
      path: tmp_path,
      filename: filename,
      content_type: content_type
    }
  end

  # ==========================================================================
  # handle_upload/1 — nil input
  # ==========================================================================
  describe "handle_upload/1 with nil" do
    test "returns bad_request error when no file is provided" do
      assert {:error, {:bad_request, message}} = UploadHandler.handle_upload(nil)
      assert message =~ "No file uploaded"
      assert message =~ "file"
    end
  end

  # ==========================================================================
  # handle_upload/1 — valid uploads
  # ==========================================================================
  describe "handle_upload/1 with valid file" do
    test "returns ok with response data for a valid upload" do
      upload = build_upload("test_document.txt", "hello world")

      assert {:ok, response} = UploadHandler.handle_upload(upload)

      assert is_binary(response.reference_id)
      assert String.starts_with?(response.reference_id, "scan_")
      assert response.original_filename == "test_document.txt"
      assert response.file_size == 11
      assert response.status == "pending"
      assert %DateTime{} = response.created_at
    end

    test "creates a scan job in the database" do
      upload = build_upload("db_check.txt", "persist this")

      {:ok, response} = UploadHandler.handle_upload(upload)

      job = ScanJob.get_by_reference_id(response.reference_id)
      assert job != nil
      assert job.original_filename == "db_check.txt"
      assert job.file_size == 12
      assert job.status in ["pending", "in_progress"]
      assert job.content_type == "application/octet-stream"
    end

    test "stores the file on disk under the upload path" do
      upload = build_upload("stored_file.bin", "binary data here")

      {:ok, response} = UploadHandler.handle_upload(upload)

      job = ScanJob.get_by_reference_id(response.reference_id)
      assert File.exists?(job.stored_path)
      assert File.read!(job.stored_path) == "binary data here"
    end

    test "stores file in a reference_id subdirectory" do
      upload = build_upload("subdir_test.txt", "content")

      {:ok, response} = UploadHandler.handle_upload(upload)

      job = ScanJob.get_by_reference_id(response.reference_id)
      upload_path = ExClamavServer.upload_path()

      assert String.starts_with?(job.stored_path, upload_path)
      assert String.contains?(job.stored_path, response.reference_id)
    end

    test "each upload gets a unique reference_id" do
      upload1 = build_upload("file1.txt", "aaa")
      upload2 = build_upload("file2.txt", "bbb")

      {:ok, resp1} = UploadHandler.handle_upload(upload1)
      {:ok, resp2} = UploadHandler.handle_upload(upload2)

      assert resp1.reference_id != resp2.reference_id
    end

    test "preserves the content_type from the upload" do
      upload = build_upload("image.png", "fake png data", "image/png")

      {:ok, response} = UploadHandler.handle_upload(upload)

      job = ScanJob.get_by_reference_id(response.reference_id)
      assert job.content_type == "image/png"
    end

    test "handles a single-byte file" do
      upload = build_upload("tiny.bin", "x")

      assert {:ok, response} = UploadHandler.handle_upload(upload)
      assert response.file_size == 1
    end

    test "handles binary content with null bytes" do
      content = <<0, 1, 2, 3, 0, 255, 254, 253>>
      upload = build_upload("binary.bin", content)

      {:ok, response} = UploadHandler.handle_upload(upload)

      job = ScanJob.get_by_reference_id(response.reference_id)
      assert File.read!(job.stored_path) == content
      assert response.file_size == 8
    end
  end

  # ==========================================================================
  # handle_upload/1 — empty file
  # ==========================================================================
  describe "handle_upload/1 with empty file" do
    test "returns bad_request for an empty file" do
      upload = build_upload("empty.txt", "")

      assert {:error, {:bad_request, message}} = UploadHandler.handle_upload(upload)
      assert message =~ "empty"
    end
  end

  # ==========================================================================
  # handle_upload/1 — missing/blank filename
  # ==========================================================================
  describe "handle_upload/1 with blank filename" do
    test "returns bad_request when filename is nil" do
      tmp_path = Path.join(System.tmp_dir!(), "nil_name_#{:erlang.unique_integer([:positive])}")
      File.write!(tmp_path, "data")
      on_exit(fn -> File.rm(tmp_path) end)

      upload = %Plug.Upload{path: tmp_path, filename: nil, content_type: "text/plain"}

      assert {:error, {:bad_request, message}} = UploadHandler.handle_upload(upload)
      assert message =~ "no filename"
    end

    test "returns bad_request when filename is empty string" do
      tmp_path = Path.join(System.tmp_dir!(), "empty_name_#{:erlang.unique_integer([:positive])}")
      File.write!(tmp_path, "data")
      on_exit(fn -> File.rm(tmp_path) end)

      upload = %Plug.Upload{path: tmp_path, filename: "", content_type: "text/plain"}

      assert {:error, {:bad_request, message}} = UploadHandler.handle_upload(upload)
      assert message =~ "no filename"
    end
  end

  # ==========================================================================
  # handle_upload/1 — file size limit
  # ==========================================================================
  describe "handle_upload/1 with size limit exceeded" do
    setup do
      original = Application.get_env(:ex_clamav_server, :max_upload_size)
      Application.put_env(:ex_clamav_server, :max_upload_size, 10)

      on_exit(fn ->
        if original do
          Application.put_env(:ex_clamav_server, :max_upload_size, original)
        else
          Application.delete_env(:ex_clamav_server, :max_upload_size)
        end
      end)

      :ok
    end

    test "returns payload_too_large when file exceeds max size" do
      upload = build_upload("big.txt", "this is longer than 10 bytes")

      assert {:error, {:payload_too_large, message}} = UploadHandler.handle_upload(upload)
      assert message =~ "exceeds maximum upload size"
    end

    test "accepts file exactly at the limit" do
      # Reset to exactly 10 bytes for this test
      Application.put_env(:ex_clamav_server, :max_upload_size, 10)
      upload = build_upload("exact.txt", "0123456789")

      assert {:ok, _response} = UploadHandler.handle_upload(upload)
    end

    test "accepts file under the limit" do
      Application.put_env(:ex_clamav_server, :max_upload_size, 100)
      upload = build_upload("small.txt", "short")

      assert {:ok, _response} = UploadHandler.handle_upload(upload)
    end
  end

  # ==========================================================================
  # sanitize_filename/1
  # ==========================================================================
  describe "sanitize_filename/1" do
    test "passes through simple safe filenames" do
      assert UploadHandler.sanitize_filename("document.pdf") == "document.pdf"
      assert UploadHandler.sanitize_filename("my_file.txt") == "my_file.txt"
      assert UploadHandler.sanitize_filename("test-file.bin") == "test-file.bin"
    end

    test "strips directory traversal components" do
      assert UploadHandler.sanitize_filename("../../etc/passwd") == "passwd"
      assert UploadHandler.sanitize_filename("../../../secret.txt") == "secret.txt"
      assert UploadHandler.sanitize_filename("/absolute/path/file.txt") == "file.txt"
    end

    test "replaces special characters with underscores" do
      assert UploadHandler.sanitize_filename("file name.txt") == "file_name.txt"
      assert UploadHandler.sanitize_filename("file@name#1.txt") == "file_name_1.txt"
      assert UploadHandler.sanitize_filename("file(1).txt") == "file_1_.txt"
    end

    test "preserves dots, dashes, and underscores" do
      assert UploadHandler.sanitize_filename("my.multi.dot.file.tar.gz") == "my.multi.dot.file.tar.gz"
      assert UploadHandler.sanitize_filename("a-b_c.d") == "a-b_c.d"
    end

    test "truncates to 255 characters" do
      long_name = String.duplicate("a", 300) <> ".txt"
      sanitized = UploadHandler.sanitize_filename(long_name)

      assert byte_size(sanitized) == 255
    end

    test "returns unnamed_upload for empty result" do
      # After stripping directory components and special chars, nothing may remain
      assert UploadHandler.sanitize_filename("") == "unnamed_upload"
    end

    test "handles unicode characters" do
      # Unicode letters are \w in Elixir regex, so they should be preserved
      result = UploadHandler.sanitize_filename("日本語.txt")
      assert String.ends_with?(result, ".txt")
    end

    test "strips Windows-style path separators" do
      sanitized = UploadHandler.sanitize_filename("C:\\Users\\hacker\\virus.exe")
      refute String.contains?(sanitized, "\\")
      refute String.contains?(sanitized, ":")
    end

    test "handles filename with only dots" do
      result = UploadHandler.sanitize_filename("...")
      assert result == "..."
    end

    test "handles filename with spaces and brackets" do
      result = UploadHandler.sanitize_filename("My Document (1) [final].docx")
      refute String.contains?(result, " ")
      refute String.contains?(result, "[")
      refute String.contains?(result, "]")
      assert String.ends_with?(result, ".docx")
    end
  end

  # ==========================================================================
  # handle_upload/1 — filename sanitization through the full pipeline
  # ==========================================================================
  describe "handle_upload/1 filename sanitization in stored path" do
    test "path traversal attack is neutralized" do
      upload = build_upload("../../etc/shadow", "sneaky content")

      {:ok, response} = UploadHandler.handle_upload(upload)

      job = ScanJob.get_by_reference_id(response.reference_id)
      refute String.contains?(job.stored_path, "..")
      refute String.contains?(job.stored_path, "/etc/")
      assert File.exists?(job.stored_path)
    end

    test "special characters in filename are sanitized on disk" do
      upload = build_upload("my file (copy).txt", "some content")

      {:ok, response} = UploadHandler.handle_upload(upload)

      job = ScanJob.get_by_reference_id(response.reference_id)
      basename = Path.basename(job.stored_path)
      refute String.contains?(basename, " ")
      refute String.contains?(basename, "(")
      assert File.exists?(job.stored_path)
    end
  end

  # ==========================================================================
  # handle_binary_upload/3
  # ==========================================================================
  describe "handle_binary_upload/3" do
    test "creates a scan job from raw binary content" do
      {:ok, response} = UploadHandler.handle_binary_upload("raw binary data", "raw.bin")

      assert is_binary(response.reference_id)
      assert String.starts_with?(response.reference_id, "scan_")
      assert response.original_filename == "raw.bin"
      assert response.file_size == 15
      assert response.status == "pending"
    end

    test "stores the binary content on disk" do
      content = "store me on disk"
      {:ok, response} = UploadHandler.handle_binary_upload(content, "binary_store.dat")

      job = ScanJob.get_by_reference_id(response.reference_id)
      assert File.exists?(job.stored_path)
      assert File.read!(job.stored_path) == content
    end

    test "accepts optional content_type" do
      {:ok, response} =
        UploadHandler.handle_binary_upload("pdf data", "doc.pdf", "application/pdf")

      job = ScanJob.get_by_reference_id(response.reference_id)
      assert job.content_type == "application/pdf"
    end

    test "defaults content_type to nil when not provided" do
      {:ok, response} = UploadHandler.handle_binary_upload("data", "file.bin")

      job = ScanJob.get_by_reference_id(response.reference_id)
      assert job.content_type == nil
    end

    test "returns bad_request for empty content" do
      assert {:error, {:bad_request, message}} =
               UploadHandler.handle_binary_upload("", "empty.bin")

      assert message =~ "empty"
    end

    test "returns payload_too_large when content exceeds max size" do
      original = Application.get_env(:ex_clamav_server, :max_upload_size)
      Application.put_env(:ex_clamav_server, :max_upload_size, 5)

      on_exit(fn ->
        if original do
          Application.put_env(:ex_clamav_server, :max_upload_size, original)
        else
          Application.delete_env(:ex_clamav_server, :max_upload_size)
        end
      end)

      assert {:error, {:payload_too_large, message}} =
               UploadHandler.handle_binary_upload("too long content", "big.bin")

      assert message =~ "exceeds maximum upload size"
    end

    test "sanitizes the filename in the stored path" do
      {:ok, response} =
        UploadHandler.handle_binary_upload("data", "../../etc/passwd")

      job = ScanJob.get_by_reference_id(response.reference_id)
      refute String.contains?(job.stored_path, "..")
    end
  end

  # ==========================================================================
  # Concurrent uploads
  # ==========================================================================
  describe "concurrent uploads" do
    test "multiple simultaneous uploads each get unique reference_ids" do
      # Pre-build uploads in the test process (not inside Task.async)
      # so that temp files exist before tasks start.
      uploads =
        for i <- 1..10 do
          build_upload("concurrent_#{i}.txt", "content #{i}")
        end

      tasks =
        for upload <- uploads do
          Task.async(fn ->
            UploadHandler.handle_upload(upload)
          end)
        end

      results = Task.await_many(tasks, 10_000)

      reference_ids =
        Enum.map(results, fn {:ok, response} -> response.reference_id end)

      # All unique
      assert length(Enum.uniq(reference_ids)) == 10

      # All exist in DB
      for ref_id <- reference_ids do
        assert ScanJob.get_by_reference_id(ref_id) != nil
      end
    end
  end

  # ==========================================================================
  # Response shape validation
  # ==========================================================================
  describe "response shape" do
    test "successful upload response contains exactly the expected keys" do
      upload = build_upload("shape.txt", "content")
      {:ok, response} = UploadHandler.handle_upload(upload)

      expected_keys =
        MapSet.new([:reference_id, :original_filename, :file_size, :status, :created_at])

      actual_keys = response |> Map.keys() |> MapSet.new()

      assert MapSet.equal?(expected_keys, actual_keys),
             "Expected keys #{inspect(MapSet.to_list(expected_keys))}, got #{inspect(MapSet.to_list(actual_keys))}"
    end

    test "error tuples use the {atom, string} format" do
      assert {:error, {kind, message}} = UploadHandler.handle_upload(nil)
      assert is_atom(kind)
      assert is_binary(message)
    end
  end
end

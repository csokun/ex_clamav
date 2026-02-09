defmodule ExClamavServer.ScanJobTest do
  use ExClamavServer.DataCase

  alias ExClamavServer.ScanJob

  @valid_attrs %{
    reference_id: "scan_abc123def456789012345678abcdef01",
    original_filename: "document.pdf",
    stored_path: "/data/uploads/scan_abc123/document.pdf",
    file_size: 2048,
    content_type: "application/pdf",
    status: "pending"
  }

  # ==========================================================================
  # create_changeset/1
  # ==========================================================================
  describe "create_changeset/1" do
    test "returns a valid changeset with all required fields" do
      changeset = ScanJob.create_changeset(@valid_attrs)
      assert changeset.valid?
    end

    test "returns a valid changeset with only required fields" do
      attrs = Map.take(@valid_attrs, [:reference_id, :original_filename, :stored_path, :file_size])
      changeset = ScanJob.create_changeset(attrs)
      assert changeset.valid?
    end

    test "defaults status to pending" do
      attrs = Map.delete(@valid_attrs, :status)
      changeset = ScanJob.create_changeset(attrs)
      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :status) == "pending"
    end

    test "rejects missing reference_id" do
      changeset = ScanJob.create_changeset(Map.delete(@valid_attrs, :reference_id))
      refute changeset.valid?
      assert %{reference_id: ["can't be blank"]} = errors_on(changeset)
    end

    test "rejects missing original_filename" do
      changeset = ScanJob.create_changeset(Map.delete(@valid_attrs, :original_filename))
      refute changeset.valid?
      assert %{original_filename: ["can't be blank"]} = errors_on(changeset)
    end

    test "rejects missing stored_path" do
      changeset = ScanJob.create_changeset(Map.delete(@valid_attrs, :stored_path))
      refute changeset.valid?
      assert %{stored_path: ["can't be blank"]} = errors_on(changeset)
    end

    test "rejects missing file_size" do
      changeset = ScanJob.create_changeset(Map.delete(@valid_attrs, :file_size))
      refute changeset.valid?
      assert %{file_size: ["can't be blank"]} = errors_on(changeset)
    end

    test "rejects negative file_size" do
      changeset = ScanJob.create_changeset(%{@valid_attrs | file_size: -1})
      refute changeset.valid?
      assert %{file_size: [_msg]} = errors_on(changeset)
    end

    test "accepts zero file_size" do
      changeset = ScanJob.create_changeset(%{@valid_attrs | file_size: 0})
      assert changeset.valid?
    end

    test "rejects invalid status" do
      changeset = ScanJob.create_changeset(%{@valid_attrs | status: "unknown"})
      refute changeset.valid?
      assert %{status: ["is invalid"]} = errors_on(changeset)
    end

    test "accepts all valid statuses" do
      for status <- ~w(pending in_progress completed failed) do
        changeset = ScanJob.create_changeset(%{@valid_attrs | status: status})
        assert changeset.valid?, "Expected status '#{status}' to be valid"
      end
    end

    test "accepts optional content_type" do
      changeset = ScanJob.create_changeset(%{@valid_attrs | content_type: "image/png"})
      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :content_type) == "image/png"
    end

    test "accepts optional virus_name" do
      attrs = Map.put(@valid_attrs, :virus_name, "Win.Test.EICAR_HDB-1")
      changeset = ScanJob.create_changeset(attrs)
      assert changeset.valid?
    end

    test "accepts optional error_message" do
      attrs = Map.put(@valid_attrs, :error_message, "Something went wrong")
      changeset = ScanJob.create_changeset(attrs)
      assert changeset.valid?
    end

    test "accepts optional scanned_by" do
      attrs = Map.put(@valid_attrs, :scanned_by, "pod-0@nonode@nohost")
      changeset = ScanJob.create_changeset(attrs)
      assert changeset.valid?
    end
  end

  # ==========================================================================
  # update_changeset/2
  # ==========================================================================
  describe "update_changeset/2" do
    setup do
      {:ok, job} = ScanJob.create(@valid_attrs)
      %{job: job}
    end

    test "updates status to in_progress", %{job: job} do
      changeset = ScanJob.update_changeset(job, %{status: "in_progress"})
      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :status) == "in_progress"
    end

    test "updates status to completed with result", %{job: job} do
      changeset = ScanJob.update_changeset(job, %{status: "completed", result: "clean"})
      assert changeset.valid?
    end

    test "updates virus_name", %{job: job} do
      changeset =
        ScanJob.update_changeset(job, %{
          status: "completed",
          result: "virus_found",
          virus_name: "Eicar-Test-Signature"
        })

      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :virus_name) == "Eicar-Test-Signature"
    end

    test "updates error_message", %{job: job} do
      changeset =
        ScanJob.update_changeset(job, %{status: "failed", error_message: "Engine crashed"})

      assert changeset.valid?
    end

    test "updates scanned_by", %{job: job} do
      changeset = ScanJob.update_changeset(job, %{scanned_by: "pod-1@nonode@nohost"})
      assert changeset.valid?
    end

    test "rejects invalid status", %{job: job} do
      changeset = ScanJob.update_changeset(job, %{status: "bogus"})
      refute changeset.valid?
      assert %{status: ["is invalid"]} = errors_on(changeset)
    end

    test "rejects invalid result", %{job: job} do
      changeset = ScanJob.update_changeset(job, %{status: "completed", result: "maybe"})
      refute changeset.valid?
      assert %{result: ["is invalid"]} = errors_on(changeset)
    end

    test "accepts valid results", %{job: job} do
      for result <- ~w(clean virus_found) do
        changeset = ScanJob.update_changeset(job, %{status: "completed", result: result})
        assert changeset.valid?, "Expected result '#{result}' to be valid"
      end
    end
  end

  # ==========================================================================
  # create/1
  # ==========================================================================
  describe "create/1" do
    test "inserts a valid scan job" do
      assert {:ok, %ScanJob{} = job} = ScanJob.create(@valid_attrs)
      assert job.id != nil
      assert job.reference_id == @valid_attrs.reference_id
      assert job.original_filename == "document.pdf"
      assert job.stored_path == @valid_attrs.stored_path
      assert job.file_size == 2048
      assert job.content_type == "application/pdf"
      assert job.status == "pending"
      assert job.inserted_at != nil
      assert job.updated_at != nil
    end

    test "generates a binary_id primary key" do
      {:ok, job} = ScanJob.create(@valid_attrs)
      assert is_binary(job.id)
      # UUIDs are 36 chars with dashes
      assert byte_size(job.id) == 36
    end

    test "enforces unique reference_id" do
      {:ok, _job1} = ScanJob.create(@valid_attrs)

      assert {:error, changeset} =
               ScanJob.create(%{@valid_attrs | original_filename: "other.txt"})

      assert %{reference_id: ["has already been taken"]} = errors_on(changeset)
    end

    test "returns error changeset for invalid attrs" do
      assert {:error, %Ecto.Changeset{}} = ScanJob.create(%{})
    end
  end

  # ==========================================================================
  # get_by_reference_id/1
  # ==========================================================================
  describe "get_by_reference_id/1" do
    test "returns the job for a known reference_id" do
      {:ok, inserted} = ScanJob.create(@valid_attrs)

      found = ScanJob.get_by_reference_id(@valid_attrs.reference_id)
      assert found != nil
      assert found.id == inserted.id
      assert found.reference_id == inserted.reference_id
    end

    test "returns nil for an unknown reference_id" do
      assert ScanJob.get_by_reference_id("scan_does_not_exist") == nil
    end

    test "returns nil for empty string" do
      assert ScanJob.get_by_reference_id("") == nil
    end
  end

  # ==========================================================================
  # mark_in_progress/2
  # ==========================================================================
  describe "mark_in_progress/2" do
    test "transitions status to in_progress" do
      {:ok, job} = ScanJob.create(@valid_attrs)
      {:ok, updated} = ScanJob.mark_in_progress(job)

      assert updated.status == "in_progress"
      assert updated.updated_at >= job.updated_at
    end

    test "sets scanned_by when provided" do
      {:ok, job} = ScanJob.create(@valid_attrs)
      {:ok, updated} = ScanJob.mark_in_progress(job, "worker-pod-0")

      assert updated.status == "in_progress"
      assert updated.scanned_by == "worker-pod-0"
    end

    test "scanned_by defaults to nil" do
      {:ok, job} = ScanJob.create(@valid_attrs)
      {:ok, updated} = ScanJob.mark_in_progress(job)

      assert updated.scanned_by == nil
    end
  end

  # ==========================================================================
  # mark_completed/3
  # ==========================================================================
  describe "mark_completed/3" do
    test "marks job as completed with clean result" do
      {:ok, job} = ScanJob.create(@valid_attrs)
      {:ok, updated} = ScanJob.mark_completed(job, "clean")

      assert updated.status == "completed"
      assert updated.result == "clean"
      assert updated.virus_name == nil
    end

    test "marks job as completed with virus_found and virus_name" do
      {:ok, job} = ScanJob.create(@valid_attrs)
      {:ok, updated} = ScanJob.mark_completed(job, "virus_found", "Win.Test.EICAR_HDB-1")

      assert updated.status == "completed"
      assert updated.result == "virus_found"
      assert updated.virus_name == "Win.Test.EICAR_HDB-1"
    end

    test "virus_name defaults to nil" do
      {:ok, job} = ScanJob.create(@valid_attrs)
      {:ok, updated} = ScanJob.mark_completed(job, "clean")

      assert updated.virus_name == nil
    end
  end

  # ==========================================================================
  # mark_failed/2
  # ==========================================================================
  describe "mark_failed/2" do
    test "marks job as failed with error message" do
      {:ok, job} = ScanJob.create(@valid_attrs)
      {:ok, updated} = ScanJob.mark_failed(job, "File not found: /data/uploads/missing.bin")

      assert updated.status == "failed"
      assert updated.error_message == "File not found: /data/uploads/missing.bin"
    end

    test "preserves original fields" do
      {:ok, job} = ScanJob.create(@valid_attrs)
      {:ok, updated} = ScanJob.mark_failed(job, "error")

      assert updated.original_filename == job.original_filename
      assert updated.file_size == job.file_size
      assert updated.stored_path == job.stored_path
      assert updated.reference_id == job.reference_id
    end
  end

  # ==========================================================================
  # claim_for_scanning/2
  # ==========================================================================
  describe "claim_for_scanning/2" do
    test "claims a pending job successfully" do
      {:ok, job} = ScanJob.create(@valid_attrs)

      assert {:ok, claimed} = ScanJob.claim_for_scanning(job, "pod-0@node")
      assert claimed.status == "in_progress"
      assert claimed.scanned_by == "pod-0@node"
    end

    test "returns :already_claimed if job is no longer pending" do
      {:ok, job} = ScanJob.create(@valid_attrs)
      {:ok, _claimed} = ScanJob.mark_in_progress(job, "pod-0")

      assert {:error, :already_claimed} = ScanJob.claim_for_scanning(job, "pod-1@node")
    end

    test "prevents double claim (atomic)" do
      {:ok, job} = ScanJob.create(@valid_attrs)

      # First claim succeeds
      assert {:ok, _} = ScanJob.claim_for_scanning(job, "pod-0@node")

      # Second claim on the same original struct fails
      assert {:error, :already_claimed} = ScanJob.claim_for_scanning(job, "pod-1@node")
    end

    test "claim sets updated_at" do
      {:ok, job} = ScanJob.create(@valid_attrs)
      {:ok, claimed} = ScanJob.claim_for_scanning(job, "pod-0")

      assert claimed.updated_at >= job.updated_at
    end
  end

  # ==========================================================================
  # list_pending/1
  # ==========================================================================
  describe "list_pending/1" do
    test "returns pending jobs ordered by inserted_at" do
      {:ok, job1} = ScanJob.create(%{@valid_attrs | reference_id: "scan_aaa"})

      {:ok, job2} =
        ScanJob.create(%{@valid_attrs | reference_id: "scan_bbb"})

      {:ok, _job3} =
        ScanJob.create(%{
          @valid_attrs
          | reference_id: "scan_ccc",
            status: "in_progress"
        })

      pending = ScanJob.list_pending()

      assert length(pending) == 2
      ids = Enum.map(pending, & &1.id)
      assert job1.id in ids
      assert job2.id in ids

      # Verify ordering: first inserted should be first
      assert hd(pending).id == job1.id
    end

    test "returns empty list when no pending jobs exist" do
      {:ok, _job} =
        ScanJob.create(%{@valid_attrs | status: "completed"})

      assert ScanJob.list_pending() == []
    end

    test "respects limit parameter" do
      for i <- 1..5 do
        ScanJob.create(%{@valid_attrs | reference_id: "scan_limit_#{i}"})
      end

      pending = ScanJob.list_pending(3)
      assert length(pending) == 3
    end

    test "excludes in_progress, completed, and failed jobs" do
      for {ref, status} <- [
            {"scan_pending_1", "pending"},
            {"scan_progress_1", "in_progress"},
            {"scan_completed_1", "completed"},
            {"scan_failed_1", "failed"},
            {"scan_pending_2", "pending"}
          ] do
        ScanJob.create(%{@valid_attrs | reference_id: ref, status: status})
      end

      pending = ScanJob.list_pending()
      assert length(pending) == 2
      assert Enum.all?(pending, &(&1.status == "pending"))
    end
  end

  # ==========================================================================
  # to_api_response/1
  # ==========================================================================
  describe "to_api_response/1" do
    test "returns base fields for pending job" do
      {:ok, job} = ScanJob.create(@valid_attrs)
      response = ScanJob.to_api_response(job)

      assert response.reference_id == job.reference_id
      assert response.original_filename == "document.pdf"
      assert response.file_size == 2048
      assert response.status == "pending"
      assert response.created_at == job.inserted_at
      refute Map.has_key?(response, :result)
      refute Map.has_key?(response, :virus_name)
      refute Map.has_key?(response, :error_message)
    end

    test "includes result for completed clean job" do
      {:ok, job} = ScanJob.create(@valid_attrs)
      {:ok, job} = ScanJob.mark_completed(job, "clean")
      response = ScanJob.to_api_response(job)

      assert response.status == "completed"
      assert response.result == "clean"
      refute Map.has_key?(response, :virus_name)
    end

    test "includes result and virus_name for virus_found" do
      {:ok, job} = ScanJob.create(@valid_attrs)
      {:ok, job} = ScanJob.mark_completed(job, "virus_found", "Eicar-Test-Signature")
      response = ScanJob.to_api_response(job)

      assert response.status == "completed"
      assert response.result == "virus_found"
      assert response.virus_name == "Eicar-Test-Signature"
    end

    test "includes error_message for failed job" do
      {:ok, job} = ScanJob.create(@valid_attrs)
      {:ok, job} = ScanJob.mark_failed(job, "Engine crashed")
      response = ScanJob.to_api_response(job)

      assert response.status == "failed"
      assert response.error_message == "Engine crashed"
    end

    test "does not include error_message for non-failed jobs" do
      {:ok, job} = ScanJob.create(@valid_attrs)
      response = ScanJob.to_api_response(job)

      refute Map.has_key?(response, :error_message)
    end

    test "does not leak internal fields" do
      {:ok, job} = ScanJob.create(@valid_attrs)
      response = ScanJob.to_api_response(job)

      refute Map.has_key?(response, :id)
      refute Map.has_key?(response, :stored_path)
      refute Map.has_key?(response, :scanned_by)
      refute Map.has_key?(response, :updated_at)
      refute Map.has_key?(response, :content_type)
    end
  end

  # ==========================================================================
  # State transition sequences
  # ==========================================================================
  describe "state transitions" do
    test "pending -> in_progress -> completed (clean)" do
      {:ok, job} = ScanJob.create(@valid_attrs)
      assert job.status == "pending"

      {:ok, job} = ScanJob.mark_in_progress(job, "worker-0")
      assert job.status == "in_progress"
      assert job.scanned_by == "worker-0"

      {:ok, job} = ScanJob.mark_completed(job, "clean")
      assert job.status == "completed"
      assert job.result == "clean"
    end

    test "pending -> in_progress -> completed (virus_found)" do
      {:ok, job} = ScanJob.create(@valid_attrs)
      {:ok, job} = ScanJob.mark_in_progress(job)
      {:ok, job} = ScanJob.mark_completed(job, "virus_found", "ClamAV.Test.File-6")

      assert job.status == "completed"
      assert job.result == "virus_found"
      assert job.virus_name == "ClamAV.Test.File-6"
    end

    test "pending -> in_progress -> failed" do
      {:ok, job} = ScanJob.create(@valid_attrs)
      {:ok, job} = ScanJob.mark_in_progress(job, "worker-1")
      {:ok, job} = ScanJob.mark_failed(job, "Scan engine timeout")

      assert job.status == "failed"
      assert job.error_message == "Scan engine timeout"
      assert job.scanned_by == "worker-1"
    end

    test "pending -> claim -> completed (via claim_for_scanning)" do
      {:ok, job} = ScanJob.create(@valid_attrs)
      {:ok, claimed} = ScanJob.claim_for_scanning(job, "pod-2@cluster")

      assert claimed.status == "in_progress"
      assert claimed.scanned_by == "pod-2@cluster"

      {:ok, done} = ScanJob.mark_completed(claimed, "clean")
      assert done.status == "completed"
      assert done.result == "clean"
    end
  end

  # ==========================================================================
  # Edge cases
  # ==========================================================================
  describe "edge cases" do
    test "handles very long filenames" do
      long_name = String.duplicate("a", 250) <> ".txt"

      attrs = %{@valid_attrs | original_filename: long_name, reference_id: "scan_longname_001"}
      {:ok, job} = ScanJob.create(attrs)
      assert job.original_filename == long_name
    end

    test "handles unicode filenames" do
      unicode_name = "日本語ファイル_テスト.pdf"

      attrs = %{@valid_attrs | original_filename: unicode_name, reference_id: "scan_unicode_001"}
      {:ok, job} = ScanJob.create(attrs)
      assert job.original_filename == unicode_name
    end

    test "handles very large file_size values" do
      attrs = %{@valid_attrs | file_size: 10_737_418_240, reference_id: "scan_bigfile_001"}
      {:ok, job} = ScanJob.create(attrs)
      assert job.file_size == 10_737_418_240
    end

    test "handles nil content_type" do
      attrs = %{@valid_attrs | content_type: nil, reference_id: "scan_noct_001"}
      {:ok, job} = ScanJob.create(attrs)
      assert job.content_type == nil
    end

    test "mark_completed with nil virus_name for clean result" do
      {:ok, job} = ScanJob.create(@valid_attrs)
      {:ok, updated} = ScanJob.mark_completed(job, "clean", nil)

      assert updated.result == "clean"
      assert updated.virus_name == nil
    end
  end
end

defmodule ExClamav.Test.FreshclamHelpers do
  @moduledoc """
  Shared test helpers for creating fake freshclam binaries and ClamAV database
  directories used by `DefinitionUpdater` and `Listener` tests.
  """

  @doc """
  Creates a fake freshclam shell script in the given `tmp_dir`.

  ## Options

    * `:simulate_update` — if `true`, the script writes a `daily.cvd` file into the
      `--datadir` directory to simulate an actual database update (default: `false`).
    * `:exit_code` — the exit code the script returns (default: `0`).

  Returns the absolute path to the generated script.
  """
  @spec create_fake_freshclam(Path.t(), keyword()) :: Path.t()
  def create_fake_freshclam(tmp_dir, opts \\ []) do
    simulate_update = Keyword.get(opts, :simulate_update, false)
    exit_code = Keyword.get(opts, :exit_code, 0)

    script_path = Path.join(tmp_dir, "freshclam")

    script_content =
      if simulate_update do
        """
        #!/bin/sh
        # Parse --datadir argument
        DATADIR=""
        for arg in "$@"; do
          case "$arg" in
            --datadir=*) DATADIR="${arg#--datadir=}" ;;
          esac
        done
        # Simulate a database update by touching/creating a cvd file
        if [ -n "$DATADIR" ]; then
          echo "updated" > "$DATADIR/daily.cvd"
        fi
        echo "daily.cvd updated (current version: 27500)"
        exit #{exit_code}
        """
      else
        """
        #!/bin/sh
        echo "daily.cvd database is up-to-date"
        exit #{exit_code}
        """
      end

    File.write!(script_path, script_content)
    File.chmod!(script_path, 0o755)
    script_path
  end

  @doc """
  Creates a fake ClamAV database directory inside the given `tmp_dir`.

  The directory contains a single `main.cvd` file with placeholder content.
  Returns the absolute path to the database directory.
  """
  @spec create_fake_db(Path.t()) :: Path.t()
  def create_fake_db(tmp_dir) do
    db_path = Path.join(tmp_dir, "db")
    File.mkdir_p!(db_path)
    File.write!(Path.join(db_path, "main.cvd"), "fake-main-db")
    db_path
  end
end

defmodule Mix.Tasks.Valgrind do
  @shortdoc "Run Valgrind memcheck on the ClamAV NIF C harness"

  @moduledoc """
  Compiles the standalone C leak-test harness and runs it under Valgrind
  `memcheck` to verify that the ClamAV NIF has no memory leaks.

  ## Usage

      mix valgrind

  ## Options

      --rebuild          Force recompile of the harness even if it is up-to-date
      --show-suppressions  Pass --show-error-list=yes to Valgrind so it prints
                         every active suppression
      --verbose          Echo every shell command before running it
      --output FILE      Write the full Valgrind log to FILE instead of stdout
                         (the summary is always printed to the terminal)

  ## What it does

  1. Verifies that `cc` and `valgrind` are installed.
  2. Compiles `tmp/nif_leak_fast.c` with `-g -O0` (debug, no optimisation)
     so that Valgrind origin tracking is accurate.
  3. Runs the resulting binary under:

         valgrind \\
           --tool=memcheck \\
           --leak-check=full \\
           --show-leak-kinds=all \\
           --track-origins=yes \\
           --error-exitcode=1

  4. Prints a pass/fail summary.  Exits with status 1 on any Valgrind error
     so CI pipelines catch regressions automatically.

  ## Requirements

  - `valgrind` must be installed (`apt install valgrind` / `brew install valgrind`).
  - `libclamav-dev` must be installed so the harness can be compiled.
  - The harness source must exist at `tmp/nif_leak_fast.c` (already committed
    in this repository).
  """

  use Mix.Task

  # ANSI helpers ----------------------------------------------------------------

  @green "\e[32m"
  @red "\e[31m"
  @yellow "\e[33m"
  @bold "\e[1m"
  @reset "\e[0m"

  defp green(s), do: "#{@green}#{s}#{@reset}"
  defp red(s), do: "#{@red}#{s}#{@reset}"
  defp yellow(s), do: "#{@yellow}#{s}#{@reset}"
  defp bold(s), do: "#{@bold}#{s}#{@reset}"

  # ---------------------------------------------------------------------------
  # Entry point
  # ---------------------------------------------------------------------------

  @switches [
    rebuild: :boolean,
    show_suppressions: :boolean,
    verbose: :boolean,
    output: :string
  ]

  @impl Mix.Task
  def run(args) do
    {opts, _rest, _invalid} = OptionParser.parse(args, strict: @switches)

    verbose = Keyword.get(opts, :verbose, false)
    rebuild = Keyword.get(opts, :rebuild, false)
    show_suppressions = Keyword.get(opts, :show_suppressions, false)
    log_file = Keyword.get(opts, :output, nil)

    project_root = project_root()
    src = Path.join([project_root, "tmp", "nif_leak_fast.c"])
    bin = Path.join([project_root, "tmp", "nif_leak_fast"])

    Mix.shell().info(bold("==> mix valgrind – NIF memory-leak check"))

    check_tool!("cc", "a C compiler (gcc/clang)")
    check_tool!("valgrind", "valgrind  (apt install valgrind / brew install valgrind)")

    unless File.exists?(src) do
      Mix.raise("""
      Harness source not found: #{src}

      The file `tmp/nif_leak_fast.c` must exist in the project root.
      It was created during the original Valgrind investigation and should
      be committed to the repository.
      """)
    end

    compile_harness!(src, bin, rebuild: rebuild, verbose: verbose)

    run_valgrind!(bin,
      show_suppressions: show_suppressions,
      verbose: verbose,
      log_file: log_file
    )
  end

  # ---------------------------------------------------------------------------
  # Pre-flight checks
  # ---------------------------------------------------------------------------

  defp check_tool!(cmd, description) do
    case System.find_executable(cmd) do
      nil ->
        Mix.raise("#{red("✗")} `#{cmd}` not found – please install #{description}")

      path ->
        Mix.shell().info("  #{green("✓")} #{cmd}: #{path}")
    end
  end

  # ---------------------------------------------------------------------------
  # Compile step
  # ---------------------------------------------------------------------------

  defp compile_harness!(src, bin, opts) do
    verbose = Keyword.get(opts, :verbose, false)
    rebuild = Keyword.get(opts, :rebuild, false)

    if not rebuild and up_to_date?(src, bin) do
      Mix.shell().info(
        "  #{green("✓")} harness up-to-date – skipping compile (use --rebuild to force)"
      )
    else
      Mix.shell().info("  #{yellow("⟳")} compiling #{Path.relative_to_cwd(src)} ...")

      # Include dirs: ERTS headers (for erl_nif.h) + system headers
      erts_include = erts_include_dir()

      cc_args = [
        "-std=c11",
        "-g",
        "-O0",
        "-Wall",
        ~s(-I#{erts_include}),
        "-I/usr/local/include",
        "-I/usr/include",
        src,
        "-lclamav",
        "-o",
        bin
      ]

      cmd = "cc " <> Enum.join(cc_args, " ")
      if verbose, do: Mix.shell().info("    $ #{cmd}")

      case System.cmd("cc", cc_args, stderr_to_stdout: true) do
        {_, 0} ->
          Mix.shell().info("  #{green("✓")} compiled → #{Path.relative_to_cwd(bin)}")

        {output, code} ->
          Mix.raise("""
          #{red("✗")} Compilation failed (exit #{code})

          #{output}
          """)
      end
    end
  end

  # True when the binary exists and is newer than the source.
  defp up_to_date?(src, bin) do
    case {File.stat(src, time: :posix), File.stat(bin, time: :posix)} do
      {{:ok, %{mtime: sm}}, {:ok, %{mtime: bm}}} -> bm >= sm
      _ -> false
    end
  end

  # ---------------------------------------------------------------------------
  # Valgrind step
  # ---------------------------------------------------------------------------

  defp run_valgrind!(bin, opts) do
    verbose = Keyword.get(opts, :verbose, false)
    show_suppressions = Keyword.get(opts, :show_suppressions, false)
    log_file = Keyword.get(opts, :log_file, nil)

    Mix.shell().info("  #{yellow("⟳")} running under Valgrind ...\n")

    valgrind_args =
      [
        "--tool=memcheck",
        "--leak-check=full",
        "--show-leak-kinds=all",
        "--track-origins=yes",
        "--error-exitcode=1"
      ]
      |> maybe_add("--show-error-list=yes", show_suppressions)
      |> then(fn args ->
        if log_file do
          args ++ ["--log-file=#{log_file}"]
        else
          args
        end
      end)
      |> Kernel.++([bin])

    if verbose do
      Mix.shell().info("    $ valgrind " <> Enum.join(valgrind_args, " "))
    end

    # Stream output live to the terminal so the user can watch progress.
    # Valgrind writes its report to stderr; we merge streams with stderr_to_stdout.
    exit_code =
      run_streaming("valgrind", valgrind_args)

    Mix.shell().info("")

    cond do
      exit_code == 0 ->
        Mix.shell().info(bold(green("✓ PASS – no memory leaks detected")))
        if log_file, do: Mix.shell().info("  full log written to #{log_file}")

      true ->
        Mix.shell().info(bold(red("✗ FAIL – Valgrind reported errors (exit #{exit_code})")))
        if log_file, do: Mix.shell().info("  full log written to #{log_file}")
        # Raise so `mix valgrind` exits with a non-zero status in CI.
        Mix.raise("Valgrind reported memory errors – see output above")
    end
  end

  # ---------------------------------------------------------------------------
  # Stream a command's stdout+stderr live to the terminal.
  # Returns the OS exit code as an integer.
  # ---------------------------------------------------------------------------

  defp run_streaming(cmd, args) do
    port =
      Port.open(
        {:spawn_executable, System.find_executable(cmd)},
        [:binary, :exit_status, :stderr_to_stdout, args: args]
      )

    collect_port(port)
  end

  defp collect_port(port) do
    receive do
      {^port, {:data, data}} ->
        IO.write(data)
        collect_port(port)

      {^port, {:exit_status, status}} ->
        status
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp maybe_add(list, _item, false), do: list
  defp maybe_add(list, item, true), do: list ++ [item]

  # Locate the ERTS include directory for the running Erlang installation.
  defp erts_include_dir do
    erts_dir =
      :erlang.system_info(:version)
      |> to_string()
      |> then(fn vsn ->
        # e.g. /usr/lib/erlang/erts-15.0/include
        Path.join([
          :code.root_dir() |> to_string(),
          "erts-#{vsn}",
          "include"
        ])
      end)

    # Fall back to the erl_interface path used by elixir_make if ERTS dir
    # is not found (common in asdf / nix environments).
    if File.dir?(erts_dir) do
      erts_dir
    else
      # Try the path elixir_make injects via $ERTS_INCLUDE_DIR at build time.
      System.get_env("ERTS_INCLUDE_DIR") ||
        raise "Cannot locate ERTS include directory. " <>
                "Set ERTS_INCLUDE_DIR env var to your Erlang include path."
    end
  end

  defp project_root do
    Mix.Project.project_file()
    |> Path.dirname()
  end
end

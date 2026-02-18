# ExClamav

[![main](https://github.com/csokun/ex_clamav/actions/workflows/ci.yml/badge.svg?branch=main&event=push)](https://github.com/csokun/ex_clamav/actions/workflows/ci.yml)

ExClamav is an Elixir library providing native bindings to the [ClamAV antivirus engine](https://docs.clamav.net/manual/Development/libclamav.html). It enables Elixir applications to scan files and data buffers for viruses and malware using ClamAV's robust detection capabilities.

This library is intended for developers who need to integrate virus scanning into their Elixir projects, such as file upload services, content moderation pipelines, or any system where security and malware detection are required. ExClamav offers both low-level access to the ClamAV engine and convenient helper functions for common scanning tasks.

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `ex_clamav` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:ex_clamav, "~> 0.1.7"}
  ]
end
```

### Install ClamAV development libraries

```bash
# Ubuntu/Debian
sudo apt-get install libclamav-dev clamav

# RHEL/CentOS
sudo yum install clamav-devel clamav

# macOS
brew install clamav
```

## Usage

```elixir
# Initialize library
:ok = ExClamav.Engine.init()

# Create an engine
{:ok, engine} = ExClamav.new_engine()

# Load database
{:ok, signatures} = ExClamav.Engine.load_database(engine, "/var/lib/clamav")
# => {:ok, 1234567}

# Compile engine
:ok = ExClamav.Engine.compile(engine)

# Scan a file
case ExClamav.Engine.scan_file(engine, "/path/to/file") do
  {:ok, :clean} ->
    IO.puts("File is clean")
    
  {:ok, :virus, virus_name} ->
    IO.puts("Virus found: #{virus_name}")
    
  {:error, reason} ->
    IO.puts("Error: #{reason}")
end

# Scan a buffer
data = File.read!("/path/to/file")
case ExClamav.Engine.scan_buffer(engine, data) do
  {:ok, :clean} -> IO.puts("Buffer is clean")
  {:ok, :virus, name} -> IO.puts("Found #{name}")
end

# Quick scan using helper function
case ExClamav.scan_file("/path/to/file") do
  {:ok, :clean} -> :safe
  {:ok, :virus, name} -> {:virus, name}
  {:error, reason} -> {:error, reason}
end

# Check if file is clean
if ExClamav.Engine.clean?(engine, "/path/to/file") do
  IO.puts("File is safe to use")
end

# Get versions
ExClamav.version()
ExClamav.Engine.get_database_version(engine)

# Clean up
ExClamav.Engine.free(engine)
```

## Development

### Checking for memory leaks

The project includes a Mix task that compiles a standalone C harness and runs
it under [Valgrind](https://valgrind.org/) `memcheck` to verify that the
ClamAV NIF has no memory leaks.

**Prerequisites**

```bash
# Ubuntu/Debian
sudo apt-get install valgrind

# macOS (via Homebrew — requires Rosetta on Apple Silicon)
brew install valgrind
```

**Run the check**

```bash
mix valgrind
```

**Options**

| Flag | Effect |
|---|---|
| `--rebuild` | Force recompile of the harness even if it is up-to-date |
| `--verbose` | Echo each shell command before running it |
| `--output FILE` | Write the full Valgrind log to a file |
| `--show-suppressions` | Tell Valgrind to list every active suppression |

**Examples**

```bash
# Force recompile and save the full log
mix valgrind --rebuild --output /tmp/valgrind.log

# Verbose mode — see every command that is run
mix valgrind --verbose
```

The task exits with status `1` if Valgrind reports any errors, making it
suitable for use in CI pipelines.

The harness (`tmp/nif_leak_fast.c`) exercises every engine lifecycle path
without loading the full virus database, so it completes in seconds even
under Valgrind:

- Normal lifecycle: `engine_new → engine_free → GC (no-op)`
- GC-only lifecycle: `engine_new → destructor`
- Double-free guard: `engine_free` called twice
- Load-database failure path
- Scan-after-free guard (NULL check)
- `fmap` lifecycle: `open → scan_callback → close`
- Multiple engines all explicitly freed
- Mixed: half explicit-free, half GC-only

A clean run reports:

```
✓ PASS – no memory leaks detected
```

---

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at <https://hexdocs.pm/ex_clamav>.

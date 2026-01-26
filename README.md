# ClamavEx

![CI](https://github.com/csokun/clamav_ex/actions/workflows/ci.yml/badge.svg)

ClamavEx is an Elixir library providing native bindings to the ClamAV antivirus engine. It enables Elixir applications to scan files and data buffers for viruses and malware using ClamAV's robust detection capabilities.

This library is intended for developers who need to integrate virus scanning into their Elixir projects, such as file upload services, content moderation pipelines, or any system where security and malware detection are required. ClamavEx offers both low-level access to the ClamAV engine and convenient helper functions for common scanning tasks.

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `clamav_ex` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:clamav_ex, "~> 0.1.0"}
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
:ok = ClamavEx.Engine.init()

# Create an engine
{:ok, engine} = ClamavEx.new_engine()

# Load database
{:ok, signatures} = ClamavEx.Engine.load_database(engine, "/var/lib/clamav")
# => {:ok, 1234567}

# Compile engine
:ok = ClamavEx.Engine.compile(engine)

# Scan a file
case ClamavEx.Engine.scan_file(engine, "/path/to/file") do
  {:ok, :clean} ->
    IO.puts("File is clean")
    
  {:ok, :virus, virus_name} ->
    IO.puts("Virus found: #{virus_name}")
    
  {:error, reason} ->
    IO.puts("Error: #{reason}")
end

# Scan a buffer
data = File.read!("/path/to/file")
case ClamavEx.Engine.scan_buffer(engine, data) do
  {:ok, :clean} -> IO.puts("Buffer is clean")
  {:ok, :virus, name} -> IO.puts("Found #{name}")
end

# Quick scan using helper function
case ClamavEx.scan_file("/path/to/file") do
  {:ok, :clean} -> :safe
  {:ok, :virus, name} -> {:virus, name}
  {:error, reason} -> {:error, reason}
end

# Check if file is clean
if ClamavEx.Engine.clean?(engine, "/path/to/file") do
  IO.puts("File is safe to use")
end

# Get versions
ClamavEx.version()
ClamavEx.Engine.get_database_version(engine)

# Clean up
ClamavEx.Engine.free(engine)
```

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at <https://hexdocs.pm/clamav_ex>.

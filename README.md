# Dynamic Supervisor

[![Hex.pm](https://img.shields.io/hexpm/v/dynamic_supervisor.svg)](https://hex.pm/packages/dynamic_supervisor)
[![License](https://img.shields.io/hexpm/l/dynamic_supervisor.svg)](https://github.com/longlene/dynamic_supervisor/blob/master/LICENSE)

An Erlang library providing a supervisor optimized for dynamically spawning children. This is a port of Elixir's DynamicSupervisor, maintaining a similar API while following Erlang conventions.

## Installation

Add to your `rebar.config`:

```erlang
{deps, [
    {dynamic_supervisor, "1.0.0"}
]}.
```

Or for hex.pm:

```erlang
{deps, [
    {dynamic_supervisor, {hex, dynamic_supervisor, "1.0.0"}}
]}.
```

## Overview

The `dynamic_supervisor` module provides a supervisor optimized for dynamically starting children. Unlike the standard supervisor which is designed for static children started in order, a dynamic supervisor:

- Starts with no children
- Allows starting children on demand via `start_child/2`
- Has no ordering between children
- Can efficiently handle millions of children
- Executes operations like shutdown concurrently

## Features

- **One-for-one supervision strategy**: Only the failed child is restarted
- **Dynamic child management**: Add and remove children at runtime
- **Restart strategies**: Support for `permanent`, `transient`, and `temporary` restart types
- **Maximum children limit**: Optional limit on the number of concurrent children
- **Extra arguments**: Arguments that are prepended to child start arguments
- **Full OTP compliance**: Implements standard supervisor behaviors

## API

### Starting a Dynamic Supervisor

```erlang
{ok, Pid} = dynamic_supervisor:start_link([
    {name, {local, my_supervisor}},
    {strategy, one_for_one},
    {max_restarts, 3},
    {max_seconds, 5},
    {max_children, 1000}
]).
```

### Starting Children

```erlang
%% Full child specification
{ok, ChildPid} = dynamic_supervisor:start_child(my_supervisor, 
    #{id => worker1,
      start => {my_worker, start_link, [Arg1, Arg2]},
      restart => permanent,
      shutdown => 5000,
      type => worker,
      modules => [my_worker]}).

%% Simplified specification (using defaults)
{ok, ChildPid2} = dynamic_supervisor:start_child(my_supervisor,
    #{id => worker2,
      start => {my_worker, start_link, []}}).
```

### Managing Children

```erlang
%% List all children
Children = dynamic_supervisor:which_children(my_supervisor).

%% Count children
Counts = dynamic_supervisor:count_children(my_supervisor).
%% Returns: #{specs => N, active => N, supervisors => N, workers => N}

%% Terminate a specific child
ok = dynamic_supervisor:terminate_child(my_supervisor, ChildPid).

%% Stop the supervisor
ok = dynamic_supervisor:stop(my_supervisor).
```

## Examples

### Basic Usage

See `example_usage.erl` for a complete example:

```bash
make example
```

### Running Tests

```bash
make test
```

### Interactive Shell

```bash
make shell
```

Then in the Erlang shell, you need to add the examples path:

```erlang
1> code:add_path("examples").
2> example_usage:demo().
```

## Differences from Elixir's DynamicSupervisor

1. **Module naming**: Uses Erlang convention (`dynamic_supervisor` instead of `DynamicSupervisor`)
2. **Options format**: Uses proplist format `[{key, value}]` instead of keyword lists
3. **Child specs**: Supports both map-based specs and traditional tuple-based specs
4. **Return values**: Uses standard Erlang return conventions
5. **Error handling**: Uses Erlang's error_logger instead of Elixir's Logger

## Implementation Notes

- Built on top of gen_server behavior
- Uses maps for efficient child storage
- Implements OTP supervisor protocols
- Supports hot code upgrades via `code_change/3`
- Proper cleanup on termination with concurrent child shutdown

## Files

- `src/dynamic_supervisor.erl` - Main implementation
- `examples/counter.erl` - Example gen_server for demonstrations
- `examples/example_usage.erl` - Usage examples
- `test/` - Test suites (EUnit and Common Test)
- `Makefile` - Build automation

## Building

```bash
make compile    # Compile the library
make test      # Run tests  
make example   # Run example
make shell     # Start Erlang shell
```

## Requirements

- Erlang/OTP 21 or later (for map support)
- rebar3 (for building)

## License

Apache 2.0 - This implementation follows the structure of Elixir's DynamicSupervisor but is written entirely in Erlang.
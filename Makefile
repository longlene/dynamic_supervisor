.PHONY: all compile clean test example shell

REBAR3 := $(shell which rebar3 || echo ./rebar3)

all: compile

compile:
	@$(REBAR3) compile

test:
	@$(REBAR3) eunit
	@$(REBAR3) ct

example: compile
	@erl -pa _build/default/lib/*/ebin examples -eval "example_usage:demo(), init:stop()." -noshell

clean:
	@$(REBAR3) clean

shell:
	@$(REBAR3) shell

# Download rebar3 if not present
rebar3:
	@curl -o rebar3 https://s3.amazonaws.com/rebar3/rebar3
	@chmod +x rebar3
.PHONY: all compile test doc clean shell

REBAR = rebar3

all: compile

compile:
	$(REBAR) compile

test:
	$(REBAR) eunit

doc:
	$(REBAR) ex_doc

clean:
	$(REBAR) clean

shell:
	$(REBAR) shell

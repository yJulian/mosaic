.PHONY: sim sim-all build program program-flash clean

# Usage: make sim TB=tb_pe
sim:
	@if [ -z "$(TB)" ]; then echo "usage: make sim TB=tb_pe"; exit 1; fi
	scripts/sim.sh $(TB)

sim-all:
	scripts/sim_all.sh

build:
	scripts/build.sh

program: build
	scripts/program.sh

program-flash: build
	scripts/program.sh --flash

clean:
	rm -rf build

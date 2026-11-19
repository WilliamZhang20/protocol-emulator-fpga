# Host-side self-test of the stimulus logic (no hardware needed).
# The real JTAG run happens via xsct jtag_verify.tcl.
CC ?= cc
CFLAGS ?= -Wall -Wextra -O2

all: jtag_verify_host

jtag_verify_host: jtag_verify.c
	$(CC) $(CFLAGS) -DSTANDALONE -o $@ $<

test: jtag_verify_host
	./jtag_verify_host

clean:
	rm -f jtag_verify_host

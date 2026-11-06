bindir := .
CFLAGS := -std=c99 -O2 -g
LDFLAGS := -static -static-libgcc

all: $(bindir)/userns_sandbox

%.o: %.c
	$(CC) -c $(CFLAGS) -o $@ $<

$(bindir)/userns_sandbox: userns_sandbox.o userns_common.o
	$(CC) $(LDFLAGS) -o $@ $^

clean:
	rm -f *.o $(bindir)/userns_sandbox

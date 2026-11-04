# frozen_string_literal: true

# Builds the Cring extension (ring.c), linked against liburing from install.sh's liburing-dev.
require "mkmf"

abort "liburing not found (install.sh installs liburing-dev)" unless have_library("uring", "io_uring_queue_init_params", "liburing.h")
$CFLAGS << " -O3 #{ENV.fetch("NATIVE", "")} -std=gnu11 -Wall -Wno-unused-parameter -Wno-unused-function"
create_makefile("cring")

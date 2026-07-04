# Child script for the WS teardown test. Serves a WS endpoint, waits for
# the parent to establish a live connection (signalled by at least one
# message arriving), then calls dr_stop() while that connection is still
# open and exits cleanly. Prints "TEARDOWN_CLEAN" on success; a crash in
# clearAllWsSessions() (touching a dead loop/connection) would abort
# before that line.
#
# Invocation: Rscript --vanilla ws-teardown-script.R <port>

args <- commandArgs(trailingOnly = TRUE)
port <- as.integer(args[[1L]])

suppressPackageStartupMessages(library(drogonR))

got <- new.env(parent = emptyenv()); got$any <- FALSE

app <- dr_app()
app <- dr_get(app, "/__ping__", function(req) "pong")
app <- dr_ws(app, "/ws",
  on_message = function(conn, msg, binary) {
    got$any <- TRUE
    dr_ws_send(conn, msg)
  })

dr_serve(app, port = port, threads = 1L)
cat("SERVING\n"); flush(stdout())

# Pump until the parent's client has sent a message (so a session is
# live), or time out.
deadline <- Sys.time() + 15
while (!got$any && Sys.time() < deadline) later::run_now(timeoutSecs = 0.1)

# Tear down with the connection still open. This is the path under test.
dr_stop()
cat("TEARDOWN_CLEAN\n"); flush(stdout())

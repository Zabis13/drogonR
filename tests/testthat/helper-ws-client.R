# Helpers for the WebSocket *client* tests (drogonR connecting outward to
# an external WS server). Unlike the server-side WS tests, no `websocket`
# package is involved: the client is drogonR's own dr_ws_connect(), whose
# events are pumped by drogonR's dispatcher on later's loop. We only have
# to drive later::run_now() so those events get delivered to our hooks.

# Drive later's loop until pred() is TRUE or we time out. Returns pred's
# final logical value.
wsc_pump_until <- function(pred, timeout = 10) {
  deadline <- Sys.time() + timeout
  repeat {
    if (isTRUE(pred())) return(TRUE)
    later::run_now(timeoutSecs = 0.05)
    if (Sys.time() > deadline) return(FALSE)
  }
}

# Direct R→JSON serializer (drogonR_to_json) — golden-comparison
# against jsonlite, which is the reference. The point is not to
# verify our output character-by-character (jsonlite has subtle
# numeric formatting we don't try to mirror) but to verify that for
# the shapes we *claim* to handle, output is byte-identical to
# jsonlite — and that for shapes we *don't* handle, we return NULL
# so dr_json() falls back instead of producing wrong JSON.

skip_if_not_installed("jsonlite")

j <- function(x, auto_unbox = TRUE) {
  .Call(drogonR:::drogonR_to_json, x, isTRUE(auto_unbox))
}
ref <- function(x, auto_unbox = TRUE) {
  as.character(jsonlite::toJSON(x, auto_unbox = auto_unbox))
}

# Byte-identical comparison for non-numeric and integer cases.
# Numerics use %.17g (round-trip-safe) instead of jsonlite's R format()
# heuristic, so for doubles we round-trip via fromJSON and compare
# semantically — the API contract is the parsed value, not the textual
# representation.
parse_back <- function(s) jsonlite::fromJSON(s, simplifyVector = TRUE)

test_that("scalar atomics with auto_unbox match jsonlite", {
  expect_equal(j(TRUE),               ref(TRUE))
  expect_equal(j(FALSE),              ref(FALSE))
  expect_equal(j(42L),                ref(42L))
  expect_equal(j(-7L),                ref(-7L))
  expect_equal(j("hi"),               ref("hi"))
  # Doubles: parse-equivalent rather than byte-equal — see note above.
  expect_equal(parse_back(j(3.14)),   3.14)
  expect_equal(parse_back(j(0.1)),    0.1)
})

test_that("length>1 atomics emit JSON arrays", {
  expect_equal(j(c(TRUE, FALSE, NA)), ref(c(TRUE, FALSE, NA)))
  expect_equal(j(1:5),                ref(1:5))
  expect_equal(j(c("a", "b", "c")),   ref(c("a", "b", "c")))
  expect_equal(parse_back(j(c(1.5, 2.5, 3.5))), c(1.5, 2.5, 3.5))
})

test_that("auto_unbox = FALSE wraps length-1 in an array", {
  expect_equal(j(TRUE,  auto_unbox = FALSE), ref(TRUE,  auto_unbox = FALSE))
  expect_equal(j(42L,   auto_unbox = FALSE), ref(42L,   auto_unbox = FALSE))
  expect_equal(j("x",   auto_unbox = FALSE), ref("x",   auto_unbox = FALSE))
})

test_that("named lists become JSON objects", {
  expect_equal(j(list(ok = TRUE)),
               ref(list(ok = TRUE)))
  expect_equal(j(list(ok = TRUE, n = 42L, name = "drogonR")),
               ref(list(ok = TRUE, n = 42L, name = "drogonR")))
})

test_that("unnamed lists become JSON arrays", {
  expect_equal(j(list(1L, 2L, 3L)), ref(list(1L, 2L, 3L)))
  expect_equal(j(list("a", "b")),   ref(list("a", "b")))
})

test_that("nested lists round-trip via jsonlite", {
  x <- list(error = FALSE,
            data  = list(items = list(
              list(id = 1L, name = "a"),
              list(id = 2L, name = "b"))),
            count = 2L)
  expect_equal(j(x), ref(x))
})

test_that("NA / NaN / Inf / -Inf become null, like jsonlite", {
  # Within an array
  expect_equal(j(c(1.0, NA, NaN, Inf, -Inf)),
               ref(c(1.0, NA, NaN, Inf, -Inf)))
  expect_equal(j(c(1L, NA_integer_, 3L)),
               ref(c(1L, NA_integer_, 3L)))
  expect_equal(j(NA),                 ref(NA))
  expect_equal(j(NA_integer_),        ref(NA_integer_))
  expect_equal(j(NA_real_),           ref(NA_real_))
  expect_equal(j(NA_character_),      ref(NA_character_))
})

test_that("empty list emits {} and empty atomic emits []", {
  expect_equal(j(list()),             ref(list()))
  expect_equal(j(integer(0)),         ref(integer(0)))
  expect_equal(j(character(0)),       ref(character(0)))
})

test_that("strings with special characters are escaped correctly", {
  for (s in list("with \"quote\"",
                 "with backslash \\",
                 "tab\there",
                 "new\nline",
                 "carriage\rreturn",
                 "controlbyte",
                 "unicode é 中")) {
    expect_equal(j(s, auto_unbox = TRUE),
                 ref(s, auto_unbox = TRUE),
                 info = paste("string:", s))
  }
})

test_that("top-level NULL emits {}", {
  expect_equal(j(NULL), ref(NULL))
})

test_that("unsupported types return NULL (caller falls back)", {
  # Factors must not be handled — they'd otherwise look like INTSXP.
  expect_null(j(factor(c("a", "b", "a"))))
  # Date / POSIXct have a class attribute.
  expect_null(j(as.Date("2025-01-01")))
  expect_null(j(as.POSIXct("2025-01-01", tz = "UTC")))
  # Raw bytes — jsonlite emits base64; we don't.
  expect_null(j(as.raw(c(1, 2, 3))))
  # AsIs scalar — jsonlite-specific class.
  expect_null(j(I(42L)))
  # data.frame is a classed VECSXP.
  expect_null(j(data.frame(x = 1:2, y = c("a", "b"))))
  # An environment is not a list type at all.
  expect_null(j(new.env()))
})

test_that("named-list with NA / empty key falls back", {
  # We refuse rather than silently disagree with jsonlite.
  bad1 <- setNames(list(1L, 2L), c("a", NA_character_))
  bad2 <- setNames(list(1L, 2L), c("",  "b"))
  expect_null(j(bad1))
  expect_null(j(bad2))
})

test_that("recursion limit triggers fallback", {
  # 65 levels deep — over the 64-level kMaxDepth.
  x <- 1L
  for (i in 1:70) x <- list(x)
  expect_null(j(x))
})

test_that("dr_json() routes simple shapes through the fast path", {
  # We can't directly observe which path was taken, but we can
  # verify the body matches jsonlite for both fast-path and
  # fallback inputs — that's the user-visible contract.
  fast <- dr_json(list(ok = TRUE, n = 7L))
  expect_equal(fast$body, ref(list(ok = TRUE, n = 7L)))
  expect_equal(fast$headers[["Content-Type"]], "application/json")

  # A factor forces the fallback. Should still produce valid JSON.
  fb <- dr_json(list(level = factor("low")))
  expect_equal(fb$body,
               as.character(jsonlite::toJSON(list(level = factor("low")),
                                             auto_unbox = TRUE)))
})

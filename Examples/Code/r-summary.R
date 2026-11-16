# Summarise a numeric vector.
summarise_vec <- function(x, na.rm = TRUE) {
  stopifnot(is.numeric(x))
  list(
    n = length(x),
    mean = mean(x, na.rm = na.rm),
    sd = sd(x, na.rm = na.rm),
    range = range(x, na.rm = na.rm)
  )
}

set.seed(42)
values <- c(rnorm(20, mean = 10), NA)
str(summarise_vec(values))

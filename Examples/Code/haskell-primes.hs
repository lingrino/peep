module Main where

import Data.List (unfoldr)

-- | Infinite list of primes (trial division by smaller primes).
primes :: [Integer]
primes = 2 : filter isPrime [3, 5 ..]
  where
    isPrime n = all (\p -> n `mod` p /= 0) (takeWhile (\p -> p * p <= n) primes)

collatz :: Integer -> [Integer]
collatz = unfoldr step
  where
    step 1 = Nothing
    step n = Just (n, if even n then n `div` 2 else 3 * n + 1)

main :: IO ()
main = do
  print (take 10 primes)
  print (length (collatz 27))

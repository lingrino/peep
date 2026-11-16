(ns words.core
  (:require [clojure.string :as str]))

(defn word-freq
  "Counts words, case-insensitively."
  [text]
  (->> (str/split (str/lower-case text) #"\W+")
       (remove str/blank?)
       frequencies
       (sort-by val >)))

(defn -main [& _]
  (doseq [[w n] (take 3 (word-freq "The cat and the hat and the bat"))]
    (println w n)))

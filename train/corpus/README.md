# Training corpora

- `ru_50k.txt`, `en_50k.txt` — top-50k word frequency lists from
  [hermitdave/FrequencyWords](https://github.com/hermitdave/FrequencyWords)
  (OpenSubtitles 2018), CC-BY-SA 4.0. Detected by `train.js` as
  "word count" lists and weighted by sqrt(count).

Retrain: `node ../train.js . /usr/share/dict/words <more text files...>`
(any mix of running text and frequency lists works).

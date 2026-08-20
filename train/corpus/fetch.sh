#!/bin/bash
# Downloads and normalizes the training corpora:
#   - hermitdave/FrequencyWords 50k lists (bigram/trigram weights + bloom forms)
#   - LibreOffice Hunspell dictionaries (bloom lemmas), lowercased word lists
# Usage: ./fetch.sh   then retrain with:
#   node ../train.js . /usr/share/dict/words \
#     words:ru_hunspell_words.txt words:en_hunspell_words.txt <text files...>
set -euo pipefail
cd "$(dirname "$0")"

curl -sL -o ru_50k.txt https://raw.githubusercontent.com/hermitdave/FrequencyWords/master/content/2018/ru/ru_50k.txt
curl -sL -o en_50k.txt https://raw.githubusercontent.com/hermitdave/FrequencyWords/master/content/2018/en/en_50k.txt
curl -sL https://raw.githubusercontent.com/LibreOffice/dictionaries/master/ru_RU/ru_RU.dic \
  | sed 's|/.*||' | grep -E '^[а-яёА-ЯЁ-]+$' | tr 'А-ЯЁ' 'а-яё' \
  | grep -E '^[а-яё]{2,}$' | sort -u > ru_hunspell_words.txt
curl -sL https://raw.githubusercontent.com/LibreOffice/dictionaries/master/en/en_US.dic \
  | sed 's|/.*||' | grep -E "^[a-zA-Z']+$" | tr 'A-Z' 'a-z' \
  | grep -E "^[a-z][a-z']*[a-z]$" | sort -u > en_hunspell_words.txt

wc -l ru_50k.txt en_50k.txt ru_hunspell_words.txt en_hunspell_words.txt

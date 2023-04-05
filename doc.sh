#!bash
dub build -b ddox > /dev/null \
    && dub run ddox -- generate-html --std-macros=./macros.ddoc ./docs.json docs \
    && ruby -run -ehttpd ./docs -p8081
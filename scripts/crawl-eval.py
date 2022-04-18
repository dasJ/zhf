#!/usr/bin/env nix-shell
#!nix-shell -i python3 -p python3 python3.pkgs.requests python3.pkgs.beautifulsoup4

# Crawl all infos about builds from an evaluation

import sys
import requests
from bs4 import BeautifulSoup

eval_id = sys.argv[1]

page = requests.get(f'https://hydra.nixos.org/eval/{eval_id}?full=1')
assert page.status_code == 200
soup = BeautifulSoup(page.text, 'html.parser')

builds = {}  # hold all builds by attr name to dedup them

for table in soup.find_all('tbody'):
    for row in table.find_all('tr'):
        cols = row.find_all('td')
        # Skip invalid rows
        if not cols[0].find('img'):
            continue
        builds[cols[2].find('a').get_text()] = {
            'status': cols[0].find('img')['title'],
            'build_id': cols[1].find('a').get_text(),
            'pkgname': cols[4].get_text(),
            'system': cols[5].find('tt').get_text()
        }

with open(f'data/evalcache/{eval_id}.cache', 'w') as f:
    for k,v in builds.items():
        f.write(f'{k} {v["build_id"]} {v["pkgname"]} {v["system"]} {v["status"]}\n')

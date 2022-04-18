#!/usr/bin/env nix-shell
#!nix-shell -i python3 -p python3 python3.pkgs.requests python3.pkgs.beautifulsoup4

# Crawl some data directly from the Hydra web interface since the API doesn't give us access

import sys
import requests
from bs4 import BeautifulSoup

project = sys.argv[1]
jobset = sys.argv[2]

page = requests.get(f'https://hydra.nixos.org/jobset/{project}/{jobset}/evals')
assert page.status_code == 200
soup = BeautifulSoup(page.text, 'html.parser')

eval_table = soup.find('tbody')
eval_rows = eval_table.find_all('tr')
for row in eval_rows:
    # Skip evals with unfinised builds
    remaining_builds = row.find(class_='badge-secondary')
    if remaining_builds:
        continue
    # Skip fully failed evals (no builds)
    succeeded = row.find(class_='badge-success')
    if succeeded.get_text() == 0:
        continue

    print(row.find('a').get_text(), end=' ')
    print(row.find(class_='badge-danger').get_text(), end=' ')
    print(row.find('time')['title'])
    sys.exit(0)

print('No finished eval found')
sys.exit(1)

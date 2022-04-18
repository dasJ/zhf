#!/usr/bin/env nix-shell
#!nix-shell -i python3 -p python3 python3.pkgs.requests python3.pkgs.beautifulsoup4

# Find the failed dependency IDs of a build

import sys
import requests
from bs4 import BeautifulSoup

build_id = sys.argv[1]

page = requests.get(f'https://hydra.nixos.org/build/{build_id}')
assert page.status_code == 200
soup = BeautifulSoup(page.text, 'html.parser')

builds = {}  # hold all builds by attr name to dedup them

for table in soup.find(id='tabs-buildsteps').find_all('table', class_='clickable-rows'):
    for row in table.find_all('tr'):
        cols = row.find_all('td')
        if len(cols) != 5:
            continue
        links = cols[4].find_all('a')
        wanted_link = ''
        for link in links:
            if wanted_link == '' and link.get_text() == 'log':
                wanted_link = link['href']
            # Prefer the propagated build ID
            if link.get_text().startswith('build '):
                wanted_link = link['href']
        if wanted_link == '':
            continue
        print(wanted_link.split('/')[4], end=' ')

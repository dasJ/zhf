#!/usr/bin/env nix-shell
#!nix-shell -i python3 -p python3 python3.pkgs.requests python3.pkgs.beautifulsoup4

# Find the failed dependency storepath basenames of a build

import os
import sys
import requests
from bs4 import BeautifulSoup

build_id = sys.argv[1]

page = requests.get(f'https://hydra.nixos.org/build/{build_id}')
assert page.status_code == 200
soup = BeautifulSoup(page.text, 'html.parser')
arch = soup.find(class_='info-table').find_all('tr')[2].find('tt').get_text()
found_store_paths = []

for table in soup.find(id='tabs-buildsteps').find_all('table', class_='clickable-rows'):
    for row in table.find_all('tr'):
        cols = row.find_all('td')
        if len(cols) != 5:
            continue
        if 'Failed' not in cols[4].get_text() and 'Cached' not in cols[4].get_text():
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
        store_path = cols[1].find('tt').get_text().split(',')[0]
        if store_path in found_store_paths:
            continue
        found_store_paths += [store_path]
        pathname = os.path.basename(store_path[44:])
        build_id = wanted_link.split('/')[4]
        print(f'{pathname};{arch};{build_id}', end=' ')

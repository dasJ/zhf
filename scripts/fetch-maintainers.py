#!/usr/bin/env nix-shell
#!nix-shell -i python3 -p python3 python3.pkgs.multiprocess python3.pkgs.GitPython



import os
import git
from multiprocessing import Pool, Manager
import subprocess
import ast
import sys


def clone_nixpkgs(rev, nixos):
    owd = os.getcwd()
    os.system("mkdir -p data/nixpkgs")
    os.chdir("data/nixpkgs")
    repo = git.Repo.init()
    try:
        origin = repo.create_remote("origin", "https://github.com/NixOS/nixpkgs.git")
    except:
        # remote already exists
        origin = repo.remotes.origin
        origin.set_url("https://github.com/NixOS/nixpkgs.git")
    print(f"Cloning revision {rev} into data/nixpkgs...")
    origin.fetch(refspec=rev)
    repo.git.reset(rev, hard=True)
    if nixos:
        print("Applying do_not_remove_maintainers.patch to nixos/release-combined.nix...")
        repo.git.apply(f"{owd}/scripts/do_not_remove_maintainers.patch")
    os.chdir(owd)


def find_maintainer_for_job(job_name, nixos, res, job_maintainers):
    name_without_arch = ".".join(job_name.split(".")[:-1])
    real_job_name = job_name
    if not nixos:
        real_job_name = ".".join(real_job_name.split(".")[1:])
    if nixos:
        file_to_evaluate = "./data/nixpkgs/nixos/release-combined.nix"
    else:
        file_to_evaluate = "./data/nixpkgs/pkgs/top-level/release.nix"
    try:
        if name_without_arch not in job_maintainers.keys():
           r = ast.literal_eval(subprocess.check_output(f"nix eval --json -f {file_to_evaluate} {real_job_name}.meta.maintainers 2> /dev/null", shell=True).decode("utf-8"))
           job_maintainers[name_without_arch] = r
           res[job_name] = r
        else:
           res[job_name] = job_maintainers[name_without_arch]

    except Exception as _:
        res[job_name] = ["error"]



def main(evals):
    with Manager() as mgr:
        for ev in evals:
            res = mgr.dict({})
            job_maintainers = mgr.dict({})

            clone_nixpkgs(ev[1], ev[2])
            f = open(f"data/evalcache/{ev[0]}.cache")
            jobs = []
            jobs_info = {}
            for line in f.readlines():
                status  = line.split(" ")
                if "failed" in status[-1].strip().lower():
                    job_name = status[0].strip()
                    if not ev[2]:
                        job_name = f"nixpkgs.{job_name}"
                    jobs.append((job_name, ev[2], res, job_maintainers))
                    jobs_info[job_name] = status[1:]
            with Pool() as p:
                p.starmap(find_maintainer_for_job, jobs)

            f = open(f"data/maintainerscache/{ev[0]}.cache", "a")
            for (k, v) in res.items():
                if v == []:
                    f.write(f"_ {k} {' '.join(jobs_info[k])}")
                for maint in v:
                    if maint != "error":
                        f.write(f"{maint['github']} {k} {' '.join(jobs_info[k])}")
                    else:
                        f.write(f"_ {k} {' '.join(jobs_info[k])}")

if __name__ == '__main__':
    args = sys.argv[1:]
    to_pass = []
    while args:
        eval_id = args.pop(0)
        commit_hash = args.pop(0)
        is_nixos = args.pop(0) == "1"
        to_pass += [(eval_id, commit_hash, is_nixos)]
    main(to_pass)

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
    os.system("rm -rf data/nixpkgs")
    os.system("mkdir -p data/nixpkgs")
    os.chdir("data/nixpkgs")
    repo = git.Repo.init()
    origin = repo.create_remote("origin", "https://github.com/NixOS/nixpkgs.git")
    print(f"Cloning revision {rev} into data/nixpkgs...")
    origin.fetch(refspec=rev, depth=1)
    repo.create_head("master", "FETCH_HEAD")  # create local branch "master" from remote "master"
    repo.heads.master.checkout()
    if nixos:
        print("Applying do_not_remove_maintainers.patch to nixos/release-combined.nix...")
        repo.git.apply("../../scripts/do_not_remove_maintainers.patch")
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



def main(eval_nb_nixos, rev_nixos, eval_nb_nixpkgs, rev_nixpkgs):
    with Manager() as mgr:
        res_nixos = mgr.dict({})
        res_nixpkgs = mgr.dict({})
        job_maintainers = mgr.dict({})
        clone_nixpkgs(rev_nixos, True)
        f = open(f"data/evalcache/{eval_nb_nixos}.cache")
        jobs = []
        jobs_info = {}
        for line in f.readlines():
            status  = line.split(" ")
            if "failed" in status[-1].strip().lower():
                job_name = status[0].strip()
                jobs.append((job_name, True, res_nixos, job_maintainers))
                jobs_info[job_name] = status[1:]
        with Pool() as p:
            p.starmap(find_maintainer_for_job, jobs)

        clone_nixpkgs(rev_nixpkgs, False)
        f = open(f"data/evalcache/{eval_nb_nixpkgs}.cache")
        jobs = []
        for line in f.readlines():
            status  = line.split(" ")
            if "failed" in status[-1].strip().lower():
                job_name = status[0].strip()
                job_name = f"nixpkgs.{job_name}"
                jobs.append((job_name, False, res_nixpkgs, job_maintainers))
                jobs_info[job_name] = status[1:]
        with Pool() as p:
            p.starmap(find_maintainer_for_job, jobs)

        


        f = open(f"data/maintainerscache/{eval_nb_nixos}.cache", "a")
        for (k, v) in res_nixos.items():
            if v == []:
                f.write(f"_ {k}  {' '.join(jobs_info[k])}")
            for maint in v:
                if maint != "error":
                    f.write(f"{maint['github']} {k} {' '.join(jobs_info[k])}")
                else:
                    f.write(f"_ {k}  {' '.join(jobs_info[k])}")

        f = open(f"data/maintainerscache/{eval_nb_nixpkgs}.cache", "a")
        for (k, v) in res_nixpkgs.items():
            if v == []:
                f.write(f"_ {k} {' '.join(jobs_info[k])}")
            for maint in v:
                if maint != "error":
                    f.write(f"{maint['github']} {k} {' '.join(jobs_info[k])}")
                else:
                    f.write(f"_ {k} {' '.join(jobs_info[k])}")





if __name__ == '__main__':
    args = sys.argv[1].split(" ")[1:]
    main(args[0], args[1], args[2], args[3])


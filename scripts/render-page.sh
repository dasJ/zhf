#!/usr/bin/env bash

set -euo pipefail

cd "$(dirname "$(dirname "$(readlink -f "${0}")")")" || exit 122

rm -rf public
mkdir -p public
if ! [[ -d data ]]; then
	mkdir -p data
fi

runRust() {
	bin="${1}"
	shift
	RUST_LOG=info nix-shell -p openssl pkg-config --run "cargo r --bin ${bin} --quiet --release -- ${*}"
}

# Gather data
targetBranch=master
case "${targetBranch}" in
	release-*)
		nixosJobset="${targetBranch}"
		nixpkgsJobset="nixpkgs-${targetBranch##*-}-darwin"
		;;
	*)
		nixosJobset=trunk-combined
		nixpkgsJobset=trunk
		;;
esac
echo "Target branch is ${targetBranch} (jobsets ${nixosJobset} and ${nixpkgsJobset})"

echo "Asking Hydra about nixos..."
read -r lastLinuxEvalNo linuxBuildFailures lastLinuxEvalTime <<< "$(set -e; runRust crawl_jobset nixos "${nixosJobset}")"
touch data/history-linux
if ! grep ^"${lastLinuxEvalNo} " data/history-linux; then
	echo "${lastLinuxEvalNo} ${linuxBuildFailures} ${lastLinuxEvalTime}" >> data/history-linux
fi

echo "Asking Hydra about nixpkgs..."
read -r lastDarwinEvalNo darwinBuildFailures lastDarwinEvalTime <<< "$(set -e; runRust crawl_jobset nixpkgs "${nixpkgsJobset}")"
touch data/history-darwin
if ! grep ^"${lastDarwinEvalNo} " data/history-darwin; then
	echo "${lastDarwinEvalNo} ${darwinBuildFailures} ${lastDarwinEvalTime}" >> data/history-darwin
fi

lastCheck="$(date --utc '+%Y-%m-%d %H:%M:%S (UTC)')"
triggeredBy="${CI_PIPELINE_SOURCE:-???}"

evalIdsUnsorted=("${lastLinuxEvalNo}" "${lastDarwinEvalNo}")
IFS=$'\n' evalIds=($(sort <<<"${evalIdsUnsorted[*]}"))
unset IFS

echo "Evaluations are ${evalIds[*]}"

echo "Crawling evals..."
args=()
for evaluation in "${evalIds[@]}"; do
	if [[ "${evaluation}" = "${lastDarwinEvalNo}" ]]; then
		args+=("${evaluation}")
		args+=("false")
	else
		args+=("${evaluation}")
		args+=("true")
	fi
done
runRust crawl_evals "${args[@]}"


echo "Calculating failing builds by platform..."
declare -A systems
mkdir -p data/failcache
if ! [ -f "data/failcache/${evalIds[*]}.cache" ]; then
	# Dedup by attrpath
	declare -A builds
	for evaluation in "${evalIds[@]}"; do
		while read -r attrpath data; do
			builds["$attrpath"]="$data"
		done < "data/evalcache/${evaluation}.cache"
	done
	# Count by system
	for val in "${builds[@]}"; do
		if [ -z "${val}" ]; then
			continue
		fi
		read -r _ _ system result <<< "${val}"
		if [ "${result}" = Succeeded ]; then
			continue
		fi
		if [ -v systems["${system}"] ]; then
			systems["${system}"]=$((systems[$system] + 1))
		else
			systems["${system}"]=1
		fi
	done
	for system in "${!systems[@]}"; do
		echo "${system} ${systems["${system}"]}" >> "data/failcache/${evalIds[*]}.cache.new"
	done
	mv "data/failcache/${evalIds[*]}.cache.new" "data/failcache/${evalIds[*]}.cache"
else
	while IFS=' ' read -r system num; do
		systems["${system}"]="${num}"
	done < "data/failcache/${evalIds[*]}.cache"
fi
# Clean cache
for file in data/failcache/*; do
	num="$(basename "${file}" .cache)"
	if [[ ! " ${evalIds[*]} " =~ " ${num} " ]]; then
		echo "Purging fail cache of ${num}"
		rm "${file}"
	fi
done

# Calculate sums
failingBuildsTable=
totalBuildFailures=0
IFS=$'\n' systemNamesSorted=($(sort <<<"${!systems[*]}"))
unset IFS
for system in "${systemNamesSorted[@]}"; do
	failingBuildsTable+="<tr><td>Failing builds on ${system}:</td><td><b>${systems["${system}"]}</b></td></tr>"
	totalBuildFailures="$((totalBuildFailures + ${systems["${system}"]}))"
done

echo "Calculating charts..."
linuxBurndown="$(
	while read -r _ failed date; do
		if [ -z "${failed}" ]; then
			continue
		fi
		echo -n "{ x: '$(date -d "${date}" '+%Y-%m-%dT%H:%M:%S')', y: '${failed}' },"
    done <<< "$(sort data/history-linux)"
)"
darwinBurndown="$(
	while read -r _ failed date; do
		if [ -z "${failed}" ]; then
			continue
		fi
		echo -n "{ x: '$(date -d "${date}" '+%Y-%m-%dT%H:%M:%S')', y: '${failed}' },"
    done <<< "$(sort data/history-darwin)"
)"

echo "Fetching maintainers..."
declare -A maintainers
mkdir -p data/maintainerscache
args=()
if [ ! -e "data/maintainerscache/${lastLinuxEvalNo}.cache" ] || [ ! -e "data/maintainerscache/${lastDarwinEvalNo}.cache" ]; then
	for evaluation in "${evalIds[@]}"; do
		if ! [ -f "data/maintainerscache/${evaluation}.cache" ]; then
			nixpkgsCommit="$(curl -fsH 'Accept: application/json' "https://hydra.nixos.org/eval/${evaluation}" | jq -r .jobsetevalinputs.nixpkgs.revision)"
			args+=("${evaluation}" "${nixpkgsCommit}")
			if [[ "${evaluation}" = "${lastDarwinEvalNo}" ]]; then
				args+=(0)
			else
				args+=(1)
			fi
		fi
done
./scripts/fetch-maintainers.py "${args[@]}"
fi
for evaluation in "${evalIds[@]}"; do
	while IFS=' ' read -r maint rest; do
			maintainers["${maint}"]+=";${rest}"
	done < "data/maintainerscache/${evaluation}.cache"
done
# Clean cache
for file in data/maintainerscache/*; do
	num="$(basename "${file}" .cache)"
	if [[ ! " ${evalIds[*]} " =~ " ${num} " ]]; then
		echo "Purging maintainers cache of ${num}"
		rm "${file}"
	fi
done


echo "Rendering maintainer pages..."
runRust maintainer_pages "${evalIds[@]}"

echo "Finding most important dependencies..."
runRust most_important_deps "${evalIds[@]}"

echo "Rendering most important builds..."
lines="$(sort -n data/mostimportantcache/*.cache | uniq -c | sort -n | tail -n30 | tac | sed 's/^ *//g')"
mostProblematicDeps=
while IFS=' ' read -r count parts; do
	IFS=';' read -r name system buildid <<< "${parts}"
	mostProblematicDeps+="<tr><td><details><summary><a href=\"https://hydra.nixos.org/build/${buildid}\">${name}</a></summary><ul>"
	mostProblematicDeps+="$(grep -h "^${buildid};" data/depcache/* | sort | awk -F ';' '{print "<li><a href=\"https://hydra.nixos.org/build/" $3 "\">" $2 "</a></li>"}' | tr -d '\n')" || :
	mostProblematicDeps+="</ul></details></td><td>${system}</td><td>${count}</td></tr>"
done <<< "${lines}"

# Render page
cp -r page/* public/
sed -i \
	-e "s/@targetbranch@/${targetBranch}/g" \
	-e "s/@lastlinuxevalno@/${lastLinuxEvalNo}/g" \
	-e "s/@lastlinuxevaltime@/${lastLinuxEvalTime}/g" \
	-e "s/@lastdarwinevalno@/${lastDarwinEvalNo}/g" \
	-e "s/@lastdarwinevaltime@/${lastDarwinEvalTime}/g" \
	-e "s/@linuxbuildfailures@/${linuxBuildFailures}/g" \
	-e "s/@darwinbuildfailures@/${darwinBuildFailures}/g" \
	-e "s/@totalbuildfailures@/${totalBuildFailures}/g" \
	-e "s@failingbuildstable@${failingBuildsTable}g" \
	-e "s/@linuxburndown@/${linuxBurndown}/g" \
	-e "s/@darwinburndown@/${darwinBurndown}/g" \
	-e "s/@lastcheck@/${lastCheck}/g" \
	-e "s/@triggered@/${triggeredBy}/g" \
	-e "s@mostproblematicdeps@${mostProblematicDeps}g" \
	public/index.html

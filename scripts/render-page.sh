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
targetBranch=release-24.05
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
read -r lastLinuxEvalNo lastLinuxEvalTime <<< "$(set -e; runRust crawl_jobset nixos "${nixosJobset}")"

echo "Asking Hydra about nixpkgs..."
read -r lastDarwinEvalNo lastDarwinEvalTime <<< "$(set -e; runRust crawl_jobset nixpkgs "${nixpkgsJobset}")"

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
		# Ignore cancelled jobs so cancelling an eval doesn't spike the graph
		if [[ "${result}" = Succeeded ]] || [[ "${result}" = Cancelled ]]; then
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

# Insert historical data
touch data/history-linux data/history-darwin
if ! grep ^"${lastLinuxEvalNo} " data/history-linux; then
	nFails=0
	for system in "${!systems[@]}"; do
		if [[ "${system}" = *'-linux' ]]; then
			nFails=$((nFails + ${systems["${system}"]}))
		fi
	done
	echo "${lastLinuxEvalNo} ${nFails} ${lastLinuxEvalTime}" >> data/history-linux
fi

if ! grep ^"${lastDarwinEvalNo} " data/history-darwin; then
	nFails=0
	for system in "${!systems[@]}"; do
		if [[ "${system}" = *'-darwin' ]]; then
			nFails=$((nFails + ${systems["${system}"]}))
		fi
	done
	echo "${lastDarwinEvalNo} ${nFails} ${lastDarwinEvalTime}" >> data/history-darwin
fi

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

echo "Finding staging merges..."
git --git-dir data/nixpkgs/.git fetch origin master
if ! [[ -f data/staging-history ]]; then
	# Some random blessed staging merge to prime the history
	echo 'cf7f4393f3f953faf5765c7a0168c6710baa1423 1665443579' > data/staging-history
fi
lastStagingMerge="$(tail -n1 data/staging-history | cut -d' ' -f1)"
git --git-dir data/nixpkgs/.git log --reverse "${lastStagingMerge}..origin/master" --grep='Merge.*staging-next' --first-parent --format=%H\ %at >> data/staging-history
stagingMerges=
while IFS=' ' read -r hash date; do
	stagingMerges+=", 'staging-${hash}': {"
	stagingMerges+="type: 'line', borderColor: 'orange', borderWidth: 2, borderDash: [5,5], scaleID: 'xAxis', "
	stagingMerges+="value: '$(date -d "@${date}" '+%Y-%m-%dT%H:%M:%S')'"
	stagingMerges+="}"
	stagingMerges+=$'\n'
done < data/staging-history

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
	-e "s/@totalbuildfailures@/${totalBuildFailures}/g" \
	-e "s@failingbuildstable@${failingBuildsTable}g" \
	-e "s/@linuxburndown@/${linuxBurndown}/g" \
	-e "s/@darwinburndown@/${darwinBurndown}/g" \
	-e "s/@lastcheck@/${lastCheck}/g" \
	-e "s/@triggered@/${triggeredBy}/g" \
	public/index.html

echo "${stagingMerges}" | sed -i -e '/@stagingMerges@/{
r /dev/stdin
d
}' public/index.html

echo "${mostProblematicDeps}" | sed -i -e '/@mostproblematicdeps@/{
r /dev/stdin
d
}' public/index.html

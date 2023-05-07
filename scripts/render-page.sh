#!/usr/bin/env bash

set -euo pipefail

cd "$(dirname "$(dirname "$(readlink -f "${0}")")")" || exit 122

rm -rf public
mkdir -p public
#ln -s /var/lib/zhf data

# Gather data
targetBranch=release-23.05
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
read -r lastLinuxEvalNo linuxBuildFailures lastLinuxEvalTime <<< "$(./scripts/crawl-jobset.py nixos "${nixosJobset}")"
touch data/history-linux
if ! grep ^"${lastLinuxEvalNo} " data/history-linux; then
	echo "${lastLinuxEvalNo} ${linuxBuildFailures} ${lastLinuxEvalTime}" >> data/history-linux
fi

echo "Asking Hydra about nixpkgs..."
read -r lastDarwinEvalNo darwinBuildFailures lastDarwinEvalTime <<< "$(./scripts/crawl-jobset.py nixpkgs "${nixpkgsJobset}")"
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
mkdir -p data/evalcache
for evaluation in "${evalIds[@]}"; do
	if ! [ -f "data/evalcache/${evaluation}.cache" ]; then
		echo "Crawling evaluation ${evaluation}..."
		scripts/crawl-eval.py "${evaluation}"
	fi
done

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
args=""
for evaluation in "${evalIds[@]}"; do
	if ! [ -f "data/maintainerscache/${evaluation}.cache" ]; then
		nixpkgsCommit="$(curl -fsH 'Accept: application/json' "https://hydra.nixos.org/eval/${evaluation}" | jq -r .jobsetevalinputs.nixpkgs.revision)"
		args="${args} ${evaluation} ${nixpkgsCommit}"
	fi
done
./scripts/fetch-maintainers.py "$args"
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
mkdir -p public/failed/by-maintainer
for maintainer in "${!maintainers[@]}"; do
	unset builds
	declare -a builds
	IFS=';' read -r -a buildsUnsorted <<< "${maintainers["${maintainer}"]}"
	IFS=$'\n' builds=($(sort <<<"${buildsUnsorted[*]}"))
	unset IFS
	prettyName="${maintainer}"
	if [ "${prettyName}" = _ ]; then
		prettyName="nobody"
	fi
	cat <<EOF > "public/failed/by-maintainer/${maintainer}.html"
<!DOCTYPE html>
<html lang="en">
  <head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <meta http-equiv="X-UA-Compatible" content="ie=edge">
    <title>Hydra failures (${prettyName})</title>
    <link rel="stylesheet" href="../../style.css">
    <link rel="icon" type="image/x-icon" href="../../favicon.ico">
    <meta property="og:title" content="Per-maintainer Hydra failures" />
    <meta property="og:description" content="Track Hydra failures that have ${prettyName} as their maintainer" />
    <meta property="og:type" content="website" />
    <meta property="og:url" content="https://zh.fail/failed/by-maintainer/${maintainer}.html" />
    <meta property="og:image" content="../../icon.png" />
  </head>
  <body id="maintainer-body">
    <h1><a href="../../index.html" title="Go Home"><img src="../../nix-snowflake.svg"></a>Hydra failures for packages maintained by ${prettyName}</h1>
      <p>Jump to: <a href="#direct">Direct Failures</a>&nbsp;&bull;&nbsp;<a href="#indirect">Indirect Failures</a></p>
      <h2 id="direct">Direct failures</h2>
      <p>These are packages fail to build themselves.</p>
      <table>
        <thead><tr><th>Attribute</th><th>Job name</th><th>Platform</th><th>Result</th></th></thead>
        <tbody>
EOF
	found=0
	for build in "${builds[@]}"; do
		IFS=' ' read -r attr buildid name system status <<< "${build}"
		if [ "${status}" = 'Dependency failed' ]; then
			continue
		fi
		found=1
		echo "<tr><td><a href=\"https://hydra.nixos.org/build/${buildid}\">${attr}</a></td><td>${name}</td><td>${system}</td><td>${status}</td></tr>" >> "public/failed/by-maintainer/${maintainer}.html"
	done
	if [ "${found}" = 0 ]; then
		echo 'None 🎉' >> "public/failed/by-maintainer/${maintainer}.html"
	fi
	cat <<EOF >> "public/failed/by-maintainer/${maintainer}.html"
      </tbody>
    </table>
    <p>Jump to: <a href="#direct">Direct Failures</a>&nbsp;&bull;&nbsp;<a href="#indirect">Indirect Failures</a></p>
    <h2 id="indirect">Indirect failures</h2>
    <p>These are packages where a dependency failed to build.<br></p>
    <table>
      <thead><tr><th>Attribute</th><th>Job name</th><th>Platform</th><th>Result</th></th></thead>
      <tbody>
EOF
	found=0
	for build in "${builds[@]}"; do
		IFS=' ' read -r attr buildid name system status <<< "${build}"
		if [ "${status}" != 'Dependency failed' ]; then
			continue
		fi
		found=1
		echo "<tr><td><a href=\"https://hydra.nixos.org/build/${buildid}\">${attr}</a></td><td>${name}</td><td>${system}</td><td>${status}</td></tr>" >> "public/failed/by-maintainer/${maintainer}.html"
	done
	if [ "${found}" = 0 ]; then
		echo '<tr><td colspan="4" class="none">None 🎉</td></tr>' >> "public/failed/by-maintainer/${maintainer}.html"
	fi
	cat <<EOF >> "public/failed/by-maintainer/${maintainer}.html"
      </tbody>
    </table>
  </body>
</html>
EOF
done

cat <<EOF > "public/failed/overview.html"
<!DOCTYPE html>
<html lang="en">
  <head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <meta http-equiv="X-UA-Compatible" content="ie=edge">
    <title>Hydra failures by maintainer</title>
    <link rel="stylesheet" href="../style.css">
    <link rel="icon" type="image/x-icon" href="../favicon.ico">
    <meta property="og:title" content="Hydra failures by maintainer" />
    <meta property="og:description" content="Overview of maintainers of broken Hydra packages" />
    <meta property="og:type" content="website" />
    <meta property="og:url" content="https://zh.fail/failed/overview.html" />
    <meta property="og:image" content="../icon.png" />
  </head>
  <body id="maintainer-overview">
    <h1><a href="../index.html" title="Go Home"><img src="../nix-snowflake.svg"></a>Hydra failures by maintainer</h1>
    <p>If your name is not in this list, then you don't maintain any failed packages. Congratulations!</p>
    <ul>
EOF
IFS=$'\n' maintainerNames=($(sort <<<"${!maintainers[@]}"))
unset IFS
for maintainer in "${maintainerNames[@]}"; do
	if [ "${maintainer}" = _ ]; then
		continue
	fi
	declare -a builds
	IFS=';' read -r -a builds <<< "${maintainers["${maintainer}"]}"
	echo "<li><a href='by-maintainer/${maintainer}.html'>${maintainer}</a> (${#builds[@]})</li>" >> "public/failed/overview.html"
done
cat <<EOF >> "public/failed/overview.html"
    </ul>
  </body>
</html>
EOF

cat <<EOF > "public/failed/all.html"
<!DOCTYPE html>
<html lang="en">
  <head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <meta http-equiv="X-UA-Compatible" content="ie=edge">
    <title>All Hydra failures</title>
    <link rel="stylesheet" href="../style.css">
    <link rel="icon" type="image/x-icon" href="../favicon.ico">
    <meta property="og:title" content="All Hydra failures" />
    <meta property="og:description" content="Overview of all Hydra failures of the most recent evaluations" />
    <meta property="og:type" content="website" />
    <meta property="og:url" content="https://zh.fail/failed/all.html" />
    <meta property="og:image" content="../icon.png" />
  </head>
  <body>
    <h1><a href="../index.html" title="Go Home"><img src="../nix-snowflake.svg"></a>All Hydra failures</h1>
    <p>Jump to: <a href="#direct">Direct Failures</a>&nbsp;&bull;&nbsp;<a href="#indirect">Indirect Failures</a></p>
    <h2 id="direct">Direct failures</h2>
    <p>These are packages fail to build themselves.</p>
    <table>
        <thead><tr><th>Attribute</th><th>Job name</th><th>Platform</th><th>Maintainer</th><th>Result</th></th></thead>
        <tbody>
EOF
found=0
while IFS=' ' read -r maintainer attr buildid name system status; do
	if [ "${status}" = 'Dependency failed' ]; then
		continue
	fi
	if [ "${maintainer}" = _ ]; then
		maintainer=
	fi
	found=1
	echo "<tr><td><a href=\"https://hydra.nixos.org/build/${buildid}\">${attr}</a></td><td>${name}</td><td>${system}</td><td>${maintainer}</td><td>${status}</td></tr>" >> "public/failed/all.html"
done <<< "$(sort -k2 data/maintainerscache/*)"
if [ "${found}" = 0 ]; then
	echo '<tr><td colspan="5" class="none">None 🎉</td></tr>' >> "public/failed/all.html"
fi
cat <<EOF >> "public/failed/all.html"
  </tbody>
</table>
<p>Jump to: <a href="#direct">Direct Failures</a>&nbsp;&bull;&nbsp;<a href="#indirect">Indirect Failures</a></p>
<h2 id="indirect">Indirect failures</h2>
<p>These are packages where a dependency failed to build.<br></p>
<table>
  <thead><tr><th>Attribute</th><th>Job name</th><th>Platform</th><th>Result</th></th></thead>
  <tbody>
EOF
found=0
while IFS=' ' read -r maintainer attr buildid name system status; do
	if [ "${status}" != 'Dependency failed' ]; then
		continue
	fi
	if [ "${maintainer}" = _ ]; then
		maintainer=
	fi
	found=1
	echo "<tr><td><a href=\"https://hydra.nixos.org/build/${buildid}\">${attr}</a></td><td>${name}</td><td>${system}</td><td>${maintainer}</td><td>${status}</td></tr>" >> "public/failed/all.html"
done <<< "$(sort -k2 data/maintainerscache/*)"
if [ "${found}" = 0 ]; then
	echo '<tr><td colspan="5" class="none">None 🎉</td></tr>' >> "public/failed/all.html"
fi
cat <<EOF >> "public/failed/all.html"
      </tbody>
    </table>
  </body>
</html>
EOF

echo "Finding most important dependencies..."
declare -A mostImportantBuilds
mkdir -p data/mostimportantcache
for evaluation in "${evalIds[@]}"; do
	rm -f "data/mostimportantcache/${evaluation}.cache.new"
	if ! [ -f "data/mostimportantcache/${evaluation}.cache" ]; then
		while IFS=' ' read -r attr buildid name system status; do
			if [ "${status}" != 'Dependency failed' ]; then
				continue
			fi
			IFS=' ' read -r -a depnames <<< "$(scripts/find-failed-deps.py "${buildid}")"
			for depname in "${depnames[@]}"; do
				if [ -v mostImportantBuilds["${depname}"] ]; then
					mostImportantBuilds["${depname}"]="$((mostImportantBuilds["${depname}"] + 1))"
				else
					mostImportantBuilds["${depname}"]=1
				fi
				echo "${depname}" >> "data/mostimportantcache/${evaluation}.cache.new"
			done
		done < "data/evalcache/${evaluation}.cache"
		mv "data/mostimportantcache/${evaluation}.cache.new" "data/mostimportantcache/${evaluation}.cache"
	else
		while IFS= read -r line; do
			if [ -v mostImportantBuilds["${line}"] ]; then
				mostImportantBuilds["${line}"]="$((mostImportantBuilds["${line}"] + 1))"
			else
				mostImportantBuilds["${line}"]=1
			fi
		done < "data/mostimportantcache/${evaluation}.cache"
	fi
done
# Clean cache
for file in data/mostimportantcache/*; do
	num="$(basename "${file}" .cache)"
	if [[ ! " ${evalIds[*]} " =~ " ${num} " ]]; then
		echo "Purging most important cache of ${num}"
		rm "${file}"
	fi
done

echo "Rendering most important builds..."
lines="$(sort -n data/mostimportantcache/*.cache | uniq -c | sort -n | tail -n30 | tac | sed 's/^ *//g')"
mostProblematicDeps=
while IFS=' ' read -r count parts; do
	IFS=';' read -r name system buildid <<< "${parts}"
	mostProblematicDeps+="<tr><td><a href=\"https://hydra.nixos.org/build/${buildid}\">${name}</a></td><td>${system}</td><td>${count}</td></tr>"
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

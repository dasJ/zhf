#!/usr/bin/env bash

set -euo pipefail

cd "$(dirname "$(dirname "$(readlink -f "${0}")")")" || exit 122

rm -rf public
mkdir public data

# Gather data
targetBranch=master # TODO softcode
case "${targetBranch}" in
	master)
		nixosJobset=trunk-combined
		nixpkgsJobset=trunk
		;;
	release-*)
		nixosJobset="${targetBranch}"
		nixpkgsJobset="nixpkgs-${targetBranch##*-}-darwin"
		;;
esac
echo "Target branch is ${targetBranch} (jobsets ${nixosJobset} and ${nixpkgsJobset})"

echo "Asking Hydra about nixos..."
read -r lastLinuxEvalNo linuxBuildFailures lastLinuxEvalTime <<< "$(./scripts/crawl-jobset.py nixos "${nixosJobset}")"
touch data/history-linux
if [ "${lastLinuxEvalNo}" != "$(tail -n1 data/history-linux | cut -d' ' -f1)" ]; then
	echo "${lastLinuxEvalNo} ${linuxBuildFailures} ${lastLinuxEvalTime}" >> data/history-linux
fi

echo "Asking Hydra about nixpkgs..."
read -r lastDarwinEvalNo darwinBuildFailures lastDarwinEvalTime <<< "$(./scripts/crawl-jobset.py nixpkgs "${nixpkgsJobset}")"
touch data/history-darwin
if [ "${lastDarwinEvalNo}" != "$(tail -n1 data/history-darwin | cut -d' ' -f1)" ]; then
	echo "${lastDarwinEvalNo} ${darwinBuildFailures} ${lastDarwinEvalTime}" >> data/history-darwin
fi

lastCheck="$(date --utc '+%Y-%m-%d %H:%M:%S (UTC)')"

evalIdsUnsorted=("${lastLinuxEvalNo}" "${lastDarwinEvalNo}")
IFS=$'\n' evalIds=($(sort <<<"${evalIdsUnsorted[*]}"))
unset IFS

echo "Crawling evals..."
for evaluation in "${evalIds[@]}"; do
	if ! [ -f "data/evalcache/${evaluation}.cache" ]; then
		echo "Crawling evaluation ${evaluation}..."
		scripts/crawl-eval.py "${evaluation}"
	fi
done

echo "Calculating failing builds by platform..."
declare -A systems
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
		echo "${system} ${systems["${system}"]}" >> "data/failcache/${evalIds[*]}.cache"
	done
else
	while IFS=' ' read -r system num; do
		systems["${system}"]="${num}"
	done < "data/failcache/${evalIds[*]}.cache"
fi

# Calculate sums
failingBuildsTable=
totalBuildFailures=0
for system in "${!systems[@]}"; do
	failingBuildsTable+="      Failing builds on ${system}: <b>${systems["${system}"]}</b>\n"
	totalBuildFailures="$((totalBuildFailures + ${systems["${system}"]}))"
done

echo "Calculating charts..."
linuxBurndown="$(
	while read -r _ failed date; do
		echo -n "{ x: '$(date -d "${date}" '+%Y-%m-%dT%H:%M:%S')', y: '${failed}' },"
	done < data/history-linux
)"
darwinBurndown="$(
	while read -r _ failed date; do
		echo -n "{ x: '$(date -d "${date}" '+%Y-%m-%dT%H:%M:%S')', y: '${failed}' },"
	done < data/history-darwin
)"

echo "Fetching maintainers..."
declare -A maintainers
for evaluation in "${evalIds[@]}"; do
	nixpkgsCommit="$(curl -fsH 'Accept: application/json' "https://hydra.nixos.org/eval/${evaluation}" | jq -r .jobsetevalinputs.nixpkgs.revision)"
	if ! [ -f "data/maintainerscache/${evaluation}.cache" ]; then
		pushd data/nixpkgs
		git fetch origin "${nixpkgsCommit}"
		git checkout "${nixpkgsCommit}"
		while IFS=' ' read -r attr buildid name system status; do
			if [ "${status}" = Succeeded ]; then
				continue
			fi
			attr="${attr%.*}"
			IFS=' ' read -r -a maint <<< "$(nix eval --raw '(builtins.concatStringsSep " " (builtins.concatLists (map (x: let maint = import ./maintainers/maintainer-list.nix; in builtins.filter (x: x != "") (map (y: if maint.${y} == x then y else "") (builtins.attrNames maint))) (import ./. {}).'"${attr}"'.meta.maintainers or [])))')"
			if [ -z "${maint:-}" ] || [ "${#maint}" = 0 ]; then
				maint=(_)
			fi
			for maint2 in "${maint[@]}"; do
				maintainers["${maint2}"]+=";${buildid} ${name} ${system} ${status}"
				echo "${maint2} ${buildid} ${name} ${system} ${status}" >> "../maintainerscache/${evaluation}.cache"
			done
		done < "../evalcache/${evaluation}.cache"
		popd
	else
		while IFS=' ' read -r maint rest; do
			maintainers["${maint}"]+=";${rest}"
		done < "data/maintainerscache/${evaluation}.cache"
	fi
done

echo "Rendering maintainer pages..."
mkdir -p public/failed/by-maintainer
cat <<EOF > "public/failed/all.html"
<!DOCTYPE html>
<html lang="en">
  <head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <meta http-equiv="X-UA-Compatible" content="ie=edge">
    <title>All Hydra failures</title>
  </head>
  <body>
    <h1>All Hydra failures</h1>
    <table>
EOF
cat <<EOF > "public/failed/overview.html"
<!DOCTYPE html>
<html lang="en">
  <head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <meta http-equiv="X-UA-Compatible" content="ie=edge">
    <title>Hydra failures by maintainer</title>
  </head>
  <body>
    <h1>Hydra failures for packages by maintainer</h1>
    <ul>
EOF
for maintainer in "${!maintainers[@]}"; do
	IFS=';' read -r -a builds <<< "${maintainers["${maintainer}"]}"
	prettyName="${maintainer}"
	if [ "${prettyName}" = _ ]; then
		prettyName="nobody"
	else
		echo "<li><a href='by-maintainer/${maintainer}.html'>${maintainer}</a></li>" >> "public/failed/overview.html"
	fi
	cat <<EOF > "public/failed/by-maintainer/${maintainer}.html"
<!DOCTYPE html>
<html lang="en">
  <head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <meta http-equiv="X-UA-Compatible" content="ie=edge">
    <title>Hydra failures (${prettyName})</title>
  </head>
  <body>
    <h1>Hydra failures for packages of ${prettyName}</h1>
      <table>
EOF
	for build in "${builds[@]}"; do
		IFS=' ' read -r buildid name system status <<< "${build}"
		echo "<tr><td><a href=\"https://hydra.nixos.org/build/${buildid}\">${name}</a></td><td>${system}</td><td>${status}</td></tr>" >> "public/failed/by-maintainer/${maintainer}.html"
		echo "<tr><td><a href=\"https://hydra.nixos.org/build/${buildid}\">${name}</a></td><td>${system}</td><td>${maintainer}</td><td>${status}</td></tr>" >> "public/failed/all.html"
	done
	cat <<EOF >> "public/failed/by-maintainer/${maintainer}.html"
    </table>
  </body>
</html>
EOF
done
cat <<EOF >> "public/failed/all.html"
    </table>
  </body>
</html>
EOF
cat <<EOF >> "public/failed/overview.html"
    </ul>
  </body>
</html>
EOF

echo "Finding most important dependencies..."
declare -A mostImportantBuildIds
mkdir -p data/mostimportantcache
for evaluation in "${evalIds[@]}"; do
	if ! [ -f "data/mostimportantcache/${evaluation}.cache" ]; then
		while IFS=' ' read -r attr buildid name system status; do
			if [ "${status}" != 'Dependency failed' ]; then
				continue
			fi
			# TODO Figure out buildid of the dependency
			depid=1
			if [ -v mostImportantBuildIds["${depid}"] ]; then
				mostImportantBuildIds["${depid}"]="$((mostImportantBuildIds["${depid}"] + 1))"
			else
				mostImportantBuildIds["${depid}"]=1
			fi
			echo "${depid}" >> "data/mostimportantcache/${evaluation}.cache"
		done < "../evalcache/${evaluation}.cache"
	else
		while IFS= read -r line; do
			if [ -v mostImportantBuildIds["${line}"] ]; then
				mostImportantBuildIds["${line}"]="$((mostImportantBuildIds["${line}"] + 1))"
			else
				mostImportantBuildIds["${line}"]=1
			fi
		done < "data/mostimportantcache/${evaluation}.cache"
	fi
done

# Render page
cp page/* public/
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
	public/index.html
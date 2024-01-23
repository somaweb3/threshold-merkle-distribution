#!/bin/bash
set -eou pipefail

LOG_START='\n\e[1;36m'           # new line + bold + color
LOG_END='\n\e[0m'                # new line + reset color
DONE_START='\n\e[1;32m'          # new line + bold + green
DONE_END='\n\n\e[0m'             # new line + reset
LOG_WARNING_START='\n\e\033[33m' # new line + bold + warning color
LOG_WARNING_END='\n\e\033[0m'    # new line + reset

PROMETHEUS_API_DEFAULT="https://monitoring.threshold.network/prometheus/api/v1"
PROMETHEUS_JOB_DEFAULT="keep-discovered-nodes"
REWARDS_JSON_DEFAULT="./rewards.json"
ETHERSCAN_API_DEFAULT="https://api.etherscan.io"
NETWORK_DEFAULT="mainnet"
KEEP_CORE_REPO="https://github.com/keep-network/keep-core"
REWARDS_DETAILS_PATH_DEFAULT="./rewards-details"
REQUIRED_PRE_PARAMS_DEFAULT=500
REQUIRED_UPTIME_DEFAULT=96 # percent
# Default should be 2. In rare cases when we release a hot fix and all 3 tags
# become eligible in a given interval, then it can be set to 3.
# Script supports up to 3 tags.
ELIGIBLE_NUMBER_OF_TAGS=2

help() {
  echo -e "\nUsage: $0" \
    "--etherscan-token <etherscan-token>" \
    "--operator-address <operator-address>" \
    "--prometheus-api <prometheus-api-address>" \
    "--prometheus-job <prometheus-job-name>" \
    "--etherscan-api <etherscan-api-url>" \
    "--network <network-name>" \
    "--output <output file>" \
    "--required-pre-params <required-pre-params>" \
    "--required-uptime <required-uptime>"
  echo -e "\nRequired command line arguments:\n"
  echo -e "\t--etherscan-token: Etherscan API key token"
  echo -e "\t--operator-address: Operator address to report on." 
  echo -e "\t--output: Output file for results"
  echo -e "\nOptional command line arguments:\n"
  echo -e "\t--prometheus-api: Prometheus API. Default: ${PROMETHEUS_API_DEFAULT}"
  echo -e "\t--prometheus-job: Prometheus service discovery job name. Default: ${PROMETHEUS_JOB_DEFAULT}"
  echo -e "\t--etherscan-api: Etherscan API url. Default: ${ETHERSCAN_API_DEFAULT}"
  echo -e "\t--network: Network name. Default: ${NETWORK_DEFAULT}"
  echo -e "\t--required-pre-params: Required pre-params. Default: ${REQUIRED_PRE_PARAMS_DEFAULT}"
  echo -e "\t--required-uptime: Required client uptime. Default: ${REQUIRED_UPTIME_DEFAULT}"
  echo -e ""
  exit 1 # Exit script after printing help
}

# Transform long options to short ones
for arg in "$@"; do
  shift
  case "$arg" in
  "--etherscan-token") set -- "$@" "-t" ;;
  "--etherscan-api") set -- "$@" "-r" ;;
  "--prometheus-api") set -- "$@" "-a" ;;
  "--prometheus-job") set -- "$@" "-p" ;;
  "--network") set -- "$@" "-n" ;;
  "--output") set -- "$@" "-d" ;;
  "--required-pre-params") set -- "$@" "-s" ;;
  "--required-uptime") set -- "$@" "-m" ;;
  "--operator-address") set -- "$@" "-x" ;;
  "--help") set -- "$@" "-h" ;;
  *) set -- "$@" "$arg" ;;
  esac
done

# Parse short options
OPTIND=1
while getopts "t:r:a:p:n:d:s:m:x:h" opt; do
  case "$opt" in
  t) etherscan_token="$OPTARG" ;;
  r) etherscan_api="$OPTARG" ;;
  a) prometheus_api="$OPTARG" ;;
  p) prometheus_job="$OPTARG" ;;
  n) network="$OPTARG" ;;
  d) output_file="$OPTARG" ;;
  s) required_pre_params="$OPTARG" ;;
  m) required_uptime="$OPTARG" ;;
  x) operator_address="$OPTARG" ;;
  h) help ;;
  ?) help ;; # Print help in case parameter is non-existent
  esac
done
shift $(expr $OPTIND - 1) # remove options from positional parameters

ETHERSCAN_TOKEN=${etherscan_token:-""}
# Can't use "now" cuz we won't find an ending block
REWARDS_END_DATE=$(date --date='15 minutes ago' +%s)
REWARDS_START_DATE=$(date -d @${REWARDS_END_DATE} +"%Y-%m-%d")
[[ "${REWARDS_START_DATE}" =~ (....-..-) ]]
REWARDS_START_DATE=$(date -d ${BASH_REMATCH[0]}01 +%s)
PROMETHEUS_API=${prometheus_api:-${PROMETHEUS_API_DEFAULT}}
PROMETHEUS_JOB=${prometheus_job:-${PROMETHEUS_JOB_DEFAULT}}
REWARDS_JSON=${rewards_json:-${REWARDS_JSON_DEFAULT}}
ETHERSCAN_API=${etherscan_api:-${ETHERSCAN_API_DEFAULT}}
NETWORK=${network:-${NETWORK_DEFAULT}}
REWARDS_DETAILS_PATH=${rewards_details_path:-${REWARDS_DETAILS_PATH_DEFAULT}}
REQUIRED_PRE_PARAMS=${required_pre_params:-${REQUIRED_PRE_PARAMS_DEFAULT}}
REQUIRED_UPTIME=${required_uptime:-${REQUIRED_UPTIME_DEFAULT}}

if [ "$REWARDS_START_DATE" == "" ]; then
  printf "${LOG_WARNING_START}Rewards start date must be provided.${LOG_WARNING_END}"
  help
fi

if [ "$REWARDS_END_DATE" == "" ]; then
  printf "${LOG_WARNING_START}Rewards end date must be provided.${LOG_WARNING_END}"
  help
fi

if [ "$ETHERSCAN_TOKEN" == "" ]; then
  printf "${LOG_WARNING_START}Etherscan API key token must be provided.${LOG_WARNING_END}"
  help
fi

# TBTCv2 rewards must be calculated since Oct 1st 2022
if [ "$REWARDS_START_DATE" -lt "1664582400" ]; then
  REWARDS_START_DATE=1664582400
fi

startBlockApiCall="${ETHERSCAN_API}/api?\
module=block&\
action=getblocknobytime&\
timestamp=$REWARDS_START_DATE&\
closest=after&\
apikey=${ETHERSCAN_TOKEN}"

endBlockApiCall="${ETHERSCAN_API}/api?\
module=block&\
action=getblocknobytime&\
timestamp=$REWARDS_END_DATE&\
closest=after&\
apikey=${ETHERSCAN_TOKEN}"

startRewardsBlock=$(curl -s $startBlockApiCall | jq '.result|tonumber')
endRewardsBlock=$(curl -s $endBlockApiCall | jq '.result|tonumber')

printf "${LOG_START}Installing yarn dependencies...${LOG_END}"
yarn install

printf "${LOG_START}Retrieving client release tags...${LOG_END}"
# Create a new git remote to fetch the release tags
git remote remove keep-core-repo 2>/dev/null || true
git remote add keep-core-repo ${KEEP_CORE_REPO}
git fetch --tags --prune --quiet keep-core-repo
allTags=($(git tag --sort=-version:refname --list 'v[0-9]*.*-m[0-9]'))
printf "Found ${allTags[*]} tags"
latestTag=${allTags[0]}
latestTimestamp=($(git tag --sort=-version:refname --list 'v[0-9]*.*-m[0-9]' --format '%(creatordate:unix)' | head -n 1))
latestTagTimestamp="${latestTag}_$latestTimestamp"

# There are at least 2 tags available at this point of time
secondToLatestTag=${allTags[1]}
secondToLatestTagTimestamp="${secondToLatestTag}_$(git tag --sort=-version:refname --list 'v[0-9]*.*-m[0-9]' --format '%(creatordate:unix)' | head -n 2 | tail -1)"

tagsInRewardInterval=()
tagsInRewardInterval+=($latestTagTimestamp)
tagsInRewardInterval+=($secondToLatestTagTimestamp)

if [ "$ELIGIBLE_NUMBER_OF_TAGS" -eq "3" ]; then
  thirdToLatestTag=${allTags[2]}
  thirdToLatestTagTimestamp="${thirdToLatestTag}_$(git tag --sort=-version:refname --list 'v[0-9]*.*-m[0-9]' --format '%(creatordate:unix)' | head -n 3 | tail -1)"
  tagsInRewardInterval+=($thirdToLatestTagTimestamp)
fi

# Converting array to string so we can pass to the rewards-requirements.ts
printf -v tags '%s|' "${tagsInRewardInterval[@]}"
tagsTrimmed="${tags%?}" # remove "|" at the end

# Removing created remote
git remote remove keep-core-repo

# Run script
printf "${LOG_START}Fetching peers data...${LOG_END}"

ETHERSCAN_TOKEN=${ETHERSCAN_TOKEN} yarn requirements \
  --api ${PROMETHEUS_API} \
  --job ${PROMETHEUS_JOB} \
  --start-timestamp $REWARDS_START_DATE \
  --end-timestamp $REWARDS_END_DATE \
  --start-block $startRewardsBlock \
  --end-block $endRewardsBlock \
  --releases $tagsTrimmed \
  --network ${NETWORK} \
  --output-file ${output_file} \
  --required-pre-params ${REQUIRED_PRE_PARAMS} \
  --required-uptime ${REQUIRED_UPTIME} \
  --operator-address $operator_address

printf "${DONE_START}Complete!${DONE_END}"

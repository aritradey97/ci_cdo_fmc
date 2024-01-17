#!/bin/bash


function showHelp() {
cat << EOF
Usage: ${0##*/}
Parameters: 
    CDO_STACK               ci or staging
    DEVICE_ID               SSX ID for FMC
    ORG_ID                  Can be found from CDO Settings page. SSE Tenant_id where you onboard the FMC 
EOF
}

function parseArgs() {
  if [ -z  "$1" ]; then
    showHelp
    exit 1
  fi

  # CDO Environment
  CDO_STACK=$1
  # FMC SSX ID
  DEVICE_ID=$2
  ORG_ID=$3
  ETH_INTERFACE="${4-eth0}"
}

parseArgs $@

SCRIPT_PATH=`pwd` 
echo "$SCRIPT_PATH"
uri_prefix="http://localhost:8989/v1"
CURL="curl"
CURL_RETRY="curl --connect-timeout 10 --max-time 20  --retry 5 --retry-delay 0  --retry-max-time 60"
https_enabled="false"


if [ $CDO_STACK == "staging" ]; then
    domain="api-services.devcd.sse.itd.cisco.com"
    client_id="bc999c59-5e5a-4421-a99e-755308aadbb5"
    client_secret="Hhn34@1n"
    sse_stack_url="staging-sse.cisco.com"
elif [ $CDO_STACK == "ci" ]; then
    domain="api-services.stage.sse.itd.cisco.com"
    client_id="35f617f8-017f-4215-9fb9-addafe5a07b1"
    client_secret="Hsg92@9i"
    sse_stack_url="stage-api-sse.cisco.com"
else
    log "Unsupported CDO Stack, $CDO_STACK should either ci or staging"
fi
  

context_create_api="$uri_prefix/contexts/"
CONFIG_PATH=$SCRIPT_PATH
context_create_json_file="$CONFIG_PATH/client_fmc.json"
context_id="default"
get_context_uri="$uri_prefix/contexts/$context_id"
activation_uri="$get_context_uri/activations"
status_uri="$get_context_uri/status"

## FMC registration details 
LOG_FILE="${SCRIPT_PATH}/ltp_registration.log"
OutputDir="${SCRIPT_PATH}/Output"

setup(){
mkdir -p $OutputDir
}

cleanup(){
    rm -rf $OutputDir
}


log()
{
        echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG_FILE"
}

replace_ip_in_client_json() {
    log $ETH_INTERFACE
    FMC_IP=`ifconfig "${ETH_INTERFACE}" | grep "inet addr:" | cut -d: -f2 | awk '{print $1}'`
    if ["$FMC_IP" == ""]; then
        FMC_IP=`ifconfig "$ETH_INTERFACE" | awk -F "inet " '{print $2}' |  awk -F " netmask" '{print $1}' | xargs`
    fi
    log "$FMC_IP"
    sed -i -e "s/ip\":.*/ip\": \"$FMC_IP\"/" $context_create_json_file
}

replace_sse_fqdn_in_client_json() {
    log "$sse_stack_url"
    sed -i -e "s/fqdn\":.*/fqdn\": \"$sse_stack_url\"/" $context_create_json_file
}


## Generate ORG JWT
gen_org_jwt() {
    log ""
    log "Generating ORG Jwt"
    log "Generating ORG Jwt with the following org information : \n  $org_info_payload \n"
    org_info_payload="client_id=$client_id&client_secret=$client_secret&grant_type=client_credentials&offline_access=true&expiry=60&scope=org_id:$SPECIFIC_ORG_ID"
    log "$org_info_payload"

    org_jwt_out=`curl -k -v  -H "Content-Type: application/x-www-form-urlencoded" -d "$org_info_payload" https://$domain/providers/sse/services/token/api/v2/oauth/service/access_token \
        -o $OutputDir/orgJwt.json -D $OutputDir/orgJwtHeaders.out`

    log "gen_org_jwt - Running Command : $CURL -k -X GET -H 'Content-Type: application/x-www-form-urlencoded' -d $org_info_payload https://$domain/providers/sse/services/token/api/v2/oauth/service/access_token \n"
    OrgJwtStatus=`grep "HTTP" $OutputDir/orgJwtHeaders.out | cut -d ' ' -f2`
    log "gen_org_jwt - HTTP Response: $OrgJwtStatus \n"
    if [ $OrgJwtStatus -eq "201" ]; then
        if [ -f $OutputDir/orgJwt.json -a -s $OutputDir/orgJwt.json ]; then
          log "Resonse for Generate ORG JWT: \n $org_jwt_out \n"
          org_jwt=`grep -Po '(?<="access_token":")[^"]*' $OutputDir/orgJwt.json | head -1`
          log "Org JWT for $SPECIFIC_ORG_ID: \n"
          log $org_jwt
        fi
    fi
}

get_device_id() {
    sn_device_id=$DEVICE_ID
    log "Getting device ID: $sn_device_id"
}

generate_token_json() {
    token_json="$OutputDir/token.json"
    log "Removing the existing token json file <token.json>, if any"
    rm -rf $token_json
    device_token_payload="{\"principal\":{\"deviceId\":\"$sn_device_id\",\"serviceType\":[\"ngfw\",\"ITD-Base\",\"hybrid-2.0\"]},\"expiry\":129600}"
    log "Generating device token with the following device information : \n  $device_token_payload \n"
    log "Running Command :$CURL -XPOST -d @device_token_payload.json -vvv https://$domain/providers/sse/services/token/api/v2/auth_tokens/registration -H Content-Type:application/json \n"
    token_curl_out=`curl -k -vv -X POST -H 'Content-Type: application/json' -H "Authorization: Bearer $org_jwt" -o $token_json -d "$device_token_payload" https://$domain/providers/sse/services/token/api/v2/auth_tokens/registration -D $OutputDir/generate_token_headers.out`
    GenerateTokenStatus=`grep "HTTP" $OutputDir/generate_token_headers.out | cut -d ' ' -f2`
    if [ $GenerateTokenStatus -eq "200" -o $GenerateTokenStatus -eq "201" ]; then
        if [ -f $token_json -a -s $token_json ]
            then
            log "Resonse for Generate Device Token: \n $token_curl_out \n"
        fi
    fi
}

create_context() {
    client_json=`cat "$context_create_json_file"`                         
    log "Creating a new context with the following client information : \n $client_json \n"
    log "Running Command :$CURL -XPOST -d @client.json -vvv $context_create_api -H Content-Type:application/json \n"
    response_json=$("$CURL" -XPOST -d @"$context_create_json_file" -vvv "$context_create_api" -H Content-Type:application/json -D $OutputDir/create_context_headers.out)
    CreateContestStatus=`grep "HTTP" $OutputDir/create_context_headers.out | cut -d ' ' -f2`
    if [ $GetContextStatus -eq "200" -o $GetContextStatus -eq "201" ]; then
        log "Response recevied from connector : \n $response_json \n"
        #Setup variables after context has been created
        context_id=`echo "$response_json" | grep -w "id" | cut -f 2 -d ":" | xargs | sed 's/,*$//g'`
    fi
}

get_context() {
    log "Get context"
    log "Running Command :$CURL -k -vvv $get_context_uri \n"
    get_context_out=$("$CURL" -k -vvv "$get_context_uri" -D $OutputDir/get_context_headers.out)
    GetContextStatus=`grep "HTTP" $OutputDir/get_context_headers.out | cut -d ' ' -f2`
    if [ $GetContextStatus -eq "200" -o $GetContextStatus -eq "201" ]; then
        log "Response recevied from connector : \n $get_context_out \n"
    fi
}

get_status() {
    log "Get Context status"
    log "Running Command :$CURL -vvv $status_uri \n"
    get_status_out=$("$CURL" -vvv "$status_uri" -D $OutputDir/get_status_headers.out -o $OutputDir/context_status.json)
    ContextStatus=`grep "HTTP" $OutputDir/get_status_headers.out | cut -d ' ' -f2`
    if [ $ContextStatus -eq "200" -o $ContextStatus -eq "201" ]; then
        log "Response received from connector : \n $get_status_out \n"
    fi
}

activate_context() {
    log "Activating the context with the following device token information : \n $token_json \n"
    log "Running Command : $CURL -vvv -XPOST -d @'$token_json' $activation_uri -H Content-Type:application/json"
    activate_context_out=$("$CURL" -vvv -XPOST -d @"$token_json" "$activation_uri" -H "Content-Type:application/json" -D $OutputDir/activate_context_headers.out)
    ActivateContextStatus=`grep "HTTP" $OutputDir/activate_context_headers.out | cut -d ' ' -f2`
    if [ $ActivateContextStatus -eq "200" -o $ActivateContextStatus -eq "201" ]; then
        log "Response recevied from connector : \n $activate_context_out \n"
    fi
}

delete_context() {
    log "Delete the connector context"
    log "Running Command : $CURL -k -vvv -XDELETE $get_context_uri"   
    delete_context_out=$("$CURL" -k -vvv -XDELETE "$get_context_uri")
    log "Response recevied from connector : \n $delete_context_out \n"
}



remove_device() {
    read -a sn_device_arr <<< $sn_device_id
    log "Removing the existing devices"

    for device_id in ${sn_device_arr[@]}; do
        rm -rf $OutputDir/delete_device_headers.json
        log "Deleting the device Id with $device_id"
        log "Running Command :$CURL -k -X DELETE  -vvv https://$domain/providers/sse/services/scim/v2/Devices/$device_id \n"
        delete_device_curl_out=`$CURL_RETRY -k -v -X DELETE  -H "Authorization: Bearer $org_jwt" "https://$domain/providers/sse/services/scim/v2/Devices/$device_id" -D $OutputDir/delete_device_headers.out`
        DeleteDeviceStatus=`grep "HTTP" $OutputDir/delete_device_headers.out | cut -d ' ' -f2`
        log "Curl command response code : $DeleteDeviceStatus"
        if [ $DeleteDeviceStatus -eq "202" ]; then
            log "Response of device delete: \n $delete_device_curl_out \n"
            log "Device Id: $device_id is deleted"
        fi
        sleep 1
    done
}

wait_for_logline() {
    local file="$1"; shift
    local search_term="$1"; shift
    local wait_time="${1:-20m}"; shift # 5 minutes as default timeout

    if [ -f $file ]; then
        log "tomcat Catalina log file is found"
        log "Waiting for the tomcat process to come up, timeout set as $wait_time"
        (timeout $wait_time tail -F -n0 "$file" &) | grep -q "$search_term" && return 0
        log "Timeout of $wait_time reached. Unable to find '$search_term' in '$file'"
        return 1
    else
        log "tomcat Catalina log file is not found, exiting the script"
        return 2
    fi
}

#FILE_TO_CHECK="/ngfw/var/log/cisco/ngfw-onbox.log"
#LINE_TO_CONTAIN="org.apache.catalina.startup.Catalina.start Server startup"
#WAIT_TIME="20m"

#wait_for_logline "$FILE_TO_CHECK" "$LINE_TO_CONTAIN" "$WAIT_TIME"

if [ "$?" -eq "0" ]; then
    log "Let's go, the file is containing what we want"
    setup

    SPECIFIC_ORG_ID=$ORG_ID
    gen_org_jwt
    ##Get Device ID
    log "Loading device id of FMC in org- $ORG_ID"
    get_device_id
    log "$sn_device_id"

    replace_sse_fqdn_in_client_json
    replace_ip_in_client_json
    ##Create Conncetor context
    log "Creating context"
    create_context

    ##Generate a new token
    log "Generate a new token for the tenant"
    generate_token_json

    ##Now Activate a context
    log "Activating context with token $token"
    activate_context
    log "Waiting for the context to be activated, sleeping for 5 seconds"
    sleep 5

    ##Get Context
    log "Get context after activation ..."
    get_context

    ##Get Status
    log "Get just the status after activation ..."
    get_status


    grep -Po '"status\".*Enrolled' $OutputDir/context_status.json
    if [ "$?" -eq "0" ]; then
        log 'device is Enrolled to SSE'
    fi

    #get_device_id
    #log $sn_device_id
    #log "Cleaning up the device in case of any errors from previous run"
    #remove_device
    #log "Delete the context from device"
    #delete_context
else
    echo "Grep the pattern in tomcat log is errored out"
    exit 10
fi


##Delete Context
#printf "\n"
#echo "Delete context $context_id"
#delete_context



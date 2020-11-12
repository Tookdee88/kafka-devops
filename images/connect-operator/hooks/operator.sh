#!/usr/bin/env bash

source $SHELL_OPERATOR_HOOKS_DIR/lib/common.sh

BASE_URL=${BASE_URL:-http://kafka-connect:8083}

# Converts the Java properties style files located
# in /etc/config/connect-operator into a string of arguments that can be passed
# into jq for file templating.
#
# Currently sets the global variable JQ_ARGS_FROM_CONFIG_FILE as it's "output"
function load_configs() {

  for f in /etc/config/connect-operator/*.properties; do (cat "${f}"; echo) >> /etc/config/connect-operator/connect-operator.properties; done

  # read all the lines from the aggregate properties file and load them
  # up into arguments with keys and values
  JQ_ARGS_FROM_CONFIG_FILE=$(
  while read line
  do
  	[[ ! -z "$line" ]] && {
      # this will turn a java properties file key like:
      # schema.registry.basic.auth.user.info
      # into
      # SCHEMA_REGISTRY_BASIC_AUTH_USER_INFO
  		KEY=$(echo ${line} | cut -d= -f1 | tr '[a-z]' '[A-Z]' | tr '.' '_')
  		VALUE=$(echo ${line} | cut -d= -f2)
  		echo -n "--arg ${KEY} \"${VALUE}\" "
  	}
  done < /etc/config/connect-operator/connect-operator.properties)

  # The end result is, JQ_ARGS_FROM_CONFIG_FILE looks something like this:
  #
  # echo $JQ_ARGS_FROM_CONFIG_FILE
  # --arg BOOTSTRAP_SERVERS abc.us-east2.confluent.cloud:9092 --arg SCHEMA_REGISTRY_URL https://sr.us-east2.confluent.cloud

}

# Accepts a single JSON string parameter representing a
# Kafka Connnect configuration and deletes it from the Kafka Connect
# cluster located at $BASE_URL
function delete_connector() {
	trap 'rm -f "$TMPFILE"' EXIT
	TMPFILE=$(mktemp) || exit 1
  echo $1 > $TMPFILE

	TEMPLATE_COMMAND="jq -c -n $JQ_ARGS_FROM_CONFIG_FILE -f $TMPFILE"

  DESIRED_CONNECTOR_CONFIG=$(eval $TEMPLATE_COMMAND | jq -c '.config')
  CONNECTOR_NAME=$(echo $DESIRED_CONNECTOR_CONFIG | jq -r '.name')
  echo "Deleting connector $CONNECTOR_NAME"
	curl -s -o /dev/null -XDELETE "$BASE_URL/connectors/$CONNECTOR_NAME"
}

# Accepts a single JSON string parameter representing a
# Kafka Connnect configuration and applies it to the Kafka Connect
# cluster located at $BASE_URL
#
# The function will pass string through the jq program in order to fill
# in any variables from either the current environment or from the
# values in the JQ_ARGS_FROM_CONFIG_FILE variable which is set on startup
# See load_configs for how those values are provided at runtime
function apply_connector() {
	trap 'rm -f "$TMPFILE"' EXIT
	TMPFILE=$(mktemp) || exit 1
  echo $1 > $TMPFILE

	TEMPLATE_COMMAND="jq -c -n $JQ_ARGS_FROM_CONFIG_FILE -f $TMPFILE"

  DESIRED_CONNECTOR_CONFIG=$(eval $TEMPLATE_COMMAND)
  CONNECTOR_NAME=$(echo $DESIRED_CONNECTOR_CONFIG | jq -r '.name')

	for i in $(seq 1 5); do
	  echo "Checking connector $CONNECTOR_NAME exists"
    CONNECTOR_EXISTS_RESULT=$(curl -s -o /dev/null -I -w "%{http_code}" -XGET -H "Accpet: application/json" "$BASE_URL/connectors/$CONNECTOR_NAME")
    if [[ "$CONNECTOR_EXISTS_RESULT" != "409" ]] ; then break; fi
    sleep 5
  done

  if [[ "$CONNECTOR_EXISTS_RESULT" == "200" ]]; then
		CURRENT_CONNECTOR_CONFIG=$(curl -s -XGET -H "Content-Type: application/json" "$BASE_URL/connectors/$CONNECTOR_NAME/config")
		if cmp -s <(echo $DESIRED_CONNECTOR_CONFIG | jq -S -c '.config') <(echo $CURRENT_CONNECTOR_CONFIG | jq -S -c .); then
			echo "No config changes for $CONNECTOR_NAME"
		else
			echo "Updating existing connector config: $CONNECTOR_NAME"
      DESIRED_CONNECTOR_CONFIG=$(echo $DESIRED_CONNECTOR_CONFIG | jq -S -c '.config')
    	curl -s -XPUT -H "Content-Type: application/json" --data "$DESIRED_CONNECTOR_CONFIG" "$BASE_URL/connectors/$CONNECTOR_NAME/config"
		fi
	elif [[ "$CONNECTOR_EXISTS_RESULT" == "404" ]]; then
    echo "Creating new connector: $CONNECTOR_NAME"
    curl -s -XPOST -H "Content-Type: application/json" --data "$DESIRED_CONNECTOR_CONFIG" "$BASE_URL/connectors"
  fi
}

function wait_kafka_connect() {
  echo "Waiting for Kafka Connect"
  while : ; do
    curl_status=$(curl -s -o /dev/null -w %{http_code} "$BASE_URL/connectors")
    echo -e $(date) " Kafka Connect listener HTTP state: " $$curl_status " (waiting for 200)"
    if [ $curl_status -eq 200 ] ; then
      break
    fi
    sleep 5
  done
}

hook::run() {
  if [ ! -z ${DEBUG+x} ]; then set -x; fi
  wait_kafka_connect
  load_configs

  # shell-operator gives us a wrapper around the resource we are monitoring
  # in a file located at the path of $BINDING_CONTEXT_PATH
  # The data model for this object can be found here:
  # https://github.com/flant/shell-operator/blob/master/pkg/hook/binding_context/binding_context.go

  ARRAY_COUNT=`jq -r '. | length-1' $BINDING_CONTEXT_PATH`
  for I in `seq 0 $ARRAY_COUNT`
  do
    export INDEX=$I
    TYPE=$(jq -r ".[$INDEX].type" $BINDING_CONTEXT_PATH)
    if [[ "$TYPE" == "Synchronization" ]]; then
      echo "Received binding context type Synchronization"
      # In the Syncronization phase, we maybe receive many object instances,
      # so we pull out each one and process them indpendently
      KEYS=$(jq -c -r ".[$INDEX].objects | .[].object.data | keys | .[]" $BINDING_CONTEXT_PATH)
      for KEY in $KEYS; do
        CONFIG=$(jq -c -r ".[$INDEX].objects | .[].object.data | select(has(\"$KEY\")) | .\"$KEY\"" $BINDING_CONTEXT_PATH)
        apply_connector "$CONFIG"
      done
    elif [[ "$TYPE" == "Event" ]]; then
      # The EVENT variable will containe either Added, Updated, or Deleted in the
      # case where TYPE == Event
      EVENT=$(jq -r ".[$INDEX].watchEvent" $BINDING_CONTEXT_PATH)
      DATA=$(jq -r ".[$INDEX].object.data" $BINDING_CONTEXT_PATH)
      KEY=$(echo $DATA | jq -r -c 'keys | .[0]')
      CONFIG=$(echo $DATA | jq -r -c ".\"$KEY\"")
      echo "Received binding context type event $EVENT"
      if [[ "$EVENT" == "Deleted" ]]; then
        delete_connector "$CONFIG"
      else
       apply_connector "$CONFIG"
      fi
    fi
  done

  if [ ! -z ${DEBUG+x} ]; then set +x; fi
}

common::run_hook "$@"


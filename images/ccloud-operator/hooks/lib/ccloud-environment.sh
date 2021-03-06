if [ -n "$LIB_CCLOUD_ENV" ]; then return; fi
LIB_CCLOUD_ENV=`date`

source $SHELL_OPERATOR_HOOKS_DIR/lib/ccloud-kafka.sh
source $SHELL_OPERATOR_HOOKS_DIR/lib/ccloud-schema-registry.sh

function ccloud::env::apply_list() {
	for ENV_ENCODED in $(echo $1 | jq -c -r '.[] | @base64'); do
		
		local ENV=$(echo "${ENV_ENCODED}" | base64 -d)
		
		local envname=$(echo $ENV | jq -r .name)
		local env_id=$(ccloud::env::apply name="$envname")

		echo "configured environment: $envname, id = $env_id"

		ccloud environment use "$env_id"

		local KAFKA=$(echo $ENV | jq -r -c '.kafka')
		ccloud::kafka::apply_list kafka="$KAFKA" environment_name="$envname"

    local SR=$(echo $ENV | jq -r -c '."schema-registry"')
    local sr_id=$(ccloud::schema-registry::apply sr="$SR" environment_name="$envname")
    echo "configured schema-registry: $sr_id"

	done
}

####################################################################
# Apply an environment configuration with the named parameters;
# name
####################################################################
function ccloud::env::apply() {
	local name
	local "${@}"
	result=$(ccloud environment create $name -o json 2>&1)
	retcode=$?
	if [[ $retcode -eq 0 ]]; then
		echo $result | jq -r '.id'
	elif [[ "$result" == *"already in use"* ]]; then
		ccloud environment list -o json | jq -r '.[] | select(.name=="'"$name"'") | .id'
	else
		echo $result
		return $retcode
	fi
}

##################################
# Delete a given environment 
# to the configured ccloud 
##################################
function ccloud::env::delete() {
	local id
	local "${@}"
	ccloud environment delete "$id"
}

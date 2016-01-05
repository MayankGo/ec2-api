#!/bin/bash -e

#Parameters to configure
SERVICE_USERNAME=ec2api
SERVICE_PASSWORD=ec2api
SERVICE_TENANT=services
CONNECTION="mysql://ec2api:ec2api@127.0.0.1/ec2api?charset=utf8"
LOG_DIR=/var/log/ec2api
CONF_DIR=/etc/ec2api
NOVA_CONF=/etc/nova/nova.conf
SIGNING_DIR=/var/cache/ec2api

#Check for environment
if [[ -z "$OS_AUTH_URL" || -z "$OS_USERNAME" || -z "$OS_PASSWORD" || -z "$OS_TENANT_NAME" ]]; then
    echo "Please set OS_AUTH_URL, OS_USERNAME, OS_PASSWORD and OS_TENANT_NAME"
    exit 1
fi


#### utilities functions merged from devstack to check required parameter is not empty
# Prints line number and "message" in error format
# err $LINENO "message"
function err() {
    local exitcode=$?
    errXTRACE=$(set +o | grep xtrace)
    set +o xtrace
    local msg="[ERROR] ${BASH_SOURCE[2]}:$1 $2"
    echo $msg 1>&2;
    if [[ -n ${SCREEN_LOGDIR} ]]; then
        echo $msg >> "${SCREEN_LOGDIR}/error.log"
    fi
    $errXTRACE
    return $exitcode
}
# Prints backtrace info
# filename:lineno:function
function backtrace {
    local level=$1
    local deep=$((${#BASH_SOURCE[@]} - 1))
    echo "[Call Trace]"
    while [ $level -le $deep ]; do
        echo "${BASH_SOURCE[$deep]}:${BASH_LINENO[$deep-1]}:${FUNCNAME[$deep-1]}"
        deep=$((deep - 1))
    done
}


# Prints line number and "message" then exits
# die $LINENO "message"
function die() {
    local exitcode=$?
    set +o xtrace
    local line=$1; shift
    if [ $exitcode == 0 ]; then
        exitcode=1
    fi
    backtrace 2
    err $line "$*"
    exit $exitcode
}


# Checks an environment variable is not set or has length 0 OR if the
# exit code is non-zero and prints "message" and exits
# NOTE: env-var is the variable name without a '$'
# die_if_not_set $LINENO env-var "message"
function die_if_not_set() {
    local exitcode=$?
    FXTRACE=$(set +o | grep xtrace)
    set +o xtrace
    local line=$1; shift
    local evar=$1; shift
    if ! is_set $evar || [ $exitcode != 0 ]; then
        die $line "$*"
    fi
    $FXTRACE
}

# Test if the named environment variable is set and not zero length
# is_set env-var
function is_set() {
    local var=\$"$1"
    eval "[ -n \"$var\" ]" # For ex.: sh -c "[ -n \"$var\" ]" would be better, but several exercises depends on this
}

#######################################

get_data() {
    local match_column=$(($1 + 1))
    local regex="$2"
    local output_column=$(($3 + 1))
    shift 3

    output=$("$@" | \
           awk -F'|' \
               "! /^\+/ && \$${match_column} ~ \"^ *${regex} *\$\" \
                { print \$${output_column} }")

    echo "$output"
}

get_id () {
    get_data 1 id 2 "$@"
}

get_user() {
    local username=$1

    local user_id=$(get_data 2 $username 1 keystone user-list)

    if [ -n "$user_id" ]; then
        echo "Found existing $username user" >&2
        echo $user_id
    else
        echo "Creating $username user..." >&2
        get_id keystone user-create --name=$username \
                                    --pass="$SERVICE_PASSWORD" \
                                    --tenant $SERVICE_TENANT \
                                    --email=$username@example.com
    fi
}

add_role() {
    local user_id=$1
    local tenant=$2
    local role_id=$3
    local username=$4

    user_roles=$(keystone user-role-list \
                          --user_id $user_id\
                          --tenant $tenant 2>/dev/null)
    die_if_not_set $LINENO user_roles "Fail to get user_roles for tenant($tenant) and user_id($user_id)"
    existing_role=$(get_data 1 $role_id 1 echo "$user_roles")
    if [ -n "$existing_role" ]
    then
        echo "User $username already has role $role_id" >&2
        return
    fi
    keystone user-role-add --tenant $tenant \
             --user_id $user_id \
             --role_id $role_id
}


# Determines if the given option is present in the INI file
# ini_has_option config-file section option
function ini_has_option() {
    local file=$1
    local section=$2
    local option=$3
    local line
    line=$(sudo sed -ne "/^\[$section\]/,/^\[.*\]/ { /^$option[ \t]*=/ p; }" "$file")
    [ -n "$line" ]
}

# Set an option in an INI file
# iniset config-file section option value
function iniset() {
    local file=$1
    local section=$2
    local option=$3
    local value=$4
    if ! sudo grep -q "^\[$section\]" "$file"; then
        # Add section at the end
        sudo bash -c "echo -e \"\n[$section]\" >>\"$file\""
    fi
    if ! ini_has_option "$file" "$section" "$option"; then
        # Add it
        sudo sed -i -e "/^\[$section\]/ a\\
$option = $value
" "$file"
    else
        # Replace it
        sudo sed -i -e "/^\[$section\]/,/^\[.*\]/ s|^\($option[ \t]*=[ \t]*\).*$|\1$value|" "$file"
    fi
}

# Get an option from an INI file
# iniget config-file section option
function iniget() {
    local file=$1
    local section=$2
    local option=$3
    local line
    line=$(sed -ne "/^\[$section\]/,/^\[.*\]/ { /^$option[ \t]*=/ p; }" "$file")
    echo ${line#*=}
}

# Copy an option from Nova INI file or from environment if it's set
function copynovaopt() {
    local option_name=$1
    local env_var
    local option
    env_var=${option_name^^}
    if [ ${!env_var+x} ]; then
        option=${!env_var}
    elif ini_has_option "$NOVA_CONF" DEFAULT $option_name; then
        option=$(iniget $NOVA_CONF DEFAULT $option_name)
    else
        return 0
    fi
    iniset $CONF_FILE DEFAULT $option_name $option
}

if [[ -n $(keystone catalog --service network) ]]; then
    VPC_SUPPORT="True"
else
    VPC_SUPPORT="False"
fi
if [[ "$VPC_SUPPORT" == "True" && -z "$EXTERNAL_NETWORK" ]]; then
    declare -a newtron_output
    readarray -s 3 -t newtron_output < <(neutron net-external-list)
    if ((${#newtron_output[@]} < 2)); then
        reason="No external network is declared in Neutron."
    elif ((${#newtron_output[@]} > 2)); then
        reason="More than one external networks are declared in Neutron."
    else
        EXTERNAL_NETWORK=$(echo $newtron_output | awk -F '|' '{ print $3 }')
    fi
    die_if_not_set $LINENO EXTERNAL_NETWORK "$reason. Please set EXTERNAL_NETWORK environment variable to the external network dedicated to EC2 elastic IP operations"
fi

#create keystone user with admin privileges
ADMIN_ROLE=$(get_data 2 admin 1 keystone role-list)
die_if_not_set $LINENO ADMIN_ROLE "Fail to get ADMIN_ROLE by 'keystone role-list' "
SERVICE_TENANT_ID=$(get_data 2 services 1 keystone tenant-list)
die_if_not_set $LINENO SERVICE_TENANT_ID "Fail to get service tenant 'keystone tenant-list' "

echo ADMIN_ROLE $ADMIN_ROLE
echo SERVICE_TENANT $SERVICE_TENANT

SERVICE_USERID=$(get_user $SERVICE_USERNAME)
die_if_not_set $LINENO SERVICE_USERID "Fail to get user for $SERVICE_USERNAME"
echo SERVICE_USERID $SERVICE_USERID
add_role $SERVICE_USERID $SERVICE_TENANT $ADMIN_ROLE $SERVICE_USERNAME

#create log dir
echo Creating log dir
sudo install -d $LOG_DIR --owner=$USER

CONF_FILE=$CONF_DIR/ec2api.conf
APIPASTE_FILE=$CONF_DIR/api-paste.ini
#copy conf files (do not override it)
echo Creating configs
sudo mkdir -p /etc/ec2api > /dev/null
if [ ! -s $CONF_FILE ]; then
    sudo cp etc/ec2api/ec2api.conf.sample $CONF_FILE
fi
if [ ! -s $APIPASTE_FILE ]; then
    sudo cp etc/ec2api/api-paste.ini $APIPASTE_FILE
fi

AUTH_HOST=${OS_AUTH_URL#*//}
AUTH_HOST=${AUTH_HOST%:*}
AUTH_CACHE_DIR=${AUTH_CACHE_DIR:-/var/cache/ec2api}
AUTH_PORT=`keystone catalog|grep -A 9 identity|grep adminURL|awk '{print $4}'`
AUTH_PORT=${AUTH_PORT##*:}
AUTH_PORT=${AUTH_PORT%%/*}
AUTH_PROTO=${OS_AUTH_URL%%:*}
PUBLIC_URL=${OS_AUTH_URL%:*}:8788/

#update default config with some values
iniset $CONF_FILE DEFAULT api_paste_config $APIPASTE_FILE
iniset $CONF_FILE DEFAULT logging_context_format_string "%(asctime)s.%(msecs)03d %(levelname)s %(name)s [%(request_id)s %(user_name)s %(project_name)s] %(instance)s%(message)s"
iniset $CONF_FILE DEFAULT log_dir "$LOG_DIR"
iniset $CONF_FILE DEFAULT verbose True
iniset $CONF_FILE DEFAULT keystone_url "$OS_AUTH_URL"
iniset $CONF_FILE database connection "$CONNECTION"
iniset $CONF_FILE DEFAULT full_vpc_support "$VPC_SUPPORT"
iniset $CONF_FILE DEFAULT external_network "$EXTERNAL_NETWORK"

iniset $CONF_FILE keystone_authtoken signing_dir $SIGNING_DIR
iniset $CONF_FILE keystone_authtoken auth_host $AUTH_HOST
iniset $CONF_FILE keystone_authtoken admin_user $SERVICE_USERNAME
iniset $CONF_FILE keystone_authtoken admin_password $SERVICE_PASSWORD
iniset $CONF_FILE keystone_authtoken admin_tenant_name $SERVICE_TENANT
iniset $CONF_FILE keystone_authtoken auth_protocol $AUTH_PROTO
iniset $CONF_FILE keystone_authtoken auth_port $AUTH_PORT

iniset $CONF_FILE DEFAULT admin_user $SERVICE_USERNAME
iniset $CONF_FILE DEFAULT admin_password $SERVICE_PASSWORD
iniset $CONF_FILE DEFAULT admin_tenant_name $SERVICE_TENANT

if [[ -f "$NOVA_CONF" ]]; then
    # NOTE(ft): use swift instead internal s3 server if enabled
    if [[ -n $(keystone catalog --service object-store) ]] &&
            [[ -n $(keystone catalog --service s3) ]]; then
        copynovaopt s3_host
        copynovaopt s3_port
        copynovaopt s3_affix_tenant
        copynovaopt s3_use_ssl
    fi
    copynovaopt cert_topic
    copynovaopt rabbit_hosts
    copynovaopt rabbit_password
    # TODO(ft): it's necessary to support other available messaging implementations

    nova_state_path=$(iniget $NOVA_CONF DEFAULT state_path)
    root_state_path=$(dirname $nova_state_path)
    iniset $CONF_FILE DEFAULT state_path ${root_state_path}/ec2api
fi

#init cache dir
echo Creating signing dir
sudo mkdir -p $AUTH_CACHE_DIR
sudo chown $USER $AUTH_CACHE_DIR
sudo rm -f $AUTH_CACHE_DIR/*

#install it
echo Installing package
if [[ -z "$VIRTUAL_ENV" ]]; then
  SUDO_PREFIX="sudo"
  if ! command -v pip >/dev/null; then
    sudo apt-get install python-pip
  fi
fi
$SUDO_PREFIX pip install -e ./
$SUDO_PREFIX rm -rf build ec2_api.egg-info

#recreate database
echo Setuping database
$SUDO_PREFIX tools/db/ec2api-db-setup deb

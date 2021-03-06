#!/bin/sh

IFACE="dummy0"
UNIT_TEST="./unit_tests/openvpn/networking_testdriver"
MAX_TEST=${1:-7}

KILL_EXEC=`which kill`
CC=${CC:-gcc}

srcdir="${srcdir:-.}"
top_builddir="${top_builddir:-..}"
openvpn="${top_builddir}/src/openvpn/openvpn"


# bail out right away on non-linux. NetLink (the object of this test) is only
# used on Linux, therefore testing other platform is not needed.
#
# Note: statements in the rest of the script may not even pass syntax check on
# solaris/bsd. It uses /bin/bash
if [ "$(uname -s)" != "Linux" ]; then
    echo "$0: this test runs only on Linux. SKIPPING TEST."
    exit 77
fi

# Commands used to retrieve the network state.
# State is retrieved after running sitnl and after running
# iproute commands. The two are then compared and expected to be equal.
typeset -a GET_STATE
GET_STATE[0]="ip link show dev $IFACE | sed 's/^[0-9]\+: //'"
GET_STATE[1]="ip addr show dev $IFACE | sed 's/^[0-9]\+: //'"
GET_STATE[2]="ip route show dev $IFACE"
GET_STATE[3]="ip -6 route show dev $IFACE"

LAST_STATE=$((${#GET_STATE[@]} - 1))

reload_dummy()
{
    $RUN_SUDO $openvpn --dev $IFACE --dev-type tun --rmtun >/dev/null
    $RUN_SUDO $openvpn --dev $IFACE --dev-type tun --mktun >/dev/null
    if [ $? -ne 0 ]; then
        echo "can't create interface $IFACE"
        exit 1
    fi

    #ip link set dev $IFACE address 00:11:22:33:44:55
}

run_test()
{
    # run all test cases from 0 to $1 in sequence
    CMD=
    for k in $(seq 0 $1); do
        # the unit-test prints to stdout the iproute command corresponding
        # to the sitnl operation being executed.
        # Format is "CMD: <commandhere>"
        OUT=$($RUN_SUDO $UNIT_TEST $k $IFACE)
        # ensure unit test worked properly
        if [ $? -ne 0 ]; then
            echo "unit-test $k errored out:"
            echo "$OUT"
            exit 1
        fi

        NEW=$(echo "$OUT" | sed -n 's/CMD: //p')
        CMD="$CMD $RUN_SUDO $NEW ;"
    done

    # collect state for later comparison
    for k in $(seq 0 $LAST_STATE); do
        STATE_TEST[$k]="$(eval ${GET_STATE[$k]})"
    done
}


## execution starts here

if [ -r "${top_builddir}"/t_client.rc ]; then
    . "${top_builddir}"/t_client.rc
elif [ -r "${srcdir}"/t_client.rc ]; then
    . "${srcdir}"/t_client.rc
else
    echo "$0: cannot find 't_client.rc' in build dir ('${top_builddir}')" >&2
    echo "$0: or source directory ('${srcdir}'). SKIPPING TEST." >&2
    exit 77
fi

if [ ! -x "$openvpn" ]; then
    echo "no (executable) openvpn binary in current build tree. FAIL." >&2
    exit 1
fi

if [ ! -x "$UNIT_TEST" ]; then
    echo "no test_networking driver available. SKIPPING TEST." >&2
    exit 77
fi


# Ensure PREFER_KSU is in a known state
PREFER_KSU="${PREFER_KSU:-0}"

# make sure we have permissions to run ifconfig/route from OpenVPN
# can't use "id -u" here - doesn't work on Solaris
ID=`id`
if expr "$ID" : "uid=0" >/dev/null
then :
else
    if [ "${PREFER_KSU}" -eq 1 ];
    then
        # Check if we have a valid kerberos ticket
        klist -l 1>/dev/null 2>/dev/null
        if [ $? -ne 0 ];
        then
            # No kerberos ticket found, skip ksu and fallback to RUN_SUDO
            PREFER_KSU=0
            echo "$0: No Kerberos ticket available.  Will not use ksu."
        else
            RUN_SUDO="ksu -q -e"
        fi
    fi

    if [ -z "$RUN_SUDO" ]
    then
        echo "$0: this test must run be as root, or RUN_SUDO=... " >&2
        echo "      must be set correctly in 't_client.rc'. SKIP." >&2
        exit 77
    else
        # We have to use sudo. Make sure that we (hopefully) do not have
        # to ask the users password during the test. This is done to
        # prevent timing issues, e.g. when the waits for openvpn to start
	    if $RUN_SUDO $KILL_EXEC -0 $$
        then
	        echo "$0: $RUN_SUDO $KILL_EXEC -0 succeeded, good."
        else
	        echo "$0: $RUN_SUDO $KILL_EXEC -0 failed, cannot go on. SKIP." >&2
	        exit 77
        fi
    fi
fi

for i in $(seq 0 $MAX_TEST); do
    # reload dummy module to cleanup state
    reload_dummy
    typeset -a STATE_TEST
    run_test $i

    # reload dummy module to cleanup state before running iproute commands
    reload_dummy

    # CMD has been set by the unit test
    eval $CMD
    if [ $? -ne 0 ]; then
        echo "error while executing:"
        echo "$CMD"
        exit 1
    fi

    # collect state after running manual ip command
    for k in $(seq 0 $LAST_STATE); do
        STATE_IP[$k]="$(eval ${GET_STATE[$k]})"
    done

    # ensure states after running unit test matches the one after running
    # manual iproute commands
    for j in $(seq 0 $LAST_STATE); do
        if [ "${STATE_TEST[$j]}" != "${STATE_IP[$j]}" ]; then
            echo "state $j mismatching after '$CMD'"
            echo "after unit-test:"
            echo "${STATE_TEST[$j]}"
            echo "after iproute command:"
            echo "${STATE_IP[$j]}"
            exit 1
        fi
    done

done

# remove interface for good
$RUN_SUDO $openvpn --dev $IFACE --dev-type tun --rmtun >/dev/null

exit 0

#!/bin/bash

##
# This script can be used to configure the Wildfly / JBoss EAP 7 instances used 
# to host the Blue Button Data Server WAR.
#
# Usage:
# 
# $ bluebutton-appserver-config.sh --serverhome /path-to-jboss --managementport 9090 --managementusername someadmin --managementpassword somepass --httpsport 443 --keystore /path-to-keystore --truststore /path-to-truststore --dburl "jdbc:something" --dbusername "some-db-user" --dbpassword "some-db-password" --dbconnectionsmax 42
##

# Constants.
serverReadyTimeoutSeconds=120
serverConnectTimeoutMilliseconds=$((30 * 1000))

# Calculate the directory that this script is in.
scriptDirectory="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Use GNU getopt to parse the options passed to this script.
TEMP=`getopt \
	-o h:m:U:P:s:k:t:u:n:p:c: \
	--long serverhome:,managementport:,managementusername:,managementpassword:,httpsport:,keystore:,truststore:,dburl:,dbusername:,dbpassword:,dbconnectionsmax: \
	-n 'bluebutton-appserver-config.sh' -- "$@"`
if [ $? != 0 ] ; then echo "Terminating." >&2 ; exit 1 ; fi

# Note the quotes around `$TEMP': they are essential!
eval set -- "$TEMP"

# Parse the getopt results.
serverHome=
managementPort=9990
managementUsername=
managementPassword=
httpsPort=
keyStore=
trustStore=
dbUrl=
dbUsername=""
dbPassword=""
dbConnectionsMax=
while true; do
	case "$1" in
		-h | --serverhome )
			serverHome="$2"; shift 2 ;;
		-m | --managementport )
			managementPort="$2"; shift 2 ;;
		-U | --managementusername )
			managementUsername="$2"; shift 2 ;;
		-P | --managementpassword )
			managementPassword="$2"; shift 2 ;;
		-s | --httpsport )
			httpsPort="$2"; shift 2 ;;
		-k | --keystore )
			keyStore="$2"; shift 2 ;;
		-t | --truststore )
			trustStore="$2"; shift 2 ;;
		-u | --dburl )
			dbUrl="$2"; shift 2 ;;
		-n | --dbusername )
			dbUsername="$2"; shift 2 ;;
		-p | --dbpassword )
			dbPassword="$2"; shift 2 ;;
		-c | --dbconnectionsmax )
			dbConnectionsMax="$2"; shift 2 ;;
		-- ) shift; break ;;
		* ) break ;;
	esac
done

# Verify that all required options were specified.
if [[ -z "${serverHome}" ]]; then >&2 echo 'The --serverhome option is required.'; exit 1; fi
if [[ -z "${httpsPort}" ]]; then >&2 echo 'The --httpsport option is required.'; exit 1; fi
if [[ -z "${keyStore}" ]]; then >&2 echo 'The --keystore option is required.'; exit 1; fi
if [[ -z "${trustStore}" ]]; then >&2 echo 'The --truststore option is required.'; exit 1; fi
if [[ -z "${dbUrl}" ]]; then >&2 echo 'The --dburl option is required.'; exit 1; fi
if [[ -z "${dbConnectionsMax}" ]]; then >&2 echo 'The --dbconnectionsmax option is required.'; exit 1; fi

# Exit immediately if something fails.
error() {
	local parent_lineno="$1"
	local message="$2"
	local code="${3:-1}"

	if [[ -n "$message" ]] ; then
		>&2 echo "Error on or near line ${parent_lineno}: ${message}; exiting with status ${code}"
	else
		>&2 echo "Error on or near line ${parent_lineno}; exiting with status ${code}"
	fi

	exit "${code}"
}
trap 'error ${LINENO}' ERR

# Check for required files.
for f in "${serverHome}/bin/jboss-cli.sh" "${keyStore}" "${trustStore}"; do
	if [[ ! -f "${f}" ]]; then
		>&2 echo "The following file is required but is missing: '${f}'."
		exit 1
	fi
done

# Clear the config log file.
> "${serverHome}/server-config.log"

# Determine the authentication arguments to use with the Wildfly CLI.
# Note: This isn't 100% secure. The CLI can't read the username and password 
# from a file, so they have to be specified as command line aguments. Such 
# arguments are visible in `/proc` and via `ps` while the command is running.
# For this script, that will only be a brief window, so the risk is acceptable.
cliArgsAuthentication=""
if [[ ! -z "${managementUsername}" ]]; then
	cliArgsAuthentication="--user=${managementUsername} --password=${managementPassword}"
fi

# Define a function that can wait for the server to be ready.
waitForServerReady() {
	echo "Waiting for server to be ready..." |& tee --append "${serverHome}/server-config.log"
	startSeconds=$SECONDS
	endSeconds=$(($startSeconds + $serverReadyTimeoutSeconds))
	while true; do
		if "${serverHome}/bin/jboss-cli.sh" --controller=localhost:${managementPort} --connect ${cliArgsAuthentication} --command=":read-attribute(name=server-state)" |& tee --append "${serverHome}/server-config.log" |& grep --quiet "\"result\" => \"running\""; then
			echo "Server ready after $(($SECONDS - $startSeconds)) seconds." |& tee --append "${serverHome}/server-config.log"
			break
		fi
		if [[ $SECONDS -gt $endSeconds ]]; then
			error ${LINENO} "Error: Server failed to be ready within ${serverReadyTimeoutSeconds} seconds." 3
		fi
		sleep 1
	done
}

# Wait for the server to be ready, in case this script is being called right
# after the server is started/restarted.
waitForServerReady

# Use the Wildfly CLI to configure the server.
# This has to be run first as until it's done and the server has reloaded, any 
# attempts to add an `https-listener` will fail.
# (Note: This interesting use of heredocs is documented here: http://unix.stackexchange.com/a/168434)
echo "Configuring server (enabling HTTPS)..."
cat <<EOF |
# Enable HTTPS.
if (outcome != success) of /core-service=management/security-realm=ApplicationRealm/server-identity=ssl:read-resource
	/core-service=management/security-realm=ApplicationRealm/server-identity=ssl:add(keystore-path="${keyStore}",keystore-password="changeit",key-password="changeit")

	# Reload the server to apply those changes.
	:reload
end-if
EOF
"${serverHome}/bin/jboss-cli.sh" \
	--controller=localhost:${managementPort} \
	--connect \
	--timeout=${serverConnectTimeoutMilliseconds} \
	${cliArgsAuthentication} \
	--file=/dev/stdin \
	&>> "${serverHome}/server-config.log"
echo "Server configured successfully (HTTPS enabled)."
waitForServerReady

# Use the Wildfly CLI to configure the server.
# (Note: This interesting use of heredocs is documented here: http://unix.stackexchange.com/a/168434)
echo "Configuring server (everything else)..."
cat <<EOF |
# Set applications to use SLF4J for the logging, rather than JBoss' builtin 
# logger. See jboss-deployment-structure.xml for details.
if (outcome == success) of /system-property=org.jboss.logging.provider:read-resource
	/system-property=org.jboss.logging.provider:remove
end-if
/system-property=org.jboss.logging.provider:add(value="slf4j")

# Set the Java system properties that are required to configure the FHIR server.
if (outcome == success) of /system-property=bbfhir.logs.dir:read-resource
	/system-property=bbfhir.logs.dir:remove
end-if
if (outcome == success) of /system-property=bbfhir.db.url:read-resource
	/system-property=bbfhir.db.url:remove
end-if
if (outcome == success) of /system-property=bbfhir.db.username:read-resource
	/system-property=bbfhir.db.username:remove
end-if
if (outcome == success) of /system-property=bbfhir.db.password:read-resource
	/system-property=bbfhir.db.password:remove
end-if
if (outcome == success) of /system-property=bbfhir.db.connections.max:read-resource
	/system-property=bbfhir.db.connections.max:remove
end-if

/system-property=bbfhir.logs.dir:add(value="./")
/system-property=bbfhir.db.url:add(value="${dbUrl}")
/system-property=bbfhir.db.username:add(value="${dbUsername}")
/system-property=bbfhir.db.password:add(value="${dbPassword}")
/system-property=bbfhir.db.connections.max:add(value="${dbConnectionsMax}")

# Configure HTTPS.
/core-service=management/security-realm=ApplicationRealm/server-identity=ssl:remove
/core-service=management/security-realm=ApplicationRealm/server-identity=ssl:add(keystore-path="${keyStore}",keystore-password="changeit",key-password="changeit")
if (outcome != success) of /subsystem=undertow/server=default-server/https-listener=https:read-resource
	/subsystem=undertow/server=default-server/https-listener=https:add(socket-binding=https,security-realm=ApplicationRealm)
end-if
/socket-binding-group=standard-sockets/socket-binding=https/:write-attribute(name=port,value="${httpsPort}")

# Per the recommendations on https://wiki.mozilla.org/Security/Server_Side_TLS,
# we only support TLS v1.2 and the cipher suites listed below. The cipher
# suites have two names: their names from their specification and their names
# in OpenSSL. JBoss/Wildfly require the spec names, though most docs use the
# OpenSSL names. The OpenSSL docs contain a mapping of the names:
# https://www.openssl.org/docs/man1.1.0/apps/ciphers.html.
#
# +===============================================+===============================+
# | Specification Name                            | OpenSSL Name                  |
# +===============================================|===============================+
# | TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384       | ECDHE-ECDSA-AES256-GCM-SHA384 |
# | TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384         | ECDHE-RSA-AES256-GCM-SHA384   |
# | TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256 | ECDHE-ECDSA-CHACHA20-POLY1305 |
# | TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256   | ECDHE-RSA-CHACHA20-POLY1305   |
# | TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256       | ECDHE-ECDSA-AES128-GCM-SHA256 |
# | TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256         | ECDHE-RSA-AES128-GCM-SHA256   |
# | TLS_ECDHE_ECDSA_WITH_AES_256_CBC_SHA384       | ECDHE-ECDSA-AES256-SHA384     |
# | TLS_ECDHE_RSA_WITH_AES_256_CBC_SHA384         | ECDHE-RSA-AES256-SHA384       |
# | TLS_ECDHE_ECDSA_WITH_AES_128_CBC_SHA256       | ECDHE-ECDSA-AES128-SHA256     |
# | TLS_ECDHE_RSA_WITH_AES_128_CBC_SHA256         | ECDHE-RSA-AES128-SHA256       |
# +-----------------------------------------------+-------------------------------+
#
# Note: Turns out that, for some unknown reason, the ChaCha20 algorithms aren't
# supported in our HealthAPT AWS environments, which use JBoss EAP 7.0 (JBoss
# fails to start if they're enabled, with an error). So we exclude them from
# `enabled-cipher-suites`.
/subsystem=undertow/server=default-server/https-listener=https/:write-attribute(name=enabled-protocols,value="TLSv1.2")
/subsystem=undertow/server=default-server/https-listener=https/:write-attribute(name=enabled-cipher-suites,value="TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384,TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384,TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_ECDSA_WITH_AES_256_CBC_SHA384,TLS_ECDHE_RSA_WITH_AES_256_CBC_SHA384,TLS_ECDHE_ECDSA_WITH_AES_128_CBC_SHA256,TLS_ECDHE_RSA_WITH_AES_128_CBC_SHA256")

# Configure and enable mandatory client-auth SSL.
if (outcome == success) of /core-service=management/security-realm=ApplicationRealm/authentication=truststore:read-resource
	/core-service=management/security-realm=ApplicationRealm/authentication=truststore:remove
end-if
/core-service=management/security-realm=ApplicationRealm/authentication=truststore:add(keystore-path="${trustStore}",keystore-password=changeit)
/subsystem=undertow/server=default-server/https-listener=https:write-attribute(name=verify-client,value=REQUIRED)

# Disable HTTP.
if (outcome == success) of /subsystem=undertow/server=default-server/http-listener=default:read-resource
	/subsystem=undertow/server=default-server/http-listener=default:remove()
end-if
/subsystem=remoting/http-connector=http-remoting-connector:write-attribute(name=connector-ref,value=https)

# These data sources were initially configured on the servers, but the app doesn't use them.
/subsystem=ee/service=default-bindings:undefine-attribute(name=datasource)
if (outcome == success) of /subsystem=datasources/data-source=fhirds:read-resource
	/subsystem=datasources/data-source=fhirds:remove
end-if
if (outcome == success) of /subsystem=datasources/data-source=ExampleDS:read-resource
	/subsystem=datasources/data-source=ExampleDS:remove
end-if
if (outcome == success) of /subsystem=datasources/data-source=TestProdFHIR:read-resource
	/subsystem=datasources/data-source=TestProdFHIR:remove
end-if

# Configure the server to listen on all configured IPs.
/interface=public:undefine-attribute(name=inet-address)
/interface=public:write-attribute(name=any-address,value=true)

# Enable and configure HTTP access logging.
# 
# References:
# * https://kb.novaordis.com/index.php/Undertow_WildFly_Subsystem_Configuration_-_access-log
# * https://stackoverflow.com/questions/34614874/wildfly-9-access-logging
/subsystem=undertow/server=default-server/https-listener=https:write-attribute(name=record-request-start-time,value=true)
if (outcome == success) of /subsystem=undertow/server=default-server/host=default-host/setting=access-log:read-resource
	/subsystem=undertow/server=default-server/host=default-host/setting=access-log:remove
end-if
/subsystem=undertow/server=default-server/host=default-host/setting=access-log:add(pattern="%h %l %u %t \\"%r\\" \\"?%q\\" %s %B %D", directory="\${jboss.server.log.dir}", prefix="access", suffix=".log")

# Reload the server to apply those changes.
:reload
EOF
"${serverHome}/bin/jboss-cli.sh" \
	--controller=localhost:${managementPort} \
	--connect \
	--timeout=${serverConnectTimeoutMilliseconds} \
	${cliArgsAuthentication} \
	--file=/dev/stdin \
	&>> "${serverHome}/server-config.log"
echo "Server configured successfully."
waitForServerReady


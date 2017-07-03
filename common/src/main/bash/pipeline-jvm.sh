#!/bin/bash
set -e

# It takes ages on Docker to run the app without this
export MAVEN_OPTS="${MAVEN_OPTS} -Djava.security.egd=file:///dev/urandom"

function build() {
    echo "Additional Maven Args [${MAVEN_ARGS}]"

    if [[ "${PROJECT_TYPE}" == "MAVEN" ]]; then
        ./mvnw versions:set -DnewVersion=${PIPELINE_VERSION} ${MAVEN_ARGS}
        if [[ "${CI}" == "CONCOURSE" ]]; then
            ./mvnw clean verify deploy -Ddistribution.management.release.id=${M2_SETTINGS_REPO_ID} -Ddistribution.management.release.url=${REPO_WITH_BINARIES} ${MAVEN_ARGS} || ( $( printTestResults ) && return 1)
        else
            ./mvnw clean verify deploy -Ddistribution.management.release.id=${M2_SETTINGS_REPO_ID} -Ddistribution.management.release.url=${REPO_WITH_BINARIES} ${MAVEN_ARGS}
        fi
    elif [[ "${PROJECT_TYPE}" == "GRADLE" ]]; then
        if [[ "${CI}" == "CONCOURSE" ]]; then
            ./gradlew clean build deploy -PnewVersion=${PIPELINE_VERSION} -DREPO_WITH_BINARIES=${REPO_WITH_BINARIES} --stacktrace  || ( $( printTestResults ) && return 1)
        else
            ./gradlew clean build deploy -PnewVersion=${PIPELINE_VERSION} -DREPO_WITH_BINARIES=${REPO_WITH_BINARIES} --stacktrace
        fi
    else
        echo "Unsupported project build tool"
        return 1
    fi
}

function apiCompatibilityCheck() {
    echo "Running retrieval of group and artifactid to download all dependencies. It might take a while..."
    projectGroupId=$( retrieveGroupId )
    appName=$( retrieveAppName )

    # Find latest prod version
    LATEST_PROD_TAG=$( findLatestProdTag )
    echo "Last prod tag equals ${LATEST_PROD_TAG}"
    if [[ -z "${LATEST_PROD_TAG}" ]]; then
        echo "No prod release took place - skipping this step"
    else
        # Downloading latest jar
        LATEST_PROD_VERSION=${LATEST_PROD_TAG#prod/}
        echo "Last prod version equals ${LATEST_PROD_VERSION}"
        echo "Additional Maven Args [${MAVEN_ARGS}]"
        if [[ "${PROJECT_TYPE}" == "MAVEN" ]]; then
            if [[ "${CI}" == "CONCOURSE" ]]; then
                ./mvnw clean verify -Papicompatibility -Dlatest.production.version=${LATEST_PROD_VERSION} -Drepo.with.jars=${REPO_WITH_BINARIES} ${MAVEN_ARGS} || ( $( printTestResults ) && return 1)
            else
                ./mvnw clean verify -Papicompatibility -Dlatest.production.version=${LATEST_PROD_VERSION} -Drepo.with.jars=${REPO_WITH_BINARIES} ${MAVEN_ARGS}
            fi
        elif [[ "${PROJECT_TYPE}" == "GRADLE" ]]; then
            if [[ "${CI}" == "CONCOURSE" ]]; then
                ./gradlew clean apiCompatibility -DlatestProductionVersion=${LATEST_PROD_VERSION} -DREPO_WITH_BINARIES=${REPO_WITH_BINARIES} --stacktrace  || ( $( printTestResults ) && return 1)
            else
                ./gradlew clean apiCompatibility -DlatestProductionVersion=${LATEST_PROD_VERSION} -DREPO_WITH_BINARIES=${REPO_WITH_BINARIES} --stacktrace
            fi
        else
            echo "Unsupported project build tool"
            return 1
        fi
    fi
}

# The function uses Maven Wrapper - if you're using Maven you have to have it on your classpath
# and change this function
function extractMavenProperty() {
    local prop="${1}"
    MAVEN_PROPERTY=$(./mvnw ${MAVEN_ARGS} -q \
                    -Dexec.executable="echo" \
                    -Dexec.args="\${${prop}}" \
                    --non-recursive \
                    org.codehaus.mojo:exec-maven-plugin:1.3.1:exec)
    # In some spring cloud projects there is info about deactivating some stuff
    MAVEN_PROPERTY=$( echo "${MAVEN_PROPERTY}" | tail -1 )
    # In Maven if there is no property it prints out ${propname}
    if [[ "${MAVEN_PROPERTY}" == "\${${prop}}" ]]; then
        echo ""
    else
        echo "${MAVEN_PROPERTY}"
    fi
}

function downloadAppBinary() {
    local redownloadInfra="${1}"
    local repoWithJars="${2}"
    local groupId="${3}"
    local artifactId="${4}"
    local version="${5}"
    local destination="`pwd`/${OUTPUT_FOLDER}/${artifactId}-${version}.jar"
    local changedGroupId="$( echo "${groupId}" | tr . / )"
    local pathToJar="${repoWithJars}/${changedGroupId}/${artifactId}/${version}/${artifactId}-${version}.jar"
    if [[ ! -e ${destination} || ( -e ${destination} && ${redownloadInfra} == "true" ) ]]; then
        mkdir -p "${OUTPUT_FOLDER}"
        echo "Current folder is [`pwd`]; Downloading [${pathToJar}] to [${destination}]"
        (curl "${pathToJar}" -o "${destination}" --fail && echo "File downloaded successfully!") || (echo "Failed to download file!" && return 1)
    else
        echo "File [${destination}] exists and redownload flag was set to false. Will not download it again"
    fi
}

function retrieveGroupId() {
    if [[ "${PROJECT_TYPE}" == "GRADLE" ]]; then
        local result=$( ./gradlew groupId -q )
        result=$( echo "${result}" | tail -1 )
        echo "${result}"
    else
        local result=$( ruby -r rexml/document -e 'puts REXML::Document.new(File.new(ARGV.shift)).elements["/project/groupId"].text' pom.xml || ./mvnw ${MAVEN_ARGS} org.apache.maven.plugins:maven-help-plugin:2.2:evaluate -Dexpression=project.groupId |grep -Ev '(^\[|Download\w+:)' )
        result=$( echo "${result}" | tail -1 )
        echo "${result}"
    fi
}

function retrieveAppName() {
    if [[ "${PROJECT_TYPE}" == "GRADLE" ]]; then
        local result=$( ./gradlew artifactId -q )
        result=$( echo "${result}" | tail -1 )
        echo "${result}"
    else
        local result=$( ruby -r rexml/document -e 'puts REXML::Document.new(File.new(ARGV.shift)).elements["/project/artifactId"].text' pom.xml || ./mvnw ${MAVEN_ARGS} org.apache.maven.plugins:maven-help-plugin:2.2:evaluate -Dexpression=project.artifactId |grep -Ev '(^\[|Download\w+:)' )
        result=$( echo "${result}" | tail -1 )
        echo "${result}"
    fi
}

function printTestResults() {
    echo -e "\n\nBuild failed!!! - will print all test results to the console (it's the easiest way to debug anything later)\n\n" && tail -n +1 "$( testResultsAntPattern )"
}

function retrieveStubRunnerIds() {
    if [[ "${PROJECT_TYPE}" == "GRADLE" ]]; then
        echo "$( ./gradlew stubIds -q | tail -1 )"
    else
        echo "$( extractMavenProperty 'stubrunner.ids' )"
    fi
}

function runSmokeTests() {
    local applicationHost="${APPLICATION_URL}"
    local stubrunnerHost="${STUBRUNNER_URL}"
    echo "Running smoke tests"

    if [[ "${PROJECT_TYPE}" == "MAVEN" ]]; then
        if [[ "${CI}" == "CONCOURSE" ]]; then
            ./mvnw clean install -Psmoke -Dapplication.url="${applicationHost}" -Dstubrunner.url="${stubrunnerHost}" ${MAVEN_ARGS} || ( echo "$( printTestResults )" && return 1)
        else
            ./mvnw clean install -Psmoke -Dapplication.url="${applicationHost}" -Dstubrunner.url="${stubrunnerHost}" ${MAVEN_ARGS}
        fi
    elif [[ "${PROJECT_TYPE}" == "GRADLE" ]]; then
        if [[ "${CI}" == "CONCOURSE" ]]; then
            ./gradlew smoke -PnewVersion=${PIPELINE_VERSION} -Dapplication.url="${applicationHost}" -Dstubrunner.url="${stubrunnerHost}" || ( echo "$( printTestResults )" && return 1)
        else
            ./gradlew smoke -PnewVersion=${PIPELINE_VERSION} -Dapplication.url="${applicationHost}" -Dstubrunner.url="${stubrunnerHost}"
        fi
    else
        echo "Unsupported project build tool"
        return 1
    fi
}

function runE2eTests() {
    local applicationHost="${APPLICATION_URL}"
    echo "Running e2e tests"

    if [[ "${PROJECT_TYPE}" == "MAVEN" ]]; then
        if [[ "${CI}" == "CONCOURSE" ]]; then
            ./mvnw clean install -Pe2e -Dapplication.url="${applicationHost}" ${BUILD_OPTIONS} || ( $( printTestResults ) && return 1)
        else
            ./mvnw clean install -Pe2e -Dapplication.url="${applicationHost}" ${BUILD_OPTIONS}
        fi
    elif [[ "${PROJECT_TYPE}" == "GRADLE" ]]; then
        if [[ "${CI}" == "CONCOURSE" ]]; then
            ./gradlew e2e -PnewVersion=${PIPELINE_VERSION} -Dapplication.url="${applicationHost}" ${BUILD_OPTIONS} || ( $( printTestResults ) && return 1)
        else
            ./gradlew e2e -PnewVersion=${PIPELINE_VERSION} -Dapplication.url="${applicationHost}" ${BUILD_OPTIONS}
        fi
    else
        echo "Unsupported project build tool"
        return 1
    fi
}


function isMavenProject() {
    [ -f "mvnw" ]
}

function isGradleProject() {
    [ -f "gradlew" ]
}

# TODO: consider also a project descriptor file
# that could override these values
function projectType() {
    if isMavenProject; then
        echo "MAVEN"
    elif isGradleProject; then
        echo "GRADLE"
    else
        echo "UNKNOWN"
    fi
}

function outputFolder() {
    if [[ "${PROJECT_TYPE}" == "GRADLE" ]]; then
        echo "build/libs"
    else
        echo "target"
    fi
}

function testResultsAntPattern() {
    if [[ "${PROJECT_TYPE}" == "GRADLE" ]]; then
        echo "**/test-results/*.xml"
    else
        echo "**/surefire-reports/*"
    fi
}

# TODO: Consider adding project type dependant sourcing
# e.g. pipeline-gradle.sh , pipeline-maven.sh
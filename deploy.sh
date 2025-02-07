#!/bin/bash

# Helper Functions
function banner() {
    clear
    echo '           _______   __           _   ______   ________            '
    echo '     /\   |  __ \ \ / /          | | |  _   | |__   ___|           '
    echo '    /  \  | |  | \ V /   ______  | | | |  | |    |  |              '
    echo "   / /\ \ | |  | |> <   |______| | | | |  | |    |  |              "
    echo '  / ____ \| |__| / . \           | | | |__| |    |  |              '
    echo ' /_/    \_\_____/_/_\_\          |_| |_____ |    |_ |              '
    echo '        |__   __| | |                   | |                        '
    echo '           | | ___| | ___ _ __ ___   ___| |_ _ __ _   _            '
    echo "           | |/ _ \ |/ _ \ '_ \` _ \ / _ \ __| '__| | | |          "
    echo '           | |  __/ |  __/ | | | | |  __/ |_| |  | |_| |           '
    echo '           |_|\___|_|\___|_| |_| |_|\___|\__|_|   \__, |           '
    echo '                                                   __/ |           '
    echo '                                                  |___/            '
}

function spinner() {
    local info="$1"
    local pid=$!
    local delay=0.75
    local spinstr='|/-\'
    while kill -0 $pid 2> /dev/null; do
        local temp=${spinstr#?}
        printf " [%c]  $info" "$spinstr"
        local spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        echo -ne "\033[0K\r"
    done
}

function deletePreLine() {
    echo -ne '\033[1A'
    echo -ne "\r\033[0K"
}

# Service Specific Functions
function add_required_extensions() {
    az extension add --name azure-iot --only-show-errors --output none; \
    az extension update --name azure-iot --only-show-errors --output none; \
    az extension add --name kusto --only-show-errors --output none; \
    az extension update --name kusto --only-show-errors --output none
}

function create_resource_group() {
    az group create --name $rgName --location "East US" --only-show-errors --output none
}

function deploy_azure_services() {
    if [ $iotCType -eq 1 ] 
    then
        az deployment group create -n $deploymentName -g $rgName \
            --template-file main.bicep \
            --parameters deploymentSuffix=$randomNum @iotanalyticsStore.parameters.json \
            --only-show-errors --output none
    else
        az deployment group create -n $deploymentName -g $rgName \
            --template-file main.bicep \
            --parameters deploymentSuffix=$randomNum @iotanalyticsLogistics.parameters.json \
            --only-show-errors --output none
    fi
}

function get_deployment_output() {
    dtName=$(az deployment group show -n $deploymentName -g $rgName --query properties.outputs.digitalTwinName.value --output tsv)
    dtHostName=$(az deployment group show -n $deploymentName -g $rgName --query properties.outputs.digitalTwinHostName.value --output tsv)
    saName=$(az deployment group show -n $deploymentName -g $rgName --query properties.outputs.saName.value --output tsv)
    saKey=$(az storage account keys list --account-name $saName --query [0].value -o tsv)
    saId=$(az deployment group show -n $deploymentName -g $rgName --query properties.outputs.saId.value --output tsv)
    adtID=$(az deployment group show -n $deploymentName -g $rgName --query properties.outputs.digitalTwinId.value --output tsv)
    adxName=$(az deployment group show -n $deploymentName -g $rgName --query properties.outputs.adxName.value --output tsv)
    adxResoureId=$(az deployment group show -n $deploymentName -g $rgName --query properties.outputs.adxClusterId.value --output tsv)
    location=$(az deployment group show -n $deploymentName -g $rgName --query properties.outputs.location.value --output tsv)
    eventHubNSId=$(az deployment group show -n $deploymentName -g $rgName --query properties.outputs.eventhubClusterId.value --output tsv)
    eventHubResourceId="$eventHubNSId/eventhubs/iotdata"
    eventHubHistoricId="$eventHubNSId/eventhubs/historicdata"
    iotCentralName=$(az deployment group show -n $deploymentName -g $rgName --query properties.outputs.iotCentralName.value --output tsv)
    iotCentralAppID=$(az iot central app show -n $iotCentralName -g $rgName --query  applicationId --output tsv)
    numDevices=$(az deployment group show -n $deploymentName -g $rgName --query properties.outputs.deviceNumber.value --output tsv)
    eventHubConnectionString=$(az deployment group show -n $deploymentName -g $rgName --query properties.outputs.eventHubConnectionString.value --output tsv)
    deployADX=$(az deployment group show -n $deploymentName -g $rgName --query properties.outputs.deployADX.value --output tsv)
    deployADT=$(az deployment group show -n $deploymentName -g $rgName --query properties.outputs.deployADT.value --output tsv)
    iotCentralType=$(az deployment group show -n $deploymentName -g $rgName --query properties.outputs.iotCentralType.value --output tsv)
}

function configure_ADX_cluster() {
    sed -i "s/<dtURI>/$dtHostName/g" config/configDB.kql ;\
    #sed -i "s/<saname>/$saName/g" config/configDB.kql ;\
    #sed -i "s/<sakey>/$saKey/g" config/configDB.kql ;\
    az storage blob upload -f config/configDB.kql -c adxscript -n configDB.kql \
        --account-key $saKey --account-name $saName --only-show-errors --output none  ;\
    blobURI="https://$saName.blob.core.windows.net/adxscript/configDB.kql"  ;\
    blobSAS=$(az storage blob generate-sas --account-name $saName --container-name adxscript \
        --name configDB.kql --permissions acdrw --expiry $tomorrow --account-key $saKey --output tsv)  ;\
    az kusto script create --cluster-name $adxName --database-name IoTAnalytics  \
        --force-update-tag "config1" --script-url $blobURI --script-url-sas-token $blobSAS \
        --resource-group $rgName --name 'configDB' --only-show-errors --output none  ;\
    az kusto data-connection event-hub create --cluster-name $adxName --name "IoTAnalytics" \
        --database-name "IoTAnalytics" --location $location --consumer-group '$Default' \
        --event-hub-resource-id $eventHubResourceId --managed-identity-resource-id $adxResoureId \
        --data-format 'JSON' --table-name 'StageIoTRawData' --mapping-rule-name 'StageIoTRawData_mapping' \
        --compression 'None' --resource-group $rgName --only-show-errors --output none

    az kusto data-connection event-grid create --cluster-name $adxName -g $rgName --database-name "IoTAnalytics" \
        --table-name "Thermostats" --name "HistoricalLoad" --ignore-first-record true --data-format csv  \
        --mapping-rule-name "Thermostats_mapping" --storage-account-resource-id $saId \
        --consumer-group '$Default' --event-hub-resource-id $eventHubHistoricId
    az storage blob upload -f config/Thermostat_January2022.csv -c adxscript -n Thermostat_January2022.csv \
        --account-key $saKey --account-name $saName --only-show-errors --output none  ;\
}

function upload_JSON_storage() {
    az storage copy -s 'https://adxmicrohacksa.blob.core.windows.net/nyc-taxi-july-22?sp=rl&st=2022-08-02T13:49:40Z&se=2025-08-02T21:49:40Z&spr=https&sv=2021-06-08&sr=c&sig=H7AMVTINcdg8cuGjWNp3yqYyDDWC1uyCTMiEQmbxBqU%3D' --destination-account-name $saName --destination-container data --recursive --only-show-errors --output none ;\

    az storage copy -s 'https://adxmicrohacksa.blob.core.windows.net/logistics-telemetry-data-july-22?sp=rl&st=2022-08-02T13:54:43Z&se=2024-08-02T21:54:43Z&spr=https&sv=2021-06-08&sr=c&sig=VjcLSN6vylf%2BfvsB5WiDFhNUuT514YPiDHfWaMl9PgQ%3D' --destination-account-name $saName --destination-container data --recursive --only-show-errors --output none ;\
}

function deploy_thermostat_devices() {
    az iot central device delete --device-id 'Thermostat' --app-id $iotCentralAppID --output none
    az iot central device delete --device-id 'Occupancy' --app-id $iotCentralAppID --output none
    if [ "$iotCentralType" == 'Store Analytics' ] 
    then
        iotCentralTemplate='dtmi:m43gbjjsrr5:fp1yz0dm0qs'
    else
        iotCentralTemplate='dtmi:ltifbs50b:mecybcwqm'
    fi
    for (( c=1; c<=$numDevices; c++ ))
    do 
        deviceId=$(cat /proc/sys/kernel/random/uuid)
        az iot central device create --device-id $deviceId --app-id $iotCentralAppID \
            --template $iotCentralTemplate --simulated --only-show-errors --output none
    done
}

function configure_IoT_Central_output() {
    az iot central export destination create --app-id $iotCentralAppID --dest-id 'eventHubExport' \
        --type eventhubs@v1 --name 'eventHubExport' \
        --authorization '{"type": "connectionString", "connectionString": "'$eventHubConnectionString'" }' \
        --only-show-errors --output none  ; \
    az iot central export create --app-id $iotCentralAppID --export-id 'iotEventHubExport' \
        --display-name 'iotEventHubExport' --source 'telemetry' --destinations '[{"id": "eventHubExport"}]' \
        --only-show-errors --output none
}

# Define required variables
randomNum=$RANDOM
currentDate=$(date)
tomorrow=$(date +"%Y-%m-%dT00:00:00Z" -d "$currentDate +1 days")
deploymentName=ADXIoTAnalyticsDeployment$randomNum
rgName=ADXIoTAnalytics$randomNum

echo $deploymentName > output.txt
echo $rgName >> output.txt


clear
echo "Please select from below deployment options"
echo "     1. ADX IoT Workshop"
echo "     2. ADX IoT Micro Hack"
read -p "Enter number:" iotCType

while [ $iotCType != 1 ] && [ $iotCType != 2 ]
do
    echo "UNKNOWN OPTION SELECTED :("
    echo "Please select from below deployment options"
    echo "     1. ADX IoT Workshop"
    echo "     2. ADX IoT Micro Hack"
    read -p "Enter number:" iotCType
done


# Setup array to utilize when assiging devices to departments and patients
floors=('DAL1' 'DAL2' 'DAL3' 'DAL4' 'DAL5' 'DAL6' 'SEA1' 'SEA2' 'SEA3' 'SEA4' 'SEA5' 'SEA6' 'ATL1' 'ATL2' 'ATL3' 'ATL4' 'ATL5' 'ATL6')

banner # Show Welcome banner

if [ $iotCType -eq 1 ]
then
    echo '1. Starting deployment of IoT Analytics Lab'
else
    echo '1. Starting deployment of IoT Open Hack Environment'
fi

add_required_extensions & # Install/Update required eztensions
spinner "Installing IoT Extensions"
create_resource_group & # Create parent resurce group
spinner "Creating Resource Group with name $rgName"
deploy_azure_services & # Create all additional services using main Bicep template
spinner "Deploying Azure Services"

echo "2. Starting configuration for deployment $deploymentName"
get_deployment_output  # Get Deployment output values

# Start Configuration
if [ $deployADX == true ] 
then
    configure_ADX_cluster & # Configure ADX cluster
    spinner "Configuring ADX Cluster"
fi

# Get/Refresh IoT Central Token 
az account get-access-token --resource https://apps.azureiotcentral.com --only-show-errors --output none

# Complete configuration
if [ $deployADT == true ] 
then
    echo "Creating $numDevices devices on IoT Central: $iotCentralName ($iotCentralAppID)"
    deploy_thermostat_devices # Deploy Thermostat simulated devices
    configure_IoT_Central_output & # On IoT Central, create an Event Hub export and destination with json payload
    spinner " Creating IoT Central App export and destination on IoT Central: $iotCentralName ($iotCentralAppID)"
else
    echo "Creating $numDevices devices on IoT Central: $iotCentralName ($iotCentralAppID)"
    deploy_thermostat_devices # Deploy Thermostat simulated devices
    configure_IoT_Central_output & # On IoT Central, create an Event Hub export and destination with json payload
    spinner " Creating IoT Central App export and destination on IoT Central: $iotCentralName ($iotCentralAppID)"
fi

if [ $iotCType -eq 2 ]
then
    upload_JSON_storage
    spinner " Uploading json files to storage account"
fi

if [ $iotCType -eq 1 ]
then
    echo 'Continue with directions on ADX-IoT-Analytics-Accelerator GitHub Page'
else
    echo "3. Configuration completed"
fi



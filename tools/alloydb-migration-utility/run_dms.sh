#!/bin/bash

CONFIG_FILE="migration.config" 

GREEN=$(tput setaf 2)
YELLOW=$(tput setaf 3)
RED=$(tput setaf 1)
BOLD=$(tput bold)
NC=$(tput sgr0)

# Source the banner script (assuming it exists in the same directory)
if [ -f "./banner.sh" ]; then
  source ./banner.sh
else
  echo "Warning: banner not found."
fi

echo -e "\n\nSelect the source PostgreSQL type:\n"
echo "1. On-premise"
echo "2. AWS"
echo "3. Azure"

read -p "Enter your choice (1-3): " source_type

# Validate source_type input
case "$source_type" in
  1)
    source_type_name="On-premise"
    ;;
  2)
    source_type_name="AWS"
    ;;
  3)
    source_type_name="Azure"
    ;;
  *)
    echo -e "\nError: Invalid source type selected. Please enter a number between 1 and 3."
    exit 1 # Exit with an error code
    ;;
esac

echo -e "\n\nSelect the target type:\n"
echo "1. AlloyDB"
echo "2. CloudSQL"

read -p "Enter your choice (1-2): " target_type

# Validate target_type input
case "$target_type" in
  1)
    target_type_name="AlloyDB"
    ;;
  2)
    target_type_name="CloudSQL"
    ;;
  *)
    echo -e "\nError: Invalid target type selected. Please enter either 1 or 2."
    exit 1 # Exit with an error code
    ;;
esac

if [[ -f "$CONFIG_FILE" ]]; then
  echo "\nLoading your configuration from $CONFIG_FILE"
  source "$CONFIG_FILE"
else
  echo "\nWarning: Configuration file '$CONFIG_FILE' not found. "
fi

echo ""
echo "-------------------------------------------------------------------------------------"
echo "You are about to migrate databases from ${GREEN}$source_type_name${NC} to ${GREEN}$target_type_name${NC}."
echo "-------------------------------------------------------------------------------------"
echo ""

# Create the connection profile for source(PostgreSQL DB)
# Provide --cloudsql-instance if source DB is CloudSQL(Postgre) 

echo "${YELLOW}Creating source profile...${NC}"

# connection profile for source DB
gcloud database-migration connection-profiles create postgresql "$SOURCE_PROFILE_NAME" \
    --region="$REGION" \
    --display-name="$SOURCE_PROFILE_NAME" \
    --username="$SOURCE_USER" \
    --host="$SOURCE_HOST" \
    --port="$SOURCE_PORT" \
    --prompt-for-password \
    --project="$PROJECT_ID"

# Check if the profile creation was successful
if [ $? -eq 0 ]; then
  echo "${GREEN}Connection profile \"${BOLD}$SOURCE_PROFILE_NAME${NC}${GREEN}\" created successfully.${NC}"
else
  echo "${RED}Error: Failed to create connection profile \"${BOLD}$SOURCE_PROFILE_NAME${NC}${RED}\".${NC}"
  exit 1
fi

# Create the connection profile for alloyDB/CloudSQL(postgresql) destination
# Provide --cloudsql-instance if source DB is CLoudSQL(Postgre) else provide --alloydb-cluster property.

if (( target_type_name == "AlloyDB" )); then
    echo "${YELLOW}creating destination profile for AlloyDB...${NC}"
    gcloud database-migration connection-profiles create postgresql $DESTINATION_PROFILE_NAME \
    --region=$REGION \
    --display-name=$DESTINATION_PROFILE_NAME \
    --alloydb-cluster=$DESTINATION_ALLOYDB \
    --username=$DESTINATION_USER \
    --host=$DESTINATION_HOST \
    --port=$DESTINATION_PORT \
    --prompt-for-password \
    --project=$PROJECT_ID
else
    echo "${YELLOW}creating destination profile for CloudSQL...${NC}"
    gcloud database-migration connection-profiles create postgresql $DESTINATION_PROFILE_NAME \
    --region=$REGION \
    --display-name=$DESTINATION_PROFILE_NAME \
    --cloudsql-instance=$DESTINATION_CloudSQL_INSTANCE_NAME \
    --username=$DESTINATION_USER \
    --host=$DESTINATION_HOST \
    --port=$DESTINATION_PORT \
    --prompt-for-password \
    --project=$PROJECT_ID
fi

# Check if the profile creation was successful
if [ $? -eq 0 ]; then
  echo "${GREEN}Connection profile \"${BOLD}$DESTINATION_PROFILE_NAME${NC}${GREEN}\" created successfully.${NC}"
else
  echo "${RED}Error: Failed to create connection profile \"${BOLD}$DESTINATION_PROFILE_NAME${NC}${RED}\".${NC}"
  exit 1
fi


# Create Migration Job

echo "${YELLOW}creating database migration job...${NC}"

# Create migration job 
# For VPC Peering (test)
# For Reverse-SSH Proxy provide the additional properties of --vm, --vm-ip, --vm-port and --vpc in the migration.config file

# Print Notes:
echo ""
echo "${BOLD}Note: By Default the tool uses VPC peering.${NC}"
echo "${BOLD}For Reverse-SSH Proxy provide the additional properties of --vm, --vm-ip, --vm-port and --vpc in the migration.config file\n${NC}"

if [ -v VM_NAME ]; then
    gcloud database-migration migration-jobs create $MIGRATION_JOB_NAME \
    --region=$REGION \
    --type=$MIGRATION_TYPE \
    --source=$SOURCE_PROFILE_NAME \
    --destination=$DESTINATION_PROFILE_NAME \
    --project=$PROJECT_ID --vm=$VM_NAME --vm-ip=$VM_IP_ADDRESS --vm-port=$VM_PORT --vpc=$VPC
else
    gcloud database-migration migration-jobs create $MIGRATION_JOB_NAME \
    --region=$REGION \
    --type=$MIGRATION_TYPE \
    --source=$SOURCE_PROFILE_NAME \
    --destination=$DESTINATION_PROFILE_NAME \
    --peer-vpc=$MIGRATION_NETWORK_FQDN \
    --project=$PROJECT_ID # --vm=$VM_NAME --vm-ip=$VM_IP_ADDRESS --vm-port=$VM_PORT --vpc=$VPC
fi



# Check if the dms job creation was successful
if [ $? -eq 0 ]; then
  echo "${GREEN}DMS job $MIGRATION_JOB_NAME created successfully.${NC}"
else
  echo "${RED}Error: Failed to create DMS job $MIGRATION_JOB_NAME.${NC}"
  exit 1
fi

echo "${YELLOW}Waiting for DMS job to be in ready state...${NC}"

# wait for DMS creation
while true; do
    STATUS=$(gcloud database-migration migration-jobs describe "$MIGRATION_JOB_NAME" --region="$REGION" --project="$PROJECT_ID" --format='value(state)')

    if [[ "$STATUS" == "NOT_STARTED" ]]; then
        echo "Migration job '$MIGRATION_JOB_NAME' has changed state to: $STATUS"
        break  # Exit the loop when the state is no longer NOT_STARTED
    else
        echo "Migration job '$MIGRATION_JOB_NAME' is still not ready. Waiting..."
        sleep 10  # Wait for 10 seconds before checking again
    fi
done

if (( target_type_name == "AlloyDB" )); then
  # Demote the destination before starting the job
  gcloud database-migration migration-jobs demote-destination $MIGRATION_JOB_NAME --region=$REGION --project=$PROJECT_ID
  echo ""
  echo "${YELLOW}waiting for destination to be in demoted state...${NC}"
  # wait for destination demotion

  while true; do
      STATUS=$(gcloud alloydb clusters describe $DESTINATION_ALLOYDB --region=$REGION --project=$PROJECT_ID --format="value(state)")

      if [[ "$STATUS" == "BOOTSTRAPPING" ]]; then
          echo "${GREEN}${BOLD}Destination is demoted.${NC}"
          break  # Exit the loop when the state is no longer NOT_STARTED
      else
          echo "Waiting for destination to be in demoted state..."
          sleep 10  # Wait for 10 seconds before checking again
      fi
  done
else
  # Demote the destination before starting the job
  gcloud database-migration migration-jobs demote-destination $MIGRATION_JOB_NAME --region=$REGION --project=$PROJECT_ID
  while true; do
      MASTER_TYPE=$(gcloud sql instances describe $DESTINATION_CloudSQL_INSTANCE_NAME --project=$PROJECT_ID --format='value(instanceType)')
      if [[ "$MASTER_TYPE" == "READ_REPLICA_INSTANCE" ]]; then
          echo "${GREEN}${BOLD}Destination is demoted.${NC}"
          break  # Exit the loop when the state is no longer NOT_STARTED
      else
          echo "Waiting for destination to be in demoted state..."
          sleep 10  # Wait for 10 seconds before checking again
      fi
  done
fi

echo ""
echo "${BOLD}Migration Job details${NC}"
gcloud database-migration migration-jobs describe $MIGRATION_JOB_NAME --region=$REGION --project=$PROJECT_ID 
echo ""
echo "${YELLOW}Starting the DMS job...${NC}"

#Start DMS Job
gcloud database-migration migration-jobs start $MIGRATION_JOB_NAME --region=$REGION --project=$PROJECT_ID

echo ""
while true; do
    STATUS=$(gcloud database-migration migration-jobs describe "$MIGRATION_JOB_NAME" --region="$REGION" --project="$PROJECT_ID" --format='value(state)')

    if [[ "$STATUS" == "FAILED" ]]; then
        echo "${RED}Migration job '$MIGRATION_JOB_NAME' has FAILED. Please check the job on the console.${NC}"
        break  # Exit the loop when the state is no longer NOT_STARTED
    elif [[ "$STATUS" == "RUNNING" ]]; then
        echo "${BOLD}Migration job '$MIGRATION_JOB_NAME' is running. Please check the job on the console.${NC}"
        break
    else
        echo "Migration job '$MIGRATION_JOB_NAME' has started. Waiting to be in running state..."
        sleep 10  # Wait for 10 seconds before checking again
    fi
done

exit 0 # Exit with a success code
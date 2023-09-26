#!/bin/bash

# Load environment variables
source .env

# Deploy using script
forge script ./src/scripts/Deploy.sol:Deploy --sig "deploy()()" $CHAIN \
--rpc-url $RPC_URL --private-key $PRIVATE_KEY --froms $DEPLOYER --slow -vvv \
--broadcast --verify --etherscan-api-key $ETHERSCAN_KEY # uncomment to broadcast to the network